// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

import {Test} from "forge-std/Test.sol";

import {IUniswapV3PositionVault} from "../src/IUniswapV3PositionVault.sol";
import {UniswapV3VaultMath} from "../src/libraries/UniswapV3VaultMath.sol";
import {LiquidityAmounts} from "../src/libraries/uniswap/LiquidityAmounts.sol";
import {SqrtPriceMath} from "../src/libraries/uniswap/SqrtPriceMath.sol";
import {TickMath} from "../src/libraries/uniswap/TickMath.sol";
import {FullMath} from "../src/libraries/uniswap/FullMath.sol";

/// @title  MathHarness
/// @author KPK
/// @notice Exposes the internal parts of UniswapV3VaultMath so they can be tested directly.
contract MathHarness {
    function floorToSpacing(int24 tick, int24 spacing) external pure returns (int24) {
        return UniswapV3VaultMath.floorToSpacing(tick, spacing);
    }

    function ceilToSpacing(int24 tick, int24 spacing) external pure returns (int24) {
        return UniswapV3VaultMath.ceilToSpacing(tick, spacing);
    }

    function upstreamLiquidityForAmount0(uint160 a, uint160 b, uint256 amount0) external pure returns (uint128) {
        return LiquidityAmounts.getLiquidityForAmount0(a, b, amount0);
    }

    function upstreamLiquidityForAmount1(uint160 a, uint160 b, uint256 amount1) external pure returns (uint128) {
        return LiquidityAmounts.getLiquidityForAmount1(a, b, amount1);
    }

    function liquidityForAmount0Saturating(uint160 a, uint160 b, uint256 amount0) external pure returns (uint128) {
        return UniswapV3VaultMath.liquidityForAmount0Saturating(a, b, amount0);
    }

    function liquidityForAmount1Saturating(uint160 a, uint160 b, uint256 amount1) external pure returns (uint128) {
        return UniswapV3VaultMath.liquidityForAmount1Saturating(a, b, amount1);
    }

    function mintableLiquidity(uint160 p, uint160 a, uint160 b, uint256 amount0, uint256 amount1)
        external
        pure
        returns (uint128)
    {
        return UniswapV3VaultMath.mintableLiquidity(p, a, b, amount0, amount1);
    }

    function amountsForLiquidity(uint160 p, uint160 a, uint160 b, uint128 liquidity, bool roundUp)
        external
        pure
        returns (uint256, uint256)
    {
        return UniswapV3VaultMath.amountsForLiquidity(p, a, b, liquidity, roundUp);
    }

    function liquidityFromSingleAmount(uint160 p, uint160 a, uint160 b, uint256 amount, bool isAmount0)
        external
        pure
        returns (uint128)
    {
        return UniswapV3VaultMath.liquidityFromSingleAmount(p, a, b, amount, isAmount0);
    }

    function meanTick(int56 start, int56 end, uint32 period) external pure returns (int24) {
        return UniswapV3VaultMath.meanTick(start, end, period);
    }

    function priceDeviationBps(uint160 spot, uint160 twap) external pure returns (uint256) {
        return UniswapV3VaultMath.priceDeviationBps(spot, twap);
    }
}

/// @title  UniswapV3PositionVaultMathTest
/// @author KPK
/// @notice Unit and fuzz tests for the vault's pure math. Needs no fork: every function under test
///         is pure, so the whole suite runs without an RPC endpoint.
contract UniswapV3PositionVaultMathTest is Test {
    MathHarness internal harness;

    /// @dev USDC has 6 decimals and WETH has 18, the ordering of the canonical mainnet pool.
    uint256 internal constant SCALE_NUM_6_18 = 1e18;
    uint256 internal constant SCALE_DEN_6_18 = 1e18 * 1e6;

    /// @dev Both tokens at 18 decimals, where the human price is the raw ratio.
    uint256 internal constant SCALE_NUM_18_18 = 1e18;
    uint256 internal constant SCALE_DEN_18_18 = 1e18 * 1e18;

    function setUp() public {
        harness = new MathHarness();
    }

    //
    // Price conversion
    //

    function test_priceConversion_matchesAKnownPoolPrice() public pure {
        // USDC/WETH at 3000 USDC per ETH: one USDC buys 1/3000 WETH.
        uint256 price = uint256(1e18) / 3000;
        uint160 sqrtPriceX96 = UniswapV3VaultMath.priceToSqrtPriceX96(price, SCALE_NUM_6_18, SCALE_DEN_6_18);

        // The raw ratio Uniswap stores is (WETH base units) / (USDC base units).
        uint256 expectedRaw = price * SCALE_NUM_6_18 / SCALE_DEN_6_18;
        uint256 actualRaw = FullMath.mulDiv(sqrtPriceX96, sqrtPriceX96, 1 << 192);
        assertApproxEqRel(actualRaw, expectedRaw, 1e12, "raw ratio");

        // Round-trips back to the same human price.
        uint256 back = UniswapV3VaultMath.sqrtPriceX96ToPrice(sqrtPriceX96, SCALE_NUM_6_18, SCALE_DEN_6_18);
        assertApproxEqRel(back, price, 1e9, "round trip");
    }

    function test_priceConversion_handlesRatiosAboveTheSplitThreshold() public pure {
        // token0 with 8 decimals against token1 with 18 pushes the raw ratio past 2**64, which is
        // the regime where the shift has to be split around the square root.
        uint256 scaleNum = 1e18;
        uint256 scaleDen = 1e18 * 1e8;
        uint256 price = 20e18; // 20 token1 per token0

        uint160 sqrtPriceX96 = UniswapV3VaultMath.priceToSqrtPriceX96(price, scaleNum, scaleDen);
        uint256 back = UniswapV3VaultMath.sqrtPriceX96ToPrice(sqrtPriceX96, scaleNum, scaleDen);
        assertApproxEqRel(back, price, 1e9, "round trip above threshold");
    }

    function testFuzz_priceConversion_roundTrips(uint256 price, uint8 decimals0, uint8 decimals1) public pure {
        decimals0 = uint8(bound(decimals0, 2, 18));
        decimals1 = uint8(bound(decimals1, 2, 18));
        uint256 scaleNum = 10 ** decimals1;
        uint256 scaleDen = 1e18 * 10 ** decimals0;

        price = bound(price, 1e6, 1e30);

        // Only prices Uniswap can represent are in scope; the rest revert by design.
        uint256 raw = FullMath.mulDiv(price, scaleNum, scaleDen);
        vm.assume(raw > 1e3 && raw < 1e30);

        uint160 sqrtPriceX96 = UniswapV3VaultMath.priceToSqrtPriceX96(price, scaleNum, scaleDen);
        uint256 back = UniswapV3VaultMath.sqrtPriceX96ToPrice(sqrtPriceX96, scaleNum, scaleDen);

        // Both directions floor, so the round trip loses at most one unit outright plus the
        // relative precision of the square root. At tiny prices the single unit dominates, which a
        // purely relative bound would call a failure.
        assertLe(back, price, "the round trip never rounds up");
        assertApproxEqAbs(back, price, 1 + price / 1e8, "round trip within a unit and 1e-8");
    }

    function test_priceToSqrtPriceX96_rejectsPricesOutsideUniswapsRange() public {
        vm.expectRevert(IUniswapV3PositionVault.PriceOutOfRange.selector);
        UniswapV3VaultMath.priceToSqrtPriceX96(0, SCALE_NUM_18_18, SCALE_DEN_18_18);

        // A raw ratio beyond 2**128 is past the largest price Uniswap v3 can represent.
        vm.expectRevert(IUniswapV3PositionVault.PriceOutOfRange.selector);
        UniswapV3VaultMath.priceToSqrtPriceX96(1e60, SCALE_NUM_18_18, SCALE_DEN_18_18);

        // The bottom of Uniswap's range is a raw ratio of 2**-128, far below anything a 1e18-scaled
        // price can express, so the smallest representable price is still comfortably inside it.
        uint160 smallest = UniswapV3VaultMath.priceToSqrtPriceX96(1, SCALE_NUM_18_18, SCALE_DEN_18_18);
        assertGt(smallest, TickMath.MIN_SQRT_RATIO, "the smallest expressible price is in range");
    }

    //
    // Tick snapping
    //

    function test_floorToSpacing_roundsTowardNegativeInfinity() public view {
        assertEq(harness.floorToSpacing(int24(125), int24(60)), int24(120), "positive");
        assertEq(harness.floorToSpacing(int24(120), int24(60)), int24(120), "exact");
        assertEq(harness.floorToSpacing(int24(-125), int24(60)), int24(-180), "negative");
        assertEq(harness.floorToSpacing(int24(-120), int24(60)), int24(-120), "negative exact");
    }

    function test_ceilToSpacing_roundsTowardPositiveInfinity() public view {
        assertEq(harness.ceilToSpacing(int24(125), int24(60)), int24(180), "positive");
        assertEq(harness.ceilToSpacing(int24(120), int24(60)), int24(120), "exact");
        assertEq(harness.ceilToSpacing(int24(-125), int24(60)), int24(-120), "negative");
        assertEq(harness.ceilToSpacing(int24(-120), int24(60)), int24(-120), "negative exact");
    }

    function testFuzz_snapping_bracketsTheOriginalTick(int24 tick, uint8 spacingChoice) public view {
        int24 spacing = _spacing(spacingChoice);
        tick = int24(bound(tick, TickMath.MIN_TICK + spacing, TickMath.MAX_TICK - spacing));

        int24 floored = harness.floorToSpacing(tick, spacing);
        int24 ceiled = harness.ceilToSpacing(tick, spacing);

        assertLe(floored, tick, "floor is at most the tick");
        assertGe(ceiled, tick, "ceil is at least the tick");
        assertEq(floored % spacing, int24(0), "floor is aligned");
        assertEq(ceiled % spacing, int24(0), "ceil is aligned");
        assertLt(tick - floored, spacing, "floor is within one spacing");
        assertLt(ceiled - tick, spacing, "ceil is within one spacing");
    }

    function test_priceRangeToTicks_coversTheRequestedPrices() public pure {
        uint256 lower = uint256(1e18) / 4000;
        uint256 upper = uint256(1e18) / 2000;

        (int24 tickLower, int24 tickUpper) =
            UniswapV3VaultMath.priceRangeToTicks(lower, upper, 10, SCALE_NUM_6_18, SCALE_DEN_6_18);

        assertLt(tickLower, tickUpper, "range is non-empty");
        assertEq(tickLower % 10, int24(0), "lower is aligned");
        assertEq(tickUpper % 10, int24(0), "upper is aligned");

        // The snapped range must contain the requested one, never be contained by it.
        uint160 sqrtLower = UniswapV3VaultMath.priceToSqrtPriceX96(lower, SCALE_NUM_6_18, SCALE_DEN_6_18);
        uint160 sqrtUpper = UniswapV3VaultMath.priceToSqrtPriceX96(upper, SCALE_NUM_6_18, SCALE_DEN_6_18);
        assertLe(TickMath.getSqrtRatioAtTick(tickLower), sqrtLower, "covers the lower price");
        assertGe(TickMath.getSqrtRatioAtTick(tickUpper), sqrtUpper, "covers the upper price");
    }

    function test_priceRangeToTicks_rejectsAnInvertedRange() public {
        vm.expectRevert(IUniswapV3PositionVault.InvalidPriceRange.selector);
        UniswapV3VaultMath.priceRangeToTicks(2e18, 1e18, 60, SCALE_NUM_18_18, SCALE_DEN_18_18);

        vm.expectRevert(IUniswapV3PositionVault.InvalidPriceRange.selector);
        UniswapV3VaultMath.priceRangeToTicks(1e18, 1e18, 60, SCALE_NUM_18_18, SCALE_DEN_18_18);
    }

    //
    // Position amounts
    //

    function test_liquidityFromSingleAmount_rejectsTheUnusableSide() public {
        uint160 sqrtP = TickMath.getSqrtRatioAtTick(0);
        uint160 above = TickMath.getSqrtRatioAtTick(6000);
        uint160 farAbove = TickMath.getSqrtRatioAtTick(12000);

        // A range entirely above the price is funded by token0 alone.
        vm.expectRevert(IUniswapV3PositionVault.AmountSideNotUsable.selector);
        harness.liquidityFromSingleAmount(sqrtP, above, farAbove, 1e18, false);

        // A range entirely below it is funded by token1 alone.
        uint160 below = TickMath.getSqrtRatioAtTick(-12000);
        uint160 farBelow = TickMath.getSqrtRatioAtTick(-6000);
        vm.expectRevert(IUniswapV3PositionVault.AmountSideNotUsable.selector);
        harness.liquidityFromSingleAmount(sqrtP, below, farBelow, 1e18, true);
    }

    function test_amountsForLiquidity_roundsUpAgainstTheSupplier() public view {
        uint160 sqrtP = TickMath.getSqrtRatioAtTick(100);
        uint160 sqrtA = TickMath.getSqrtRatioAtTick(-600);
        uint160 sqrtB = TickMath.getSqrtRatioAtTick(600);

        (uint256 up0, uint256 up1) = harness.amountsForLiquidity(sqrtP, sqrtA, sqrtB, 1e18, true);
        (uint256 down0, uint256 down1) = harness.amountsForLiquidity(sqrtP, sqrtA, sqrtB, 1e18, false);

        assertGe(up0, down0, "ceiling is at least the floor");
        assertGe(up1, down1, "ceiling is at least the floor");
        assertLe(up0 - down0, 1, "ceiling exceeds the floor by at most a wei");
        assertLe(up1 - down1, 1, "ceiling exceeds the floor by at most a wei");
    }

    function testFuzz_amountsForLiquidity_fundsTheLiquidityItPricesFor(uint128 liquidity, int24 currentTick)
        public
        view
    {
        liquidity = uint128(bound(liquidity, 1e6, 1e24));
        currentTick = int24(bound(currentTick, -5000, 5000));

        uint160 sqrtA = TickMath.getSqrtRatioAtTick(-6000);
        uint160 sqrtB = TickMath.getSqrtRatioAtTick(6000);
        uint160 sqrtP = TickMath.getSqrtRatioAtTick(currentTick);

        (uint256 need0, uint256 need1) = harness.amountsForLiquidity(sqrtP, sqrtA, sqrtB, liquidity, true);

        // Offering exactly the rounded-up amounts must buy back at least the liquidity they priced.
        uint128 recovered = harness.mintableLiquidity(sqrtP, sqrtA, sqrtB, need0, need1);
        assertGe(recovered, liquidity, "rounded-up amounts fund the liquidity");
    }

    //
    // Share accounting
    //

    function test_sharesForSide_pricesFromTheNamedSide() public pure {
        // A vault holding 100 token0 against 1000 shares: ten token0 buys a tenth of the supply.
        assertEq(UniswapV3VaultMath.sharesForSide(10, 100, 1000), 100, "a tenth of the supply");
        assertEq(UniswapV3VaultMath.sharesForSide(100, 100, 1000), 1000, "all of it");
    }

    function test_sharesForSide_roundsDownAgainstTheDepositor() public pure {
        // 999 * 1000 / 1000 is exact; 999 * 1000 / 1001 is not, and must not round up.
        assertEq(UniswapV3VaultMath.sharesForSide(999, 1001, 1000), 998, "rounds down");
    }

    function test_sharesForSide_rejectsASideTheVaultDoesNotHold() public {
        // An out-of-range position holds only one token, so naming the other cannot buy anything.
        vm.expectRevert(IUniswapV3PositionVault.AmountSideNotUsable.selector);
        UniswapV3VaultMath.sharesForSide(1e18, 0, 1000);
    }

    function test_depositPlan_neverChargesMoreThanTheNamedAmount() public pure {
        uint160 sqrtP = TickMath.getSqrtRatioAtTick(0);
        uint160 sqrtA = TickMath.getSqrtRatioAtTick(-600);
        uint160 sqrtB = TickMath.getSqrtRatioAtTick(600);
        uint128 liquidity = 1e18;
        uint256 supply = liquidity;

        (uint256 total0,) = UniswapV3VaultMath.positionValue(sqrtP, sqrtA, sqrtB, liquidity);

        // A deposit many times the size of the vault is the case that used to break. The share
        // count comes from the vault's own totals and the charge is then recomputed from the
        // liquidity those shares buy, so truncation in that denominator reappears in the charge
        // multiplied by the ratio of the deposit to the vault. It has to hold at every size.
        uint256[7] memory multiples = [uint256(1), 2, 3, 5, 10, 1000, 100_000];
        for (uint256 i; i < multiples.length; ++i) {
            uint256 amount = total0 * multiples[i];
            (,,, uint256 pulled0,) =
                UniswapV3VaultMath.depositPlan(sqrtP, sqrtA, sqrtB, liquidity, 0, 0, supply, amount, true);

            assertLe(pulled0, amount, "charged more than the caller named");
        }
    }

    function testFuzz_depositPlan_neverChargesMoreThanTheNamedAmount(
        uint256 amountSeed,
        uint128 liquiditySeed,
        int24 currentTick
    ) public pure {
        uint128 liquidity = uint128(bound(liquiditySeed, 1e12, 1e30));
        currentTick = int24(bound(currentTick, -500, 500));

        uint160 sqrtP = TickMath.getSqrtRatioAtTick(currentTick);
        uint160 sqrtA = TickMath.getSqrtRatioAtTick(-600);
        uint160 sqrtB = TickMath.getSqrtRatioAtTick(600);

        (uint256 total0,) = UniswapV3VaultMath.positionValue(sqrtP, sqrtA, sqrtB, liquidity);
        vm.assume(total0 > 1e6);

        uint256 amount = bound(amountSeed, 1e6, total0 * 100_000);
        (,,, uint256 pulled0,) =
            UniswapV3VaultMath.depositPlan(sqrtP, sqrtA, sqrtB, liquidity, 0, 0, liquidity, amount, true);

        assertLe(pulled0, amount, "charged more than the caller named");
    }

    //
    // Oracle helpers
    //

    function test_meanTick_roundsTowardNegativeInfinity() public view {
        // A negative cumulative delta that does not divide evenly must round down, not toward zero.
        assertEq(harness.meanTick(int56(0), int56(-7), uint32(2)), int24(-4), "negative rounds down");
        assertEq(harness.meanTick(int56(0), int56(7), uint32(2)), int24(3), "positive truncates");
        assertEq(harness.meanTick(int56(0), int56(-8), uint32(2)), int24(-4), "negative exact");
    }

    function test_priceDeviationBps_worksAtTheLowEndOfUniswapsRange() public view {
        // Squaring each sqrt ratio and shifting down by 2**96 threw away everything below the shift.
        // Uniswap represents sqrt ratios from 2**32, and anything under 2**48 squared to zero, so a
        // pool of two tokens whose raw price ratio was small enough had every guarded call revert
        // PriceOutOfRange from the moment it was deployed.
        uint160 low = 1 << 40;

        assertEq(harness.priceDeviationBps(low, low), 0, "a price equal to its own average deviates by nothing");

        // A one percent move in price is 10000 * (1.01 - 1) = 100 bps, whatever the ratio's scale.
        uint160 moved = uint160(FullMath.mulDiv(low, 100_499, 100_000));
        uint256 deviation = harness.priceDeviationBps(moved, low);
        assertApproxEqAbs(deviation, 100, 1, "one percent reads as one percent down here too");
    }

    function test_priceDeviationBps_measuresPriceNotSqrtPrice() public view {
        uint160 twap = TickMath.getSqrtRatioAtTick(0);
        // A price 21% above the average: sqrt(1.21) = 1.1, so the sqrt price is only 10% higher.
        uint160 spot = uint160(uint256(twap) * 11 / 10);
        assertApproxEqAbs(harness.priceDeviationBps(spot, twap), 2100, 2, "deviation is on price");
    }

    //
    // Swap sizing
    //

    function test_solveSwap_returnsNoSwapWhenBalancesAlreadyMatch() public pure {
        uint160 sqrtP = TickMath.getSqrtRatioAtTick(0);
        uint160 sqrtA = TickMath.getSqrtRatioAtTick(-6000);
        uint160 sqrtB = TickMath.getSqrtRatioAtTick(6000);

        // At tick 0 with a symmetric range the position wants equal amounts of both tokens.
        (uint256 need0, uint256 need1) = UniswapV3VaultMath.positionValue(sqrtP, sqrtA, sqrtB, 1e21);

        (, uint256 amountIn) = UniswapV3VaultMath.solveSwap(
            UniswapV3VaultMath.SwapParams({
                sqrtPriceX96: sqrtP,
                sqrtRatioAX96: sqrtA,
                sqrtRatioBX96: sqrtB,
                poolLiquidity: 1e24,
                feePips: 3000,
                amount0: need0,
                amount1: need1
            })
        );
        assertEq(amountIn, 0, "balanced holdings need no swap");
    }

    function test_solveSwap_sellsEverythingWhenTheRangeIsWhollyBelowThePrice() public pure {
        // A range below the spot price holds only token1, so all token0 must be sold.
        uint160 sqrtP = TickMath.getSqrtRatioAtTick(20000);
        uint160 sqrtA = TickMath.getSqrtRatioAtTick(-6000);
        uint160 sqrtB = TickMath.getSqrtRatioAtTick(-3000);

        (bool zeroForOne, uint256 amountIn) = UniswapV3VaultMath.solveSwap(
            UniswapV3VaultMath.SwapParams({
                sqrtPriceX96: sqrtP,
                sqrtRatioAX96: sqrtA,
                sqrtRatioBX96: sqrtB,
                poolLiquidity: 1e24,
                feePips: 3000,
                amount0: 1e18,
                amount1: 0
            })
        );
        assertTrue(zeroForOne, "sells token0");
        assertEq(amountIn, 1e18, "sells the whole balance");
    }

    function test_solveSwap_sellsEverythingWhenTheRangeIsWhollyAboveThePrice() public pure {
        uint160 sqrtP = TickMath.getSqrtRatioAtTick(-20000);
        uint160 sqrtA = TickMath.getSqrtRatioAtTick(3000);
        uint160 sqrtB = TickMath.getSqrtRatioAtTick(6000);

        (bool zeroForOne, uint256 amountIn) = UniswapV3VaultMath.solveSwap(
            UniswapV3VaultMath.SwapParams({
                sqrtPriceX96: sqrtP,
                sqrtRatioAX96: sqrtA,
                sqrtRatioBX96: sqrtB,
                poolLiquidity: 1e24,
                feePips: 3000,
                amount0: 0,
                amount1: 1e18
            })
        );
        assertFalse(zeroForOne, "sells token1");
        assertEq(amountIn, 1e18, "sells the whole balance");
    }

    function test_solveSwap_beatsEveryNearbyAlternative() public pure {
        UniswapV3VaultMath.SwapParams memory params = UniswapV3VaultMath.SwapParams({
            sqrtPriceX96: TickMath.getSqrtRatioAtTick(0),
            sqrtRatioAX96: TickMath.getSqrtRatioAtTick(-6000),
            sqrtRatioBX96: TickMath.getSqrtRatioAtTick(6000),
            poolLiquidity: 1e24,
            feePips: 3000,
            amount0: 1000e18,
            amount1: 0
        });

        (bool zeroForOne, uint256 amountIn) = UniswapV3VaultMath.solveSwap(params);
        assertTrue(zeroForOne, "sells the token it holds");
        assertGt(amountIn, 0, "swaps something");

        uint128 best = _mintableAfter(params, zeroForOne, amountIn);

        // Sweep the whole feasible range; the solver's answer must be the best of them.
        for (uint256 i = 0; i <= 100; ++i) {
            uint256 candidate = params.amount0 * i / 100;
            assertGe(best, _mintableAfter(params, zeroForOne, candidate), "solver is optimal");
        }
    }

    function testFuzz_solveSwap_isOptimalAcrossPricesAndBalances(int24 currentTick, uint256 amount0, uint256 amount1)
        public
        pure
    {
        currentTick = int24(bound(currentTick, -5500, 5500));
        amount0 = bound(amount0, 1e12, 1e24);
        amount1 = bound(amount1, 1e12, 1e24);

        UniswapV3VaultMath.SwapParams memory params = UniswapV3VaultMath.SwapParams({
            sqrtPriceX96: TickMath.getSqrtRatioAtTick(currentTick),
            sqrtRatioAX96: TickMath.getSqrtRatioAtTick(-6000),
            sqrtRatioBX96: TickMath.getSqrtRatioAtTick(6000),
            poolLiquidity: 1e27,
            feePips: 3000,
            amount0: amount0,
            amount1: amount1
        });

        (bool zeroForOne, uint256 amountIn) = UniswapV3VaultMath.solveSwap(params);
        uint128 best = _mintableAfter(params, zeroForOne, amountIn);
        uint256 budget = zeroForOne ? amount0 : amount1;

        // The solver must not be beaten by any coarse alternative, including not swapping at all.
        for (uint256 i; i <= 20; ++i) {
            assertGe(best, _mintableAfter(params, zeroForOne, budget * i / 20), "solver is optimal");
        }
    }

    function test_solveSwap_revertsWhenThePoolHasNoLiquidityToSizeAgainst() public {
        // A pool with no in-range liquidity gives the model nothing to project a price move
        // against, so the rebalance stops rather than swapping blind.
        vm.expectRevert(IUniswapV3PositionVault.PoolHasNoLiquidity.selector);
        UniswapV3VaultMath.solveSwap(
            UniswapV3VaultMath.SwapParams({
                sqrtPriceX96: TickMath.getSqrtRatioAtTick(0),
                sqrtRatioAX96: TickMath.getSqrtRatioAtTick(-6000),
                sqrtRatioBX96: TickMath.getSqrtRatioAtTick(6000),
                poolLiquidity: 0,
                feePips: 3000,
                amount0: 1000e18,
                amount1: 0
            })
        );
    }

    function test_solveSwap_doesNothingWhenTheSoldSideIsEmpty() public pure {
        // Holding only the token the range wants leaves nothing to sell.
        (, uint256 amountIn) = UniswapV3VaultMath.solveSwap(
            UniswapV3VaultMath.SwapParams({
                sqrtPriceX96: TickMath.getSqrtRatioAtTick(20000),
                sqrtRatioAX96: TickMath.getSqrtRatioAtTick(-6000),
                sqrtRatioBX96: TickMath.getSqrtRatioAtTick(-3000),
                poolLiquidity: 1e24,
                feePips: 3000,
                amount0: 0,
                amount1: 500e18
            })
        );
        assertEq(amountIn, 0, "nothing to sell");
    }

    function test_solveSwap_handlesABudgetThatOvershootsTheRangeEdge() public pure {
        // The liquidity a balance can fund grows without bound as the price nears the edge that
        // balance funds, so a probe placed a hair inside an edge used to ask for more than a uint128
        // holds and revert with no data. It is reachable whenever the balance being sold could push
        // the price past the far edge, which is the ordinary case for a narrow range and exactly
        // what the swapping rebalance exists for.
        (, uint256 sellingToken1) = UniswapV3VaultMath.solveSwap(
            UniswapV3VaultMath.SwapParams({
                sqrtPriceX96: TickMath.getSqrtRatioAtTick(-60),
                sqrtRatioAX96: TickMath.getSqrtRatioAtTick(0),
                sqrtRatioBX96: TickMath.getSqrtRatioAtTick(60),
                poolLiquidity: 1e21,
                feePips: 3000,
                amount0: 0,
                amount1: 10e18
            })
        );
        assertGt(sellingToken1, 0, "a swap should still be sized");

        (, uint256 sellingToken0) = UniswapV3VaultMath.solveSwap(
            UniswapV3VaultMath.SwapParams({
                sqrtPriceX96: TickMath.getSqrtRatioAtTick(60),
                sqrtRatioAX96: TickMath.getSqrtRatioAtTick(-60),
                sqrtRatioBX96: TickMath.getSqrtRatioAtTick(0),
                poolLiquidity: 1e21,
                feePips: 3000,
                amount0: 1e19,
                amount1: 0
            })
        );
        assertGt(sellingToken0, 0, "and in the other direction too");
    }

    function testFuzz_solveSwap_answersABudgetUpToAThousandTimesThePool(uint256 budgetSeed, bool zeroForOne)
        public
        pure
    {
        uint256 budget = bound(budgetSeed, 1e15, 1e24);

        // Sizing a swap into a one-tick-wide range must produce an answer rather than an undecodable
        // revert. The bound is named in the test's own name because the claim is not unconditional:
        // Uniswap's getNextSqrtPriceFromInput casts to uint160 and panics once the amount exceeds
        // the pool's liquidity by 2**64, sixty-one orders of magnitude past what this covers and far
        // past any pool a vault could be pointed at. Reaching it would be a curator-facing failure
        // of rebalanceWithSwap, with the non-trading rebalance still working.
        UniswapV3VaultMath.solveSwap(
            UniswapV3VaultMath.SwapParams({
                sqrtPriceX96: TickMath.getSqrtRatioAtTick(zeroForOne ? int24(60) : int24(-60)),
                sqrtRatioAX96: TickMath.getSqrtRatioAtTick(zeroForOne ? int24(-60) : int24(0)),
                sqrtRatioBX96: TickMath.getSqrtRatioAtTick(zeroForOne ? int24(0) : int24(60)),
                poolLiquidity: 1e21,
                feePips: 3000,
                amount0: zeroForOne ? budget : 0,
                amount1: zeroForOne ? 0 : budget
            })
        );
    }

    function test_solveSwap_neverPicksASwapWorseThanNotSwapping() public pure {
        // A budget enormous relative to the pool's liquidity: selling it all drives the price out
        // of the target range and leaves nothing mintable, while leaving the balances alone still
        // funds a little. The solver reaches its endpoint return here, and the endpoint returns
        // have to compare spending everything against spending nothing rather than assume the
        // extreme wins. Found by sweeping the search's own objective; these are its numbers.
        UniswapV3VaultMath.SwapParams memory params = UniswapV3VaultMath.SwapParams({
            sqrtPriceX96: TickMath.getSqrtRatioAtTick(1),
            sqrtRatioAX96: TickMath.getSqrtRatioAtTick(-95),
            sqrtRatioBX96: TickMath.getSqrtRatioAtTick(187),
            poolLiquidity: 1_000_000_000_000_000_001,
            feePips: 3000,
            amount0: 378_380_548_692_128_997_450_151,
            amount1: 1
        });

        (bool sells, uint256 amountIn) = UniswapV3VaultMath.solveSwap(params);

        // The two extremes are both bad here: spending everything drives the price out of the range
        // and mints nothing, and spending nothing mints 208. The answer is the crossing between
        // them, and it has to beat both.
        assertGt(
            _mintableAfter(params, sells, amountIn),
            _mintableAfter(params, sells, 0),
            "must beat leaving the balances alone"
        );
        assertGt(
            _mintableAfter(params, sells, amountIn),
            _mintableAfter(params, sells, params.amount0),
            "must beat spending the whole budget"
        );
    }

    function test_solveSwap_reachesACrossingThatSitsNextToTheRangeEdge() public pure {
        // The crossing here sits close enough to the lower edge that the search could not once look
        // at it: Uniswap's getLiquidityForAmount0/1 cast to uint128 and revert with no error data
        // for a price that near, so the search was held a sixty-fourth of the range clear of both
        // edges and returned the margin instead. That cost six orders of magnitude — 2.07e19 minted
        // against an achievable 2.69e25. The caps saturate now rather than revert, the exclusion is
        // down to a single wei, and the crossing is reachable wherever it falls.
        UniswapV3VaultMath.SwapParams memory params = UniswapV3VaultMath.SwapParams({
            sqrtPriceX96: TickMath.getSqrtRatioAtTick(1),
            sqrtRatioAX96: TickMath.getSqrtRatioAtTick(-95),
            sqrtRatioBX96: TickMath.getSqrtRatioAtTick(187),
            poolLiquidity: 1_000_000_000_000_000_001,
            feePips: 3000,
            amount0: 378_380_548_692_128_997_450_151,
            amount1: 1
        });

        (bool sells, uint256 amountIn) = UniswapV3VaultMath.solveSwap(params);

        // 1e16 is the best a coarse sweep of the objective finds. The search has to match it or beat
        // it, rather than stopping at a margin short of it.
        assertGe(
            _mintableAfter(params, sells, amountIn),
            _mintableAfter(params, sells, 1e16),
            "the search must reach the crossing, not stop at a margin short of it"
        );
        assertGt(_mintableAfter(params, sells, amountIn), 1e25, "and that is worth six orders of magnitude");
    }

    function test_solveSwap_declinesWhenTheBalancesAlreadyFundTheCeiling() public pure {
        // The balances already fund more liquidity than a position can hold, so no trade could do
        // better and paying a pool fee to find that out would be a straight loss.
        //
        // Measured: removing the explicit check for this leaves the answer unchanged, because the
        // same rule that turns the saturated baseline into a zero turns every saturated candidate
        // into one too, and nothing then beats nothing. The check is kept because relying on two
        // zeros cancelling is not the same as saying what is meant, and because that reasoning
        // stops holding the moment either rule changes.
        UniswapV3VaultMath.SwapParams memory params = UniswapV3VaultMath.SwapParams({
            sqrtPriceX96: TickMath.getSqrtRatioAtTick(0),
            sqrtRatioAX96: TickMath.getSqrtRatioAtTick(-1),
            sqrtRatioBX96: TickMath.getSqrtRatioAtTick(0),
            poolLiquidity: 1e21,
            feePips: 3000,
            amount0: 1e24,
            amount1: 1e35
        });

        assertEq(
            UniswapV3VaultMath.mintableLiquidity(
                params.sqrtPriceX96, params.sqrtRatioAX96, params.sqrtRatioBX96, params.amount0, params.amount1
            ),
            type(uint128).max,
            "the balances really do fund the ceiling"
        );

        (, uint256 amountIn) = UniswapV3VaultMath.solveSwap(params);
        assertEq(amountIn, 0, "no swap can improve on the ceiling");
    }

    function test_liquidityForAmount_saturatesInsteadOfRevertingAtAnEdge() public view {
        uint160 sqrtA = TickMath.getSqrtRatioAtTick(-60);
        uint160 sqrtB = TickMath.getSqrtRatioAtTick(60);

        // One wei of interval and a real balance: the honest answer is more liquidity than a uint128
        // holds. Uniswap's own helpers revert here with no error data, which is what used to make
        // the swap search unable to look near a range edge at all.
        assertEq(
            harness.liquidityForAmount0Saturating(sqrtA, sqrtA + 1, 1e18), type(uint128).max, "token0 side saturates"
        );
        assertEq(
            harness.liquidityForAmount1Saturating(sqrtB - 1, sqrtB, 1e18), type(uint128).max, "token1 side saturates"
        );

        // Away from the edge it is Uniswap's own number, unchanged.
        assertEq(
            harness.liquidityForAmount0Saturating(sqrtA, sqrtB, 1e18),
            LiquidityAmounts.getLiquidityForAmount0(sqrtA, sqrtB, 1e18),
            "token0 side matches upstream where upstream has an answer"
        );
        assertEq(
            harness.liquidityForAmount1Saturating(sqrtA, sqrtB, 1e18),
            LiquidityAmounts.getLiquidityForAmount1(sqrtA, sqrtB, 1e18),
            "token1 side matches upstream where upstream has an answer"
        );
    }

    function testFuzz_liquidityForAmount_onlyEverCapsUpstreamNeverContradictsIt(
        uint256 amountSeed,
        int256 lowSeed,
        int256 highSeed,
        bool isAmount0
    ) public view {
        // The docstring's whole claim is that the formula is Uniswap's and only the ceiling differs.
        // One branch used to break that, returning the ceiling where upstream returns zero, in the
        // regime where the two sqrt ratios multiply to less than the Q96 shift. So: wherever upstream
        // gives an answer below the ceiling, this must give exactly the same number.
        int24 lower = int24(bound(lowSeed, TickMath.MIN_TICK, TickMath.MAX_TICK - 1));
        int24 upper = int24(bound(highSeed, int256(lower) + 1, TickMath.MAX_TICK));
        uint256 amount = bound(amountSeed, 0, 1e30);

        uint160 sqrtA = TickMath.getSqrtRatioAtTick(lower);
        uint160 sqrtB = TickMath.getSqrtRatioAtTick(upper);

        // Upstream is called through the harness so its overflow revert can be caught rather than
        // skipped. Skipping on our own ceiling would hide the very case this is here for: the broken
        // branch returned the ceiling precisely where upstream answers.
        if (isAmount0) {
            uint128 mine = harness.liquidityForAmount0Saturating(sqrtA, sqrtB, amount);
            try harness.upstreamLiquidityForAmount0(sqrtA, sqrtB, amount) returns (uint128 theirs) {
                assertEq(mine, theirs, "token0 side must match upstream wherever upstream answers");
            } catch {
                assertEq(mine, type(uint128).max, "token0 side may only cap where upstream overflows");
            }
        } else {
            uint128 mine = harness.liquidityForAmount1Saturating(sqrtA, sqrtB, amount);
            try harness.upstreamLiquidityForAmount1(sqrtA, sqrtB, amount) returns (uint128 theirs) {
                assertEq(mine, theirs, "token1 side must match upstream wherever upstream answers");
            } catch {
                assertEq(mine, type(uint128).max, "token1 side may only cap where upstream overflows");
            }
        }
    }

    function testFuzz_liquidityForAmount_neverRevertsAnywhereUniswapCanPrice(
        uint256 amountSeed,
        int256 lowSeed,
        int256 highSeed,
        bool isAmount0
    ) public view {
        // The saturation threshold is itself a mulDiv, and a mulDiv reverts when its result does not
        // fit a uint256. Whether that is reachable is the sort of claim worth pinning rather than
        // arguing: this sweeps the whole tick range Uniswap can represent, at every balance from one
        // wei to a trillion tokens, and requires an answer every time.
        int24 lower = int24(bound(lowSeed, TickMath.MIN_TICK, TickMath.MAX_TICK - 1));
        int24 upper = int24(bound(highSeed, int256(lower) + 1, TickMath.MAX_TICK));
        uint256 amount = bound(amountSeed, 1, 1e30);

        uint160 sqrtA = TickMath.getSqrtRatioAtTick(lower);
        uint160 sqrtB = TickMath.getSqrtRatioAtTick(upper);

        if (isAmount0) harness.liquidityForAmount0Saturating(sqrtA, sqrtB, amount);
        else harness.liquidityForAmount1Saturating(sqrtA, sqrtB, amount);
    }

    function testFuzz_liquidityForAmount_matchesUpstreamWhereverUpstreamAnswers(
        uint256 amountSeed,
        uint16 widthSeed,
        bool isAmount0
    ) public view {
        uint256 amount = bound(amountSeed, 1, 1e24);
        int24 width = int24(int256(bound(uint256(widthSeed), 1, 20_000)));

        uint160 sqrtA = TickMath.getSqrtRatioAtTick(-width);
        uint160 sqrtB = TickMath.getSqrtRatioAtTick(width);

        // Saturation must change nothing except the ceiling. Wherever Uniswap returns a number, the
        // saturating version returns the same one.
        if (isAmount0) {
            uint128 upstream = LiquidityAmounts.getLiquidityForAmount0(sqrtA, sqrtB, amount);
            assertEq(harness.liquidityForAmount0Saturating(sqrtA, sqrtB, amount), upstream, "token0 side agrees");
        } else {
            uint128 upstream = LiquidityAmounts.getLiquidityForAmount1(sqrtA, sqrtB, amount);
            assertEq(harness.liquidityForAmount1Saturating(sqrtA, sqrtB, amount), upstream, "token1 side agrees");
        }
    }

    function testFuzz_solveSwap_neverPicksASwapWorseThanNotSwapping(
        int24 priceTick,
        int24 lowTick,
        uint16 widthSeed,
        uint256 budgetSeed,
        uint128 poolLiquiditySeed,
        bool zeroForOne,
        uint256 otherSeed
    ) public pure {
        // The same property over the whole parameter space the solver has to work in: any price,
        // any range, any pool depth, and balances from one wei to a trillion tokens.
        int24 lower = int24(bound(int256(lowTick), -30_000, 30_000));
        int24 upper = lower + int24(int256(bound(uint256(widthSeed), 1, 2000)));

        uint256 budget = bound(budgetSeed, 1e12, 1e24);
        uint256 other = bound(otherSeed, 0, 1e22);

        UniswapV3VaultMath.SwapParams memory params = UniswapV3VaultMath.SwapParams({
            sqrtPriceX96: TickMath.getSqrtRatioAtTick(int24(bound(int256(priceTick), -30_000, 30_000))),
            sqrtRatioAX96: TickMath.getSqrtRatioAtTick(lower),
            sqrtRatioBX96: TickMath.getSqrtRatioAtTick(upper),
            poolLiquidity: uint128(bound(uint256(poolLiquiditySeed), 1e18, 1e26)),
            feePips: 3000,
            amount0: zeroForOne ? budget : other,
            amount1: zeroForOne ? other : budget
        });

        (bool sells, uint256 amountIn) = UniswapV3VaultMath.solveSwap(params);
        if (amountIn == 0) return;

        assertGe(
            _mintableAfter(params, sells, amountIn),
            _mintableAfter(params, sells, 0),
            "the solver must never pick a swap that mints less than leaving the balances alone"
        );
    }

    //
    // Price band
    //

    function test_priceBand_bracketsThePriceItIsCentredOn() public pure {
        uint160 centre = TickMath.getSqrtRatioAtTick(0);
        (uint160 low, uint160 high) = UniswapV3VaultMath.priceBand(centre, 500);

        assertLt(low, centre, "the lower edge sits below the centre");
        assertGt(high, centre, "the upper edge sits above it");

        // The tolerance is on price, so each edge is the centre scaled by the square root of one
        // minus or plus it. A 500 basis point tolerance is a 2.53% move down and a 2.47% move up in
        // sqrt space, because the square root compresses both directions.
        assertApproxEqRel(uint256(low), uint256(centre) * 9747 / 10_000, 1e15, "lower edge");
        assertApproxEqRel(uint256(high), uint256(centre) * 10_247 / 10_000, 1e15, "upper edge");
    }

    function test_priceBand_isTighterForASmallerTolerance() public pure {
        uint160 centre = TickMath.getSqrtRatioAtTick(0);

        (uint160 tightLow, uint160 tightHigh) = UniswapV3VaultMath.priceBand(centre, 10);
        (uint160 wideLow, uint160 wideHigh) = UniswapV3VaultMath.priceBand(centre, 1000);

        assertGt(tightLow, wideLow, "a smaller tolerance stops the price falling as far");
        assertLt(tightHigh, wideHigh, "and stops it rising as far");
    }

    function test_priceBand_clampsToWhatUniswapCanRepresent() public pure {
        // A band that would run past either end of Uniswap's range is pinned to it, so the value
        // is always usable as a swap price limit.
        (uint160 low,) = UniswapV3VaultMath.priceBand(TickMath.MIN_SQRT_RATIO + 1, 10_000);
        assertGe(low, TickMath.MIN_SQRT_RATIO + 1, "lower edge stays inside the range");

        (, uint160 high) = UniswapV3VaultMath.priceBand(TickMath.MAX_SQRT_RATIO - 1, 10_000);
        assertLe(high, TickMath.MAX_SQRT_RATIO - 1, "upper edge stays inside the range");
    }

    //
    // Plans
    //

    function test_positionPlan_returnsNothingWhenThereIsNothingToMint() public pure {
        (uint128 liquidity, uint256 need0, uint256 need1) = UniswapV3VaultMath.positionPlan(
            TickMath.getSqrtRatioAtTick(0), TickMath.getSqrtRatioAtTick(-6000), TickMath.getSqrtRatioAtTick(6000), 0, 0
        );
        assertEq(liquidity, 0, "no liquidity");
        assertEq(need0 + need1, 0, "nothing required");
    }

    function test_counterAmount_pairsEitherSide() public pure {
        uint160 sqrtP = TickMath.getSqrtRatioAtTick(0);
        uint160 sqrtA = TickMath.getSqrtRatioAtTick(-6000);
        uint160 sqrtB = TickMath.getSqrtRatioAtTick(6000);

        uint256 need1 = UniswapV3VaultMath.counterAmount(sqrtP, sqrtA, sqrtB, 1000e18, true);
        assertGt(need1, 0, "token0 needs token1 alongside it");

        uint256 need0 = UniswapV3VaultMath.counterAmount(sqrtP, sqrtA, sqrtB, need1, false);

        // Pairing one side then the other must land back where it started, give or take the
        // rounding that always runs in the vault's favour.
        assertApproxEqRel(need0, 1000e18, 1e12, "the pairing round trips");
    }

    function test_createPlan_revertsWhenTheAmountBuysNoLiquidity() public {
        vm.expectRevert(IUniswapV3PositionVault.InvalidArguments.selector);
        UniswapV3VaultMath.createPlan(
            TickMath.getSqrtRatioAtTick(0),
            TickMath.getSqrtRatioAtTick(-6000),
            TickMath.getSqrtRatioAtTick(6000),
            0,
            true
        );
    }

    //
    // Helpers
    //

    /// @notice Liquidity the vault could mint after paying `amountIn` into the pool.
    /// @dev    Models the pool exactly as the solver does, so this is an independent replay of the
    ///         objective rather than a reimplementation of the search.
    function _mintableAfter(UniswapV3VaultMath.SwapParams memory params, bool zeroForOne, uint256 amountIn)
        internal
        pure
        returns (uint128)
    {
        if (amountIn == 0) {
            return UniswapV3VaultMath.mintableLiquidity(
                params.sqrtPriceX96, params.sqrtRatioAX96, params.sqrtRatioBX96, params.amount0, params.amount1
            );
        }

        uint256 net = FullMath.mulDiv(amountIn, 1e6 - params.feePips, 1e6);
        if (net == 0) return 0;

        uint160 sqrtAfter =
            SqrtPriceMath.getNextSqrtPriceFromInput(params.sqrtPriceX96, params.poolLiquidity, net, zeroForOne);

        uint256 balance0;
        uint256 balance1;
        if (zeroForOne) {
            uint256 out = SqrtPriceMath.getAmount1Delta(sqrtAfter, params.sqrtPriceX96, params.poolLiquidity, false);
            balance0 = params.amount0 - amountIn;
            balance1 = params.amount1 + out;
        } else {
            uint256 out = SqrtPriceMath.getAmount0Delta(params.sqrtPriceX96, sqrtAfter, params.poolLiquidity, false);
            balance0 = params.amount0 + out;
            balance1 = params.amount1 - amountIn;
        }

        return
            UniswapV3VaultMath.mintableLiquidity(
                sqrtAfter, params.sqrtRatioAX96, params.sqrtRatioBX96, balance0, balance1
            );
    }

    /// @notice One of the four tick spacings Uniswap v3 uses.
    function _spacing(uint8 choice) internal pure returns (int24) {
        uint8 index = choice % 4;
        if (index == 0) return 1;
        if (index == 1) return 10;
        if (index == 2) return 60;
        return 200;
    }
}
