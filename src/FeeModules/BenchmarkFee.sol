// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {
    AggregatorV3Interface
} from "chainlink-brownie-contracts/contracts/src/v0.8/shared/interfaces/AggregatorV3Interface.sol";
import {PeriodicWatermarkFee} from "./PeriodicWatermarkFee.sol";

/// @title BenchmarkFee
/// @notice Fee on outperformance of a benchmark read from a Chainlink-style feed. The watermark is carried
///         forward at the benchmark's return: a fund whose watermark was set when the benchmark stood at B0
///         owes a fee only above `watermark * B / B0`, and `feePct` of the excess. A shortfall against the
///         benchmark carries forward, because the watermark and B0 only move together, when a call charges a
///         fee or finds no investor shares (pinned: test/FeeStructures.t.sol::test_benchmark_underperformanceIsMadeUpBeforeTheNextFee).
/// @dev    With `requireAbsoluteGain` false, a fund that loses less than a falling benchmark is charged even
///         though its investors lost money. Setting it true also requires the price to be above the watermark
///         itself.
///
///         A feed that reverts, answers 0 or less, or has not updated within `maxStaleness` makes the call a
///         no-op: no seeding, no charge, no state change. The fee is deferred, not lost, since the watermark
///         and its benchmark level stay put. Reverting instead would block the fund's settlements until the
///         feed recovered.
///
///         Only the ratio of two readings is used, so the feed's decimals do not matter.
contract BenchmarkFee is PeriodicWatermarkFee {
    /// @notice The benchmark feed.
    AggregatorV3Interface public immutable benchmark;

    /// @notice Oldest acceptable feed update, in seconds.
    uint256 public immutable maxStaleness;

    /// @notice Whether a fee also requires the price to be above the watermark, not only above the benchmark.
    bool public immutable requireAbsoluteGain;

    /// @notice Benchmark level when each fund's watermark was last seeded or moved.
    mapping(address => uint256) public benchmarkAtWatermark;

    error InvalidBenchmark();

    /// @param benchmark_             The benchmark feed.
    /// @param maxStaleness_          Oldest acceptable feed update, in seconds; not 0.
    /// @param requireAbsoluteGain_   Whether a fee also requires the price to be above the watermark.
    /// @param crystallizationPeriod_ Minimum time between two charges, in seconds; 0 for every call.
    constructor(
        AggregatorV3Interface benchmark_,
        uint256 maxStaleness_,
        bool requireAbsoluteGain_,
        uint256 crystallizationPeriod_
    ) PeriodicWatermarkFee(crystallizationPeriod_) {
        if (address(benchmark_) == address(0) || maxStaleness_ == 0) {
            revert InvalidBenchmark();
        }
        benchmark = benchmark_;
        maxStaleness = maxStaleness_;
        requireAbsoluteGain = requireAbsoluteGain_;
    }

    /// @dev Charges `feePct` of the gain above the benchmark-adjusted watermark.
    function _crystallizeDue(uint256 sharesPrice, uint256 watermark, uint256 feePct, uint256 netSupply, uint256)
        internal
        view
        override
        returns (uint256 fee, uint256 newWatermark)
    {
        uint256 level = _benchmarkLevel();
        if (level == 0) return (0, watermark);
        // Rounded up, in investors' favour.
        uint256 threshold = Math.mulDiv(watermark, level, benchmarkAtWatermark[msg.sender], Math.Rounding.Ceil);
        if (requireAbsoluteGain && threshold < watermark) threshold = watermark;
        if (sharesPrice <= threshold) return (0, watermark);
        return _sizeExact(sharesPrice, (sharesPrice - threshold) * feePct, netSupply);
    }

    /// @dev Seeding needs a benchmark level to measure from.
    function _canSeed() internal view override returns (bool) {
        return _benchmarkLevel() != 0;
    }

    /// @dev Records the benchmark level alongside every new watermark. Only reached after `_canSeed` or
    ///      `_crystallizeDue` read a usable level in this same call, so the level stored is non-zero provided
    ///      the feed answers alike twice in one transaction. A feed is trusted regardless: it sets the fee.
    function _afterWatermarkSet() internal override {
        super._afterWatermarkSet();
        benchmarkAtWatermark[msg.sender] = _benchmarkLevel();
    }

    /// @dev The feed's latest answer, or 0 if it is unusable.
    function _benchmarkLevel() internal view returns (uint256) {
        try benchmark.latestRoundData() returns (uint80, int256 answer, uint256, uint256 updatedAt, uint80) {
            if (answer <= 0 || updatedAt > block.timestamp || block.timestamp - updatedAt > maxStaleness) return 0;
            return uint256(answer);
        } catch {
            return 0;
        }
    }
}
