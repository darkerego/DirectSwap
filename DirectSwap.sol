// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;
// Copyright Darkerego, 2025
import {UniswapV2DirectSwapper} from "lib/SwapV2.sol";
import{UniswapV3DirectSwapper} from "lib/SwapV3.sol";

/*
* @dev Perform swaps on uniswap v3 and v3 by interacting directly with the liquidity pools, rather than the swap router.
*/

contract UniswapDirectSwap is UniswapV2DirectSwapper, UniswapV3DirectSwapper {
    error NotAuthorizedCaller();
    event ExecSwap(address indexed tokenIn, address indexed tokenOut, uint256 amountIn);
    event ExecSwapTest(address indexed tokenIn, address indexed tokenOut, uint256 amountIn, uint256 amountOut);
    event AdminTransferred(address indexed old, address indexed _new);
    event Withdrawal(address indexed token, uint256 amount);
    address public admin;

    constructor() {
        admin = msg.sender;
    }

    modifier auth {
        _auth();
        _;
    }

    receive() external payable {}

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
        uint24 fee
        ) external payable auth override
        returns(
            address poolUsed,
            uint256 amountOut
            ) {
        emit ExecSwap(tokenIn, tokenOut, amountIn);
        return super._swapV3(tokenIn, tokenOut, amountIn, fee, true, true);
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
        uint256 amountIn
        ) external payable auth override
        returns
        (
            address poolUsed,
            uint256 amountOut
        ) {
        emit ExecSwap(tokenIn, tokenOut, amountIn);
        return super._swapV2(tokenIn, tokenOut, amountIn, true, true);
    }

    /*
    * @notice : Swap tokenIn to tokenOut and back to tokenIn
    * @dev : Used to detect honeypot tokens
    * @param tokenIn : spend token
    * @param tokenOut : swap into token
    * @param amountIn : amount of tokenIn to spend
    * @param fee : fee tier of v3 pool if v3
    * @param useV3 : use Uniswap V3 or V2
    */

    function swapTest(
        address tokenIn,
        address tokenOut,
        uint256 amountIn,
        uint24 fee,
        bool useV3
        ) external payable auth
        returns(
            uint256 amountOut0,
            uint256 amountOut1
            ){
        if (useV3) {
            (, amountOut0) = _swapV3(tokenIn, tokenOut, amountIn, fee, true, false);
            (, amountOut1) = _swapV3(tokenOut, tokenIn, amountOut0, fee, false, true);
        } else {
            (, amountOut0) = _swapV2(tokenIn, tokenOut, amountIn, true, false);
            (, amountOut1) = _swapV2(tokenOut, tokenIn, amountOut0, false, true);
        }
        emit ExecSwapTest(tokenIn, tokenOut, amountIn, amountOut1);
    }

    /*
    * @notice : Withdraw token from contract
    * @param tokenAddress : token to withdraw
    * @param amount : amount of token to withdraw
    */
    function withdraw(address tokenAddress, uint256 amount) external auth {
        emit Withdrawal(tokenAddress, amount);
        if (tokenAddress == deployment.nativeEther) {
            executeCall(msg.sender, amount, "");
        } else {
            safeTransfer(tokenAddress, msg.sender, amount);
        }
    }

    /*
    * @notice : Transfer admin role to new address
    */
    function setAdmin(address _admin) external auth {
        emit AdminTransferred(admin, _admin);
        admin = _admin;
    }

    /*
    * @dev : Check if caller is admin
    */
    function _auth() internal view {
        require(msg.sender == admin, NotAuthorizedCaller());
    }

}