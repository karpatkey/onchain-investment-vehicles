// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";
import {KpkShares} from "./kpkShares.sol";
import {ISafe} from "./interfaces/ISafe.sol";
import {ISafeProxyFactory} from "./interfaces/ISafeProxyFactory.sol";
import {ISafeModuleSetup} from "./interfaces/ISafeModuleSetup.sol";
import {IModuleProxyFactory} from "./interfaces/IModuleProxyFactory.sol";
import {IRoles} from "./interfaces/IRoles.sol";

/// @notice On-chain factory that deploys a full kpk fund stack in a single transaction:
///         Avatar Safe → Manager Safe → 3 Roles Modifiers → kpkShares UUPS proxy.
///
///         Avoids the SafeProxyOwner workaround by deploying Roles Modifiers first (factory
///         as temporary owner/avatar/target), then deploying Safes with the modifier addresses
///         embedded in their setup() delegatecall data (SafeModuleSetup.enableModules).
///         After Safes are deployed the factory fixes avatars/targets and transfers ownership.
contract KpkSharesFactory is Ownable {
    // ── Roles ─────────────────────────────────────────────────────────────────

    bytes32 private constant OPERATOR = keccak256("OPERATOR");
    bytes32 private constant DEFAULT_ADMIN_ROLE = 0x00;
    // forge-lint: disable-next-line(unsafe-typecast)
    bytes32 private constant MANAGER_ROLE = bytes32("MANAGER");

    // ── Immutables ─────────────────────────────────────────────────────────────

    /// @notice Shared KpkShares implementation — every proxy deployed by this factory points here.
    // forge-lint: disable-next-line(screaming-snake-case-immutable)
    address public immutable kpkSharesImpl;

    // forge-lint: disable-next-line(screaming-snake-case-immutable)
    address public immutable safeProxyFactory;
    // forge-lint: disable-next-line(screaming-snake-case-immutable)
    address public immutable safeSingleton;

    /// @notice Safe utility contract delegatecalled during Safe setup() to enable modules.
    // forge-lint: disable-next-line(screaming-snake-case-immutable)
    address public immutable safeModuleSetup;

    // forge-lint: disable-next-line(screaming-snake-case-immutable)
    address public immutable safeFallbackHandler;
    // forge-lint: disable-next-line(screaming-snake-case-immutable)
    address public immutable moduleProxyFactory;
    // forge-lint: disable-next-line(screaming-snake-case-immutable)
    address public immutable rolesModifierMastercopy;

    // ── Structs ────────────────────────────────────────────────────────────────

    struct SafeConfig {
        address[] owners;
        uint256 threshold;
        /// @notice Passed as saltNonce to createProxyWithNonce for deterministic addressing.
        uint256 nonce;
    }

    struct RolesModifierConfig {
        /// @notice saltNonce passed to ModuleProxyFactory.deployModule.
        uint256 salt;
        /// @notice Address that receives ownership after wiring is complete.
        address finalOwner;
    }

    struct FundConfig {
        SafeConfig avatarSafe;
        SafeConfig managerSafe;
        /// @notice Primary modifier — enabled as module on Avatar Safe.
        RolesModifierConfig execRolesMod;
        /// @notice Sub-modifier — enabled as module inside execRolesMod, targets execRolesMod.
        RolesModifierConfig subRolesMod;
        /// @notice Manager modifier — enabled as module on Manager Safe, guards manager actions.
        RolesModifierConfig managerRolesMod;
        /// @notice kpkShares initialization params. sharesParams.safe is overridden with the
        ///         deployed avatarSafe address. sharesParams.admin is overridden with address(this)
        ///         during initialization so the factory can set up roles, then the real admin is
        ///         granted and the factory renounces.
        KpkShares.ConstructorParams sharesParams;
        /// @notice Address that receives the OPERATOR role on the kpkShares proxy.
        address sharesOperator;
    }

    struct FundInstance {
        address avatarSafe;
        address managerSafe;
        address execRolesModifier;
        address subRolesModifier;
        address managerRolesModifier;
        address kpkSharesProxy;
    }

    // ── State ──────────────────────────────────────────────────────────────────

    uint256 public instanceCount;
    mapping(uint256 => FundInstance) public instances;

    // ── Events ─────────────────────────────────────────────────────────────────

    event FundDeployed(uint256 indexed instanceId, FundInstance instance);

    // ── Errors ─────────────────────────────────────────────────────────────────

    error ZeroAddress();
    error EmptyOwners();
    error InvalidThreshold();

    // ── Constructor ────────────────────────────────────────────────────────────

    constructor(
        address _owner,
        address _kpkSharesImpl,
        address _safeProxyFactory,
        address _safeSingleton,
        address _safeModuleSetup,
        address _safeFallbackHandler,
        address _moduleProxyFactory,
        address _rolesModifierMastercopy
    ) Ownable(_owner) {
        if (
            _kpkSharesImpl == address(0) || _safeProxyFactory == address(0) || _safeSingleton == address(0)
                || _safeModuleSetup == address(0) || _safeFallbackHandler == address(0)
                || _moduleProxyFactory == address(0) || _rolesModifierMastercopy == address(0)
        ) revert ZeroAddress();

        kpkSharesImpl = _kpkSharesImpl;
        safeProxyFactory = _safeProxyFactory;
        safeSingleton = _safeSingleton;
        safeModuleSetup = _safeModuleSetup;
        safeFallbackHandler = _safeFallbackHandler;
        moduleProxyFactory = _moduleProxyFactory;
        rolesModifierMastercopy = _rolesModifierMastercopy;
    }

    // ── Main entry point ────────────────────────────────────────────────────────

    /// @notice Deploy a full fund stack: safes, roles modifiers, and a kpkShares proxy.
    /// @dev Deployment order:
    ///      1. Deploy 3 roles modifiers (factory as temp owner/avatar/target).
    ///      2. Deploy Avatar Safe with execRolesMod already enabled via setup delegatecall.
    ///      3. Deploy Manager Safe with managerRolesMod already enabled via setup delegatecall.
    ///      4. Wire execRolesMod: fix avatar/target, assign roles, enable subRolesMod, transfer ownership.
    ///      5. Wire subRolesMod: fix avatar/target, transfer ownership to managerSafe.
    ///      6. Wire managerRolesMod: fix avatar/target, transfer ownership to managerSafe.
    ///      7. Deploy kpkShares proxy, grant roles, factory renounces.
    function deployFund(FundConfig calldata config) external onlyOwner returns (FundInstance memory instance) {
        _validateConfig(config);

        // Step 1 – Deploy all three roles modifiers with factory as temp owner/avatar/target.
        address execMod = _deployRolesModifier(config.execRolesMod.salt);
        address subMod = _deployRolesModifier(config.subRolesMod.salt);
        address managerMod = _deployRolesModifier(config.managerRolesMod.salt);

        // Step 2 – Deploy Avatar Safe; enableModules([execMod]) is called via delegatecall during
        //          setup() so execMod is already a module when the Safe is initialized.
        address avatarSafe = _deploySafe(config.avatarSafe, execMod);

        // Step 3 – Deploy Manager Safe with managerMod enabled the same way.
        address managerSafe = _deploySafe(config.managerSafe, managerMod);

        // Step 4 – Wire exec modifier.
        _wireExecModifier(execMod, avatarSafe, managerSafe, subMod, config.execRolesMod.finalOwner);

        // Step 5 – Wire sub modifier.
        _wireSubModifier(subMod, avatarSafe, execMod, managerSafe);

        // Step 6 – Wire manager modifier.
        _wireManagerModifier(managerMod, managerSafe);

        // Step 7 – Deploy kpkShares proxy.
        address sharesProxy = _deploySharesProxy(config.sharesParams, config.sharesOperator, avatarSafe);

        instance = FundInstance({
            avatarSafe: avatarSafe,
            managerSafe: managerSafe,
            execRolesModifier: execMod,
            subRolesModifier: subMod,
            managerRolesModifier: managerMod,
            kpkSharesProxy: sharesProxy
        });

        uint256 id = instanceCount++;
        instances[id] = instance;
        emit FundDeployed(id, instance);
    }

    // ── Internal: deployment helpers ────────────────────────────────────────────

    /// @dev Deploys a Zodiac Roles Modifier proxy via ModuleProxyFactory.
    ///      Factory is set as owner, avatar, and target so it can configure the modifier
    ///      before handing off ownership.
    function _deployRolesModifier(uint256 salt) internal returns (address mod) {
        bytes memory initParams = abi.encode(address(this), address(this), address(this));
        bytes memory initializer = abi.encodeCall(IRoles.setUp, (initParams));
        mod = IModuleProxyFactory(moduleProxyFactory).deployModule(rolesModifierMastercopy, initializer, salt);
    }

    /// @dev Deploys a Gnosis Safe proxy with `moduleToEnable` pre-enabled via SafeModuleSetup
    ///      delegatecall during setup(), avoiding any post-deployment enablement step.
    function _deploySafe(SafeConfig calldata cfg, address moduleToEnable) internal returns (address safe) {
        address[] memory modules = new address[](1);
        modules[0] = moduleToEnable;

        bytes memory setupData = abi.encodeCall(ISafeModuleSetup.enableModules, (modules));

        bytes memory initializer = abi.encodeCall(
            ISafe.setup,
            (
                cfg.owners,
                cfg.threshold,
                safeModuleSetup,
                setupData,
                safeFallbackHandler,
                address(0),
                0,
                payable(address(0))
            )
        );

        safe = ISafeProxyFactory(safeProxyFactory).createProxyWithNonce(safeSingleton, initializer, cfg.nonce);
    }

    // ── Internal: wiring helpers ────────────────────────────────────────────────

    /// @dev Configures the primary (exec) roles modifier:
    ///      - Fixes avatar and target to the real Avatar Safe.
    ///      - Assigns MANAGER role to managerSafe.
    ///      - Enables subRolesMod as a nested module (factory is still avatar at this point).
    ///      - Sets subRolesMod default role to MANAGER and assigns it MANAGER.
    ///      - Transfers ownership to finalOwner (typically Security Council).
    function _wireExecModifier(
        address mod,
        address avatarSafe,
        address managerSafe,
        address subMod,
        address finalOwner
    ) internal {
        bytes32[] memory roleKeys = new bytes32[](1);
        roleKeys[0] = MANAGER_ROLE;
        bool[] memory memberOf = new bool[](1);
        memberOf[0] = true;

        // Assign MANAGER role to managerSafe.
        IRoles(mod).assignRoles(managerSafe, roleKeys, memberOf);

        // Enable subRolesMod — requires factory == avatar (still true here).
        IRoles(mod).enableModule(subMod);

        // subRolesMod gets MANAGER by default and explicitly.
        IRoles(mod).setDefaultRole(subMod, MANAGER_ROLE);
        IRoles(mod).assignRoles(subMod, roleKeys, memberOf);

        // Fix avatar and target to real Safe, then transfer ownership.
        IRoles(mod).setAvatar(avatarSafe);
        IRoles(mod).setTarget(avatarSafe);
        IRoles(mod).transferOwnership(finalOwner);
    }

    /// @dev Configures the sub roles modifier:
    ///      - Fixes avatar to Avatar Safe, target to execRolesMod (it controls the exec layer).
    ///      - Transfers ownership to managerSafe.
    function _wireSubModifier(address mod, address avatarSafe, address execMod, address managerSafe) internal {
        IRoles(mod).setAvatar(avatarSafe);
        IRoles(mod).setTarget(execMod);
        IRoles(mod).transferOwnership(managerSafe);
    }

    /// @dev Configures the manager roles modifier:
    ///      - Fixes avatar and target to managerSafe (it guards manager-level actions).
    ///      - Transfers ownership to managerSafe.
    function _wireManagerModifier(address mod, address managerSafe) internal {
        IRoles(mod).setAvatar(managerSafe);
        IRoles(mod).setTarget(managerSafe);
        IRoles(mod).transferOwnership(managerSafe);
    }

    /// @dev Deploys a kpkShares UUPS proxy.
    ///      Overrides params.safe with avatarSafe and params.admin with address(this) so the
    ///      factory can grant roles. After role setup the factory renounces DEFAULT_ADMIN_ROLE.
    function _deploySharesProxy(
        KpkShares.ConstructorParams memory params,
        address operator,
        address avatarSafe
    ) internal returns (address proxy) {
        address finalAdmin = params.admin;

        params.safe = avatarSafe;
        params.admin = address(this);

        proxy = address(new ERC1967Proxy(kpkSharesImpl, abi.encodeCall(KpkShares.initialize, (params))));

        KpkShares shares = KpkShares(proxy);
        shares.grantRole(OPERATOR, operator);
        shares.grantRole(DEFAULT_ADMIN_ROLE, finalAdmin);
        shares.renounceRole(DEFAULT_ADMIN_ROLE, address(this));
    }

    // ── Internal: validation ────────────────────────────────────────────────────

    function _validateConfig(FundConfig calldata config) internal pure {
        if (config.avatarSafe.owners.length == 0) revert EmptyOwners();
        if (config.managerSafe.owners.length == 0) revert EmptyOwners();
        if (config.avatarSafe.threshold == 0 || config.avatarSafe.threshold > config.avatarSafe.owners.length) {
            revert InvalidThreshold();
        }
        if (
            config.managerSafe.threshold == 0
                || config.managerSafe.threshold > config.managerSafe.owners.length
        ) revert InvalidThreshold();
        if (config.execRolesMod.finalOwner == address(0)) revert ZeroAddress();
        if (config.sharesOperator == address(0)) revert ZeroAddress();
        if (config.sharesParams.admin == address(0)) revert ZeroAddress();
        if (config.sharesParams.asset == address(0)) revert ZeroAddress();
    }
}
