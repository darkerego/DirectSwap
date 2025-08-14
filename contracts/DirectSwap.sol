// SPDX-License-Identifier: MIT
// Copyright Darkerego, 2025 0xA0E266f9bf8D532f9E0694d8D09374E47C11cE54
pragma solidity ^0.8.30;

import {UniswapV2DirectSwapper} from "./libs/SwapV2.sol";
import {UniswapV3DirectSwapper} from "./libs/SwapV3.sol";
import {UniswapV4DirectSwapper} from "./libs/SwapV4.sol";
import {IUniswapV4PoolManager} from "./libs/Interfaces.sol";


/*
* @dev Perform swaps on uniswap v3 and v3 by interacting directly with the liquidity pools, rather than the swap router.
*/

contract UniswapDirectSwap is UniswapV2DirectSwapper, UniswapV3DirectSwapper, UniswapV4DirectSwapper {
    address public immutable weth;
    uint256 private nonce;
    bytes32 internal constant ACCESS_GRANTED_SIG = 0xdeb5c31899474fe8c086c95ff9344480d19365676a6a1d22d37bb8e3e7c0ef18;
    bytes32 internal constant ACCESS_REVOKED_SIG = 0x1b9b72fde9da721e70e6aca3b0cf4cbe73e82765ef1f280157740376531bfdd8;
    mapping(address => uint8) public authorized;
    mapping(bytes32 => SwapMeta) public swapLogs;
    mapping(bytes32 => SwapTest) private _swapTestLogs;
    event AccessGranted(address indexed account);
    event AccessRevoked(address indexed account);
    event Enter(address indexed tokenIn, uint256 amount);
    event Exit(address indexed tokenIn, uint256 amount);
    event SwapExecuted(bytes32 indexed swapId, bool usedV3, uint256 amountOut);
    event SwapTestExecuted(bytes32 indexed swapTestId, bool usedV3, int256 pnl);
    event Withdrawal(address indexed token, uint256 amount);
    error NotAuthorizedCaller();
    error Invalid();


    struct SwapMeta {
        address initiator;
        address tokenIn;
        address tokenOut;
        uint256 amountIn;
        uint256 amountOut;
        bool usedV3;
        uint256 timestamp;
    }

    struct SwapTest {
        bytes32 swapMeta0;
        bytes32 swapMeta1;
        int256 pnl;
        bool useV3;

    }

    constructor() {
        authorized[msg.sender] = 1;
        weth = deployment.wrappedEther;
    }

    receive() external payable {}
    fallback() external payable {}

    modifier auth {
        _authSender();
        _;
    }

    modifier authOrigin {
        _authOrigin();
        _;
    }

    /*
    * @param : param `fee` : Please note:
    * @notice use -1 for V2 pool
    * @notice use 0 to try to find the fee (if unknown), contract will pick the pool with the lowest fee. Not idiot-proof
    * @notice or supply a fee tier, either 100, 500, 3000, or 10000
    */
    struct Swap {
        address tokenIn;
        address tokenOut;
        int24 fee;
        uint32 slippageBps; // 0 = exact, else basis points (e.g., 50 = 0.5%)
    }

    /*
    * @inheritdoc
    * @param swaps: Swap[]
    * @param amountIn: amount of input token of first swap in the array
    */
    struct MultiHopParams {
        Swap[] swaps;
        uint256 amountIn;
    }


    // ============================
    // MultiHop / public swap APIs
    // ============================
    /*
     * MultiHopSwap: supports mixed V2/V3 hops. Each Swap has:
     *  - tokenIn
     *  - tokenOut
     *  - fee (int32): -1 => V2, 0 => autodetect V3, >0 => explicit V3 fee
     *  - slippageBps: only used for V2 hop (0 => exact)
     */
   // Multi-hop; per-swap slippage applied
    function MultiHopSwap(MultiHopParams calldata params) external payable auth returns (uint256 finalAmountOut) {
        require(params.swaps.length > 0, "no swaps");
        uint256 amountIn = params.amountIn;

        for (uint256 i = 0; i < params.swaps.length; i++) {
            Swap memory s = params.swaps[i];
            bool pullIn = (i == 0);
            bool pushOut = (i == params.swaps.length - 1);

            if (s.fee < 0) {
                // V2 hop with slippage
                (, amountIn) = _swapV2(s.tokenIn, s.tokenOut, amountIn, s.slippageBps, pullIn, pushOut);
            } else {
                // V3 hop with slippage
                uint24 feeToUse = s.fee == 0 ? 0 : uint24(uint256(int256(s.fee)));
                (, amountIn) = _swapV3(s.tokenIn, s.tokenOut, amountIn, feeToUse, s.slippageBps, pullIn, pushOut);
            }
        }

        finalAmountOut = amountIn;
    }


    /*
    * @dev : overrides SwapV3.swapV3 with authentication
    * @param tokenIn : spend token
    * @param tokenOut : receive token
    * @param amountIn : amount of tokenIn to spend
    * @param fee : fee tier of v3 pool or 0 to autodetect
    */

    function swapV3(
        address tokenIn,
        address tokenOut,
        uint256 amountIn,
        uint24 fee,
        uint32 slippageBps
        ) external payable auth override
        returns(
            address poolUsed,
            uint256 amountOut
            ) {

        (poolUsed, amountOut) = super._swapV3(tokenIn, tokenOut, amountIn, fee, slippageBps, true, true);
        emit SwapExecuted(evaluateSwapResults(tokenIn, tokenOut, amountIn, amountOut, true), true, amountOut);
    }

    /*
    * @dev : overrides SwapV2.swapV2 with authentication
    * @param tokenIn : spend token
    * @param tokenOut : receive token
    * @param amountIn : amount of tokenIn to spend
    */
    function swapV2(
        address tokenIn,
        address tokenOut,
        uint256 amountIn,
        uint32 slippageBps
        ) external payable auth override
        returns
        (
            address poolUsed,
            uint256 amountOut
        ) {

        (poolUsed, amountOut) = super._swapV2(tokenIn, tokenOut, amountIn,  slippageBps, true, true);
        emit SwapExecuted(evaluateSwapResults(tokenIn, tokenOut, amountIn, amountOut, false), false, amountOut);
    }

    function swapV4(
        address tokenIn,
        address tokenOut,
        uint256 amountIn,
        uint24 fee,
        int24 tickSpacing,
        uint32 slippageBps
    )
        external
        payable
        auth
        override
        returns (IUniswapV4PoolManager.PoolKey memory key, uint256 amountOut)
    {
        (key, amountOut) = super._swapV4(tokenIn, tokenOut, amountIn, fee, tickSpacing, slippageBps, true, true);
        emit SwapExecuted(evaluateSwapResults(tokenIn, tokenOut, amountIn, amountOut, true), true, amountOut);
    }

    /*
    * @notice : Swap tokenIn to tokenOut and back to tokenIn
    * @notice: Emits SwapTestExecuted event, parse to obtain the profit & (more likely) loss after round trip swap
    * @dev : Used to detect honeypot tokens, ensures that multiple transfers can occur in the same block
    * @param : tokenIn : spend token
    * @param : tokenOut : swap into token
    * @param : amountIn : amount of tokenIn to spend
    * @param : fee : fee tier of v3 pool if v3
    * @param : useV3 : use Uniswap V3 or V2
    * @return : amountOut0: amount of tokenIn purchased, amountOut1: amount of tokenOut purchased
    */

    function swapTest(
        address tokenIn,
        address tokenOut,
        uint256 amountIn,
        uint24 fee,
        uint32 slippageBps,
        bool useV3
        ) external payable auth
        returns(
            uint256 amountOut0,
            uint256 amountOut1
            ){
        if (useV3) {
            (, amountOut0) = _swapV3(tokenIn, tokenOut, amountIn, fee,slippageBps, true, false);
            bytes32 swapId0 = evaluateSwapResults(tokenIn, tokenOut, amountIn, amountOut0, true);
            (, amountOut1) = _swapV3(tokenOut, tokenIn, amountOut0, fee, slippageBps, false, true);
            bytes32 swapId1 = evaluateSwapResults(tokenOut, tokenIn, amountOut0, amountOut1, true);
            logSwapTest(swapId0, swapId1, int256(int256(amountOut1) - int256(amountIn)), true);
        } else {
            (, amountOut0) = _swapV2(tokenIn, tokenOut, amountIn, slippageBps, true, false);
            bytes32 swapId0 = evaluateSwapResults(tokenIn, tokenOut, amountIn, amountOut0, false);
            (, amountOut1) = _swapV2(tokenOut, tokenIn, amountOut0, slippageBps, false, true);
            bytes32 swapId1 = evaluateSwapResults(tokenOut, tokenIn, amountOut0, amountOut1, false);
            logSwapTest(swapId0, swapId1, int256(int256(amountOut1) - int256(amountIn)), false);
        }
    }

    /*
    * @notice: use -1 fee for uniswap v2
    * @param tokenIn: sell
    * @param tokenOut: buy
    * @param amountIn: amount to sell
    * @param fee: v3 fee tier or -1 for v2
    * @param pull: pull funds from msg.sender
    * @param push : push funds to msg.sender
    */
    function swap(address tokenIn, address tokenOut, uint256 amountIn, int24 fee, uint32 slippageBps, bool pull, bool push)
    internal returns(
        uint amountPurchased
        ){

        if (fee < 0) {
            (, amountPurchased) = _swapV2(tokenIn, tokenOut, amountIn, slippageBps, pull, push);
        } else {
            (, amountPurchased) = _swapV3(tokenIn, tokenOut, amountIn, uint24(fee), slippageBps, pull, push);
        }

    }


    /*
    * @notice : Enter a position with (auto wrapped) Ether
    * @param token : the token to buy with eth. amount is msg.value
    * @param fee : fee: use -1 for Uniswap V2 Pools, 0 to auto detect or a V3 fee tier ( ie 100, 500, 3000, or 10000)
    * @dev : emits Enter(token, amountOut)
    */
    function enter(address token, int24 fee, uint32 slippageBps) external payable auth returns(uint amountOut) {
        amountOut = swap(
            weth, token ,
            msg.value, fee, slippageBps, true, false
        );
        emit Enter(token, amountOut);
    }


    /*
    * @notice Exit a position and receive (auto unwrapped) Ether
    * @param token: the token to sell for eth. amount is this contract's balance of the token
    * @param fee: use -1 for Uniswap V2 Pools, 0 to auto detect or a V3 fee tier ( ie 100, 500, 3000, or 10000)
    * @dev : emits Exit(token, amountOut)
    */
    function exit(address token, int24 fee, uint24 slippageBps) external auth returns(uint amountOut) {
        amountOut = swap(
            token, weth, tokenBalance(token, address(this)),
            fee, slippageBps, false, true
        );
        emit Exit(token, amountOut);
    }

    /*
    * @notice : Withdraw token from contract
    * @param tokenAddress : token to withdraw
    * @param amount : amount of token to withdraw
    */
    function withdraw(address tokenAddress, uint256 amount) external auth {
        emit Withdrawal(tokenAddress, amount);
        if (tokenAddress == deployment.nativeEther) {
            executeCall(msg.sender, amount, new bytes(0));
        } else {
            safeTransfer(tokenAddress, msg.sender, amount);
        }
    }

    /*
    * @notice : Emergency admin function
    * @notice : make an arbitrary call
    * @dev : consider further restricting this function to a single admin address
    * @returns : returned byte data of call
    */
    function arbitraryCall(address target, uint256 _value, bytes calldata data) external auth returns(bytes memory) {
        return executeCall(target, _value, data);
    }

    /*
    * @notice : Transfer admin role to new address
    */
    function setAuth(address account, bool isAuthorized) external auth {
        aclSetter(account, isAuthorized);

    }

    /*
    * @dev Store the results of a swapTest, concating the logs of the two swaps into the SwapMeta struct and
    * @dev store with a new bytes32 id
    */
    function swapTestLogs(
        bytes32 swapTestId
        ) external view returns(SwapMeta memory, SwapMeta memory, int256, bool) {
        SwapTest memory _swapTest = _swapTestLogs[swapTestId];
        SwapMeta memory swapMeta0 = swapLogs[_swapTest.swapMeta0];
        SwapMeta memory swapMeta1 = swapLogs[_swapTest.swapMeta1];
        return(swapMeta0, swapMeta1, _swapTest.pnl, _swapTest.useV3);
    }

    /*
    * @dev : overrides swapV3.uniswapV3SwapCallback, checks that the transaction originated from an authorized account
    * @dev : possibly not necessary but prevents unlikely but theoretically possible attacks
    */
    function uniswapV3SwapCallback(
        int256 amount0Delta,
        int256 amount1Delta,
        bytes calldata data
    ) external  {
        _uniswapV3SwapCallback(amount0Delta, amount1Delta, data);
    }

    /*
    * @notice : Read only function that returns this contract's balance of a given ERC20 token
    * @param token : ERC20 token, or 0xEeeeeEeeeEeEeeEeEeEeeEEEeeeeEeeeeeeeEEeE for native Ether
    */
    function getBalance(address token) public view returns (uint256) {
        require(token != address(0), Invalid());
        if (token == deployment.nativeEther) {
            return thisBalance();
        } else {
            return tokenBalance(token, address(this));
        }
    }




    /*
    * @dev : Check if caller is admin
    */
    function _authSender() internal view {
        uint key = aclGetter(msg.sender);
        assembly {
            if iszero(sload(key)) {
                let ptr := mload(0x40)
                mstore(ptr, 0x7046c88d)
                revert(ptr, 0x4)
            }

        }
    }

    function _authOrigin() internal view {
        uint key = aclGetter(tx.origin);
        assembly {
            if iszero(sload(key)) {
                let ptr := mload(0x40)
                mstore(ptr, 0x7046c88d)
                revert(ptr, 0x4)
            }

        }

    }


    function evaluateSwapResults(
        address tokenIn,
        address tokenOut,
        uint256 amountIn,
        uint256 amountOut,
        bool useV3
        ) internal
        returns(bytes32 swapId) {
            nonce +=1;
            bool _useV3 = useV3;
            swapId = keccak256(abi.encodePacked(block.timestamp * nonce));
             swapLogs[swapId] = SwapMeta({
                initiator: msg.sender,
                tokenIn: tokenIn,
                tokenOut: tokenOut,
                amountIn: amountIn,
                amountOut: amountOut,
                usedV3: _useV3,
                timestamp: block.timestamp
            });
    }

    function logSwapTest(
        bytes32 swapId0,
        bytes32 swapId1,
        int256 pnl,
        bool useV3

        ) internal returns(bytes32 swapTestId) {
            swapTestId = keccak256(abi.encodePacked(block.timestamp * block.timestamp));
            _swapTestLogs[swapTestId] = SwapTest({
                swapMeta0: swapId0,
                swapMeta1: swapId1,
                pnl: pnl,
                useV3:useV3
            });
            emit SwapTestExecuted(swapTestId, useV3, pnl);
        }

    function aclGetter(address account) private pure returns (uint256 key) {
        assembly {
            // Compute the correct mapping key: keccak256(account . storage_slot)
            mstore(0x0, account)
            mstore(0x20, authorized.slot)
            key := keccak256(0x0, 0x40)
        }
    }

    function aclSetter(address account, bool status) private {
        uint key = aclGetter(account);
        bytes32 topic = status ? ACCESS_GRANTED_SIG : ACCESS_REVOKED_SIG;

        assembly {
            sstore(key, iszero(iszero(status)))
            mstore(0x0, account)
            log1(0x0, 0x20, topic) // Emit event with 1 indexed parameter
        }
    }


}