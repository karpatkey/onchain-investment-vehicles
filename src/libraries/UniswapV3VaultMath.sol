// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";

import {IUniswapV3PositionVault} from "../IUniswapV3PositionVault.sol";
import {FullMath} from "./uniswap/FullMath.sol";
import {LiquidityAmounts} from "./uniswap/LiquidityAmounts.sol";
import {SqrtPriceMath} from "./uniswap/SqrtPriceMath.sol";
import {TickMath} from "./uniswap/TickMath.sol";

/// @title  UniswapV3VaultMath
/// @author KPK
/// @notice Pure math backing UniswapV3PositionVault: price conversion, tick snapping, position
///         amounts and the swap sizing used when a position is rebalanced into a new range.
/// @dev    Every quantity that touches Uniswap is computed with Uniswap's own libraries, vendored
///         under ./uniswap. This file only composes them; it never reimplements their arithmetic.
///         All functions are pure, which keeps them cheap to test in isolation.
library UniswapV3VaultMath {
    /// @dev Swap fees are expressed in hundredths of a basis point.
    uint256 internal constant FEE_DENOMINATOR = 1e6;

    /// @dev Basis-point denominator for the TWAP deviation cap.
    uint256 internal constant BPS_DENOMINATOR = 10_000;

    /// @dev Upper bound on bisection steps when sizing a swap. The search halves a sqrt-price
    ///      interval, so 128 steps resolve any interval Uniswap can represent far past wei
    ///      precision while keeping the worst-case gas of a rebalance bounded.
    uint256 internal constant MAX_SWAP_SEARCH_STEPS = 128;

    /// @dev Worst-case wei a deposit's two rounded-up components can add over the linear cost.
    uint256 internal constant ROUNDING_HEADROOM = 2;

    //
    // Price conversion
    //

    /// @notice Converts a human price into Uniswap's Q64.96 sqrt ratio.
    /// @dev    The human price is token1 per token0, decimal-adjusted and scaled by 1e18, so a pool
    ///         of USDC (6 decimals, token0) and WETH (18 decimals, token1) quoting 0.00033 WETH per
    ///         USDC is passed as 33e13. The raw ratio Uniswap stores is
    ///         `price * 10**decimals1 / (1e18 * 10**decimals0)`, and the result is the square root
    ///         of that ratio shifted left by 96 bits.
    ///
    ///         Two regimes are needed because `raw * 2**192` only fits in a uint256 while
    ///         `raw <= 2**64`, yet Uniswap supports raw ratios up to 2**128, which real pairs of
    ///         very differently priced tokens do reach. Below the threshold the shift is applied
    ///         before the square root, which is exact to the last bit. Above it the shift is split,
    ///         costing at most 64 low bits of a result that is itself larger than 2**128, so the
    ///         relative error stays under 2**-64.
    /// @param price    The human price, 1e18-scaled.
    /// @param scaleNum `10**decimals1`, cached by the vault at initialization.
    /// @param scaleDen `1e18 * 10**decimals0`, cached by the vault at initialization.
    /// @return sqrtPriceX96 The equivalent Q64.96 sqrt ratio.
    function priceToSqrtPriceX96(uint256 price, uint256 scaleNum, uint256 scaleDen)
        public
        pure
        returns (uint160 sqrtPriceX96)
    {
        if (price == 0) revert IUniswapV3PositionVault.PriceOutOfRange();

        // raw > 2**64 exactly when price > scaleDen * 2**64 / scaleNum. scaleDen is at most 1e36 and
        // the shift adds 64 bits, so the threshold itself never overflows.
        uint256 threshold = FullMath.mulDiv(scaleDen, 1 << 64, scaleNum);

        uint256 result;
        if (price < threshold) {
            // raw < 2**64, so raw * 2**192 < 2**256 and the square root is exact.
            result = Math.sqrt(FullMath.mulDiv(price, scaleNum << 192, scaleDen));
        } else {
            // raw >= 2**64. Square root of raw * 2**64 gives sqrt(raw) * 2**32; shifting by 64 more
            // bits completes the Q64.96 scaling.
            result = Math.sqrt(FullMath.mulDiv(price, scaleNum << 64, scaleDen)) << 64;
        }

        if (result < TickMath.MIN_SQRT_RATIO || result >= TickMath.MAX_SQRT_RATIO) {
            revert IUniswapV3PositionVault.PriceOutOfRange();
        }
        sqrtPriceX96 = uint160(result);
    }

    /// @notice Converts a Q64.96 sqrt ratio back into a human price.
    /// @dev    The inverse of priceToSqrtPriceX96, provided so off-chain tooling and tests can read
    ///         the vault's current range in the same units they use to set it. Rounds down.
    /// @param sqrtPriceX96 The Q64.96 sqrt ratio.
    /// @param scaleNum     `10**decimals1`.
    /// @param scaleDen     `1e18 * 10**decimals0`.
    /// @return price The human price, 1e18-scaled.
    function sqrtPriceX96ToPrice(uint160 sqrtPriceX96, uint256 scaleNum, uint256 scaleDen)
        public
        pure
        returns (uint256 price)
    {
        // raw * 2**96, at most 2**224 because raw is at most 2**128.
        uint256 ratioX96 = FullMath.mulDiv(sqrtPriceX96, sqrtPriceX96, 1 << 96);
        price = FullMath.mulDiv(ratioX96, scaleDen, scaleNum << 96);
    }

    //
    // Tick snapping
    //

    /// @notice Rounds a tick down to the nearest multiple of the spacing.
    /// @dev    Solidity truncates division toward zero, so negative ticks need an explicit
    ///         correction to round toward negative infinity.
    /// @param tick    The tick to round.
    /// @param spacing The pool's tick spacing.
    /// @return The largest multiple of spacing that is at most `tick`.
    function floorToSpacing(int24 tick, int24 spacing) internal pure returns (int24) {
        int24 quotient = tick / spacing;
        if (tick < 0 && quotient * spacing != tick) quotient--;
        return quotient * spacing;
    }

    /// @notice Rounds a tick up to the nearest multiple of the spacing.
    /// @param tick    The tick to round.
    /// @param spacing The pool's tick spacing.
    /// @return The smallest multiple of spacing that is at least `tick`.
    function ceilToSpacing(int24 tick, int24 spacing) internal pure returns (int24) {
        int24 quotient = tick / spacing;
        if (tick > 0 && quotient * spacing != tick) quotient++;
        return quotient * spacing;
    }

    /// @notice The Q64.96 sqrt ratio at a tick.
    /// @dev    A thin pass-through to TickMath so callers reach it through this library rather than
    ///         inlining TickMath's own large lookup, which keeps the calling contract small.
    /// @param tick The tick to convert.
    /// @return The sqrt ratio at that tick.
    function sqrtRatioAtTick(int24 tick) internal pure returns (uint160) {
        return TickMath.getSqrtRatioAtTick(tick);
    }

    /// @notice The tick at a Q64.96 sqrt ratio, rounded down.
    /// @param sqrtPriceX96 The sqrt ratio to convert.
    /// @return The greatest tick whose sqrt ratio is at most the input.
    function tickAtSqrtRatio(uint160 sqrtPriceX96) internal pure returns (int24) {
        return TickMath.getTickAtSqrtRatio(sqrtPriceX96);
    }

    /// @notice Converts a human price range into a pair of usable tick boundaries.
    /// @dev    The lower bound rounds down and the upper bound rounds up, so the minted position
    ///         always covers at least the range the curator asked for rather than a subset of it.
    ///         TickMath.getTickAtSqrtRatio floors, so the upper bound is nudged up by one tick when
    ///         the requested sqrt ratio falls strictly between two ticks. Both results are clamped
    ///         to the ticks the pool can actually use.
    /// @param priceLower The lower human price, 1e18-scaled.
    /// @param priceUpper The upper human price, 1e18-scaled.
    /// @param spacing    The pool's tick spacing.
    /// @param scaleNum   `10**decimals1`.
    /// @param scaleDen   `1e18 * 10**decimals0`.
    /// @return tickLower The snapped lower tick.
    /// @return tickUpper The snapped upper tick.
    function priceRangeToTicks(
        uint256 priceLower,
        uint256 priceUpper,
        int24 spacing,
        uint256 scaleNum,
        uint256 scaleDen
    ) public pure returns (int24 tickLower, int24 tickUpper) {
        if (priceLower >= priceUpper) revert IUniswapV3PositionVault.InvalidPriceRange();

        uint160 sqrtLower = priceToSqrtPriceX96(priceLower, scaleNum, scaleDen);
        uint160 sqrtUpper = priceToSqrtPriceX96(priceUpper, scaleNum, scaleDen);

        tickLower = floorToSpacing(TickMath.getTickAtSqrtRatio(sqrtLower), spacing);

        int24 rawUpper = TickMath.getTickAtSqrtRatio(sqrtUpper);
        if (TickMath.getSqrtRatioAtTick(rawUpper) < sqrtUpper) rawUpper++;
        tickUpper = ceilToSpacing(rawUpper, spacing);

        int24 minUsable = ceilToSpacing(TickMath.MIN_TICK, spacing);
        int24 maxUsable = floorToSpacing(TickMath.MAX_TICK, spacing);
        if (tickLower < minUsable) tickLower = minUsable;
        if (tickUpper > maxUsable) tickUpper = maxUsable;

        if (tickLower >= tickUpper) revert IUniswapV3PositionVault.InvalidPriceRange();
    }

    //
    // Position amounts
    //

    /// @notice Token amounts a position of the given liquidity occupies at the current price.
    /// @dev    Delegates to SqrtPriceMath so the rounding matches what the pool itself applies.
    ///         Callers fund a position with `roundUp = true`, because the pool takes the ceiling of
    ///         what a liquidity amount costs, and value a position with `roundUp = false`, because
    ///         the pool returns the floor of what it holds.
    /// @param sqrtPriceX96 The current pool price.
    /// @param sqrtRatioAX96 The range's lower sqrt ratio.
    /// @param sqrtRatioBX96 The range's upper sqrt ratio.
    /// @param liquidity     The liquidity to price.
    /// @param roundUp       Whether to round each amount up.
    /// @return amount0 Token0 the liquidity corresponds to.
    /// @return amount1 Token1 the liquidity corresponds to.
    function amountsForLiquidity(
        uint160 sqrtPriceX96,
        uint160 sqrtRatioAX96,
        uint160 sqrtRatioBX96,
        uint128 liquidity,
        bool roundUp
    ) internal pure returns (uint256 amount0, uint256 amount1) {
        if (liquidity == 0) return (0, 0);

        if (sqrtPriceX96 <= sqrtRatioAX96) {
            amount0 = SqrtPriceMath.getAmount0Delta(sqrtRatioAX96, sqrtRatioBX96, liquidity, roundUp);
        } else if (sqrtPriceX96 < sqrtRatioBX96) {
            amount0 = SqrtPriceMath.getAmount0Delta(sqrtPriceX96, sqrtRatioBX96, liquidity, roundUp);
            amount1 = SqrtPriceMath.getAmount1Delta(sqrtRatioAX96, sqrtPriceX96, liquidity, roundUp);
        } else {
            amount1 = SqrtPriceMath.getAmount1Delta(sqrtRatioAX96, sqrtRatioBX96, liquidity, roundUp);
        }
    }

    /// @notice Liquidity each token balance can independently support in a range at a given price.
    /// @dev    Outside the range one side is dead weight and reports zero: a range entirely above
    ///         the price is funded by token0 alone, and one entirely below it by token1 alone. The
    ///         strict inequalities keep both LiquidityAmounts calls away from a zero denominator.
    /// @param sqrtPriceX96  The price to evaluate at.
    /// @param sqrtRatioAX96 The range's lower sqrt ratio.
    /// @param sqrtRatioBX96 The range's upper sqrt ratio.
    /// @param amount0       Token0 available.
    /// @param amount1       Token1 available.
    /// @return cap0 Liquidity that token0 alone could fund.
    /// @return cap1 Liquidity that token1 alone could fund.
    function liquidityCaps(
        uint160 sqrtPriceX96,
        uint160 sqrtRatioAX96,
        uint160 sqrtRatioBX96,
        uint256 amount0,
        uint256 amount1
    ) internal pure returns (uint128 cap0, uint128 cap1) {
        if (sqrtPriceX96 <= sqrtRatioAX96) {
            cap0 = LiquidityAmounts.getLiquidityForAmount0(sqrtRatioAX96, sqrtRatioBX96, amount0);
        } else if (sqrtPriceX96 >= sqrtRatioBX96) {
            cap1 = LiquidityAmounts.getLiquidityForAmount1(sqrtRatioAX96, sqrtRatioBX96, amount1);
        } else {
            cap0 = LiquidityAmounts.getLiquidityForAmount0(sqrtPriceX96, sqrtRatioBX96, amount0);
            cap1 = LiquidityAmounts.getLiquidityForAmount1(sqrtRatioAX96, sqrtPriceX96, amount1);
        }
    }

    /// @notice Liquidity that a pair of balances can actually mint into a range at a given price.
    /// @param sqrtPriceX96  The price to evaluate at.
    /// @param sqrtRatioAX96 The range's lower sqrt ratio.
    /// @param sqrtRatioBX96 The range's upper sqrt ratio.
    /// @param amount0       Token0 available.
    /// @param amount1       Token1 available.
    /// @return The mintable liquidity.
    function mintableLiquidity(
        uint160 sqrtPriceX96,
        uint160 sqrtRatioAX96,
        uint160 sqrtRatioBX96,
        uint256 amount0,
        uint256 amount1
    ) public pure returns (uint128) {
        (uint128 cap0, uint128 cap1) = liquidityCaps(sqrtPriceX96, sqrtRatioAX96, sqrtRatioBX96, amount0, amount1);
        if (sqrtPriceX96 <= sqrtRatioAX96) return cap0;
        if (sqrtPriceX96 >= sqrtRatioBX96) return cap1;
        return cap0 < cap1 ? cap0 : cap1;
    }

    /// @notice Liquidity that a single token amount funds in a range at the current price.
    /// @dev    Lets the curator open a position by naming one side and letting the vault derive the
    ///         other. A range wholly above the price is funded by token0 alone and one wholly below
    ///         it by token1 alone, so naming the unusable side is rejected rather than silently
    ///         producing an empty position.
    /// @param sqrtPriceX96  The current pool price.
    /// @param sqrtRatioAX96 The range's lower sqrt ratio.
    /// @param sqrtRatioBX96 The range's upper sqrt ratio.
    /// @param amount        The amount of the named token.
    /// @param isAmount0     True when the amount is token0, false when it is token1.
    /// @return The liquidity that amount funds.
    function liquidityFromSingleAmount(
        uint160 sqrtPriceX96,
        uint160 sqrtRatioAX96,
        uint160 sqrtRatioBX96,
        uint256 amount,
        bool isAmount0
    ) internal pure returns (uint128) {
        if (sqrtPriceX96 <= sqrtRatioAX96) {
            if (!isAmount0) revert IUniswapV3PositionVault.AmountSideNotUsable();
            return LiquidityAmounts.getLiquidityForAmount0(sqrtRatioAX96, sqrtRatioBX96, amount);
        }
        if (sqrtPriceX96 >= sqrtRatioBX96) {
            if (isAmount0) revert IUniswapV3PositionVault.AmountSideNotUsable();
            return LiquidityAmounts.getLiquidityForAmount1(sqrtRatioAX96, sqrtRatioBX96, amount);
        }
        return isAmount0
            ? LiquidityAmounts.getLiquidityForAmount0(sqrtPriceX96, sqrtRatioBX96, amount)
            : LiquidityAmounts.getLiquidityForAmount1(sqrtRatioAX96, sqrtPriceX96, amount);
    }

    //
    // Share accounting
    //

    /// @notice The share count a given amount of one token buys.
    /// @dev    A share is a claim on everything the vault owns, so its cost is linear and one side
    ///         is enough to price it. The other side follows from the position's ratio, which is
    ///         what lets a depositor name a single amount the way a curator does when opening one.
    /// @param amount The amount of the named token.
    /// @param total  Everything the vault owns of that token, position and idle together.
    /// @param supply The current share supply.
    /// @return The share count that amount buys, rounded down.
    function sharesForSide(uint256 amount, uint256 total, uint256 supply) public pure returns (uint256) {
        if (total == 0) revert IUniswapV3PositionVault.AmountSideNotUsable();
        return FullMath.mulDiv(amount, supply, total);
    }

    /// @notice What the unnamed side of a deposit would cost at a reference price.
    /// @dev    The counter amount a deposit actually charges is set by the pool's spot price, which
    ///         anyone can move. Pricing the same deposit at the pool's time-weighted average gives a
    ///         figure nobody can move cheaply, which is what a caller's slippage allowance is
    ///         measured against.
    ///
    ///         It prices the whole claim, position and idle together, exactly as the real charge
    ///         does, so the two are comparable even when a rebalance has left a large one-sided
    ///         surplus sitting in the vault.
    /// @param sqrtPriceX96  The reference price, in practice the average rather than the spot.
    /// @param sqrtRatioAX96 The position's lower sqrt ratio.
    /// @param sqrtRatioBX96 The position's upper sqrt ratio.
    /// @param liquidity     The position's current liquidity.
    /// @param idle0         Token0 sitting idle in the vault.
    /// @param idle1         Token1 sitting idle in the vault.
    /// @param amount        The amount of the named token.
    /// @param isAmount0     True when that amount is token0.
    /// @return The amount of the other token the deposit would cost at that price.
    function referenceCounter(
        uint160 sqrtPriceX96,
        uint160 sqrtRatioAX96,
        uint160 sqrtRatioBX96,
        uint128 liquidity,
        uint256 idle0,
        uint256 idle1,
        uint256 amount,
        bool isAmount0
    ) public pure returns (uint256) {
        (uint256 total0, uint256 total1) =
            amountsForLiquidity(sqrtPriceX96, sqrtRatioAX96, sqrtRatioBX96, liquidity, false);
        total0 += idle0;
        total1 += idle1;

        uint256 named = isAmount0 ? total0 : total1;
        if (named == 0) revert IUniswapV3PositionVault.AmountSideNotUsable();

        return FullMath.mulDiv(amount, isAmount0 ? total1 : total0, named);
    }

    /// @notice What a deposit of the given share count costs and how much liquidity it buys.
    /// @dev    Splits the cost into the part that funds new liquidity and the part that buys into
    ///         the idle balances. The liquidity part rounds up because that is what the pool charges
    ///         for it, and the idle part rounds up so a deposit can never dilute the idle claim of
    ///         existing holders.
    /// @param sqrtPriceX96  The current pool price.
    /// @param sqrtRatioAX96 The position's lower sqrt ratio.
    /// @param sqrtRatioBX96 The position's upper sqrt ratio.
    /// @param liquidity     The position's current liquidity.
    /// @param idle0         Token0 sitting idle in the vault.
    /// @param idle1         Token1 sitting idle in the vault.
    /// @param supply        The current share supply.
    /// @param shares        The share count being bought.
    /// @return targetLiquidity Liquidity the deposit should add.
    /// @return charge0 Token0 that funds the new liquidity.
    /// @return charge1 Token1 that funds the new liquidity.
    /// @return pulled0 Total token0 to take from the depositor.
    /// @return pulled1 Total token1 to take from the depositor.
    function depositCost(
        uint160 sqrtPriceX96,
        uint160 sqrtRatioAX96,
        uint160 sqrtRatioBX96,
        uint128 liquidity,
        uint256 idle0,
        uint256 idle1,
        uint256 supply,
        uint256 shares
    )
        internal
        pure
        returns (uint128 targetLiquidity, uint256 charge0, uint256 charge1, uint256 pulled0, uint256 pulled1)
    {
        uint256 scaled = FullMath.mulDiv(liquidity, shares, supply);
        if (scaled > type(uint128).max) revert IUniswapV3PositionVault.InvalidArguments();
        targetLiquidity = uint128(scaled);
        if (targetLiquidity == 0) revert IUniswapV3PositionVault.ZeroShares();

        (charge0, charge1) = amountsForLiquidity(sqrtPriceX96, sqrtRatioAX96, sqrtRatioBX96, targetLiquidity, true);
        pulled0 = charge0 + idleShare(idle0, shares, supply);
        pulled1 = charge1 + idleShare(idle1, shares, supply);
    }

    /// @notice A share count's claim on an idle balance, rounded up.
    /// @param idle   The idle balance.
    /// @param shares The share count.
    /// @param supply The current share supply.
    /// @return The claim.
    function idleShare(uint256 idle, uint256 shares, uint256 supply) internal pure returns (uint256) {
        if (idle == 0) return 0;
        return FullMath.mulDivRoundingUp(idle, shares, supply);
    }

    /// @notice A share count's claim on an idle balance, rounded down.
    /// @param idle   The idle balance.
    /// @param shares The share count.
    /// @param supply The current share supply.
    /// @return The claim.
    function idleShareDown(uint256 idle, uint256 shares, uint256 supply) internal pure returns (uint256) {
        if (idle == 0) return 0;
        return FullMath.mulDiv(idle, shares, supply);
    }

    /// @notice The share count that a liquidity increase is worth against an existing position.
    /// @param supply           The share supply before the increase.
    /// @param mintedLiquidity  Liquidity the position gained.
    /// @param liquidityBefore  Liquidity the position held beforehand.
    /// @return The share count, rounded down.
    function sharesForLiquidity(uint256 supply, uint128 mintedLiquidity, uint128 liquidityBefore)
        internal
        pure
        returns (uint256)
    {
        return FullMath.mulDiv(supply, mintedLiquidity, liquidityBefore);
    }

    /// @notice The liquidity a share count is entitled to withdraw from a position.
    /// @param liquidity The position's liquidity.
    /// @param shares    The share count being redeemed.
    /// @param supply    The current share supply.
    /// @return The liquidity to withdraw, rounded down.
    function liquidityForShares(uint128 liquidity, uint256 shares, uint256 supply) internal pure returns (uint128) {
        return uint128(FullMath.mulDiv(liquidity, shares, supply));
    }

    /// @notice The amount of the other token that a named amount must be paired with.
    /// @dev    Rounds the counter amount up, so supplying exactly it is always enough to mint the
    ///         liquidity the named amount implies.
    /// @param sqrtPriceX96  The current pool price.
    /// @param sqrtRatioAX96 The range's lower sqrt ratio.
    /// @param sqrtRatioBX96 The range's upper sqrt ratio.
    /// @param amount        Amount of the named token.
    /// @param isAmount0     True when the amount is token0.
    /// @return The counter amount.
    function counterAmount(
        uint160 sqrtPriceX96,
        uint160 sqrtRatioAX96,
        uint160 sqrtRatioBX96,
        uint256 amount,
        bool isAmount0
    ) public pure returns (uint256) {
        uint128 liquidity = liquidityFromSingleAmount(sqrtPriceX96, sqrtRatioAX96, sqrtRatioBX96, amount, isAmount0);
        (uint256 amount0, uint256 amount1) =
            amountsForLiquidity(sqrtPriceX96, sqrtRatioAX96, sqrtRatioBX96, liquidity, true);
        return isAmount0 ? amount1 : amount0;
    }

    //
    // Swap sizing
    //

    /// @notice Inputs describing the swap-sizing problem posed by a rebalance.
    /// @param sqrtPriceX96  The pool's current price.
    /// @param sqrtRatioAX96 The target range's lower sqrt ratio.
    /// @param sqrtRatioBX96 The target range's upper sqrt ratio.
    /// @param poolLiquidity The pool's in-range liquidity.
    /// @param feePips       The pool's fee, in hundredths of a basis point.
    /// @param amount0       Token0 the vault holds.
    /// @param amount1       Token1 the vault holds.
    struct SwapParams {
        uint160 sqrtPriceX96;
        uint160 sqrtRatioAX96;
        uint160 sqrtRatioBX96;
        uint128 poolLiquidity;
        uint24 feePips;
        uint256 amount0;
        uint256 amount1;
    }

    /// @notice Sizes the swap that leaves the vault able to mint the most liquidity in a range.
    /// @dev    The search runs over the post-swap price rather than over the input amount. Within
    ///         the current initialized-tick interval the pool's liquidity is constant, so the input
    ///         needed to reach any candidate price has a closed form, and the two liquidity caps
    ///         move strictly in opposite directions as that price slides across the range: the cap
    ///         funded by the token being sold falls while the cap funded by the token being bought
    ///         rises. Their crossing is the optimum, and a monotone predicate makes it a plain
    ///         bisection rather than a search for a maximum.
    ///
    ///         The search interval is clipped to the prices actually reachable with the balances at
    ///         hand and to the range's own boundaries, so an optimum that lies outside becomes the
    ///         corresponding endpoint: selling everything when the range sits wholly on one side of
    ///         the price, and selling nothing when the balances are already in ratio.
    ///
    ///         The result is exact while the swap stays inside the current tick interval, which is
    ///         the normal case. If the swap crosses an initialized tick the realised price differs
    ///         slightly from the modelled one, which is why the caller re-reads the pool after
    ///         swapping and mints against the balances it actually holds.
    /// @param params The swap-sizing inputs.
    /// @return zeroForOne True when token0 must be sold, false when token1 must be sold.
    /// @return amountIn   Amount of that token to pay into the pool, fee included. Zero means no swap.
    function solveSwap(SwapParams memory params) public pure returns (bool zeroForOne, uint256 amountIn) {
        uint160 sqrtP = params.sqrtPriceX96;
        uint160 sqrtA = params.sqrtRatioAX96;
        uint160 sqrtB = params.sqrtRatioBX96;

        // Decide which side is over-supplied for the target range.
        if (sqrtP <= sqrtA) {
            // The range sits above the price, so it is funded by token0 alone.
            if (params.amount1 == 0) return (false, 0);
            zeroForOne = false;
        } else if (sqrtP >= sqrtB) {
            // The range sits below the price, so it is funded by token1 alone.
            if (params.amount0 == 0) return (true, 0);
            zeroForOne = true;
        } else {
            (uint128 cap0, uint128 cap1) = liquidityCaps(sqrtP, sqrtA, sqrtB, params.amount0, params.amount1);
            if (cap0 == cap1) return (false, 0);
            zeroForOne = cap0 > cap1;
            if (zeroForOne && params.amount0 == 0) return (true, 0);
            if (!zeroForOne && params.amount1 == 0) return (false, 0);
        }

        if (params.poolLiquidity == 0) revert IUniswapV3PositionVault.PoolHasNoLiquidity();

        uint256 budget = zeroForOne ? params.amount0 : params.amount1;

        // Furthest price reachable by paying the whole budget into the pool.
        uint256 netBudget = FullMath.mulDiv(budget, FEE_DENOMINATOR - params.feePips, FEE_DENOMINATOR);
        if (netBudget == 0) return (zeroForOne, 0);
        uint160 sqrtLimit = SqrtPriceMath.getNextSqrtPriceFromInput(sqrtP, params.poolLiquidity, netBudget, zeroForOne);

        // Bracket the crossing. `lo` and `hi` are named for the predicate, not for price order:
        // `lo` always holds the endpoint where the sold token is still in surplus.
        uint160 lo;
        uint160 hi;
        bool degenerate;
        if (zeroForOne) {
            // Selling token0 pushes the price down. Surplus of token0 shrinks as the price falls.
            lo = sqrtP < sqrtB ? sqrtP : sqrtB - 1;
            hi = sqrtLimit > sqrtA ? sqrtLimit : sqrtA + 1;
            degenerate = hi >= lo;
        } else {
            // Selling token1 pushes the price up. Surplus of token1 shrinks as the price rises.
            lo = sqrtP > sqrtA ? sqrtP : sqrtA + 1;
            hi = sqrtLimit < sqrtB ? sqrtLimit : sqrtB - 1;
            degenerate = hi <= lo;
        }

        // No usable interior: the optimum is an endpoint, so take whichever of the two extremes
        // mints more, including not swapping at all. That comparison, and the one at the end of the
        // search, are made against this model, in which the pool's liquidity is the constant the
        // caller passed. A swap that crosses an initialized tick trades against a different
        // liquidity than was modelled and can therefore end up worse than not swapping, by at most
        // the pool fee on the amount traded within the caller's price-impact cap. The caller mints
        // from the balances it actually holds afterwards, so the shortfall stays idle rather than
        // being lost.
        if (degenerate) {
            uint128 mintNone = mintableLiquidity(sqrtP, sqrtA, sqrtB, params.amount0, params.amount1);
            uint128 mintAll = _mintableAfterSwap(params, sqrtLimit, zeroForOne, budget);
            return (zeroForOne, mintAll > mintNone ? budget : 0);
        }

        // If the sold token is still in surplus once the whole budget is spent, spend all of it.
        if (_soldSideInSurplus(params, hi, zeroForOne)) return (zeroForOne, budget);

        // Bisect between the surplus endpoint and the deficit endpoint.
        for (uint256 i; i < MAX_SWAP_SEARCH_STEPS; ++i) {
            uint160 mid = uint160((uint256(lo) + uint256(hi)) >> 1);
            if (mid == lo || mid == hi) break;
            if (_soldSideInSurplus(params, mid, zeroForOne)) {
                lo = mid;
            } else {
                hi = mid;
            }
        }

        // The crossing lies between the two endpoints, one tick of sqrt price apart. Take whichever
        // mints more, and fall back to not swapping if neither beats the untouched balances.
        uint256 inAtLo = _amountInForPrice(params, lo, zeroForOne);
        uint256 inAtHi = _amountInForPrice(params, hi, zeroForOne);
        if (inAtLo > budget) inAtLo = budget;
        if (inAtHi > budget) inAtHi = budget;

        uint128 mintAtLo = _mintableAfterSwap(params, lo, zeroForOne, inAtLo);
        uint128 mintAtHi = _mintableAfterSwap(params, hi, zeroForOne, inAtHi);

        uint128 best;
        (best, amountIn) = mintAtHi > mintAtLo ? (mintAtHi, inAtHi) : (mintAtLo, inAtLo);

        if (mintableLiquidity(sqrtP, sqrtA, sqrtB, params.amount0, params.amount1) >= best) amountIn = 0;
    }

    /// @notice Whether the token being sold would still be in surplus at a candidate price.
    /// @dev    The predicate the bisection halves on. It is monotone in the candidate price for a
    ///         fixed direction, because moving the price further in the direction of the swap both
    ///         spends more of the sold token and narrows the part of the range that token funds.
    /// @param params     The swap-sizing inputs.
    /// @param sqrtTarget The candidate post-swap price.
    /// @param zeroForOne The swap direction.
    /// @return True when the sold token could still fund more liquidity than the bought token.
    function _soldSideInSurplus(SwapParams memory params, uint160 sqrtTarget, bool zeroForOne)
        private
        pure
        returns (bool)
    {
        uint256 paid = _amountInForPrice(params, sqrtTarget, zeroForOne);
        uint256 budget = zeroForOne ? params.amount0 : params.amount1;
        if (paid > budget) paid = budget;

        (uint256 balance0, uint256 balance1) = _balancesAfterSwap(params, sqrtTarget, zeroForOne, paid);
        (uint128 cap0, uint128 cap1) =
            liquidityCaps(sqrtTarget, params.sqrtRatioAX96, params.sqrtRatioBX96, balance0, balance1);

        return zeroForOne ? cap0 >= cap1 : cap1 >= cap0;
    }

    /// @notice Liquidity the vault could mint after a swap that lands on the candidate price.
    /// @param params     The swap-sizing inputs.
    /// @param sqrtTarget The candidate post-swap price.
    /// @param zeroForOne The swap direction.
    /// @param paid       The input amount, already capped at the available balance.
    /// @return The mintable liquidity.
    function _mintableAfterSwap(SwapParams memory params, uint160 sqrtTarget, bool zeroForOne, uint256 paid)
        private
        pure
        returns (uint128)
    {
        (uint256 balance0, uint256 balance1) = _balancesAfterSwap(params, sqrtTarget, zeroForOne, paid);
        return mintableLiquidity(sqrtTarget, params.sqrtRatioAX96, params.sqrtRatioBX96, balance0, balance1);
    }

    /// @notice Balances the vault would hold after a swap that lands on the candidate price.
    /// @param params     The swap-sizing inputs.
    /// @param sqrtTarget The candidate post-swap price.
    /// @param zeroForOne The swap direction.
    /// @param paid       The input amount, already capped at the available balance.
    /// @return balance0 Token0 held afterwards.
    /// @return balance1 Token1 held afterwards.
    function _balancesAfterSwap(SwapParams memory params, uint160 sqrtTarget, bool zeroForOne, uint256 paid)
        private
        pure
        returns (uint256 balance0, uint256 balance1)
    {
        if (zeroForOne) {
            uint256 received =
                SqrtPriceMath.getAmount1Delta(sqrtTarget, params.sqrtPriceX96, params.poolLiquidity, false);
            balance0 = params.amount0 - paid;
            balance1 = params.amount1 + received;
        } else {
            uint256 received =
                SqrtPriceMath.getAmount0Delta(params.sqrtPriceX96, sqrtTarget, params.poolLiquidity, false);
            balance0 = params.amount0 + received;
            balance1 = params.amount1 - paid;
        }
    }

    /// @notice Input needed to move the pool from its current price to a candidate price.
    /// @dev    The pool charges its fee on the input before using it to move the price, so the
    ///         amount that must be paid in is the price-moving amount grossed up by the fee. Both
    ///         steps round up, because paying less than this would stop short of the target.
    /// @param params     The swap-sizing inputs.
    /// @param sqrtTarget The candidate post-swap price.
    /// @param zeroForOne The swap direction.
    /// @return The gross input amount.
    function _amountInForPrice(SwapParams memory params, uint160 sqrtTarget, bool zeroForOne)
        private
        pure
        returns (uint256)
    {
        uint256 net = zeroForOne
            ? SqrtPriceMath.getAmount0Delta(sqrtTarget, params.sqrtPriceX96, params.poolLiquidity, true)
            : SqrtPriceMath.getAmount1Delta(params.sqrtPriceX96, sqrtTarget, params.poolLiquidity, true);

        return FullMath.mulDivRoundingUp(net, FEE_DENOMINATOR, FEE_DENOMINATOR - params.feePips);
    }

    //
    // Oracle
    //

    /// @notice Deviation between a spot price and a time-weighted average, in basis points.
    /// @dev    Compares squared sqrt ratios, which is the price itself, so the result is a genuine
    ///         price deviation rather than a deviation of its square root. Both squares are taken
    ///         at Q96 scale, where the largest supported price still fits comfortably.
    /// @param sqrtSpotX96 The pool's current sqrt price.
    /// @param sqrtTwapX96 The sqrt price implied by the average tick.
    /// @return The absolute deviation, in basis points.
    function priceDeviationBps(uint160 sqrtSpotX96, uint160 sqrtTwapX96) internal pure returns (uint256) {
        uint256 spot = FullMath.mulDiv(sqrtSpotX96, sqrtSpotX96, 1 << 96);
        uint256 twap = FullMath.mulDiv(sqrtTwapX96, sqrtTwapX96, 1 << 96);
        if (twap == 0) revert IUniswapV3PositionVault.PriceOutOfRange();

        uint256 difference = spot > twap ? spot - twap : twap - spot;
        return FullMath.mulDiv(difference, BPS_DENOMINATOR, twap);
    }

    /// @notice The sqrt-price band a price may move within, given a tolerance in basis points.
    /// @dev    The tolerance is a bound on the price, not on its square root, so the edges are the
    ///         price scaled by one minus and one plus the tolerance and then square-rooted back into
    ///         sqrt-price space. The square root of the scaling factor is taken at Q96 and applied
    ///         with a single mulDiv, which keeps full precision without ever squaring a sqrt price.
    ///
    ///         Used to turn a curator's price-impact cap into the swap price limit the pool takes,
    ///         so a swap that would move the price further simply stops at the edge and fills
    ///         partially instead of reverting. A tolerance of 10000 basis points collapses the lower
    ///         edge to the bottom of Uniswap's range, which is as close to unbounded as the pool
    ///         allows.
    /// @param sqrtPriceX96 The sqrt price the band is centred on.
    /// @param maxBps       The tolerance, in basis points, at most 10000.
    /// @return sqrtLowX96  Lower edge of the band.
    /// @return sqrtHighX96 Upper edge of the band.
    function priceBand(uint160 sqrtPriceX96, uint16 maxBps)
        public
        pure
        returns (uint160 sqrtLowX96, uint160 sqrtHighX96)
    {
        uint256 lowFactor = Math.sqrt(FullMath.mulDiv(BPS_DENOMINATOR - maxBps, 1 << 96, BPS_DENOMINATOR));
        uint256 highFactor = Math.sqrt(FullMath.mulDiv(BPS_DENOMINATOR + maxBps, 1 << 96, BPS_DENOMINATOR));

        uint256 low = FullMath.mulDiv(sqrtPriceX96, lowFactor, 1 << 48);
        uint256 high = FullMath.mulDiv(sqrtPriceX96, highFactor, 1 << 48);

        uint256 floor_ = uint256(TickMath.MIN_SQRT_RATIO) + 1;
        uint256 ceiling = uint256(TickMath.MAX_SQRT_RATIO) - 1;
        if (low < floor_) low = floor_;
        if (low > ceiling) low = ceiling;
        if (high > ceiling) high = ceiling;
        if (high < floor_) high = floor_;

        sqrtLowX96 = uint160(low);
        sqrtHighX96 = uint160(high);
    }

    /// @notice Arithmetic mean tick implied by a pair of cumulative tick readings.
    /// @dev    Rounds toward negative infinity for negative means, matching Uniswap's own
    ///         OracleLibrary, so the average never drifts upward relative to the observed path.
    /// @param tickCumulativeStart The cumulative tick at the start of the window.
    /// @param tickCumulativeEnd   The cumulative tick at the end of the window.
    /// @param period              The window length, in seconds.
    /// @return The average tick over the window.
    function meanTick(int56 tickCumulativeStart, int56 tickCumulativeEnd, uint32 period) internal pure returns (int24) {
        int56 delta = tickCumulativeEnd - tickCumulativeStart;
        int24 average = int24(delta / int56(uint56(period)));
        if (delta < 0 && (delta % int56(uint56(period)) != 0)) average--;
        return average;
    }

    //
    // Coarse entry points
    //

    /// @notice The sqrt ratios at a pair of ticks.
    /// @dev    Bundled so a caller crossing the library boundary pays for one call rather than two.
    /// @param tickLower The lower tick.
    /// @param tickUpper The upper tick.
    /// @return sqrtRatioAX96 The sqrt ratio at the lower tick.
    /// @return sqrtRatioBX96 The sqrt ratio at the upper tick.
    function sqrtRatiosForTicks(int24 tickLower, int24 tickUpper)
        public
        pure
        returns (uint160 sqrtRatioAX96, uint160 sqrtRatioBX96)
    {
        sqrtRatioAX96 = TickMath.getSqrtRatioAtTick(tickLower);
        sqrtRatioBX96 = TickMath.getSqrtRatioAtTick(tickUpper);
    }

    /// @notice The token amounts a position of the given liquidity is currently worth.
    /// @dev    Rounds down, which is what the position would actually release if closed.
    /// @param sqrtPriceX96  The current pool price.
    /// @param sqrtRatioAX96 The position's lower sqrt ratio.
    /// @param sqrtRatioBX96 The position's upper sqrt ratio.
    /// @param liquidity     The position's liquidity.
    /// @return amount0 Token0 the position holds.
    /// @return amount1 Token1 the position holds.
    function positionValue(uint160 sqrtPriceX96, uint160 sqrtRatioAX96, uint160 sqrtRatioBX96, uint128 liquidity)
        public
        pure
        returns (uint256 amount0, uint256 amount1)
    {
        return amountsForLiquidity(sqrtPriceX96, sqrtRatioAX96, sqrtRatioBX96, liquidity, false);
    }

    /// @notice The largest position a pair of balances can mint into a range, and what it costs.
    /// @dev    The amounts are what the pool charges, so they are rounded up and then clipped to the
    ///         balances actually held; the ceiling can exceed the balance by a wei, and offering the
    ///         balance is still enough to mint the liquidity that balance implies.
    /// @param sqrtPriceX96  The current pool price.
    /// @param sqrtRatioAX96 The range's lower sqrt ratio.
    /// @param sqrtRatioBX96 The range's upper sqrt ratio.
    /// @param balance0      Token0 available.
    /// @param balance1      Token1 available.
    /// @return liquidity Liquidity that can be minted.
    /// @return need0     Token0 to offer.
    /// @return need1     Token1 to offer.
    function positionPlan(
        uint160 sqrtPriceX96,
        uint160 sqrtRatioAX96,
        uint160 sqrtRatioBX96,
        uint256 balance0,
        uint256 balance1
    ) public pure returns (uint128 liquidity, uint256 need0, uint256 need1) {
        liquidity = mintableLiquidity(sqrtPriceX96, sqrtRatioAX96, sqrtRatioBX96, balance0, balance1);
        if (liquidity == 0) return (0, 0, 0);

        (need0, need1) = amountsForLiquidity(sqrtPriceX96, sqrtRatioAX96, sqrtRatioBX96, liquidity, true);
        if (need0 > balance0) need0 = balance0;
        if (need1 > balance1) need1 = balance1;
    }

    /// @notice The position a single named amount funds, and what it costs on both sides.
    /// @param sqrtPriceX96  The current pool price.
    /// @param sqrtRatioAX96 The range's lower sqrt ratio.
    /// @param sqrtRatioBX96 The range's upper sqrt ratio.
    /// @param amount        Amount of the named token.
    /// @param isAmount0     True when the amount is token0.
    /// @return liquidity Liquidity that will be minted.
    /// @return need0     Token0 required.
    /// @return need1     Token1 required.
    function createPlan(
        uint160 sqrtPriceX96,
        uint160 sqrtRatioAX96,
        uint160 sqrtRatioBX96,
        uint256 amount,
        bool isAmount0
    ) public pure returns (uint128 liquidity, uint256 need0, uint256 need1) {
        liquidity = liquidityFromSingleAmount(sqrtPriceX96, sqrtRatioAX96, sqrtRatioBX96, amount, isAmount0);
        if (liquidity == 0) revert IUniswapV3PositionVault.InvalidArguments();
        (need0, need1) = amountsForLiquidity(sqrtPriceX96, sqrtRatioAX96, sqrtRatioBX96, liquidity, true);
    }

    /// @notice Everything a deposit needs: how many shares the caller's maxima buy and what to take.
    /// @dev    Prices a share as a claim on the position and the idle balances together, so a
    ///         depositor buys into both in the same proportion and neither dilutes the other.
    /// @param sqrtPriceX96  The current pool price.
    /// @param sqrtRatioAX96 The position's lower sqrt ratio.
    /// @param sqrtRatioBX96 The position's upper sqrt ratio.
    /// @param liquidity     The position's current liquidity.
    /// @param idle0         Token0 sitting idle in the vault.
    /// @param idle1         Token1 sitting idle in the vault.
    /// @param supply        The current share supply.
    /// @param amount        The amount of the named token the caller will supply.
    /// @param isAmount0     True when that amount is token0.
    /// @return shares  The share count that amount buys.
    /// @return charge0 Token0 that funds the new liquidity.
    /// @return charge1 Token1 that funds the new liquidity.
    /// @return pulled0 Total token0 to take from the depositor.
    /// @return pulled1 Total token1 to take from the depositor.
    function depositPlan(
        uint160 sqrtPriceX96,
        uint160 sqrtRatioAX96,
        uint160 sqrtRatioBX96,
        uint128 liquidity,
        uint256 idle0,
        uint256 idle1,
        uint256 supply,
        uint256 amount,
        bool isAmount0
    ) public pure returns (uint256 shares, uint256 charge0, uint256 charge1, uint256 pulled0, uint256 pulled1) {
        // The denominator rounds UP, and that direction is load-bearing rather than cosmetic. What
        // the deposit is finally charged is recomputed from the liquidity the share count buys, so
        // any truncation left in this denominator reappears in the charge multiplied by the ratio of
        // the deposit to the vault. Flooring it therefore over-charges by roughly that ratio: a
        // deposit three times the size of the vault exceeded the caller's amount by a wei, and one a
        // thousand times its size by several hundred, each reverting as SlippageExceeded. Rounding
        // up makes the share count slightly conservative instead, which errs toward the vault at
        // every size.
        (uint256 total0, uint256 total1) =
            amountsForLiquidity(sqrtPriceX96, sqrtRatioAX96, sqrtRatioBX96, liquidity, true);

        // The charge also rounds two components up: the tokens the new liquidity needs, and the
        // claim on the idle balances. Each ceiling can add a wei, so the amount is reduced by that
        // fixed headroom as well.
        shares = sharesForSide(_lessHeadroom(amount), isAmount0 ? total0 + idle0 : total1 + idle1, supply);
        (, charge0, charge1, pulled0, pulled1) =
            depositCost(sqrtPriceX96, sqrtRatioAX96, sqrtRatioBX96, liquidity, idle0, idle1, supply, shares);
    }

    /// @notice A budget reduced by the worst-case rounding headroom of a deposit.
    /// @param amount The caller's maximum.
    /// @return The amount to size the purchase against.
    function _lessHeadroom(uint256 amount) private pure returns (uint256) {
        return amount > ROUNDING_HEADROOM ? amount - ROUNDING_HEADROOM : 0;
    }

    /// @notice Reverts unless a spot price is within the tolerance of its own recent average.
    /// @dev    Bundles the average, its sqrt price and the tolerance test into the single call the
    ///         vault makes before and after every price-sensitive operation.
    /// @param sqrtSpotX96         The pool's current sqrt price.
    /// @param tickCumulativeStart The cumulative tick at the start of the window.
    /// @param tickCumulativeEnd   The cumulative tick at the end of the window.
    /// @param period              The window length, in seconds.
    /// @param maxBps              The tolerance, in basis points.
    /// @return sqrtTwapX96 The sqrt price implied by the average tick.
    function twapCheck(
        uint160 sqrtSpotX96,
        int56 tickCumulativeStart,
        int56 tickCumulativeEnd,
        uint32 period,
        uint16 maxBps
    ) public pure returns (uint160 sqrtTwapX96) {
        sqrtTwapX96 = TickMath.getSqrtRatioAtTick(meanTick(tickCumulativeStart, tickCumulativeEnd, period));
        uint256 deviation = priceDeviationBps(sqrtSpotX96, sqrtTwapX96);
        if (deviation > maxBps) revert IUniswapV3PositionVault.PriceDeviationTooHigh(deviation, maxBps);
    }
}
