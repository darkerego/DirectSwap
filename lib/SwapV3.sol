// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;
// Copyright Darkerego, 2025
import {DeploymentAddresses} from "lib/DeploymentAddresses.sol";
import {TransferHelper} from "lib/TransferHelper.sol";

interface IUniswapV3Pool {
    function token0() external view returns (address);
    function token1() external view returns (address);
    function slot0() external view returns (
        uint160 sqrtPriceX96,
        int24 tick,
        uint16 observationIndex,
        uint16 observationCardinality,
        uint16 observationCardinalityNext,
        uint8 feeProtocol,
        bool unlocked
    );
    function swap(
        address recipient,
        bool zeroForOne,
        int256 amountSpecified,
        uint160 sqrtPriceLimitX96,
        bytes calldata data
    ) external returns (int256 amount0, int256 amount1);
}

interface IUniswapV3Factory {
    function getPool(address tokenA, address tokenB, uint24 fee) external view returns (address pool);
}

interface IWETH {
    function deposit() external payable;
    function withdraw(uint256) external;
}



contract UniswapV3DirectSwapper is DeploymentAddresses, TransferHelper {
    address private immutable factory;
    address private immutable weth;
    uint160 private constant MIN_SQRT_RATIO = 4295128739 + 1;
    uint160 private constant MAX_SQRT_RATIO = 1461446703485210103287273052203988822378723970341 - 1;

    uint24[4] private fees = [100, 500, 3000, 10000];
    error InvalidCallback(address _caller, address _pool);
    error NoPoolFound();
    error AmountMismatch(uint256 msgValue, uint256 amountIn);
    event Callback(address indexed caller);

    constructor() {
        factory = deployment.uniswapV3Factory;
        weth = deployment.wrappedEther;

    }


    /*
    * @notice Swap tokens externally using Uniswap V3.
    * @dev WARN: UNAUTHENTICATED! Override this function with some logic like:
    * `require(msg.sender == admin, UnAuthorized());` or get rekt!
    */
    function swapV3(
        address tokenIn,
        address tokenOut,
        uint256 amountIn,
        uint24 fee
    ) external virtual payable returns (address poolUsed, uint256 amountOut) {
        return _swapV3(tokenIn, tokenOut, amountIn, fee, true, true);
    }

    function _swapV3(
        address tokenIn,
        address tokenOut,
        uint256 amountIn,
        uint24 fee,
        bool pullIn, // calls transferFrom(msg.sender, address(this), amountIn) before swap
        bool pushOut // calls transfer(msg.sender, amountOut) after swap
    ) internal returns (address poolUsed, uint256 amountOut) {

        (address _tokenOut, address _tokenIn, uint256 _amountIn, uint24 _fee) = (tokenIn, tokenOut, amountIn, fee);
        if (fee == 0) {
            (poolUsed, _fee) = findBestFeePool(tokenIn, tokenOut);
            require(poolUsed != address(0), NoPoolFound());
        } else {
            poolUsed = IUniswapV3Factory(factory).getPool(tokenIn, tokenOut, fee);
            require(poolUsed != address(0), NoPoolFound());
        }
        bool zeroForOne = tokenIn == IUniswapV3Pool(poolUsed).token0();
        uint160 sqrtPriceLimitX96 = computeSqrtPriceLimit(poolUsed, zeroForOne);
        if (msg.value > 0 && tokenIn == weth) {
            require(amountIn == msg.value, AmountMismatch(msg.value, amountIn));
            IWETH(weth).deposit{value: msg.value}();
        } else {
            if (pullIn) {
                safeTransferFrom(tokenIn, msg.sender, address(this), amountIn);
            }
        }
       (int256 amount0, int256 amount1) = IUniswapV3Pool(poolUsed).swap(
            address(this),
            zeroForOne,
            int256(_amountIn),
            sqrtPriceLimitX96,
            abi.encode(_tokenIn, _tokenOut, _fee)
        );
        int256 _amountOut = zeroForOne ? -amount1 : -amount0;
        amountOut = uint256(_amountOut);
        if (pushOut) {
            safeTransfer(_tokenOut, msg.sender, amountOut);
        }


    }

    function computeSqrtPriceLimit(
        address pool,
        bool zeroForOne
    ) internal view returns (uint160) {
        (uint160 currentSqrtPriceX96,,,,,,) = IUniswapV3Pool(pool).slot0();

        // Apply small buffer: ~0.01% of the price
        uint160 buffer = currentSqrtPriceX96 / 10000;
        if (zeroForOne) {
            uint160 limit = currentSqrtPriceX96 - buffer;
            return limit > MIN_SQRT_RATIO ? limit : MIN_SQRT_RATIO;
        } else {
            uint160 limit = currentSqrtPriceX96 + buffer;
            return limit < MAX_SQRT_RATIO ? limit : MAX_SQRT_RATIO;
        }
    }

    function sqrt(uint y) internal pure returns (uint z) {
        if (y > 3) {
            z = y;
            uint x = y / 2 + 1;
            while (x < z) {
                z = x;
                x = (y / x + x) / 2;
            }
        } else if (y != 0) {
            z = 1;
        }
    }


    function findBestFeePool(address token0, address token1) internal view returns (address bestPool, uint24 _fee) {
        for (uint8 i = 0; i < fees.length; i++) {
            address pool = IUniswapV3Factory(factory).getPool(token0, token1, fees[i]);
            if (pool != address(0)) {
                bestPool = pool;
                _fee = fees[i];
                break;
            }
        }
    }

    function uniswapV3SwapCallback(
        int256 amount0Delta,
        int256 amount1Delta,
        bytes calldata data
    ) external {
        (address token0, address token1, uint24 fee) = abi.decode(data, (address, address, uint24));
        address pool = IUniswapV3Factory(factory).getPool(token0, token1, fee);
        require(msg.sender == pool, InvalidCallback(msg.sender, pool));
         if (amount0Delta > 0) {
            safeTransfer(IUniswapV3Pool(msg.sender).token0(), pool, uint256(amount0Delta));
        } else {
            assert(amount1Delta > 0);
            safeTransfer(IUniswapV3Pool(msg.sender).token1(), pool, uint256(amount1Delta));
        }


    }

    receive() external payable {}
}
