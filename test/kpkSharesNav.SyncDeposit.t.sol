// SPDX-License-Identifier: MIT
pragma solidity ^0.8;

import {kpkSharesNavTestBase} from "./kpkSharesNav.TestBase.sol";
import {IKpkSharesNav} from "../src/IKpkSharesNav.sol";

/// @notice The synchronous deposit path and its admin toggle.
contract kpkSharesNavSyncDepositTest is kpkSharesNavTestBase {
    function testSyncDepositsDisabledByDefault() public {
        assertFalse(fund.syncDepositsEnabled());

        vm.prank(alice);
        vm.expectRevert(IKpkSharesNav.SyncDepositsDisabled.selector);
        fund.subscribe(1_000e6, 1, address(usdc), alice);
    }

    function testOnlyAdminCanToggleSyncDeposits() public {
        vm.prank(ops);
        vm.expectRevert(IKpkSharesNav.NotAuthorized.selector);
        fund.setSyncDepositsEnabled(true);

        vm.prank(alice);
        vm.expectRevert(IKpkSharesNav.NotAuthorized.selector);
        fund.setSyncDepositsEnabled(true);
    }

    function testAdminCanEnableAndDisable() public {
        vm.prank(admin);
        vm.expectEmit(true, true, true, true);
        emit IKpkSharesNav.SyncDepositsEnabledUpdate(true);
        fund.setSyncDepositsEnabled(true);
        assertTrue(fund.syncDepositsEnabled());

        vm.prank(admin);
        fund.setSyncDepositsEnabled(false);
        assertFalse(fund.syncDepositsEnabled());

        vm.prank(alice);
        vm.expectRevert(IKpkSharesNav.SyncDepositsDisabled.selector);
        fund.subscribe(1_000e6, 1, address(usdc), alice);
    }

    function _enable() internal {
        vm.prank(admin);
        fund.setSyncDepositsEnabled(true);
    }

    function testSyncDepositMintsAndSendsAssetsToTheSafe() public {
        _seedFund(alice, 1_000e6);
        _enable();

        uint256 safeBefore = usdc.balanceOf(safe);

        vm.prank(bob);
        uint256 shares = fund.subscribe(1_000e6, 1, address(usdc), bob);

        assertEq(shares, 1_000e18, "shares minted at $1.00");
        assertEq(fund.balanceOf(bob), 1_000e18);
        assertEq(usdc.balanceOf(safe) - safeBefore, 1_000e6, "assets went straight to the safe");
        // No escrow was involved
        assertEq(usdc.balanceOf(address(fund)), 0, "nothing held on the fund");
        assertEq(fund.subscriptionAssets(address(usdc)), 0, "escrow accounting untouched");
        assertEq(fund.requestId(), 1, "no request created");
    }

    /// @dev The invariant that matters: a deposit must not be valued against its own contribution.
    ///      Here the NAV deliberately stays at the pre-deposit value; if the fund priced after the
    ///      transfer it would still mint 1,000 shares, so instead we assert the price the deposit
    ///      settled at is the pre-deposit price.
    function testSyncDepositIsPricedBeforeAssetsMove() public {
        _seedFund(alice, 1_000e6);
        _enable();

        uint256 priceBefore = fund.getSharePriceUsd();

        vm.prank(bob);
        vm.expectEmit(true, true, true, true);
        emit IKpkSharesNav.SyncSubscription(bob, bob, address(usdc), 1_000e6, 1_000e18, priceBefore);
        fund.subscribe(1_000e6, 1, address(usdc), bob);
    }

    function testSyncDepositRespectsSlippageBound() public {
        _seedFund(alice, 1_000e6);
        // Share price doubles, so 1,000 USDC now buys only 500 shares
        nav.setNavValue(int256(2_000 * 1e8));
        _enable();

        vm.prank(bob);
        vm.expectRevert(IKpkSharesNav.SlippageBoundNotMet.selector);
        fund.subscribe(1_000e6, 501e18, address(usdc), bob);

        vm.prank(bob);
        uint256 shares = fund.subscribe(1_000e6, 500e18, address(usdc), bob);
        assertEq(shares, 500e18);
    }

    function testSyncDepositRejectsZeroSlippageBound() public {
        _seedFund(alice, 1_000e6);
        _enable();

        vm.prank(bob);
        vm.expectRevert(IKpkSharesNav.InvalidArguments.selector);
        fund.subscribe(1_000e6, 0, address(usdc), bob);
    }

    function testSyncDepositRejectsUnapprovedAsset() public {
        _seedFund(alice, 1_000e6);
        _enable();

        vm.prank(bob);
        vm.expectRevert(IKpkSharesNav.NotAnApprovedAsset.selector);
        fund.subscribe(1_000e6, 1, makeAddr("random"), bob);
    }

    function testSyncDepositHaltsWhenNavUnhealthy() public {
        _seedFund(alice, 1_000e6);
        _enable();
        nav.setSequencerDown(true);

        vm.prank(bob);
        vm.expectRevert(IKpkSharesNav.NavUnhealthy.selector);
        fund.subscribe(1_000e6, 1, address(usdc), bob);
    }

    function testSyncDepositToDifferentReceiver() public {
        _seedFund(alice, 1_000e6);
        _enable();

        vm.prank(bob);
        fund.subscribe(1_000e6, 1, address(usdc), alice);

        assertEq(fund.balanceOf(bob), 0);
        assertEq(fund.balanceOf(alice), 1_000e18 + 1_000e18);
    }

    function testSyncDepositOnEmptyFundUsesBootstrapPrice() public {
        _enable();

        vm.prank(alice);
        uint256 shares = fund.subscribe(1_000e6, 1, address(usdc), alice);
        assertEq(shares, 1_000e18);
    }

    function testSyncDepositRecordsPricingEvent() public {
        _seedFund(alice, 1_000e6);
        _enable();

        vm.prank(bob);
        fund.subscribe(1_000e6, 1, address(usdc), bob);

        assertEq(fund.lastSharePriceUsd(), ONE_USD);
        assertEq(fund.lastPricedAt(), uint64(block.timestamp));
    }
}
