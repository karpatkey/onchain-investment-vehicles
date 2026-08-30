// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";
import {KpkOivFactory} from "./KpkOivFactory.sol";
import {KpkSharesNav} from "./KpkSharesNav.sol";

/// @title  KpkSharesNavFactory
/// @author kpk
/// @notice One-call deployment of a NAV-priced fund: the full five-contract operational stack
///         (Avatar Safe, Manager Safe, three Zodiac Roles Modifiers) plus a `KpkSharesNav` proxy,
///         all on a single chain.
///
/// @dev    WHY THIS IS A SEPARATE CONTRACT RATHER THAN A FUNCTION ON `KpkOivFactory`
///         `KpkOivFactory` is byte-frozen. `test/FactoryAddressSync.t.sol` derives the factory's
///         address from `type(KpkOivFactory).creationCode`, and the live salt-v3 stack — factory,
///         shares deployer and CCIP orchestrator — is deployed and Safe-owned on 19 chains at
///         addresses that are a pure function of that bytecode. Adding a function, or even editing
///         a NatSpec line, moves all three and the repo can no longer reproduce what is deployed.
///         So this is a sibling, exactly as `KpkSharesNav` is a sibling of `KpkShares`.
///
///         WHY IT COMPOSES THE LIVE FACTORY INSTEAD OF REDEPLOYING THE STACK ITSELF
///         `KpkOivFactory.deployStack` is permissionless and already does the hard part: it deploys
///         and wires the two Safes and the three Roles Modifiers, registers the MultiSend unwrap
///         adapters, and transfers ownership. Calling it reuses that audited, deployed code
///         verbatim rather than copying ~700 lines of Safe and Roles wiring into a second contract
///         that would then have to be kept in step forever. This repo has already been bitten twice
///         by exactly that class of drift, and the unwrapper defect that made every fund reject
///         batched multiSends originated in this wiring.
///
///         WHY THE IMPLEMENTATION IS PRE-DEPLOYED RATHER THAN MINTED PER FUND
///         `KpkOivFactory` deploys a fresh `KpkShares` implementation per fund through
///         `KpkSharesDeployer`, which embeds `type(KpkShares).creationCode` (22,912 bytes) in its
///         runtime. That trick cannot work here: `KpkSharesNav`'s initcode is 24,704 bytes, which
///         on its own exceeds EIP-170's 24,576-byte runtime limit, so no contract can carry it.
///         The implementation is therefore deployed once, out of band, and set by the owner. Funds
///         share it, which is safe — UUPS upgrades are per-proxy, so one fund's upgrade cannot
///         reach another — but it does mean this factory's funds do NOT get the isolated upgrade
///         surface `deployOiv` gives, and the owner is trusted to set a genuine implementation.
///
///         WHAT THIS FACTORY DELIBERATELY DOES NOT DO: TOKEN APPROVALS.
///         `deployOiv` grants the shares proxy an infinite allowance from the Avatar Safe, which it
///         can do because it is still enabled as an Avatar Safe module at that point.
///         `deployStack` disables the factory as a module before returning, and `StackConfig` has
///         no field for enabling another one, so this contract has no route to execute as the
///         Avatar Safe and cannot grant those approvals.
///
///         CONSEQUENCE, AND IT IS OPERATIONAL, NOT COSMETIC: **redemptions revert on payout until
///         the Avatar Safe approves the fund proxy for every redeemable asset.** That approval must
///         be made after deployment as a normal governed transaction through the exec Roles
///         Modifier. `NavFundDeployed` carries every address needed to build it. This matches what
///         `script/DeployKpkSharesNav.s.sol` already documents for the standalone path.
contract KpkSharesNavFactory is Ownable, ReentrancyGuard {
    // ── Constants ──────────────────────────────────────────────────────────────

    /// @notice `DEFAULT_ADMIN_ROLE` on the deployed fund.
    bytes32 private constant DEFAULT_ADMIN_ROLE = 0x00;

    /// @notice OPERATOR role identifier on the deployed fund.
    /// @dev Must match `KpkSharesNav.OPERATOR`. Asserted in `test/KpkSharesNavFactory.t.sol`
    ///      against the live constant rather than trusted.
    bytes32 private constant OPERATOR = keccak256("OPERATOR");

    // ── Storage ────────────────────────────────────────────────────────────────

    /// @notice The live `KpkOivFactory` whose `deployStack` produces the operational stack.
    /// @dev Immutable: repointing it would silently change every future fund's Safe addresses, and
    ///      the whole security argument for this contract is that the stack comes from the audited,
    ///      already-deployed factory.
    KpkOivFactory public immutable oivFactory;

    /// @notice The `KpkSharesNav` implementation every fund's proxy delegates to.
    address public navImplementation;

    /// @notice Append-only log of funds this factory deployed.
    mapping(uint256 => NavFundInstance) public funds;

    /// @notice Number of funds deployed; also the next fund's id.
    uint256 public fundCount;

    // ── Structs ────────────────────────────────────────────────────────────────

    /// @notice Full configuration for a NAV fund deployment.
    struct NavFundConfig {
        /// @notice Signer configuration for the Manager Safe.
        ///         SECURITY: these owners must be trusted at the same operational level as `admin`
        ///         — the Manager Safe receives ownership of the sub and manager Roles Modifiers.
        KpkOivFactory.SafeConfig managerSafe;
        /// @notice Final owner of the exec Roles Modifier — the authoritative gatekeeper of Avatar
        ///         Safe execution. The sub and manager modifiers always go to the Manager Safe
        ///         regardless of what is passed here.
        KpkOivFactory.RolesModifierConfig execRolesMod;
        /// @notice Receives `DEFAULT_ADMIN_ROLE` on the fund. Must not be this factory.
        address admin;
        /// @notice Fund initialization parameters. `admin` and `safe` are OVERWRITTEN by this
        ///         factory — `safe` with the freshly deployed Avatar Safe, `admin` with this
        ///         factory for the duration of the call. Whatever is passed in those two fields is
        ///         ignored.
        KpkSharesNav.ConstructorParams sharesParams;
        /// @notice Assets to list beyond the base asset. Each must already be registered and
        ///         priceable in the NAV calculator, or `updateAsset` reverts and the deploy fails.
        KpkOivFactory.AssetConfig[] additionalAssets;
        /// @notice Base salt. Hashed together with `msg.sender` so two callers using the same salt
        ///         get independent stacks rather than colliding on an already-deployed Safe.
        uint256 salt;
    }

    /// @notice Addresses of the seven contracts a successful deployment produces.
    struct NavFundInstance {
        /// @notice Avatar Safe — holds fund assets; execution via Roles Modifiers only.
        address avatarSafe;
        /// @notice Manager Safe — operational multisig; holds OPERATOR on the fund.
        address managerSafe;
        /// @notice Exec Roles Modifier — primary layer; module on the Avatar Safe.
        address execRolesModifier;
        /// @notice Sub Roles Modifier — nested inside the exec modifier.
        address subRolesModifier;
        /// @notice Manager Roles Modifier — guards the Manager Safe's own actions.
        address managerRolesModifier;
        /// @notice The shared `KpkSharesNav` implementation this fund delegates to.
        address navImpl;
        /// @notice The fund itself.
        address navProxy;
    }

    // ── Events ─────────────────────────────────────────────────────────────────

    /// @notice Emitted when the shared implementation is set or replaced.
    event NavImplementationUpdated(address indexed navImplementation);

    /// @notice Emitted once per successful deployment, carrying every address an operator needs —
    ///         including the two required to build the post-deploy approval transaction.
    event NavFundDeployed(uint256 indexed id, NavFundInstance instance);

    // ── Errors ─────────────────────────────────────────────────────────────────

    error ZeroAddress();
    error NotAContract();
    error NavImplementationNotSet();
    error AdminIsFactory();
    error DuplicateAsset();
    error RoleHandoverFailed();

    // ── Constructor ────────────────────────────────────────────────────────────

    /// @param _oivFactory        The live `KpkOivFactory` (salt-v3) on this chain.
    /// @param _navImplementation The pre-deployed `KpkSharesNav` implementation. May be zero here
    ///                           and set later with `setNavImplementation`.
    /// @param initialOwner       Owner of this factory; may set the implementation.
    constructor(address _oivFactory, address _navImplementation, address initialOwner) Ownable(initialOwner) {
        if (_oivFactory == address(0)) revert ZeroAddress();
        if (_oivFactory.code.length == 0) revert NotAContract();
        oivFactory = KpkOivFactory(_oivFactory);

        if (_navImplementation != address(0)) {
            _setNavImplementation(_navImplementation);
        }
    }

    // ── Admin ──────────────────────────────────────────────────────────────────

    /// @notice Sets the shared `KpkSharesNav` implementation used by future deployments.
    /// @dev Existing funds are unaffected — each proxy holds its own implementation pointer, so
    ///      changing this never migrates a deployed fund.
    /// @param _navImplementation The new implementation. Must be a contract.
    function setNavImplementation(address _navImplementation) external onlyOwner {
        if (_navImplementation == address(0)) revert ZeroAddress();
        _setNavImplementation(_navImplementation);
    }

    // ── Main entry point ───────────────────────────────────────────────────────

    /// @notice Deploys a complete NAV-priced fund on this chain: Avatar Safe, Manager Safe, three
    ///         Roles Modifiers, and an initialized `KpkSharesNav` proxy.
    /// @dev    Permissionless, mirroring `deployOiv`.
    ///
    ///         Sequence, and the ordering is load-bearing:
    ///           1. Reserve the registry id before any external call (CEI), so an ERC-20 callback
    ///              fired during `updateAsset` cannot shift indices.
    ///           2. `oivFactory.deployStack` — the audited stack, with a salt bound to `msg.sender`.
    ///           3. Deploy the proxy with THIS FACTORY as admin and the fresh Avatar Safe as the
    ///              portfolio safe. The factory must hold admin to complete the wiring below; it
    ///              gives it up before returning.
    ///           4. Take OPERATOR transiently — `updateAsset` is operator-gated, not admin-gated —
    ///              list the additional assets, then drop it.
    ///           5. Hand OPERATOR to the Manager Safe and `DEFAULT_ADMIN_ROLE` to `config.admin`,
    ///              renounce the factory's own admin, and ASSERT the handover landed.
    ///
    ///         Reverts if the NAV calculator rejects any listed asset — `KpkSharesNav.initialize`
    ///         and `updateAsset` both gate on the NAV registry, so a fund can never be deployed
    ///         holding an asset it cannot price.
    ///
    ///         REMINDER: the Avatar Safe must still approve the returned `navProxy` for every
    ///         redeemable asset before redemptions can pay out. See the contract-level NatSpec.
    /// @param  config   Deployment parameters.
    /// @return instance The seven deployed addresses, also stored at `funds[id]`.
    function deployNavFund(NavFundConfig calldata config)
        external
        nonReentrant
        returns (NavFundInstance memory instance)
    {
        address impl = navImplementation;
        if (impl == address(0)) revert NavImplementationNotSet();
        _validate(config);

        // CEI: reserve the id before any external call.
        uint256 id = fundCount++;

        KpkOivFactory.StackInstance memory stack = oivFactory.deployStack(
            KpkOivFactory.StackConfig({
                managerSafe: config.managerSafe,
                execRolesMod: config.execRolesMod,
                // The sub and manager modifiers always transfer to the Manager Safe regardless of
                // the `finalOwner` passed, so the exec config is reused rather than asking the
                // caller for two values that are documented to be ignored.
                subRolesMod: config.execRolesMod,
                managerRolesMod: config.execRolesMod,
                // Bound to the caller so two callers sharing a salt get independent stacks instead
                // of the second one reverting on an already-deployed Safe address.
                salt: uint256(keccak256(abi.encode(msg.sender, config.salt)))
            })
        );

        address proxy = _deployFundProxy(impl, config, stack.avatarSafe);
        _wireFund(proxy, config, stack.managerSafe);

        instance = NavFundInstance({
            avatarSafe: stack.avatarSafe,
            managerSafe: stack.managerSafe,
            execRolesModifier: stack.execRolesModifier,
            subRolesModifier: stack.subRolesModifier,
            managerRolesModifier: stack.managerRolesModifier,
            navImpl: impl,
            navProxy: proxy
        });

        funds[id] = instance;
        emit NavFundDeployed(id, instance);
    }

    // ── Internals ──────────────────────────────────────────────────────────────

    /// @dev Deploys the ERC-1967 proxy and initializes it in one transaction.
    ///      `admin` is set to this factory and `safe` to the Avatar Safe, overwriting whatever the
    ///      caller passed in those two fields — the factory needs admin to finish wiring, and the
    ///      Avatar Safe does not exist until `deployStack` has run.
    function _deployFundProxy(address impl, NavFundConfig calldata config, address avatarSafe)
        private
        returns (address)
    {
        KpkSharesNav.ConstructorParams memory params = config.sharesParams;
        params.admin = address(this);
        params.safe = avatarSafe;

        bytes32 proxySalt = keccak256(abi.encode(msg.sender, config.salt, "KPK_SHARES_NAV_PROXY"));
        return address(new ERC1967Proxy{salt: proxySalt}(impl, abi.encodeCall(KpkSharesNav.initialize, (params))));
    }

    /// @dev Lists the additional assets, hands the roles to their real holders, and verifies it.
    ///      The post-conditions assert POSITIVELY that the intended holders hold their roles, not
    ///      merely that the factory dropped its own: if `config.admin` were this factory, the grant
    ///      would be a no-op on a role it already holds, the renounce would remove the only holder,
    ///      and a factory-only check would pass precisely because nobody was left. `_validate`
    ///      refuses that configuration outright; this is the backstop.
    function _wireFund(address proxy, NavFundConfig calldata config, address managerSafe) private {
        KpkSharesNav fund = KpkSharesNav(proxy);

        uint256 length = config.additionalAssets.length;
        if (length != 0) {
            // `updateAsset` is operator-gated rather than admin-gated, so the factory takes
            // OPERATOR for exactly as long as it needs it.
            fund.grantRole(OPERATOR, address(this));
            for (uint256 i; i < length; i++) {
                KpkOivFactory.AssetConfig calldata asset = config.additionalAssets[i];
                fund.updateAsset(asset.asset, asset.canDeposit, asset.canRedeem);
            }
            fund.revokeRole(OPERATOR, address(this));
        }

        fund.grantRole(OPERATOR, managerSafe);
        fund.grantRole(DEFAULT_ADMIN_ROLE, config.admin);
        fund.renounceRole(DEFAULT_ADMIN_ROLE, address(this));

        if (
            !fund.hasRole(DEFAULT_ADMIN_ROLE, config.admin) || !fund.hasRole(OPERATOR, managerSafe)
                || fund.hasRole(DEFAULT_ADMIN_ROLE, address(this)) || fund.hasRole(OPERATOR, address(this))
        ) revert RoleHandoverFailed();
    }

    /// @dev Validates what this factory is responsible for. Manager-Safe owners, the threshold and
    ///      the exec modifier's owner are validated by `deployStack`, and every asset's NAV
    ///      registration by the fund itself — neither is re-checked here.
    function _validate(NavFundConfig calldata config) private view {
        if (config.admin == address(0)) revert ZeroAddress();
        if (config.sharesParams.asset == address(0)) revert ZeroAddress();

        // A fund whose admin is this factory would be left with NO admin: the grant is a no-op and
        // the renounce that follows removes the last holder. No upgrades, no `setNavCalculator`,
        // no toggles, forever.
        if (config.admin == address(this)) revert AdminIsFactory();

        uint256 length = config.additionalAssets.length;
        for (uint256 i; i < length; i++) {
            address asset = config.additionalAssets[i].asset;
            if (asset == address(0)) revert ZeroAddress();
            // Listing the base asset again would overwrite its flags with whatever is passed here,
            // silently disabling deposits or redemptions on the fund's own base asset.
            if (asset == config.sharesParams.asset) revert DuplicateAsset();
            for (uint256 j = i + 1; j < length; j++) {
                if (asset == config.additionalAssets[j].asset) revert DuplicateAsset();
            }
        }
    }

    /// @dev Shared by the constructor and the setter so both enforce the contract check.
    function _setNavImplementation(address _navImplementation) private {
        if (_navImplementation.code.length == 0) revert NotAContract();
        navImplementation = _navImplementation;
        emit NavImplementationUpdated(_navImplementation);
    }
}
