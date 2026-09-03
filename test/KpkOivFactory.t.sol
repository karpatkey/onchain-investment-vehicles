// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {KpkOivFactory} from "src/KpkOivFactory.sol";
import {KpkSharesDeployer} from "src/KpkSharesDeployer.sol";
import {KpkTimelockDeployer} from "src/KpkTimelockDeployer.sol";
import {TimelockParams} from "src/interfaces/IKpkTimelockDeployer.sol";
import {TimelockController} from "@openzeppelin/contracts/governance/TimelockController.sol";
import {KpkShares} from "src/kpkShares.sol";
import {IkpkShares} from "src/IkpkShares.sol";
import {ISafe} from "src/interfaces/ISafe.sol";
import {IRoles} from "src/interfaces/IRoles.sol";
import {OivTestConstants} from "test/OivTestConstants.sol";

/// @notice Fork tests for KpkOivFactory against mainnet Safe and Zodiac contracts.
///         Run with: forge test --match-contract KpkOivFactoryTest --fork-url $MAINNET_URL -vvv
///         Fork prerequisite: OivInfraConstants.ROLES_MODIFIER_MASTERCOPY (the Roles Modifier v2.1.1
///         mastercopy) must have bytecode at the forked block — proxy deployment reverts
///         TargetHasNoCode otherwise. It is live on mainnet, so a latest fork is fine; only a fork
///         pinned before its deploy block fails.

contract KpkOivFactoryTest is OivTestConstants {
    // USDC + Safe/Zodiac infra (SAFE_*, MODULE_PROXY_FACTORY, ROLES_MODIFIER_MASTERCOPY) are inherited
    // from OivTestConstants — the single test-side source.

    // ── Test accounts ───────────────────────────────────────────────────────────

    address factoryOwner = makeAddr("factoryOwner");
    address securityCouncil = makeAddr("securityCouncil");
    address managerSigner = makeAddr("managerSigner");
    address admin = makeAddr("admin");
    address feeReceiver = makeAddr("feeReceiver");

    // ── Contracts under test ────────────────────────────────────────────────────

    KpkOivFactory factory;
    KpkTimelockDeployer timelockDeployer;

    KpkOivFactory.OivConfig oivConfig;

    /// @dev Derived from the signature rather than mirrored from `OivInfraConstants`, so these tests
    ///      independently check the selector the factory registers the unwrap adapter against.
    bytes4 internal constant MULTI_SEND_SELECTOR = bytes4(keccak256("multiSend(bytes)"));

    /// @dev `ConditionViolation(Status,bytes32)` — the error Roles v2.1 wraps every failed
    ///      permission check in. The specific reason travels in the `Status` enum parameter, which
    ///      is why assertions match on the selector rather than on a bare error signature.
    bytes4 internal constant CONDITION_VIOLATION_SELECTOR = bytes4(keccak256("ConditionViolation(uint8,bytes32)"));

    // ── Setup ───────────────────────────────────────────────────────────────────

    function setUp() public {
        vm.createSelectFork(vm.envString("MAINNET_URL"));
        _requireInfraDeployed();

        // KpkSharesDeployer is now factory-locked. Pre-compute the factory address so the
        // deployer can be constructed with it: this contract's next nonce produces the
        // deployer, and the one after that produces the factory.
        // Nonce map for this contract: n = timelock deployer, n+1 = shares deployer, n+2 = factory.
        uint256 nextNonce = vm.getNonce(address(this));
        address predictedFactory = vm.computeCreateAddress(address(this), nextNonce + 2);

        timelockDeployer = new KpkTimelockDeployer();
        KpkSharesDeployer sharesDeployer = new KpkSharesDeployer(predictedFactory);

        factory = new KpkOivFactory(
            factoryOwner,
            SAFE_PROXY_FACTORY,
            SAFE_SINGLETON,
            SAFE_MODULE_SETUP,
            SAFE_FALLBACK_HANDLER,
            MODULE_PROXY_FACTORY,
            ROLES_MODIFIER_MASTERCOPY,
            address(sharesDeployer),
            address(timelockDeployer)
        );
        require(address(factory) == predictedFactory, "factory address mismatch");

        oivConfig = _buildOivConfig();
    }

    // ── deployOiv tests ────────────────────────────────────────────────────────

    function test_deployOiv_deploysAllSevenContracts() public {
        KpkOivFactory.OivInstance memory inst = factory.deployOiv(oivConfig);

        assertTrue(inst.avatarSafe != address(0), "avatarSafe not deployed");
        assertTrue(inst.managerSafe != address(0), "managerSafe not deployed");
        assertTrue(inst.execRolesModifier != address(0), "execRolesModifier not deployed");
        assertTrue(inst.subRolesModifier != address(0), "subRolesModifier not deployed");
        assertTrue(inst.managerRolesModifier != address(0), "managerRolesModifier not deployed");
        assertTrue(inst.kpkSharesImpl != address(0), "kpkSharesImpl not deployed");
        assertTrue(inst.kpkSharesProxy != address(0), "kpkSharesProxy not deployed");
    }

    function test_deployOiv_revertsWhenEmptyContractIsNotCanonical() public {
        // Fail-closed guarantee: a contract OTHER than the canonical Empty squatting EMPTY_CONTRACT
        // must revert. The old `code.length == 0` presence check would have wrongly accepted any
        // non-empty code here (e.g. a hostile ERC-1271 signer as the Avatar's sole owner); the codehash
        // guard rejects it.
        vm.etch(factory.EMPTY_CONTRACT(), hex"60006000fd"); // arbitrary non-Empty bytecode
        vm.expectRevert(KpkOivFactory.EmptyContractMissing.selector);
        factory.deployOiv(oivConfig);
    }

    function test_avatarSafe_hasExecModifierAsModule() public {
        KpkOivFactory.OivInstance memory inst = factory.deployOiv(oivConfig);

        assertTrue(
            ISafe(inst.avatarSafe).isModuleEnabled(inst.execRolesModifier),
            "execRolesModifier not a module of avatarSafe"
        );
    }

    function test_avatarSafe_ownerIsEmptyContract() public {
        KpkOivFactory.OivInstance memory inst = factory.deployOiv(oivConfig);

        address[] memory owners = ISafe(inst.avatarSafe).getOwners();
        assertEq(owners.length, 1, "avatarSafe should have exactly one owner");
        assertEq(owners[0], factory.EMPTY_CONTRACT(), "avatarSafe owner is not EMPTY_CONTRACT");
    }

    function test_factory_isNotModuleOfAvatarSafeAfterDeploy() public {
        KpkOivFactory.OivInstance memory inst = factory.deployOiv(oivConfig);

        assertFalse(
            ISafe(inst.avatarSafe).isModuleEnabled(address(factory)), "factory should not remain a module of avatarSafe"
        );
    }

    function test_managerSafe_hasManagerModifierAsModule() public {
        KpkOivFactory.OivInstance memory inst = factory.deployOiv(oivConfig);

        assertTrue(
            ISafe(inst.managerSafe).isModuleEnabled(inst.managerRolesModifier),
            "managerRolesModifier not a module of managerSafe"
        );
    }

    function test_execModifier_avatarIsAvatarSafe() public {
        KpkOivFactory.OivInstance memory inst = factory.deployOiv(oivConfig);

        assertEq(IRoles(inst.execRolesModifier).avatar(), inst.avatarSafe, "execMod avatar mismatch");
    }

    function test_execModifier_targetIsAvatarSafe() public {
        KpkOivFactory.OivInstance memory inst = factory.deployOiv(oivConfig);

        assertEq(IRoles(inst.execRolesModifier).target(), inst.avatarSafe, "execMod target mismatch");
    }

    function test_subModifier_avatarIsAvatarSafe() public {
        KpkOivFactory.OivInstance memory inst = factory.deployOiv(oivConfig);

        assertEq(IRoles(inst.subRolesModifier).avatar(), inst.avatarSafe, "subMod avatar mismatch");
    }

    function test_subModifier_targetIsExecModifier() public {
        KpkOivFactory.OivInstance memory inst = factory.deployOiv(oivConfig);

        assertEq(IRoles(inst.subRolesModifier).target(), inst.execRolesModifier, "subMod target mismatch");
    }

    function test_managerModifier_avatarIsManagerSafe() public {
        KpkOivFactory.OivInstance memory inst = factory.deployOiv(oivConfig);

        assertEq(IRoles(inst.managerRolesModifier).avatar(), inst.managerSafe, "managerMod avatar mismatch");
    }

    function test_managerModifier_targetIsManagerSafe() public {
        KpkOivFactory.OivInstance memory inst = factory.deployOiv(oivConfig);

        assertEq(IRoles(inst.managerRolesModifier).target(), inst.managerSafe, "managerMod target mismatch");
    }

    /// @dev Proves MANAGER role is assigned to managerSafe on execRolesModifier by having
    ///      managerSafe execute a real transaction through it. The Security Council (owner)
    ///      first scopes a target and allows a function for the MANAGER role, then managerSafe
    ///      calls execTransactionWithRole — which succeeds only if managerSafe holds MANAGER.
    function test_execModifier_managerSafeHasManagerRole() public {
        KpkOivFactory.OivInstance memory inst = factory.deployOiv(oivConfig);

        bytes32 managerRole = bytes32("MANAGER");
        // Scope USDC and allow approve() for the MANAGER role — approving 0 always succeeds.
        bytes4 selector = IERC20.approve.selector;

        vm.startPrank(admin);
        IRoles(inst.execRolesModifier).scopeTarget(managerRole, USDC);
        IRoles(inst.execRolesModifier).allowFunction(managerRole, USDC, selector, 0);
        vm.stopPrank();

        // Manager Safe calls execTransactionWithRole — reverts with NoMembership() if
        // managerSafe does not hold the MANAGER role.
        vm.prank(inst.managerSafe);
        bool success = IRoles(inst.execRolesModifier)
            .execTransactionWithRole(USDC, 0, abi.encodeWithSelector(selector, address(1), 0), 0, managerRole, true);
        assertTrue(success, "managerSafe could not execute with MANAGER role on execRolesModifier");
    }

    function test_execModifier_hasSubModifierAsNestedModule() public {
        KpkOivFactory.OivInstance memory inst = factory.deployOiv(oivConfig);

        assertTrue(
            IRoles(inst.execRolesModifier).isModuleEnabled(inst.subRolesModifier),
            "subRolesModifier not enabled in execRolesModifier"
        );
    }

    function test_execModifier_ownerIsAdmin() public {
        KpkOivFactory.OivInstance memory inst = factory.deployOiv(oivConfig);

        assertEq(IRoles(inst.execRolesModifier).owner(), admin, "execMod owner is not admin");
    }

    function test_subModifier_ownerIsManagerSafe() public {
        KpkOivFactory.OivInstance memory inst = factory.deployOiv(oivConfig);

        assertEq(IRoles(inst.subRolesModifier).owner(), inst.managerSafe, "subMod owner is not managerSafe");
    }

    function test_managerModifier_ownerIsManagerSafe() public {
        KpkOivFactory.OivInstance memory inst = factory.deployOiv(oivConfig);

        assertEq(IRoles(inst.managerRolesModifier).owner(), inst.managerSafe, "managerMod owner is not managerSafe");
    }

    // ── MultiSend unwrapper wiring ─────────────────────────────────────────────
    //
    // Regression coverage for the oiv_prod_usd defect found on 2026-07-24: the factory deployed
    // Roles Modifiers with NO unwrap adapter registered, so every batched `multiSend` through them
    // reverted and could only be repaired by an owner transaction after handover.

    /// @dev The adapter is keyed on the `(target, selector)` pair: target in the high 20 bytes,
    ///      selector in the next 4. Mirrors `Roles.key(address,bytes4)`.
    function _unwrapperKey(address to, bytes4 selector) internal pure returns (bytes32) {
        return bytes32(bytes20(to)) | (bytes32(selector) >> 160);
    }

    function _assertUnwrappersRegistered(address mod, string memory label) internal view {
        assertEq(
            IRoles(mod).unwrappers(_unwrapperKey(factory.MULTI_SEND(), MULTI_SEND_SELECTOR)),
            factory.MULTISEND_UNWRAPPER(),
            string.concat(label, ": MultiSend unwrapper not registered")
        );
        assertEq(
            IRoles(mod).unwrappers(_unwrapperKey(factory.MULTI_SEND_CALLS_ONLY(), MULTI_SEND_SELECTOR)),
            factory.MULTISEND_UNWRAPPER(),
            string.concat(label, ": MultiSendCallsOnly unwrapper not registered")
        );
    }

    function test_deployOiv_registersMultiSendUnwrappersOnAllThreeModifiers() public {
        KpkOivFactory.OivInstance memory inst = factory.deployOiv(oivConfig);

        _assertUnwrappersRegistered(inst.execRolesModifier, "execMod");
        _assertUnwrappersRegistered(inst.subRolesModifier, "subMod");
        _assertUnwrappersRegistered(inst.managerRolesModifier, "managerMod");
    }

    function test_deployStack_registersMultiSendUnwrappersOnAllThreeModifiers() public {
        KpkOivFactory.StackInstance memory inst = factory.deployStack(factory.oivToStackConfig(oivConfig));

        _assertUnwrappersRegistered(inst.execRolesModifier, "execMod");
        _assertUnwrappersRegistered(inst.subRolesModifier, "subMod");
        _assertUnwrappersRegistered(inst.managerRolesModifier, "managerMod");
    }

    /// @dev Registration happens while the factory still owns the modifier — `setTransactionUnwrapper`
    ///      is `onlyOwner`, so wiring it after `transferOwnership` would be impossible without a
    ///      multisig transaction. Ownership having moved on is what makes the ordering load-bearing.
    function test_unwrappersRegisteredBeforeOwnershipHandover() public {
        KpkOivFactory.OivInstance memory inst = factory.deployOiv(oivConfig);

        assertEq(IRoles(inst.execRolesModifier).owner(), admin, "precondition: exec ownership already moved");
        _assertUnwrappersRegistered(inst.execRolesModifier, "execMod");

        // The factory can no longer touch it — proving the registration could not have happened later.
        // Read the constants first: an argument call would otherwise consume the prank and expectRevert.
        address multiSend = factory.MULTI_SEND();
        address unwrapper = factory.MULTISEND_UNWRAPPER();

        vm.prank(address(factory));
        vm.expectRevert();
        IRoles(inst.execRolesModifier).setTransactionUnwrapper(multiSend, MULTI_SEND_SELECTOR, unwrapper);
    }

    /// @dev End-to-end proof of the fix: the Manager Safe batches two calls through MultiSend and
    ///      routes them via the exec modifier. This is the exact operation that reverted on the live
    ///      fund. Then the unwrapper is cleared and the same batch is re-run to show it fails without
    ///      it — so the test would catch a silent regression in the registration, not just its absence.
    function test_execModifier_multiSendBatchExecutes() public {
        KpkOivFactory.OivInstance memory inst = factory.deployOiv(oivConfig);

        bytes32 managerRole = bytes32("MANAGER");
        bytes4 approveSel = IERC20.approve.selector;

        vm.startPrank(admin);
        IRoles(inst.execRolesModifier).scopeTarget(managerRole, USDC);
        IRoles(inst.execRolesModifier).allowFunction(managerRole, USDC, approveSel, 0);
        vm.stopPrank();

        bytes memory inner = abi.encodeWithSelector(approveSel, address(1), 0);
        bytes memory batch = abi.encodeWithSignature(
            "multiSend(bytes)",
            bytes.concat(
                abi.encodePacked(uint8(0), USDC, uint256(0), uint256(inner.length), inner),
                abi.encodePacked(uint8(0), USDC, uint256(0), uint256(inner.length), inner)
            )
        );

        // Read the constant into a local: as an argument it would be the call the prank applies to.
        address multiSend = factory.MULTI_SEND();

        // operation 1 = DELEGATECALL — MultiSend refuses to run any other way.
        vm.prank(inst.managerSafe);
        bool success = IRoles(inst.execRolesModifier).execTransactionWithRole(multiSend, 0, batch, 1, managerRole, true);
        assertTrue(success, "batched multiSend through execRolesModifier failed");

        // Negative control: without the adapter the identical batch is rejected. Assert the SPECIFIC
        // revert rather than a bare `expectRevert`, which would also pass on an unrelated failure and
        // stop proving the adapter is what makes the batch work. With no unwrapper registered the
        // modifier falls back to checking MULTI_SEND as an ordinary target, which the MANAGER role
        // has no clearance for; Roles v2.1 reports that as `ConditionViolation(Status, bytes32)`
        // rather than the bare `TargetAddressNotAllowed()`.
        vm.prank(admin);
        IRoles(inst.execRolesModifier).setTransactionUnwrapper(multiSend, MULTI_SEND_SELECTOR, address(0));

        vm.prank(inst.managerSafe);
        (bool ok2, bytes memory ret) = inst.execRolesModifier
            .call(
                abi.encodeWithSelector(
                    IRoles.execTransactionWithRole.selector, multiSend, uint256(0), batch, uint8(1), managerRole, true
                )
            );
        assertFalse(ok2, "batch still executed after the unwrapper was cleared");
        assertEq(
            bytes4(bytes.concat(ret[0], ret[1], ret[2], ret[3])),
            CONDITION_VIOLATION_SELECTOR,
            "expected a Roles permission rejection, not an unrelated revert"
        );
    }

    /// @dev `MultiSendCallOnly` is registered separately (the adapter is keyed on the
    ///      `(target, selector)` pair) and had no end-to-end coverage. It refuses inner
    ///      delegatecalls, so it is the safer of the two, but both must actually work.
    function test_execModifier_multiSendCallOnlyBatchExecutes() public {
        KpkOivFactory.OivInstance memory inst = factory.deployOiv(oivConfig);

        bytes32 managerRole = bytes32("MANAGER");
        vm.startPrank(admin);
        IRoles(inst.execRolesModifier).scopeTarget(managerRole, USDC);
        IRoles(inst.execRolesModifier).allowFunction(managerRole, USDC, IERC20.approve.selector, 0);
        vm.stopPrank();

        address multiSendCallsOnly = factory.MULTI_SEND_CALLS_ONLY();

        vm.prank(inst.managerSafe);
        bool ok = IRoles(inst.execRolesModifier)
            .execTransactionWithRole(multiSendCallsOnly, 0, _approveBatch(), 1, managerRole, true);
        assertTrue(ok, "batched multiSend through MultiSendCallOnly failed");
    }

    /// @dev The route the production incident was actually reported on. The sub modifier's target is
    ///      the exec modifier, so a batch sent here is unwrapped and permission-checked TWICE — once
    ///      by the sub modifier, then again by the exec modifier when the sub modifier calls through
    ///      under its default MANAGER role. That is why the fix has to register on BOTH; this test
    ///      fails if either registration is dropped.
    function test_subModifier_nestedMultiSendBatchExecutes() public {
        KpkOivFactory.OivInstance memory inst = factory.deployOiv(oivConfig);

        bytes32 managerRole = bytes32("MANAGER");
        address subOperator = makeAddr("subOperator");

        // The exec modifier already grants the sub modifier the MANAGER role (factory-wired).
        // Scope the target there, and give the sub modifier its own member + identical scoping.
        vm.startPrank(admin);
        IRoles(inst.execRolesModifier).scopeTarget(managerRole, USDC);
        IRoles(inst.execRolesModifier).allowFunction(managerRole, USDC, IERC20.approve.selector, 0);
        vm.stopPrank();

        bytes32[] memory roleKeys = new bytes32[](1);
        roleKeys[0] = managerRole;
        bool[] memory memberOf = new bool[](1);
        memberOf[0] = true;

        vm.startPrank(inst.managerSafe);
        IRoles(inst.subRolesModifier).assignRoles(subOperator, roleKeys, memberOf);
        IRoles(inst.subRolesModifier).scopeTarget(managerRole, USDC);
        IRoles(inst.subRolesModifier).allowFunction(managerRole, USDC, IERC20.approve.selector, 0);
        vm.stopPrank();

        address multiSend = factory.MULTI_SEND();

        vm.prank(subOperator);
        bool ok =
            IRoles(inst.subRolesModifier).execTransactionWithRole(multiSend, 0, _approveBatch(), 1, managerRole, true);
        assertTrue(ok, "nested batch through subRolesModifier failed");
    }

    /// @dev The manager modifier guards the Manager Safe itself. The factory assigns it no members,
    ///      so this asserts the registration landed rather than driving a call through it.
    function test_managerModifier_unwrappersUsableByItsOwner() public {
        KpkOivFactory.OivInstance memory inst = factory.deployOiv(oivConfig);

        _assertUnwrappersRegistered(inst.managerRolesModifier, "managerMod");

        // Its owner can still manage the registration post-handover (the recovery path).
        address multiSend = factory.MULTI_SEND();
        vm.prank(inst.managerSafe);
        IRoles(inst.managerRolesModifier).setTransactionUnwrapper(multiSend, MULTI_SEND_SELECTOR, address(0));
        assertEq(
            IRoles(inst.managerRolesModifier).unwrappers(_unwrapperKey(multiSend, MULTI_SEND_SELECTOR)),
            address(0),
            "managerMod owner could not clear its own registration"
        );
    }

    /// @dev Two `USDC.approve(address(1), 0)` calls, MultiSend-encoded.
    function _approveBatch() internal view returns (bytes memory) {
        bytes memory inner = abi.encodeWithSelector(IERC20.approve.selector, address(1), 0);
        return abi.encodeWithSignature(
            "multiSend(bytes)",
            bytes.concat(
                abi.encodePacked(uint8(0), USDC, uint256(0), uint256(inner.length), inner),
                abi.encodePacked(uint8(0), USDC, uint256(0), uint256(inner.length), inner)
            )
        );
    }

    /// @dev Fail closed when the canonical unwrapper has no code on this chain (as was the case on
    ///      Linea and Scroll until 2026-07-24). Deploying anyway would produce a fund that looks
    ///      correctly wired but rejects every batch.
    function test_deployOiv_revertsWhenUnwrapperHasNoCode() public {
        vm.etch(factory.MULTISEND_UNWRAPPER(), "");
        vm.expectRevert(KpkOivFactory.MultiSendUnwrapperMissing.selector);
        factory.deployOiv(oivConfig);
    }

    function test_deployStack_revertsWhenUnwrapperHasNoCode() public {
        // Build the config first — evaluating it as an argument would consume the expectRevert.
        KpkOivFactory.StackConfig memory stackConfig = factory.oivToStackConfig(oivConfig);

        vm.etch(factory.MULTISEND_UNWRAPPER(), "");
        vm.expectRevert(KpkOivFactory.MultiSendUnwrapperMissing.selector);
        factory.deployStack(stackConfig);
    }

    /// @dev The distinction a presence check cannot make: a DIFFERENT contract occupying the
    ///      address. Registering an unwrap adapter makes the registered MultiSend an unconditional,
    ///      un-permission-checked DELEGATECALL target for every role, so a non-canonical occupant is
    ///      a fund takeover rather than a degraded feature. `code.length != 0` would accept all three
    ///      of these; the codehash assert rejects them.
    function test_deployOiv_revertsWhenUnwrapperIsNotCanonical() public {
        vm.etch(factory.MULTISEND_UNWRAPPER(), hex"60006000fd");
        vm.expectRevert(KpkOivFactory.MultiSendUnwrapperMissing.selector);
        factory.deployOiv(oivConfig);
    }

    function test_deployOiv_revertsWhenMultiSendIsNotCanonical() public {
        address multiSend = factory.MULTI_SEND();

        vm.etch(multiSend, hex"60006000fd");
        vm.expectRevert(abi.encodeWithSelector(KpkOivFactory.MultiSendMissing.selector, multiSend));
        factory.deployOiv(oivConfig);
    }

    function test_deployOiv_revertsWhenMultiSendCallsOnlyIsNotCanonical() public {
        address multiSendCallsOnly = factory.MULTI_SEND_CALLS_ONLY();

        vm.etch(multiSendCallsOnly, hex"60006000fd");
        vm.expectRevert(abi.encodeWithSelector(KpkOivFactory.MultiSendMissing.selector, multiSendCallsOnly));
        factory.deployOiv(oivConfig);
    }

    /// @dev Pins the three hardcoded constants against REAL chain state. Every other assertion in
    ///      this file compares the factory's constants to themselves (or to `OivInfraConstants`,
    ///      which is where they come from), so a wrong address would sail through CI. This is the
    ///      only check that would catch one.
    function test_multiSendConstantsMatchOnChainCode() public view {
        assertEq(
            factory.MULTI_SEND().codehash,
            0x0e4f7fc66550a322d1e7688e181b75e217e662a4f3f4d6a29b22bc61217c4b77,
            "MULTI_SEND is not the canonical Safe v1.4.1 MultiSend on this fork"
        );
        assertEq(
            factory.MULTI_SEND_CALLS_ONLY().codehash,
            0xecd5bd14a08c5d2122379900b2f272bdf107a7e92423c10dd5fe3254386c9939,
            "MULTI_SEND_CALLS_ONLY is not the canonical Safe v1.4.1 MultiSendCallOnly on this fork"
        );
        assertEq(
            factory.MULTISEND_UNWRAPPER().codehash,
            0x1f6e088be5e6ef9d0fbe0547d3fa9a9e40d823433fd8a4449215b5663209a1eb,
            "MULTISEND_UNWRAPPER is not the canonical Zodiac MultiSendUnwrapper on this fork"
        );
    }

    function test_sharesProxy_portfolioSafeIsAvatarSafe() public {
        KpkOivFactory.OivInstance memory inst = factory.deployOiv(oivConfig);

        assertEq(KpkShares(inst.kpkSharesProxy).portfolioSafe(), inst.avatarSafe, "portfolioSafe mismatch");
    }

    function test_sharesProxy_adminHasDefaultAdminRole() public {
        KpkOivFactory.OivInstance memory inst = factory.deployOiv(oivConfig);

        KpkShares shares = KpkShares(inst.kpkSharesProxy);
        assertTrue(shares.hasRole(0x00, admin), "admin does not have DEFAULT_ADMIN_ROLE");
    }

    /// @dev The admin arg to deployOiv must be the single source of truth for both
    ///      the exec Roles Modifier owner and DEFAULT_ADMIN_ROLE on the shares proxy.
    function test_deployOiv_adminArgControlsBothExecModOwnerAndSharesAdmin() public {
        address customAdmin = makeAddr("customAdmin");
        KpkOivFactory.OivConfig memory cfg = _buildOivConfig();
        cfg.admin = customAdmin;

        KpkOivFactory.OivInstance memory inst = factory.deployOiv(cfg);

        assertEq(IRoles(inst.execRolesModifier).owner(), customAdmin, "execMod owner must equal admin arg");
        assertTrue(
            KpkShares(inst.kpkSharesProxy).hasRole(0x00, customAdmin), "shares DEFAULT_ADMIN_ROLE must equal admin arg"
        );
        assertEq(
            IRoles(inst.execRolesModifier).owner(),
            customAdmin,
            "execMod owner and shares admin must be the same address"
        );
    }

    function test_sharesProxy_operatorIsManagerSafe() public {
        KpkOivFactory.OivInstance memory inst = factory.deployOiv(oivConfig);

        KpkShares shares = KpkShares(inst.kpkSharesProxy);
        assertTrue(shares.hasRole(keccak256("OPERATOR"), inst.managerSafe), "managerSafe does not have OPERATOR role");
    }

    function test_sharesProxy_factoryHasNoAdminRole() public {
        KpkOivFactory.OivInstance memory inst = factory.deployOiv(oivConfig);

        KpkShares shares = KpkShares(inst.kpkSharesProxy);
        assertFalse(shares.hasRole(0x00, address(factory)), "factory still has DEFAULT_ADMIN_ROLE");
    }

    function test_sharesProxy_baseAssetHasInfiniteAllowance() public {
        KpkOivFactory.OivInstance memory inst = factory.deployOiv(oivConfig);

        assertEq(
            IERC20(USDC).allowance(inst.avatarSafe, inst.kpkSharesProxy),
            type(uint256).max,
            "base asset allowance is not infinite"
        );
    }

    function test_sharesProxy_cannotReinitialize() public {
        KpkOivFactory.OivInstance memory inst = factory.deployOiv(oivConfig);

        vm.expectRevert();
        KpkShares(inst.kpkSharesProxy).initialize(oivConfig.sharesParams);
    }

    function test_instanceCount_incrementsOnEachDeploy() public {
        assertEq(factory.instanceCount(), 0);

        factory.deployOiv(oivConfig);
        assertEq(factory.instanceCount(), 1);

        // Deploy a second fund with a different salt to avoid CREATE2 collisions.
        KpkOivFactory.OivConfig memory cfg2 = _buildOivConfig();
        cfg2.salt = 999;

        factory.deployOiv(cfg2);
        assertEq(factory.instanceCount(), 2);
    }

    function test_deployOiv_revertsOnZeroAdmin() public {
        oivConfig.admin = address(0);
        vm.expectRevert(KpkOivFactory.ZeroAddress.selector);
        factory.deployOiv(oivConfig);
    }

    /// @dev Deterministic-CREATE2 deploy pattern: the factory may be constructed with
    ///      `_kpkSharesDeployer == address(0)` so its CREATE2 init-code is independent of the
    ///      (chicken-and-egg) deployer address. Until `setKpkSharesDeployer` wires it,
    ///      `deployOiv` must revert cleanly. `deployStack` is unaffected — it does not touch
    ///      `kpkSharesDeployer`.
    function test_deployOiv_revertsWhenKpkSharesDeployerNotSet() public {
        // Deploy a second factory with kpkSharesDeployer == address(0). No predicted-factory
        // dance needed since we never call `deployOiv` against this factory while wired.
        KpkOivFactory unwired = new KpkOivFactory(
            factoryOwner,
            SAFE_PROXY_FACTORY,
            SAFE_SINGLETON,
            SAFE_MODULE_SETUP,
            SAFE_FALLBACK_HANDLER,
            MODULE_PROXY_FACTORY,
            ROLES_MODIFIER_MASTERCOPY,
            address(0),
            address(0)
        );

        assertEq(unwired.kpkSharesDeployer(), address(0), "expected unwired factory");

        vm.expectRevert(KpkOivFactory.KpkSharesDeployerNotSet.selector);
        unwired.deployOiv(oivConfig);
    }

    /// @dev Companion to the above: once the owner wires the deployer, `deployOiv` works
    ///      without further intervention. Exercises the full deploy-time wiring flow used
    ///      by `script/DeployKpkOivFactory.s.sol`.
    function test_deployOiv_succeedsAfterSetKpkSharesDeployer() public {
        // Pre-compute the unwired factory's address so we can lock the deployer to it before
        // either is deployed (mirrors the on-chain CREATE2 prediction we'll do in the script).
        uint256 nextNonce = vm.getNonce(address(this));
        address predictedUnwired = vm.computeCreateAddress(address(this), nextNonce + 1);

        KpkSharesDeployer freshDeployer = new KpkSharesDeployer(predictedUnwired);

        KpkOivFactory unwired = new KpkOivFactory(
            factoryOwner,
            SAFE_PROXY_FACTORY,
            SAFE_SINGLETON,
            SAFE_MODULE_SETUP,
            SAFE_FALLBACK_HANDLER,
            MODULE_PROXY_FACTORY,
            ROLES_MODIFIER_MASTERCOPY,
            address(0),
            address(0)
        );
        require(address(unwired) == predictedUnwired, "unwired factory address mismatch");

        // Pre-wire reverts.
        vm.expectRevert(KpkOivFactory.KpkSharesDeployerNotSet.selector);
        unwired.deployOiv(oivConfig);

        // Owner wires the deployer.
        vm.prank(factoryOwner);
        unwired.setKpkSharesDeployer(address(freshDeployer));
        assertEq(unwired.kpkSharesDeployer(), address(freshDeployer), "deployer not set");

        // Post-wire succeeds.
        KpkOivFactory.OivInstance memory inst = unwired.deployOiv(oivConfig);
        assertTrue(inst.avatarSafe != address(0), "avatarSafe not deployed post-wire");
    }

    function test_deployOiv_revertsOnEmptyManagerOwners() public {
        oivConfig.managerSafe.owners = new address[](0);
        vm.expectRevert(KpkOivFactory.EmptyOwners.selector);
        factory.deployOiv(oivConfig);
    }

    function test_deployOiv_revertsOnInvalidThreshold() public {
        oivConfig.managerSafe.threshold = 5; // more than 1 owner
        vm.expectRevert(KpkOivFactory.InvalidThreshold.selector);
        factory.deployOiv(oivConfig);
    }

    function test_deployOiv_revertsIfApproveModuleCallFails() public {
        // Make USDC.approve revert so that the Avatar Safe's execTransactionFromModule
        // returns false when the factory tries to grant the shares proxy its allowance.
        vm.mockCallRevert(USDC, abi.encodeWithSelector(IERC20.approve.selector), "");
        vm.expectRevert("KpkOivFactory: approve module call failed");
        factory.deployOiv(oivConfig);
    }

    /// @dev L-05: zero owner is rejected at the factory level (descriptive error) instead of
    ///      surfacing as an opaque GS203 from deep inside Safe `setup()`.
    function test_deployOiv_revertsOnZeroOwner() public {
        oivConfig.managerSafe.owners = new address[](2);
        oivConfig.managerSafe.owners[0] = managerSigner;
        oivConfig.managerSafe.owners[1] = address(0);
        oivConfig.managerSafe.threshold = 1;
        vm.expectRevert(KpkOivFactory.ZeroAddress.selector);
        factory.deployOiv(oivConfig);
    }

    /// @dev L-05: duplicate owner is rejected at the factory level (descriptive error) instead
    ///      of surfacing as an opaque GS204 from deep inside Safe `setup()`.
    function test_deployOiv_revertsOnDuplicateOwner() public {
        oivConfig.managerSafe.owners = new address[](2);
        oivConfig.managerSafe.owners[0] = managerSigner;
        oivConfig.managerSafe.owners[1] = managerSigner;
        oivConfig.managerSafe.threshold = 1;
        vm.expectRevert(KpkOivFactory.DuplicateOwner.selector);
        factory.deployOiv(oivConfig);
    }

    /// @dev M-06 / L-03: `additionalAssets` cannot include the base deposit asset, otherwise
    ///      the second `updateAsset` call would clear `isFeeModuleAsset`, silently disabling
    ///      performance fees.
    function test_deployOiv_revertsWhenAdditionalAssetEqualsBaseAsset() public {
        oivConfig.additionalAssets = new KpkOivFactory.AssetConfig[](1);
        oivConfig.additionalAssets[0] = KpkOivFactory.AssetConfig({asset: USDC, canDeposit: true, canRedeem: true});
        vm.expectRevert(KpkOivFactory.DuplicateAsset.selector);
        factory.deployOiv(oivConfig);
    }

    /// @dev M-06: duplicate `additionalAssets` entries are rejected — without this guard a
    ///      duplicate with `canRedeem=true` would cause a second `approve(MAX)` call which
    ///      reverts on USDT-like tokens, DoS'ing the entire deployment.
    function test_deployOiv_revertsOnDuplicateAdditionalAsset() public {
        address dummy = makeAddr("dummyToken");
        oivConfig.additionalAssets = new KpkOivFactory.AssetConfig[](2);
        oivConfig.additionalAssets[0] = KpkOivFactory.AssetConfig({asset: dummy, canDeposit: true, canRedeem: false});
        oivConfig.additionalAssets[1] = KpkOivFactory.AssetConfig({asset: dummy, canDeposit: false, canRedeem: true});
        vm.expectRevert(KpkOivFactory.DuplicateAsset.selector);
        factory.deployOiv(oivConfig);
    }

    /// @dev L-06: `feeReceiver` is validated at the factory level so misconfiguration fails
    ///      fast instead of surfacing as a deep KpkShares initializer revert.
    function test_deployOiv_revertsOnZeroFeeReceiver() public {
        oivConfig.sharesParams.feeReceiver = address(0);
        vm.expectRevert(KpkOivFactory.InvalidSharesParams.selector);
        factory.deployOiv(oivConfig);
    }

    /// @dev L-06: TTLs are validated at the factory level for the same reason.
    function test_deployOiv_revertsOnZeroSubscriptionTtl() public {
        oivConfig.sharesParams.subscriptionRequestTtl = 0;
        vm.expectRevert(KpkOivFactory.InvalidSharesParams.selector);
        factory.deployOiv(oivConfig);
    }

    function test_deployOiv_revertsOnZeroRedemptionTtl() public {
        oivConfig.sharesParams.redemptionRequestTtl = 0;
        vm.expectRevert(KpkOivFactory.InvalidSharesParams.selector);
        factory.deployOiv(oivConfig);
    }

    // ── Address prediction tests ──────────────────────────────────────────────

    /// @dev `predictStackAddresses` must exactly match the addresses returned by `deployStack`.
    function test_predictStackAddresses_matchesActualDeployment() public {
        KpkOivFactory.StackConfig memory cfg = _buildStackConfig();

        KpkOivFactory.StackInstance memory predicted = factory.predictStackAddresses(cfg, address(this));
        KpkOivFactory.StackInstance memory actual = factory.deployStack(cfg);

        assertEq(predicted.avatarSafe, actual.avatarSafe, "avatarSafe prediction mismatch");
        assertEq(predicted.managerSafe, actual.managerSafe, "managerSafe prediction mismatch");
        assertEq(predicted.execRolesModifier, actual.execRolesModifier, "execMod prediction mismatch");
        assertEq(predicted.subRolesModifier, actual.subRolesModifier, "subMod prediction mismatch");
        assertEq(predicted.managerRolesModifier, actual.managerRolesModifier, "managerMod prediction mismatch");
    }

    /// @dev `predictOivAddresses` must match `deployOiv` for ALL seven contracts. Since the
    ///      KpkShares implementation and ERC-1967 proxy now use CREATE2 (with salts derived from
    ///      `(caller, baseSalt, 5)` and `(caller, baseSalt, 6)`), they are deterministic and the
    ///      prediction must agree byte-for-byte with the actual deployment.
    function test_predictOivAddresses_matchesActualDeployment() public {
        KpkOivFactory.OivInstance memory predicted = factory.predictOivAddresses(oivConfig, address(this));
        KpkOivFactory.OivInstance memory actual = factory.deployOiv(oivConfig);

        assertEq(predicted.avatarSafe, actual.avatarSafe, "avatarSafe prediction mismatch");
        assertEq(predicted.managerSafe, actual.managerSafe, "managerSafe prediction mismatch");
        assertEq(predicted.execRolesModifier, actual.execRolesModifier, "execMod prediction mismatch");
        assertEq(predicted.subRolesModifier, actual.subRolesModifier, "subMod prediction mismatch");
        assertEq(predicted.managerRolesModifier, actual.managerRolesModifier, "managerMod prediction mismatch");
        assertEq(predicted.kpkSharesImpl, actual.kpkSharesImpl, "kpkSharesImpl prediction mismatch");
        assertEq(predicted.kpkSharesProxy, actual.kpkSharesProxy, "kpkSharesProxy prediction mismatch");
        assertTrue(predicted.kpkSharesImpl != address(0), "kpkSharesImpl should be predicted non-zero");
        assertTrue(predicted.kpkSharesProxy != address(0), "kpkSharesProxy should be predicted non-zero");
    }

    /// @dev Cross-flow address invariant: `predictStackAddresses` and `predictOivAddresses` MUST
    ///      produce identical operational-stack addresses for the same `(salt, caller)`. This
    ///      is the entire point of the multichain design — `deployOiv` on mainnet must yield
    ///      the same Avatar Safe address as `deployStack` on every sidechain. Both flows now
    ///      include the factory as a setup-time Avatar Safe module so the setup() initializer
    ///      is byte-identical.
    function test_predict_addressesMatchBetweenStackAndOiv() public {
        KpkOivFactory.StackConfig memory stackCfg = _buildStackConfig();
        // Use the same salt for both predictions to assert cross-flow address agreement.
        stackCfg.salt = oivConfig.salt;

        KpkOivFactory.StackInstance memory stackPred = factory.predictStackAddresses(stackCfg, address(this));
        KpkOivFactory.OivInstance memory oivPred = factory.predictOivAddresses(oivConfig, address(this));

        assertEq(stackPred.avatarSafe, oivPred.avatarSafe, "avatarSafe should match across flows");
        assertEq(stackPred.managerSafe, oivPred.managerSafe, "managerSafe should match");
        assertEq(stackPred.execRolesModifier, oivPred.execRolesModifier, "execMod should match");
        assertEq(stackPred.subRolesModifier, oivPred.subRolesModifier, "subMod should match");
        assertEq(stackPred.managerRolesModifier, oivPred.managerRolesModifier, "managerMod should match");
    }

    /// @dev Cross-flow real-deployment invariant: predictOiv before deploying via deployStack
    ///      must agree on the Avatar Safe address that deployStack actually produces. (We can't
    ///      run both deployStack and deployOiv on the same salt+caller — they'd CREATE2-collide
    ///      — so this test verifies the prediction matches the actual deployment path the user
    ///      will take on the OTHER chain.)
    function test_predictOiv_avatarSafeMatchesDeployStackActualAddress() public {
        // Predict via the deployOiv path for a given salt+caller.
        KpkOivFactory.OivInstance memory oivPred = factory.predictOivAddresses(oivConfig, address(this));

        // Now actually deploy via the deployStack path with the same salt+caller — should
        // produce the same Avatar Safe address as the deployOiv prediction.
        KpkOivFactory.StackConfig memory stackCfg = _buildStackConfig();
        stackCfg.salt = oivConfig.salt;
        KpkOivFactory.StackInstance memory stackActual = factory.deployStack(stackCfg);

        assertEq(stackActual.avatarSafe, oivPred.avatarSafe, "deployStack avatarSafe != deployOiv prediction");
        assertEq(stackActual.managerSafe, oivPred.managerSafe, "managerSafe mismatch");
        assertEq(stackActual.execRolesModifier, oivPred.execRolesModifier, "execMod mismatch");
        assertEq(stackActual.subRolesModifier, oivPred.subRolesModifier, "subMod mismatch");
        assertEq(stackActual.managerRolesModifier, oivPred.managerRolesModifier, "managerMod mismatch");
    }

    /// @dev Symmetrical to the above — predictStack before deploying via deployOiv must agree
    ///      on the Avatar Safe address that deployOiv actually produces.
    function test_predictStack_avatarSafeMatchesDeployOivActualAddress() public {
        KpkOivFactory.StackConfig memory stackCfg = _buildStackConfig();
        stackCfg.salt = oivConfig.salt;
        KpkOivFactory.StackInstance memory stackPred = factory.predictStackAddresses(stackCfg, address(this));

        KpkOivFactory.OivInstance memory oivActual = factory.deployOiv(oivConfig);

        assertEq(oivActual.avatarSafe, stackPred.avatarSafe, "deployOiv avatarSafe != deployStack prediction");
        assertEq(oivActual.managerSafe, stackPred.managerSafe, "managerSafe mismatch");
        assertEq(oivActual.execRolesModifier, stackPred.execRolesModifier, "execMod mismatch");
        assertEq(oivActual.subRolesModifier, stackPred.subRolesModifier, "subMod mismatch");
        assertEq(oivActual.managerRolesModifier, stackPred.managerRolesModifier, "managerMod mismatch");
    }

    /// @dev Cross-flow CREATE2-collision invariant: deployStack followed by deployOiv with the
    ///      same `(caller, salt)` MUST revert. This is the operational consequence of the
    ///      address invariant — both flows compete for the same Avatar Safe / Manager Safe /
    ///      Roles Modifier addresses, so the second one always reverts. Same-address-everywhere
    ///      also means same-CREATE2-collision when both run on the same chain.
    function test_deployStackThenDeployOiv_revertsOnSameCallerAndSalt() public {
        KpkOivFactory.StackConfig memory stackCfg = _buildStackConfig();
        stackCfg.salt = oivConfig.salt;

        factory.deployStack(stackCfg);

        // Same salt, same caller — collides on the already-deployed Avatar Safe (or another
        // CREATE2 contract; the Roles Modifiers actually deploy first and would collide first).
        vm.expectRevert();
        factory.deployOiv(oivConfig);
    }

    /// @dev Symmetrical: deployOiv then deployStack with the same `(caller, salt)` MUST revert.
    function test_deployOivThenDeployStack_revertsOnSameCallerAndSalt() public {
        factory.deployOiv(oivConfig);

        KpkOivFactory.StackConfig memory stackCfg = _buildStackConfig();
        stackCfg.salt = oivConfig.salt;

        vm.expectRevert();
        factory.deployStack(stackCfg);
    }

    /// @dev Sanity check: predicted addresses are uninhabited contracts before deployment, and
    ///      contain code after. Catches any future regression where the predict math drifts
    ///      from the deployment math without surfacing in the matches-actual-deployment tests.
    function test_predictStack_addressesAreEmptyBeforeDeployAndPopulatedAfter() public {
        KpkOivFactory.StackConfig memory cfg = _buildStackConfig();
        KpkOivFactory.StackInstance memory predicted = factory.predictStackAddresses(cfg, address(this));

        assertEq(predicted.avatarSafe.code.length, 0, "avatarSafe should be empty pre-deploy");
        assertEq(predicted.managerSafe.code.length, 0, "managerSafe should be empty pre-deploy");
        assertEq(predicted.execRolesModifier.code.length, 0, "execMod should be empty pre-deploy");
        assertEq(predicted.subRolesModifier.code.length, 0, "subMod should be empty pre-deploy");
        assertEq(predicted.managerRolesModifier.code.length, 0, "managerMod should be empty pre-deploy");

        factory.deployStack(cfg);

        assertGt(predicted.avatarSafe.code.length, 0, "avatarSafe should have code post-deploy");
        assertGt(predicted.managerSafe.code.length, 0, "managerSafe should have code post-deploy");
        assertGt(predicted.execRolesModifier.code.length, 0, "execMod should have code post-deploy");
        assertGt(predicted.subRolesModifier.code.length, 0, "subMod should have code post-deploy");
        assertGt(predicted.managerRolesModifier.code.length, 0, "managerMod should have code post-deploy");
    }

    /// @dev Different callers with the same salt must produce different predicted addresses
    ///      (M-01 salt-squat protection visible from the read API).
    function test_predict_differentCallerYieldsDifferentAddresses() public {
        KpkOivFactory.StackInstance memory predA = factory.predictStackAddresses(_buildStackConfig(), address(this));
        KpkOivFactory.StackInstance memory predB =
            factory.predictStackAddresses(_buildStackConfig(), makeAddr("otherCaller"));

        assertTrue(predA.avatarSafe != predB.avatarSafe, "avatarSafe should differ");
        assertTrue(predA.managerSafe != predB.managerSafe, "managerSafe should differ");
        assertTrue(predA.execRolesModifier != predB.execRolesModifier, "execMod should differ");
    }

    /// @dev L-01: KpkSharesDeployer.deploy() rejects callers other than the factory.
    function test_kpkSharesDeployer_deploy_revertsForNonFactoryCaller() public {
        KpkSharesDeployer deployer = new KpkSharesDeployer(address(this));
        vm.prank(makeAddr("stranger"));
        vm.expectRevert(KpkSharesDeployer.UnauthorizedCaller.selector);
        deployer.deploy(bytes32(uint256(1)));
    }

    /// @dev L-01: KpkSharesDeployer constructor rejects address(0) factory.
    function test_kpkSharesDeployer_constructor_revertsOnZeroFactory() public {
        vm.expectRevert(KpkSharesDeployer.ZeroFactory.selector);
        new KpkSharesDeployer(address(0));
    }

    // ── deployStack tests ───────────────────────────────────────────────────────

    function test_deployStack_deploysFiveContracts() public {
        KpkOivFactory.StackInstance memory inst = factory.deployStack(_buildStackConfig());

        assertTrue(inst.avatarSafe != address(0), "avatarSafe not deployed");
        assertTrue(inst.managerSafe != address(0), "managerSafe not deployed");
        assertTrue(inst.execRolesModifier != address(0), "execRolesModifier not deployed");
        assertTrue(inst.subRolesModifier != address(0), "subRolesModifier not deployed");
        assertTrue(inst.managerRolesModifier != address(0), "managerRolesModifier not deployed");
    }

    function test_deployStack_avatarSafe_ownerIsEmptyContract() public {
        KpkOivFactory.StackInstance memory inst = factory.deployStack(_buildStackConfig());

        address[] memory owners = ISafe(inst.avatarSafe).getOwners();
        assertEq(owners.length, 1, "avatarSafe should have exactly one owner");
        assertEq(owners[0], factory.EMPTY_CONTRACT(), "avatarSafe owner is not EMPTY_CONTRACT");
    }

    /// @dev The factory is enabled as an Avatar Safe module at setup() time (so the setup data
    ///      matches deployOiv and the Avatar Safe address is identical across flows). It MUST
    ///      be disabled before deployStack returns.
    function test_deployStack_factoryIsNotModuleOfAvatarSafeAfterDeploy() public {
        KpkOivFactory.StackInstance memory inst = factory.deployStack(_buildStackConfig());
        assertFalse(
            ISafe(inst.avatarSafe).isModuleEnabled(address(factory)),
            "factory should not remain a module of avatarSafe after deployStack"
        );
    }

    function test_deployStack_wiringMatchesDeployOiv() public {
        KpkOivFactory.StackConfig memory stackCfg = _buildStackConfig();

        KpkOivFactory.StackInstance memory inst = factory.deployStack(stackCfg);

        assertTrue(ISafe(inst.avatarSafe).isModuleEnabled(inst.execRolesModifier), "execMod not module of avatarSafe");
        assertTrue(
            ISafe(inst.managerSafe).isModuleEnabled(inst.managerRolesModifier), "managerMod not module of managerSafe"
        );
        assertEq(IRoles(inst.execRolesModifier).avatar(), inst.avatarSafe, "execMod avatar mismatch");
        assertEq(IRoles(inst.execRolesModifier).target(), inst.avatarSafe, "execMod target mismatch");
        assertEq(IRoles(inst.execRolesModifier).owner(), securityCouncil, "execMod owner mismatch");
        assertEq(IRoles(inst.subRolesModifier).avatar(), inst.avatarSafe, "subMod avatar mismatch");
        assertEq(IRoles(inst.subRolesModifier).target(), inst.execRolesModifier, "subMod target mismatch");
        assertEq(IRoles(inst.subRolesModifier).owner(), inst.managerSafe, "subMod owner mismatch");
        assertEq(IRoles(inst.managerRolesModifier).avatar(), inst.managerSafe, "managerMod avatar mismatch");
        assertEq(IRoles(inst.managerRolesModifier).target(), inst.managerSafe, "managerMod target mismatch");
        assertEq(IRoles(inst.managerRolesModifier).owner(), inst.managerSafe, "managerMod owner mismatch");
    }

    function test_deployStack_sameSaltProducesSameAddresses() public {
        KpkOivFactory.StackConfig memory cfg = _buildStackConfig();

        KpkOivFactory.StackInstance memory inst1 = factory.deployStack(cfg);

        // The same caller using the same salt MUST collide (CREATE2 redeploy revert).
        vm.expectRevert();
        factory.deployStack(cfg);

        // A different salt produces different addresses.
        cfg.salt = 999;
        KpkOivFactory.StackInstance memory inst2 = factory.deployStack(cfg);

        assertTrue(inst1.avatarSafe != inst2.avatarSafe, "same avatarSafe address with different salt");
        assertTrue(inst1.execRolesModifier != inst2.execRolesModifier, "same execMod address with different salt");
    }

    /// @dev M-01: a different caller using the same salt produces DIFFERENT addresses,
    ///      preventing salt-squat front-running of deterministic deployment addresses.
    function test_deployStack_differentCallerSameSaltProducesDifferentAddresses() public {
        KpkOivFactory.StackConfig memory cfg = _buildStackConfig();

        KpkOivFactory.StackInstance memory inst1 = factory.deployStack(cfg);

        address otherCaller = makeAddr("otherCaller");
        vm.prank(otherCaller);
        KpkOivFactory.StackInstance memory inst2 = factory.deployStack(cfg);

        assertTrue(inst1.avatarSafe != inst2.avatarSafe, "salt-squat: same avatarSafe across callers");
        assertTrue(inst1.managerSafe != inst2.managerSafe, "salt-squat: same managerSafe across callers");
        assertTrue(inst1.execRolesModifier != inst2.execRolesModifier, "salt-squat: same execMod across callers");
        assertTrue(inst1.subRolesModifier != inst2.subRolesModifier, "salt-squat: same subMod across callers");
        assertTrue(
            inst1.managerRolesModifier != inst2.managerRolesModifier, "salt-squat: same managerMod across callers"
        );
    }

    function test_stackCount_incrementsOnEachDeploy() public {
        assertEq(factory.stackCount(), 0);

        factory.deployStack(_buildStackConfig());
        assertEq(factory.stackCount(), 1);

        KpkOivFactory.StackConfig memory cfg2 = _buildStackConfig();
        cfg2.salt = 999;
        factory.deployStack(cfg2);
        assertEq(factory.stackCount(), 2);
    }

    // ── Permissionless deployment tests ────────────────────────────────────────

    function test_deployOiv_isPermissionless() public {
        address stranger = makeAddr("stranger");
        vm.prank(stranger);
        KpkOivFactory.OivInstance memory inst = factory.deployOiv(oivConfig);

        assertTrue(inst.kpkSharesProxy != address(0), "stranger could not deploy OIV");
    }

    function test_deployStack_isPermissionless() public {
        address stranger = makeAddr("stranger");
        vm.prank(stranger);
        KpkOivFactory.StackInstance memory inst = factory.deployStack(_buildStackConfig());

        assertTrue(inst.avatarSafe != address(0), "stranger could not deploy stack");
    }

    // ── Integration tests ───────────────────────────────────────────────────────

    /// @dev End-to-end: factory deploys a USDC fund, an investor submits the first
    ///      subscription request, and the request sits pending for the operator.
    ///      Verifies the full path from factory deployment to investor interaction.
    function test_integration_firstUsdcSubscriptionRequest() public {
        KpkOivFactory.OivInstance memory inst = factory.deployOiv(oivConfig);

        KpkShares shares = KpkShares(inst.kpkSharesProxy);
        address investor = makeAddr("investor");
        uint256 subscriptionAmount = 1_000e6; // 1,000 USDC

        deal(USDC, investor, subscriptionAmount);

        vm.prank(investor);
        IERC20(USDC).approve(address(shares), subscriptionAmount);

        // Expected shares at the opening price of 1 USDC = 1e8 NAV
        uint256 sharesPrice = 1e8;
        uint256 minSharesOut = shares.assetsToShares(subscriptionAmount, sharesPrice, USDC);

        uint256 expectedRequestId = shares.requestId() + 1;
        uint256 investorUsdcBefore = IERC20(USDC).balanceOf(investor);

        vm.prank(investor);
        uint256 requestId = shares.requestSubscription(subscriptionAmount, minSharesOut, USDC, investor);

        // ── request ID ──────────────────────────────────────────────────────────
        assertEq(requestId, expectedRequestId, "unexpected request ID");

        // ── USDC moved from investor to the shares proxy ─────────────────────────
        assertEq(IERC20(USDC).balanceOf(investor), investorUsdcBefore - subscriptionAmount, "investor USDC not pulled");
        assertGe(IERC20(USDC).balanceOf(address(shares)), subscriptionAmount, "shares proxy did not receive USDC");

        // ── request state ────────────────────────────────────────────────────────
        IkpkShares.UserRequest memory req = shares.getRequest(requestId);
        assertEq(uint8(req.requestStatus), uint8(IkpkShares.RequestStatus.PENDING), "request not pending");
        assertEq(uint8(req.requestType), uint8(IkpkShares.RequestType.SUBSCRIPTION), "wrong request type");
        assertEq(req.investor, investor, "request investor mismatch");
        assertEq(req.receiver, investor, "request receiver mismatch");
        assertEq(req.asset, USDC, "request asset mismatch");
        assertEq(req.assetAmount, subscriptionAmount, "request assetAmount mismatch");
        assertEq(req.sharesAmount, minSharesOut, "request minSharesOut mismatch");
    }

    // ── Helpers ─────────────────────────────────────────────────────────────────

    function _buildStackConfig() internal view returns (KpkOivFactory.StackConfig memory cfg) {
        address[] memory managerOwners = new address[](1);
        managerOwners[0] = managerSigner;

        cfg.managerSafe = KpkOivFactory.SafeConfig({owners: managerOwners, threshold: 1});
        cfg.execRolesMod = KpkOivFactory.RolesModifierConfig({finalOwner: securityCouncil});
        cfg.subRolesMod = KpkOivFactory.RolesModifierConfig({finalOwner: address(0)});
        cfg.managerRolesMod = KpkOivFactory.RolesModifierConfig({finalOwner: address(0)});
        cfg.salt = 42;
    }

    function _buildOivConfig() internal view returns (KpkOivFactory.OivConfig memory cfg) {
        address[] memory managerOwners = new address[](1);
        managerOwners[0] = managerSigner;

        cfg.managerSafe = KpkOivFactory.SafeConfig({owners: managerOwners, threshold: 1});
        cfg.salt = 42;
        cfg.admin = admin;
        cfg.additionalAssets = new KpkOivFactory.AssetConfig[](0);
        cfg.sharesParams = KpkShares.ConstructorParams({
            asset: USDC,
            admin: address(0), // ignored — overridden by cfg.admin
            name: "Test Fund Shares",
            symbol: "kTEST",
            safe: address(0), // ignored — overridden by factory
            subscriptionRequestTtl: 1 days,
            redemptionRequestTtl: 1 days,
            feeReceiver: feeReceiver,
            managementFeeRate: 100,
            redemptionFeeRate: 50,
            performanceFeeModule: address(0),
            performanceFeeRate: 0
        });
    }

    // ── Chain-independent shares address ───────────────────────────────────────

    /// @dev Mainnet DAI. Used only as "an ERC-20 that is not the base asset", standing in for the
    ///      different base asset a fund would use on another chain.
    address constant OTHER_ASSET = 0x6B175474E89094C44Da98b954EedeAC495271d0F;

    /// @notice The whole point of deploying the proxy with empty constructor data: the base asset is
    ///         necessarily chain-specific, so it must not reach the CREATE2 init code. Two funds that
    ///         differ ONLY in their base asset must predict the same shares proxy address.
    function test_sharesProxyAddress_isIndependentOfTheBaseAsset() public view {
        KpkOivFactory.OivConfig memory withUsdc = oivConfig;
        KpkOivFactory.OivConfig memory withDai = oivConfig;
        withDai.sharesParams.asset = OTHER_ASSET;

        KpkOivFactory.OivInstance memory a = factory.predictOivAddresses(withUsdc, address(this));
        KpkOivFactory.OivInstance memory b = factory.predictOivAddresses(withDai, address(this));

        assertEq(b.kpkSharesProxy, a.kpkSharesProxy, "a different base asset must not move the proxy");
        assertEq(b.kpkSharesImpl, a.kpkSharesImpl, "nor the implementation");
    }

    /// @dev The prediction is worth nothing unless a real deploy with the OTHER asset lands there.
    function test_sharesProxy_deployedWithADifferentAssetMatchesTheUsdcPrediction() public {
        KpkOivFactory.OivInstance memory predictedWithUsdc = factory.predictOivAddresses(oivConfig, address(this));

        oivConfig.sharesParams.asset = OTHER_ASSET;
        KpkOivFactory.OivInstance memory deployed = factory.deployOiv(oivConfig);

        assertEq(
            deployed.kpkSharesProxy,
            predictedWithUsdc.kpkSharesProxy,
            "a fund deployed on a chain with a different base asset must land at the same address"
        );
        assertEq(address(KpkShares(deployed.kpkSharesProxy).getApprovedAsset(OTHER_ASSET).asset), OTHER_ASSET);
    }

    /// @dev Initialization moved out of the constructor, so pin that it still happened — an
    ///      uninitialized proxy at the right address would be a far worse outcome than a wrong address.
    function test_sharesProxy_isInitializedDespiteEmptyConstructorData() public {
        KpkOivFactory.OivInstance memory inst = factory.deployOiv(oivConfig);
        KpkShares shares = KpkShares(inst.kpkSharesProxy);

        assertEq(shares.name(), "Test Fund Shares", "ERC-20 metadata proves initialize() ran");
        assertEq(shares.portfolioSafe(), inst.avatarSafe, "portfolio Safe wired");
        assertTrue(shares.hasRole(0x00, admin), "admin holds DEFAULT_ADMIN_ROLE");
        assertFalse(shares.hasRole(0x00, address(factory)), "factory renounced");

        vm.expectRevert();
        shares.initialize(oivConfig.sharesParams);
    }

    // ── Timelock governance (deployOiv / deployStack) ───────────────────────────

    address govSafe = makeAddr("govSafe");
    address superadminSafe = makeAddr("superadminSafe");
    address managerVeto = makeAddr("managerVeto");
    address lpVeto = makeAddr("lpVeto");

    /// @dev Two proposers, two cancellers — the shape the rollout actually uses.
    function _timelockParams(uint256 minDelay) internal view returns (TimelockParams memory p) {
        // Sorted: the deployer requires strictly ascending arrays.
        p = TimelockParams({
            minDelay: minDelay,
            proposers: _sortedPair(govSafe, superadminSafe),
            cancellers: _sortedPair(managerVeto, lpVeto)
        });
    }

    function _sortedPair(address a, address b) internal pure returns (address[] memory out) {
        out = new address[](2);
        (out[0], out[1]) = a < b ? (a, b) : (b, a);
    }

    function test_deployOiv_execTimelockOwnsExecModifier() public {
        oivConfig.execTimelock = _timelockParams(2 days);
        KpkOivFactory.OivInstance memory inst = factory.deployOiv(oivConfig);

        assertTrue(inst.execTimelock != address(0), "execTimelock not recorded");
        assertEq(
            IRoles(inst.execRolesModifier).owner(), inst.execTimelock, "exec modifier must be owned by the timelock"
        );
        assertTrue(IRoles(inst.execRolesModifier).owner() != admin, "admin must no longer own the exec modifier");
    }

    function test_deployOiv_sharesTimelockReplacesAdminEntirely() public {
        oivConfig.sharesTimelock = _timelockParams(7 days);
        KpkOivFactory.OivInstance memory inst = factory.deployOiv(oivConfig);

        KpkShares shares = KpkShares(inst.kpkSharesProxy);
        assertTrue(inst.sharesTimelock != address(0), "sharesTimelock not recorded");
        assertTrue(shares.hasRole(0x00, inst.sharesTimelock), "timelock must hold DEFAULT_ADMIN_ROLE");
        assertFalse(
            shares.hasRole(0x00, admin), "admin must NOT retain DEFAULT_ADMIN_ROLE - that would be a delay-free bypass"
        );
    }

    /// @dev The default config leaves both delays at zero, which must behave exactly as before.
    function test_deployOiv_zeroDelayMeansNoTimelock() public {
        KpkOivFactory.OivInstance memory inst = factory.deployOiv(oivConfig);

        assertEq(inst.execTimelock, address(0), "no exec timelock expected");
        assertEq(inst.sharesTimelock, address(0), "no shares timelock expected");
        assertEq(IRoles(inst.execRolesModifier).owner(), admin, "admin must still own the exec modifier");
        assertTrue(KpkShares(inst.kpkSharesProxy).hasRole(0x00, admin), "admin must still hold DEFAULT_ADMIN_ROLE");
    }

    function test_deployOiv_timelockRolesAreWiredThrough() public {
        oivConfig.execTimelock = _timelockParams(2 days);
        KpkOivFactory.OivInstance memory inst = factory.deployOiv(oivConfig);
        TimelockController tl = TimelockController(payable(inst.execTimelock));

        assertTrue(tl.hasRole(tl.PROPOSER_ROLE(), govSafe), "governance proposes");
        assertTrue(tl.hasRole(tl.PROPOSER_ROLE(), superadminSafe), "superadmin proposes");
        assertTrue(tl.hasRole(tl.CANCELLER_ROLE(), lpVeto), "lp veto cancels");
        assertFalse(tl.hasRole(tl.PROPOSER_ROLE(), lpVeto), "veto must not gain proposal rights");
        assertTrue(tl.hasRole(tl.EXECUTOR_ROLE(), address(0)), "execution is open");
        assertFalse(tl.hasRole(0x00, address(factory)), "factory must hold no role on the timelock");
        assertEq(tl.getMinDelay(), 2 days, "minDelay must be the supplied parameter");
    }

    /// @dev End to end: the timelock really does control the modifier it owns.
    function test_deployOiv_execTimelockCanGovernTheModifier() public {
        oivConfig.execTimelock = _timelockParams(2 days);
        KpkOivFactory.OivInstance memory inst = factory.deployOiv(oivConfig);
        TimelockController tl = TimelockController(payable(inst.execTimelock));

        // A no-op re-set of the avatar the modifier already has.
        bytes memory payload = abi.encodeCall(IRoles.setAvatar, (inst.avatarSafe));

        vm.prank(govSafe);
        tl.schedule(inst.execRolesModifier, 0, payload, bytes32(0), bytes32(0), 2 days);

        vm.warp(vm.getBlockTimestamp() + 2 days + 1);
        tl.execute(inst.execRolesModifier, 0, payload, bytes32(0), bytes32(0));

        assertEq(IRoles(inst.execRolesModifier).avatar(), inst.avatarSafe, "timelocked call must have landed");
    }

    /// @dev The veto stops a queued change to the fund's permission layer.
    function test_deployOiv_vetoBlocksAQueuedModifierChange() public {
        oivConfig.execTimelock = _timelockParams(2 days);
        KpkOivFactory.OivInstance memory inst = factory.deployOiv(oivConfig);
        TimelockController tl = TimelockController(payable(inst.execTimelock));

        address hostileAvatar = makeAddr("hostileAvatar");
        bytes memory payload = abi.encodeCall(IRoles.setAvatar, (hostileAvatar));
        bytes32 id = tl.hashOperation(inst.execRolesModifier, 0, payload, bytes32(0), bytes32(0));

        vm.prank(govSafe);
        tl.schedule(inst.execRolesModifier, 0, payload, bytes32(0), bytes32(0), 2 days);

        vm.prank(lpVeto);
        tl.cancel(id);

        vm.warp(vm.getBlockTimestamp() + 2 days + 1);
        vm.expectRevert();
        tl.execute(inst.execRolesModifier, 0, payload, bytes32(0), bytes32(0));
        assertEq(IRoles(inst.execRolesModifier).avatar(), inst.avatarSafe, "vetoed change must not have landed");
    }

    function test_predictOivAddresses_includesBothTimelocks() public {
        oivConfig.execTimelock = _timelockParams(2 days);
        oivConfig.sharesTimelock = _timelockParams(7 days);

        KpkOivFactory.OivInstance memory predicted = factory.predictOivAddresses(oivConfig, address(this));
        KpkOivFactory.OivInstance memory inst = factory.deployOiv(oivConfig);

        assertEq(predicted.execTimelock, inst.execTimelock, "exec timelock prediction");
        assertEq(predicted.sharesTimelock, inst.sharesTimelock, "shares timelock prediction");
    }

    function test_deployStack_deploysExecTimelockToo() public {
        KpkOivFactory.StackConfig memory stackConfig = factory.oivToStackConfig(oivConfig);
        stackConfig.execTimelock = _timelockParams(2 days);

        KpkOivFactory.StackInstance memory inst = factory.deployStack(stackConfig);
        assertEq(
            IRoles(inst.execRolesModifier).owner(), inst.execTimelock, "sidechain exec modifier must be timelocked"
        );
    }

    function test_oivToStackConfig_carriesExecTimelockThrough() public view {
        KpkOivFactory.OivConfig memory cfg = oivConfig;
        cfg.execTimelock = _timelockParams(2 days);

        KpkOivFactory.StackConfig memory mapped = factory.oivToStackConfig(cfg);
        assertEq(mapped.execTimelock.minDelay, 2 days, "delay must map through to the sidechain payload");
        assertEq(mapped.execTimelock.proposers.length, 2, "proposers must map through");
        assertEq(mapped.execTimelock.cancellers.length, 2, "cancellers must map through");
    }

    // ── Deliberately-permitted weak configurations ─────────────────────────────

    /// @dev A single proposer is accepted. One lost key then freezes the modifier permanently, and
    ///      that is the deployer's call to make, not the factory's.
    function test_deployOiv_acceptsASingleProposer() public {
        TimelockParams memory p = _timelockParams(2 days);
        address[] memory one = new address[](1);
        one[0] = govSafe;
        p.proposers = one;
        oivConfig.execTimelock = p;

        KpkOivFactory.OivInstance memory inst = factory.deployOiv(oivConfig);
        TimelockController tl = TimelockController(payable(inst.execTimelock));
        assertTrue(tl.hasRole(tl.PROPOSER_ROLE(), govSafe), "single proposer must be wired");
    }

    /// @dev No dedicated canceller is accepted: a delay with no veto beyond the proposers.
    function test_deployOiv_acceptsNoCancellers() public {
        TimelockParams memory p = _timelockParams(2 days);
        p.cancellers = new address[](0);
        oivConfig.execTimelock = p;

        KpkOivFactory.OivInstance memory inst = factory.deployOiv(oivConfig);
        TimelockController tl = TimelockController(payable(inst.execTimelock));
        assertFalse(tl.hasRole(tl.CANCELLER_ROLE(), lpVeto), "no dedicated canceller expected");
        assertTrue(tl.hasRole(tl.CANCELLER_ROLE(), govSafe), "proposers still receive CANCELLER from OZ");
    }

    /// @dev The shares-timelock guard must fire BEFORE the stack is built, not deep inside
    ///      `_deploySharesProxy` after ~7M gas of deployment has already happened.
    function test_deployOiv_sharesTimelockGuardFailsFast() public {
        KpkOivFactory bare = new KpkOivFactory(
            factoryOwner,
            SAFE_PROXY_FACTORY,
            SAFE_SINGLETON,
            SAFE_MODULE_SETUP,
            SAFE_FALLBACK_HANDLER,
            MODULE_PROXY_FACTORY,
            ROLES_MODIFIER_MASTERCOPY,
            address(new KpkSharesDeployer(address(this))),
            address(0)
        );

        oivConfig.sharesTimelock = _timelockParams(7 days);
        uint256 gasBefore = gasleft();
        vm.expectRevert(KpkOivFactory.TimelockDeployerNotSet.selector);
        bare.deployOiv(oivConfig);
        // A revert from inside `_deploySharesProxy` would have burned millions by this point.
        assertLt(gasBefore - gasleft(), 500_000, "guard must fire before any deployment work");
    }

    function test_setTimelockDeployer_emitsEvent() public {
        address newDeployer = makeAddr("newTimelockDeployer");
        vm.expectEmit(true, true, true, true, address(factory));
        emit KpkOivFactory.TimelockDeployerUpdated(newDeployer);
        vm.prank(factoryOwner);
        factory.setTimelockDeployer(newDeployer);
        assertEq(factory.timelockDeployer(), newDeployer, "setter must take effect");
    }

    function test_deployOiv_revertsWhenTimelockConfiguredButDeployerUnset() public {
        vm.prank(factoryOwner);
        KpkOivFactory bare = new KpkOivFactory(
            factoryOwner,
            SAFE_PROXY_FACTORY,
            SAFE_SINGLETON,
            SAFE_MODULE_SETUP,
            SAFE_FALLBACK_HANDLER,
            MODULE_PROXY_FACTORY,
            ROLES_MODIFIER_MASTERCOPY,
            address(new KpkSharesDeployer(address(this))),
            address(0)
        );

        oivConfig.execTimelock = _timelockParams(2 days);
        vm.expectRevert(KpkOivFactory.TimelockDeployerNotSet.selector);
        bare.deployOiv(oivConfig);
    }
}

/// @notice Exposes internal KpkOivFactory functions for unit testing.
contract KpkOivFactoryHarness is KpkOivFactory {
    constructor(
        address owner,
        address safeProxyFactory,
        address safeSingleton,
        address safeModuleSetup,
        address safeFallbackHandler,
        address moduleProxyFactory,
        address rolesModifierMastercopy,
        address kpkSharesDeployer,
        address timelockDeployer_
    )
        KpkOivFactory(
            owner,
            safeProxyFactory,
            safeSingleton,
            safeModuleSetup,
            safeFallbackHandler,
            moduleProxyFactory,
            rolesModifierMastercopy,
            kpkSharesDeployer,
            timelockDeployer_
        )
    {}

    /// @dev Exposes the factory's `internal` expected-codehash constants so a sync test can pin the
    ///      duplicate copies in `script/base/OivChainDeploy.sol` to the REAL values the factory
    ///      compiles in, rather than to another transcription of the same literals.
    function exposed_expectedMultiSendCodehashes() external pure returns (bytes32, bytes32, bytes32) {
        return
            (
                EXPECTED_MULTI_SEND_CODEHASH,
                EXPECTED_MULTI_SEND_CALLS_ONLY_CODEHASH,
                EXPECTED_MULTISEND_UNWRAPPER_CODEHASH
            );
    }

    function exposed_execApprove(address avatarSafe, address asset, address spender) external {
        _execApprove(avatarSafe, asset, spender);
    }

    function exposed_disableFactoryModule(address avatarSafe) external {
        bool moduleDisabled = ISafe(avatarSafe)
            .execTransactionFromModule(
                avatarSafe, 0, abi.encodeCall(ISafe.disableModule, (address(0x1), address(this))), 0
            );
        require(moduleDisabled, "KpkOivFactory: failed to disable module");
    }
}

/// @notice Pure unit tests for the execTransactionFromModule return-value checks.
///         No fork required — uses vm.mockCall to simulate Safe responses.
contract KpkOivFactoryUnitTest is OivTestConstants {
    // Safe/Zodiac infra inherited from OivTestConstants; available for the harness constructor, not
    // called in these (non-fork) unit tests.

    KpkOivFactoryHarness harness;

    function setUp() public {
        // KpkSharesDeployer is factory-locked. Pre-compute the harness address so the deployer
        // can be constructed with it: this contract's next nonce produces the deployer,
        // and the one after that produces the harness.
        // Nonce map: n = timelock deployer, n+1 = shares deployer, n+2 = harness.
        uint256 nextNonce = vm.getNonce(address(this));
        address predictedHarness = vm.computeCreateAddress(address(this), nextNonce + 2);
        KpkTimelockDeployer harnessTimelockDeployer = new KpkTimelockDeployer();

        KpkSharesDeployer deployer = new KpkSharesDeployer(predictedHarness);
        harness = new KpkOivFactoryHarness(
            address(this),
            SAFE_PROXY_FACTORY,
            SAFE_SINGLETON,
            SAFE_MODULE_SETUP,
            SAFE_FALLBACK_HANDLER,
            MODULE_PROXY_FACTORY,
            ROLES_MODIFIER_MASTERCOPY,
            address(deployer),
            address(harnessTimelockDeployer)
        );
        require(address(harness) == predictedHarness, "harness address mismatch");
    }

    function test_execApprove_revertsIfModuleCallReturnsFalse() public {
        address mockSafe = makeAddr("mockSafe");
        address mockToken = makeAddr("mockToken");
        address spender = makeAddr("spender");

        vm.mockCall(
            mockSafe,
            abi.encodeCall(
                ISafe.execTransactionFromModule,
                (mockToken, 0, abi.encodeCall(IERC20.approve, (spender, type(uint256).max)), 0)
            ),
            abi.encode(false)
        );

        vm.expectRevert("KpkOivFactory: approve module call failed");
        harness.exposed_execApprove(mockSafe, mockToken, spender);
    }

    function test_disableModule_revertsIfModuleCallReturnsFalse() public {
        address mockSafe = makeAddr("mockSafe");

        vm.mockCall(
            mockSafe,
            abi.encodeCall(
                ISafe.execTransactionFromModule,
                (mockSafe, 0, abi.encodeCall(ISafe.disableModule, (address(0x1), address(harness))), 0)
            ),
            abi.encode(false)
        );

        vm.expectRevert("KpkOivFactory: failed to disable module");
        harness.exposed_disableFactoryModule(mockSafe);
    }
}
