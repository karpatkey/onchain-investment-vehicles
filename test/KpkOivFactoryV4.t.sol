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
import {ISafe} from "src/interfaces/ISafe.sol";
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

    // ── Round-6 invariant pins ─────────────────────────────────────────────────

    /// @notice Reusing one salt across two entry points REVERTS rather than aliasing a Safe.
    /// @dev The five stack addresses derive from `_deriveSalts(config.salt, msg.sender)` with the
    ///      same component indices 0-4 for ALL THREE entry points, so the same `(caller, salt)`
    ///      targets the SAME Avatar Safe regardless of which entry point asks for it. The only thing
    ///      standing between that and a NAV fund silently adopting an existing KpkShares fund's
    ///      Avatar Safe — pricing itself off someone else's book and minting against it — is that
    ///      the Zodiac `ModuleProxyFactory` reverts `TakenAddress` on an occupied address.
    ///
    ///      That guarantee lives in third-party deployed bytecode and is asserted NOWHERE in this
    ///      repo; the factory codehash-checks `EMPTY_CONTRACT` and the MultiSends but not the module
    ///      or Safe proxy factories. In V3 this was unreachable — there was one fund-minting entry
    ///      point. V4 makes it reachable, so it is pinned here. If a target chain ever hosts a
    ///      module factory that overwrites instead of reverting, this test is what fails.
    ///
    ///      A bare `expectRevert` on purpose: the revert comes from external bytecode whose exact
    ///      error may differ by chain and version, and pinning the selector would make this test
    ///      fail for the wrong reason on a chain that still behaves correctly.
    function test_sameSaltAcrossEntryPointsReverts() public {
        factory.deployOiv(_oivConfig(777));
        vm.expectRevert();
        factory.deployNavFund(_navConfig(777));
    }

    function test_sameSaltAcrossEntryPointsRevertsInTheOtherOrder() public {
        factory.deployNavFund(_navConfig(888));
        vm.expectRevert();
        factory.deployOiv(_oivConfig(888));
    }

    function test_sameSaltAfterDeployStackReverts() public {
        address[] memory owners = new address[](1);
        owners[0] = managerSigner;
        factory.deployStack(
            KpkOivFactoryV4.StackConfig({
                managerSafe: KpkOivFactoryV4.SafeConfig({owners: owners, threshold: 1}),
                execRolesMod: KpkOivFactoryV4.RolesModifierConfig({finalOwner: admin}),
                subRolesMod: KpkOivFactoryV4.RolesModifierConfig({finalOwner: address(0)}),
                managerRolesMod: KpkOivFactoryV4.RolesModifierConfig({finalOwner: address(0)}),
                salt: 999
            })
        );
        vm.expectRevert();
        factory.deployNavFund(_navConfig(999));
    }

    /// @notice `canDeposit` and `canRedeem` are threaded INDEPENDENTLY, and only redeemables get an
    ///         allowance.
    /// @dev The existing listing test used `canDeposit = canRedeem = true` and asserted only
    ///      `canRedeem`, so swapping the two adjacent bools at the `updateAsset` call site would
    ///      compile, deploy, and pass the whole suite while shipping funds with inverted permissions.
    ///      Asymmetric flags are what make the assertion bind. The allowance check pins the other
    ///      half: `_grantApprovals` deliberately approves only assets marked redeemable.
    function test_assetFlagsAreThreadedIndependently() public {
        KpkOivFactoryV4.NavFundConfig memory cfg = _navConfig(41);
        cfg.additionalAssets[0].canDeposit = true;
        cfg.additionalAssets[0].canRedeem = false;

        KpkOivFactoryV4.NavFundInstance memory inst = factory.deployNavFund(cfg);
        IKpkSharesNav.ApprovedAsset memory dai = KpkSharesNav(inst.navProxy).getApprovedAsset(DAI);

        assertTrue(dai.canDeposit, "canDeposit should be true");
        assertFalse(dai.canRedeem, "canRedeem should be false - the two flags may be swapped");
        assertEq(
            IERC20(DAI).allowance(inst.avatarSafe, inst.navProxy), 0, "a non-redeemable asset must not be approved"
        );
    }

    /// @notice A fund can never be deployed holding an asset the NAV calculator cannot price.
    function test_deployNavFund_revertsWhenTheBaseAssetIsNotRegistered() public {
        nav.unregisterAsset(USDC);
        vm.expectRevert();
        factory.deployNavFund(_navConfig(42));
    }

    function test_deployNavFund_revertsWhenAnAdditionalAssetIsNotRegistered() public {
        nav.unregisterAsset(DAI);
        vm.expectRevert();
        factory.deployNavFund(_navConfig(43));
    }

    /// @notice The factory must not remain an enabled module on the Avatar Safe.
    /// @dev The module window is the only interval in which the factory can execute as the Safe. If
    ///      it ever survived the call, the factory — permissionless, and able to run caller-supplied
    ///      calculator code — would be a standing backdoor into a live fund's assets.
    function test_factoryIsNotAModuleAfterDeployNavFund() public {
        KpkOivFactoryV4.NavFundInstance memory inst = factory.deployNavFund(_navConfig(44));
        assertFalse(
            ISafe(inst.avatarSafe).isModuleEnabled(address(factory)), "factory is still an enabled Avatar Safe module"
        );
    }

    /// @notice End to end: money actually moves, using the allowance the factory granted.
    /// @dev This is the test that proves why V4 exists rather than the standalone factory it
    ///      replaced. That one could not grant the Avatar Safe's approvals, so a redemption reverted
    ///      on payout until somebody sent a manual Roles-routed transaction. Asserting the allowance
    ///      VALUE (as the other test does) only shows a number in a mapping; this asserts a redeemer
    ///      is actually paid out of the Safe through it.
    function test_endToEnd_subscribeThenRedeemThroughFactoryGrantedApprovals() public {
        KpkOivFactoryV4.NavFundInstance memory inst = factory.deployNavFund(_navConfig(45));
        KpkSharesNav fund = KpkSharesNav(inst.navProxy);

        // Price the fund off the Avatar Safe's real USDC balance, so settlement is not measured
        // against a static number that would make the assertions vacuous.
        nav.setNavAccount(inst.avatarSafe);
        nav.trackBalance(USDC, 1e2); // 6-decimal USDC -> 8-decimal USD

        address investor = makeAddr("investor");
        deal(USDC, investor, 1_000e6);
        vm.prank(investor);
        IERC20(USDC).approve(address(fund), type(uint256).max);

        vm.prank(investor);
        uint256 subId = fund.requestSubscription(1_000e6, 1, USDC, investor);

        uint256[] memory approveIds = new uint256[](1);
        approveIds[0] = subId;
        uint256[] memory none = new uint256[](0);

        vm.prank(inst.managerSafe);
        fund.processRequests(approveIds, none, USDC);

        assertGt(fund.balanceOf(investor), 0, "no shares minted");
        assertEq(IERC20(USDC).balanceOf(inst.avatarSafe), 1_000e6, "deposit did not reach the Avatar Safe");

        // Redeem. The payout pulls from the Avatar Safe via the allowance the FACTORY granted.
        uint256 shares = fund.balanceOf(investor);
        vm.prank(investor);
        uint256 redId = fund.requestRedemption(shares, 1, USDC, investor);

        approveIds[0] = redId;
        vm.prank(inst.managerSafe);
        fund.processRequests(approveIds, none, USDC);

        assertEq(IERC20(USDC).balanceOf(investor), 1_000e6, "redeemer was not paid out of the Avatar Safe");
        assertEq(fund.balanceOf(investor), 0, "shares not burned");
    }

    /// @notice Re-running the deploy script after ownership handover is a clean no-op.
    /// @dev Under `forge script` each call is its own broadcast TRANSACTION, so an unconditional
    ///      `new KpkSharesNav()` followed by an owner-only `setNavImplementation` does not fail
    ///      atomically: the implementation deploy LANDS and only the setter reverts, leaving an
    ///      orphan contract and burnt gas. Re-running is a normal operational act during a 19-chain
    ///      rollout — a retry after a dropped transaction — and the script's own `[SKIP]` branches
    ///      advertise idempotency it did not actually have.
    function test_deployScript_isIdempotentOnRerun() public {
        DeployKpkOivFactoryV4 script = new DeployKpkOivFactoryV4();
        address finalOwner = makeAddr("v4RerunOwner");

        (address f1, address d1, address impl1) = script.run(address(this), finalOwner);
        (address f2, address d2, address impl2) = script.run(address(this), finalOwner);

        assertEq(f2, f1, "factory address changed on rerun");
        assertEq(d2, d1, "shares deployer address changed on rerun");
        assertEq(impl2, impl1, "rerun deployed a second implementation instead of reusing the configured one");
        assertEq(KpkOivFactoryV4(f1).owner(), finalOwner, "ownership disturbed by the rerun");
    }

    // ── `_validateNavFundConfig` negative paths ────────────────────────────────
    //
    // The NAV validator is a hand-written near-duplicate of `_validateOivConfig`, not a shared
    // helper — deliberately, because sharing them would have meant editing the copied body and
    // giving up the "frozen bytes + 4 hunks" property that makes this contract reviewable. The cost
    // of that choice is that the two can drift, and until these tests existed NOTHING exercised the
    // NAV copy's rejections: the repo's `DuplicateAsset` / `ZeroAddress` / `InvalidSharesParams`
    // expectations all run against the frozen V3 contract and never construct a V4 at all.

    function test_deployNavFund_revertsOnDuplicateAdditionalAssets() public {
        KpkOivFactoryV4.NavFundConfig memory cfg = _navConfig(50);
        cfg.additionalAssets = new KpkOivFactoryV4.AssetConfig[](2);
        cfg.additionalAssets[0] = KpkOivFactoryV4.AssetConfig({asset: DAI, canDeposit: true, canRedeem: true});
        cfg.additionalAssets[1] = KpkOivFactoryV4.AssetConfig({asset: DAI, canDeposit: true, canRedeem: true});

        vm.expectRevert(KpkOivFactoryV4.DuplicateAsset.selector);
        factory.deployNavFund(cfg);
    }

    /// @dev Re-listing the base asset would overwrite its flags with whatever is passed here. Unlike
    ///      the KpkShares path there is no `isFeeModuleAsset` field to make the mistake surface
    ///      elsewhere, so a base asset silently re-listed with `canDeposit = false` would ship a
    ///      fund nobody can subscribe to.
    function test_deployNavFund_revertsWhenAnAdditionalAssetIsTheBaseAsset() public {
        KpkOivFactoryV4.NavFundConfig memory cfg = _navConfig(51);
        cfg.additionalAssets[0].asset = USDC;

        vm.expectRevert(KpkOivFactoryV4.DuplicateAsset.selector);
        factory.deployNavFund(cfg);
    }

    function test_deployNavFund_revertsOnZeroAdditionalAsset() public {
        KpkOivFactoryV4.NavFundConfig memory cfg = _navConfig(52);
        cfg.additionalAssets[0].asset = address(0);

        vm.expectRevert(KpkOivFactoryV4.ZeroAddress.selector);
        factory.deployNavFund(cfg);
    }

    function test_deployNavFund_revertsOnZeroBaseAsset() public {
        KpkOivFactoryV4.NavFundConfig memory cfg = _navConfig(53);
        cfg.sharesParams.asset = address(0);

        vm.expectRevert(KpkOivFactoryV4.ZeroAddress.selector);
        factory.deployNavFund(cfg);
    }

    function test_deployNavFund_revertsOnUnsetFeeReceiver() public {
        KpkOivFactoryV4.NavFundConfig memory cfg = _navConfig(54);
        cfg.sharesParams.feeReceiver = address(0);

        vm.expectRevert(KpkOivFactoryV4.InvalidSharesParams.selector);
        factory.deployNavFund(cfg);
    }

    function test_deployNavFund_revertsOnZeroTtl() public {
        KpkOivFactoryV4.NavFundConfig memory cfg = _navConfig(55);
        cfg.sharesParams.subscriptionRequestTtl = 0;

        vm.expectRevert(KpkOivFactoryV4.InvalidSharesParams.selector);
        factory.deployNavFund(cfg);
    }

    /// @notice A fund with NO additional assets — the most likely production shape — deploys and
    ///         wires correctly.
    /// @dev Every other test in this suite lists DAI, so `additionalAssets.length == 0` never ran.
    ///      That branch skips the `grantRole(OPERATOR, this)` / `revokeRole(OPERATOR, this)` bracket
    ///      in `_deployNavProxy` entirely, taking a different route through the `RoleHandoverFailed`
    ///      backstop — the one where the factory never holds OPERATOR in the first place. Worth
    ///      pinning precisely because it is the path a real deployment is most likely to take.
    function test_deployNavFund_withNoAdditionalAssets() public {
        KpkOivFactoryV4.NavFundConfig memory cfg = _navConfig(56);
        cfg.additionalAssets = new KpkOivFactoryV4.AssetConfig[](0);

        KpkOivFactoryV4.NavFundInstance memory inst = factory.deployNavFund(cfg);
        KpkSharesNav fund = KpkSharesNav(inst.navProxy);

        assertTrue(fund.hasRole(0x00, admin), "admin does not hold DEFAULT_ADMIN_ROLE");
        assertTrue(fund.hasRole(fund.OPERATOR(), inst.managerSafe), "manager Safe does not hold OPERATOR");
        assertFalse(fund.hasRole(fund.OPERATOR(), address(factory)), "factory retained OPERATOR");
        assertFalse(fund.hasRole(0x00, address(factory)), "factory retained admin");
        assertEq(
            IERC20(USDC).allowance(inst.avatarSafe, inst.navProxy),
            type(uint256).max,
            "base asset allowance not granted"
        );
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
