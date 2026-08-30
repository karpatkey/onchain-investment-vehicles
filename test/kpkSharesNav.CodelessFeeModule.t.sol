// SPDX-License-Identifier: MIT
pragma solidity ^0.8;

import {kpkSharesNavTestBase} from "./kpkSharesNav.TestBase.sol";
import {IKpkSharesNav} from "../src/IKpkSharesNav.sol";
import {KpkSharesNav} from "../src/KpkSharesNav.sol";
import {WatermarkFee} from "../src/FeeModules/WatermarkFee.sol";
import {UnsafeUpgrades} from "openzeppelin-foundry-upgrades/Upgrades.sol";

/// @title kpkSharesNavCodelessFeeModuleTest
/// @notice A performance fee module with no code is the one broken module `try/catch` cannot save.
/// @dev The sibling suite proves a REVERTING module cannot halt the fund, because its revert lands
///      inside `_chargePerformanceFee`'s `catch`. A CODELESS module is a different animal and the
///      distinction is easy to get wrong: for a high-level call Solidity emits an `extcodesize`
///      probe and reverts on an empty result *in the caller's frame, before the call is made*. There
///      is no callee revert for `catch` to catch, so the try/catch is bypassed entirely and the
///      revert propagates.
///
///      Configured live, that reproduces the round-three brick through a different door — the rate
///      cannot be zeroed (zeroing settles through the module), so the module cannot be swapped,
///      while `_chargeFees` halts every settlement. A nonzero EOA satisfies every other check, which
///      is exactly how it reaches production: one wrong address in a deploy config.
///
///      Two layers, tested separately because they fail in different places. The setter refuses to
///      CREATE the state; `_chargePerformanceFee` tolerates the state ARISING anyway, which the
///      setter cannot prevent for a module that loses its code after being configured.
contract kpkSharesNavCodelessFeeModuleTest is kpkSharesNavTestBase {
    address internal healthyModule;

    function setUp() public override {
        super.setUp();

        healthyModule = address(new WatermarkFee());
        fund = KpkSharesNav(_deployWithModule(healthyModule, 2000));

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

    /// @notice A codeless module cannot be configured at deployment.
    function testCodelessModuleIsRefusedAtInitialization() public {
        address eoaModule = makeAddr("eoaModule"); // nonzero, no code

        // The implementation and the calldata are built BEFORE the expectation. A `new` in argument
        // position is itself a call, and `expectRevert` binds to the next call it sees — inline
        // construction would consume the expectation and the test would pass without ever
        // reaching the initializer.
        address impl = address(new KpkSharesNav());
        bytes memory initData = abi.encodeCall(KpkSharesNav.initialize, (_params(eoaModule, 2000)));

        vm.expectRevert(IKpkSharesNav.InvalidArguments.selector);
        UnsafeUpgrades.deployUUPSProxy(impl, initData);
    }

    /// @notice And it cannot be introduced later through the setter.
    function testCodelessModuleIsRefusedBySetter() public {
        address eoaModule = makeAddr("eoaModule");

        vm.prank(admin);
        fund.setPerformanceFeeRate(0); // the swap guard requires a zero rate first

        vm.prank(admin);
        vm.expectRevert(IKpkSharesNav.InvalidArguments.selector);
        fund.setPerformanceFeeModule(eoaModule);
    }

    /// @notice The other direction: the guard must not fire on the nearest legitimate input.
    /// @dev `address(0)` is also codeless, but it is the supported way to REMOVE the module. A guard
    ///      written as a bare `code.length == 0` would reject it and take the removal path with it —
    ///      fixing a footgun by welding shut the escape hatch next to it.
    function testClearingTheModuleIsStillAllowed() public {
        vm.prank(admin);
        fund.setPerformanceFeeRate(0);

        vm.prank(admin);
        fund.setPerformanceFeeModule(address(0));
        assertEq(fund.performanceFeeModule(), address(0), "the module can still be removed");
    }

    /// @notice A module that LOSES its code cannot halt settlement — the case the setter cannot catch.
    /// @dev The setter validates at write time; nothing stops a module from being a proxy that is
    ///      later pointed at nothing. `_chargePerformanceFee` must therefore check at call time too.
    function testModuleThatLosesItsCodeCannotBrickTheFund() public {
        vm.etch(healthyModule, ""); // the module's code goes away underneath the fund
        vm.warp(vm.getBlockTimestamp() + 7 hours);

        vm.prank(bob);
        uint256 id = fund.requestSubscription(1_000e6, 1, address(usdc), bob);
        _approve(id);
        assertEq(fund.balanceOf(bob), 1_000e18, "the batch settled despite a codeless module");

        // And the admin can still climb out: zero the rate, then swap in a working module.
        vm.prank(admin);
        fund.setPerformanceFeeRate(0);
        address replacement = address(new WatermarkFee());
        vm.prank(admin);
        fund.setPerformanceFeeModule(replacement);
        vm.prank(admin);
        fund.setPerformanceFeeRate(2000);
        assertEq(fund.performanceFeeRate(), 2000, "the fee can be turned back on");
    }

    /// @notice Redemptions survive it too — the path people need most in a crisis.
    function testRedemptionSurvivesACodelessModule() public {
        vm.etch(healthyModule, "");
        vm.warp(vm.getBlockTimestamp() + 7 hours);

        uint256 before = usdc.balanceOf(alice);
        vm.prank(alice);
        uint256 id = fund.requestRedemption(500e18, 1, address(usdc), alice);
        _approve(id);

        assertEq(usdc.balanceOf(alice) - before, 500e6, "the redeemer got paid");
    }

    function _params(address module, uint256 rate) internal view returns (KpkSharesNav.ConstructorParams memory) {
        return KpkSharesNav.ConstructorParams({
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
            performanceFeeRate: rate,
            navCalculator: address(nav),
            initialSharePrice: ONE_USD
        });
    }

    function _deployWithModule(address module, uint256 rate) internal returns (address) {
        address impl = address(new KpkSharesNav());
        return UnsafeUpgrades.deployUUPSProxy(impl, abi.encodeCall(KpkSharesNav.initialize, (_params(module, rate))));
    }
}
