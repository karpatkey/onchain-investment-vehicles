// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

import {Test} from "forge-std/Test.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {KpkOivFactory} from "src/KpkOivFactory.sol";

/// @notice Unit tests for the curated external-fund registry (`registerFund` / `unregisterFund`).
/// @dev    No fork needed: these are pure storage ops. The factory is constructed with placeholder
///         infrastructure addresses — the constructor only requires them to be non-zero and never
///         calls them, and the registry functions touch no external contracts.
contract KpkOivFactoryRegistryTest is Test {
    KpkOivFactory factory;

    address owner = makeAddr("owner");
    address stranger = makeAddr("stranger");

    // Re-declared to drive `vm.expectEmit` (must match KpkOivFactory's definitions exactly).
    event FundRegistered(
        uint256 indexed registeredFundId, KpkOivFactory.OivInstance instance, address indexed registrar
    );
    event FundUnregistered(uint256 indexed registeredFundId, address indexed kpkSharesProxy);

    function setUp() public {
        factory = new KpkOivFactory(
            owner,
            address(0xA1), // safeProxyFactory
            address(0xA2), // safeSingleton
            address(0xA3), // safeModuleSetup
            address(0xA4), // safeFallbackHandler
            address(0xA5), // moduleProxyFactory
            address(0xA6), // rolesModifierMastercopy
            address(0xA7) //  kpkSharesDeployer
        );
    }

    /// @dev Builds a fully-populated (all non-zero, all distinct) OivInstance keyed off `seed`.
    function _instance(uint160 seed) internal pure returns (KpkOivFactory.OivInstance memory) {
        return KpkOivFactory.OivInstance({
            avatarSafe: address(0x100000 + seed),
            managerSafe: address(0x200000 + seed),
            execRolesModifier: address(0x300000 + seed),
            subRolesModifier: address(0x400000 + seed),
            managerRolesModifier: address(0x500000 + seed),
            kpkSharesImpl: address(0x600000 + seed),
            kpkSharesProxy: address(0x700000 + seed)
        });
    }

    function _assertEq(KpkOivFactory.OivInstance memory a, KpkOivFactory.OivInstance memory b) internal pure {
        assertEq(a.avatarSafe, b.avatarSafe, "avatarSafe");
        assertEq(a.managerSafe, b.managerSafe, "managerSafe");
        assertEq(a.execRolesModifier, b.execRolesModifier, "execRolesModifier");
        assertEq(a.subRolesModifier, b.subRolesModifier, "subRolesModifier");
        assertEq(a.managerRolesModifier, b.managerRolesModifier, "managerRolesModifier");
        assertEq(a.kpkSharesImpl, b.kpkSharesImpl, "kpkSharesImpl");
        assertEq(a.kpkSharesProxy, b.kpkSharesProxy, "kpkSharesProxy");
    }

    /// @dev Reads `registeredFunds[id]` back through the auto-generated public getter.
    function _stored(uint256 id) internal view returns (KpkOivFactory.OivInstance memory) {
        (
            address avatarSafe,
            address managerSafe,
            address execRolesModifier,
            address subRolesModifier,
            address managerRolesModifier,
            address kpkSharesImpl,
            address kpkSharesProxy
        ) = factory.registeredFunds(id);
        return KpkOivFactory.OivInstance(
            avatarSafe,
            managerSafe,
            execRolesModifier,
            subRolesModifier,
            managerRolesModifier,
            kpkSharesImpl,
            kpkSharesProxy
        );
    }

    // ── registerFund ─────────────────────────────────────────────────────────────

    function test_registerFund_storesAndEmits() public {
        KpkOivFactory.OivInstance memory inst = _instance(1);

        vm.expectEmit(true, true, true, true, address(factory));
        emit FundRegistered(0, inst, owner);

        vm.prank(owner);
        uint256 id = factory.registerFund(inst);

        assertEq(id, 0, "first id");
        assertEq(factory.registeredFundCount(), 1, "count");
        assertTrue(factory.isFundRegistered(inst.kpkSharesProxy), "membership");
        _assertEq(_stored(0), inst);
    }

    function test_registerFund_assignsSequentialIds() public {
        vm.startPrank(owner);
        uint256 id0 = factory.registerFund(_instance(1));
        uint256 id1 = factory.registerFund(_instance(2));
        vm.stopPrank();

        assertEq(id0, 0);
        assertEq(id1, 1);
        assertEq(factory.registeredFundCount(), 2);
    }

    function test_registerFund_revertsForNonOwner() public {
        vm.prank(stranger);
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, stranger));
        factory.registerFund(_instance(1));
    }

    function test_registerFund_revertsOnDuplicateProxy() public {
        KpkOivFactory.OivInstance memory a = _instance(1);
        KpkOivFactory.OivInstance memory b = _instance(2);
        b.kpkSharesProxy = a.kpkSharesProxy; // same fund identity

        vm.startPrank(owner);
        factory.registerFund(a);
        vm.expectRevert(KpkOivFactory.FundAlreadyRegistered.selector);
        factory.registerFund(b);
        vm.stopPrank();
    }

    function test_registerFund_revertsOnAnyZeroAddress() public {
        // Each of the seven components must be non-zero.
        for (uint256 field = 0; field < 7; field++) {
            KpkOivFactory.OivInstance memory inst = _instance(uint160(field + 1));
            if (field == 0) inst.avatarSafe = address(0);
            else if (field == 1) inst.managerSafe = address(0);
            else if (field == 2) inst.execRolesModifier = address(0);
            else if (field == 3) inst.subRolesModifier = address(0);
            else if (field == 4) inst.managerRolesModifier = address(0);
            else if (field == 5) inst.kpkSharesImpl = address(0);
            else inst.kpkSharesProxy = address(0);

            vm.prank(owner);
            vm.expectRevert(KpkOivFactory.ZeroAddress.selector);
            factory.registerFund(inst);
        }
    }

    function test_registerFund_doesNotTouchDeploymentLog() public {
        vm.prank(owner);
        factory.registerFund(_instance(1));
        // The trustless deploy log is a separate registry and must be unaffected.
        assertEq(factory.instanceCount(), 0, "instanceCount");
        assertEq(factory.stackCount(), 0, "stackCount");
    }

    // ── unregisterFund ───────────────────────────────────────────────────────────

    function test_unregisterFund_clearsEntryAndEmits() public {
        KpkOivFactory.OivInstance memory inst = _instance(1);
        vm.prank(owner);
        factory.registerFund(inst);

        vm.expectEmit(true, true, true, true, address(factory));
        emit FundUnregistered(0, inst.kpkSharesProxy);

        vm.prank(owner);
        factory.unregisterFund(0);

        assertFalse(factory.isFundRegistered(inst.kpkSharesProxy), "membership cleared");
        assertEq(_stored(0).kpkSharesProxy, address(0), "slot zeroed");
        // IDs are never reused: the counter holds even though the slot is now empty (a gap).
        assertEq(factory.registeredFundCount(), 1, "count holds");
    }

    function test_unregisterFund_revertsForNonOwner() public {
        vm.prank(owner);
        factory.registerFund(_instance(1));

        vm.prank(stranger);
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, stranger));
        factory.unregisterFund(0);
    }

    function test_unregisterFund_revertsWhenNeverRegistered() public {
        vm.prank(owner);
        vm.expectRevert(KpkOivFactory.FundNotRegistered.selector);
        factory.unregisterFund(0);
    }

    function test_unregisterFund_revertsOnDoubleRemove() public {
        vm.startPrank(owner);
        factory.registerFund(_instance(1));
        factory.unregisterFund(0);
        vm.expectRevert(KpkOivFactory.FundNotRegistered.selector);
        factory.unregisterFund(0);
        vm.stopPrank();
    }

    function test_canReregisterSameProxyAfterUnregister() public {
        KpkOivFactory.OivInstance memory inst = _instance(1);

        vm.startPrank(owner);
        uint256 id0 = factory.registerFund(inst);
        factory.unregisterFund(id0);
        uint256 id1 = factory.registerFund(inst); // same proxy, allowed again once removed
        vm.stopPrank();

        assertEq(id0, 0);
        assertEq(id1, 1, "fresh id, never reused");
        assertTrue(factory.isFundRegistered(inst.kpkSharesProxy));
        _assertEq(_stored(1), inst);
        assertEq(_stored(0).kpkSharesProxy, address(0), "old slot still empty");
    }
}
