// SPDX-License-Identifier: MIT
pragma solidity ^0.8;

import {kpkSharesNavTestBase} from "./kpkSharesNav.TestBase.sol";
import {IKpkSharesNav} from "../src/IKpkSharesNav.sol";
import {KpkSharesNav} from "../src/KpkSharesNav.sol";
import {Mock_ERC20} from "./mocks/tokens.sol";
import {MockNavCalculator} from "./mocks/MockNavCalculator.sol";
import {Mock_HookERC20} from "./mocks/HookERC20.sol";
import {UnsafeUpgrades} from "openzeppelin-foundry-upgrades/Upgrades.sol";

/// @title kpkSharesNavReviewFixesTest
/// @notice Coverage for the guards added during pre-merge review, plus the paths that mutation
///         testing showed no existing test was binding.
contract kpkSharesNavReviewFixesTest is kpkSharesNavTestBase {
    //
    // Bootstrap may not happen through the permissionless path
    //

    /// @dev While the supply is zero the price is `initialSharePrice` and the NAV is never read, so
    ///      there is no health gate and no link between the price and the safe's contents. That
    ///      window re-arms every time the supply returns to zero, which a full redemption does while
    ///      the safe still holds anything a payout could not drain.
    function testSyncSubscribeCannotBootstrapAnEmptyFund() public {
        vm.prank(admin);
        fund.setSyncDepositsEnabled(true);

        assertEq(fund.totalSupply(), 0);

        vm.prank(alice);
        vm.expectRevert(IKpkSharesNav.BootstrapRequiresOperator.selector);
        fund.subscribe(1_000e6, address(usdc), alice);
    }

    /// @notice The window re-arms after a full redemption, and is still closed to the sync path
    function testSyncSubscribeRefusesAfterSupplyReturnsToZero() public {
        _seedFund(alice, 1_000e6);

        // Alice redeems everything
        vm.prank(alice);
        uint256 id = fund.requestRedemption(1_000e18, 1, address(usdc), alice);
        _approve(id);
        assertEq(fund.totalSupply(), 0, "supply is back to zero");

        // The safe still carries value a USDC payout could not drain
        nav.setNavValue(int256(500 * 1e8));

        vm.prank(admin);
        fund.setSyncDepositsEnabled(true);

        // Without the guard, 1 USDC would mint 100% of the supply and capture the residual $500
        vm.prank(bob);
        vm.expectRevert(IKpkSharesNav.BootstrapRequiresOperator.selector);
        fund.subscribe(1e6, address(usdc), bob);
    }

    /// @notice Once seeded, the sync path works normally
    function testSyncSubscribeWorksOnceSeeded() public {
        _seedFund(alice, 1_000e6);

        vm.prank(admin);
        fund.setSyncDepositsEnabled(true);

        vm.prank(bob);
        assertEq(fund.subscribe(1_000e6, address(usdc), bob), 1_000e18);
    }

    //
    // setNavCalculator applies the SAME test as listing
    //

    function testSetNavCalculatorRejectsNavThatCannotPriceAListedAsset() public {
        MockNavCalculator fresh = new MockNavCalculator();
        // Registered, but with no price feed: settlement would revert PriceFeedNotSet forever, and
        // the base asset cannot be delisted to escape it.
        fresh.registerAssetWithoutFeed(address(usdc), 6);

        vm.prank(admin);
        vm.expectRevert(IKpkSharesNav.AssetNotPriceable.selector);
        fund.setNavCalculator(address(fresh));
    }

    function testSetNavCalculatorRejectsNavWithMismatchedDecimals() public {
        MockNavCalculator fresh = new MockNavCalculator();
        // Registry claims USDC is 18 decimals; the fund has cached 6. Accepting this would silently
        // rescale the safe's valuation by 10^12.
        fresh.registerAsset(address(usdc), 18, int256(ONE_USD), 8);

        vm.prank(admin);
        vm.expectRevert(IKpkSharesNav.InvalidArguments.selector);
        fund.setNavCalculator(address(fresh));
    }

    function testSetNavCalculatorRejectsNavWithAnUnhealthyFeed() public {
        MockNavCalculator fresh = new MockNavCalculator();
        fresh.registerAsset(address(usdc), 6, int256(ONE_USD), 8);
        fresh.setPriceStale(address(usdc), true);

        vm.prank(admin);
        vm.expectRevert(IKpkSharesNav.AssetNotPriceable.selector);
        fund.setNavCalculator(address(fresh));
    }

    //
    // Escrow is recorded before the assets are pulled
    //

    /// @dev `RecoverFunds.recoverAssets` is permissionless and has no reentrancy guard of its own, so
    ///      `nonReentrant` on `requestSubscription` does not cover it. Crediting the escrow before
    ///      the transfer means there is no instant at which the fund holds assets that
    ///      `_assetRecoverableAmount` would consider sweepable.
    ///      A plain ERC-20 cannot prove this: with no callback, both orderings reach the same end
    ///      state, so an end-state assertion holds either way. The ordering is only observable from
    ///      inside the transfer, so the test uses a token that re-enters there and tries the sweep at
    ///      exactly the vulnerable moment.
    function testEscrowIsRecordedBeforeAssetsArrive() public {
        Mock_HookERC20 hookToken = new Mock_HookERC20("HOOK", 6);
        nav.registerAsset(address(hookToken), 6, int256(ONE_USD), 8);
        vm.prank(ops);
        fund.updateAsset(address(hookToken), true, true);

        hookToken.mint(alice, 1_000e6);
        vm.prank(alice);
        hookToken.approve(address(fund), type(uint256).max);

        // From inside its own transfer, the token attempts the sweep that would strand the escrow
        address[] memory assets = new address[](1);
        assets[0] = address(hookToken);
        hookToken.setHook(address(fund), abi.encodeCall(fund.recoverAssets, (assets)));

        vm.prank(alice);
        fund.requestSubscription(1_000e6, 1, address(hookToken), alice);

        // Because the escrow was credited BEFORE the pull, `_assetRecoverableAmount` already saw a
        // pending request during the callback and released nothing.
        assertEq(hookToken.balanceOf(address(fund)), 1_000e6, "escrow survived the re-entrant sweep");
        assertEq(fund.subscriptionAssets(address(hookToken)), 1_000e6, "books match the real balance");

        // And the investor can still get their money back, which is the point.
        vm.warp(vm.getBlockTimestamp() + SUBSCRIPTION_TTL + 1);
        vm.prank(alice);
        fund.cancelSubscription(1);
        assertEq(hookToken.balanceOf(alice), 1_000e6, "refund honoured");
    }

    //
    // recoverAssets guards (previously unexercised by any test)
    //

    function testRecoverAssetsCannotSweepTheShareToken() public {
        _seedFund(alice, 1_000e6);

        // Park some shares on the contract, as a redemption escrow would
        vm.prank(alice);
        fund.requestRedemption(500e18, 1, address(usdc), alice);
        assertEq(fund.balanceOf(address(fund)), 500e18);

        address[] memory assets = new address[](1);
        assets[0] = address(fund);
        fund.recoverAssets(assets);

        assertEq(fund.balanceOf(address(fund)), 500e18, "share token is never recoverable");
    }

    function testRecoverAssetsCannotSweepAssetWithPendingRequests() public {
        _seedFund(alice, 1_000e6);

        // A pending REDEMPTION leaves no `subscriptionAssets` escrow, so the pending-count guard is
        // the only thing protecting a donation sitting on the contract.
        vm.prank(alice);
        fund.requestRedemption(500e18, 1, address(usdc), alice);

        usdc.mint(address(fund), 250e6);

        address[] memory assets = new address[](1);
        assets[0] = address(usdc);
        fund.recoverAssets(assets);

        assertEq(usdc.balanceOf(address(fund)), 250e6, "blocked while any request for the asset is pending");
    }

    function testRecoverAssetsSweepsOnlyWhenNothingIsPending() public {
        uint256 safeBefore = usdc.balanceOf(safe);
        usdc.mint(address(fund), 250e6);

        address[] memory assets = new address[](1);
        assets[0] = address(usdc);
        fund.recoverAssets(assets);

        assertEq(usdc.balanceOf(address(fund)), 0, "donation swept");
        assertEq(usdc.balanceOf(safe) - safeBefore, 250e6, "and it went to the portfolio safe");
    }

    //
    // receiver != investor (every other async test uses the same address for both)
    //

    function testSubscriptionMintsToReceiverNotInvestor() public {
        _seedFund(alice, 1_000e6);

        vm.prank(bob);
        uint256 id = fund.requestSubscription(1_000e6, 1, address(usdc), alice);
        _approve(id);

        assertEq(fund.balanceOf(bob), 0, "investor receives nothing");
        assertEq(fund.balanceOf(alice), 2_000e18, "receiver is credited");
    }

    function testRedemptionPaysReceiverNotInvestor() public {
        _seedFund(alice, 1_000e6);

        uint256 aliceBefore = usdc.balanceOf(alice);
        uint256 bobBefore = usdc.balanceOf(bob);

        vm.prank(alice);
        uint256 id = fund.requestRedemption(500e18, 1, address(usdc), bob);
        _approve(id);

        assertEq(usdc.balanceOf(alice), aliceBefore, "investor receives nothing");
        assertEq(usdc.balanceOf(bob) - bobBefore, 500e6, "receiver is paid");
    }

    function testRejectedSubscriptionRefundsInvestorNotReceiver() public {
        uint256 bobBefore = usdc.balanceOf(bob);
        uint256 aliceBefore = usdc.balanceOf(alice);

        vm.prank(bob);
        uint256 id = fund.requestSubscription(1_000e6, 1, address(usdc), alice);
        _reject(id);

        assertEq(usdc.balanceOf(bob), bobBefore, "investor made whole");
        assertEq(usdc.balanceOf(alice), aliceBefore, "receiver gets nothing on a refund");
    }

    //
    // Cancellation authorization
    //

    function testStrangerCannotCancelSomeoneElsesRequest() public {
        vm.prank(alice);
        uint256 id = fund.requestSubscription(1_000e6, 1, address(usdc), alice);

        vm.warp(vm.getBlockTimestamp() + SUBSCRIPTION_TTL + 1);

        vm.prank(bob);
        vm.expectRevert(IKpkSharesNav.NotAuthorized.selector);
        fund.cancelSubscription(id);
    }

    function testReceiverMayCancel() public {
        vm.prank(bob);
        uint256 id = fund.requestSubscription(1_000e6, 1, address(usdc), alice);

        vm.warp(vm.getBlockTimestamp() + SUBSCRIPTION_TTL + 1);

        uint256 bobBefore = usdc.balanceOf(bob);
        vm.prank(alice);
        fund.cancelSubscription(id);
        assertEq(usdc.balanceOf(bob) - bobBefore, 1_000e6, "refund still goes to the investor");
    }

    //
    // Rounding direction
    //

    /// @dev Pins the direction rather than a round number: `sharesToAssets` must never return MORE
    ///      than the exact quotient, or a redeemer extracts value from the remaining holders. Uses a
    ///      price that does not divide evenly so Floor and Ceil differ by one unit.
    function testSharesToAssetsRoundsDownNotUp() public {
        _seedFund(alice, 1_000e6);
        // 1,000 shares against $333.33333333 → a share price that leaves a remainder
        nav.setNavValue(int256(33_333_333_333));

        uint256 assetsOut = fund.previewRedemption(1e18, address(usdc));
        // Exact value is 333333.333... asset units; Floor gives 333333, Ceil would give 333334
        assertEq(assetsOut, 333_333, "must floor, never round up");
    }

    //
    // A performance fee rate with no module is refused
    //

    /// @dev The initializer's pairing guard is worth nothing if two admin calls can walk back into
    ///      the state it forbids, which is exactly what the scoped review found: clear the module
    ///      (explicitly allowed, it disables performance fees), then set a rate.
    function testSetPerformanceFeeRateRequiresAModule() public {
        // A fund whose module has been cleared
        vm.prank(admin);
        fund.setPerformanceFeeModule(address(0));

        vm.prank(admin);
        vm.expectRevert(IKpkSharesNav.InvalidArguments.selector);
        fund.setPerformanceFeeRate(2000);

        assertEq(fund.performanceFeeRate(), 0, "no fee that could never accrue");
    }

    function testCannotClearModuleWhileRateIsLive() public {
        vm.prank(admin);
        fund.setPerformanceFeeRate(2000);

        vm.prank(admin);
        vm.expectRevert(IKpkSharesNav.InvalidArguments.selector);
        fund.setPerformanceFeeModule(address(0));

        assertEq(fund.performanceFeeModule(), address(perfFeeModule), "module still in place");
    }

    /// @notice Clearing the module is still possible once the rate is zeroed first
    function testModuleCanBeClearedAfterZeroingTheRate() public {
        vm.prank(admin);
        fund.setPerformanceFeeRate(2000);

        vm.prank(admin);
        fund.setPerformanceFeeRate(0);
        vm.prank(admin);
        fund.setPerformanceFeeModule(address(0));

        assertEq(fund.performanceFeeModule(), address(0));
    }

    function testInitializeRejectsPerformanceRateWithoutModule() public {
        address impl = address(new KpkSharesNav());

        vm.expectRevert(IKpkSharesNav.InvalidArguments.selector);
        UnsafeUpgrades.deployUUPSProxy(
            impl,
            abi.encodeCall(
                KpkSharesNav.initialize,
                (KpkSharesNav.ConstructorParams({
                        asset: address(usdc),
                        admin: admin,
                        name: "kpk NAV",
                        symbol: "kpkNAV",
                        safe: safe,
                        subscriptionRequestTtl: SUBSCRIPTION_TTL,
                        redemptionRequestTtl: REDEMPTION_TTL,
                        feeReceiver: feeRecipient,
                        managementFeeRate: 0,
                        redemptionFeeRate: 0,
                        performanceFeeModule: address(0),
                        performanceFeeRate: 2000,
                        navCalculator: address(nav),
                        initialSharePrice: ONE_USD
                    }))
            )
        );
    }
}
