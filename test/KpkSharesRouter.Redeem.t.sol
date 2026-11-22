// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

import {KpkSharesRouterTestBase} from "test/KpkSharesRouter.TestBase.sol";
import {IKpkSharesRouter} from "src/periphery/IKpkSharesRouter.sol";
import {IkpkShares} from "src/IkpkShares.sol";
import {IAccessControl} from "@openzeppelin/contracts/access/IAccessControl.sol";

/// @notice Atomic redemption: payouts, the owner-intent authorisation model, and batch settlement.
contract KpkSharesRouterRedeemTest is KpkSharesRouterTestBase {
    uint256 internal constant SUBSCRIBED = 1000;

    function setUp() public virtual override {
        super.setUp();
        _routerSubscribeAndApproveShares(investor, _usdcAmount(SUBSCRIBED), SHARES_PRICE);
    }

    // ============================================================================
    // Happy path
    // ============================================================================

    function test_redeem_paysPreviewedAssetsToOwner() public {
        uint256 sharesIn = _sharesAmount(100);
        uint256 expected = kpkSharesContract.previewRedemption(sharesIn, SHARES_PRICE, address(usdc));
        uint256 balanceBefore = usdc.balanceOf(investor);

        (uint256 requestId, uint256 assetsOut) = _routerRedeem(investor, investorPk, sharesIn, SHARES_PRICE);

        assertEq(assetsOut, expected, "payout must equal the preview exactly");
        assertEq(usdc.balanceOf(investor) - balanceBefore, expected, "receiver must be paid");
        assertEq(
            uint8(kpkSharesContract.getRequest(requestId).requestStatus),
            uint8(IkpkShares.RequestStatus.PROCESSED),
            "request must end PROCESSED"
        );
    }

    function test_redeem_burnsNetSharesAndTransfersFeeShares() public {
        uint256 sharesIn = _sharesAmount(100);
        uint256 expectedFee = (sharesIn * REDEMPTION_FEE_RATE) / 10_000;

        uint256 supplyBefore = kpkSharesContract.totalSupply();
        uint256 feeReceiverBefore = kpkSharesContract.balanceOf(feeRecipient);

        _routerRedeem(investor, investorPk, sharesIn, SHARES_PRICE);

        assertEq(
            kpkSharesContract.balanceOf(feeRecipient) - feeReceiverBefore,
            expectedFee,
            "fee receiver must get the redemption fee in shares"
        );
        assertEq(
            supplyBefore - kpkSharesContract.totalSupply(),
            sharesIn - expectedFee,
            "only net shares are burned; fee shares stay outstanding"
        );
    }

    function test_redeem_paysDistinctReceiver() public {
        uint256 sharesIn = _sharesAmount(100);

        IKpkSharesRouter.RedemptionIntent memory intent = _intent(investor, address(usdc), sharesIn, 1);
        intent.receiver = carol;
        bytes memory intentSig = _signIntent(intent, investorPk);

        IKpkSharesRouter.NavAttestation memory nav = _nav(address(usdc), SHARES_PRICE);
        bytes memory navSig = _signNav(nav);

        uint256 carolBefore = usdc.balanceOf(carol);

        vm.prank(bot);
        (, uint256 assetsOut) = router.redeem(intent, intentSig, nav, navSig);

        assertEq(usdc.balanceOf(carol) - carolBefore, assetsOut, "named receiver must be paid");
    }

    function test_redeem_leavesRouterEmpty() public {
        _routerRedeem(investor, investorPk, _sharesAmount(100), SHARES_PRICE);

        assertEq(kpkSharesContract.balanceOf(address(router)), 0, "router must hold no shares");
        assertEq(usdc.balanceOf(address(router)), 0, "router must hold no assets");
    }

    function test_previewRedeem_matchesActualPayout() public {
        uint256 sharesIn = _sharesAmount(250);
        uint256 preview = router.previewRedeem(address(usdc), sharesIn, SHARES_PRICE);

        (, uint256 assetsOut) = _routerRedeem(investor, investorPk, sharesIn, SHARES_PRICE);

        assertEq(assetsOut, preview, "preview must match the settled payout");
    }

    // ============================================================================
    // Authorisation — the intent is what constrains the relayer
    // ============================================================================

    function test_redeem_revertsWhenRelayerFabricatesIntent() public {
        uint256 sharesIn = _sharesAmount(100);

        IKpkSharesRouter.RedemptionIntent memory intent = _intent(investor, address(usdc), sharesIn, 1);
        // The bot signs with its own key rather than the owner's.
        bytes memory forged = _signIntent(intent, rogueSignerPk);

        IKpkSharesRouter.NavAttestation memory nav = _nav(address(usdc), SHARES_PRICE);
        bytes memory navSig = _signNav(nav);

        vm.prank(bot);
        vm.expectRevert(IKpkSharesRouter.InvalidIntentSignature.selector);
        router.redeem(intent, forged, nav, navSig);
    }

    function test_redeem_revertsWhenCallerLacksRelayerRole() public {
        uint256 sharesIn = _sharesAmount(100);

        IKpkSharesRouter.RedemptionIntent memory intent = _intent(investor, address(usdc), sharesIn, 1);
        bytes memory intentSig = _signIntent(intent, investorPk);

        IKpkSharesRouter.NavAttestation memory nav = _nav(address(usdc), SHARES_PRICE);
        bytes memory navSig = _signNav(nav);

        // Read the role before pranking: a call in argument position consumes the pending prank.
        bytes32 relayerRole = router.RELAYER_ROLE();

        // Even the owner cannot drive their own intent: the relayer decides when, after liquidity lands.
        vm.prank(investor);
        vm.expectRevert(
            abi.encodeWithSelector(IAccessControl.AccessControlUnauthorizedAccount.selector, investor, relayerRole)
        );
        router.redeem(intent, intentSig, nav, navSig);
    }

    function test_redeem_revertsOnReplayedIntent() public {
        uint256 sharesIn = _sharesAmount(100);

        IKpkSharesRouter.RedemptionIntent memory intent = _intent(investor, address(usdc), sharesIn, 1);
        bytes memory intentSig = _signIntent(intent, investorPk);

        IKpkSharesRouter.NavAttestation memory nav = _nav(address(usdc), SHARES_PRICE);
        bytes memory navSig = _signNav(nav);

        vm.prank(bot);
        router.redeem(intent, intentSig, nav, navSig);

        IKpkSharesRouter.NavAttestation memory nav2 = _nav(address(usdc), SHARES_PRICE);
        bytes memory navSig2 = _signNav(nav2);

        vm.prank(bot);
        vm.expectRevert(abi.encodeWithSelector(IKpkSharesRouter.IntentAlreadyConsumed.selector, _intentDigest(intent)));
        router.redeem(intent, intentSig, nav2, navSig2);
    }

    function test_redeem_revertsAfterDeadline() public {
        uint256 sharesIn = _sharesAmount(100);

        IKpkSharesRouter.RedemptionIntent memory intent = _intent(investor, address(usdc), sharesIn, 1);
        bytes memory intentSig = _signIntent(intent, investorPk);

        skip(2 hours); // past the intent's 1-hour deadline

        IKpkSharesRouter.NavAttestation memory nav = _nav(address(usdc), SHARES_PRICE);
        bytes memory navSig = _signNav(nav);

        vm.prank(bot);
        vm.expectRevert(
            abi.encodeWithSelector(IKpkSharesRouter.IntentExpired.selector, intent.deadline, block.timestamp)
        );
        router.redeem(intent, intentSig, nav, navSig);
    }

    function test_redeem_revertsAfterOwnerBumpsEpoch() public {
        uint256 sharesIn = _sharesAmount(100);

        IKpkSharesRouter.RedemptionIntent memory intent = _intent(investor, address(usdc), sharesIn, 1);
        bytes memory intentSig = _signIntent(intent, investorPk);

        vm.prank(investor);
        uint256 newEpoch = router.bumpEpoch();

        IKpkSharesRouter.NavAttestation memory nav = _nav(address(usdc), SHARES_PRICE);
        bytes memory navSig = _signNav(nav);

        vm.prank(bot);
        vm.expectRevert(abi.encodeWithSelector(IKpkSharesRouter.IntentEpochMismatch.selector, intent.epoch, newEpoch));
        router.redeem(intent, intentSig, nav, navSig);
    }

    function test_redeem_revertsAfterCancelIntent() public {
        uint256 sharesIn = _sharesAmount(100);

        IKpkSharesRouter.RedemptionIntent memory intent = _intent(investor, address(usdc), sharesIn, 1);
        bytes memory intentSig = _signIntent(intent, investorPk);

        vm.prank(investor);
        router.cancelIntent(intent);

        assertTrue(router.isIntentConsumed(_intentDigest(intent)), "digest must be burned");

        IKpkSharesRouter.NavAttestation memory nav = _nav(address(usdc), SHARES_PRICE);
        bytes memory navSig = _signNav(nav);

        vm.prank(bot);
        vm.expectRevert(abi.encodeWithSelector(IKpkSharesRouter.IntentAlreadyConsumed.selector, _intentDigest(intent)));
        router.redeem(intent, intentSig, nav, navSig);
    }

    function test_cancelIntent_revertsForNonOwner() public {
        IKpkSharesRouter.RedemptionIntent memory intent = _intent(investor, address(usdc), _sharesAmount(100), 1);

        vm.prank(bob);
        vm.expectRevert(abi.encodeWithSelector(IKpkSharesRouter.NotIntentOwner.selector, investor, bob));
        router.cancelIntent(intent);
    }

    /// @dev Each tampered field must invalidate the signature, otherwise a compromised relayer could
    ///      resize the trade, move the destination, or settle at an arbitrary price.
    function test_redeem_revertsOnTamperedReceiver() public {
        (IKpkSharesRouter.RedemptionIntent memory intent, bytes memory sig) = _tamper(TamperField.Receiver);
        _expectTamperRejected(intent, sig);
    }

    function test_redeem_revertsOnTamperedSharesIn() public {
        (IKpkSharesRouter.RedemptionIntent memory intent, bytes memory sig) = _tamper(TamperField.SharesIn);
        _expectTamperRejected(intent, sig);
    }

    function test_redeem_revertsOnTamperedMinAssetsOut() public {
        (IKpkSharesRouter.RedemptionIntent memory intent, bytes memory sig) = _tamper(TamperField.MinAssetsOut);
        _expectTamperRejected(intent, sig);
    }

    function test_redeem_revertsOnIntentForDifferentFund() public {
        uint256 sharesIn = _sharesAmount(100);

        IKpkSharesRouter.RedemptionIntent memory intent = _intent(investor, address(usdc), sharesIn, 1);
        intent.fund = address(0xdead);
        bytes memory intentSig = _signIntent(intent, investorPk);

        IKpkSharesRouter.NavAttestation memory nav = _nav(address(usdc), SHARES_PRICE);
        bytes memory navSig = _signNav(nav);

        vm.prank(bot);
        vm.expectRevert(
            abi.encodeWithSelector(IKpkSharesRouter.FundMismatch.selector, address(kpkSharesContract), address(0xdead))
        );
        router.redeem(intent, intentSig, nav, navSig);
    }

    function test_redeem_revertsWhenBelowOwnerFloor() public {
        uint256 sharesIn = _sharesAmount(100);
        uint256 achievable = kpkSharesContract.previewRedemption(sharesIn, SHARES_PRICE, address(usdc));

        IKpkSharesRouter.RedemptionIntent memory intent = _intent(investor, address(usdc), sharesIn, achievable + 1);
        bytes memory intentSig = _signIntent(intent, investorPk);

        IKpkSharesRouter.NavAttestation memory nav = _nav(address(usdc), SHARES_PRICE);
        bytes memory navSig = _signNav(nav);

        vm.prank(bot);
        vm.expectRevert(
            abi.encodeWithSelector(IKpkSharesRouter.InsufficientOutput.selector, achievable, achievable + 1)
        );
        router.redeem(intent, intentSig, nav, navSig);
    }

    // ============================================================================
    // Batch
    // ============================================================================

    function test_redeemBatch_settlesEveryIntentInOneCall() public {
        _routerSubscribeAndApproveShares(investor2, _usdcAmount(SUBSCRIBED), SHARES_PRICE);

        uint256 sharesIn = _sharesAmount(50);

        IKpkSharesRouter.RedemptionIntent[] memory intents = new IKpkSharesRouter.RedemptionIntent[](2);
        bytes[] memory sigs = new bytes[](2);

        intents[0] = _intent(investor, address(usdc), sharesIn, 1);
        sigs[0] = _signIntent(intents[0], investorPk);
        intents[1] = _intent(investor2, address(usdc), sharesIn, 1);
        sigs[1] = _signIntent(intents[1], investor2Pk);

        IKpkSharesRouter.NavAttestation memory nav = _nav(address(usdc), SHARES_PRICE);
        bytes memory navSig = _signNav(nav);

        uint256 before1 = usdc.balanceOf(investor);
        uint256 before2 = usdc.balanceOf(investor2);

        vm.prank(bot);
        (uint256[] memory ids, uint256[] memory outs) = router.redeemBatch(intents, sigs, nav, navSig);

        assertEq(ids.length, 2, "both requests created");
        assertEq(usdc.balanceOf(investor) - before1, outs[0], "first owner paid");
        assertEq(usdc.balanceOf(investor2) - before2, outs[1], "second owner paid");

        for (uint256 i = 0; i < 2; i++) {
            assertEq(
                uint8(kpkSharesContract.getRequest(ids[i]).requestStatus),
                uint8(IkpkShares.RequestStatus.PROCESSED),
                "each request must end PROCESSED"
            );
        }
    }

    /// @notice One breaching floor unwinds the whole batch, and — critically — leaves no request
    ///         behind. This is the coupled-failure trade-off the batch entry point documents.
    function test_redeemBatch_oneBadIntentRevertsAllAndCreatesNoRequest() public {
        _routerSubscribeAndApproveShares(investor2, _usdcAmount(SUBSCRIBED), SHARES_PRICE);

        uint256 sharesIn = _sharesAmount(50);
        uint256 achievable = kpkSharesContract.previewRedemption(sharesIn, SHARES_PRICE, address(usdc));

        IKpkSharesRouter.RedemptionIntent[] memory intents = new IKpkSharesRouter.RedemptionIntent[](2);
        bytes[] memory sigs = new bytes[](2);

        intents[0] = _intent(investor, address(usdc), sharesIn, 1);
        sigs[0] = _signIntent(intents[0], investorPk);
        intents[1] = _intent(investor2, address(usdc), sharesIn, achievable + 1); // unsatisfiable
        sigs[1] = _signIntent(intents[1], investor2Pk);

        IKpkSharesRouter.NavAttestation memory nav = _nav(address(usdc), SHARES_PRICE);
        bytes memory navSig = _signNav(nav);

        uint256 requestIdBefore = kpkSharesContract.requestId();
        uint256 sharesBefore = kpkSharesContract.balanceOf(investor);

        vm.prank(bot);
        vm.expectRevert(
            abi.encodeWithSelector(IKpkSharesRouter.InsufficientOutput.selector, achievable, achievable + 1)
        );
        router.redeemBatch(intents, sigs, nav, navSig);

        assertEq(kpkSharesContract.requestId(), requestIdBefore, "no request may survive the revert");
        assertEq(kpkSharesContract.balanceOf(investor), sharesBefore, "first owner's shares untouched");
    }

    function test_redeemBatch_revertsOnMismatchedLengths() public {
        IKpkSharesRouter.RedemptionIntent[] memory intents = new IKpkSharesRouter.RedemptionIntent[](2);
        bytes[] memory sigs = new bytes[](1);

        IKpkSharesRouter.NavAttestation memory nav = _nav(address(usdc), SHARES_PRICE);
        bytes memory navSig = _signNav(nav);

        vm.prank(bot);
        vm.expectRevert(IKpkSharesRouter.InvalidBatch.selector);
        router.redeemBatch(intents, sigs, nav, navSig);
    }

    function test_redeemBatch_revertsOnEmptyBatch() public {
        IKpkSharesRouter.RedemptionIntent[] memory intents = new IKpkSharesRouter.RedemptionIntent[](0);
        bytes[] memory sigs = new bytes[](0);

        IKpkSharesRouter.NavAttestation memory nav = _nav(address(usdc), SHARES_PRICE);
        bytes memory navSig = _signNav(nav);

        vm.prank(bot);
        vm.expectRevert(IKpkSharesRouter.InvalidBatch.selector);
        router.redeemBatch(intents, sigs, nav, navSig);
    }

    // ============================================================================
    // Fund-side preconditions
    // ============================================================================

    /// @notice The payout is pulled from the portfolio Safe by the shares contract
    ///         (`kpkShares.sol:867`), so revoking that allowance fails the call closed with the
    ///         owner's shares intact.
    function test_redeem_revertsWhenSafeAllowanceRevoked() public {
        vm.prank(safe);
        usdc.approve(address(kpkSharesContract), 0);

        uint256 sharesBefore = kpkSharesContract.balanceOf(investor);
        uint256 requestIdBefore = kpkSharesContract.requestId();

        IKpkSharesRouter.RedemptionIntent memory intent = _intent(investor, address(usdc), _sharesAmount(100), 1);
        bytes memory intentSig = _signIntent(intent, investorPk);

        IKpkSharesRouter.NavAttestation memory nav = _nav(address(usdc), SHARES_PRICE);
        bytes memory navSig = _signNav(nav);

        vm.prank(bot);
        vm.expectRevert();
        router.redeem(intent, intentSig, nav, navSig);

        assertEq(kpkSharesContract.balanceOf(investor), sharesBefore, "owner keeps their shares");
        assertEq(kpkSharesContract.requestId(), requestIdBefore, "no request survives");
    }

    function test_redeem_revertsWhenSafeBalanceInsufficient() public {
        // Drain the Safe below the payout. Read the balance first, or it consumes the prank.
        uint256 safeBalance = usdc.balanceOf(safe);
        vm.prank(safe);
        usdc.transfer(bob, safeBalance);

        uint256 sharesBefore = kpkSharesContract.balanceOf(investor);

        IKpkSharesRouter.RedemptionIntent memory intent = _intent(investor, address(usdc), _sharesAmount(100), 1);
        bytes memory intentSig = _signIntent(intent, investorPk);

        IKpkSharesRouter.NavAttestation memory nav = _nav(address(usdc), SHARES_PRICE);
        bytes memory navSig = _signNav(nav);

        vm.prank(bot);
        vm.expectRevert();
        router.redeem(intent, intentSig, nav, navSig);

        assertEq(kpkSharesContract.balanceOf(investor), sharesBefore, "owner keeps their shares");
    }

    function test_redeem_revertsWhenOwnerHasNotApprovedRouter() public {
        vm.prank(investor);
        kpkSharesContract.approve(address(router), 0);

        IKpkSharesRouter.RedemptionIntent memory intent = _intent(investor, address(usdc), _sharesAmount(100), 1);
        bytes memory intentSig = _signIntent(intent, investorPk);

        IKpkSharesRouter.NavAttestation memory nav = _nav(address(usdc), SHARES_PRICE);
        bytes memory navSig = _signNav(nav);

        vm.prank(bot);
        vm.expectRevert();
        router.redeem(intent, intentSig, nav, navSig);
    }

    // ============================================================================
    // Holding period
    // ============================================================================

    function test_redeem_holdingPeriodBlocksImmediateRoundTrip() public {
        IKpkSharesRouter.AssetConfig memory config = _defaultConfig();
        config.minHoldingPeriod = 1 days;
        vm.prank(admin);
        router.setAssetConfig(address(usdc), config);

        // Fresh subscription stamps the clock.
        _routerSubscribeAndApproveShares(investor2, _usdcAmount(SUBSCRIBED), SHARES_PRICE);

        IKpkSharesRouter.RedemptionIntent memory intent = _intent(investor2, address(usdc), _sharesAmount(50), 1);
        bytes memory intentSig = _signIntent(intent, investor2Pk);

        IKpkSharesRouter.NavAttestation memory nav = _nav(address(usdc), SHARES_PRICE);
        bytes memory navSig = _signNav(nav);

        uint64 heldSince = router.sharesHeldSince(investor2);

        vm.prank(bot);
        vm.expectRevert(
            abi.encodeWithSelector(IKpkSharesRouter.HoldingPeriodNotElapsed.selector, heldSince, heldSince + 1 days)
        );
        router.redeem(intent, intentSig, nav, navSig);
    }

    function test_redeem_succeedsOnceHoldingPeriodElapsed() public {
        IKpkSharesRouter.AssetConfig memory config = _defaultConfig();
        config.minHoldingPeriod = 1 days;
        vm.prank(admin);
        router.setAssetConfig(address(usdc), config);

        _routerSubscribeAndApproveShares(investor2, _usdcAmount(SUBSCRIBED), SHARES_PRICE);

        skip(1 days + 1);

        (, uint256 assetsOut) = _routerRedeem(investor2, investor2Pk, _sharesAmount(50), SHARES_PRICE);
        assertGt(assetsOut, 0, "redemption must succeed after the holding period");
    }

    // ============================================================================
    // Helpers
    // ============================================================================

    enum TamperField {
        Receiver,
        SharesIn,
        MinAssetsOut
    }

    /// @dev Signs a clean intent, then mutates one field so the signature no longer matches.
    function _tamper(TamperField field)
        internal
        view
        returns (IKpkSharesRouter.RedemptionIntent memory tampered, bytes memory sig)
    {
        IKpkSharesRouter.RedemptionIntent memory clean = _intent(investor, address(usdc), _sharesAmount(100), 1);
        sig = _signIntent(clean, investorPk);

        tampered = clean;
        if (field == TamperField.Receiver) {
            tampered.receiver = bob;
        } else if (field == TamperField.SharesIn) {
            tampered.sharesIn = _sharesAmount(200);
        } else {
            tampered.minAssetsOut = 1e6;
        }
    }

    function _expectTamperRejected(IKpkSharesRouter.RedemptionIntent memory intent, bytes memory sig) internal {
        IKpkSharesRouter.NavAttestation memory nav = _nav(address(usdc), SHARES_PRICE);
        bytes memory navSig = _signNav(nav);

        vm.prank(bot);
        vm.expectRevert(IKpkSharesRouter.InvalidIntentSignature.selector);
        router.redeem(intent, sig, nav, navSig);
    }
}
