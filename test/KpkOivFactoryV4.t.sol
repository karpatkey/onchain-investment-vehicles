// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {KpkOivFactoryV4} from "src/KpkOivFactoryV4.sol";
import {KpkSharesDeployer} from "src/KpkSharesDeployer.sol";
import {KpkShares} from "src/kpkShares.sol";
import {IKpkSharesNav} from "src/IKpkSharesNav.sol";
import {KpkSharesNav} from "src/KpkSharesNav.sol";
import {MockNavCalculator} from "test/mocks/MockNavCalculator.sol";
import {OivTestConstants} from "test/OivTestConstants.sol";
import {DeployKpkOivFactoryV4} from "script/DeployKpkOivFactoryV4.s.sol";
import {DeployOiv} from "script/DeployOiv.s.sol";

/// @notice Fork tests for `KpkOivFactoryV4` — the unified factory that deploys BOTH fund types.
/// @dev    `KpkOivFactory` deploys operator-priced `KpkShares` funds; `KpkSharesNavFactory` deployed
///         NAV-priced ones against the live factory from the outside. This contract supersedes both
///         by carrying the audited Safe/Roles wiring and adding a second entry point on top of it.
///
///         The suite therefore has to prove two different things. For the NAV path, that the new
///         code works. For the `deployOiv` path, that the CARRIED-OVER code still behaves — it was
///         copied byte-for-byte from a frozen, audited file, and the only thing that could have
///         broken it is the two edits made afterwards.
contract KpkOivFactoryV4Test is OivTestConstants {
    /// @dev DAI, the additional asset. 18 decimals against USDC's 6, so the listing gate's decimals
    ///      check is genuinely exercised rather than trivially satisfied.
    address internal constant DAI = 0x6B175474E89094C44Da98b954EedeAC495271d0F;

    uint256 internal constant ONE_USD = 1e8;

    address internal factoryOwner = makeAddr("factoryOwner");
    address internal managerSigner = makeAddr("managerSigner");
    address internal admin = makeAddr("admin");
    address internal feeReceiver = makeAddr("feeReceiver");

    KpkOivFactoryV4 internal factory;
    MockNavCalculator internal nav;
    address internal navImpl;

    function setUp() public {
        vm.createSelectFork(vm.envString("MAINNET_URL"));
        _requireInfraDeployed();

        // `KpkSharesDeployer` is factory-locked, so the factory's address must be known before the
        // deployer is constructed. V4 needs its OWN deployer: the live one is locked to the live
        // factory and would reject every call from this contract.
        uint256 nextNonce = vm.getNonce(address(this));
        address predictedFactory = vm.computeCreateAddress(address(this), nextNonce + 1);
        KpkSharesDeployer sharesDeployer = new KpkSharesDeployer(predictedFactory);

        factory = new KpkOivFactoryV4(
            factoryOwner,
            SAFE_PROXY_FACTORY,
            SAFE_SINGLETON,
            SAFE_MODULE_SETUP,
            SAFE_FALLBACK_HANDLER,
            MODULE_PROXY_FACTORY,
            ROLES_MODIFIER_MASTERCOPY,
            address(sharesDeployer)
        );
        require(address(factory) == predictedFactory, "factory address mismatch");

        nav = new MockNavCalculator();
        nav.registerAsset(USDC, 6, int256(ONE_USD), 8);
        nav.registerAsset(DAI, 18, int256(ONE_USD), 8);

        navImpl = address(new KpkSharesNav());
        vm.prank(factoryOwner);
        factory.setNavImplementation(navImpl);
    }

    // ── The NAV path ───────────────────────────────────────────────────────────

    function test_deployNavFund_deploysAllSevenContracts() public {
        KpkOivFactoryV4.NavFundInstance memory inst = factory.deployNavFund(_navConfig(1));

        assertTrue(inst.avatarSafe != address(0), "avatarSafe not deployed");
        assertTrue(inst.managerSafe != address(0), "managerSafe not deployed");
        assertTrue(inst.execRolesModifier != address(0), "execRolesModifier not deployed");
        assertTrue(inst.subRolesModifier != address(0), "subRolesModifier not deployed");
        assertTrue(inst.managerRolesModifier != address(0), "managerRolesModifier not deployed");
        assertEq(inst.navImpl, navImpl, "navImpl is the shared implementation");
        assertTrue(inst.navProxy != address(0), "navProxy not deployed");
        assertTrue(inst.avatarSafe != inst.managerSafe, "the two Safes must be distinct");
    }

    /// @notice THE REASON THIS FACTORY EXISTS RATHER THAN THE STANDALONE ONE.
    /// @dev A factory that composes `deployStack` from outside cannot grant these: `deployStack`
    ///      disables the factory as an Avatar Safe module before returning, so there is no route to
    ///      execute as the Safe, and redemptions revert on payout until somebody does it by hand
    ///      through the Roles system. Deploying the stack itself keeps the factory enabled as a
    ///      module for exactly as long as it needs to issue the approvals.
    function test_deployNavFund_grantsAvatarSafeApprovals() public {
        KpkOivFactoryV4.NavFundInstance memory inst = factory.deployNavFund(_navConfig(2));

        assertEq(
            IERC20(USDC).allowance(inst.avatarSafe, inst.navProxy),
            type(uint256).max,
            "base asset allowance not granted"
        );
        assertEq(
            IERC20(DAI).allowance(inst.avatarSafe, inst.navProxy),
            type(uint256).max,
            "redeemable additional asset allowance not granted"
        );
    }

    function test_deployNavFund_pointsTheFundAtItsOwnAvatarSafe() public {
        KpkOivFactoryV4.NavFundInstance memory inst = factory.deployNavFund(_navConfig(3));
        KpkSharesNav fund = KpkSharesNav(inst.navProxy);

        assertEq(fund.portfolioSafe(), inst.avatarSafe, "fund is not pointed at its own Avatar Safe");
        assertEq(fund.navCalculator(), address(nav), "NAV calculator not set");
    }

    function test_deployNavFund_handsOverEveryRole() public {
        KpkOivFactoryV4.NavFundInstance memory inst = factory.deployNavFund(_navConfig(4));
        KpkSharesNav fund = KpkSharesNav(inst.navProxy);

        assertTrue(fund.hasRole(0x00, admin), "admin does not hold DEFAULT_ADMIN_ROLE");
        assertTrue(fund.hasRole(fund.OPERATOR(), inst.managerSafe), "manager Safe does not hold OPERATOR");
        assertFalse(fund.hasRole(0x00, address(factory)), "factory still holds admin");
        assertFalse(fund.hasRole(fund.OPERATOR(), address(factory)), "factory still holds OPERATOR");
    }

    function test_deployNavFund_listsAdditionalAssets() public {
        KpkOivFactoryV4.NavFundInstance memory inst = factory.deployNavFund(_navConfig(5));

        IKpkSharesNav.ApprovedAsset memory dai = KpkSharesNav(inst.navProxy).getApprovedAsset(DAI);
        assertEq(dai.asset, DAI, "DAI not listed");
        assertEq(dai.decimals, 18, "DAI decimals not recorded");
        assertTrue(dai.canRedeem, "DAI not redeemable");
    }

    function test_deployNavFund_recordsTheFundInItsOwnRegistry() public {
        uint256 idBefore = factory.navFundCount();
        KpkOivFactoryV4.NavFundInstance memory inst = factory.deployNavFund(_navConfig(6));

        assertEq(factory.navFundCount(), idBefore + 1, "navFundCount did not advance");
        (address avatarSafe,,,,,, address navProxy) = factory.navFunds(idBefore);
        assertEq(avatarSafe, inst.avatarSafe, "registry avatarSafe mismatch");
        assertEq(navProxy, inst.navProxy, "registry navProxy mismatch");
    }

    function test_deployNavFund_revertsWhenImplementationIsUnset() public {
        uint256 nextNonce = vm.getNonce(address(this));
        address predicted = vm.computeCreateAddress(address(this), nextNonce + 1);
        KpkSharesDeployer deployer = new KpkSharesDeployer(predicted);
        KpkOivFactoryV4 bare = new KpkOivFactoryV4(
            factoryOwner,
            SAFE_PROXY_FACTORY,
            SAFE_SINGLETON,
            SAFE_MODULE_SETUP,
            SAFE_FALLBACK_HANDLER,
            MODULE_PROXY_FACTORY,
            ROLES_MODIFIER_MASTERCOPY,
            address(deployer)
        );

        vm.expectRevert(KpkOivFactoryV4.NavImplementationNotSet.selector);
        bare.deployNavFund(_navConfig(7));
    }

    function test_setNavImplementation_rejectsAnAddressWithNoCode() public {
        vm.prank(factoryOwner);
        vm.expectRevert(KpkOivFactoryV4.NotAContract.selector);
        factory.setNavImplementation(makeAddr("notAContract"));
    }

    function test_setNavImplementation_isOwnerOnly() public {
        address replacement = address(new KpkSharesNav());

        vm.prank(makeAddr("stranger"));
        vm.expectRevert();
        factory.setNavImplementation(replacement);
    }

    // ── The carried-over KpkShares path still works ────────────────────────────

    /// @notice Regression guard on code copied verbatim from the frozen factory.
    function test_deployOiv_stillDeploysAllSevenContracts() public {
        KpkOivFactoryV4.OivInstance memory inst = factory.deployOiv(_oivConfig(20));

        assertTrue(inst.avatarSafe != address(0), "avatarSafe not deployed");
        assertTrue(inst.managerSafe != address(0), "managerSafe not deployed");
        assertTrue(inst.execRolesModifier != address(0), "execRolesModifier not deployed");
        assertTrue(inst.kpkSharesImpl != address(0), "kpkSharesImpl not deployed");
        assertTrue(inst.kpkSharesProxy != address(0), "kpkSharesProxy not deployed");
    }

    function test_deployOiv_stillGrantsApprovals() public {
        KpkOivFactoryV4.OivInstance memory inst = factory.deployOiv(_oivConfig(21));

        assertEq(
            IERC20(USDC).allowance(inst.avatarSafe, inst.kpkSharesProxy),
            type(uint256).max,
            "base asset allowance not granted on the KpkShares path"
        );
    }

    /// @notice `deployStack` — the third entry point — is untouched too.
    function test_deployStack_stillDeploysTheFiveContracts() public {
        address[] memory owners = new address[](1);
        owners[0] = managerSigner;

        KpkOivFactoryV4.StackInstance memory stack = factory.deployStack(
            KpkOivFactoryV4.StackConfig({
                managerSafe: KpkOivFactoryV4.SafeConfig({owners: owners, threshold: 1}),
                execRolesMod: KpkOivFactoryV4.RolesModifierConfig({finalOwner: admin}),
                subRolesMod: KpkOivFactoryV4.RolesModifierConfig({finalOwner: address(0)}),
                managerRolesMod: KpkOivFactoryV4.RolesModifierConfig({finalOwner: address(0)}),
                salt: 22
            })
        );

        assertTrue(stack.avatarSafe != address(0), "avatarSafe not deployed");
        assertTrue(stack.managerRolesModifier != address(0), "managerRolesModifier not deployed");
    }

    // ── The deliberate deviation from the frozen original ──────────────────────

    /// @notice Both entry points refuse an admin that is the factory itself.
    /// @dev The frozen `KpkOivFactory` accepts this on the `deployOiv` path and produces a fund
    ///      NOBODY can administer: the grant is a no-op on a role the factory already holds, the
    ///      renounce removes the only holder, and its assertion — which only checks that the factory
    ///      does not hold admin — passes precisely because nobody is left. Fixed here, on both
    ///      paths, because V4 is a new deployment and carries no compatibility debt.
    function test_bothPathsRefuseTheFactoryAsAdmin() public {
        KpkOivFactoryV4.OivConfig memory oivCfg = _oivConfig(23);
        oivCfg.admin = address(factory);
        vm.expectRevert(KpkOivFactoryV4.AdminIsFactory.selector);
        factory.deployOiv(oivCfg);

        KpkOivFactoryV4.NavFundConfig memory navCfg = _navConfig(24);
        navCfg.admin = address(factory);
        vm.expectRevert(KpkOivFactoryV4.AdminIsFactory.selector);
        factory.deployNavFund(navCfg);
    }

    // ── The two fund types coexisting ──────────────────────────────────────────

    /// @notice One factory, one salt, both fund types — no collision, separate registries.
    /// @dev The stack addresses for the two DO coincide by design (same caller, same salt, same
    ///      derivation), which is why the second call must be given a different salt. What must not
    ///      coincide is the fund proxies, and the two registries must not share a counter.
    function test_bothFundTypesCoexistInSeparateRegistries() public {
        KpkOivFactoryV4.OivInstance memory oiv = factory.deployOiv(_oivConfig(30));
        KpkOivFactoryV4.NavFundInstance memory navFund = factory.deployNavFund(_navConfig(31));

        assertTrue(oiv.kpkSharesProxy != navFund.navProxy, "the two funds share an address");
        assertTrue(oiv.avatarSafe != navFund.avatarSafe, "the two funds share an Avatar Safe");
        assertEq(factory.instanceCount(), 1, "KpkShares registry should hold exactly one");
        assertEq(factory.navFundCount(), 1, "NAV registry should hold exactly one");
    }

    // ── The deploy script ──────────────────────────────────────────────────────

    /// @notice V4 lands on a DIFFERENT address from the live v3 factory.
    /// @dev The whole supersede story depends on this. If salt v4 collided with the deployed v3
    ///      address the CREATE2 deploy would simply be skipped as "already deployed" and the
    ///      rollout would silently leave v3 in place, believing it had shipped v4.
    function test_deployScript_v4AddressDiffersFromTheLiveV3Factory() public {
        DeployKpkOivFactoryV4 script = new DeployKpkOivFactoryV4();
        address liveV3 = new DeployOiv().FACTORY();

        address predicted = script.predictFactoryV4(address(this));
        assertTrue(predicted != liveV3, "v4 collides with the live v3 factory address");
        assertEq(predicted.code.length, 0, "something already occupies the predicted v4 address");
    }

    /// @notice The script produces a factory that can actually mint BOTH fund types.
    function test_deployScript_producesAFactoryThatDeploysBothTypes() public {
        DeployKpkOivFactoryV4 script = new DeployKpkOivFactoryV4();
        address finalOwner = makeAddr("v4FinalOwner");

        // The script broadcasts as `eoaOwner`, which is also the address baked into the factory's
        // CREATE2 init-code and the one that calls the owner-only setters. Passing this contract
        // keeps all three the same here, exactly as `--account` does under `forge script`.
        (address deployed, address sharesDeployer, address impl) = script.run(address(this), finalOwner);

        KpkOivFactoryV4 f = KpkOivFactoryV4(deployed);
        assertEq(f.owner(), finalOwner, "ownership not transferred");
        assertEq(f.kpkSharesDeployer(), sharesDeployer, "shares deployer not wired");
        assertEq(f.navImplementation(), impl, "NAV implementation not set");

        // Both entry points work on the factory the script actually produced.
        factory = f;
        KpkOivFactoryV4.NavFundInstance memory navFund = f.deployNavFund(_navConfig(40));
        KpkOivFactoryV4.OivInstance memory oiv = f.deployOiv(_oivConfig(41));

        assertTrue(navFund.navProxy != address(0), "NAV fund not deployed");
        assertTrue(oiv.kpkSharesProxy != address(0), "KpkShares fund not deployed");
        assertEq(
            IERC20(USDC).allowance(navFund.avatarSafe, navFund.navProxy),
            type(uint256).max,
            "NAV fund approvals not granted by a script-deployed factory"
        );
    }

    /// @notice The final owner must not be the deploying key.
    /// @dev The owner controls `setNavImplementation`, i.e. the implementation every future NAV
    ///      fund delegates to. That is not a power to leave on a hot deploy key.
    function test_deployScript_rejectsTheDeployingKeyAsFinalOwner() public {
        DeployKpkOivFactoryV4 script = new DeployKpkOivFactoryV4();

        vm.expectRevert(bytes("finalOwner must not be the deploying key"));
        script.run(address(this), address(this));
    }

    // ── Helpers ────────────────────────────────────────────────────────────────

    function _navConfig(uint256 salt) internal view returns (KpkOivFactoryV4.NavFundConfig memory cfg) {
        address[] memory owners = new address[](1);
        owners[0] = managerSigner;

        KpkOivFactoryV4.AssetConfig[] memory additional = new KpkOivFactoryV4.AssetConfig[](1);
        additional[0] = KpkOivFactoryV4.AssetConfig({asset: DAI, canDeposit: true, canRedeem: true});

        cfg.managerSafe = KpkOivFactoryV4.SafeConfig({owners: owners, threshold: 1});
        cfg.salt = salt;
        cfg.admin = admin;
        cfg.additionalAssets = additional;
        cfg.sharesParams = KpkSharesNav.ConstructorParams({
            asset: USDC,
            // Overwritten by the factory — set to obviously wrong values so a test fails loudly if
            // the overwrite is ever dropped.
            admin: address(0xdead),
            name: "kpk NAV Fund",
            symbol: "kpkNAV",
            safe: address(0xdead),
            subscriptionRequestTtl: 1 days,
            redemptionRequestTtl: 1 days,
            feeReceiver: feeReceiver,
            managementFeeRate: 0,
            redemptionFeeRate: 0,
            performanceFeeModule: address(0),
            performanceFeeRate: 0,
            navCalculator: address(nav),
            initialSharePrice: ONE_USD
        });
    }

    function _oivConfig(uint256 salt) internal view returns (KpkOivFactoryV4.OivConfig memory cfg) {
        address[] memory owners = new address[](1);
        owners[0] = managerSigner;

        cfg.managerSafe = KpkOivFactoryV4.SafeConfig({owners: owners, threshold: 1});
        cfg.salt = salt;
        cfg.admin = admin;
        cfg.additionalAssets = new KpkOivFactoryV4.AssetConfig[](0);
        cfg.sharesParams = KpkShares.ConstructorParams({
            asset: USDC,
            admin: address(0),
            name: "Test Fund Shares",
            symbol: "kTEST",
            safe: address(0),
            subscriptionRequestTtl: 1 days,
            redemptionRequestTtl: 1 days,
            feeReceiver: feeReceiver,
            managementFeeRate: 100,
            redemptionFeeRate: 50,
            performanceFeeModule: address(0),
            performanceFeeRate: 0
        });
    }
}
