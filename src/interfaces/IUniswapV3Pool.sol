// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

/// @title  IUniswapV3Pool
/// @author KPK
/// @notice Minimal interface for a Uniswap v3 pool.
/// @dev    Only the functions used by UniswapV3PositionVault are included. The upstream interface is
///         split across several inherited files; the members below are copied verbatim from
///         IUniswapV3PoolState, IUniswapV3PoolImmutables, IUniswapV3PoolDerivedState and
///         IUniswapV3PoolActions so their ABI encoding matches exactly.
interface IUniswapV3Pool {
    /// @notice The first of the two pool tokens, sorted by address.
    /// @return The token0 address.
    function token0() external view returns (address);

    /// @notice The second of the two pool tokens, sorted by address.
    /// @return The token1 address.
    function token1() external view returns (address);

    /// @notice The pool fee in hundredths of a basis point (e.g. 3000 for 0.3%).
    /// @dev    Charged on the swap input amount, which is why swap sizing must apply it before
    ///         projecting the post-swap price.
    /// @return The fee, in units of 1e-6.
    function fee() external view returns (uint24);

    /// @notice The spacing between usable ticks for this fee tier.
    /// @dev    Position boundaries must be integer multiples of this value.
    /// @return The tick spacing.
    function tickSpacing() external view returns (int24);

    /// @notice The pool's currently active in-range liquidity.
    /// @dev    Constant only while the price stays inside the current initialized-tick interval;
    ///         a swap that crosses an initialized tick changes it.
    /// @return The in-range liquidity.
    function liquidity() external view returns (uint128);

    /// @notice The pool's first storage slot, holding the price and oracle bookkeeping.
    /// @return sqrtPriceX96                 Current price as a Q64.96 sqrt ratio of token1 to token0.
    /// @return tick                         Current tick, i.e. log base 1.0001 of the price.
    /// @return observationIndex             Index of the most recently written oracle observation.
    /// @return observationCardinality       Number of observations currently populated.
    /// @return observationCardinalityNext   Number of observations the pool is growing towards.
    /// @return feeProtocol                  Protocol fee shares for both tokens, packed.
    /// @return unlocked                     False while the pool is mid-callback.
    function slot0()
        external
        view
        returns (
            uint160 sqrtPriceX96,
            int24 tick,
            uint16 observationIndex,
            uint16 observationCardinality,
            uint16 observationCardinalityNext,
            uint8 feeProtocol,
            bool unlocked
        );

    /// @notice Returns cumulative tick and liquidity values as of each given seconds-ago value.
    /// @dev    Reverts with "OLD" when the requested age exceeds the pool's stored observation
    ///         history, which is how a pool with insufficient observation cardinality is detected.
    /// @param secondsAgos           Ages, in seconds, at which to read the cumulatives.
    /// @return tickCumulatives      Cumulative tick values as of each age.
    /// @return secondsPerLiquidityCumulativeX128s Cumulative seconds per in-range liquidity as of each age.
    function observe(uint32[] calldata secondsAgos)
        external
        view
        returns (int56[] memory tickCumulatives, uint160[] memory secondsPerLiquidityCumulativeX128s);

    /// @notice Swap token0 for token1, or token1 for token0.
    /// @dev    The caller receives the output optimistically and must pay the input inside
    ///         uniswapV3SwapCallback before the call returns.
    /// @param recipient        Address that receives the output token.
    /// @param zeroForOne       True to sell token0 for token1, false for the opposite direction.
    /// @param amountSpecified  Positive for an exact-input swap, negative for exact-output.
    /// @param sqrtPriceLimitX96 Price limit; the swap stops here even if the amount is not filled.
    /// @param data             Payload forwarded verbatim to uniswapV3SwapCallback.
    /// @return amount0         Change in the pool's token0 balance; positive means the caller owes it.
    /// @return amount1         Change in the pool's token1 balance; positive means the caller owes it.
    function swap(
        address recipient,
        bool zeroForOne,
        int256 amountSpecified,
        uint160 sqrtPriceLimitX96,
        bytes calldata data
    ) external returns (int256 amount0, int256 amount1);
}
