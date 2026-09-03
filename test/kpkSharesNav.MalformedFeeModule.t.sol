// SPDX-License-Identifier: MIT
pragma solidity ^0.8;

import {kpkSharesNavTestBase} from "./kpkSharesNav.TestBase.sol";
import {KpkSharesNav} from "../src/KpkSharesNav.sol";
import {WatermarkFee} from "../src/FeeModules/WatermarkFee.sol";
import {Mock_MalformedPerfFeeModule} from "./mocks/MalformedPerfFeeModule.sol";
import {UnsafeUpgrades} from "openzeppelin-foundry-upgrades/Upgrades.sol";

/// @title kpkSharesNavMalformedFeeModuleTest
/// @notice No reply shape from a performance fee module may halt the fund.
/// @dev Third round on the same defect, so the test is written against the CLASS rather than the
///      instance. Two previous fixes each closed one door and left the next one open:
///
///        1. `try/catch` was added, on the belief that it made a broken module non-fatal. It absorbs
///           a callee REVERT and nothing else.
///        2. A `code.length` check was added for a codeless module, whose `extcodesize` probe reverts
///           in the fund's frame BEFORE the call. That closed the codeless door — and left open the
///           strictly more reachable one below.
///        3. A module WITH code that returns fewer than 32 bytes. The call SUCCEEDS; the fund then
///           dies decoding the reply, in its own frame, AFTER the call. Both guards above pass it.
///
///      The third is not exotic. An upgraded module that renames or re-signs its function falls
///      through to a fallback returning nothing, and a proxy module pointed at a codeless
///      implementation delegatecalls successfully and returns zero bytes while still reporting
///      `code.length > 0` itself — which is the very example the round-five comment cited as the
///      reason for the `code.length` guard that does not, in fact, cover it.
///
///      So this suite asserts over the whole shape space — 0, 8, 32, 64 and 1024 bytes — rather than
///      the one shape that was reported. The over-long cases matter as much as the short ones: a
///      fund that halted on a chatty module would have the same bug pointing the other way.
contract kpkSharesNavMalformedFeeModuleTest is kpkSharesNavTestBase {
    function setUp() public override {
        super.setUp();
    }

    /// @notice A reply too short to be a `uint256` is a skipped fee, not a halted fund.
    function testShortRepliesDoNotHaltTheFund() public {
        _assertSettlesWithModule(new Mock_MalformedPerfFeeModule(0, 0), 0);
        _assertSettlesWithModule(new Mock_MalformedPerfFeeModule(8, 0), 0);
        _assertSettlesWithModule(new Mock_MalformedPerfFeeModule(31, 0), 0);
    }

    /// @notice The other direction: a well-formed or over-long reply is still HONOURED, not skipped.
    /// @dev Without this, a fix that simply skipped every fee would pass the tests above while
    ///      silently forgiving all performance fees forever — a fail-open dressed as a fail-safe.
    function testWellFormedAndOverLongRepliesAreHonoured() public {
        _assertSettlesWithModule(new Mock_MalformedPerfFeeModule(32, 1e18), 1e18);
        _assertSettlesWithModule(new Mock_MalformedPerfFeeModule(64, 1e18), 1e18);
        _assertSettlesWithModule(new Mock_MalformedPerfFeeModule(1024, 1e18), 1e18);
    }

    /// @notice The escape hatch survives every shape: the rate can be zeroed and the module swapped.
    /// @dev This is what makes the difference between "a fee was skipped" and "the fund is bricked".
    ///      Zeroing the rate settles through the module, so if that path reverts the rate cannot be
    ///      zeroed, and the module cannot be swapped because swapping requires a zero rate.
    function testAdminCanAlwaysRecoverFromAMalformedModule() public {
        address bad = address(new Mock_MalformedPerfFeeModule(0, 0));
        fund = KpkSharesNav(_deployWithModule(bad));
        _wireAndSeed();

        vm.warp(vm.getBlockTimestamp() + 7 hours);

        vm.prank(admin);
        fund.setPerformanceFeeRate(0);
        assertEq(fund.performanceFeeRate(), 0, "the rate can still be zeroed");

        address healthy = address(new WatermarkFee());
        vm.prank(admin);
        fund.setPerformanceFeeModule(healthy);
        assertEq(fund.performanceFeeModule(), healthy, "and the module can still be swapped");
    }

    /// @notice Redemptions survive too — the path people need most in a crisis.
    function testRedemptionSurvivesAMalformedModule() public {
        fund = KpkSharesNav(_deployWithModule(address(new Mock_MalformedPerfFeeModule(0, 0))));
        _wireAndSeed();

        vm.warp(vm.getBlockTimestamp() + 7 hours);
        uint256 before = usdc.balanceOf(alice);
        vm.prank(alice);
        uint256 id = fund.requestRedemption(500e18, 1, address(usdc), alice);
        _approve(id);

        assertEq(usdc.balanceOf(alice) - before, 500e6, "the redeemer got paid");
    }

    /// @notice Deploys a fund on `module`, settles a subscription, and checks the fee that resulted.
    function _assertSettlesWithModule(Mock_MalformedPerfFeeModule module, uint256 expectedFee) internal {
        fund = KpkSharesNav(_deployWithModule(address(module)));
        _wireAndSeed();

        vm.warp(vm.getBlockTimestamp() + 7 hours);
        vm.prank(bob);
        uint256 id = fund.requestSubscription(1_000e6, 1, address(usdc), bob);
        _approve(id);

        // Not an exact share count: minting fee shares dilutes, so a settlement that DID charge a
        // fee leaves the subscriber with slightly more than the undiluted 1,000. The load-bearing
        // assertion is the fee itself — that the reply was honoured rather than skipped.
        assertGt(fund.balanceOf(bob), 0, "the batch settled");
        assertEq(fund.balanceOf(feeRecipient), expectedFee, "the fee matched the module's reply");
    }

    function _wireAndSeed() internal {
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

    function _deployWithModule(address module) internal returns (address) {
        address impl = address(new KpkSharesNav());
        return UnsafeUpgrades.deployUUPSProxy(
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
                        performanceFeeModule: module,
                        performanceFeeRate: 2000,
                        navCalculator: address(nav),
                        initialSharePrice: ONE_USD
                    }))
            )
        );
    }
}
