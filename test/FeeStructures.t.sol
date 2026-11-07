// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

import {Test} from "forge-std/Test.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {
    AggregatorV3Interface
} from "chainlink-brownie-contracts/contracts/src/v0.8/shared/interfaces/AggregatorV3Interface.sol";
import {WatermarkFeeBase} from "src/FeeModules/WatermarkFeeBase.sol";
import {ExactWatermarkFee} from "src/FeeModules/ExactWatermarkFee.sol";
import {PeriodicWatermarkFee} from "src/FeeModules/PeriodicWatermarkFee.sol";
import {HardHurdleFee} from "src/FeeModules/HardHurdleFee.sol";
import {SoftHurdleFee} from "src/FeeModules/SoftHurdleFee.sol";
import {CatchUpHurdleFee} from "src/FeeModules/CatchUpHurdleFee.sol";
import {NoWatermarkFee} from "src/FeeModules/NoWatermarkFee.sol";
import {BenchmarkFee} from "src/FeeModules/BenchmarkFee.sol";

contract MockFeed {
    int256 public answer;
    uint256 public updatedAt;
    bool public down;
    uint8 public decimals = 8;

    function set(int256 answer_, uint256 updatedAt_) external {
        answer = answer_;
        updatedAt = updatedAt_;
    }

    function setDown(bool down_) external {
        down = down_;
    }

    function setDecimals(uint8 decimals_) external {
        decimals = decimals_;
    }

    function latestRoundData() external view returns (uint80, int256, uint256, uint256, uint80) {
        require(!down, "feed down");
        return (1, answer, updatedAt, updatedAt, 1);
    }
}

/// Answers `latestRoundData` with one word instead of five, which a `try`/`catch` cannot absorb.
contract ShortReplyFeed {
    fallback() external {
        assembly {
            mstore(0, 1)
            return(0, 32)
        }
    }
}

/// Answers with five well-formed words except round ids too wide for `uint80`, which `abi.decode` would reject.
contract WideRoundIdFeed {
    function decimals() external pure returns (uint8) {
        return 8;
    }

    fallback() external {
        bytes memory reply =
            abi.encode(uint256(1) << 100, int256(2000e8), block.timestamp, block.timestamp, uint256(1) << 100);
        assembly {
            return(add(reply, 32), mload(reply))
        }
    }
}

/// Never returns: spends whatever gas it is given.
contract GasBurnerFeed {
    fallback() external {
        while (true) {}
    }
}

/// Answers `latestRoundData` normally, then spends whatever gas `decimals()` is given.
contract DecimalsBurnerFeed {
    function latestRoundData() external view returns (uint80, int256, uint256, uint256, uint80) {
        return (1, 2000e8, block.timestamp, block.timestamp, 1);
    }

    function decimals() external pure returns (uint8) {
        while (true) {}
        return 8;
    }
}

/// Answers `latestRoundData` with only the first four of the five words, all well-formed, and `decimals()`
/// correctly, so only the reply-length check can reject it.
contract FourWordFeed {
    function decimals() external pure returns (uint8) {
        return 8;
    }

    fallback() external {
        bytes memory reply = abi.encode(uint256(1), int256(2000e8), block.timestamp, block.timestamp);
        assembly {
            return(add(reply, 32), mload(reply))
        }
    }
}

/// @notice The non-watermark fee structures, called directly as a fund whose 1,000 shares all belong to
///         investors. Every module here sizes fees exactly, so a per-share fee `a` at price P mints
///         a * S / (P - a) shares and leaves the watermark at P - a; the tests state `a` by hand.
contract FeeStructuresTest is Test {
    uint256 constant S = 1000e18;
    uint256 constant RATE = 2000; // 20%
    uint256 constant HURDLE = 1000; // 10% a year
    address fund = makeAddr("fund");

    function setUp() public {
        vm.mockCall(fund, abi.encodeWithSelector(IERC20.totalSupply.selector), abi.encode(S));
    }

    function _call(WatermarkFeeBase module, uint256 price) internal returns (uint256) {
        vm.prank(fund);
        return module.calculatePerformanceFee(price, 0, RATE, S);
    }

    function _callAt(WatermarkFeeBase module, uint256 price, uint256 rate) internal returns (uint256) {
        vm.prank(fund);
        return module.calculatePerformanceFee(price, 0, rate, S);
    }

    /// Asserts a charge of `a` per share at `price`.
    function _assertCharged(WatermarkFeeBase module, uint256 price, uint256 a, uint256 fee) internal view {
        assertEq(fee, S * a / (price - a), "fee shares");
        assertEq(module.highWatermark(fund), price - a, "watermark at the post-fee price");
    }

    function _assertUntouched(WatermarkFeeBase module, uint256 fee, uint256 watermark) internal view {
        assertEq(fee, 0, "no fee");
        assertEq(module.highWatermark(fund), watermark, "watermark unchanged");
    }

    // ── Shared guards ──────────────────────────────────────────────────────────────────────────────

    function test_zeroPrice_neitherSeedsNorResets() public {
        NoWatermarkFee m = new NoWatermarkFee(0);
        vm.recordLogs();
        assertEq(_call(m, 0), 0);
        assertEq(vm.getRecordedLogs().length, 0, "no seeding event at price 0");
        assertEq(m.watermarkSetAt(fund), 0, "period clock not started");

        _call(m, 1e8);
        _assertUntouched(m, _call(m, 0), 1e8); // a seeded reference does not fall to the 'unseeded' 0
    }

    function test_repeatOfTheLastChargedPriceIsSkipped() public {
        ExactWatermarkFee m = new ExactWatermarkFee();
        _call(m, 1e8);
        _assertCharged(m, 1.2e8, 0.04e8, _call(m, 1.2e8));
        _assertUntouched(m, _call(m, 1.2e8), 1.16e8); // the pre-fee price again, as setPerformanceFeeRate sends it
        _assertCharged(m, 1.21e8, 0.01e8, _call(m, 1.21e8)); // any other price is charged as usual
    }

    // ── Hard hurdle ─────────────────────────────────────────────────────────────────────────────────

    function test_hardHurdle_chargesOnlyTheGainAboveTheHurdle() public {
        HardHurdleFee m = new HardHurdleFee(HURDLE, 0);
        _call(m, 1e8);
        skip(365 days);
        _assertCharged(m, 1.2e8, 0.02e8, _call(m, 1.2e8)); // 20% of 1.20 - 1.10
    }

    function test_hardHurdle_keepsGrowingWhileBelowIt() public {
        HardHurdleFee m = new HardHurdleFee(HURDLE, 0);
        _call(m, 1e8);
        skip(365 days);
        _assertUntouched(m, _call(m, 1.1e8), 1e8); // exactly at the hurdle
        skip(365 days);
        _assertUntouched(m, _call(m, 1.15e8), 1e8); // two years in, the hurdle is 1.20
        _assertCharged(m, 1.25e8, 0.01e8, _call(m, 1.25e8)); // 20% of 1.25 - 1.20
    }

    // ── Soft hurdle ─────────────────────────────────────────────────────────────────────────────────

    function test_softHurdle_chargesTheWholeGainOnceCleared() public {
        SoftHurdleFee m = new SoftHurdleFee(HURDLE, 0);
        _call(m, 1e8);
        skip(365 days);
        _assertUntouched(m, _call(m, 1.09e8), 1e8);
        _assertCharged(m, 1.12e8, 0.024e8, _call(m, 1.12e8)); // 20% of 1.12 - 1.00, not of 1.12 - 1.10
    }

    // ── Catch-up ────────────────────────────────────────────────────────────────────────────────────

    function test_catchUp_takesTheExcessUntilTheFullRateIsReached() public {
        CatchUpHurdleFee m = new CatchUpHurdleFee(HURDLE, 10_000, 0);
        _call(m, 1e8);
        skip(365 days);
        _assertUntouched(m, _call(m, 1.09e8), 1e8);
        // 1.12: all 0.02 above the hurdle, which is still below 20% of the 0.12 gain.
        _assertCharged(m, 1.12e8, 0.02e8, _call(m, 1.12e8));
    }

    function test_catchUp_settlesAtTheFullRateAboveTheCatchUp() public {
        CatchUpHurdleFee m = new CatchUpHurdleFee(HURDLE, 10_000, 0);
        _call(m, 1e8);
        skip(365 days);
        // 1.20: 0.10 above the hurdle exceeds 20% of the 0.20 gain, so the fee is 0.04.
        _assertCharged(m, 1.2e8, 0.04e8, _call(m, 1.2e8));
    }

    function test_catchUp_rejectsAShareOutsideOneToTenThousand() public {
        vm.expectRevert(CatchUpHurdleFee.InvalidCatchUp.selector);
        new CatchUpHurdleFee(HURDLE, 0, 0);
        vm.expectRevert(CatchUpHurdleFee.InvalidCatchUp.selector);
        new CatchUpHurdleFee(HURDLE, 10_001, 0);
    }

    function test_catchUp_partialShareTakesThatShareOfTheExcess() public {
        CatchUpHurdleFee m = new CatchUpHurdleFee(HURDLE, 5000, 0);
        _call(m, 1e8);
        skip(365 days);
        // 1.12: half of the 0.02 above the hurdle, which is below 20% of the 0.12 gain.
        _assertCharged(m, 1.12e8, 0.01e8, _call(m, 1.12e8));
    }

    // ── Crystallization period ─────────────────────────────────────────────────────────────────────

    function test_periodic_chargesAtMostOncePerPeriod() public {
        PeriodicWatermarkFee m = new PeriodicWatermarkFee(365 days);
        _call(m, 1e8);
        skip(200 days);
        _assertUntouched(m, _call(m, 1.2e8), 1e8);
        skip(165 days);
        _assertCharged(m, 1.2e8, 0.04e8, _call(m, 1.2e8));
        skip(1 days);
        _assertUntouched(m, _call(m, 1.3e8), 1.16e8); // next period has only just started
    }

    function test_periodic_cutThenRaiseChargesTheLowestRate() public {
        PeriodicWatermarkFee m = new PeriodicWatermarkFee(365 days);
        _callAt(m, 1e8, 500); // seed under 5%
        skip(10 days);
        _callAt(m, 1e8, 500);
        skip(10 days);
        _callAt(m, 1.05e8, 200); // cut to 2%
        skip(100 days);
        _callAt(m, 1.1e8, 2000); // raised to 20%
        skip(250 days);
        _assertCharged(m, 1.2e8, 0.004e8, _callAt(m, 1.2e8, 2000)); // 2% of the 0.20 gain
    }

    function test_periodic_cutBelowTheWatermarkLastsUntilTheWatermarkMoves() public {
        PeriodicWatermarkFee m = new PeriodicWatermarkFee(90 days);
        _callAt(m, 1e8, 2000);
        skip(20 days);
        _callAt(m, 0.95e8, 100); // cut to 1% while below the watermark
        skip(10 days);
        _callAt(m, 0.95e8, 2000); // raised back, still below it
        skip(300 days);
        _assertCharged(m, 1.3e8, 0.003e8, _callAt(m, 1.3e8, 2000)); // still 1%: only a watermark move restarts it
        skip(91 days);
        _assertCharged(m, 1.4e8, 0.0206e8, _callAt(m, 1.4e8, 2000)); // the period that charge began, at 20%
    }

    function test_periodic_raiseByAChargingRateChangeCallWaitsForTheNextPeriod() public {
        PeriodicWatermarkFee m = new PeriodicWatermarkFee(365 days);
        _callAt(m, 1e8, 500);
        skip(366 days);
        // KpkShares' rate-change call: outgoing 5%, period due, so it charges and begins the next period at 5%.
        _assertCharged(m, 1.1e8, 0.005e8, _callAt(m, 1.1e8, 500));
        skip(1 hours);
        _callAt(m, 1.098e8, 2000); // the first settlement under the new 20%, above the watermark
        skip(366 days);
        _assertCharged(m, 1.3e8, 0.01025e8, _callAt(m, 1.3e8, 2000)); // 5% of 1.30 - 1.095
        skip(366 days);
        _assertCharged(m, 1.4e8, 0.02205e8, _callAt(m, 1.4e8, 2000)); // 20% of 1.40 - 1.28975
    }

    function test_periodic_cutByAChargingRateChangeCallAppliesNextPeriod() public {
        PeriodicWatermarkFee m = new PeriodicWatermarkFee(365 days);
        _callAt(m, 1e8, 2000);
        skip(366 days);
        // KpkShares' rate-change call: outgoing 20%, period due, so it charges the due period at 20%.
        _assertCharged(m, 1.1e8, 0.02e8, _callAt(m, 1.1e8, 2000));
        skip(1 hours);
        _callAt(m, 1.09e8, 500); // the first settlement under the new 5%
        skip(366 days);
        _assertCharged(m, 1.3e8, 0.011e8, _callAt(m, 1.3e8, 500)); // 5% of 1.30 - 1.08
    }

    function test_periodic_seedRecordsItsRate() public {
        PeriodicWatermarkFee m = new PeriodicWatermarkFee(365 days);
        _callAt(m, 1e8, 500); // seeded under 5%
        skip(366 days);
        _assertCharged(m, 1.1e8, 0.005e8, _callAt(m, 1.1e8, 2000)); // the period began under 5%
    }

    function test_periodic_zeroPeriodRaiseWaitsForTheNextCharge() public {
        PeriodicWatermarkFee m = new PeriodicWatermarkFee(0);
        _callAt(m, 1e8, 500);
        _callAt(m, 0.9e8, 500); // below the watermark: nothing to charge
        _assertCharged(m, 1.2e8, 0.01e8, _callAt(m, 1.2e8, 2000)); // 5%: the period began under 5%
        _assertCharged(m, 1.3e8, 0.022e8, _callAt(m, 1.3e8, 2000)); // 20% from the period that charge began
    }

    // ── No watermark ───────────────────────────────────────────────────────────────────────────────

    function test_noWatermark_repeatAfterAResetIsCharged() public {
        NoWatermarkFee m = new NoWatermarkFee(0);
        _call(m, 1e8);
        _assertCharged(m, 1.2e8, 0.04e8, _call(m, 1.2e8));
        _call(m, 1e8); // a fall resets the reference to 1.00
        _assertCharged(m, 1.2e8, 0.04e8, _call(m, 1.2e8)); // the same price is now a real 0.20 gain
    }

    function test_noWatermark_chargesTheRecoveryOfALoss() public {
        NoWatermarkFee m = new NoWatermarkFee(0);
        ExactWatermarkFee w = new ExactWatermarkFee();
        _call(m, 1e8);
        _call(w, 1e8);

        assertEq(_call(m, 0.9e8), 0, "no fee on a fall");
        assertEq(m.highWatermark(fund), 0.9e8, "reference follows the price down");
        _assertUntouched(w, _call(w, 0.9e8), 1e8);

        _assertCharged(m, 1e8, 0.02e8, _call(m, 1e8)); // 20% of the 0.10 recovery
        _assertUntouched(w, _call(w, 1e8), 1e8); // a watermark charges nothing back at 1.00
    }

    // ── Benchmark ──────────────────────────────────────────────────────────────────────────────────

    function _benchmark(bool requireAbsoluteGain) internal returns (BenchmarkFee m, MockFeed feed) {
        feed = new MockFeed();
        feed.set(2000e8, vm.getBlockTimestamp());
        m = new BenchmarkFee(AggregatorV3Interface(address(feed)), 1 days, requireAbsoluteGain, 0);
        _call(m, 1e8);
    }

    function test_benchmark_chargesOnlyTheOutperformance() public {
        (BenchmarkFee m, MockFeed feed) = _benchmark(false);
        feed.set(2200e8, vm.getBlockTimestamp()); // benchmark +10%
        _assertCharged(m, 1.2e8, 0.02e8, _call(m, 1.2e8)); // 20% of 1.20 - 1.10
        assertEq(m.benchmarkAtWatermark(fund), 2200e8, "benchmark level moves with the watermark");
    }

    function test_benchmark_relativeChargesALoss_absoluteDoesNot() public {
        (BenchmarkFee relative, MockFeed feed) = _benchmark(false);
        feed.set(1600e8, vm.getBlockTimestamp()); // benchmark -20%, fund -10%
        _assertCharged(relative, 0.9e8, 0.02e8, _call(relative, 0.9e8));

        (BenchmarkFee absolute, MockFeed feed2) = _benchmark(true);
        feed2.set(1600e8, vm.getBlockTimestamp());
        _assertUntouched(absolute, _call(absolute, 0.9e8), 1e8);
    }

    function test_benchmark_underperformanceIsMadeUpBeforeTheNextFee() public {
        (BenchmarkFee m, MockFeed feed) = _benchmark(false);
        feed.set(2400e8, vm.getBlockTimestamp()); // benchmark +20%, fund +10%
        _assertUntouched(m, _call(m, 1.1e8), 1e8);
        _assertCharged(m, 1.25e8, 0.01e8, _call(m, 1.25e8)); // only 1.25 - 1.20 counts
    }

    function test_benchmark_unusableFeedDefersInsteadOfReverting() public {
        MockFeed feed = new MockFeed();
        feed.set(2000e8, vm.getBlockTimestamp());
        skip(2 days);
        BenchmarkFee m = new BenchmarkFee(AggregatorV3Interface(address(feed)), 1 days, false, 0);
        assertEq(_call(m, 1e8), 0);
        assertEq(m.highWatermark(fund), 0, "stale feed: not seeded");

        feed.set(2000e8, vm.getBlockTimestamp());
        _call(m, 1e8);
        assertEq(m.highWatermark(fund), 1e8, "fresh feed: seeded");

        feed.set(2000e8, vm.getBlockTimestamp() - 2 days);
        _assertUntouched(m, _call(m, 1.5e8), 1e8);
        feed.set(0, vm.getBlockTimestamp());
        _assertUntouched(m, _call(m, 1.5e8), 1e8);
        feed.setDown(true);
        _assertUntouched(m, _call(m, 1.5e8), 1e8);

        feed.setDown(false);
        feed.set(2000e8, vm.getBlockTimestamp());
        _assertCharged(m, 1.5e8, 0.1e8, _call(m, 1.5e8)); // the deferred gain is still charged
    }

    function test_benchmark_negativeOrFutureAnswerDefers() public {
        MockFeed feed = new MockFeed();
        BenchmarkFee m = new BenchmarkFee(AggregatorV3Interface(address(feed)), 1 days, false, 0);
        feed.set(-1, vm.getBlockTimestamp());
        assertEq(_call(m, 1e8), 0);
        assertEq(m.highWatermark(fund), 0, "negative answer: not seeded");
        feed.set(2000e8, vm.getBlockTimestamp() + 1);
        assertEq(_call(m, 1e8), 0);
        assertEq(m.highWatermark(fund), 0, "future update: not seeded");

        feed.set(2000e8, vm.getBlockTimestamp());
        _call(m, 1e8);
        feed.set(2000e8, vm.getBlockTimestamp() + 1);
        _assertUntouched(m, _call(m, 1.5e8), 1e8);
        feed.set(-1, vm.getBlockTimestamp());
        _assertUntouched(m, _call(m, 1.5e8), 1e8);
    }

    function test_benchmark_codelessOrMalformedFeedDefers() public {
        (BenchmarkFee m, MockFeed feed) = _benchmark(false);
        vm.etch(address(feed), hex""); // the feed loses its code after deployment
        _assertUntouched(m, _call(m, 1.5e8), 1e8);
        vm.etch(address(feed), address(new ShortReplyFeed()).code);
        _assertUntouched(m, _call(m, 1.5e8), 1e8);
    }

    function test_benchmark_rejectsCodelessFeedOrZeroStaleness() public {
        AggregatorV3Interface feed = AggregatorV3Interface(address(new MockFeed()));
        vm.expectRevert(BenchmarkFee.InvalidBenchmark.selector);
        new BenchmarkFee(AggregatorV3Interface(address(0)), 1 days, false, 0);
        vm.expectRevert(BenchmarkFee.InvalidBenchmark.selector);
        new BenchmarkFee(AggregatorV3Interface(makeAddr("noCode")), 1 days, false, 0);
        vm.expectRevert(BenchmarkFee.InvalidBenchmark.selector);
        new BenchmarkFee(feed, 0, false, 0);
    }

    function test_benchmark_fourWordReplyDefers() public {
        (BenchmarkFee m, MockFeed feed) = _benchmark(false);
        vm.etch(address(feed), address(new FourWordFeed()).code);
        _assertUntouched(m, _call(m, 1.5e8), 1e8);
    }

    function test_benchmark_wideRoundIdIsReadNotReverted() public {
        (BenchmarkFee m, MockFeed feed) = _benchmark(false);
        vm.etch(address(feed), address(new WideRoundIdFeed()).code); // level unchanged at 2000
        _assertCharged(m, 1.5e8, 0.1e8, _call(m, 1.5e8));
    }

    function test_benchmark_gasBurningFeedDefers() public {
        (BenchmarkFee m, MockFeed feed) = _benchmark(false);
        vm.etch(address(feed), address(new GasBurnerFeed()).code);
        uint256 before = gasleft();
        vm.prank(fund);
        uint256 fee = m.calculatePerformanceFee{gas: 1_000_000}(1.5e8, 0, RATE, S);
        assertLt(before - gasleft(), 200_000, "the feed spends at most its gas limit");
        _assertUntouched(m, fee, 1e8);
    }

    function test_benchmark_gasBurningDecimalsDefers() public {
        (BenchmarkFee m, MockFeed feed) = _benchmark(false);
        vm.etch(address(feed), address(new DecimalsBurnerFeed()).code);
        uint256 before = gasleft();
        vm.prank(fund);
        uint256 fee = m.calculatePerformanceFee{gas: 1_000_000}(1.5e8, 0, RATE, S);
        assertLt(before - gasleft(), 250_000, "the second call is capped too");
        _assertUntouched(m, fee, 1e8);
    }

    function test_benchmark_moveWithoutAChargeRecordsTheLevel() public {
        (BenchmarkFee m, MockFeed feed) = _benchmark(false);
        feed.set(2200e8, vm.getBlockTimestamp());
        vm.prank(fund);
        assertEq(m.calculatePerformanceFee(1.2e8, 0, RATE, 0), 0); // no investor shares: moves, charges nothing
        assertEq(m.highWatermark(fund), 1.2e8);
        assertEq(m.benchmarkAtWatermark(fund), 2200e8, "B0 moves with the watermark");
    }

    function test_benchmark_rateRaisedDuringAnOutageDoesNotReachTheDeferredGain() public {
        (BenchmarkFee m, MockFeed feed) = _benchmark(false);
        feed.setDown(true);
        _assertUntouched(m, _callAt(m, 1.2e8, 1000), 1e8); // the rate-change call, outgoing 10%: deferred
        feed.setDown(false);
        _assertCharged(m, 1.2e8, 0.02e8, _callAt(m, 1.2e8, 2000)); // 10% of the 0.20 outperformance, not 20%
    }

    function test_benchmark_cutWhileTrailingLastsUntilTheWatermarkMoves() public {
        (BenchmarkFee m, MockFeed feed) = _benchmark(false);
        feed.set(2400e8, vm.getBlockTimestamp()); // benchmark +20%: the threshold is 1.20
        _callAt(m, 1.1e8, 100); // cut to 1% while trailing the benchmark
        _callAt(m, 1.1e8, 2000); // raised back, still trailing it
        _assertCharged(m, 1.5e8, 0.003e8, _callAt(m, 1.5e8, 2000)); // still 1% of 1.50 - 1.20
    }

    function test_benchmark_lowerRateHoldsWhileOutperformanceIsOwedBelowTheWatermark() public {
        MockFeed feed = new MockFeed();
        feed.set(2000e8, vm.getBlockTimestamp());
        BenchmarkFee m = new BenchmarkFee(AggregatorV3Interface(address(feed)), 1 days, false, 90 days);
        _call(m, 1e8);
        skip(10 days);
        _callAt(m, 0.9e8, 100); // benchmark -20%, fund -10%: outperformance owed at a price below the watermark
        skip(10 days);
        _callAt(m, 0.9e8, 2000);
        skip(80 days);
        feed.set(1600e8, vm.getBlockTimestamp());
        _assertCharged(m, 0.9e8, 0.001e8, _callAt(m, 0.9e8, 2000)); // 1% of 0.90 - 0.80
    }

    function test_benchmark_decimalsChangeDefers() public {
        (BenchmarkFee m, MockFeed feed) = _benchmark(false);
        feed.setDecimals(6);
        feed.set(2000e6, vm.getBlockTimestamp()); // the same level at a smaller scale would read as a 99% fall
        _assertUntouched(m, _call(m, 1.5e8), 1e8);
        feed.setDecimals(8);
        feed.set(2000e8, vm.getBlockTimestamp());
        _assertCharged(m, 1.5e8, 0.1e8, _call(m, 1.5e8)); // the deferred gain is still charged
    }

    function test_benchmark_absurdAnswerDefers() public {
        MockFeed feed = new MockFeed();
        feed.set(4000, vm.getBlockTimestamp()); // a low-scale index level
        BenchmarkFee m = new BenchmarkFee(AggregatorV3Interface(address(feed)), 1 days, false, 0);
        _call(m, 1e8);
        feed.set(type(int256).max, vm.getBlockTimestamp()); // watermark * level / 4000 would not fit in 256 bits
        _assertUntouched(m, _call(m, 1.5e8), 1e8);
    }
}
