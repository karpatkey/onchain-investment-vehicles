// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {ExactWatermarkFee} from "./ExactWatermarkFee.sol";

/// @title PeriodicWatermarkFee
/// @notice `ExactWatermarkFee` that charges at most once per `crystallizationPeriod`: a call before the
///         period has run since the watermark last moved charges nothing and leaves the watermark, and the first
///         call after it charges on whatever gain is above the watermark at that moment. A period of 0 charges at
///         every call, like `ExactWatermarkFee`, except at a rate change (below). Also the base for the hurdle,
///         benchmark and no-watermark modules, which take the same period.
/// @dev    Nothing accrues between charges. KpkShares prices subscriptions and redemptions at the operator's
///         price, which carries no pending performance fee, so an investor who redeems mid-period pays none
///         of that period's fee and one who subscribes mid-period pays it on gains made before they joined.
///         The longer the period, the larger both effects.
///
///         The period is rolling: it restarts whenever the watermark moves (a charge, the first seed, a fee that
///         rounds to 0, or `NoWatermarkFee`'s reset on a fall), so charges do not fall on fixed calendar dates.
///
///         A charge uses the lowest rate passed in since the fund last owed nothing: since the watermark last
///         moved, or since the last call that found the price at or below it (for `BenchmarkFee`, a due call that
///         found no outperformance). Every call counts, including one that changes nothing, so a raise never
///         reaches a gain made while a lower rate was in force, and a cut applies to every gain not yet charged.
///         A raise applies from the next time the fund owes nothing: KpkShares' rate-change call passes the
///         outgoing rate, so when that call charges a due period the next period runs at the new rate, but a raise
///         sent right after a charge leaves the period that charge began at the old rate. This holds at any
///         period, 0 included (pinned: test/WatermarkFeeVariants.t.sol::test_periodic_rateRaisedMidPeriod_chargesTheOldRate,
///         test/WatermarkFeeVariants.t.sol::test_periodic_raiseRightAfterACharge_chargesTheOldRate,
///         test/FeeStructures.t.sol::test_periodic_cutThenRaiseChargesTheLowestRate,
///         test/FeeStructures.t.sol::test_periodic_raiseWhenTheRateChangeCallChargesAppliesNextPeriod,
///         test/FeeStructures.t.sol::test_periodic_rateRecordRestartsOnceNothingIsOwed).
contract PeriodicWatermarkFee is ExactWatermarkFee {
    /// @notice Minimum time between two charges for the same fund, in seconds.
    uint256 public immutable crystallizationPeriod;

    /// @notice When each fund's watermark was last seeded or moved.
    mapping(address => uint256) public watermarkSetAt;

    /// @notice Lowest fee rate passed in since each fund last owed nothing, in basis points; 0 when no call has
    ///         passed one since.
    mapping(address => uint256) public periodRate;

    /// @param crystallizationPeriod_ Minimum time between two charges, in seconds; 0 for every call.
    constructor(uint256 crystallizationPeriod_) {
        crystallizationPeriod = crystallizationPeriod_;
    }

    /// @dev Lowers the fund's record to `feePct` if it is lower, and charges at the record.
    function _recordRate(uint256 feePct) internal override returns (uint256 rate) {
        rate = periodRate[msg.sender];
        if (rate == 0 || feePct < rate) periodRate[msg.sender] = rate = feePct;
    }

    /// @inheritdoc ExactWatermarkFee
    function _crystallize(uint256 sharesPrice, uint256 watermark, uint256 feePct, uint256 netSupply)
        internal
        override
        returns (uint256 fee, uint256 newWatermark)
    {
        uint256 elapsed = block.timestamp - watermarkSetAt[msg.sender];
        if (elapsed >= crystallizationPeriod) {
            (fee, newWatermark) = _crystallizeDue(sharesPrice, watermark, feePct, netSupply, elapsed);
            if (fee != 0 || newWatermark != watermark) return (fee, newWatermark);
        }
        // Nothing moves. If nothing is owed either, a later fee can only be on gains made after this call.
        if (_owesNothing(sharesPrice, watermark)) delete periodRate[msg.sender];
        return (0, watermark);
    }

    /// @dev Whether a call that moves nothing leaves no gain a later charge could include. Every fee here is a
    ///      share of the gain above the watermark, so a price at or below it owes nothing.
    function _owesNothing(uint256 sharesPrice, uint256 watermark) internal pure virtual returns (bool) {
        return sharesPrice <= watermark;
    }

    /// @dev `_crystallize` once the period has run, with the seconds since the watermark was last seeded or
    ///      moved as the last argument. Defaults to the plain high watermark, which ignores it.
    function _crystallizeDue(uint256 sharesPrice, uint256 watermark, uint256 feePct, uint256 netSupply, uint256)
        internal
        virtual
        returns (uint256 fee, uint256 newWatermark)
    {
        return ExactWatermarkFee._crystallize(sharesPrice, watermark, feePct, netSupply);
    }

    /// @dev Starts the period, and the hurdle clock, from every new watermark, and restarts the rate record.
    function _afterWatermarkSet() internal virtual override {
        watermarkSetAt[msg.sender] = block.timestamp;
        delete periodRate[msg.sender];
    }
}
