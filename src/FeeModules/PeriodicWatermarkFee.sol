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
///         rounds to 0, no investor shares, or `NoWatermarkFee`'s reset on a fall), so charges do not fall on fixed
///         calendar dates.
///
///         A charge uses the lowest rate passed in during the period it ends or the period before. A period begins
///         when the watermark moves, and the call that moves it counts with the rate it passes; every later call
///         counts too, including one that changes nothing and one skipped as a repeat. Only a watermark move
///         restarts the record, never a price. The previous period counts because a call's price can lag the fund:
///         KpkShares passes the last settled price on a rate change, and an operator strikes a settlement's price
///         before it executes. A gain that a moving call's price does not yet show was made under the rates of the
///         period that call ends, and is charged in the next one. So, for any lag shorter than a period, a raise
///         does not reach a gain made while a lower rate was passed in, and a cut sent mid-period applies to the
///         period it lands in and the next one. A raise applies from the second period that begins after it: sent
///         mid-period, right after a charge, or by a rate-change call that charges nothing, the next two charges use
///         the old rate; sent by a rate-change call that charges a due period, that call's charge and the next two
///         do, because the call passes the outgoing rate and begins the next period before the raise takes effect.
///         A period lasts until the watermark next moves, so a cut keeps applying while the watermark stands.
///         KpkShares passes the outgoing rate only if that rate is above 0 and the asset given to
///         `setPerformanceFeeRate` is a fee asset; otherwise the module is not called and the outgoing rate is not
///         recorded. This holds at any period, 0 included (pinned: test/WatermarkFeeVariants.t.sol::test_periodic_rateRaisedMidPeriod_chargesTheOldRate,
///         test/WatermarkFeeVariants.t.sol::test_periodic_raiseRightAfterACharge_chargesTheOldRate,
///         test/WatermarkFeeVariants.t.sol::test_periodic_raiseWithAStaleSettledPrice_chargesTheOldRate,
///         test/WatermarkFeeVariants.t.sol::test_periodic_twoRateChangesBeforeASettlement_chargeTheLowerRate,
///         test/FeeStructures.t.sol::test_periodic_cutThenRaiseChargesTheLowestRate,
///         test/FeeStructures.t.sol::test_periodic_raiseByAChargingRateChangeCallWaitsThreeCharges,
///         test/FeeStructures.t.sol::test_periodic_cutByAChargingRateChangeCallAppliesNextPeriod,
///         test/FeeStructures.t.sol::test_periodic_cutBelowTheWatermarkLastsAnotherPeriod,
///         test/FeeStructures.t.sol::test_periodic_settlementPricedBeforeARaiseKeepsTheOldRate,
///         test/FeeStructures.t.sol::test_periodic_skippedRepeatStillRecordsItsRate,
///         test/FeeStructures.t.sol::test_periodic_seedRecordsItsRate,
///         test/FeeStructures.t.sol::test_periodic_zeroPeriodRaiseWaitsTwoCharges).
contract PeriodicWatermarkFee is ExactWatermarkFee {
    /// @notice Minimum time between two charges for the same fund, in seconds.
    uint256 public immutable crystallizationPeriod;

    /// @notice When each fund's watermark was last seeded or moved.
    mapping(address => uint256) public watermarkSetAt;

    /// @notice Lowest fee rate passed in since each fund's watermark last moved, counting the call that moved it,
    ///         in basis points; 0 before the fund is seeded.
    mapping(address => uint256) public periodRate;

    /// @notice Lowest fee rate passed in during each fund's previous period, in basis points; at the seed, the
    ///         seed's rate.
    mapping(address => uint256) public previousPeriodRate;

    /// @param crystallizationPeriod_ Minimum time between two charges, in seconds; 0 for every call.
    constructor(uint256 crystallizationPeriod_) {
        crystallizationPeriod = crystallizationPeriod_;
    }

    /// @dev Lowers this period's record to `feePct` if it is lower, and charges at the lower of this period's and
    ///      the previous period's record.
    function _recordRate(uint256 feePct) internal override returns (uint256 rate) {
        rate = periodRate[msg.sender];
        if (feePct < rate) periodRate[msg.sender] = rate = feePct;
        uint256 previous = previousPeriodRate[msg.sender];
        if (previous < rate) rate = previous;
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

    /// @dev Starts the period, and the hurdle clock, from every new watermark. The closing period's record, which
    ///      includes the moving call's rate, becomes the previous one, and the new period's record starts at the
    ///      moving call's rate; at the seed there is no closing period, so both start there.
    function _afterWatermarkSet(uint256 feePct) internal virtual override {
        watermarkSetAt[msg.sender] = block.timestamp;
        uint256 closing = periodRate[msg.sender];
        previousPeriodRate[msg.sender] = closing == 0 ? feePct : closing;
        periodRate[msg.sender] = feePct;
    }
}
