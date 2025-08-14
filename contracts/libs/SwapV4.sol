// SPDX-License-Identifier: MIT
pragma solidity ^0.8.30;

import {DeploymentAddresses} from "./DeploymentAddresses.sol";
import {TransferHelper} from "./TransferHelper.sol";
import {IWETH, IUniswapV4PoolManager} from "./Interfaces.sol";

abstract contract UniswapV4DirectSwapper is DeploymentAddresses, TransferHelper {
    address private immutable poolManager;
    address private immutable wrappedEther;
    uint160 private constant MIN_SQRT_RATIO = 4295128739 + 1;
    uint160 private constant MAX_SQRT_RATIO = 1461446703485210103287273052203988822378723970341 - 1;

    error AmountMismatch(uint256 msgValue, uint256 amountIn);
    error QuoteCallFailed();

    constructor() {
        poolManager = deployment.uniswapV4PoolManager;
        wrappedEther = deployment.wrappedEther;
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
        virtual
        returns (IUniswapV4PoolManager.PoolKey memory key, uint256 amountOut)
    {
        return _swapV4(tokenIn, tokenOut, amountIn, fee, tickSpacing, slippageBps, true, true);
    }

    function _swapV4(
        address tokenIn,
        address tokenOut,
        uint256 amountIn,
        uint24 fee,
        int24 tickSpacing,
        uint32 slippageBps,
        bool pullIn,
        bool pushOut
    )
        internal
        returns (IUniswapV4PoolManager.PoolKey memory key, uint256 amountOut)
    {
        require(poolManager != address(0), "pool manager not set");

        (address currency0, address currency1) = tokenIn < tokenOut
            ? (tokenIn, tokenOut)
            : (tokenOut, tokenIn);
        bool zeroForOne = tokenIn == currency0;

        key = IUniswapV4PoolManager.PoolKey({
            currency0: currency0,
            currency1: currency1,
            fee: fee,
            tickSpacing: tickSpacing,
            hook: address(0)
        });

        if (tokenIn == wrappedEther && msg.value > 0) {
            if (msg.value != amountIn) revert AmountMismatch(msg.value, amountIn);
            IWETH(wrappedEther).deposit{value: msg.value}();
        } else {
            if (pullIn) {
                if (tokenAllowance(tokenIn, msg.sender, address(this)) < amountIn) {
                    revert InsufficientAllowance(tokenIn, msg.sender, amountIn);
                }
                safeTransferFrom(tokenIn, msg.sender, address(this), amountIn);
            }
        }

        safeApprove(tokenIn, poolManager, amountIn);

        uint256 balBefore = tokenBalance(tokenOut, address(this));

        IUniswapV4PoolManager.SwapParams memory params = IUniswapV4PoolManager.SwapParams({
            key: key,
            zeroForOne: zeroForOne,
            amountSpecified: int256(amountIn),
            sqrtPriceLimitX96: zeroForOne ? MIN_SQRT_RATIO : MAX_SQRT_RATIO,
            hookData: new bytes(0)
        });

        IUniswapV4PoolManager.BalanceDelta memory delta =
            IUniswapV4PoolManager(poolManager).swap(params);

        if (delta.amount0 > 0) {
            safeTransfer(tokenIn, poolManager, uint256(delta.amount0));
        } else if (delta.amount1 > 0) {
            safeTransfer(tokenIn, poolManager, uint256(delta.amount1));
        }

        amountOut = tokenBalance(tokenOut, address(this)) - balBefore;

        if (slippageBps > 0) {
            uint256 minAmountOut = (amountIn * (10000 - slippageBps)) / 10000;
            if (amountOut < minAmountOut) revert SlippageExceeded(amountOut, minAmountOut);
        }

        if (pushOut) {
            if (tokenOut == wrappedEther) {
                IWETH(wrappedEther).withdraw(amountOut);
                executeCall(msg.sender, amountOut, new bytes(0));
            } else {
                safeTransfer(tokenOut, msg.sender, amountOut);
            }
        }
    }

    function quoteV4(
        address tokenIn,
        address tokenOut,
        uint256 amountIn,
        uint24 fee,
        int24 tickSpacing
    ) external view returns (uint256 amountOut) {
        (address currency0, address currency1) = tokenIn < tokenOut
            ? (tokenIn, tokenOut)
            : (tokenOut, tokenIn);
        bool zeroForOne = tokenIn == currency0;

        IUniswapV4PoolManager.PoolKey memory key = IUniswapV4PoolManager.PoolKey({
            currency0: currency0,
            currency1: currency1,
            fee: fee,
            tickSpacing: tickSpacing,
            hook: address(0)
        });

        IUniswapV4PoolManager.SwapParams memory params = IUniswapV4PoolManager.SwapParams({
            key: key,
            zeroForOne: zeroForOne,
            amountSpecified: int256(amountIn),
            sqrtPriceLimitX96: zeroForOne ? MIN_SQRT_RATIO : MAX_SQRT_RATIO,
            hookData: new bytes(0)
        });

        bytes memory payload = abi.encodeWithSelector(
            IUniswapV4PoolManager.swap.selector,
            params
        );
        (bool ok, bytes memory data) = staticCall(poolManager, payload);
        if (!ok) revert QuoteCallFailed();

        IUniswapV4PoolManager.BalanceDelta memory delta =
            abi.decode(data, (IUniswapV4PoolManager.BalanceDelta));

        amountOut = uint256(
            zeroForOne ? -delta.amount1 : -delta.amount0
        );
    }
}

