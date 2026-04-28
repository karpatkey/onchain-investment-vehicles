// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {KpkShares} from "./kpkShares.sol";
import {ISafe} from "./interfaces/ISafe.sol";
import {ISafeProxyFactory} from "./interfaces/ISafeProxyFactory.sol";
import {ISafeModuleSetup} from "./interfaces/ISafeModuleSetup.sol";
import {IModuleProxyFactory} from "./interfaces/IModuleProxyFactory.sol";
import {IRoles} from "./interfaces/IRoles.sol";

interface IKpkSharesDeployer {
    function deploy() external returns (address);
}

/// @notice On-chain factory that deploys a full kpk fund stack in a single transaction:
///         Avatar Safe → Manager Safe → 3 Roles Modifiers → kpkShares UUPS proxy.
///
///         The Avatar Safe is always deployed with a single signer: the Empty contract at
///         EMPTY_CONTRACT, which is deployed at the same address on every chain. This means
///         no EOA or multisig can execute transactions directly on the Avatar Safe — all
///         execution must flow through the Roles Modifiers.
///
///         deployStack() deploys only the operational stack (Safes + Roles Modifiers) and is
///         intended for multichain deployments where the same addresses are needed on every chain.
///         deployFund() additionally deploys the kpkShares proxy, grants infinite asset approvals
///         from the Avatar Safe to the shares proxy, and is mainnet-only.
///
///         A single salt in StackConfig drives all five CREATE2 deployments, guaranteeing
///         identical addresses across chains when the factory is deployed at the same address
///         and its constructor arguments are identical.
contract KpkSharesFactory is Ownable {
    // ── Roles ─────────────────────────────────────────────────────────────────

    bytes32 private constant OPERATOR = keccak256("OPERATOR");
    bytes32 private constant DEFAULT_ADMIN_ROLE = 0x00;
    // forge-lint: disable-next-line(unsafe-typecast)
    bytes32 private constant MANAGER_ROLE = bytes32("MANAGER");

    /// @notice Empty contract deployed at the same address on all chains via CREATE2.
    ///         Used as the sole signer of every Avatar Safe.
    address public constant EMPTY_CONTRACT = 0xA4703438f8cc4fc2C2503a7e43935Da16BA74652;

    /// @notice Gnosis Safe linked-list sentinel for the modules mapping.
    address private constant SENTINEL_MODULES = address(0x1);

    // ── Infrastructure addresses (constructor arguments, owner-updatable) ──────

    address public safeProxyFactory;
    address public safeSingleton;
    /// @notice Safe utility contract delegatecalled during Safe setup() to enable modules.
    address public safeModuleSetup;
    address public safeFallbackHandler;
    address public moduleProxyFactory;
    address public rolesModifierMastercopy;
    /// @notice Deploys a fresh KpkShares implementation per fund.
    ///         Lives in a separate contract so its creation bytecode is not embedded in this
    ///         factory's runtime (which would exceed EIP-170's 24 576-byte limit).
    address public kpkSharesDeployer;

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
    ///         The Avatar Safe is always deployed with EMPTY_CONTRACT as sole signer; no SafeConfig
    ///         is needed for it. A single salt drives all five CREATE2 deployments.
    struct StackConfig {
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

    /// @notice Configuration for an additional asset beyond the base asset.
    struct AssetConfig {
        address asset;
        bool canDeposit;
        bool canRedeem;
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
        /// @notice Additional assets to enable on the shares proxy beyond the base asset.
        ///         The factory temporarily holds OPERATOR to register these, then revokes it.
        AssetConfig[] additionalAssets;
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
    event KpkSharesDeployerUpdated(address indexed newAddress);

    // ── Errors ─────────────────────────────────────────────────────────────────

    error ZeroAddress();
    error EmptyOwners();
    error InvalidThreshold();

    // ── Constructor ────────────────────────────────────────────────────────────

    constructor(
        address _owner,
        address _safeProxyFactory,
        address _safeSingleton,
        address _safeModuleSetup,
        address _safeFallbackHandler,
        address _moduleProxyFactory,
        address _rolesModifierMastercopy,
        address _kpkSharesDeployer
    ) Ownable(_owner) {
        if (
            _safeProxyFactory == address(0) || _safeSingleton == address(0) || _safeModuleSetup == address(0)
                || _safeFallbackHandler == address(0) || _moduleProxyFactory == address(0)
                || _rolesModifierMastercopy == address(0) || _kpkSharesDeployer == address(0)
        ) revert ZeroAddress();

        safeProxyFactory = _safeProxyFactory;
        safeSingleton = _safeSingleton;
        safeModuleSetup = _safeModuleSetup;
        safeFallbackHandler = _safeFallbackHandler;
        moduleProxyFactory = _moduleProxyFactory;
        rolesModifierMastercopy = _rolesModifierMastercopy;
        kpkSharesDeployer = _kpkSharesDeployer;
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

    function setKpkSharesDeployer(address _kpkSharesDeployer) external onlyOwner {
        if (_kpkSharesDeployer == address(0)) revert ZeroAddress();
        kpkSharesDeployer = _kpkSharesDeployer;
        emit KpkSharesDeployerUpdated(_kpkSharesDeployer);
    }

    // ── Main entry points ───────────────────────────────────────────────────────

    /// @notice Deploy only the operational stack: Avatar Safe, Manager Safe, and three Roles Modifiers.
    ///         The Avatar Safe is deployed with EMPTY_CONTRACT as its sole signer.
    ///         Intended for multichain deployments — the same salt on the same factory produces
    ///         identical addresses on every chain.
    function deployStack(StackConfig calldata config) external onlyOwner returns (StackInstance memory instance) {
        _validateStackConfig(config);

        instance = _deployAndWireStack(config, false);

        uint256 id = stackCount++;
        stacks[id] = instance;
        emit StackDeployed(id, instance);
    }

    /// @notice Deploy a full fund stack: operational stack + kpkShares UUPS proxy.
    ///         Also grants infinite allowance from the Avatar Safe to the shares proxy for every
    ///         configured asset. Typically called on mainnet only; use deployStack() on sidechains.
    /// @dev Deployment order:
    ///      1. Deploy 3 roles modifiers (factory as temp owner/avatar/target).
    ///      2. Deploy Avatar Safe (EMPTY_CONTRACT signer; execRolesMod + factory pre-enabled as modules).
    ///      3. Deploy Manager Safe with managerRolesMod pre-enabled as module.
    ///      4. Wire execRolesMod: fix avatar/target, assign roles, enable subRolesMod, transfer ownership.
    ///      5. Wire subRolesMod: fix avatar/target, transfer ownership to managerSafe.
    ///      6. Wire managerRolesMod: fix avatar/target, transfer ownership to managerSafe.
    ///      7. Deploy kpkShares implementation + proxy, enable additional assets, grant roles, factory renounces.
    ///      8. Grant infinite approval from Avatar Safe to shares proxy for all assets.
    ///      9. Remove factory as module from Avatar Safe.
    function deployFund(FundConfig calldata config) external onlyOwner returns (FundInstance memory instance) {
        _validateFundConfig(config);

        // Enable factory as an extra module on the Avatar Safe so it can grant approvals below.
        StackInstance memory stack = _deployAndWireStack(config.stack, true);

        (address sharesImpl, address sharesProxy) =
            _deploySharesProxy(config.sharesParams, config.sharesOperator, stack.avatarSafe, config.additionalAssets);

        // Grant infinite allowance from Avatar Safe to shares proxy for all assets.
        _grantApprovals(stack.avatarSafe, sharesProxy, config.sharesParams.asset, config.additionalAssets);

        // Remove factory as module from Avatar Safe — it is at the front of the list (SENTINEL → factory → execMod).
        ISafe(stack.avatarSafe)
            .execTransactionFromModule(
                stack.avatarSafe, 0, abi.encodeCall(ISafe.disableModule, (SENTINEL_MODULES, address(this))), 0
            );

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
    ///      When includeFactoryAsAvatarModule is true, the factory is enabled as an additional
    ///      module on the Avatar Safe so it can perform post-deployment actions (approvals)
    ///      before removing itself.
    function _deployAndWireStack(StackConfig calldata config, bool includeFactoryAsAvatarModule)
        internal
        returns (StackInstance memory inst)
    {
        (uint256 execSalt, uint256 subSalt, uint256 mgrSalt, uint256 avatarNonce, uint256 mgrNonce) =
            _deriveSalts(config.salt);

        // Step 1 – Deploy all three roles modifiers with factory as temp owner/avatar/target.
        address execMod = _deployRolesModifier(execSalt);
        address subMod = _deployRolesModifier(subSalt);
        address managerMod = _deployRolesModifier(mgrSalt);

        // Step 2 – Deploy Avatar Safe with EMPTY_CONTRACT as sole signer.
        //          Modules enabled during setup(): always execMod, optionally the factory.
        //          If factory is enabled, it is inserted at the front: SENTINEL → factory → execMod.
        address avatarSafe;
        {
            address[] memory avatarOwners = new address[](1);
            avatarOwners[0] = EMPTY_CONTRACT;

            address[] memory avatarModules;
            if (includeFactoryAsAvatarModule) {
                avatarModules = new address[](2);
                avatarModules[0] = execMod;
                avatarModules[1] = address(this);
            } else {
                avatarModules = new address[](1);
                avatarModules[0] = execMod;
            }
            avatarSafe = _deploySafe(avatarOwners, 1, avatarModules, avatarNonce);
        }

        // Step 3 – Deploy Manager Safe with managerMod enabled.
        address[] memory managerOwners = config.managerSafe.owners;
        address[] memory managerModules = new address[](1);
        managerModules[0] = managerMod;
        address managerSafe = _deploySafe(managerOwners, config.managerSafe.threshold, managerModules, mgrNonce);

        // Steps 4-6 – Wire all three modifiers.
        _wireExecModifier(execMod, avatarSafe, managerSafe, subMod, config.execRolesMod.finalOwner);
        _wireSubModifier(subMod, avatarSafe, execMod, managerSafe);
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

    /// @dev Deploys a Gnosis Safe proxy with the given modules pre-enabled via SafeModuleSetup
    ///      delegatecall during setup(), avoiding any post-deployment enablement step.
    ///      Modules are enabled in order; each new module is inserted at the front of the list.
    function _deploySafe(address[] memory owners, uint256 threshold, address[] memory modulesToEnable, uint256 nonce)
        internal
        returns (address safe)
    {
        bytes memory setupData = abi.encodeCall(ISafeModuleSetup.enableModules, (modulesToEnable));

        bytes memory initializer = abi.encodeCall(
            ISafe.setup,
            (owners, threshold, safeModuleSetup, setupData, safeFallbackHandler, address(0), 0, payable(address(0)))
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

        IRoles(mod).assignRoles(managerSafe, roleKeys, memberOf);
        IRoles(mod).enableModule(subMod);
        IRoles(mod).setDefaultRole(subMod, MANAGER_ROLE);
        IRoles(mod).assignRoles(subMod, roleKeys, memberOf);
        IRoles(mod).setAvatar(avatarSafe);
        IRoles(mod).setTarget(avatarSafe);
        IRoles(mod).transferOwnership(finalOwner);
    }

    /// @dev Configures the sub roles modifier:
    ///      - Fixes avatar to Avatar Safe, target to execRolesMod.
    ///      - Transfers ownership to managerSafe.
    function _wireSubModifier(address mod, address avatarSafe, address execMod, address managerSafe) internal {
        IRoles(mod).setAvatar(avatarSafe);
        IRoles(mod).setTarget(execMod);
        IRoles(mod).transferOwnership(managerSafe);
    }

    /// @dev Configures the manager roles modifier:
    ///      - Fixes avatar and target to managerSafe.
    ///      - Transfers ownership to managerSafe.
    function _wireManagerModifier(address mod, address managerSafe) internal {
        IRoles(mod).setAvatar(managerSafe);
        IRoles(mod).setTarget(managerSafe);
        IRoles(mod).transferOwnership(managerSafe);
    }

    /// @dev Deploys a fresh KpkShares implementation via kpkSharesDeployer (isolated per fund)
    ///      and a UUPS proxy pointing to it.
    ///      Temporarily holds OPERATOR to register additional assets, then revokes it.
    function _deploySharesProxy(
        KpkShares.ConstructorParams memory params,
        address operator,
        address avatarSafe,
        AssetConfig[] calldata additionalAssets
    ) internal returns (address impl, address proxy) {
        impl = IKpkSharesDeployer(kpkSharesDeployer).deploy();
        address finalAdmin = params.admin;
        params.safe = avatarSafe;
        params.admin = address(this);

        proxy = address(new ERC1967Proxy(impl, abi.encodeCall(KpkShares.initialize, (params))));

        KpkShares shares = KpkShares(proxy);

        if (additionalAssets.length > 0) {
            shares.grantRole(OPERATOR, address(this));
            for (uint256 i = 0; i < additionalAssets.length; i++) {
                shares.updateAsset(
                    additionalAssets[i].asset, false, additionalAssets[i].canDeposit, additionalAssets[i].canRedeem
                );
            }
            shares.revokeRole(OPERATOR, address(this));
        }

        shares.grantRole(OPERATOR, operator);
        shares.grantRole(DEFAULT_ADMIN_ROLE, finalAdmin);
        shares.renounceRole(DEFAULT_ADMIN_ROLE, address(this));
    }

    /// @dev Grants infinite allowance from the Avatar Safe to the shares proxy for every asset
    ///      that has canRedeem enabled (the shares proxy pulls tokens from the Safe on redemptions).
    ///      The base asset always has canRedeem = true.
    function _grantApprovals(
        address avatarSafe,
        address sharesProxy,
        address baseAsset,
        AssetConfig[] calldata additionalAssets
    ) internal {
        _execApprove(avatarSafe, baseAsset, sharesProxy);
        for (uint256 i = 0; i < additionalAssets.length; i++) {
            if (additionalAssets[i].canRedeem) {
                _execApprove(avatarSafe, additionalAssets[i].asset, sharesProxy);
            }
        }
    }

    /// @dev Instructs the Avatar Safe (via execTransactionFromModule) to approve `spender`
    ///      for the maximum possible amount of `asset`.
    function _execApprove(address avatarSafe, address asset, address spender) internal {
        ISafe(avatarSafe)
            .execTransactionFromModule(asset, 0, abi.encodeCall(IERC20.approve, (spender, type(uint256).max)), 0);
    }

    // ── Internal: validation ────────────────────────────────────────────────────

    function _validateStackConfig(StackConfig calldata config) internal pure {
        if (config.managerSafe.owners.length == 0) revert EmptyOwners();
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
        for (uint256 i = 0; i < config.additionalAssets.length; i++) {
            if (config.additionalAssets[i].asset == address(0)) revert ZeroAddress();
        }
    }
}
