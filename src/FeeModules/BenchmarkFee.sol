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
///         benchmark carries forward: the watermark and B0 move together, only when a call charges a fee, finds no
///         investor shares, or charges a fee that rounds to 0 shares
///         (pinned: test/FeeStructures.t.sol::test_benchmark_underperformanceIsMadeUpBeforeTheNextFee).
/// @dev    With `requireAbsoluteGain` false, a fund that loses less than a falling benchmark is charged even
///         though its investors lost money. Setting it true also requires the price to be above the watermark
///         itself.
///
///         The benchmark must be in the same unit as the fund's price: a WETH-priced fund measured against an
///         ETH/USD feed is charged when ETH falls and its own price does not.
///
///         The feed is read when the call executes, while `sharesPrice` is whatever price the caller passes:
///         the operator's price, struck when the settlement was prepared, or on `setPerformanceFeeRate` the last
///         settled price. If the benchmark moves in between, the outperformance is mismeasured in either
///         direction by about `feePct` times that move.
///
///         A feed with no code, a reverting or malformed reply, an answer of 0 or less, or no update within
///         `maxStaleness` makes the call a no-op: no seeding, no charge, no state change. The fee is deferred,
///         not lost, since the watermark and its benchmark level stay put
///         (pinned: test/FeeStructures.t.sol::test_benchmark_unusableFeedDefersInsteadOfReverting).
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
        if (address(benchmark_).code.length == 0 || maxStaleness_ == 0) {
            revert InvalidBenchmark();
        }
        benchmark = benchmark_;
        maxStaleness = maxStaleness_;
        requireAbsoluteGain = requireAbsoluteGain_;
    }

    /// @dev Charges `feePct` of the gain above the benchmark-adjusted watermark, and records the level it measured
    ///      against whenever the watermark moves.
    function _crystallizeDue(uint256 sharesPrice, uint256 watermark, uint256 feePct, uint256 netSupply, uint256)
        internal
        override
        returns (uint256 fee, uint256 newWatermark)
    {
        uint256 level = _benchmarkLevel();
        if (level == 0) return (0, watermark);
        // Rounded up, in investors' favour.
        uint256 threshold = Math.mulDiv(watermark, level, benchmarkAtWatermark[msg.sender], Math.Rounding.Ceil);
        if (requireAbsoluteGain && threshold < watermark) threshold = watermark;
        if (sharesPrice <= threshold) return (0, watermark);
        (fee, newWatermark) = _sizeExact(sharesPrice, (sharesPrice - threshold) * feePct, netSupply);
        // Mirrors the base's no-op test, so B0 moves exactly when the base stores the new watermark.
        if (fee != 0 || newWatermark != watermark) benchmarkAtWatermark[msg.sender] = level;
    }

    /// @dev Seeding needs a benchmark level to measure from; records it.
    function _canSeed() internal override returns (bool) {
        uint256 level = _benchmarkLevel();
        if (level == 0) return false;
        benchmarkAtWatermark[msg.sender] = level;
        return true;
    }

    /// @dev The feed's latest answer, or 0 if it is unusable. A low-level call, because `try`/`catch` does not
    ///      catch a reply that fails to decode, which is what an address with no code returns.
    function _benchmarkLevel() internal view returns (uint256) {
        (bool ok, bytes memory data) =
            address(benchmark).staticcall(abi.encodeCall(AggregatorV3Interface.latestRoundData, ()));
        if (!ok || data.length < 160) return 0;
        (, int256 answer,, uint256 updatedAt,) = abi.decode(data, (uint80, int256, uint256, uint256, uint80));
        if (answer <= 0 || updatedAt > block.timestamp || block.timestamp - updatedAt > maxStaleness) return 0;
        return uint256(answer);
    }
}
