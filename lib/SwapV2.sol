// SPDX-License-Identifier: MIT
pragma solidity ^0.8.30;
import {DeploymentAddresses} from "lib/DeploymentAddresses.sol";
import {TransferHelper} from "lib/TransferHelper.sol";
import {IWETH, IUniswapV2Pair, IUniswapV2Factory} from "lib/Interfaces.sol";



abstract contract UniswapV2DirectSwapper is DeploymentAddresses, TransferHelper {
    address private immutable factory;
    address private immutable weth;
    error PairNotFound();
    error MismatchedEthAmount(uint256 msgValue, uint256 amountIn);
    error InvalidToken(address);

    constructor() {
        factory = deployment.uniswapV2Factory;
        weth = deployment.wrappedEther;
    }


    /*
    * @notice Swap tokens externally using Uniswap V3.
    * @dev WARN: UNAUTHENTICATED! Override this function with some logic like:
    * `require(msg.sender == admin, UnAuthorized());` or get rekt!
    */

    function swapV2(address tokenIn, address tokenOut, uint256 amountIn) external payable virtual returns(address, uint256) {
        return _swapV2(tokenIn, tokenOut, amountIn, true, true);
    }

    function _swapV2(
        address tokenIn,
        address tokenOut,
        uint256 amountIn,
        bool pullIn,
        bool pushOut
    ) internal returns(address pair, uint256 amountOut) {
        address _tokenIn = tokenIn;
        address _tokenOut = tokenOut;
        uint256 tokenOutBalanceBefore = tokenBalance(tokenOut, address(this));
        uint256 _amountIn = amountIn;
        pair = IUniswapV2Factory(factory).getPair(tokenIn, tokenOut);
        require(pair != address(0), PairNotFound());

        if (tokenIn == weth && msg.value > 0) {
            require(msg.value == amountIn, MismatchedEthAmount(msg.value, amountIn));
            IWETH(weth).deposit{value: msg.value}();
            safeTransfer(weth, pair, amountIn);
        } else {
            if (pullIn){
                require(tokenAllowance(tokenIn, msg.sender, address(this)) >= amountIn, InsufficientAllowance(tokenIn, msg.sender, amountIn));
                safeTransferFrom(tokenIn, msg.sender, pair, amountIn);
            } else {
                safeTransfer(tokenIn, pair, amountIn);
            }
        }

        (uint112 reserve0, uint112 reserve1, ) = IUniswapV2Pair(pair).getReserves();
        address token0 = IUniswapV2Pair(pair).token0();
        address token1 = IUniswapV2Pair(pair).token1();

        (uint256 amount0Out, uint256 amount1Out) =
            _calculateSwap(_tokenIn, token0, token1, reserve0, reserve1, _amountIn);
        IUniswapV2Pair(pair).swap(amount0Out, amount1Out, address(this), new bytes(0));
        amountOut = tokenBalance(_tokenOut, address(this)) - tokenOutBalanceBefore;
        if (pushOut) {
            if (_tokenOut == weth) {
                IWETH(weth).withdraw(amountOut);
                executeCall(msg.sender, amountOut, new bytes(0));
            } else {
                safeTransfer(_tokenOut, msg.sender, amountOut);
            }

        }
    }

    function quoteV2(address tokenIn, address tokenOut, uint256 amountIn) external view returns(uint256) {
        address pair = IUniswapV2Factory(factory).getPair(tokenIn, tokenOut);
        require(pair != address(0), PairNotFound());
        (uint112 reserve0, uint112 reserve1, ) = IUniswapV2Pair(pair).getReserves();
        address token0 = IUniswapV2Pair(pair).token0();
        address token1 = IUniswapV2Pair(pair).token1();

        (uint256 amount0Out, uint256 amount1Out) =
            _calculateSwap(tokenIn, token0, token1, reserve0, reserve1, amountIn);
        return amount0Out == 0 ? amount1Out : amount0Out;
    }


    function _calculateSwap(
        address tokenIn,
        address token0,
        address token1,
        uint112 reserve0,
        uint112 reserve1,
        uint amountIn
    ) internal pure returns (
        uint256 amount0Out,
        uint256 amount1Out
    ) {
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
