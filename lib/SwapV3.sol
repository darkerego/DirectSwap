// SPDX-License-Identifier: MIT
pragma solidity ^0.8.30;
import {DeploymentAddresses} from "lib/DeploymentAddresses.sol";
import {TransferHelper} from "lib/TransferHelper.sol";
import {IWETH, IUniswapV3Factory, IUniswapV3Pool} from "lib/Interfaces.sol";


contract UniswapV3DirectSwapper is DeploymentAddresses, TransferHelper {
    address private immutable factory;
    address private immutable weth;
    uint160 private constant MIN_SQRT_RATIO = 4295128739 + 1;
    uint160 private constant MAX_SQRT_RATIO = 1461446703485210103287273052203988822378723970341 - 1;
    uint24[4] private fees = [100, 500, 3000, 10000];
    error InvalidCallback(address _caller, address _pool);
    error NoPoolFound();
    error AmountMismatch(uint256 msgValue, uint256 amountIn);
    error QuoteCallFailed();
    event Callback(address indexed caller);

    struct QuoteParams {
        address tokenIn;
        address tokenOut;
        uint256 amountIn;
        uint24 fee;
        uint160 sqrtPriceLimitX96;
    }

    constructor() {
        (factory, weth) = (deployment.uniswapV3Factory, deployment.wrappedEther);
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
        address tokenIn, // @dev sell
        address tokenOut, //@dev buy
        uint256 amountIn, //@dev sell amount
        uint24 fee, // @dev leave 0 to autodetect
        bool pullIn, // @dev input token is weth, wrap native ether, otherwise, call transferFrom(msg.sender, address(this), amountIn
        bool pushOut // @dev output token is weth, unwrap and send native eth sender, otherwise call tranfer(msg.sender, amountOut)
    ) internal returns (address poolUsed, uint256 amountOut) {

         (address _tokenIn, address _tokenOut, uint256 _amountIn, uint24 _fee,
         uint160 sqrtPriceLimitX96, bool zeroForOne) = (tokenIn, tokenOut, amountIn, fee, 0, false);


        //bool zeroForOne = tokenIn == IUniswapV3Pool(poolUsed).token0();
        (poolUsed , _fee, sqrtPriceLimitX96, zeroForOne ) = parsePool(tokenIn, tokenOut, fee);
        if (msg.value > 0 && tokenIn == weth) {
            require(amountIn == msg.value, AmountMismatch(msg.value, amountIn));
            IWETH(weth).deposit{value: msg.value}();
        } else {
            if (pullIn) {
                require(tokenAllowance(tokenIn, msg.sender, address(this)) >= amountIn, InsufficientAllowance(tokenIn, msg.sender, amountIn));
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
            if (_tokenOut == weth) {
                IWETH(weth).withdraw(amountOut);
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
        (, uint24 _fee, uint160 _sqrtPriceLimitX96, ) = parsePool(tokenIn, tokenOut, fee);
        fee == 0 ? _fee : fee;
        sqrtPriceLimitX96 == 0 ? _sqrtPriceLimitX96 : _sqrtPriceLimitX96;
        (, bytes memory r) = staticCall(
            deployment.uniswapV3Quoter,
            abi.encodeWithSelector(
                0xc6a5026a,
                QuoteParams(tokenIn, tokenOut, amountIn, fee, sqrtPriceLimitX96)
            )
        );
        (amountOut,,,) = abi.decode(r, (uint256, uint160, uint32, uint256));
        }

    function parsePool(
        address tokenIn,
        address tokenOut,
        uint24 fee
        ) internal view returns(
            address pool,
            uint24 _fee,
            uint160 sqrtPriceLimitX96,
            bool zeroForOne
        ) {
        if (fee == 0) {
            (pool, _fee) = findBestFeePool(tokenIn, tokenOut);
        } else {
            (pool,_fee) = (IUniswapV3Factory(factory).getPool(tokenIn, tokenOut, fee), fee);
        }
        require(pool != address(0), NoPoolFound());
        zeroForOne = tokenIn == IUniswapV3Pool(pool).token0();
        sqrtPriceLimitX96 = computeSqrtPriceLimit(pool, zeroForOne);
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
    ) external virtual {
        _uniswapV3SwapCallback(amount0Delta, amount1Delta, data);
    }

    function _uniswapV3SwapCallback(
        int256 amount0Delta,
        int256 amount1Delta,
        bytes calldata data
    ) internal {
        (address token0, address token1, uint24 fee) = abi.decode(data, (address, address, uint24));
        address pool = IUniswapV3Factory(factory).getPool(token0, token1, fee);
        require(msg.sender == pool, InvalidCallback(msg.sender, pool));
         if (amount0Delta > 0) {
            safeTransfer(IUniswapV3Pool(msg.sender).token0(), pool, uint256(amount0Delta));
        } else if (amount1Delta > 0) {
            safeTransfer(IUniswapV3Pool(msg.sender).token1(), pool, uint256(amount1Delta));
            }
          else {
            revert InvalidCallback(msg.sender, pool);
          }


        }}






