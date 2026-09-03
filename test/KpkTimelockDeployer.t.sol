// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

import {Test} from "forge-std/Test.sol";
import {TimelockController} from "@openzeppelin/contracts/governance/TimelockController.sol";
import {KpkTimelockDeployer} from "src/KpkTimelockDeployer.sol";
import {TimelockParams} from "src/interfaces/IKpkTimelockDeployer.sol";

/// @notice Minimal stand-in for a Zodiac Roles Modifier's ownership surface.
contract MockOwnable {
    address public owner;

    constructor(address _owner) {
        owner = _owner;
    }

    function transferOwnership(address newOwner) external {
        require(msg.sender == owner, "not owner");
        owner = newOwner;
    }
}

/// @notice Minimal stand-in for the KpkShares proxy's `DEFAULT_ADMIN_ROLE` surface.
contract MockAccessControlled {
    mapping(bytes32 => mapping(address => bool)) internal _roles;

    constructor(address admin) {
        _roles[0x00][admin] = true;
    }

    function hasRole(bytes32 role, address account) external view returns (bool) {
        return _roles[role][account];
    }

    function grantRole(bytes32 role, address account) external {
        require(_roles[0x00][msg.sender], "not admin");
        _roles[role][account] = true;
    }

    function renounceRole(bytes32 role, address account) external {
        require(account == msg.sender, "not self");
        _roles[role][account] = false;
    }
}

/// @notice Trivial call target used to drive operations through a deployed timelock.
contract Counter {
    uint256 public value;

    function bump() external {
        value += 1;
    }
}

/// @notice Unit tests for `KpkTimelockDeployer` — no fork required.
///         The end-to-end adoption flow against a real fund lives in
///         `KpkTimelockDeployerFork.t.sol`.
contract KpkTimelockDeployerTest is Test {
    KpkTimelockDeployer kit;

    address governanceSafe = makeAddr("governanceSafe");
    address superadminSafe = makeAddr("superadminSafe");
    address managerVetoSafe = makeAddr("managerVetoSafe");
    address lpVetoSafe = makeAddr("lpVetoSafe");
    address execMod = makeAddr("execMod");
    address sharesProxy = makeAddr("sharesProxy");
    address randomExecutor = makeAddr("randomExecutor");

    bytes32 constant DEFAULT_ADMIN_ROLE = 0x00;

    function setUp() public {
        kit = new KpkTimelockDeployer();
    }

    // ── Helpers ────────────────────────────────────────────────────────────────

    /// @dev The configuration the rollout actually uses: two proposers (governance + superadmin) and
    ///      two cancellers (a manager-side operational veto and an investor-side veto).
    function _params() internal view returns (TimelockParams memory p) {
        address[] memory proposers = new address[](2);
        proposers[0] = governanceSafe;
        proposers[1] = superadminSafe;

        address[] memory cancellers = new address[](2);
        cancellers[0] = managerVetoSafe;
        cancellers[1] = lpVetoSafe;

        p = TimelockParams({minDelay: 2 days, proposers: proposers, cancellers: cancellers});
    }

    // ── Determinism ────────────────────────────────────────────────────────────

    function test_predict_matchesDeployedAddress() public {
        TimelockParams memory p = _params();
        address predicted = kit.predictExecTimelock(execMod, p);
        address deployed = kit.deployExecTimelock(execMod, p);
        assertEq(deployed, predicted, "deployed address must match prediction");
    }

    function test_predict_isIndependentOfChainId() public {
        TimelockParams memory p = _params();
        address onMainnet = kit.predictExecTimelock(execMod, p);
        vm.chainId(42161);
        assertEq(kit.predictExecTimelock(execMod, p), onMainnet, "address must not depend on chain id");
    }

    function test_deploy_isIdempotent() public {
        TimelockParams memory p = _params();
        address first = kit.deployExecTimelock(execMod, p);
        address second = kit.deployExecTimelock(execMod, p);
        assertEq(second, first, "redeploy must return the existing timelock, not revert");
    }

    /// @notice Cancellers are granted after construction, so they are absent from the init code and
    ///         influence the address only through the salt. This pins that they do.
    function test_salt_bindsCancellersIntoTheAddress() public {
        TimelockParams memory a = _params();

        TimelockParams memory b = _params();
        b.cancellers[1] = makeAddr("differentVetoSafe");

        assertTrue(
            kit.predictExecTimelock(execMod, a) != kit.predictExecTimelock(execMod, b),
            "a different canceller set must produce a different address"
        );
    }

    function test_salt_separatesExecAndSharesDomains() public view {
        TimelockParams memory p = _params();
        address sameTarget = execMod;
        assertTrue(
            kit.predictExecTimelock(sameTarget, p) != kit.predictSharesTimelock(sameTarget, p),
            "exec and shares domains must not collide"
        );
    }

    function test_salt_bindsMinDelay() public view {
        TimelockParams memory a = _params();
        TimelockParams memory b = _params();
        b.minDelay = 3 days;
        assertTrue(kit.predictExecTimelock(execMod, a) != kit.predictExecTimelock(execMod, b), "minDelay must bind");
    }

    // ── Role wiring ────────────────────────────────────────────────────────────

    function test_roles_proposersHoldProposerAndCanceller() public {
        TimelockController tl = TimelockController(payable(kit.deployExecTimelock(execMod, _params())));

        assertTrue(tl.hasRole(tl.PROPOSER_ROLE(), governanceSafe), "governance must propose");
        assertTrue(tl.hasRole(tl.PROPOSER_ROLE(), superadminSafe), "superadmin must propose");
        assertTrue(tl.hasRole(tl.CANCELLER_ROLE(), governanceSafe), "proposers get CANCELLER from OZ");
        assertTrue(tl.hasRole(tl.CANCELLER_ROLE(), superadminSafe), "proposers get CANCELLER from OZ");
    }

    function test_roles_cancellersHoldVetoButCannotPropose() public {
        TimelockController tl = TimelockController(payable(kit.deployExecTimelock(execMod, _params())));

        assertTrue(tl.hasRole(tl.CANCELLER_ROLE(), managerVetoSafe), "manager veto must hold CANCELLER");
        assertTrue(tl.hasRole(tl.CANCELLER_ROLE(), lpVetoSafe), "lp veto must hold CANCELLER");
        assertFalse(tl.hasRole(tl.PROPOSER_ROLE(), managerVetoSafe), "veto must not gain proposal rights");
        assertFalse(tl.hasRole(tl.PROPOSER_ROLE(), lpVetoSafe), "veto must not gain proposal rights");
    }

    function test_roles_executionIsOpen() public {
        TimelockController tl = TimelockController(payable(kit.deployExecTimelock(execMod, _params())));
        assertTrue(tl.hasRole(tl.EXECUTOR_ROLE(), address(0)), "EXECUTOR_ROLE(0) enables open execution");
    }

    function test_roles_isSelfAdministeredAndKitRenounced() public {
        TimelockController tl = TimelockController(payable(kit.deployExecTimelock(execMod, _params())));

        assertTrue(tl.hasRole(DEFAULT_ADMIN_ROLE, address(tl)), "timelock must administer itself");
        assertFalse(tl.hasRole(DEFAULT_ADMIN_ROLE, address(kit)), "kit must renounce its transient admin role");
        assertFalse(tl.hasRole(DEFAULT_ADMIN_ROLE, governanceSafe), "no external admin");
        assertFalse(tl.hasRole(DEFAULT_ADMIN_ROLE, address(this)), "no external admin");
    }

    function test_minDelay_isTheSuppliedParameter() public {
        TimelockParams memory p = _params();
        p.minDelay = 5 days;
        TimelockController tl = TimelockController(payable(kit.deployExecTimelock(execMod, p)));
        assertEq(tl.getMinDelay(), 5 days, "minDelay must be caller-supplied");
    }

    // ── Validation ─────────────────────────────────────────────────────────────

    function test_revert_delayBelowFloor() public {
        TimelockParams memory p = _params();
        p.minDelay = 1 hours;
        vm.expectRevert(abi.encodeWithSelector(KpkTimelockDeployer.DelayOutOfBounds.selector, 1 hours));
        kit.deployExecTimelock(execMod, p);
    }

    function test_revert_delayAboveCap() public {
        TimelockParams memory p = _params();
        p.minDelay = 60 days;
        vm.expectRevert(abi.encodeWithSelector(KpkTimelockDeployer.DelayOutOfBounds.selector, 60 days));
        kit.deployExecTimelock(execMod, p);
    }

    function test_revert_zeroProposer() public {
        TimelockParams memory p = _params();
        p.proposers[1] = address(0);
        vm.expectRevert(KpkTimelockDeployer.ZeroAddress.selector);
        kit.deployExecTimelock(execMod, p);
    }

    function test_revert_zeroCanceller() public {
        TimelockParams memory p = _params();
        p.cancellers[0] = address(0);
        vm.expectRevert(KpkTimelockDeployer.ZeroAddress.selector);
        kit.deployExecTimelock(execMod, p);
    }

    function test_revert_duplicateProposer() public {
        TimelockParams memory p = _params();
        p.proposers[1] = governanceSafe;
        vm.expectRevert(abi.encodeWithSelector(KpkTimelockDeployer.DuplicateRoleMember.selector, governanceSafe));
        kit.deployExecTimelock(execMod, p);
    }

    function test_revert_duplicateCanceller() public {
        TimelockParams memory p = _params();
        p.cancellers[1] = managerVetoSafe;
        vm.expectRevert(abi.encodeWithSelector(KpkTimelockDeployer.DuplicateRoleMember.selector, managerVetoSafe));
        kit.deployExecTimelock(execMod, p);
    }

    function test_revert_tooManyProposers() public {
        TimelockParams memory p = _params();
        address[] memory many = new address[](21);
        for (uint256 i; i < 21; ++i) {
            many[i] = address(uint160(i + 1));
        }
        p.proposers = many;
        vm.expectRevert(abi.encodeWithSelector(KpkTimelockDeployer.TooManyRoleMembers.selector, 21));
        kit.deployExecTimelock(execMod, p);
    }

    function test_revert_tooManyCancellers() public {
        TimelockParams memory p = _params();
        address[] memory many = new address[](21);
        for (uint256 i; i < 21; ++i) {
            many[i] = address(uint160(i + 1));
        }
        p.cancellers = many;
        vm.expectRevert(abi.encodeWithSelector(KpkTimelockDeployer.TooManyRoleMembers.selector, 21));
        kit.deployExecTimelock(execMod, p);
    }

    /// @dev The two relaxations are reachable, not merely undocumented: pin that they deploy.
    function test_acceptsSingleProposerAndNoCancellers() public {
        TimelockParams memory p = _params();
        address[] memory one = new address[](1);
        one[0] = governanceSafe;
        p.proposers = one;
        p.cancellers = new address[](0);

        TimelockController tl = TimelockController(payable(kit.deployExecTimelock(execMod, p)));
        assertTrue(tl.hasRole(tl.PROPOSER_ROLE(), governanceSafe), "single proposer must be wired");
        assertFalse(tl.hasRole(tl.CANCELLER_ROLE(), lpVetoSafe), "no dedicated canceller expected");
    }

    function test_revert_zeroGovernedAddress() public {
        vm.expectRevert(KpkTimelockDeployer.ZeroAddress.selector);
        kit.deployExecTimelock(address(0), _params());
    }

    // ── Veto semantics ─────────────────────────────────────────────────────────

    /// @notice A canceller stops a scheduled operation from ever becoming executable.
    function test_veto_cancelledOperationCannotExecute() public {
        (TimelockController tl, Counter counter, bytes memory payload, bytes32 id) = _scheduled();

        vm.prank(lpVetoSafe);
        tl.cancel(id);

        vm.warp(block.timestamp + 3 days);
        vm.expectRevert();
        tl.execute(address(counter), 0, payload, bytes32(0), bytes32(0));
        assertEq(counter.value(), 0, "vetoed operation must not take effect");
    }

    /// @notice `cancel` resets an operation to `Unset`, so the identical operation can be scheduled
    ///         again with the timer restarted. The veto is suspensive, not terminal — blocking
    ///         indefinitely requires cancelling every re-proposal.
    function test_veto_isSuspensiveNotTerminal() public {
        (TimelockController tl, Counter counter, bytes memory payload, bytes32 id) = _scheduled();

        vm.prank(lpVetoSafe);
        tl.cancel(id);

        // Same target, same payload, same salt — the identical operation id.
        vm.prank(governanceSafe);
        tl.schedule(address(counter), 0, payload, bytes32(0), bytes32(0), 2 days);

        vm.warp(block.timestamp + 3 days);
        tl.execute(address(counter), 0, payload, bytes32(0), bytes32(0));
        assertEq(counter.value(), 1, "re-proposed operation must execute after a veto");
    }

    /// @notice A canceller cannot pre-emptively block: `cancel` requires a pending operation.
    function test_veto_cannotCancelBeforeScheduling() public {
        TimelockController tl = TimelockController(payable(kit.deployExecTimelock(execMod, _params())));
        Counter counter = new Counter();
        bytes memory payload = abi.encodeCall(Counter.bump, ());
        bytes32 id = tl.hashOperation(address(counter), 0, payload, bytes32(0), bytes32(0));

        vm.prank(lpVetoSafe);
        vm.expectRevert();
        tl.cancel(id);
    }

    function test_veto_nonCancellerCannotCancel() public {
        (TimelockController tl,,, bytes32 id) = _scheduled();

        vm.prank(randomExecutor);
        vm.expectRevert();
        tl.cancel(id);
    }

    /// @notice Open execution: anyone may push the button once the delay has elapsed unvetoed.
    function test_openExecution_anyCallerMayExecute() public {
        (TimelockController tl, Counter counter, bytes memory payload,) = _scheduled();

        vm.warp(block.timestamp + 3 days);
        vm.prank(randomExecutor);
        tl.execute(address(counter), 0, payload, bytes32(0), bytes32(0));
        assertEq(counter.value(), 1, "open execution must let an unprivileged caller execute");
    }

    function test_delay_isEnforced() public {
        (TimelockController tl, Counter counter, bytes memory payload,) = _scheduled();

        vm.warp(block.timestamp + 1 days);
        vm.expectRevert();
        tl.execute(address(counter), 0, payload, bytes32(0), bytes32(0));
    }

    // ── Adoption views ─────────────────────────────────────────────────────────

    function test_isExecTimelocked_reflectsOwnershipTransfer() public {
        MockOwnable mod = new MockOwnable(governanceSafe);
        address tl = kit.deployExecTimelock(address(mod), _params());

        assertFalse(kit.isExecTimelocked(address(mod), tl), "not adopted before transfer");

        vm.prank(governanceSafe);
        mod.transferOwnership(tl);

        assertTrue(kit.isExecTimelocked(address(mod), tl), "adopted after transfer");
    }

    function test_isSharesTimelocked_requiresOldAdminToHaveRenounced() public {
        MockAccessControlled shares = new MockAccessControlled(governanceSafe);
        address tl = kit.deploySharesTimelock(address(shares), _params());

        vm.prank(governanceSafe);
        shares.grantRole(DEFAULT_ADMIN_ROLE, tl);

        assertFalse(
            kit.isSharesTimelocked(address(shares), tl, governanceSafe),
            "granting alone leaves a delay-free bypass and must not count as adopted"
        );

        vm.prank(governanceSafe);
        shares.renounceRole(DEFAULT_ADMIN_ROLE, governanceSafe);

        assertTrue(kit.isSharesTimelocked(address(shares), tl, governanceSafe), "adopted after renounce");
    }

    // ── Internal helpers ───────────────────────────────────────────────────────

    /// @dev Deploys a timelock, schedules a `Counter.bump()` operation from a proposer, and returns
    ///      the pieces needed to cancel or execute it.
    function _scheduled()
        internal
        returns (TimelockController tl, Counter counter, bytes memory payload, bytes32 id)
    {
        tl = TimelockController(payable(kit.deployExecTimelock(execMod, _params())));
        counter = new Counter();
        payload = abi.encodeCall(Counter.bump, ());
        // Resolved here, never inline at a call site: `hashOperation` is itself a call, so evaluating
        // it as an argument would consume a preceding `vm.prank` and the cancel would run as the test
        // contract instead of the intended canceller.
        id = tl.hashOperation(address(counter), 0, payload, bytes32(0), bytes32(0));

        vm.prank(governanceSafe);
        tl.schedule(address(counter), 0, payload, bytes32(0), bytes32(0), 2 days);
    }
}
