// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

import {ExactWatermarkFee} from "./ExactWatermarkFee.sol";

/// @title PeriodicWatermarkFee
/// @notice `ExactWatermarkFee` that charges at most once per `crystallizationPeriod`: a call before the
///         period has run since the watermark last moved charges nothing and leaves the watermark, and the first
///         call after it charges on whatever gain is above the watermark at that moment. A period of 0 charges at
///         every call, like `ExactWatermarkFee`, except for the rate rule below. Also the base for the hurdle,
///         benchmark and no-watermark modules, which take the same period.
/// @dev    Nothing accrues between charges. KpkShares prices subscriptions and redemptions at the operator's
///         price, which carries no pending performance fee, so an investor who redeems mid-period pays none
///         of that period's fee and one who subscribes mid-period pays it on gains made before they joined.
///         The longer the period, the larger both effects.
///
///         The period is rolling: it restarts whenever the watermark moves (a charge, the first seed, a fee that
///         rounds to 0, or `NoWatermarkFee`'s reset on a fall), so charges do not fall on fixed calendar dates.
///
///         Each period is charged at the lowest rate passed in during it. A period begins when the watermark
///         moves, and the call that moves it counts with the rate it passes; every later call counts too, including
///         one that changes nothing and one skipped as a repeat. Only a watermark move restarts the record, never a
///         price, because the price on KpkShares' rate-change call is the last settled one and can be stale. So a
///         raise does not reach a gain made while a lower rate was passed in, whatever price the rate-change call
///         carries, and a cut applies to the whole period it lands in. A raise applies from the first period that
///         begins after it: KpkShares' rate-change call passes the outgoing rate, so the period it begins by
///         charging, or the one a charge right before it began, still runs at the old rate. A period lasts until the
///         watermark next moves, so while the fund stays at or below its watermark a cut keeps applying. KpkShares
///         passes the outgoing rate only if that rate is above 0 and the asset given to `setPerformanceFeeRate` is a
///         fee asset; otherwise the module is not called and the outgoing rate is not recorded. This holds at any
///         period, 0 included (pinned: test/WatermarkFeeVariants.t.sol::test_periodic_rateRaisedMidPeriod_chargesTheOldRate,
///         test/WatermarkFeeVariants.t.sol::test_periodic_raiseRightAfterACharge_chargesTheOldRate,
///         test/WatermarkFeeVariants.t.sol::test_periodic_raiseWithAStaleSettledPrice_chargesTheOldRate,
///         test/FeeStructures.t.sol::test_periodic_cutThenRaiseChargesTheLowestRate,
///         test/FeeStructures.t.sol::test_periodic_raiseByAChargingRateChangeCallWaitsForTheNextPeriod,
///         test/FeeStructures.t.sol::test_periodic_cutByAChargingRateChangeCallAppliesNextPeriod,
///         test/FeeStructures.t.sol::test_periodic_cutBelowTheWatermarkLastsUntilTheWatermarkMoves,
///         test/FeeStructures.t.sol::test_periodic_seedRecordsItsRate,
///         test/FeeStructures.t.sol::test_periodic_zeroPeriodRaiseWaitsForTheNextCharge).
contract PeriodicWatermarkFee is ExactWatermarkFee {
    /// @notice Minimum time between two charges for the same fund, in seconds.
    uint256 public immutable crystallizationPeriod;

    /// @notice When each fund's watermark was last seeded or moved.
    mapping(address => uint256) public watermarkSetAt;

    /// @notice Lowest fee rate passed in since each fund's watermark last moved, counting the call that moved it,
    ///         in basis points; 0 before the fund is seeded.
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
        if (elapsed < crystallizationPeriod) return (0, watermark);
        return _crystallizeDue(sharesPrice, watermark, feePct, netSupply, elapsed);
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

    /// @dev Starts the period, and the hurdle clock, from every new watermark, and restarts the rate record at
    ///      the rate the moving call passed in.
    function _afterWatermarkSet(uint256 feePct) internal virtual override {
        watermarkSetAt[msg.sender] = block.timestamp;
        periodRate[msg.sender] = feePct;
    }
}
