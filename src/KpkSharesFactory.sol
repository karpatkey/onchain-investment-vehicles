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
///
///         deployStack() deploys only the operational stack (Safes + Roles Modifiers) and is
///         intended for multichain deployments where the same addresses are needed on every chain.
///         deployFund() additionally deploys the kpkShares proxy and is mainnet-only.
///
///         A single salt in StackConfig drives all five CREATE2 deployments, guaranteeing
///         identical addresses across chains when the factory is deployed at the same address
///         and the infrastructure addresses are identical.
///
///         Infrastructure addresses are initialised to the canonical Safe v1.4.1 + Zodiac
///         values and can be updated by the owner to support new versions or other chains.
contract KpkSharesFactory is Ownable {
    // ── Roles ─────────────────────────────────────────────────────────────────

    bytes32 private constant OPERATOR = keccak256("OPERATOR");
    bytes32 private constant DEFAULT_ADMIN_ROLE = 0x00;
    // forge-lint: disable-next-line(unsafe-typecast)
    bytes32 private constant MANAGER_ROLE = bytes32("MANAGER");

    // ── Default infrastructure addresses (Safe v1.4.1 + Zodiac, most EVM chains) ──

    address private constant _DEFAULT_SAFE_PROXY_FACTORY = 0xa6B71E26C5e0845f74c812102Ca7114b6a896AB2;
    address private constant _DEFAULT_SAFE_SINGLETON = 0x41675C099F32341bf84BFc5382aF534df5C7461a;
    address private constant _DEFAULT_SAFE_MODULE_SETUP = 0x2dd68b007B46fBe91B9A7c3EDa5A7a1063cB5b47;
    address private constant _DEFAULT_SAFE_FALLBACK_HANDLER = 0xfd0732Dc9E303f09fCEf3a7388Ad10A83459Ec99;
    address private constant _DEFAULT_MODULE_PROXY_FACTORY = 0x000000000000aDdB49795b0f9bA5BC298cDda236;
    address private constant _DEFAULT_ROLES_MODIFIER_MASTERCOPY = 0x9646fDAD06d3e24444381f44362a3B0eB343D337;

    // ── Infrastructure addresses (owner-updatable) ─────────────────────────────

    address public safeProxyFactory;
    address public safeSingleton;
    /// @notice Safe utility contract delegatecalled during Safe setup() to enable modules.
    address public safeModuleSetup;
    address public safeFallbackHandler;
    address public moduleProxyFactory;
    address public rolesModifierMastercopy;

    // ── Structs ────────────────────────────────────────────────────────────────

    struct SafeConfig {
        address[] owners;
        uint256 threshold;
    }

    struct RolesModifierConfig {
        /// @notice Address that receives ownership after wiring is complete.
        ///         Ignored for subRolesMod and managerRolesMod — those always transfer to managerSafe.
        address finalOwner;
    }

    /// @notice Configuration for the operational stack (Safes + Roles Modifiers).
    ///         A single salt drives all five CREATE2 deployments; the same salt on the same
    ///         factory produces identical addresses on every chain.
    struct StackConfig {
        SafeConfig avatarSafe;
        SafeConfig managerSafe;
        /// @notice Primary modifier — enabled as module on Avatar Safe.
        RolesModifierConfig execRolesMod;
        /// @notice Sub-modifier — enabled as module inside execRolesMod, targets execRolesMod.
        RolesModifierConfig subRolesMod;
        /// @notice Manager modifier — enabled as module on Manager Safe, guards manager actions.
        RolesModifierConfig managerRolesMod;
        /// @notice Single salt that is hashed with a component index to derive per-contract
        ///         CREATE2 salts/nonces, ensuring all five addresses are determined by one value.
        uint256 salt;
    }

    struct FundConfig {
        StackConfig stack;
        /// @notice kpkShares initialization params. sharesParams.safe is overridden with the
        ///         deployed avatarSafe address. sharesParams.admin is overridden with address(this)
        ///         during initialization so the factory can set up roles, then the real admin is
        ///         granted and the factory renounces.
        KpkShares.ConstructorParams sharesParams;
        /// @notice Address that receives the OPERATOR role on the kpkShares proxy.
        address sharesOperator;
    }

    struct StackInstance {
        address avatarSafe;
        address managerSafe;
        address execRolesModifier;
        address subRolesModifier;
        address managerRolesModifier;
    }

    struct FundInstance {
        address avatarSafe;
        address managerSafe;
        address execRolesModifier;
        address subRolesModifier;
        address managerRolesModifier;
        address kpkSharesImpl;
        address kpkSharesProxy;
    }

    // ── State ──────────────────────────────────────────────────────────────────

    uint256 public stackCount;
    mapping(uint256 => StackInstance) public stacks;

    uint256 public instanceCount;
    mapping(uint256 => FundInstance) public instances;

    // ── Events ─────────────────────────────────────────────────────────────────

    event StackDeployed(uint256 indexed stackId, StackInstance instance);
    event FundDeployed(uint256 indexed instanceId, FundInstance instance);

    event SafeProxyFactoryUpdated(address indexed newAddress);
    event SafeSingletonUpdated(address indexed newAddress);
    event SafeModuleSetupUpdated(address indexed newAddress);
    event SafeFallbackHandlerUpdated(address indexed newAddress);
    event ModuleProxyFactoryUpdated(address indexed newAddress);
    event RolesModifierMastercopyUpdated(address indexed newAddress);

    // ── Errors ─────────────────────────────────────────────────────────────────

    error ZeroAddress();
    error EmptyOwners();
    error InvalidThreshold();

    // ── Constructor ────────────────────────────────────────────────────────────

    constructor(address _owner) Ownable(_owner) {
        safeProxyFactory = _DEFAULT_SAFE_PROXY_FACTORY;
        safeSingleton = _DEFAULT_SAFE_SINGLETON;
        safeModuleSetup = _DEFAULT_SAFE_MODULE_SETUP;
        safeFallbackHandler = _DEFAULT_SAFE_FALLBACK_HANDLER;
        moduleProxyFactory = _DEFAULT_MODULE_PROXY_FACTORY;
        rolesModifierMastercopy = _DEFAULT_ROLES_MODIFIER_MASTERCOPY;
    }

    // ── Infrastructure setters ─────────────────────────────────────────────────

    function setSafeProxyFactory(address _safeProxyFactory) external onlyOwner {
        if (_safeProxyFactory == address(0)) revert ZeroAddress();
        safeProxyFactory = _safeProxyFactory;
        emit SafeProxyFactoryUpdated(_safeProxyFactory);
    }

    function setSafeSingleton(address _safeSingleton) external onlyOwner {
        if (_safeSingleton == address(0)) revert ZeroAddress();
        safeSingleton = _safeSingleton;
        emit SafeSingletonUpdated(_safeSingleton);
    }

    function setSafeModuleSetup(address _safeModuleSetup) external onlyOwner {
        if (_safeModuleSetup == address(0)) revert ZeroAddress();
        safeModuleSetup = _safeModuleSetup;
        emit SafeModuleSetupUpdated(_safeModuleSetup);
    }

    function setSafeFallbackHandler(address _safeFallbackHandler) external onlyOwner {
        if (_safeFallbackHandler == address(0)) revert ZeroAddress();
        safeFallbackHandler = _safeFallbackHandler;
        emit SafeFallbackHandlerUpdated(_safeFallbackHandler);
    }

    function setModuleProxyFactory(address _moduleProxyFactory) external onlyOwner {
        if (_moduleProxyFactory == address(0)) revert ZeroAddress();
        moduleProxyFactory = _moduleProxyFactory;
        emit ModuleProxyFactoryUpdated(_moduleProxyFactory);
    }

    function setRolesModifierMastercopy(address _rolesModifierMastercopy) external onlyOwner {
        if (_rolesModifierMastercopy == address(0)) revert ZeroAddress();
        rolesModifierMastercopy = _rolesModifierMastercopy;
        emit RolesModifierMastercopyUpdated(_rolesModifierMastercopy);
    }

    // ── Main entry points ───────────────────────────────────────────────────────

    /// @notice Deploy only the operational stack: Avatar Safe, Manager Safe, and three Roles Modifiers.
    ///         Intended for multichain deployments — the same salt on the same factory produces
    ///         identical addresses on every chain.
    function deployStack(StackConfig calldata config) external onlyOwner returns (StackInstance memory instance) {
        _validateStackConfig(config);

        instance = _deployAndWireStack(config);

        uint256 id = stackCount++;
        stacks[id] = instance;
        emit StackDeployed(id, instance);
    }

    /// @notice Deploy a full fund stack: operational stack + kpkShares UUPS proxy.
    ///         Typically called on mainnet only; use deployStack() on sidechains.
    /// @dev Deployment order:
    ///      1. Deploy 3 roles modifiers (factory as temp owner/avatar/target).
    ///      2. Deploy Avatar Safe with execRolesMod already enabled via setup delegatecall.
    ///      3. Deploy Manager Safe with managerRolesMod already enabled via setup delegatecall.
    ///      4. Wire execRolesMod: fix avatar/target, assign roles, enable subRolesMod, transfer ownership.
    ///      5. Wire subRolesMod: fix avatar/target, transfer ownership to managerSafe.
    ///      6. Wire managerRolesMod: fix avatar/target, transfer ownership to managerSafe.
    ///      7. Deploy kpkShares implementation + proxy, grant roles, factory renounces.
    function deployFund(FundConfig calldata config) external onlyOwner returns (FundInstance memory instance) {
        _validateFundConfig(config);

        StackInstance memory stack = _deployAndWireStack(config.stack);

        (address sharesImpl, address sharesProxy) =
            _deploySharesProxy(config.sharesParams, config.sharesOperator, stack.avatarSafe);

        instance = FundInstance({
            avatarSafe: stack.avatarSafe,
            managerSafe: stack.managerSafe,
            execRolesModifier: stack.execRolesModifier,
            subRolesModifier: stack.subRolesModifier,
            managerRolesModifier: stack.managerRolesModifier,
            kpkSharesImpl: sharesImpl,
            kpkSharesProxy: sharesProxy
        });

        uint256 id = instanceCount++;
        instances[id] = instance;
        emit FundDeployed(id, instance);
    }

    // ── Internal: stack deployment ──────────────────────────────────────────────

    /// @dev Deploys and fully wires the five-contract operational stack.
    ///      Per-component salts/nonces are derived by hashing the base salt with a fixed index,
    ///      so a single value in StackConfig.salt determines all addresses.
    function _deployAndWireStack(StackConfig calldata config) internal returns (StackInstance memory inst) {
        (uint256 execSalt, uint256 subSalt, uint256 mgrSalt, uint256 avatarNonce, uint256 mgrNonce) =
            _deriveSalts(config.salt);

        // Step 1 – Deploy all three roles modifiers with factory as temp owner/avatar/target.
        address execMod = _deployRolesModifier(execSalt);
        address subMod = _deployRolesModifier(subSalt);
        address managerMod = _deployRolesModifier(mgrSalt);

        // Step 2 – Deploy Avatar Safe; enableModules([execMod]) is called via delegatecall during
        //          setup() so execMod is already a module when the Safe is initialized.
        address avatarSafe = _deploySafe(config.avatarSafe, execMod, avatarNonce);

        // Step 3 – Deploy Manager Safe with managerMod enabled the same way.
        address managerSafe = _deploySafe(config.managerSafe, managerMod, mgrNonce);

        // Step 4 – Wire exec modifier.
        _wireExecModifier(execMod, avatarSafe, managerSafe, subMod, config.execRolesMod.finalOwner);

        // Step 5 – Wire sub modifier.
        _wireSubModifier(subMod, avatarSafe, execMod, managerSafe);

        // Step 6 – Wire manager modifier.
        _wireManagerModifier(managerMod, managerSafe);

        inst = StackInstance({
            avatarSafe: avatarSafe,
            managerSafe: managerSafe,
            execRolesModifier: execMod,
            subRolesModifier: subMod,
            managerRolesModifier: managerMod
        });
    }

    /// @dev Derives five independent CREATE2 salts/nonces from a single base salt.
    ///      Indices 0-2 are for the three Roles Modifiers; 3-4 are Safe nonces.
    function _deriveSalts(uint256 baseSalt)
        internal
        pure
        returns (uint256 execSalt, uint256 subSalt, uint256 mgrSalt, uint256 avatarNonce, uint256 mgrNonce)
    {
        execSalt = uint256(keccak256(abi.encode(baseSalt, uint8(0))));
        subSalt = uint256(keccak256(abi.encode(baseSalt, uint8(1))));
        mgrSalt = uint256(keccak256(abi.encode(baseSalt, uint8(2))));
        avatarNonce = uint256(keccak256(abi.encode(baseSalt, uint8(3))));
        mgrNonce = uint256(keccak256(abi.encode(baseSalt, uint8(4))));
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
    function _deploySafe(SafeConfig calldata cfg, address moduleToEnable, uint256 nonce)
        internal
        returns (address safe)
    {
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

        safe = ISafeProxyFactory(safeProxyFactory).createProxyWithNonce(safeSingleton, initializer, nonce);
    }

    // ── Internal: wiring helpers ────────────────────────────────────────────────

    /// @dev Configures the primary (exec) roles modifier:
    ///      - Fixes avatar and target to the real Avatar Safe.
    ///      - Assigns MANAGER role to managerSafe.
    ///      - Enables subRolesMod as a nested module (factory is still avatar at this point).
    ///      - Sets subRolesMod default role to MANAGER and assigns it MANAGER.
    ///      - Transfers ownership to finalOwner (typically Security Council).
    function _wireExecModifier(address mod, address avatarSafe, address managerSafe, address subMod, address finalOwner)
        internal
    {
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

    /// @dev Deploys a fresh KpkShares implementation and a UUPS proxy pointing to it.
    ///      Each fund gets its own implementation so upgrades are isolated per fund.
    ///      Overrides params.safe with avatarSafe and params.admin with address(this) so the
    ///      factory can grant roles. After role setup the factory renounces DEFAULT_ADMIN_ROLE.
    function _deploySharesProxy(KpkShares.ConstructorParams memory params, address operator, address avatarSafe)
        internal
        returns (address impl, address proxy)
    {
        impl = address(new KpkShares());

        address finalAdmin = params.admin;

        params.safe = avatarSafe;
        params.admin = address(this);

        proxy = address(new ERC1967Proxy(impl, abi.encodeCall(KpkShares.initialize, (params))));

        KpkShares shares = KpkShares(proxy);
        shares.grantRole(OPERATOR, operator);
        shares.grantRole(DEFAULT_ADMIN_ROLE, finalAdmin);
        shares.renounceRole(DEFAULT_ADMIN_ROLE, address(this));
    }

    // ── Internal: validation ────────────────────────────────────────────────────

    function _validateStackConfig(StackConfig calldata config) internal pure {
        if (config.avatarSafe.owners.length == 0) revert EmptyOwners();
        if (config.managerSafe.owners.length == 0) revert EmptyOwners();
        if (config.avatarSafe.threshold == 0 || config.avatarSafe.threshold > config.avatarSafe.owners.length) {
            revert InvalidThreshold();
        }
        if (config.managerSafe.threshold == 0 || config.managerSafe.threshold > config.managerSafe.owners.length) {
            revert InvalidThreshold();
        }
        if (config.execRolesMod.finalOwner == address(0)) revert ZeroAddress();
    }

    function _validateFundConfig(FundConfig calldata config) internal pure {
        _validateStackConfig(config.stack);
        if (config.sharesOperator == address(0)) revert ZeroAddress();
        if (config.sharesParams.admin == address(0)) revert ZeroAddress();
        if (config.sharesParams.asset == address(0)) revert ZeroAddress();
    }
}
