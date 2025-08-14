// SPDX-License-Identifier: MIT
pragma solidity ^0.8.30;
interface IUniswapV2Factory {
    function getPair(address tokenA, address tokenB) external view returns (address);
}

interface IUniswapV2Pair {
    function getReserves() external view returns (
        uint112 reserve0, uint112 reserve1, uint32 blockTimestampLast
    );
    function token0() external view returns (address);
    function token1() external view returns (address);
    function swap(uint amount0Out, uint amount1Out, address to, bytes calldata data) external;
}


interface IWETH {
    function deposit() external payable;
    function withdraw(uint256) external;
}


interface IUniswapV3Factory {
    function getPool(address tokenA, address tokenB, uint24 fee) external view returns (address pool);
}

interface IUniswapV3Pool {
    function token0() external view returns (address);
    function token1() external view returns (address);
    function liquidity() external view returns(uint128);
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

interface IUniswapV4PoolManager {
    struct PoolKey {
        address currency0;
        address currency1;
        uint24 fee;
        int24 tickSpacing;
        address hook;
    }

    struct SwapParams {
        PoolKey key;
        bool zeroForOne;
        int256 amountSpecified;
        uint160 sqrtPriceLimitX96;
        bytes hookData;
    }

    struct BalanceDelta {
        int256 amount0;
        int256 amount1;
    }

    function swap(SwapParams calldata params) external returns (BalanceDelta memory delta);
}