// SPDX-License-Identifier: MIT
pragma solidity ^0.8;

import {kpkSharesNavTestBase} from "./kpkSharesNav.TestBase.sol";
import {IKpkSharesNav} from "../src/IKpkSharesNav.sol";
import {KpkSharesNav} from "../src/KpkSharesNav.sol";
import {WatermarkFee} from "../src/FeeModules/WatermarkFee.sol";
import {Mock_RevertingPerfFeeModule} from "./mocks/RevertingPerfFeeModule.sol";
import {UnsafeUpgrades} from "openzeppelin-foundry-upgrades/Upgrades.sol";

/// @title kpkSharesNavBrokenFeeModuleTest
/// @notice A performance fee module that stops answering must not be able to halt the fund.
/// @dev The performance fee module is an independently deployed contract reached only through an
///      interface — it can be a proxy that gets upgraded, can acquire access control, or can simply
///      revert on an edge case. The fund cannot verify it and must not depend on it to keep
///      settling: a fee is an accounting detail, and no accounting detail should be able to stop
///      people getting their money.
///
///      This suite exists because a review round nearly shipped the opposite. Requiring
///      `performanceFeeRate == 0` before ANY module swap correctly closed a fee-forgiveness hole,
///      but the only route to a zero rate runs through the module itself — so a broken module made
///      the rate unzeroable, which made the module unswappable, while `_chargeFees` halted every
///      settlement six hours later. The escape hatch and the hole were the same door.
contract kpkSharesNavBrokenFeeModuleTest is kpkSharesNavTestBase {
    Mock_RevertingPerfFeeModule internal badModule;

    function setUp() public override {
        super.setUp();

        badModule = new Mock_RevertingPerfFeeModule();

        // A fund carrying a live performance fee, paid to a module that will later break
        address impl = address(new KpkSharesNav());
        address proxy = UnsafeUpgrades.deployUUPSProxy(
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
                        performanceFeeModule: address(badModule),
                        performanceFeeRate: 2000,
                        navCalculator: address(nav),
                        initialSharePrice: ONE_USD
                    }))
            )
        );
        fund = KpkSharesNav(proxy);

        vm.prank(admin);
        fund.grantRole(OPERATOR, ops);
        vm.prank(safe);
        usdc.approve(address(fund), type(uint256).max);
        vm.prank(alice);
        usdc.approve(address(fund), type(uint256).max);
        vm.prank(bob);
        usdc.approve(address(fund), type(uint256).max);

        _seedFund(alice, 1_000e6);
    }

    /// @notice Settlement survives a module that has started reverting.
    /// @dev The fee is skipped for that batch rather than taken down with it. `WatermarkFee`-style
    ///      modules keep their high-water mark, so a later working module still charges the gain
    ///      from where it left off — the fee is deferred, not forgiven.
    function testSettlementSurvivesABrokenFeeModule() public {
        badModule.setBroken(true);
        vm.warp(vm.getBlockTimestamp() + 7 hours);

        vm.prank(bob);
        uint256 id = fund.requestSubscription(1_000e6, 1, address(usdc), bob);
        _approve(id);

        assertEq(fund.balanceOf(bob), 1_000e18, "the batch settled despite the broken module");
        assertEq(fund.balanceOf(feeRecipient), 0, "and simply charged no fee");
    }

    /// @notice Redemptions survive it too — the path people need most in a crisis.
    function testRedemptionSurvivesABrokenFeeModule() public {
        badModule.setBroken(true);
        vm.warp(vm.getBlockTimestamp() + 7 hours);

        uint256 before = usdc.balanceOf(alice);
        vm.prank(alice);
        uint256 id = fund.requestRedemption(500e18, 1, address(usdc), alice);
        _approve(id);

        assertEq(usdc.balanceOf(alice) - before, 500e6, "the redeemer got paid");
    }

    /// @notice The admin can still recover: zero the rate, then swap the module.
    /// @dev This is the escape hatch the round-three guard closed. Zeroing the rate settles against
    ///      the current module, so a broken one made the rate unzeroable and the module unswappable.
    function testAdminCanRecoverFromABrokenFeeModule() public {
        badModule.setBroken(true);
        vm.warp(vm.getBlockTimestamp() + 7 hours);

        vm.prank(admin);
        fund.setPerformanceFeeRate(0);
        assertEq(fund.performanceFeeRate(), 0, "rate zeroed despite the module reverting");

        address healthy = address(new WatermarkFee());
        vm.prank(admin);
        fund.setPerformanceFeeModule(healthy);
        assertEq(fund.performanceFeeModule(), healthy, "module replaced");

        vm.prank(admin);
        fund.setPerformanceFeeRate(2000);
        assertEq(fund.performanceFeeRate(), 2000, "and the fee can be turned back on");
    }

    /// @notice The other direction: a HEALTHY module is still charged, and still blocks a swap.
    /// @dev Tolerating a broken module must not quietly stop charging a working one, and must not
    ///      reopen the fee-forgiveness hole the guard was added to close.
    function testHealthyModuleStillChargesAndStillBlocksSwaps() public {
        // Swap to a real module while nothing is accrued
        vm.prank(admin);
        fund.setPerformanceFeeRate(0);
        address healthy = address(new WatermarkFee());
        vm.prank(admin);
        fund.setPerformanceFeeModule(healthy);
        vm.prank(admin);
        fund.setPerformanceFeeRate(2000);

        // Seed the watermark, then double the fund
        vm.warp(vm.getBlockTimestamp() + 7 hours);
        vm.prank(bob);
        _approve(fund.requestSubscription(1e6, 1, address(usdc), bob));
        _setSharePrice(2 * ONE_USD);
        vm.warp(vm.getBlockTimestamp() + 7 hours);

        vm.prank(bob);
        _approve(fund.requestSubscription(1_000e6, 1, address(usdc), bob));
        assertGt(fund.balanceOf(feeRecipient), 0, "a working module still charges");

        // And the forgiveness guard still holds. The replacement is constructed BEFORE the
        // `expectRevert`: a `new` in the argument position is itself a call, and `expectRevert`
        // binds to the next one it sees, so an inline construction would consume the expectation
        // and the assertion would pass without ever reaching the setter.
        address another = address(new WatermarkFee());
        vm.prank(admin);
        vm.expectRevert(IKpkSharesNav.InvalidArguments.selector);
        fund.setPerformanceFeeModule(another);
    }
}
