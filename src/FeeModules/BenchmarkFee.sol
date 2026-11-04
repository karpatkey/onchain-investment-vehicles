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
///         A feed with no code, a reverting, short or malformed reply, a reply that needs more than
///         `FEED_GAS_LIMIT` gas, an answer of 0 or less, or no update within `maxStaleness` defers the fee: nothing is
///         seeded or charged, and the watermark and its benchmark level stay put, so the fee is not lost. (With a
///         period, the rate passed in is still recorded for the lowest-rate rule.) (pinned: test/FeeStructures.t.sol::test_benchmark_unusableFeedDefersInsteadOfReverting,
///         test/FeeStructures.t.sol::test_benchmark_codelessOrMalformedFeedDefers,
///         test/FeeStructures.t.sol::test_benchmark_gasBurningFeedDefers).
///
///         Only the ratio of two readings is used, so the feed's decimals do not matter.
contract BenchmarkFee is PeriodicWatermarkFee {
    /// @notice Gas the feed may use per read. A read that needs more counts as unusable, so a misbehaving feed
    ///         cannot consume the settlement's gas.
    uint256 public constant FEED_GAS_LIMIT = 100_000;

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

    /// @dev The feed's latest answer, or 0 if it is unusable. Raw `staticcall` with a fixed gas limit and a
    ///      five-word output buffer: `try`/`catch` cannot catch a reply that fails to decode (an address with no
    ///      code replies with nothing), and `abi.decode` range-checks the two `uint80` round ids, which are unused.
    function _benchmarkLevel() internal view returns (uint256) {
        address feed = address(benchmark);
        bytes4 selector = AggregatorV3Interface.latestRoundData.selector;
        uint256 gasLimit = FEED_GAS_LIMIT;
        bool ok;
        int256 answer;
        uint256 updatedAt;
        assembly ("memory-safe") {
            let ptr := mload(0x40)
            mstore(ptr, selector)
            ok := staticcall(gasLimit, feed, ptr, 4, ptr, 160)
            // A separate statement: Yul evaluates arguments right to left, so `returndatasize()` inside the same
            // expression would be read before the call.
            if lt(returndatasize(), 160) { ok := 0 }
            answer := mload(add(ptr, 32))
            updatedAt := mload(add(ptr, 96))
        }
        if (!ok || answer <= 0 || updatedAt > block.timestamp || block.timestamp - updatedAt > maxStaleness) return 0;
        return uint256(answer);
    }
}
