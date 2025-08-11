// SPDX-License-Identifier: MIT
pragma solidity ^0.8.30;
import {DeploymentAddresses} from "./DeploymentAddresses.sol";
import {TransferHelper} from "./TransferHelper.sol";
import {IWETH, IUniswapV3Factory, IUniswapV3Pool} from "./Interfaces.sol";


contract UniswapV3DirectSwapper is DeploymentAddresses, TransferHelper {
    address private immutable factory;
    address private immutable wrappedEther;
    uint160 private constant MIN_SQRT_RATIO = 4295128739 + 1;
    uint160 private constant MAX_SQRT_RATIO = 1461446703485210103287273052203988822378723970341 - 1;
    uint24[4] private fees = [100, 500, 3000, 10000];
    uint128 public constant MIN_V3_LIQUIDITY = 1000; // pool.liquidity() must exceed this
    error InvalidCallback(address _caller, address _pool);
    error NoPoolFound();
    error AmountMismatch(uint256 msgValue, uint256 amountIn);
    error QuoteCallFailed();
    event Callback(address indexed caller);
     event SwapDebugV3(
        address indexed pool,
        address tokenIn,
        address tokenOut,
        uint24 fee,
        uint256 amountIn,
        uint256 amountOutExpected,
        uint256 minAmountOut,
        uint128 poolLiquidity
    );

    struct QuoteParams {
        address tokenIn;
        address tokenOut;
        uint256 amountIn;
        uint24 fee;
        uint160 sqrtPriceLimitX96;
    }

    constructor() {
        (factory, wrappedEther) = (deployment.uniswapV3Factory, deployment.wrappedEther);
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
        uint24 fee,
        uint32 slippageBps
    ) external virtual payable returns (address poolUsed, uint256 amountOut) {
        return _swapV3(tokenIn, tokenOut, amountIn, fee, slippageBps, true, true);
    }

    // _swapV3 includes slippageBps parameter (0 => exact)
    function _swapV3(
        address tokenIn,
        address tokenOut,
        uint256 amountIn,
        uint24 fee, // 0 => autodetect
        uint32 slippageBps,
        bool pullIn,
        bool pushOut
    ) internal returns (address poolUsed, uint256 amountOut) {
        address _tokenIn = tokenIn;
        address _tokenOut = tokenOut;
        uint256 _amountIn = amountIn;
        uint24 _fee = fee;
        uint160 sqrtPriceLimitX96;
        bool zeroForOne;

        (poolUsed, _fee, sqrtPriceLimitX96, zeroForOne) = parsePool(tokenIn, tokenOut, fee);

        // handle incoming funds
        if (msg.value > 0 && tokenIn == wrappedEther) {
            if (_amountIn != msg.value) revert AmountMismatch(msg.value, _amountIn);
            IWETH(wrappedEther).deposit{value: msg.value}();
            // WETH must be transferred in callback to pool; for V3 we deposit to this contract and provide funds in callback
        } else {
            if (pullIn) {
                if (tokenAllowance(tokenIn, msg.sender, address(this)) < amountIn) {
                    revert InsufficientAllowance(tokenIn, msg.sender, amountIn);
                }
                safeTransferFrom(tokenIn, msg.sender, address(this), amountIn);
            }
        }

        // pre-quote expected amount out if slippage protection is requested
        uint256 amountOutExpected = 0;
        uint256 minAmountOut = 0;
        if (slippageBps > 0) {
            // call quoteV3 to estimate
            amountOutExpected = quoteV3View(tokenIn, tokenOut, _fee, _amountIn, sqrtPriceLimitX96);
            minAmountOut = (amountOutExpected * (10000 - slippageBps)) / 10000;
        }

        // sanity cast
        if (_amountIn > uint256(type(int256).max)) revert AmountTooLargeForInt256();

        // perform swap on poolUsed
        (int256 amount0, int256 amount1) = IUniswapV3Pool(poolUsed).swap(
            address(this),
            zeroForOne,
            int256(_amountIn),
            sqrtPriceLimitX96,
            abi.encode(_tokenIn, _tokenOut, _fee)
        );

        int256 _amountOutSigned = zeroForOne ? -amount1 : -amount0;
        amountOut = uint256(_amountOutSigned);

        // If slippage protection requested, if we didn't precompute expected, compute now from quote
        if (slippageBps > 0 && amountOutExpected == 0) {
            amountOutExpected = quoteV3View(tokenIn, tokenOut, _fee, _amountIn, sqrtPriceLimitX96);
            minAmountOut = (amountOutExpected * (10000 - slippageBps)) / 10000;
        }

        emit SwapDebugV3(poolUsed, tokenIn, tokenOut, _fee, _amountIn, amountOutExpected, minAmountOut, IUniswapV3Pool(poolUsed).liquidity());

        if (slippageBps > 0 && amountOut < minAmountOut) revert SlippageExceeded(amountOut, minAmountOut);

        if (pushOut) {
            if (_tokenOut == wrappedEther) {
                IWETH(wrappedEther).withdraw(amountOut);
                executeCall(msg.sender, amountOut, new bytes(0));
            } else {
                safeTransfer(_tokenOut, msg.sender, amountOut);
            }
        }
    }


    function quoteV3(
        address tokenIn,
        address tokenOut,
        uint24 fee,
        uint256 amountIn,
        uint160 sqrtPriceLimitX96
    ) external view returns (uint256 amountOut) {
        return quoteV3View(tokenIn, tokenOut, fee, amountIn, sqrtPriceLimitX96);
    }

     // quoteV3 that calls the external quoter (non-view wrapper for staticCall)
    // Exposed version uses parsePool to resolve fee/sqrt defaults and staticcall to quoter
    function quoteV3View(address tokenIn, address tokenOut, uint24 fee, uint256 amountIn, uint160 sqrtPriceLimitX96) internal view returns (uint256 amountOut) {
        (, uint24 resolvedFee, uint160 resolvedSqrtLimit, ) = parsePool(tokenIn, tokenOut, fee);
        uint24 feeToUse = fee == 0 ? resolvedFee : fee;
        uint160 sqrtToUse = sqrtPriceLimitX96 == 0 ? resolvedSqrtLimit : sqrtPriceLimitX96;

        // build payload to quoter; confirm selector / ABI matches your deployed quoter
        bytes memory payload = abi.encodeWithSelector(
            0xc6a5026a,
            QuoteParams(tokenIn, tokenOut, amountIn, feeToUse, sqrtToUse)
        );

        (bool ok, bytes memory r) = staticCall(deployment.uniswapV3Quoter, payload);
        if (!ok) revert QuoteCallFailed();
        (amountOut,,,) = abi.decode(r, (uint256, uint160, uint32, uint256));
    }

     // parsePool resolves pool, fee and sqrtPriceLimit; if fee==0 autodetects pool with liquidity check
    function parsePool(address tokenIn, address tokenOut, uint24 fee) internal view returns (address pool, uint24 _fee, uint160 sqrtPriceLimitX96, bool zeroForOne) {
        if (fee == 0) {
            (pool, _fee) = findBestFeePool(tokenIn, tokenOut);
        } else {
            (pool, _fee) = (IUniswapV3Factory(factory).getPool(tokenIn, tokenOut, fee), fee);
        }
        if (pool == address(0)) revert NoPoolFound();
        zeroForOne = tokenIn == IUniswapV3Pool(pool).token0();
        sqrtPriceLimitX96 = computeSqrtPriceLimit(pool, zeroForOne);
    }

    // compute small sqrtPriceLimit buffer around current price
    function computeSqrtPriceLimit(address pool, bool zeroForOne) internal view returns (uint160) {
        (uint160 currentSqrtPriceX96,,,,,,) = IUniswapV3Pool(pool).slot0();
        uint160 buffer = currentSqrtPriceX96 / 10000; // ~0.01%
        if (zeroForOne) {
            uint160 limit = currentSqrtPriceX96 - buffer;
            return limit > MIN_SQRT_RATIO ? limit : MIN_SQRT_RATIO;
        } else {
            uint160 limit = currentSqrtPriceX96 + buffer;
            return limit < MAX_SQRT_RATIO ? limit : MAX_SQRT_RATIO;
        }
    }

    // findBestFeePool returns the first pool (lowest fee) with sufficient liquidity
    function findBestFeePool(address token0, address token1) internal view returns (address bestPool, uint24 _fee) {
        for (uint8 i = 0; i < fees.length; i++) {
            address pool = IUniswapV3Factory(factory).getPool(token0, token1, fees[i]);
            if (pool == address(0)) continue;
            // check pool liquidity and slot0 sanity
            uint128 liq = IUniswapV3Pool(pool).liquidity();
            (uint160 sqrtPriceX96,,,,,,) = IUniswapV3Pool(pool).slot0();
            if (liq >= MIN_V3_LIQUIDITY && sqrtPriceX96 != 0) {
                bestPool = pool;
                _fee = fees[i];
                break;
            }
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


   

    function _uniswapV3SwapCallback(int256 amount0Delta, int256 amount1Delta, bytes calldata data) internal {
        (address tokenInEncoded, address tokenOutEncoded, uint24 feeEncoded) = abi.decode(data, (address, address, uint24));
        address pool = IUniswapV3Factory(factory).getPool(tokenInEncoded, tokenOutEncoded, feeEncoded);
        require(msg.sender == pool, InvalidCallback(msg.sender, pool));
        if (amount0Delta > 0) {
            safeTransfer(IUniswapV3Pool(msg.sender).token0(), pool, uint256(amount0Delta));
        } else if (amount1Delta > 0) {
            safeTransfer(IUniswapV3Pool(msg.sender).token1(), pool, uint256(amount1Delta));
        } else {
            revert InvalidCallback(msg.sender, pool);
        }
    }
}






