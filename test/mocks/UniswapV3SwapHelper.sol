// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";

import {IUniswapV3Pool} from "../../src/interfaces/IUniswapV3Pool.sol";
import {IUniswapV3SwapCallback} from "../../src/interfaces/IUniswapV3SwapCallback.sol";
import {TickMath} from "../../src/libraries/uniswap/TickMath.sol";

/// @title  UniswapV3SwapHelper
/// @author KPK
/// @notice Test-only contract that swaps against a pool so a suite can move the price or accrue
///         fees for a position. Holds its own token balances, which tests fund with `deal`.
contract UniswapV3SwapHelper is IUniswapV3SwapCallback {
    using SafeERC20 for IERC20;

    /// @dev The pool the in-flight swap belongs to.
    address private _pool;

    /// @notice Swaps an exact input amount, taking whatever price the pool offers.
    /// @param pool            The pool to swap against.
    /// @param zeroForOne      True to sell token0.
    /// @param amountSpecified Exact input when positive, exact output when negative.
    /// @return amount0 The pool's token0 delta.
    /// @return amount1 The pool's token1 delta.
    function swap(address pool, bool zeroForOne, int256 amountSpecified)
        external
        returns (int256 amount0, int256 amount1)
    {
        uint160 limit = zeroForOne ? TickMath.MIN_SQRT_RATIO + 1 : TickMath.MAX_SQRT_RATIO - 1;
        return _swap(pool, zeroForOne, amountSpecified, limit);
    }

    /// @notice Swaps until the pool reaches a target price, or the input runs out.
    /// @param pool       The pool to swap against.
    /// @param zeroForOne True to sell token0, which moves the price down.
    /// @param sqrtTarget The price to stop at.
    /// @return amount0 The pool's token0 delta.
    /// @return amount1 The pool's token1 delta.
    function swapToPrice(address pool, bool zeroForOne, uint160 sqrtTarget)
        external
        returns (int256 amount0, int256 amount1)
    {
        return _swap(pool, zeroForOne, type(int128).max, sqrtTarget);
    }

    /// @inheritdoc IUniswapV3SwapCallback
    function uniswapV3SwapCallback(int256 amount0Delta, int256 amount1Delta, bytes calldata) external override {
        require(msg.sender == _pool, "unexpected callback");
        if (amount0Delta > 0) {
            IERC20(IUniswapV3Pool(msg.sender).token0()).safeTransfer(msg.sender, uint256(amount0Delta));
        }
        if (amount1Delta > 0) {
            IERC20(IUniswapV3Pool(msg.sender).token1()).safeTransfer(msg.sender, uint256(amount1Delta));
        }
    }

    function _swap(address pool, bool zeroForOne, int256 amountSpecified, uint160 limit)
        private
        returns (int256 amount0, int256 amount1)
    {
        _pool = pool;
        (amount0, amount1) = IUniswapV3Pool(pool).swap(address(this), zeroForOne, amountSpecified, limit, "");
        _pool = address(0);
    }
}
