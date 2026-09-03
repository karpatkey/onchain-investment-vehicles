// SPDX-License-Identifier: MIT
pragma solidity 0.8.34;

import {
    TimelockControllerUpgradeable
} from "@openzeppelin/contracts-upgradeable/governance/TimelockControllerUpgradeable.sol";
import {Clones} from "@openzeppelin/contracts/proxy/Clones.sol";
import {IRoles} from "./interfaces/IRoles.sol";
import {IKpkTimelockDeployer, TimelockParams} from "./interfaces/IKpkTimelockDeployer.sol";

/// @notice Minimal view of OpenZeppelin `AccessControl`, used to inspect a KpkShares proxy's
///         `DEFAULT_ADMIN_ROLE` holders without importing `KpkShares` (which would pull its full
///         creation bytecode into this contract's runtime — the same rationale as
///         `IKpkSharesDeployer` in `KpkOivFactory.sol`).
interface IAccessControlView {
    /// @notice Returns true if `account` holds `role`.
    function hasRole(bytes32 role, address account) external view returns (bool);
}

/// @title  KpkTimelockDeployer
/// @author kpk
/// @notice Deploys pre-validated OpenZeppelin `TimelockController` instances that a deployed fund's
///         admin holds as (a) the owner of its exec Roles Modifier and (b) the
///         `DEFAULT_ADMIN_ROLE` holder on its KpkShares proxy.
///
/// @dev    `KpkOivFactory` calls this during `deployOiv` / `deployStack` whenever a fund configures a
///         non-zero `minDelay`, and hands the resulting timelock the corresponding authority before
///         the deployment returns. It is also permissionless, so the admin of an already-deployed
///         fund can deploy a matching timelock here and transfer ownership to it by hand.
///
///         ## Clones, not full deployments
///
///         Each timelock is an EIP-1167 minimal proxy against a single per-chain
///         `TimelockControllerUpgradeable` mastercopy — the shape the Zodiac Roles Modifiers already
///         use through `ModuleProxyFactory`. Deploying the controller outright cost about 1.45M gas,
///         which by itself pushed a timelocked `deployStack` past the 3,000,000-gas ceiling that 10 of
///         the 20 CCIP lanes enforce, making a timelocked fund undeliverable to those chains. A clone
///         costs a small fraction of that.
///
///         The clone is immutable — an EIP-1167 stub always delegates to the same mastercopy — so this
///         adds no upgrade surface. The mastercopy takes no constructor arguments and is deployed
///         through the canonical CREATE2 factory, so it sits at one address on every chain and clone
///         addresses stay chain-independent.
///
///         `IKpkTimelockDeployer` additionally keeps the factory's import graph free of the timelock
///         code while still letting it name `TimelockParams`.
///
///         ## Why a contract at all, rather than a deploy script
///
///         `TimelockController`'s constructor is `(minDelay, proposers, executors, admin)` — there is
///         **no cancellers argument**, and `CANCELLER_ROLE` is granted only to proposers. Giving the
///         veto to an address that is deliberately *not* a proposer therefore requires holding
///         `DEFAULT_ADMIN_ROLE` after construction. Doing that from a script leaves a window in which
///         an EOA has full role control over the timelock. This contract closes that window by taking
///         the admin role itself, granting `CANCELLER_ROLE`, and renouncing — atomically, in one
///         transaction, with a closing assertion. It mirrors the transient-admin pattern
///         `KpkOivFactory._deploySharesProxy` already uses on the shares proxy.
///
///         It additionally rejects the misconfigurations that would make an address ambiguous (see
///         `_validate`) and gives every
///         timelock a CREATE2 address that is a function of its full effective configuration, so a
///         predicted address attests the roles and delay it was CREATED with. That is not the same as
///         its state at adoption — a self-administered timelock can be mutated in between — which is
///         why an already-occupied address is re-checked against its live state before it is
///         returned. See `_requireLiveConfigMatches`. That matters because adopting a timelock is one-way in practice: transferring exec
///         Roles Modifier ownership is single-step, so a transfer to a misconfigured timelock
///         permanently strands policy administration for that fund.
///
///         ## Resulting role model (identical for both timelocks)
///
///         | Role                 | Holder                                                      |
///         |----------------------|-------------------------------------------------------------|
///         | `PROPOSER_ROLE`      | `params.proposers` (>= 2, enforced)                          |
///         | `CANCELLER_ROLE`     | `params.cancellers`, plus every proposer (OZ constructor)     |
///         | `EXECUTOR_ROLE`      | `address(0)` — open execution                                |
///         | `DEFAULT_ADMIN_ROLE` | the timelock itself only — self-administered                 |
///
///         Open execution is deliberate: an operation's content is fixed and public at schedule time
///         and has already survived the full delay under the cancellers' eyes, so restricting *who*
///         may push the final button adds no security while introducing a liveness failure — a
///         timelock whose only executors are lost keys can never act again.
///
///         Self-administration is likewise deliberate. An external admin could re-grant itself
///         `PROPOSER_ROLE` instantly, silently removing every operation from the cancellers' view and
///         hollowing out the veto. With `DEFAULT_ADMIN_ROLE` held only by the timelock, role changes
///         and `updateDelay` must themselves be scheduled, delayed, and are cancellable.
///
///         ## What a canceller can and cannot do
///
///         `TimelockController.cancel` resets an operation to `Unset`, which makes it schedulable
///         again. A veto is therefore *suspensive*, not terminal: the same operation may be
///         re-proposed, restarting the timer. Blocking indefinitely requires cancelling every
///         re-proposal inside every delay window. Two consequences worth stating plainly:
///         a canceller that stops paying attention silently stops blocking anything (losing a veto
///         key is harmless), whereas losing every proposer key is fatal and unrecoverable.
///
///         That asymmetry is a reason to hand `CANCELLER_ROLE` out freely and to guard proposer keys
///         carefully — but it is deliberately *not* enforced here. This contract sets no floor on
///         either role set, because `KpkOivFactory` must be able to express every configuration a
///         fund's deployer chooses, including a single proposer and no dedicated canceller. The
///         consequences of those choices are documented at `_validate` and belong to the caller.
///
///         A canceller must also react *within* the delay window; it cannot pre-emptively block a
///         future operation. `minDelay` must therefore be at least the slowest canceller's realistic
///         worst-case reaction time, which is why it is a caller-supplied parameter rather than a
///         constant here — an internal operations multisig and an investor committee convening under
///         notice provisions have reaction times orders of magnitude apart.
contract KpkTimelockDeployer is IKpkTimelockDeployer {
    /// @notice The `TimelockControllerUpgradeable` every clone this contract creates delegates to.
    ///         Immutable: changing it would silently move every predicted clone address.
    address public immutable timelockMastercopy;

    /// @notice Thrown when the constructor is given a zero or codeless mastercopy. A clone of an
    ///         address with no code is an inert contract that would hold a fund's authority and be
    ///         unable to act on it.
    error InvalidMastercopy();

    /// @param _timelockMastercopy The per-chain `TimelockControllerUpgradeable` mastercopy. It takes no
    ///                            constructor arguments and is deployed through the canonical CREATE2
    ///                            factory, so it is at one address on every chain — which is what keeps
    ///                            clone addresses identical across chains.
    constructor(address _timelockMastercopy) {
        if (_timelockMastercopy.code.length == 0) revert InvalidMastercopy();
        timelockMastercopy = _timelockMastercopy;
    }

    // ── Constants ─────────────────────────────────────────────────────────────

    /// @notice Salt domain for timelocks intended to own a fund's exec Roles Modifier.
    bytes32 public constant DOMAIN_EXEC = keccak256("KpkTimelockDeployer.exec");

    /// @notice Salt domain for timelocks intended to hold `DEFAULT_ADMIN_ROLE` on a KpkShares proxy.
    bytes32 public constant DOMAIN_SHARES = keccak256("KpkTimelockDeployer.shares");

    /// @notice Mixed into every salt so a future behavioural change to this contract can be rolled out
    ///         without colliding with addresses produced by this version.
    bytes32 public constant KIT_VERSION = keccak256("KpkTimelockDeployer.v1");

    /// @dev OpenZeppelin `AccessControl` default admin role.
    bytes32 private constant DEFAULT_ADMIN_ROLE = 0x00;

    /// @notice Lower bound on `minDelay`. A delay shorter than this cannot be reacted to by any
    ///         realistic human process, which would make the veto decorative.
    uint256 public constant MIN_DELAY_FLOOR = 12 hours;

    /// @notice Upper bound on `minDelay`. Guards against a fat-fingered unit error (e.g. passing
    ///         milliseconds) permanently freezing a fund's governance behind a decade-long delay.
    uint256 public constant MIN_DELAY_CAP = 30 days;

    /// @notice Upper bound on the length of the `proposers` and `cancellers` arrays. Validation is
    ///         O(n^2) (duplicate detection), so this bounds worst-case gas.
    uint256 public constant MAX_ROLE_MEMBERS = 20;

    // ── Events ────────────────────────────────────────────────────────────────

    /// @notice Emitted once per timelock actually DEPLOYED by this contract. A call that finds the
    ///         deterministic address already occupied returns it without emitting, so this event is a
    ///         record of creation, not of adoption. The canonical record of which timelock governs a
    ///         given fund is `KpkOivFactory`'s `StackDeployed` / `OivDeployed`, whose instance structs
    ///         carry the addresses on every path.
    /// @param domain    `DOMAIN_EXEC` or `DOMAIN_SHARES`.
    /// @param governed  The exec Roles Modifier or KpkShares proxy this timelock is intended to govern.
    /// @param timelock  The deployed `TimelockController`.
    /// @param minDelay  The timelock's minimum delay, in seconds.
    event TimelockDeployed(
        bytes32 indexed domain, address indexed governed, address indexed timelock, uint256 minDelay
    );

    // ── Errors ────────────────────────────────────────────────────────────────

    /// @notice Thrown when `governed`, a proposer, or a canceller is the zero address.
    error ZeroAddress();

    /// @notice Thrown when `minDelay` falls outside `[MIN_DELAY_FLOOR, MIN_DELAY_CAP]`.
    /// @param minDelay The rejected value.
    error DelayOutOfBounds(uint256 minDelay);

    /// @notice Thrown when a role array exceeds `MAX_ROLE_MEMBERS`.
    /// @param provided The rejected length.
    error TooManyRoleMembers(uint256 provided);

    /// @notice Thrown when a role array contains the same address twice. Rejected so that a timelock's
    ///         address remains a one-to-one function of its effective role set.
    /// @param duplicate The repeated address.
    error DuplicateRoleMember(address duplicate);

    /// @notice Thrown when the deterministic address is already occupied by a timelock whose LIVE
    ///         role state no longer matches `params` — see `_requireLiveConfigMatches`.
    /// @param timelock The occupant that was rejected.
    error TimelockStateMismatch(address timelock);

    /// @notice Thrown if this contract still holds `DEFAULT_ADMIN_ROLE` after provisioning. Unreachable
    ///         defensively — a failure here would mean a deployed timelock is externally administrable.
    error AdminNotRenounced();

    // ── Deployment ────────────────────────────────────────────────────────────

    /// @notice Deploys the timelock intended to own `execRolesModifier`.
    /// @dev    Permissionless and idempotent: a second call with identical parameters returns the
    ///         already-deployed address rather than reverting. Deploying does **not** adopt — the
    ///         current owner must subsequently call `IRoles(execRolesModifier).transferOwnership(timelock)`.
    ///         Verify with `isExecTimelocked` afterwards.
    /// @param  execRolesModifier The fund's exec Roles Modifier, whose address is identical on every
    ///                           chain. Given the SAME `params` on each chain, the resulting timelock
    ///                           address is therefore identical everywhere too; differing params on one
    ///                           chain silently produce a different address there.
    /// @param  params            Effective timelock configuration.
    /// @return timelock          The deployed (or pre-existing) `TimelockController`.
    function deployExecTimelock(address execRolesModifier, TimelockParams calldata params)
        external
        returns (address timelock)
    {
        return _deployTimelock(DOMAIN_EXEC, execRolesModifier, params);
    }

    /// @notice Deploys the timelock intended to hold `DEFAULT_ADMIN_ROLE` on `sharesProxy`.
    /// @dev    Permissionless and idempotent, as `deployExecTimelock`. Deploying does **not** adopt —
    ///         the current admin must subsequently `grantRole(0x00, timelock)` and
    ///         `renounceRole(0x00, currentAdmin)`, ideally in one atomic Safe batch. Verify with
    ///         `isSharesTimelocked` afterwards.
    /// @param  sharesProxy The fund's KpkShares proxy.
    /// @param  params      Effective timelock configuration.
    /// @return timelock    The deployed (or pre-existing) `TimelockController`.
    function deploySharesTimelock(address sharesProxy, TimelockParams calldata params)
        external
        returns (address timelock)
    {
        return _deployTimelock(DOMAIN_SHARES, sharesProxy, params);
    }

    // ── Prediction ────────────────────────────────────────────────────────────

    /// @notice Returns the address `deployExecTimelock` would produce for `(execRolesModifier, params)`.
    /// @dev    Validates `params` exactly as the deploy would, so a prediction can never succeed for a
    ///         configuration `deployExecTimelock` would reject. Otherwise pure CREATE2 arithmetic — it
    ///         does not indicate whether that address is already deployed.
    function predictExecTimelock(address execRolesModifier, TimelockParams calldata params)
        external
        view
        returns (address)
    {
        _validate(execRolesModifier, params);
        return _predict(DOMAIN_EXEC, execRolesModifier, params);
    }

    /// @notice Returns the address `deploySharesTimelock` would produce for `(sharesProxy, params)`.
    /// @dev    Validates `params` exactly as the deploy would, so a prediction can never succeed for a
    ///         configuration `deploySharesTimelock` would reject. Otherwise pure CREATE2 arithmetic — it
    ///         does not indicate whether that address is already deployed.
    function predictSharesTimelock(address sharesProxy, TimelockParams calldata params)
        external
        view
        returns (address)
    {
        _validate(sharesProxy, params);
        return _predict(DOMAIN_SHARES, sharesProxy, params);
    }

    // ── Adoption checks ───────────────────────────────────────────────────────

    /// @notice True once `timelock` owns `execRolesModifier`.
    /// @dev    Intended to be swept across every chain a fund lives on: partial adoption leaves a fund
    ///         under mixed governance with nothing on-chain to flag it.
    function isExecTimelocked(address execRolesModifier, address timelock) external view returns (bool) {
        return IRoles(execRolesModifier).owner() == timelock;
    }

    /// @notice True once `timelock` holds `DEFAULT_ADMIN_ROLE` on `sharesProxy` and `previousAdmin`
    ///         no longer does.
    /// @dev    Both halves matter: granting the timelock while the old admin retains the role leaves a
    ///         delay-free bypass of everything the timelock exists to gate.
    function isSharesTimelocked(address sharesProxy, address timelock, address previousAdmin)
        external
        view
        returns (bool)
    {
        IAccessControlView shares = IAccessControlView(sharesProxy);
        return shares.hasRole(DEFAULT_ADMIN_ROLE, timelock) && !shares.hasRole(DEFAULT_ADMIN_ROLE, previousAdmin);
    }

    // ── Internal ──────────────────────────────────────────────────────────────

    /// @dev Validates, CREATE2-deploys, provisions cancellers, and renounces the transient admin role.
    ///      Returns early if the deterministic address is already occupied, which makes the call safe to
    ///      retry after a failed or partially-broadcast multi-chain rollout.
    function _deployTimelock(bytes32 domain, address governed, TimelockParams calldata params)
        internal
        returns (address timelock)
    {
        _validate(governed, params);

        address predicted = _predict(domain, governed, params);
        if (predicted.code.length != 0) {
            // The address attests the CONSTRUCTOR state only. A `TimelockController` is
            // self-administered, so between a permissionless pre-deployment and adoption here, any
            // proposer can schedule and execute `revokeRole`/`updateDelay` on the instance itself —
            // stripping the cancellers and leaving an address that still matches the prediction.
            // Verify the live state before handing this instance a fund's authority.
            _requireLiveConfigMatches(predicted, params);
            return predicted;
        }

        // Open execution: granting EXECUTOR_ROLE to address(0) makes `onlyRoleOrOpenRole` accept any
        // caller. See the contract-level note on why this is a liveness property, not a weakness.
        address[] memory executors = new address[](1);
        executors[0] = address(0);

        // Clone and initialize atomically. The clone exists uninitialized for the span of these two
        // statements only, and no other contract can CREATE2 at this address, so there is no window in
        // which anyone else could initialize it with roles of their own.
        //
        // `address(this)` as the initializing admin is what makes canceller provisioning atomic; it is
        // renounced below, in this same call, before control ever returns to the caller.
        TimelockControllerUpgradeable tl = TimelockControllerUpgradeable(
            payable(Clones.cloneDeterministic(timelockMastercopy, _salt(domain, governed, params)))
        );
        tl.initialize(params.minDelay, params.proposers, executors, address(this));

        uint256 cancellerCount = params.cancellers.length;
        for (uint256 i; i < cancellerCount; ++i) {
            tl.grantRole(tl.CANCELLER_ROLE(), params.cancellers[i]);
        }

        tl.renounceRole(DEFAULT_ADMIN_ROLE, address(this));
        if (tl.hasRole(DEFAULT_ADMIN_ROLE, address(this))) revert AdminNotRenounced();

        timelock = address(tl);
        emit TimelockDeployed(domain, governed, timelock, params.minDelay);
    }

    /// @dev Checks that an already-deployed occupant still matches the configuration its address was
    ///      derived from. Detects the mutations that defeat the design — a removed canceller, a
    ///      removed proposer, a changed delay, a closed executor, or an admin other than the timelock
    ///      itself.
    ///
    ///      LIMIT, and it is a real one: OpenZeppelin's `AccessControl` is not enumerable, so an
    ///      ADDED member cannot be detected. An attacker who pre-deploys and grants themselves
    ///      `PROPOSER_ROLE` passes this check. That weakens the proposer set but does NOT defeat the
    ///      veto — every configured canceller is still verified present, so a hostile proposal
    ///      remains cancellable. Removal, which does defeat it, is caught.
    function _requireLiveConfigMatches(address timelock, TimelockParams calldata params) internal view {
        TimelockControllerUpgradeable tl = TimelockControllerUpgradeable(payable(timelock));

        if (tl.getMinDelay() != params.minDelay) revert TimelockStateMismatch(timelock);
        if (!tl.hasRole(tl.EXECUTOR_ROLE(), address(0))) revert TimelockStateMismatch(timelock);
        if (!tl.hasRole(DEFAULT_ADMIN_ROLE, timelock)) revert TimelockStateMismatch(timelock);
        if (tl.hasRole(DEFAULT_ADMIN_ROLE, address(this))) revert TimelockStateMismatch(timelock);

        bytes32 proposerRole = tl.PROPOSER_ROLE();
        uint256 proposerCount = params.proposers.length;
        for (uint256 i; i < proposerCount; ++i) {
            if (!tl.hasRole(proposerRole, params.proposers[i])) revert TimelockStateMismatch(timelock);
        }

        bytes32 cancellerRole = tl.CANCELLER_ROLE();
        uint256 cancellerCount = params.cancellers.length;
        for (uint256 i; i < cancellerCount; ++i) {
            if (!tl.hasRole(cancellerRole, params.cancellers[i])) revert TimelockStateMismatch(timelock);
        }
    }

    /// @dev Rejects only what would make a timelock's address ambiguous or one of its members
    ///      unusable. It deliberately does NOT reject configurations that are merely dangerous —
    ///      see the block inside this function for which ones, and why that is the caller's call.
    function _validate(address governed, TimelockParams calldata params) internal pure {
        if (governed == address(0)) revert ZeroAddress();

        if (params.minDelay < MIN_DELAY_FLOOR || params.minDelay > MIN_DELAY_CAP) {
            revert DelayOutOfBounds(params.minDelay);
        }

        // No floor on either role set. A caller may deploy a single-proposer timelock, or one with
        // no canceller beyond its own proposers, and both are reachable through `KpkOivFactory`.
        // The hazards are real and are the caller's to accept:
        //
        //   - Zero proposers produces a timelock that can never schedule anything. Whatever it is
        //     then given authority over is frozen permanently — there is no recovery, because
        //     `DEFAULT_ADMIN_ROLE` is held only by the timelock and granting a proposer would
        //     itself have to be proposed.
        //   - One proposer is the same failure one lost key away.
        //   - Zero cancellers is a delay with no veto. That is a coherent configuration, just not
        //     the one the veto design assumes.
        //
        // What remains enforced is only what would make an address ambiguous or a member
        // unusable — see `_validateMembers`.
        _validateMembers(params.proposers);
        _validateMembers(params.cancellers);

        // A canceller that is already a proposer is a no-op grant (OpenZeppelin grants every proposer
        // `CANCELLER_ROLE` at construction) that nonetheless changes the salt. Allowing it would mean
        // two different addresses could carry byte-identical effective roles, breaking the
        // address-attests-configuration property the salt exists to provide.
        uint256 proposerCount = params.proposers.length;
        uint256 cancellerCount = params.cancellers.length;
        for (uint256 i; i < cancellerCount; ++i) {
            address canceller = params.cancellers[i];
            for (uint256 j; j < proposerCount; ++j) {
                if (params.proposers[j] == canceller) revert DuplicateRoleMember(canceller);
            }
        }
    }

    /// @dev Enforces the bound, non-zero and distinctness rules on one role array.
    function _validateMembers(address[] calldata members) internal pure {
        uint256 length = members.length;
        if (length > MAX_ROLE_MEMBERS) revert TooManyRoleMembers(length);

        for (uint256 i; i < length; ++i) {
            address member = members[i];
            if (member == address(0)) revert ZeroAddress();
            for (uint256 j = i + 1; j < length; ++j) {
                if (members[j] == member) revert DuplicateRoleMember(member);
            }
        }
    }

    /// @dev The CREATE2 salt. `cancellers` is load-bearing here and not merely descriptive: cancellers
    ///      are granted *after* construction, so unlike `minDelay` and `proposers` they are absent from
    ///      the init code and would otherwise not influence the address. Binding them into the salt is
    ///      what makes a predicted address a complete attestation of the timelock's role set.
    function _salt(bytes32 domain, address governed, TimelockParams calldata params) internal pure returns (bytes32) {
        return
            keccak256(abi.encode(KIT_VERSION, domain, governed, params.minDelay, params.proposers, params.cancellers));
    }

    /// @dev The EIP-1167 clone address this contract would produce under `_salt`. It depends only on
    ///      `(this deployer, mastercopy, salt)` — all three identical on every chain, which is what
    ///      keeps a fund's timelock address the same everywhere.
    function _predict(bytes32 domain, address governed, TimelockParams calldata params)
        internal
        view
        returns (address)
    {
        return Clones.predictDeterministicAddress(timelockMastercopy, _salt(domain, governed, params), address(this));
    }
}
