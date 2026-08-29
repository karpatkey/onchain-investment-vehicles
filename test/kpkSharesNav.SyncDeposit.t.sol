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
        fund.subscribe(1_000e6, address(usdc), alice);
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
        fund.subscribe(1_000e6, address(usdc), alice);
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
        uint256 shares = fund.subscribe(1_000e6, address(usdc), bob);

        assertEq(shares, 1_000e18, "shares minted at $1.00");
        assertEq(fund.balanceOf(bob), 1_000e18);
        assertEq(usdc.balanceOf(safe) - safeBefore, 1_000e6, "assets went straight to the safe");
        // No escrow was involved
        assertEq(usdc.balanceOf(address(fund)), 0, "nothing held on the fund");
        assertEq(fund.subscriptionAssets(address(usdc)), 0, "escrow accounting untouched");
        assertEq(fund.requestId(), 1, "no request created");
    }

    /// @notice A deposit must not be valued against its own contribution.
    /// @dev This test is only meaningful if the mock's NAV actually responds to token movement. With
    ///      a stored scalar NAV the reported value is identical whether the fund prices before or
    ///      after the transfer, so the assertion would hold either way and prove nothing. So the
    ///      mock is switched into balance-tracking mode: NAV = the safe's real USDC balance.
    ///
    ///      Priced BEFORE the transfer the safe holds 1,000 USDC → $1.00/share → 1,000 shares.
    ///      Priced AFTER, it would hold 2,000 → $2.00/share → 500 shares. The two are
    ///      distinguishable, which is what makes the ordering testable at all.
    function testSyncDepositIsPricedBeforeAssetsMove() public {
        // Start the safe empty so its balance is exactly what this test puts there
        usdc.burn(safe, usdc.balanceOf(safe));

        vm.prank(alice);
        uint256 id = fund.requestSubscription(1_000e6, 1, address(usdc), alice);
        _approve(id);
        assertEq(usdc.balanceOf(safe), 1_000e6, "safe holds only the seed");
        assertEq(fund.totalSupply(), 1_000e18);

        // NAV now derives from the safe's live balance: 1 USDC unit (1e-6) = 100 USD-8dp units
        nav.trackBalance(address(usdc), 100);
        nav.setNavValue(0);
        assertEq(fund.getSharePriceUsd(), ONE_USD, "seeded at $1.00/share");

        _enable();

        vm.prank(bob);
        uint256 shares = fund.subscribe(1_000e6, address(usdc), bob);

        assertEq(shares, 1_000e18, "priced at the pre-deposit NAV, not including bob's own assets");
        assertEq(usdc.balanceOf(safe), 2_000e6, "and the assets did land in the safe");
    }

    /// @notice The sync path takes NO slippage bound: the caller accepts the price at inclusion.
    /// @dev This replaces a test that asserted a `minSharesOut` bound was honoured. The argument was
    ///      removed, so the behaviour it guarded is gone: a price that has moved against the caller
    ///      no longer causes a revert, it simply mints fewer shares. Pinned here so the exposure is
    ///      visible rather than implied by an absence.
    function testSyncDepositHasNoSlippageBound() public {
        _seedFund(alice, 1_000e6);
        // The price doubles between the caller's decision and inclusion
        nav.setNavValue(int256(2_000 * 1e8));
        _enable();

        vm.prank(bob);
        uint256 shares = fund.subscribe(1_000e6, address(usdc), bob);

        // Half what the pre-move price would have given, and it went through regardless
        assertEq(shares, 500e18, "the caller absorbs the move with no floor to refuse it");
    }

    /// @notice A deposit too small to mint a single share unit reverts rather than donating.
    /// @dev The only floor left on this path. Conversions floor, so without this guard the assets
    ///      would move to the safe and the caller would receive nothing. Previously this was a side
    ///      effect of `minSharesOut` being required non-zero; it is now explicit.
    function testSyncDepositRevertsRatherThanMintingZeroShares() public {
        _seedFund(alice, 1_000e6);
        // shares = assetsIn * assetPrice * 1e18 / (1e6 * sharePrice), so one unit of a 6-decimal
        // asset floors to zero once the share price passes 1e20 (USD-8dp). A NAV of 1e24 against
        // 1,000e18 shares puts the price at 1e21, comfortably past it.
        nav.setNavValue(int256(1e24));
        _enable();

        vm.prank(bob);
        vm.expectRevert(IKpkSharesNav.ZeroSharesOut.selector);
        fund.subscribe(1, address(usdc), bob);
    }

    /// @notice The nearest legitimate deposit still succeeds, so the guard is not over-broad.
    function testSyncDepositOfOneShareUnitSucceeds() public {
        _seedFund(alice, 1_000e6);
        _enable();

        vm.prank(bob);
        uint256 shares = fund.subscribe(1, address(usdc), bob);
        assertGt(shares, 0, "a deposit that can mint something is not refused");
    }

    function testSyncDepositRejectsZeroAmountAndZeroReceiver() public {
        _seedFund(alice, 1_000e6);
        _enable();

        vm.prank(bob);
        vm.expectRevert(IKpkSharesNav.InvalidArguments.selector);
        fund.subscribe(0, address(usdc), bob);

        vm.prank(bob);
        vm.expectRevert(IKpkSharesNav.InvalidArguments.selector);
        fund.subscribe(1_000e6, address(usdc), address(0));
    }

    function testSyncDepositRejectsUnapprovedAsset() public {
        _seedFund(alice, 1_000e6);
        _enable();

        vm.prank(bob);
        vm.expectRevert(IKpkSharesNav.NotAnApprovedAsset.selector);
        fund.subscribe(1_000e6, makeAddr("random"), bob);
    }

    function testSyncDepositHaltsWhenNavUnhealthy() public {
        _seedFund(alice, 1_000e6);
        _enable();
        nav.setSequencerDown(true);

        vm.prank(bob);
        vm.expectRevert(IKpkSharesNav.NavUnhealthy.selector);
        fund.subscribe(1_000e6, address(usdc), bob);
    }

    function testSyncDepositToDifferentReceiver() public {
        _seedFund(alice, 1_000e6);
        _enable();

        vm.prank(bob);
        fund.subscribe(1_000e6, address(usdc), alice);

        assertEq(fund.balanceOf(bob), 0);
        assertEq(fund.balanceOf(alice), 1_000e18 + 1_000e18);
    }

    /// @notice The sync path refuses to be the one that opens a fund
    /// @dev This asserted the opposite until pre-merge review. Bootstrapping prices at
    ///      `initialSharePrice` without reading the NAV, so it is neither health gated nor connected
    ///      to what the safe holds — and the window re-arms whenever the supply returns to zero.
    ///      Opening a fund is now an operator decision. See `kpkSharesNav.ReviewFixes.t.sol` for the
    ///      post-full-redemption case this closes.
    function testSyncDepositCannotBootstrapAnEmptyFund() public {
        _enable();
        assertEq(fund.totalSupply(), 0);

        vm.prank(alice);
        vm.expectRevert(IKpkSharesNav.BootstrapRequiresOperator.selector);
        fund.subscribe(1_000e6, address(usdc), alice);
    }

    function testSyncDepositRecordsPricingEvent() public {
        _seedFund(alice, 1_000e6);
        _enable();

        vm.prank(bob);
        fund.subscribe(1_000e6, address(usdc), bob);

        assertEq(fund.lastSharePriceUsd(), ONE_USD);
        assertEq(fund.lastPricedAt(), uint64(block.timestamp));
    }
}
