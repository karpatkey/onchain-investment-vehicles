// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {KpkShares} from "./kpkShares.sol";
import {ISafe} from "./interfaces/ISafe.sol";
import {ISafeProxyFactory} from "./interfaces/ISafeProxyFactory.sol";
import {ISafeModuleSetup} from "./interfaces/ISafeModuleSetup.sol";
import {IModuleProxyFactory} from "./interfaces/IModuleProxyFactory.sol";
import {IRoles} from "./interfaces/IRoles.sol";

/// @notice Minimal interface for KpkSharesDeployer.
/// @dev    Kept as a local interface so importing KpkSharesDeployer.sol (which imports KpkShares)
///         does not embed KpkShares creation bytecode into this contract's runtime.
interface IKpkSharesDeployer {
    /// @notice Deploys a fresh KpkShares implementation and returns its address.
    function deploy() external returns (address);
}

/// @title  KpkOivFactory
/// @author KPK
/// @notice On-chain factory that atomically deploys a full kpk fund stack:
///         Avatar Safe → Manager Safe → 3 Zodiac Roles Modifiers → KpkShares UUPS proxy.
///
///         The Avatar Safe is always deployed with a single signer — the Empty contract at
///         EMPTY_CONTRACT — which is deployed at the same address on every chain via CREATE2.
///         This makes it impossible to execute transactions directly on the Avatar Safe;
///         all execution must flow through the Roles Modifiers.
///
///         Two entry points are provided:
///         - `deployStack` deploys only the five-contract operational stack (two Safes + three
///           Roles Modifiers) and is intended for multichain deployments where the same addresses
///           must exist on every chain.
///         - `deployOiv` additionally deploys a KpkShares UUPS proxy, grants infinite asset
///           allowances from the Avatar Safe to the shares proxy, and wires the Manager Safe as
///           the shares operator. Typically called on mainnet only.
///
///         Both deployment entry points are permissionless — any caller may invoke them.
///         Only the infrastructure setter functions are restricted to the factory owner.
///
///         A single `salt` in `StackConfig` drives all five CREATE2 deployments, guaranteeing
///         identical contract addresses across chains when the factory is deployed at the same
///         address with the same constructor arguments AND called by the same `msg.sender`.
///         The caller's address is mixed into the salt derivation to prevent salt-squat
///         front-running of deterministic deployment addresses.
///
///         Trust assumptions:
///         - The factory `owner` controls all infrastructure setters with immediate effect (no
///           timelock). The owner SHOULD be a TimelockController or governance multisig — never
///           an EOA — because a compromised owner can swap `kpkSharesDeployer`,
///           `rolesModifierMastercopy`, or `safeSingleton` to backdoor every future deployment.
///         - For `deployOiv`, the caller controls `config.managerSafe.owners`. The deployed
///           Manager Safe receives ownership of both the sub and manager Roles Modifiers, so
///           `managerSafe.owners` MUST be trusted at the same operational level as
///           `config.admin`. The exec Roles Modifier (owned by `admin`) remains the
///           authoritative gatekeeper of Avatar Safe execution.
contract KpkOivFactory is Ownable, ReentrancyGuard {
    // ── Role keys ─────────────────────────────────────────────────────────────

    /// @dev keccak256("OPERATOR") — role key used by KpkShares to gate process/asset functions.
    bytes32 private constant OPERATOR = keccak256("OPERATOR");

    /// @dev bytes32(0) — OpenZeppelin AccessControl default admin role.
    bytes32 private constant DEFAULT_ADMIN_ROLE = 0x00;

    /// @dev bytes32("MANAGER") — role key assigned on the exec Roles Modifier to the Manager Safe
    ///      and the sub Roles Modifier, permitting them to route transactions to the Avatar Safe.
    // forge-lint: disable-next-line(unsafe-typecast)
    bytes32 private constant MANAGER_ROLE = bytes32("MANAGER");

    // ── Constants ─────────────────────────────────────────────────────────────

    /// @notice Address of the Empty contract, deployed at the same address on every chain via
    ///         CREATE2. Used as the sole signer of every Avatar Safe so that no EOA or multisig
    ///         can execute transactions directly — all execution must go through the Roles Modifiers.
    address public constant EMPTY_CONTRACT = 0xA4703438f8cc4fc2C2503a7e43935Da16BA74652;

    /// @dev Head sentinel of the Gnosis Safe module linked-list. The list is ordered from most
    ///      recently enabled to oldest: SENTINEL → newest → … → oldest → SENTINEL.
    address private constant SENTINEL_MODULES = address(0x1);

    // ── Infrastructure addresses ───────────────────────────────────────────────

    /// @notice Gnosis Safe v1.4.1 proxy factory. Deploys Safe proxies via CREATE2.
    address public safeProxyFactory;

    /// @notice Gnosis Safe v1.4.1 singleton (implementation). All Safe proxies delegate to this.
    address public safeSingleton;

    /// @notice Gnosis SafeModuleSetup utility contract. Delegatecalled during Safe `setup()` to
    ///         pre-enable modules at deployment time, avoiding a separate post-deployment call.
    address public safeModuleSetup;

    /// @notice Fallback handler set on every Safe deployed by this factory.
    address public safeFallbackHandler;

    /// @notice Zodiac ModuleProxyFactory. Deploys EIP-1167 minimal proxies for Zodiac modules
    ///         via CREATE2.
    address public moduleProxyFactory;

    /// @notice Zodiac Roles Modifier v2 mastercopy. All Roles Modifier proxies delegate to this.
    address public rolesModifierMastercopy;

    /// @notice Deploys a fresh KpkShares implementation contract per fund.
    ///         Isolated in its own contract so that KpkShares creation bytecode is not embedded
    ///         in this factory's runtime, which would exceed EIP-170's 24 576-byte limit.
    address public kpkSharesDeployer;

    // ── Structs ────────────────────────────────────────────────────────────────

    /// @notice Signer configuration for a Gnosis Safe.
    struct SafeConfig {
        /// @notice Addresses that are owners (signers) of the Safe. Must be non-empty.
        address[] owners;
        /// @notice Minimum number of owner signatures required to execute a transaction.
        ///         Must be > 0 and <= owners.length.
        uint256 threshold;
    }

    /// @notice Ownership configuration for a Zodiac Roles Modifier.
    struct RolesModifierConfig {
        /// @notice Address that receives ownership of the modifier after wiring is complete.
        ///         Ignored for `subRolesMod` and `managerRolesMod` — those always transfer
        ///         ownership to the deployed Manager Safe.
        address finalOwner;
    }

    /// @notice Full configuration for the five-contract operational stack.
    ///         The Avatar Safe is always deployed with EMPTY_CONTRACT as its sole signer;
    ///         no SafeConfig is needed for it.
    struct StackConfig {
        /// @notice Signer configuration for the Manager Safe.
        SafeConfig managerSafe;
        /// @notice Configuration for the exec Roles Modifier — the primary execution layer.
        ///         Enabled as a module on the Avatar Safe; its owner is `finalOwner`.
        RolesModifierConfig execRolesMod;
        /// @notice Configuration for the sub Roles Modifier — nested inside the exec modifier.
        ///         Enabled as a module on the exec Roles Modifier; ownership transfers to
        ///         Manager Safe regardless of `finalOwner`.
        RolesModifierConfig subRolesMod;
        /// @notice Configuration for the manager Roles Modifier — guards Manager Safe actions.
        ///         Enabled as a module on the Manager Safe; ownership transfers to Manager Safe
        ///         regardless of `finalOwner`.
        RolesModifierConfig managerRolesMod;
        /// @notice Base salt that deterministically controls all five deployment addresses.
        ///         Hashed with a component index (0–4) to produce independent per-contract
        ///         CREATE2 salts/nonces. The same salt on the same factory yields identical
        ///         addresses on every chain.
        uint256 salt;
    }

    /// @notice Enables an ERC-20 asset on the KpkShares proxy beyond the base deposit asset.
    struct AssetConfig {
        /// @notice ERC-20 token address. Must not be zero.
        address asset;
        /// @notice Whether this asset may be used for subscription deposits.
        bool canDeposit;
        /// @notice Whether this asset may be used for redemption payouts.
        ///         If true, the Avatar Safe also grants the shares proxy infinite allowance
        ///         for this asset.
        bool canRedeem;
    }

    /// @notice Full configuration for a fund deployment (stack + KpkShares proxy).
    struct OivConfig {
        /// @notice Signer configuration for the Manager Safe.
        ///         SECURITY: `managerSafe.owners` MUST be trusted at the same operational level
        ///         as `admin`. The deployed Manager Safe receives ownership of both the sub
        ///         Roles Modifier and the manager Roles Modifier (see `_wireSubModifier` /
        ///         `_wireManagerModifier`), so a hostile Manager Safe can re-wire those two
        ///         modifiers' avatar/target/enabled-modules — disrupting fund operations and
        ///         potentially diverting sub-modifier-routed traffic away from the exec
        ///         modifier. The exec modifier (owned by `admin`) remains the authoritative
        ///         gatekeeper of Avatar Safe execution, so direct fund drainage requires
        ///         exec-modifier compromise — but `managerSafe.owners` cannot be treated as
        ///         purely operational signers.
        SafeConfig managerSafe;
        /// @notice Base salt that deterministically controls all five deployment addresses.
        ///         The same salt on the same factory yields identical addresses on every chain.
        uint256 salt;
        /// @notice Address that receives ownership of the exec Roles Modifier and
        ///         `DEFAULT_ADMIN_ROLE` on the KpkShares proxy. Must not be zero.
        address admin;
        /// @notice KpkShares initialization parameters.
        ///         `sharesParams.safe` is overridden with the deployed Avatar Safe address.
        ///         `sharesParams.admin` is ignored — the top-level `admin` field is used instead.
        KpkShares.ConstructorParams sharesParams;
        /// @notice Additional assets to register on the KpkShares proxy beyond the base asset.
        ///         The factory temporarily holds OPERATOR to call `updateAsset`, then revokes it.
        AssetConfig[] additionalAssets;
    }

    /// @notice Addresses of the five contracts deployed by `deployStack`.
    struct StackInstance {
        /// @notice Avatar Safe — holds fund assets; execution via Roles Modifiers only.
        address avatarSafe;
        /// @notice Manager Safe — operational multisig used by fund managers.
        address managerSafe;
        /// @notice Exec Roles Modifier — primary layer; module on Avatar Safe.
        address execRolesModifier;
        /// @notice Sub Roles Modifier — nested inside exec modifier; routes calls through it.
        address subRolesModifier;
        /// @notice Manager Roles Modifier — guards Manager Safe's own actions.
        address managerRolesModifier;
    }

    /// @notice Addresses of all seven contracts deployed by `deployOiv`.
    struct OivInstance {
        /// @notice Avatar Safe — holds fund assets; execution via Roles Modifiers only.
        address avatarSafe;
        /// @notice Manager Safe — operational multisig; also holds OPERATOR on KpkShares.
        address managerSafe;
        /// @notice Exec Roles Modifier — primary layer; module on Avatar Safe.
        address execRolesModifier;
        /// @notice Sub Roles Modifier — nested inside exec modifier; routes calls through it.
        address subRolesModifier;
        /// @notice Manager Roles Modifier — guards Manager Safe's own actions.
        address managerRolesModifier;
        /// @notice KpkShares implementation deployed exclusively for this fund.
        ///         Each fund receives its own implementation so upgrades are isolated.
        address kpkSharesImpl;
        /// @notice KpkShares ERC-1967 UUPS proxy — the fund's shares token.
        address kpkSharesProxy;
    }

    // ── State ──────────────────────────────────────────────────────────────────

    /// @notice Number of operational stacks deployed via `deployStack`.
    uint256 public stackCount;

    /// @notice Stack instances indexed by their deployment order (0-based).
    mapping(uint256 => StackInstance) public stacks;

    /// @notice Number of full fund instances deployed via `deployOiv`.
    uint256 public instanceCount;

    /// @notice Fund instances indexed by their deployment order (0-based).
    mapping(uint256 => OivInstance) public instances;

    // ── Events ─────────────────────────────────────────────────────────────────

    /// @notice Emitted when `deployStack` successfully deploys an operational stack.
    /// @param stackId   Zero-based index of this stack in the `stacks` mapping.
    /// @param instance  Addresses of all five deployed contracts.
    event StackDeployed(uint256 indexed stackId, StackInstance instance);

    /// @notice Emitted when `deployOiv` successfully deploys a full fund.
    /// @param instanceId  Zero-based index of this fund in the `instances` mapping.
    /// @param instance    Addresses of all seven deployed contracts.
    event OivDeployed(uint256 indexed instanceId, OivInstance instance);

    /// @notice Emitted when the owner updates the Safe proxy factory address.
    event SafeProxyFactoryUpdated(address indexed newAddress);

    /// @notice Emitted when the owner updates the Safe singleton address.
    event SafeSingletonUpdated(address indexed newAddress);

    /// @notice Emitted when the owner updates the Safe module setup address.
    event SafeModuleSetupUpdated(address indexed newAddress);

    /// @notice Emitted when the owner updates the Safe fallback handler address.
    event SafeFallbackHandlerUpdated(address indexed newAddress);

    /// @notice Emitted when the owner updates the Zodiac module proxy factory address.
    event ModuleProxyFactoryUpdated(address indexed newAddress);

    /// @notice Emitted when the owner updates the Zodiac Roles Modifier mastercopy address.
    event RolesModifierMastercopyUpdated(address indexed newAddress);

    /// @notice Emitted when the owner updates the KpkShares deployer address.
    event KpkSharesDeployerUpdated(address indexed newAddress);

    // ── Errors ─────────────────────────────────────────────────────────────────

    /// @notice Thrown when a required address argument is `address(0)`.
    error ZeroAddress();

    /// @notice Thrown when `SafeConfig.owners` is empty.
    error EmptyOwners();

    /// @notice Thrown when `SafeConfig.threshold` is zero or exceeds the owners count.
    error InvalidThreshold();

    /// @notice Thrown when `OivConfig.additionalAssets` contains a duplicate entry, or an
    ///         entry equal to `OivConfig.sharesParams.asset`.
    error DuplicateAsset();

    /// @notice Thrown when `SafeConfig.owners` contains a duplicate entry.
    error DuplicateOwner();

    /// @notice Thrown when a required `OivConfig.sharesParams` field is unset
    ///         (`feeReceiver`, `subscriptionRequestTtl`, or `redemptionRequestTtl`).
    error InvalidSharesParams();

    /// @notice Thrown when `EMPTY_CONTRACT` has no deployed bytecode on the current chain.
    ///         The Avatar Safe would otherwise be initialised with a bare-EOA owner, breaking
    ///         the Roles-Modifier-only execution invariant.
    error EmptyContractMissing();

    // ── Constructor ────────────────────────────────────────────────────────────

    /// @notice Deploys the factory and sets all infrastructure addresses.
    /// @dev    All seven infrastructure addresses are validated to be non-zero. They can be
    ///         updated post-deployment by the owner via the corresponding setter functions.
    /// @param _owner                   Address that will own this factory and may call
    ///                                 the infrastructure setters.
    /// @param _safeProxyFactory        Gnosis Safe v1.4.1 proxy factory.
    /// @param _safeSingleton           Gnosis Safe v1.4.1 singleton.
    /// @param _safeModuleSetup         Gnosis SafeModuleSetup utility contract.
    /// @param _safeFallbackHandler     Fallback handler applied to every deployed Safe.
    /// @param _moduleProxyFactory      Zodiac ModuleProxyFactory.
    /// @param _rolesModifierMastercopy Zodiac Roles Modifier v2 mastercopy.
    /// @param _kpkSharesDeployer       KpkSharesDeployer contract address.
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
    //
    // SECURITY: All setters take effect immediately with no timelock. A malicious or
    //           compromised owner can swap `kpkSharesDeployer`, `rolesModifierMastercopy`,
    //           `safeSingleton`, or `safeModuleSetup` to backdoor every future `deployOiv` /
    //           `deployStack` call. Past deployments are unaffected (each fund references its
    //           own already-deployed implementation), but the blast radius for FUTURE
    //           deployments is unbounded. The factory `owner` MUST therefore be a
    //           TimelockController or governance multisig — never an EOA — and any value
    //           change SHOULD go through a public proposal/timelock cycle.

    /// @notice Updates the Gnosis Safe proxy factory address.
    /// @param _safeProxyFactory New address. Must not be zero.
    function setSafeProxyFactory(address _safeProxyFactory) external onlyOwner {
        if (_safeProxyFactory == address(0)) revert ZeroAddress();
        safeProxyFactory = _safeProxyFactory;
        emit SafeProxyFactoryUpdated(_safeProxyFactory);
    }

    /// @notice Updates the Gnosis Safe singleton address.
    /// @param _safeSingleton New address. Must not be zero.
    function setSafeSingleton(address _safeSingleton) external onlyOwner {
        if (_safeSingleton == address(0)) revert ZeroAddress();
        safeSingleton = _safeSingleton;
        emit SafeSingletonUpdated(_safeSingleton);
    }

    /// @notice Updates the Gnosis SafeModuleSetup address.
    /// @param _safeModuleSetup New address. Must not be zero.
    function setSafeModuleSetup(address _safeModuleSetup) external onlyOwner {
        if (_safeModuleSetup == address(0)) revert ZeroAddress();
        safeModuleSetup = _safeModuleSetup;
        emit SafeModuleSetupUpdated(_safeModuleSetup);
    }

    /// @notice Updates the Safe fallback handler address.
    /// @param _safeFallbackHandler New address. Must not be zero.
    function setSafeFallbackHandler(address _safeFallbackHandler) external onlyOwner {
        if (_safeFallbackHandler == address(0)) revert ZeroAddress();
        safeFallbackHandler = _safeFallbackHandler;
        emit SafeFallbackHandlerUpdated(_safeFallbackHandler);
    }

    /// @notice Updates the Zodiac ModuleProxyFactory address.
    /// @param _moduleProxyFactory New address. Must not be zero.
    function setModuleProxyFactory(address _moduleProxyFactory) external onlyOwner {
        if (_moduleProxyFactory == address(0)) revert ZeroAddress();
        moduleProxyFactory = _moduleProxyFactory;
        emit ModuleProxyFactoryUpdated(_moduleProxyFactory);
    }

    /// @notice Updates the Zodiac Roles Modifier mastercopy address.
    /// @param _rolesModifierMastercopy New address. Must not be zero.
    function setRolesModifierMastercopy(address _rolesModifierMastercopy) external onlyOwner {
        if (_rolesModifierMastercopy == address(0)) revert ZeroAddress();
        rolesModifierMastercopy = _rolesModifierMastercopy;
        emit RolesModifierMastercopyUpdated(_rolesModifierMastercopy);
    }

    /// @notice Updates the KpkSharesDeployer address.
    /// @param _kpkSharesDeployer New address. Must not be zero.
    function setKpkSharesDeployer(address _kpkSharesDeployer) external onlyOwner {
        if (_kpkSharesDeployer == address(0)) revert ZeroAddress();
        kpkSharesDeployer = _kpkSharesDeployer;
        emit KpkSharesDeployerUpdated(_kpkSharesDeployer);
    }

    // ── Main entry points ───────────────────────────────────────────────────────

    /// @notice Deploys the five-contract operational stack: Avatar Safe, Manager Safe, and three
    ///         Zodiac Roles Modifiers, fully wired and ownership-transferred.
    ///         Intended for multichain deployments — the same `config.salt` on the same factory
    ///         (same constructor arguments, same address) produces identical addresses on every
    ///         EVM-compatible chain.
    /// @dev    Permissionless — any caller may deploy a stack.
    ///         Reverts if `config` fails validation (see `_validateStackConfig`).
    ///         The returned `StackInstance` is also stored in `stacks[stackCount - 1]`.
    /// @param  config   Stack deployment parameters.
    /// @return instance Addresses of the five deployed contracts.
    function deployStack(StackConfig calldata config) external nonReentrant returns (StackInstance memory instance) {
        _validateStackConfig(config);

        // Reserve the registry ID before any external calls (CEI) — defends against any
        // future callback path that might re-enter the factory and shift indices.
        uint256 id = stackCount++;

        instance = _deployAndWireStack(config, false);

        stacks[id] = instance;
        emit StackDeployed(id, instance);
    }

    /// @notice Deploys a complete fund: operational stack + KpkShares UUPS proxy.
    ///         In addition to the stack, this function:
    ///         - Deploys a fresh KpkShares implementation (isolated upgrade surface per fund).
    ///         - Deploys an ERC-1967 proxy and initializes it.
    ///         - Registers any additional assets on the shares proxy.
    ///         - Grants `type(uint256).max` allowance from the Avatar Safe to the shares proxy
    ///           for the base asset and every additional asset with `canRedeem = true`.
    ///         - Wires the Manager Safe as the OPERATOR on the shares proxy.
    ///         - Removes itself as a module from the Avatar Safe before returning.
    ///         Typically called on mainnet only; use `deployStack` for sidechain deployments.
    /// @dev    Permissionless — any caller may deploy a fund.
    ///         The factory is temporarily enabled as an additional module on the Avatar Safe so
    ///         it can call `execTransactionFromModule` for the approve transactions. It removes
    ///         itself (SENTINEL → factory → execMod) before returning.
    ///         Reverts if `config` fails validation (see `_validateOivConfig`).
    ///         The returned `OivInstance` is also stored in `instances[instanceCount - 1]`.
    /// @param  config   Fund deployment parameters. `config.admin` is used as both the exec
    ///                  Roles Modifier owner and the `DEFAULT_ADMIN_ROLE` holder on KpkShares.
    /// @return instance Addresses of the seven deployed contracts.
    function deployOiv(OivConfig calldata config) external nonReentrant returns (OivInstance memory instance) {
        _validateOivConfig(config);

        // Reserve the registry ID before any external calls (CEI). Combined with `nonReentrant`,
        // this makes ID assignment immune to attacker-controlled ERC-20 callbacks that fire
        // during `KpkShares.updateAsset` / `Avatar.execTransactionFromModule(approve)`.
        uint256 id = instanceCount++;

        StackConfig memory stackConfig = StackConfig({
            managerSafe: config.managerSafe,
            execRolesMod: RolesModifierConfig({finalOwner: config.admin}),
            subRolesMod: RolesModifierConfig({finalOwner: address(0)}),
            managerRolesMod: RolesModifierConfig({finalOwner: address(0)}),
            salt: config.salt
        });

        // Enable factory as an extra module on the Avatar Safe so it can grant approvals below.
        StackInstance memory stack = _deployAndWireStack(stackConfig, true);

        (address sharesImpl, address sharesProxy) = _deploySharesProxy(
            config.sharesParams, stack.managerSafe, stack.avatarSafe, config.admin, config.additionalAssets
        );

        // Grant infinite allowance from Avatar Safe to shares proxy for all assets.
        _grantApprovals(stack.avatarSafe, sharesProxy, config.sharesParams.asset, config.additionalAssets);

        // Remove factory as module from Avatar Safe. Under standard Gnosis SafeModuleSetup
        // semantics (reverse-order insertion) the factory is at the head of the module list
        // (SENTINEL → factory → execMod), so SENTINEL is the correct `prevModule`.
        bool moduleDisabled = ISafe(stack.avatarSafe)
            .execTransactionFromModule(
                stack.avatarSafe, 0, abi.encodeCall(ISafe.disableModule, (SENTINEL_MODULES, address(this))), 0
            );
        require(moduleDisabled, "KpkOivFactory: failed to disable module");
        // Defensive post-condition: independent of module-list ordering / SafeModuleSetup
        // implementation. Catches any failure mode where the disableModule call returned
        // success without actually removing the factory.
        require(
            !ISafe(stack.avatarSafe).isModuleEnabled(address(this)), "KpkOivFactory: factory still enabled as module"
        );

        instance = OivInstance({
            avatarSafe: stack.avatarSafe,
            managerSafe: stack.managerSafe,
            execRolesModifier: stack.execRolesModifier,
            subRolesModifier: stack.subRolesModifier,
            managerRolesModifier: stack.managerRolesModifier,
            kpkSharesImpl: sharesImpl,
            kpkSharesProxy: sharesProxy
        });

        instances[id] = instance;
        emit OivDeployed(id, instance);
    }

    // ── Read-only: address prediction ───────────────────────────────────────────

    /// @notice Predicts the five-contract operational stack addresses that `deployStack(config)`
    ///         would produce when called by `caller`.
    /// @dev    All five contracts use CREATE2; their addresses are fully determined by
    ///         (factory address, infrastructure addresses, `caller`, `config.salt`, and the
    ///         Manager Safe's owners/threshold). The prediction does NOT validate `config` —
    ///         pass a config that would actually succeed (see `_validateStackConfig`).
    ///         Note that `predictStackAddresses` and `predictOivAddresses` produce DIFFERENT
    ///         Avatar Safe addresses for the same salt: `deployOiv` enables the factory as a
    ///         second module on the Avatar Safe during setup, which changes the setup() data
    ///         and therefore the CREATE2 salt.
    /// @param  config  Stack deployment parameters.
    /// @param  caller  Address that would call `deployStack`. Pass `msg.sender` if you intend
    ///                 to be the deployer.
    /// @return inst    Predicted addresses of the five contracts.
    function predictStackAddresses(StackConfig calldata config, address caller)
        external
        view
        returns (StackInstance memory inst)
    {
        return _predictStack(config.managerSafe.owners, config.managerSafe.threshold, config.salt, caller, false);
    }

    /// @notice Predicts the deterministic addresses produced by `deployOiv(config)` when called
    ///         by `caller`. The KpkShares implementation and proxy fields are returned as
    ///         `address(0)` because they are NOT deterministic — both are deployed via plain
    ///         CREATE (the implementation by `KpkSharesDeployer` and the proxy by this factory),
    ///         so their addresses depend on the deployer's nonce at the time of execution.
    /// @dev    Inherits the caveats of `predictStackAddresses`. The Avatar Safe address differs
    ///         from `predictStackAddresses` because `deployOiv` enables the factory as an
    ///         additional Avatar Safe module during setup (see `_deployAndWireStack`).
    /// @param  config  Fund deployment parameters.
    /// @param  caller  Address that would call `deployOiv`.
    /// @return inst    Predicted addresses; `kpkSharesImpl` and `kpkSharesProxy` are zero.
    function predictOivAddresses(OivConfig calldata config, address caller)
        external
        view
        returns (OivInstance memory inst)
    {
        StackInstance memory stack =
            _predictStack(config.managerSafe.owners, config.managerSafe.threshold, config.salt, caller, true);
        inst = OivInstance({
            avatarSafe: stack.avatarSafe,
            managerSafe: stack.managerSafe,
            execRolesModifier: stack.execRolesModifier,
            subRolesModifier: stack.subRolesModifier,
            managerRolesModifier: stack.managerRolesModifier,
            kpkSharesImpl: address(0),
            kpkSharesProxy: address(0)
        });
    }

    /// @dev Predicts the operational stack addresses. Mirrors the deployment paths in
    ///      `_deployAndWireStack` exactly — any change to the deployment flow that affects
    ///      addresses MUST be mirrored here.
    function _predictStack(
        address[] memory managerOwners,
        uint256 managerThreshold,
        uint256 baseSalt,
        address caller,
        bool includeFactoryAsAvatarModule
    ) internal view returns (StackInstance memory inst) {
        (uint256 execSalt, uint256 subSalt, uint256 mgrSalt, uint256 avatarNonce, uint256 mgrNonce) =
            _deriveSalts(baseSalt, caller);

        inst.execRolesModifier = _predictRolesModifier(execSalt);
        inst.subRolesModifier = _predictRolesModifier(subSalt);
        inst.managerRolesModifier = _predictRolesModifier(mgrSalt);

        address[] memory avatarOwners = new address[](1);
        avatarOwners[0] = EMPTY_CONTRACT;

        address[] memory avatarModules;
        if (includeFactoryAsAvatarModule) {
            avatarModules = new address[](2);
            avatarModules[0] = inst.execRolesModifier;
            avatarModules[1] = address(this);
        } else {
            avatarModules = new address[](1);
            avatarModules[0] = inst.execRolesModifier;
        }
        inst.avatarSafe = _predictSafe(avatarOwners, 1, avatarModules, avatarNonce);

        address[] memory managerModules = new address[](1);
        managerModules[0] = inst.managerRolesModifier;
        inst.managerSafe = _predictSafe(managerOwners, managerThreshold, managerModules, mgrNonce);
    }

    /// @dev Computes the CREATE2 address of a Roles Modifier proxy. Mirrors exactly the
    ///      initializer used by `_deployRolesModifier` and the EIP-1167 deployment bytecode
    ///      used by Zodiac's `ModuleProxyFactory.deployModule`.
    function _predictRolesModifier(uint256 saltNonce) internal view returns (address) {
        bytes memory initParams = abi.encode(address(this), address(this), address(this));
        bytes memory initializer = abi.encodeCall(IRoles.setUp, (initParams));
        bytes32 salt = keccak256(abi.encodePacked(keccak256(initializer), saltNonce));
        // Zodiac ModuleProxyFactory deployment bytecode: 9-byte init header + 10-byte EIP-1167
        // runtime prefix + 20-byte mastercopy address + 15-byte runtime suffix = 54 bytes.
        bytes memory deployment = abi.encodePacked(
            hex"602d8060093d393df3363d3d373d3d3d363d73", rolesModifierMastercopy, hex"5af43d82803e903d91602b57fd5bf3"
        );
        return _create2Address(moduleProxyFactory, salt, keccak256(deployment));
    }

    /// @dev Computes the CREATE2 address of a Safe proxy. Mirrors the initializer used by
    ///      `_deploySafe` and the deployment bytecode used by `SafeProxyFactory.createProxyWithNonce`
    ///      (proxyCreationCode || abi.encode(singleton)).
    function _predictSafe(address[] memory owners, uint256 threshold, address[] memory modulesToEnable, uint256 nonce)
        internal
        view
        returns (address)
    {
        bytes memory setupData = abi.encodeCall(ISafeModuleSetup.enableModules, (modulesToEnable));
        bytes memory initializer = abi.encodeCall(
            ISafe.setup,
            (owners, threshold, safeModuleSetup, setupData, safeFallbackHandler, address(0), 0, payable(address(0)))
        );
        bytes32 salt = keccak256(abi.encodePacked(keccak256(initializer), nonce));
        bytes memory deployment =
            abi.encodePacked(ISafeProxyFactory(safeProxyFactory).proxyCreationCode(), uint256(uint160(safeSingleton)));
        return _create2Address(safeProxyFactory, salt, keccak256(deployment));
    }

    /// @dev Standard CREATE2 address derivation: keccak256(0xff || deployer || salt || codeHash).
    function _create2Address(address deployer, bytes32 salt, bytes32 codeHash) internal pure returns (address) {
        return address(uint160(uint256(keccak256(abi.encodePacked(bytes1(0xff), deployer, salt, codeHash)))));
    }

    // ── Internal: stack deployment ──────────────────────────────────────────────

    /// @dev Deploys and fully wires the five-contract operational stack.
    ///      When `includeFactoryAsAvatarModule` is true, the factory is pre-enabled as an
    ///      additional module on the Avatar Safe (inserted at the front of the module list:
    ///      SENTINEL → factory → execMod) so the caller can perform post-deployment actions
    ///      such as granting token approvals before removing itself.
    /// @param config                    Stack deployment parameters.
    /// @param includeFactoryAsAvatarModule Whether to include the factory as a temporary module.
    /// @return inst                     Addresses of the five deployed contracts.
    function _deployAndWireStack(StackConfig memory config, bool includeFactoryAsAvatarModule)
        internal
        returns (StackInstance memory inst)
    {
        // Defense against `EMPTY_CONTRACT` not being deployed on the current chain. If absent,
        // the Avatar Safe's sole owner would be a bare-EOA address, breaking the
        // Roles-Modifier-only execution invariant the entire fund stack depends on.
        if (EMPTY_CONTRACT.code.length == 0) revert EmptyContractMissing();

        (uint256 execSalt, uint256 subSalt, uint256 mgrSalt, uint256 avatarNonce, uint256 mgrNonce) =
            _deriveSalts(config.salt, msg.sender);

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

    /// @dev Derives five independent CREATE2 salts/nonces from a single base salt by hashing
    ///      the caller, the base salt, and a fixed component index (0–4). Mixing the caller's
    ///      address binds deployment addresses to a single deployer, preventing salt-squat
    ///      front-running while preserving cross-chain determinism for any single deployer.
    ///      Index mapping: 0 = execRolesModifier, 1 = subRolesModifier, 2 = managerRolesModifier,
    ///      3 = Avatar Safe nonce, 4 = Manager Safe nonce.
    /// @param baseSalt   The user-supplied base salt from `StackConfig.salt`.
    /// @param caller     The address calling `deployStack` / `deployOiv`. The same caller using
    ///                   the same `baseSalt` on a same-address factory yields identical addresses
    ///                   on every EVM-compatible chain.
    /// @return execSalt   CREATE2 salt for the exec Roles Modifier.
    /// @return subSalt    CREATE2 salt for the sub Roles Modifier.
    /// @return mgrSalt    CREATE2 salt for the manager Roles Modifier.
    /// @return avatarNonce Safe nonce for the Avatar Safe.
    /// @return mgrNonce    Safe nonce for the Manager Safe.
    function _deriveSalts(uint256 baseSalt, address caller)
        internal
        pure
        returns (uint256 execSalt, uint256 subSalt, uint256 mgrSalt, uint256 avatarNonce, uint256 mgrNonce)
    {
        execSalt = uint256(keccak256(abi.encode(caller, baseSalt, uint8(0))));
        subSalt = uint256(keccak256(abi.encode(caller, baseSalt, uint8(1))));
        mgrSalt = uint256(keccak256(abi.encode(caller, baseSalt, uint8(2))));
        avatarNonce = uint256(keccak256(abi.encode(caller, baseSalt, uint8(3))));
        mgrNonce = uint256(keccak256(abi.encode(caller, baseSalt, uint8(4))));
    }

    // ── Internal: deployment helpers ────────────────────────────────────────────

    /// @dev Deploys a Zodiac Roles Modifier EIP-1167 proxy via the ModuleProxyFactory using
    ///      CREATE2. The factory is set as the initial owner, avatar, and target so it can
    ///      fully configure the modifier before transferring ownership.
    /// @param salt  CREATE2 salt for this modifier (derived from the base salt).
    /// @return mod  Address of the deployed Roles Modifier proxy.
    function _deployRolesModifier(uint256 salt) internal returns (address mod) {
        bytes memory initParams = abi.encode(address(this), address(this), address(this));
        bytes memory initializer = abi.encodeCall(IRoles.setUp, (initParams));
        mod = IModuleProxyFactory(moduleProxyFactory).deployModule(rolesModifierMastercopy, initializer, salt);
    }

    /// @dev Deploys a Gnosis Safe proxy via the SafeProxyFactory using CREATE2 (createProxyWithNonce).
    ///      All `modulesToEnable` are pre-enabled atomically during `setup()` via a delegatecall
    ///      to SafeModuleSetup, avoiding any post-deployment module enablement step.
    ///      The Safe module list after setup is ordered newest-first:
    ///      SENTINEL → modulesToEnable[last] → … → modulesToEnable[0] → SENTINEL.
    /// @param owners          Signer addresses for this Safe.
    /// @param threshold       Required signature count.
    /// @param modulesToEnable Modules to enable during `setup()`. Enabled in array order; each is
    ///                        inserted at the front of the linked list.
    /// @param nonce           CREATE2 nonce (salt) for address determinism.
    /// @return safe           Address of the deployed Safe proxy.
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

    /// @dev Wires the exec (primary) Roles Modifier. After this call:
    ///      - avatar = avatarSafe, target = avatarSafe.
    ///      - Manager Safe has the MANAGER role.
    ///      - Sub Roles Modifier is enabled as a nested module; its default role is MANAGER
    ///        and it also holds the MANAGER role, so calls it routes inherit the role automatically.
    ///      - Ownership is transferred to `finalOwner` (typically the Security Council).
    /// @param mod         Exec Roles Modifier address (factory is still owner/avatar at call time).
    /// @param avatarSafe  Avatar Safe address — becomes avatar and target.
    /// @param managerSafe Manager Safe address — receives the MANAGER role.
    /// @param subMod      Sub Roles Modifier address — enabled as a nested module.
    /// @param finalOwner  Address that receives ownership (must not be zero).
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

    /// @dev Wires the sub Roles Modifier. After this call:
    ///      - avatar = avatarSafe, target = execRolesModifier (calls are forwarded to the exec
    ///        layer, not directly to the Avatar Safe).
    ///      - Ownership is transferred to Manager Safe.
    /// @param mod         Sub Roles Modifier address.
    /// @param avatarSafe  Avatar Safe address — becomes avatar.
    /// @param execMod     Exec Roles Modifier address — becomes target.
    /// @param managerSafe Manager Safe address — receives ownership.
    function _wireSubModifier(address mod, address avatarSafe, address execMod, address managerSafe) internal {
        IRoles(mod).setAvatar(avatarSafe);
        IRoles(mod).setTarget(execMod);
        IRoles(mod).transferOwnership(managerSafe);
    }

    /// @dev Wires the manager Roles Modifier. After this call:
    ///      - avatar = managerSafe, target = managerSafe (guards actions originating from the
    ///        Manager Safe itself).
    ///      - Ownership is transferred to Manager Safe.
    /// @param mod         Manager Roles Modifier address.
    /// @param managerSafe Manager Safe address — becomes avatar, target, and owner.
    function _wireManagerModifier(address mod, address managerSafe) internal {
        IRoles(mod).setAvatar(managerSafe);
        IRoles(mod).setTarget(managerSafe);
        IRoles(mod).transferOwnership(managerSafe);
    }

    /// @dev Deploys a fresh KpkShares implementation via `kpkSharesDeployer` (ensuring each fund
    ///      has an isolated upgrade surface) and an ERC-1967 UUPS proxy pointing to it.
    ///      Role setup sequence:
    ///      1. Factory temporarily holds DEFAULT_ADMIN_ROLE (set during `initialize`).
    ///      2. If additional assets are provided, factory also temporarily holds OPERATOR to call
    ///         `updateAsset`, then revokes it.
    ///      3. OPERATOR is granted to `operator` (Manager Safe).
    ///      4. DEFAULT_ADMIN_ROLE is granted to `finalAdmin` and the factory renounces it.
    /// @param params           KpkShares initialization parameters (`safe` and `admin` are
    ///                         overridden by the factory before calling `initialize`).
    /// @param operator         Address that receives the OPERATOR role (Manager Safe).
    /// @param avatarSafe       Avatar Safe address — overrides `params.safe`.
    /// @param finalAdmin       Address that receives DEFAULT_ADMIN_ROLE — overrides `params.admin`.
    /// @param additionalAssets Additional assets to register via `updateAsset`.
    /// @return impl  Address of the newly deployed KpkShares implementation.
    /// @return proxy Address of the ERC-1967 proxy (the fund's shares token).
    function _deploySharesProxy(
        KpkShares.ConstructorParams memory params,
        address operator,
        address avatarSafe,
        address finalAdmin,
        AssetConfig[] calldata additionalAssets
    ) internal returns (address impl, address proxy) {
        impl = IKpkSharesDeployer(kpkSharesDeployer).deploy();
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
        // Defensive: under OZ AccessControl v5, `renounceRole` cannot fail when the caller passes
        // its own address, so this assert holds in all valid execution paths. Kept as a guard
        // against a future OZ version change or an upgraded shares implementation.
        assert(!shares.hasRole(DEFAULT_ADMIN_ROLE, address(this)));
    }

    /// @dev Instructs the Avatar Safe (via `execTransactionFromModule`) to approve `sharesProxy`
    ///      for `type(uint256).max` of the base asset and every additional asset with
    ///      `canRedeem = true`. These approvals are required because the shares proxy pulls
    ///      tokens from the Avatar Safe when processing redemptions.
    ///      The factory must be an enabled module on `avatarSafe` when this is called.
    /// @param avatarSafe       Avatar Safe that issues the approvals.
    /// @param sharesProxy      Spender address (the KpkShares proxy).
    /// @param baseAsset        Base deposit/redemption asset — always approved.
    /// @param additionalAssets Additional assets; only those with `canRedeem = true` are approved.
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

    /// @dev Issues a single `ERC20.approve(spender, type(uint256).max)` call from `avatarSafe`
    ///      by routing it through `execTransactionFromModule`. The factory must be an enabled
    ///      module on `avatarSafe`.
    /// @param avatarSafe Address of the Safe executing the approval.
    /// @param asset      ERC-20 token to approve.
    /// @param spender    Address to grant the unlimited allowance to.
    function _execApprove(address avatarSafe, address asset, address spender) internal {
        bool success = ISafe(avatarSafe)
            .execTransactionFromModule(asset, 0, abi.encodeCall(IERC20.approve, (spender, type(uint256).max)), 0);
        require(success, "KpkOivFactory: approve module call failed");
        require(
            IERC20(asset).allowance(avatarSafe, spender) == type(uint256).max,
            "KpkOivFactory: approve did not set allowance"
        );
    }

    // ── Internal: validation ────────────────────────────────────────────────────

    /// @dev Validates a `StackConfig` before deployment.
    ///      Reverts with `EmptyOwners`      if `managerSafe.owners` is empty.
    ///      Reverts with `InvalidThreshold` if `threshold` is 0 or exceeds owner count.
    ///      Reverts with `ZeroAddress`      if any owner or `execRolesMod.finalOwner` is zero.
    ///      Reverts with `DuplicateOwner`   if `managerSafe.owners` contains duplicates.
    function _validateStackConfig(StackConfig calldata config) internal pure {
        _validateManagerOwners(config.managerSafe);
        if (config.execRolesMod.finalOwner == address(0)) revert ZeroAddress();
    }

    /// @dev Validates an `OivConfig` before deployment.
    ///      Reverts with `EmptyOwners`      if `managerSafe.owners` is empty.
    ///      Reverts with `InvalidThreshold` if `threshold` is 0 or exceeds owner count.
    ///      Reverts with `DuplicateOwner`   if `managerSafe.owners` contains duplicates.
    ///      Reverts with `ZeroAddress`      if `admin`, any owner, `sharesParams.asset`,
    ///                                      or any `additionalAssets[i].asset` is zero.
    ///      Reverts with `DuplicateAsset`     if `additionalAssets` contains duplicates or any
    ///                                        entry equals `sharesParams.asset` (the latter would
    ///                                        silently clear the base asset's `isFeeModuleAsset`
    ///                                        flag, disabling performance fees).
    ///      Reverts with `InvalidSharesParams` if `sharesParams.feeReceiver`,
    ///                                        `sharesParams.subscriptionRequestTtl`, or
    ///                                        `sharesParams.redemptionRequestTtl` is unset.
    function _validateOivConfig(OivConfig calldata config) internal pure {
        _validateManagerOwners(config.managerSafe);
        if (config.admin == address(0)) revert ZeroAddress();
        if (config.sharesParams.asset == address(0)) revert ZeroAddress();
        // Mirror KpkShares._validateInitializationParams so misconfiguration fails fast at the
        // factory level instead of deep inside the proxy initializer.
        if (
            config.sharesParams.feeReceiver == address(0) || config.sharesParams.subscriptionRequestTtl == 0
                || config.sharesParams.redemptionRequestTtl == 0
        ) revert InvalidSharesParams();

        uint256 len = config.additionalAssets.length;
        for (uint256 i = 0; i < len; i++) {
            address asset = config.additionalAssets[i].asset;
            if (asset == address(0)) revert ZeroAddress();
            // Reject if the entry matches the base deposit asset — registering the base asset
            // again via `updateAsset(_, isFeeModuleAsset=false, …)` would clear the flag set
            // during `initialize`, silently disabling performance fees for the fund's lifetime.
            if (asset == config.sharesParams.asset) revert DuplicateAsset();
            // Reject duplicates within `additionalAssets`. Without this, a duplicate entry
            // with `canRedeem=true` causes a second `approve(spender, max)` call which reverts
            // on USDT-like tokens (non-zero → non-zero allowance), DoS'ing the entire deployment.
            for (uint256 j = i + 1; j < len; j++) {
                if (asset == config.additionalAssets[j].asset) revert DuplicateAsset();
            }
        }
    }

    /// @dev Validates a Manager Safe owners array: non-empty, threshold within bounds, every
    ///      owner non-zero, no duplicates. Mirrors Gnosis Safe v1.4.1 `setup()` invariants but
    ///      surfaces descriptive factory-level errors instead of opaque `GS20x` reverts from
    ///      deep inside `createProxyWithNonce`.
    function _validateManagerOwners(SafeConfig calldata managerSafe) internal pure {
        uint256 len = managerSafe.owners.length;
        if (len == 0) revert EmptyOwners();
        if (managerSafe.threshold == 0 || managerSafe.threshold > len) revert InvalidThreshold();
        for (uint256 i = 0; i < len; i++) {
            address owner = managerSafe.owners[i];
            if (owner == address(0)) revert ZeroAddress();
            for (uint256 j = i + 1; j < len; j++) {
                if (owner == managerSafe.owners[j]) revert DuplicateOwner();
            }
        }
    }
}
