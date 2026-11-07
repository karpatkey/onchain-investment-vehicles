// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

import {IPerfFeeModule} from "./IPerfFeeModule.sol";

/// @title WatermarkFeeBase
/// @notice Per-fund state and call flow shared by the performance fee modules. A concrete module decides
///         whether a price owes a fee, how the fee becomes shares, and where the watermark lands afterwards.
/// @dev    Watermark state is keyed by `msg.sender` (the calling KpkShares proxy), so one deployment can
///         serve many funds, and a direct caller can only move its own slot.
///
///         The first call for a fund seeds the watermark at the price it is given and charges nothing.
///         That is the first price the module is shown, not the price investors entered at: KpkShares
///         only calls the module from a fee-module settlement more than `MIN_TIME_ELAPSED` after the
///         previous performance-fee update, or from `setPerformanceFeeRate`. Gains before that first
///         call are never charged, and if the fund is below its entry price at that moment, the recovery
///         back up to entry is charged.
///
///         `timeElapsed` does not enter the fee math; it is only re-emitted.
abstract contract WatermarkFeeBase is IPerfFeeModule {
    /// @notice Reference price per calling fund (keyed by `msg.sender`); 0 means not yet seeded. Which price
    ///         it records, and whether it can move down, depends on the concrete module.
    mapping(address => uint256) public highWatermark;

    /// @notice Price of each calling fund's last charge, as passed in (before the fee's dilution), while that
    ///         charge's watermark stands; 0 before any charge and after any watermark move without a charge. The
    ///         repeat-price skip compares against it.
    mapping(address => uint256) public lastChargedPrice;

    /// @notice Emitted when a fund's watermark is seeded or changes.
    /// @param fund         The calling fund (msg.sender).
    /// @param oldWatermark The previous watermark value.
    /// @param newWatermark The new watermark value.
    event WatermarkUpdated(address indexed fund, uint256 oldWatermark, uint256 newWatermark);

    /// @notice Emitted alongside every `WatermarkUpdated`, with `fee == 0` when the watermark is seeded or moves
    ///         without a charge. Not emitted when a call changes nothing.
    /// @param fund        The calling fund (msg.sender).
    /// @param fee         The performance fee in shares.
    /// @param sharesPrice The price per share passed in (8 decimals).
    /// @param timeElapsed The time elapsed since the last calculation (informational only).
    event PerformanceFeeCalculated(address indexed fund, uint256 fee, uint256 sharesPrice, uint256 timeElapsed);

    /// @inheritdoc IPerfFeeModule
    function calculatePerformanceFee(uint256 sharesPrice, uint256 timeElapsed, uint256 feePct, uint256 netSupply)
        external
        returns (uint256 fee)
    {
        uint256 watermark = highWatermark[msg.sender];
        uint256 newWatermark;
        if (watermark == 0) {
            // 0 is the "not seeded" marker, and is what KpkShares passes for a fee asset it has never settled.
            if (sharesPrice == 0 || !_canSeed()) return 0;
            newWatermark = sharesPrice;
        } else {
            // Before any skip: a skipped call is still a call made under the rate it passes.
            uint256 rate = _recordRate(feePct);
            // KpkShares records the operator's pre-fee price and `setPerformanceFeeRate` sends it back. A module that
            // leaves its watermark at the post-fee price would read that price as a new gain and charge its own fee's
            // dilution, so an exact repeat of the last charged price is skipped while that charge's watermark stands
            // (pinned: test/WatermarkFeeVariants.t.sol::test_rateChangeAfterACharge_mintsNothing). A genuine settlement
            // at that exact price is skipped too: deferred where the watermark only rises, but forgiven if
            // `NoWatermarkFee` resets or `BenchmarkFee`'s benchmark recovers before the next charge.
            if (sharesPrice == 0 || sharesPrice == lastChargedPrice[msg.sender]) return 0;
            (fee, newWatermark) = _crystallize(sharesPrice, watermark, rate, netSupply);
            if (fee == 0 && newWatermark == watermark) return 0;
        }
        highWatermark[msg.sender] = newWatermark;
        // Any later move without a charge retires the evidence (pinned: test/FeeStructures.t.sol::test_noWatermark_repeatAfterAResetIsCharged).
        lastChargedPrice[msg.sender] = fee != 0 ? sharesPrice : 0;
        _afterWatermarkSet(feePct);
        emit WatermarkUpdated(msg.sender, watermark, newWatermark);
        emit PerformanceFeeCalculated(msg.sender, fee, sharesPrice, timeElapsed);
    }

    /// @dev Called once the fund is seeded, for every non-zero price other than the last charged one. Returning
    ///      `(0, watermark)` makes the base store nothing and emit nothing. Not `view`, so a module may keep its
    ///      own records of what it read.
    /// @param sharesPrice  The current price per share (8 decimals).
    /// @param watermark    The fund's current watermark, never 0.
    /// @param feePct       The fee rate to charge at, in basis points, as `_recordRate` returned it.
    /// @param netSupply    totalSupply minus the fee receiver's balance.
    /// @return fee          Shares the caller mints to its fee receiver.
    /// @return newWatermark The watermark to store for the caller.
    function _crystallize(uint256 sharesPrice, uint256 watermark, uint256 feePct, uint256 netSupply)
        internal
        virtual
        returns (uint256 fee, uint256 newWatermark);

    /// @dev Whether a first call may seed the fund now; a `false` leaves it unseeded until a later call. Not
    ///      `view`, so a module may record what it read for the seed.
    function _canSeed() internal virtual returns (bool) {
        return true;
    }

    /// @dev Called on every call for a seeded fund, skipped ones included, with the rate passed in; returns the
    ///      rate to charge at. Defaults to the rate passed in.
    function _recordRate(uint256 feePct) internal virtual returns (uint256) {
        return feePct;
    }

    /// @dev Runs after a new watermark is stored for `msg.sender`, on seeding and on every change.
    /// @param feePct The fee rate passed in on the call that set the watermark.
    function _afterWatermarkSet(uint256 feePct) internal virtual {}
}
