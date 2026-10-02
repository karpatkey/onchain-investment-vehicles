// SPDX-License-Identifier: MIT
pragma solidity ^0.8;

import {kpkSharesNavTestBase} from "./kpkSharesNav.TestBase.sol";
import {IKpkSharesNav} from "../src/IKpkSharesNav.sol";

/// @notice Request lifecycle, redemptions, and the removal of the price-deviation constraint.
contract kpkSharesNavRequestsTest is kpkSharesNavTestBase {
    //
    // The 30% deviation constraint is gone
    //

    /// @dev `KpkShares` rejects any settlement more than 30% away from the last settled price
    ///      (`MAX_PRICE_DEVIATION_BPS = 3000`). That guard existed to bound an operator-supplied
    ///      price; with the price derived from the NAV there is nothing to bound, so a move of any
    ///      size must settle.
    function testSettlesAcrossAMoveFarBeyondThirtyPercent() public {
        _seedFund(alice, 1_000e6);
        assertEq(fund.lastSharePriceUsd(), ONE_USD);

        // A 10x jump — more than three times the old limit
        nav.setNavValue(int256(10_000 * 1e8));

        vm.prank(bob);
        uint256 id = fund.requestSubscription(1_000e6, 1, address(usdc), bob);
        _approve(id);

        assertEq(fund.lastSharePriceUsd(), 10 * ONE_USD);
        assertEq(fund.balanceOf(bob), 100e18, "1,000 USDC at $10.00/share");
    }

    function testSettlesAcrossACollapseFarBeyondThirtyPercent() public {
        _seedFund(alice, 1_000e6);

        // A 95% drawdown
        nav.setNavValue(int256(50 * 1e8));

        vm.prank(bob);
        uint256 id = fund.requestSubscription(1_000e6, 1, address(usdc), bob);
        _approve(id);

        assertEq(fund.lastSharePriceUsd(), ONE_USD / 20);
        assertEq(fund.balanceOf(bob), 20_000e18, "1,000 USDC at $0.05/share");
    }

    //
    // Slippage bounds skip rather than revert the batch
    //

    /// @dev With an operator-supplied price an unmet bound could be cleared by submitting a better
    ///      price. The NAV cannot be re-priced, so reverting would let one request brick every batch
    ///      containing it. It is skipped and left PENDING instead.
    function testUnmetSlippageBoundSkipsWithoutRevertingTheBatch() public {
        _seedFund(alice, 1_000e6);

        vm.prank(bob);
        uint256 greedy = fund.requestSubscription(1_000e6, 5_000e18, address(usdc), bob);
        vm.prank(alice);
        uint256 ok = fund.requestSubscription(1_000e6, 1, address(usdc), alice);

        uint256[] memory approvals = new uint256[](2);
        approvals[0] = greedy;
        approvals[1] = ok;
        vm.prank(ops);
        vm.expectEmit(true, true, true, true);
        emit IKpkSharesNav.RequestSkippedForSlippage(greedy, 5_000e18, 1_000e18);
        fund.processRequests(approvals, new uint256[](0), address(usdc));

        // The unsatisfiable request is untouched and still pending
        assertEq(uint8(fund.getRequest(greedy).requestStatus), uint8(IKpkSharesNav.RequestStatus.PENDING));
        assertEq(fund.balanceOf(bob), 0);
        // The satisfiable one settled
        assertEq(uint8(fund.getRequest(ok).requestStatus), uint8(IKpkSharesNav.RequestStatus.PROCESSED));
        assertEq(fund.balanceOf(alice), 1_000e18 + 1_000e18);
    }

    function testSkippedRequestCanStillBeRejectedForARefund() public {
        _seedFund(alice, 1_000e6);

        vm.prank(bob);
        uint256 greedy = fund.requestSubscription(1_000e6, 5_000e18, address(usdc), bob);
        _approve(greedy);
        assertEq(uint8(fund.getRequest(greedy).requestStatus), uint8(IKpkSharesNav.RequestStatus.PENDING));

        uint256 before = usdc.balanceOf(bob);
        _reject(greedy);
        assertEq(usdc.balanceOf(bob) - before, 1_000e6);
        assertEq(uint8(fund.getRequest(greedy).requestStatus), uint8(IKpkSharesNav.RequestStatus.REJECTED));
    }

    //
    // Requests carry no price
    //

    function testSubscriptionRequestEscrowsAssetsOnTheFund() public {
        vm.prank(alice);
        uint256 id = fund.requestSubscription(1_000e6, 1, address(usdc), alice);

        assertEq(usdc.balanceOf(address(fund)), 1_000e6, "assets escrowed, not sent to the safe");
        assertEq(fund.subscriptionAssets(address(usdc)), 1_000e6);
        assertEq(fund.getRequest(id).sharesAmount, 1, "request records only the slippage bound");
    }

    function testRejectedSubscriptionRefundsTheInvestor() public {
        vm.prank(alice);
        uint256 id = fund.requestSubscription(1_000e6, 1, address(usdc), alice);

        uint256 before = usdc.balanceOf(alice);
        _reject(id);
        assertEq(usdc.balanceOf(alice) - before, 1_000e6);
        assertEq(fund.subscriptionAssets(address(usdc)), 0);
    }

    function testCancelSubscriptionAfterTtl() public {
        vm.prank(alice);
        uint256 id = fund.requestSubscription(1_000e6, 1, address(usdc), alice);

        vm.prank(alice);
        vm.expectRevert(IKpkSharesNav.RequestNotPastTtl.selector);
        fund.cancelSubscription(id);

        vm.warp(vm.getBlockTimestamp() + SUBSCRIPTION_TTL + 1);
        uint256 before = usdc.balanceOf(alice);
        vm.prank(alice);
        fund.cancelSubscription(id);
        assertEq(usdc.balanceOf(alice) - before, 1_000e6);
    }

    /// @dev Cancellation must never need a price, so it stays available during a NAV outage.
    function testCancelWorksWhileNavIsUnhealthy() public {
        vm.prank(alice);
        uint256 id = fund.requestSubscription(1_000e6, 1, address(usdc), alice);

        nav.setNavReverts(true);
        vm.warp(vm.getBlockTimestamp() + SUBSCRIPTION_TTL + 1);

        uint256 before = usdc.balanceOf(alice);
        vm.prank(alice);
        fund.cancelSubscription(id);
        assertEq(usdc.balanceOf(alice) - before, 1_000e6);
    }

    //
    // Redemptions
    //

    function testRedemptionEscrowsSharesAndPaysFromTheSafe() public {
        _seedFund(alice, 1_000e6);

        vm.prank(alice);
        uint256 id = fund.requestRedemption(500e18, 1, address(usdc), alice);
        assertEq(fund.balanceOf(address(fund)), 500e18, "shares escrowed");

        uint256 aliceBefore = usdc.balanceOf(alice);
        uint256 safeBefore = usdc.balanceOf(safe);
        _approve(id);

        assertEq(usdc.balanceOf(alice) - aliceBefore, 500e6, "paid at $1.00/share");
        assertEq(safeBefore - usdc.balanceOf(safe), 500e6, "paid out of the safe");
        assertEq(fund.totalSupply(), 500e18, "shares burned");
    }

    function testRedemptionAtDoubledPricePaysTwiceTheAssets() public {
        _seedFund(alice, 1_000e6);
        nav.setNavValue(int256(2_000 * 1e8));

        vm.prank(alice);
        uint256 id = fund.requestRedemption(500e18, 1, address(usdc), alice);

        uint256 before = usdc.balanceOf(alice);
        _approve(id);
        assertEq(usdc.balanceOf(alice) - before, 1_000e6, "500 shares at $2.00");
    }

    function testRejectedRedemptionReturnsEscrowedShares() public {
        _seedFund(alice, 1_000e6);

        vm.prank(alice);
        uint256 id = fund.requestRedemption(500e18, 1, address(usdc), alice);
        _reject(id);

        assertEq(fund.balanceOf(alice), 1_000e18, "shares returned");
        assertEq(fund.balanceOf(address(fund)), 0);
    }

    function testRedemptionSlippageBoundSkipsRatherThanReverts() public {
        _seedFund(alice, 1_000e6);

        vm.prank(alice);
        uint256 id = fund.requestRedemption(500e18, 10_000e6, address(usdc), alice);
        _approve(id);

        assertEq(uint8(fund.getRequest(id).requestStatus), uint8(IKpkSharesNav.RequestStatus.PENDING));
        assertEq(fund.balanceOf(address(fund)), 500e18, "escrow untouched");
    }

    //
    // Expiry
    //

    function testExpiredRequestIsRefundedRatherThanSettled() public {
        _seedFund(alice, 1_000e6);

        vm.prank(bob);
        uint256 id = fund.requestSubscription(1_000e6, 1, address(usdc), bob);

        vm.warp(vm.getBlockTimestamp() + 8 days);

        uint256 before = usdc.balanceOf(bob);
        vm.expectEmit(true, true, true, true);
        emit IKpkSharesNav.SubscriptionRequestExpired(id, fund.getRequest(id).expiryAt);
        _approve(id);

        assertEq(usdc.balanceOf(bob) - before, 1_000e6);
        assertEq(fund.balanceOf(bob), 0);
    }

    //
    // Access control
    //

    function testOnlyOperatorCanProcessRequests() public {
        vm.prank(alice);
        uint256 id = fund.requestSubscription(1_000e6, 1, address(usdc), alice);

        uint256[] memory approvals = new uint256[](1);
        approvals[0] = id;
        vm.prank(alice);
        vm.expectRevert(IKpkSharesNav.NotAuthorized.selector);
        fund.processRequests(approvals, new uint256[](0), address(usdc));
    }
}
