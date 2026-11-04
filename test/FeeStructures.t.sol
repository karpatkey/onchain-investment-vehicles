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

    function set(int256 answer_, uint256 updatedAt_) external {
        answer = answer_;
        updatedAt = updatedAt_;
    }

    function setDown(bool down_) external {
        down = down_;
    }

    function latestRoundData() external view returns (uint80, int256, uint256, uint256, uint80) {
        require(!down, "feed down");
        return (1, answer, updatedAt, updatedAt, 1);
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

    /// Asserts a charge of `a` per share at `price`.
    function _assertCharged(WatermarkFeeBase module, uint256 price, uint256 a, uint256 fee) internal view {
        assertEq(fee, S * a / (price - a), "fee shares");
        assertEq(module.highWatermark(fund), price - a, "watermark at the post-fee price");
    }

    function _assertUntouched(WatermarkFeeBase module, uint256 fee, uint256 watermark) internal view {
        assertEq(fee, 0, "no fee");
        assertEq(module.highWatermark(fund), watermark, "watermark unchanged");
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

    // ── No watermark ───────────────────────────────────────────────────────────────────────────────

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
        feed.set(2000e8, block.timestamp);
        m = new BenchmarkFee(AggregatorV3Interface(address(feed)), 1 days, requireAbsoluteGain, 0);
        _call(m, 1e8);
    }

    function test_benchmark_chargesOnlyTheOutperformance() public {
        (BenchmarkFee m, MockFeed feed) = _benchmark(false);
        feed.set(2200e8, block.timestamp); // benchmark +10%
        _assertCharged(m, 1.2e8, 0.02e8, _call(m, 1.2e8)); // 20% of 1.20 - 1.10
        assertEq(m.benchmarkAtWatermark(fund), 2200e8, "benchmark level moves with the watermark");
    }

    function test_benchmark_relativeChargesALoss_absoluteDoesNot() public {
        (BenchmarkFee relative, MockFeed feed) = _benchmark(false);
        feed.set(1600e8, block.timestamp); // benchmark -20%, fund -10%
        _assertCharged(relative, 0.9e8, 0.02e8, _call(relative, 0.9e8));

        (BenchmarkFee absolute, MockFeed feed2) = _benchmark(true);
        feed2.set(1600e8, block.timestamp);
        _assertUntouched(absolute, _call(absolute, 0.9e8), 1e8);
    }

    function test_benchmark_underperformanceIsMadeUpBeforeTheNextFee() public {
        (BenchmarkFee m, MockFeed feed) = _benchmark(false);
        feed.set(2400e8, block.timestamp); // benchmark +20%, fund +10%
        _assertUntouched(m, _call(m, 1.1e8), 1e8);
        _assertCharged(m, 1.25e8, 0.01e8, _call(m, 1.25e8)); // only 1.25 - 1.20 counts
    }

    function test_benchmark_unusableFeedDefersInsteadOfReverting() public {
        MockFeed feed = new MockFeed();
        feed.set(2000e8, block.timestamp);
        skip(2 days);
        BenchmarkFee m = new BenchmarkFee(AggregatorV3Interface(address(feed)), 1 days, false, 0);
        assertEq(_call(m, 1e8), 0);
        assertEq(m.highWatermark(fund), 0, "stale feed: not seeded");

        feed.set(2000e8, block.timestamp);
        _call(m, 1e8);
        assertEq(m.highWatermark(fund), 1e8, "fresh feed: seeded");

        feed.set(2000e8, block.timestamp - 2 days);
        _assertUntouched(m, _call(m, 1.5e8), 1e8);
        feed.set(0, block.timestamp);
        _assertUntouched(m, _call(m, 1.5e8), 1e8);
        feed.setDown(true);
        _assertUntouched(m, _call(m, 1.5e8), 1e8);

        feed.setDown(false);
        feed.set(2000e8, block.timestamp);
        _assertCharged(m, 1.5e8, 0.1e8, _call(m, 1.5e8)); // the deferred gain is still charged
    }

    function test_benchmark_rejectsMissingFeedOrZeroStaleness() public {
        AggregatorV3Interface feed = AggregatorV3Interface(address(new MockFeed()));
        vm.expectRevert(BenchmarkFee.InvalidBenchmark.selector);
        new BenchmarkFee(AggregatorV3Interface(address(0)), 1 days, false, 0);
        vm.expectRevert(BenchmarkFee.InvalidBenchmark.selector);
        new BenchmarkFee(feed, 0, false, 0);
    }
}
