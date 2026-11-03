// SPDX-License-Identifier: MIT
pragma solidity ^0.8;

import {kpkSharesNavTestBase} from "./kpkSharesNav.TestBase.sol";
import {KpkSharesNavLens} from "../src/periphery/KpkSharesNavLens.sol";

/// @title kpkSharesNavLensTest
/// @notice The lens must answer the question the fund refuses to answer, and never disagree with it.
/// @dev `getSharePriceUsd` is health-gated and REVERTS while the NAV is unhealthy. That is right for
///      settlement — minting against a price the contract cannot justify is the failure this design
///      exists to prevent — and useless for monitoring, because the moment an operator most needs to
///      read the fund is exactly the moment it will not answer.
///
///      So the lens has one hard requirement beyond "returns a number": its verdict must match the
///      gate. A monitor that drifts from the settlement path fails silently and in the worst
///      direction — a dashboard reporting healthy while every batch reverts. That is what
///      `testLensVerdictMatchesWhatSettlementActuallyDoes` pins, across every health signal.
contract kpkSharesNavLensTest is kpkSharesNavTestBase {
    KpkSharesNavLens internal lens;

    function setUp() public override {
        super.setUp();
        lens = new KpkSharesNavLens();
    }

    // ── The headline: it answers where the fund reverts ────────────────────────

    function testHealthyFundReportsTheSamePriceTheFundWouldUse() public {
        _seedFund(alice, 1_000e6);

        (uint256 price, bool healthy) = lens.sharePrice(address(fund));
        assertTrue(healthy, "a healthy fund should report healthy");
        assertEq(price, fund.getSharePriceUsd(), "lens price disagrees with the fund's own price");
    }

    /// @notice The case the fund cannot serve: unhealthy NAV.
    function testLensAnswersWhileTheFundReverts() public {
        _seedFund(alice, 1_000e6);
        nav.setSequencerDown(true);

        // The fund refuses, by design.
        vm.expectRevert();
        fund.getSharePriceUsd();

        // The lens answers.
        (uint256 price, bool healthy) = lens.sharePrice(address(fund));
        assertFalse(healthy, "should report unhealthy");
        assertEq(price, 0, "an unusable price must be reported as zero, never as a number");
    }

    /// @notice And it says WHICH signal is stopping it.
    function testNavStatusNamesTheSignal() public {
        _seedFund(alice, 1_000e6);
        nav.setSequencerDown(true);

        KpkSharesNavLens.FundStatus memory s = lens.navStatus(address(fund));
        assertTrue(s.answered, "the calculator did answer");
        assertFalse(s.canSettle, "cannot settle with the sequencer down");
        assertTrue(s.sequencerDown, "the responsible flag is not reported");
        assertFalse(s.quoteAssetStale, "an unrelated flag was raised");
        assertFalse(s.quoteAssetIrregular, "an unrelated flag was raised");
    }

    /// @notice A stale feed is reported by ASSET, not just as a count.
    /// @dev "Which feed is stale" is the question an operator has at 3am; a count sends them to
    ///      query the calculator by hand.
    function testNavStatusNamesTheOffendingAsset() public {
        _seedFund(alice, 1_000e6);
        nav.pushStaleAsset(address(usdc));

        KpkSharesNavLens.FundStatus memory s = lens.navStatus(address(fund));
        assertFalse(s.canSettle, "a stale touched asset must halt pricing");
        assertEq(s.stalePriceAssets.length, 1, "the stale asset was not reported");
        assertEq(s.stalePriceAssets[0], address(usdc), "the wrong asset was named");
        assertEq(s.irregularPriceAssets.length, 0, "an unrelated list was populated");
    }

    // ── The agreement invariant ────────────────────────────────────────────────

    /// @notice Across every health signal, `canSettle` equals what settlement actually does.
    /// @dev The load-bearing test. It does not check the lens against a re-implementation of the
    ///      gate — that would only prove two copies agree. It settles a real batch through
    ///      `processRequests` and asserts the lens predicted the outcome, so the two can only agree
    ///      by actually sharing one definition.
    function testLensVerdictMatchesWhatSettlementActuallyDoes() public {
        _seedFund(alice, 1_000e6);

        _assertLensPredictsSettlement("healthy");

        nav.setSequencerDown(true);
        _assertLensPredictsSettlement("sequencerDown");
        nav.setSequencerDown(false);

        nav.setQuoteAssetStale(true);
        _assertLensPredictsSettlement("quoteAssetStale");
        nav.setQuoteAssetStale(false);

        nav.setQuoteAssetIrregular(true);
        _assertLensPredictsSettlement("quoteAssetIrregular");
        nav.setQuoteAssetIrregular(false);

        nav.pushStaleAsset(address(usdc));
        _assertLensPredictsSettlement("stalePriceAssets");
        nav.clearTroubleArrays();

        nav.pushIrregularAsset(address(usdc));
        _assertLensPredictsSettlement("irregularPriceAssets");
        nav.clearTroubleArrays();

        nav.pushMonitorsUnhealthyAsset(address(usdc));
        _assertLensPredictsSettlement("monitorsUnhealthy");
        nav.clearTroubleArrays();

        // Back to healthy — proves the harness is not just reporting "false" throughout.
        _assertLensPredictsSettlement("recovered");
    }

    // ── Edge states ───────────────────────────────────────────────────────────

    /// @notice A fund with no shares can settle even while the NAV is unhealthy.
    /// @dev It prices the first subscription at its bootstrap price without reading the NAV at all,
    ///      so reporting `canSettle = false` here because the calculator is unwell would be wrong.
    function testBootstrappingFundCanSettleWithAnUnhealthyNav() public {
        nav.setSequencerDown(true);

        KpkSharesNavLens.FundStatus memory s = lens.navStatus(address(fund));
        assertEq(s.totalSupply, 0, "precondition: no shares yet");
        assertTrue(s.bootstrapping, "should report bootstrapping");
        assertTrue(s.canSettle, "a bootstrap mint does not read the NAV");
        assertEq(s.sharePriceUsd, ONE_USD, "should report the bootstrap price");
        assertTrue(s.sequencerDown, "the NAV's condition is still reported, just not decisive");
    }

    /// @notice A calculator that does not answer is distinct from one that answers "unhealthy".
    function testUnreachableCalculatorIsReportedAsUnanswered() public {
        _seedFund(alice, 1_000e6);
        nav.setNavReverts(true);

        KpkSharesNavLens.FundStatus memory s = lens.navStatus(address(fund));
        assertFalse(s.answered, "a reverting calculator must report answered = false");
        assertFalse(s.canSettle, "and must not be settleable");
        assertEq(s.navUsd, 0, "no NAV value should be claimed");
    }

    /// @notice A negative NAV halts pricing and is reported as the negative number it is.
    function testNegativeNavIsReportedAndBlocksSettlement() public {
        _seedFund(alice, 1_000e6);
        nav.setNavValue(-1);

        KpkSharesNavLens.FundStatus memory s = lens.navStatus(address(fund));
        assertTrue(s.answered, "the calculator answered");
        assertFalse(s.canSettle, "debts exceeding holdings has no honest share price");
        assertEq(s.navUsd, -1, "the reported NAV should be the signed value");
        assertEq(s.sharePriceUsd, 0, "no price should be offered");
    }

    // ── Asset-level introspection ─────────────────────────────────────────────

    /// @notice Listed and priceable are separate questions that fail independently.
    function testAssetStatusSeparatesListingFromPriceability() public {
        _seedFund(alice, 1_000e6);

        (bool canDeposit, bool canRedeem, bool priceable) = lens.assetStatus(address(fund), address(usdc));
        assertTrue(canDeposit, "USDC should be listed for deposit");
        assertTrue(canRedeem, "USDC should be listed for redemption");
        assertTrue(priceable, "USDC should be priceable");

        // The feed goes stale. The asset stays listed — nothing delists it — but it is no longer
        // priceable, which is exactly the split this function exists to surface.
        nav.setPriceStale(address(usdc), true);

        (canDeposit, canRedeem, priceable) = lens.assetStatus(address(fund), address(usdc));
        assertTrue(canDeposit, "a stale feed does not delist an asset");
        assertFalse(priceable, "a stale feed is not priceable");
    }

    // ── Helper ────────────────────────────────────────────────────────────────

    /// @dev Asks the lens whether the fund can settle, then actually tries to settle a real
    ///      subscription through `processRequests` and asserts the prediction held.
    function _assertLensPredictsSettlement(string memory label) internal {
        (, bool predicted) = lens.sharePrice(address(fund));

        vm.prank(bob);
        uint256 id = fund.requestSubscription(10e6, 1, address(usdc), bob);

        uint256[] memory approveIds = new uint256[](1);
        approveIds[0] = id;
        uint256[] memory none = new uint256[](0);

        vm.prank(ops);
        try fund.processRequests(approveIds, none, address(usdc)) {
            assertTrue(predicted, string.concat(label, ": settlement succeeded but the lens said it could not"));
        } catch {
            assertFalse(predicted, string.concat(label, ": settlement reverted but the lens said it could"));

            // Clear the request so the next case starts clean. A REJECTION, not a cancellation:
            // cancelling needs the request to be past its TTL, and a pure-rejection
            // `processRequests` skips the NAV read entirely — the liveness carve-out that lets an
            // operator always return escrow while the fund is unpriceable. So this also
            // incidentally proves that carve-out works in every unhealthy state swept here.
            uint256[] memory rejectIds = new uint256[](1);
            rejectIds[0] = id;
            vm.prank(ops);
            fund.processRequests(none, rejectIds, address(usdc));
        }
    }
}
