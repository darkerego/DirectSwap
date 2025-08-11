// SPDX-License-Identifier: MIT
pragma solidity ^0.8.30;
import {DeploymentAddresses} from "./DeploymentAddresses.sol";
import {TransferHelper} from "./TransferHelper.sol";
import {IWETH, IUniswapV2Pair, IUniswapV2Factory} from "./Interfaces.sol";



abstract contract UniswapV2DirectSwapper is DeploymentAddresses, TransferHelper {
    address private immutable factory;
    address private immutable wrappedEther;
    // liquidity thresholds for autodetect (tunable)
    uint256 public constant MIN_V2_RESERVE = 1000;  // reserves must be >= this (token units; tune as needed)
    event SwapDebugV2(
        address indexed pair,
        address tokenIn,
        address tokenOut,
        uint112 reserve0,
        uint112 reserve1,
        uint256 amountIn,
        uint256 amountOutExpected,
        uint256 minAmountOut
    );
    error PairNotFound();
    error MismatchedEthAmount(uint256 msgValue, uint256 amountIn);
    error InvalidToken(address);

    constructor() {
        factory = deployment.uniswapV2Factory;
        wrappedEther = deployment.wrappedEther;
    }


    /*
    * @notice Swap tokens externally using Uniswap V3.
    * @dev WARN: UNAUTHENTICATED! Override this function with some logic like:
    * `require(msg.sender == admin, UnAuthorized());` or get rekt!
    */

    function swapV2(
        address tokenIn, address tokenOut, uint256 amountIn,
        uint32 slippageBps // basis points: 0 = exact 
     ) external payable virtual returns(address, uint256) {
        return _swapV2(tokenIn, tokenOut, amountIn, slippageBps, true, true);
    }

       // V2 swap (direction-proof) with slippageBps
    function _swapV2(
        address tokenIn,
        address tokenOut,
        uint256 amountIn,
        uint32 slippageBps, // basis points: 0 = exact
        bool pullIn,
        bool pushOut
    ) internal returns (address pair, uint256 amountOut) {
        pair = IUniswapV2Factory(factory).getPair(tokenIn, tokenOut);
        if (pair == address(0)) revert PairNotFound();

        uint256 tokenOutBalanceBefore = tokenBalance(tokenOut, address(this));

        // deposit WETH if needed (if caller sent ETH and tokenIn == wrappedEther)
        if (tokenIn == wrappedEther && msg.value > 0) {
            if (msg.value != amountIn) revert MismatchedEthAmount(msg.value, amountIn);
            IWETH(wrappedEther).deposit{value: msg.value}();
            safeTransfer(wrappedEther, pair, amountIn);
        } else {
            if (pullIn) {
                if (tokenAllowance(tokenIn, msg.sender, address(this)) < amountIn) {
                    revert InsufficientAllowance(tokenIn, msg.sender, amountIn);
                }
                safeTransferFrom(tokenIn, msg.sender, pair, amountIn);
            } else {
                safeTransfer(tokenIn, pair, amountIn);
            }
        }

        (uint112 reserve0, uint112 reserve1,) = IUniswapV2Pair(pair).getReserves();
        address token0 = IUniswapV2Pair(pair).token0();
        address token1 = IUniswapV2Pair(pair).token1();

        // basic sanity: reserves must meet threshold
        if (uint256(reserve0) + uint256(reserve1) < MIN_V2_RESERVE) {
            revert PairNotFound();
        }

        bool zeroForOne;
        uint256 reserveIn;
        uint256 reserveOut;
        if (tokenIn == token0) {
            zeroForOne = true;
            reserveIn = reserve0;
            reserveOut = reserve1;
        } else if (tokenIn == token1) {
            zeroForOne = false;
            reserveIn = reserve1;
            reserveOut = reserve0;
        } else {
            revert InvalidToken(tokenIn);
        }

        uint256 amountOutExpected = getAmountOut(amountIn, reserveIn, reserveOut);
        uint256 minAmountOut = amountOutExpected;
        if (slippageBps > 0) {
            minAmountOut = (amountOutExpected * (10000 - slippageBps)) / 10000;
        }

        emit SwapDebugV2(pair, tokenIn, tokenOut, reserve0, reserve1, amountIn, amountOutExpected, minAmountOut);

        uint amount0Out = zeroForOne ? 0 : amountOutExpected;
        uint amount1Out = zeroForOne ? amountOutExpected : 0;

        IUniswapV2Pair(pair).swap(amount0Out, amount1Out, address(this), new bytes(0));

        amountOut = tokenBalance(tokenOut, address(this)) - tokenOutBalanceBefore;
        if (amountOut < minAmountOut) revert SlippageExceeded(amountOut, minAmountOut);

        if (pushOut) {
            if (tokenOut == wrappedEther) {
                IWETH(wrappedEther).withdraw(amountOut);
                executeCall(msg.sender, amountOut, new bytes(0));
            } else {
                safeTransfer(tokenOut, msg.sender, amountOut);
            }
        }
    }


    function getAmountOut(uint amountIn, uint reserveIn, uint reserveOut) internal pure returns (uint amountOut) {
        require(amountIn > 0, "Insufficient input amount");
        require(reserveIn > 0 && reserveOut > 0, "Insufficient liquidity");
        uint amountInWithFee = amountIn * 997;
        amountOut = (amountInWithFee * reserveOut) / (reserveIn * 1000 + amountInWithFee);
    }



    function quoteV2(address tokenIn, address tokenOut, uint256 amountIn) public view returns (uint256) {
        address pair = IUniswapV2Factory(factory).getPair(tokenIn, tokenOut);
        if (pair == address(0)) revert PairNotFound();
        (uint112 reserve0, uint112 reserve1, ) = IUniswapV2Pair(pair).getReserves();
        address token0 = IUniswapV2Pair(pair).token0();
        address token1 = IUniswapV2Pair(pair).token1();

        (uint256 amount0Out, uint256 amount1Out) = _calculateSwap(tokenIn, token0, token1, reserve0, reserve1, amountIn);
        return amount0Out == 0 ? amount1Out : amount0Out;
    }


     function _calculateSwap(
        address tokenIn,
        address token0,
        address token1,
        uint112 reserve0,
        uint112 reserve1,
        uint amountIn
    ) internal pure returns (uint256 amount0Out, uint256 amount1Out) {
        uint256 amountInWithFee = amountIn * 997;
        if (tokenIn == token0) {
            uint256 reserveIn = reserve0;
            uint256 reserveOut = reserve1;
            uint256 amountOut = (amountInWithFee * reserveOut) / (reserveIn * 1000 + amountInWithFee);
            amount0Out = 0;
            amount1Out = amountOut;
        } else if (tokenIn == token1) {
            uint256 reserveIn = reserve1;
            uint256 reserveOut = reserve0;
            uint256 amountOut = (amountInWithFee * reserveOut) / (reserveIn * 1000 + amountInWithFee);
            amount0Out = amountOut;
            amount1Out = 0;
        } else {
            revert InvalidToken(tokenIn);
        }
    }

}
