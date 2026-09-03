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
import {IKpkTimelockDeployer, TimelockParams} from "./interfaces/IKpkTimelockDeployer.sol";
import {OivInfraConstants} from "./OivInfraConstants.sol";

/// @notice Minimal interface for KpkSharesDeployer.
/// @dev    Kept as a local interface so importing KpkSharesDeployer.sol (which imports KpkShares)
///         does not embed KpkShares creation bytecode into this contract's runtime.
interface IKpkSharesDeployer {
    /// @notice Deploys a fresh KpkShares implementation at the CREATE2 address derived from
    ///         `(deployer, salt, type(KpkShares).creationCode)` and returns its address.
    function deploy(bytes32 salt) external returns (address);

    /// @notice Predicts the address `deploy(salt)` will produce on this chain.
    function predictImpl(bytes32 salt) external view returns (address);
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
///         - `deployStack` deploys the five-contract operational stack (two Safes + three Roles
///           Modifiers). Intended for sidechain deployments paired with `deployOiv` on mainnet.
///         - `deployOiv` deploys the same five-contract stack PLUS a KpkShares UUPS proxy,
///           grants infinite asset allowances from the Avatar Safe to the shares proxy, and
///           wires the Manager Safe as the shares operator. Typically called on mainnet only.
///
///         Cross-flow address invariant: for the same `(caller, salt)`, `deployStack` and
///         `deployOiv` produce IDENTICAL Avatar Safe / Manager Safe / Roles Modifier addresses.
///         The factory is unconditionally enabled as a setup-time Avatar Safe module in both
///         flows (and disabled before each entry point returns) so the Safe `setup()` call
///         is byte-identical across flows. This is the load-bearing property that lets
///         `deployOiv` on mainnet and `deployStack` on every sidechain produce a fund with the
///         same Avatar Safe address everywhere.
///
///         Both deployment entry points are permissionless — any caller may invoke them.
///         Only the infrastructure setter functions are restricted to the factory owner.
///
///         A single `salt` in `StackConfig` drives all five CREATE2 deployments. The caller's
///         address is mixed into the salt derivation, so identical contract addresses across
///         chains require the factory to be deployed at the same address with the same
///         constructor arguments AND called by the same `msg.sender`. Caller mixing prevents
///         salt-squat front-running of deterministic deployment addresses.
///
///         `predictStackAddresses` and `predictOivAddresses` are read-only helpers that return
///         the addresses a deployment with a given `(config, caller)` tuple would produce.
///         By the cross-flow invariant above, both predict functions return the same five
///         operational-stack addresses for the same `(caller, salt)`.
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

    /// @notice `EXTCODEHASH` of the canonical `Empty` runtime. The deploy tooling only ever lands the
    ///         one fixed `Empty` bytecode at `EMPTY_CONTRACT` (caller-independent CREATE2), so its code
    ///         hash is a constant. Deploys assert the occupant matches this rather than merely having
    ///         code: CREATE2 address-binding already makes a hostile substitute infeasible, but this
    ///         fails closed if anything other than the canonical `Empty` ever occupies the address.
    ///         COUPLING: must equal keccak256 of the canonical `Empty` runtime the deploy tooling lands
    ///         (`OivChainDeploy.EMPTY_RUNTIME` / `emptyDeployCalldata` in `ccip-networks.json`). The two
    ///         are cross-checked fork-independently by `test/EmptyCodehashSync.t.sol`, so recompiling
    ///         `Empty` and updating one side but not the other fails CI instead of bricking deploys.
    bytes32 internal constant EXPECTED_EMPTY_CODEHASH =
        0x43e02797734360da7ebc3a304cb0e9d6cbce443548d8095bd757080788e14495;

    /// @dev Head sentinel of the Gnosis Safe module linked-list. The list is ordered from most
    ///      recently enabled to oldest: SENTINEL → newest → … → oldest → SENTINEL.
    address private constant SENTINEL_MODULES = address(0x1);

    /// @notice Gnosis Safe v1.4.1 `MultiSend`, registered for unwrapping on every Roles Modifier
    ///         this factory deploys.
    address public constant MULTI_SEND = OivInfraConstants.MULTI_SEND;

    /// @notice Gnosis Safe v1.4.1 `MultiSendCallOnly`, registered separately because the unwrap
    ///         adapter is keyed on the `(target, selector)` pair.
    address public constant MULTI_SEND_CALLS_ONLY = OivInfraConstants.MULTI_SEND_CALLS_ONLY;

    /// @notice Zodiac `MultiSendUnwrapper` registered against both MultiSend contracts.
    /// @dev    Deliberately a `constant` rather than an owner-settable infrastructure address, in
    ///         the same tier as `EMPTY_CONTRACT`. The unwrapper decides how a batch is split into
    ///         the individual calls that then get permission-checked, so a swapped adapter could
    ///         mis-decompose a batch and slip unchecked calls past every role — a privilege
    ///         escalation on all future funds. It is a canonical CREATE2 address, identical on all
    ///         19 chains, so there is no legitimate reason for it to vary per deployment.
    address public constant MULTISEND_UNWRAPPER = OivInfraConstants.MULTISEND_UNWRAPPER;

    /// @notice `EXTCODEHASH` of the canonical Safe v1.4.1 `MultiSend`.
    /// @dev    WHY A CODEHASH AND NOT A PRESENCE CHECK. Registering an unwrap adapter for
    ///         `(target, selector)` does more than teach the modifier to decompose batches:
    ///         `PermissionChecker._authorize` branches on the adapter lookup BEFORE any clearance
    ///         check, and the adapter branch never reads `role.targets[target]` nor evaluates the
    ///         outer `ExecutionOptions`. Registration is therefore equivalent to granting every
    ///         present and future role an unconditional, un-permission-checked DELEGATECALL to
    ///         `target` — into the Avatar Safe's own storage context. A hostile occupant of the
    ///         address needs only to expose `multiSend(bytes)` to run as the Safe (e.g. call
    ///         `enableModule` on itself) and take the fund over, starting from any role at all.
    ///         The safety of the whole scheme reduces to "the code at these addresses is the code
    ///         we think it is", so it is asserted exactly, not approximated by `code.length != 0`.
    ///         CREATE2 address-binding already makes substitution infeasible on a standard-EVM
    ///         chain; this fails closed on one where it is not (genesis allocation, non-standard
    ///         address derivation) — the factory is built for permissionless rollout to new chains.
    bytes32 internal constant EXPECTED_MULTI_SEND_CODEHASH =
        0x0e4f7fc66550a322d1e7688e181b75e217e662a4f3f4d6a29b22bc61217c4b77;

    /// @notice `EXTCODEHASH` of the canonical Safe v1.4.1 `MultiSendCallOnly`.
    /// @dev    Same rationale as `EXPECTED_MULTI_SEND_CODEHASH` — this address is an equally
    ///         unconditional DELEGATECALL sink once registered.
    bytes32 internal constant EXPECTED_MULTI_SEND_CALLS_ONLY_CODEHASH =
        0xecd5bd14a08c5d2122379900b2f272bdf107a7e92423c10dd5fe3254386c9939;

    /// @notice `EXTCODEHASH` of the canonical Zodiac `MultiSendUnwrapper`.
    /// @dev    A presence check would also have caught the EIP-2470 silent-OOG failure mode
    ///         documented in `OivInfraConstants` (EVM code deposit is all-or-nothing, so that
    ///         mode leaves `code.length == 0`), but it is the weakest available check on the
    ///         dependency that decides how batches are decomposed. Asserted exactly instead.
    bytes32 internal constant EXPECTED_MULTISEND_UNWRAPPER_CODEHASH =
        0x1f6e088be5e6ef9d0fbe0547d3fa9a9e40d823433fd8a4449215b5663209a1eb;

    /// @dev `multiSend(bytes)` — the selector the unwrap adapter is registered against on both
    ///      MultiSend contracts.
    bytes4 private constant MULTI_SEND_SELECTOR = OivInfraConstants.MULTI_SEND_SELECTOR;

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

    /// @notice Deploys a fund's `TimelockController` instances. Isolated in its own contract for the
    ///         same EIP-170 reason as `kpkSharesDeployer`: `TimelockController`'s creation bytecode
    ///         alone is larger than this factory's remaining runtime margin.
    address public timelockDeployer;

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
        /// @notice Timelock that receives ownership of the exec Roles Modifier instead of
        ///         `execRolesMod.finalOwner`.
        ///
        ///         A `minDelay` of zero means no timelock: the modifier is transferred to
        ///         `finalOwner` exactly as before. Any non-zero delay causes the factory to deploy a
        ///         `TimelockController` through `timelockDeployer` and hand it the modifier, leaving
        ///         `finalOwner` unused (it is still validated non-zero, since it is what
        ///         `oivToStackConfig` derives from `admin` and the owner a fund falls back to).
        ///
        ///         Carried in `StackConfig` rather than only in `OivConfig` so `deployStack` and the
        ///         CCIP fan-out configure it identically: the exec Roles Modifier exists on every
        ///         chain a fund lives on, and a fund timelocked on one chain but not the others is
        ///         mixed governance with nothing on-chain to flag it. Because the timelock's address
        ///         derives from the exec modifier's — itself identical across chains — the timelock
        ///         lands at one address everywhere too.
        TimelockParams execTimelock;
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
        /// @notice Timelock that receives ownership of the exec Roles Modifier. Mapped straight
        ///         through to `StackConfig.execTimelock` by `oivToStackConfig`, so mainnet and every
        ///         sidechain agree. Zero `minDelay` means no timelock.
        TimelockParams execTimelock;
        /// @notice Timelock that receives `DEFAULT_ADMIN_ROLE` on the KpkShares proxy **instead of**
        ///         `admin`. Zero `minDelay` means no timelock and `admin` receives the role as before.
        ///
        ///         Deliberately a separate instance from `execTimelock`, and deliberately not sent to
        ///         sidechains: the shares proxy exists only where `deployOiv` runs, and the two
        ///         authorities have different risk cadences — routine policy edits on the exec
        ///         modifier versus a total-control `upgradeToAndCall` on the shares proxy. Separate
        ///         instances let each carry its own delay and canceller set, and stop a frozen one
        ///         from freezing the other.
        ///
        ///         The role is granted to the timelock ALONE. Granting it while `admin` kept the role
        ///         would leave a delay-free bypass of everything the timelock exists to gate.
        TimelockParams sharesTimelock;
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
        /// @notice Timelock owning the exec Roles Modifier, or `address(0)` if none was configured.
        address execTimelock;
    }

    /// @notice Addresses of the contracts deployed by `deployOiv`.
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
        /// @notice Timelock owning the exec Roles Modifier, or `address(0)` if none was configured.
        address execTimelock;
        /// @notice Timelock holding `DEFAULT_ADMIN_ROLE` on the shares proxy, or `address(0)` if
        ///         none was configured (in which case `admin` holds it).
        address sharesTimelock;
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

    /// @notice Number of funds ever added to the curated external-fund registry via `registerFund`.
    ///         Monotonic — IDs are never reused, including across `unregisterFund` (which leaves a
    ///         gap). This is NOT the count of currently-registered funds; to enumerate live entries,
    ///         iterate `[0, registeredFundCount)` and skip slots with a zero `kpkSharesProxy`.
    uint256 public registeredFundCount;

    /// @notice Curated registry of funds NOT deployed by this factory, indexed by registration order
    ///         (0-based). Intentionally separate from `instances` (the trustless, append-only log of
    ///         funds this factory itself deployed): entries here are owner-asserted and removable. A
    ///         removed entry is zeroed; a live entry always has a non-zero `kpkSharesProxy`.
    mapping(uint256 => OivInstance) public registeredFunds;

    /// @notice Whether a fund — keyed by its KpkShares proxy — is currently in the curated registry.
    ///         Prevents duplicate registration and gives O(1) membership lookups.
    mapping(address => bool) public isFundRegistered;

    // ── Events ─────────────────────────────────────────────────────────────────

    /// @notice Emitted when `deployStack` successfully deploys an operational stack.
    /// @param stackId   Zero-based index of this stack in the `stacks` mapping.
    /// @param instance  Addresses of all five deployed contracts.
    event StackDeployed(uint256 indexed stackId, StackInstance instance);

    /// @notice Emitted when `deployOiv` successfully deploys a full fund.
    /// @param instanceId  Zero-based index of this fund in the `instances` mapping.
    /// @param instance    Addresses of all seven deployed contracts.
    event OivDeployed(uint256 indexed instanceId, OivInstance instance);

    /// @notice Emitted when the owner adds an externally-deployed fund to the curated registry.
    /// @param registeredFundId  Zero-based index of this fund in the `registeredFunds` mapping.
    /// @param instance          The seven fund-component addresses, as supplied by the owner.
    /// @param registrar         The owner address that registered the fund.
    event FundRegistered(uint256 indexed registeredFundId, OivInstance instance, address indexed registrar);

    /// @notice Emitted when the owner removes a fund from the curated registry.
    /// @param registeredFundId  Zero-based index removed from the `registeredFunds` mapping.
    /// @param kpkSharesProxy    The removed fund's KpkShares proxy (its registry key).
    event FundUnregistered(uint256 indexed registeredFundId, address indexed kpkSharesProxy);

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

    /// @notice Thrown when `EMPTY_CONTRACT` is not the canonical `Empty` on the current chain —
    ///         either no bytecode, or a different contract squatting the address (checked by
    ///         codehash). The Avatar Safe would otherwise get an owner that is not the always-
    ///         reverting `Empty`, breaking the Roles-Modifier-only execution invariant.
    error EmptyContractMissing();

    /// @notice Thrown when the occupant of `MULTISEND_UNWRAPPER` is not the canonical Zodiac
    ///         `MultiSendUnwrapper` (checked by codehash, so "no bytecode" is covered too).
    ///         Deploying a fund would otherwise register an adapter that cannot decompose a batch,
    ///         leaving every `multiSend` through the Roles Modifiers permanently rejected — the
    ///         exact defect this wiring exists to prevent, and one only discovered in production.
    ///         The unwrapper is deployable permissionlessly at its canonical address on any chain
    ///         (EIP-2470 SingletonFactory, salt 0), so this fails closed rather than silently
    ///         producing a fund that looks correctly wired.
    error MultiSendUnwrapperMissing();

    /// @notice Thrown when the occupant of `MULTI_SEND` or `MULTI_SEND_CALLS_ONLY` is not the
    ///         canonical Safe v1.4.1 contract. Registering an unwrap adapter for an address turns
    ///         it into an unconditional DELEGATECALL sink for every role on the modifier (see
    ///         `EXPECTED_MULTI_SEND_CODEHASH`), so a non-canonical occupant is a fund takeover, and
    ///         a codeless one silently burns role allowances on batches that execute nothing —
    ///         Safe's `Executor.execute` does a bare `delegatecall` with no `extcodesize` guard, so
    ///         it reports success.
    /// @param  multiSendContract The address whose codehash did not match.
    error MultiSendMissing(address multiSendContract);

    /// @notice Thrown when `deployOiv` is called before `setKpkSharesDeployer` has wired the
    ///         deployer post-construction. This is only reachable in the brief window between
    ///         factory deployment and the post-deploy `setKpkSharesDeployer` call (see the
    ///         constructor NatSpec for the deterministic-CREATE2 deployment flow). `deployStack`
    ///         is unaffected — it does not touch `kpkSharesDeployer` and remains callable
    ///         regardless of wiring status.
    error KpkSharesDeployerNotSet();

    /// @notice Thrown when a deployment configures a timelock (non-zero `minDelay`) but
    ///         `timelockDeployer` has not been wired yet.
    error TimelockDeployerNotSet();

    /// @notice Thrown when `registerFund` is given a fund whose KpkShares proxy is already in the
    ///         curated registry.
    error FundAlreadyRegistered();

    /// @notice Thrown when `unregisterFund` targets an ID with no live entry (never registered, or
    ///         already removed).
    error FundNotRegistered();

    // ── Constructor ────────────────────────────────────────────────────────────

    /// @notice Deploys the factory and sets all infrastructure addresses.
    /// @dev    All six Safe/Zodiac infrastructure addresses are validated to be non-zero.
    ///         `_kpkSharesDeployer` may be passed as `address(0)` so the factory's CREATE2
    ///         creation code is independent of the (chicken-and-egg) deployer address; the owner
    ///         must then call `setKpkSharesDeployer` to wire it before `deployOiv` can be
    ///         invoked. Once set, `setKpkSharesDeployer`'s non-zero check prevents resetting it
    ///         back to zero. This is the deterministic-cross-chain deploy pattern used in
    ///         `script/DeployKpkOivFactory.s.sol`. Infrastructure addresses can be updated
    ///         post-deployment by the owner via the corresponding setter functions.
    /// @param _owner                   Address that will own this factory and may call
    ///                                 the infrastructure setters.
    /// @param _safeProxyFactory        Gnosis Safe v1.4.1 proxy factory.
    /// @param _safeSingleton           Gnosis Safe v1.4.1 singleton.
    /// @param _safeModuleSetup         Gnosis SafeModuleSetup utility contract.
    /// @param _safeFallbackHandler     Fallback handler applied to every deployed Safe.
    /// @param _moduleProxyFactory      Zodiac ModuleProxyFactory.
    /// @param _rolesModifierMastercopy Zodiac Roles Modifier v2 mastercopy.
    /// @param _kpkSharesDeployer       KpkSharesDeployer contract address. May be `address(0)`
    ///                                 at construction; must be set via `setKpkSharesDeployer`
    ///                                 before `deployOiv` is callable.
    /// @param _timelockDeployer        KpkTimelockDeployer contract address. May be `address(0)`
    ///                                 at construction for the same chicken-and-egg reason, and is
    ///                                 only required by deployments that actually configure a
    ///                                 timelock — funds with a zero `minDelay` never touch it.
    constructor(
        address _owner,
        address _safeProxyFactory,
        address _safeSingleton,
        address _safeModuleSetup,
        address _safeFallbackHandler,
        address _moduleProxyFactory,
        address _rolesModifierMastercopy,
        address _kpkSharesDeployer,
        address _timelockDeployer
    ) Ownable(_owner) {
        if (
            _safeProxyFactory == address(0) || _safeSingleton == address(0) || _safeModuleSetup == address(0)
                || _safeFallbackHandler == address(0) || _moduleProxyFactory == address(0)
                || _rolesModifierMastercopy == address(0)
        ) revert ZeroAddress();

        safeProxyFactory = _safeProxyFactory;
        safeSingleton = _safeSingleton;
        safeModuleSetup = _safeModuleSetup;
        safeFallbackHandler = _safeFallbackHandler;
        moduleProxyFactory = _moduleProxyFactory;
        rolesModifierMastercopy = _rolesModifierMastercopy;
        kpkSharesDeployer = _kpkSharesDeployer;
        timelockDeployer = _timelockDeployer;
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

    /// @notice Updates the KpkTimelockDeployer address.
    /// @dev    Same blast radius as `setKpkSharesDeployer`: a hostile deployer could hand every
    ///         FUTURE fund a timelock whose proposer and canceller sets it controls. Past
    ///         deployments are unaffected — each fund's timelock is already deployed and
    ///         self-administered.
    /// @param _timelockDeployer New address. Must not be zero.
    function setTimelockDeployer(address _timelockDeployer) external onlyOwner {
        if (_timelockDeployer == address(0)) revert ZeroAddress();
        timelockDeployer = _timelockDeployer;
    }

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
    ///         Intended for sidechain deployments paired with `deployOiv` on mainnet — the same
    ///         `(caller, config.salt)` on the same factory (same constructor arguments, same
    ///         address) produces IDENTICAL Avatar Safe / Manager Safe / Roles Modifier addresses
    ///         across `deployStack` and `deployOiv` on every EVM-compatible chain.
    /// @dev    Permissionless — any caller may deploy a stack.
    ///         The factory is enabled as an Avatar Safe module at setup time (so the setup()
    ///         data is byte-identical with `deployOiv`) and disabled before this function
    ///         returns. The factory is not used in this flow.
    ///         Reverts if `config` fails validation (see `_validateStackConfig`).
    ///         The returned `StackInstance` is also stored in `stacks[stackCount - 1]`.
    /// @param  config   Stack deployment parameters.
    /// @return instance Addresses of the five deployed contracts.
    function deployStack(StackConfig calldata config) external nonReentrant returns (StackInstance memory instance) {
        _validateStackConfig(config);

        // Reserve the registry ID before any external calls (CEI) — defends against any
        // future callback path that might re-enter the factory and shift indices.
        uint256 id = stackCount++;

        instance = _deployAndWireStack(config);

        // The factory was enabled as a setup-time Avatar Safe module to keep the setup() data
        // byte-identical with `deployOiv` (so cross-chain Avatar Safe addresses match). The
        // factory makes no use of the slot in this flow — disable immediately.
        _disableFactoryAsAvatarModule(instance.avatarSafe);

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
    ///         The five operational-stack addresses (Avatar Safe, Manager Safe, three Roles
    ///         Modifiers) are IDENTICAL to those produced by `deployStack` for the same
    ///         `(caller, config.salt)`.
    /// @dev    Permissionless — any caller may deploy a fund.
    ///         The factory is enabled as an additional module on the Avatar Safe at setup
    ///         time so it can call `execTransactionFromModule` for the approve transactions
    ///         and grant token approvals. It removes itself (SENTINEL → factory → execMod)
    ///         before returning.
    ///         Reverts if `config` fails validation (see `_validateOivConfig`).
    ///         The returned `OivInstance` is also stored in `instances[instanceCount - 1]`.
    /// @param  config   Fund deployment parameters. `config.admin` is used as both the exec
    ///                  Roles Modifier owner and the `DEFAULT_ADMIN_ROLE` holder on KpkShares.
    /// @return instance Addresses of the seven deployed contracts.
    function deployOiv(OivConfig calldata config) external nonReentrant returns (OivInstance memory instance) {
        // Guard the brief deploy-time window where the factory is constructed with
        // `kpkSharesDeployer == address(0)` so its CREATE2 address is independent of the deployer
        // (see constructor NatSpec). Once `setKpkSharesDeployer` has wired the deployer the
        // setter's non-zero check prevents this from ever reverting again.
        if (kpkSharesDeployer == address(0)) revert KpkSharesDeployerNotSet();

        _validateOivConfig(config);

        // Reserve the registry ID before any external calls (CEI). Combined with `nonReentrant`,
        // this makes ID assignment immune to attacker-controlled ERC-20 callbacks that fire
        // during `KpkShares.updateAsset` / `Avatar.execTransactionFromModule(approve)`.
        uint256 id = instanceCount++;

        StackConfig memory stackConfig = oivToStackConfig(config);

        // The factory is always enabled as a setup-time Avatar Safe module by `_deployAndWireStack`
        // (see that helper for the cross-chain rationale). It is used here to grant the approvals
        // below before being disabled.
        StackInstance memory stack = _deployAndWireStack(stackConfig);

        (bytes32 implSalt, bytes32 proxySalt) = _deriveSharesSalts(config.salt, msg.sender);
        (address sharesImpl, address sharesProxy, address sharesTimelock) = _deploySharesProxy(
            config.sharesParams,
            stack.managerSafe,
            stack.avatarSafe,
            config.admin,
            config.additionalAssets,
            implSalt,
            proxySalt,
            config.sharesTimelock
        );

        // Grant infinite allowance from Avatar Safe to shares proxy for all assets.
        _grantApprovals(stack.avatarSafe, sharesProxy, config.sharesParams.asset, config.additionalAssets);

        // Remove factory as module from Avatar Safe.
        _disableFactoryAsAvatarModule(stack.avatarSafe);

        instance = OivInstance({
            avatarSafe: stack.avatarSafe,
            managerSafe: stack.managerSafe,
            execRolesModifier: stack.execRolesModifier,
            subRolesModifier: stack.subRolesModifier,
            managerRolesModifier: stack.managerRolesModifier,
            kpkSharesImpl: sharesImpl,
            kpkSharesProxy: sharesProxy,
            execTimelock: stack.execTimelock,
            sharesTimelock: sharesTimelock
        });

        instances[id] = instance;
        emit OivDeployed(id, instance);
    }

    // ── Curated external-fund registry ───────────────────────────────────────────

    /// @notice Adds a fund that was NOT deployed by this factory to a curated, owner-managed registry.
    /// @dev    Owner-only. This registry is intentionally separate from `instances` (the append-only
    ///         log of funds this factory deployed deterministically): entries here are owner-ASSERTED,
    ///         and can be removed via `unregisterFund`. The factory performs no wiring, ownership, or
    ///         approval changes on the supplied fund — registration is purely bookkeeping. All seven
    ///         addresses must be non-zero, and the fund (keyed by `kpkSharesProxy`) must not already
    ///         be registered.
    ///
    ///         SECURITY — every entry is OWNER-ASSERTED and NOT verified on-chain: registration stores
    ///         the supplied addresses as-is, with NO proof they form a genuine, correctly-wired OIV. In
    ///         particular the recorded `avatarSafe` is NOT checked to belong to the recorded
    ///         `kpkSharesProxy`, so a mis-entered or malicious pairing is possible. An on-chain consumer
    ///         that wants a trustless list of funds this factory actually deployed MUST read `instances`
    ///         / `stacks` (the append-only deployment logs), never `registeredFunds`.
    ///         The full `OivInstance` is stored on-chain (not just `kpkSharesProxy`) by design, so an
    ///         on-chain consumer can read a registered fund's seven component addresses directly via the
    ///         `registeredFunds`/`getFund` getter without replaying `FundRegistered` events. The extra
    ///         SSTOREs are paid once per (rare, owner-only) registration.
    /// @param  instance The seven fund-component addresses to record.
    /// @return registeredFundId Zero-based index assigned in the `registeredFunds` mapping.
    function registerFund(OivInstance calldata instance) external onlyOwner returns (uint256 registeredFundId) {
        if (
            instance.avatarSafe == address(0) || instance.managerSafe == address(0)
                || instance.execRolesModifier == address(0) || instance.subRolesModifier == address(0)
                || instance.managerRolesModifier == address(0) || instance.kpkSharesImpl == address(0)
                || instance.kpkSharesProxy == address(0)
        ) revert ZeroAddress();
        if (isFundRegistered[instance.kpkSharesProxy]) revert FundAlreadyRegistered();

        registeredFundId = registeredFundCount++;
        registeredFunds[registeredFundId] = instance;
        isFundRegistered[instance.kpkSharesProxy] = true;

        emit FundRegistered(registeredFundId, instance, msg.sender);
    }

    /// @notice Removes a previously `registerFund`-ed fund from the curated registry.
    /// @dev    Owner-only. Only funds added via `registerFund` live in `registeredFunds`, so
    ///         factory-deployed funds in `instances` are never affected — the deployment log stays
    ///         append-only and tamper-evident. The slot is zeroed (IDs are never reused, leaving a
    ///         gap) and the membership flag cleared.
    /// @param  registeredFundId The `registeredFunds` index to remove (from the `FundRegistered` event).
    function unregisterFund(uint256 registeredFundId) external onlyOwner {
        // Only the proxy is needed (membership key + event); read just that slot, not the whole struct.
        address kpkSharesProxy = registeredFunds[registeredFundId].kpkSharesProxy;
        if (kpkSharesProxy == address(0)) revert FundNotRegistered();

        delete isFundRegistered[kpkSharesProxy];
        delete registeredFunds[registeredFundId];

        emit FundUnregistered(registeredFundId, kpkSharesProxy);
    }

    /// @notice Whether `registeredFundId` holds a live (registered, not-removed) fund.
    /// @dev    `registeredFundCount` is monotonic and `unregisterFund` leaves zeroed gaps, so the raw
    ///         `registeredFunds` auto-getter returns an all-zero struct for a removed/never-set id
    ///         rather than reverting. Enumerators iterating `[0, registeredFundCount)` MUST gate on
    ///         this (or `getFund`) to skip gaps — do NOT treat every id `< registeredFundCount` as a
    ///         live fund (unlike the gap-free `instances`/`stacks` deploy logs).
    /// @param  registeredFundId The `registeredFunds` index to check.
    function registeredFundExists(uint256 registeredFundId) public view returns (bool) {
        return registeredFunds[registeredFundId].kpkSharesProxy != address(0);
    }

    /// @notice Returns the registered fund at `registeredFundId`, reverting `FundNotRegistered` if the
    ///         slot is empty (never registered, or removed). Safe accessor for indexers/consumers —
    ///         prefer it over the raw `registeredFunds` getter, which silently returns a zero struct.
    /// @param  registeredFundId The `registeredFunds` index to read.
    /// @return instance The seven fund-component addresses recorded at that id.
    function getFund(uint256 registeredFundId) external view returns (OivInstance memory instance) {
        instance = registeredFunds[registeredFundId];
        if (instance.kpkSharesProxy == address(0)) revert FundNotRegistered();
    }

    /// @notice Derives the operational `StackConfig` that `deployOiv` builds for a given `OivConfig`.
    /// @dev    Single source of truth for the OivConfig → StackConfig mapping: `deployOiv` calls this
    ///         internally, and off-chain orchestrators (e.g. a cross-chain CCIP deployer that runs
    ///         `deployStack` on sidechains) MUST call this — rather than re-deriving the mapping —
    ///         so the operational-stack addresses they produce match `deployOiv` on every chain.
    ///         `subRolesMod` / `managerRolesMod` finalOwners are always `address(0)` (ownership goes
    ///         to the Manager Safe during wiring); the exec modifier's finalOwner is `config.admin`.
    /// @param  config Fund deployment parameters.
    /// @return The operational-stack configuration.
    function oivToStackConfig(OivConfig calldata config) public pure returns (StackConfig memory) {
        return StackConfig({
            managerSafe: config.managerSafe,
            execRolesMod: RolesModifierConfig({finalOwner: config.admin}),
            subRolesMod: RolesModifierConfig({finalOwner: address(0)}),
            managerRolesMod: RolesModifierConfig({finalOwner: address(0)}),
            salt: config.salt,
            execTimelock: config.execTimelock
        });
    }

    // ── Read-only: address prediction ───────────────────────────────────────────

    /// @notice Predicts the five-contract operational stack addresses that `deployStack(config)`
    ///         would produce when called by `caller`.
    /// @dev    All five contracts use CREATE2; their addresses are fully determined by
    ///         (factory address, infrastructure addresses, `caller`, `config.salt`, and the
    ///         Manager Safe's owners/threshold). The prediction does NOT validate `config` —
    ///         pass a config that would actually succeed (see `_validateStackConfig`).
    ///         By design, `predictStackAddresses` and `predictOivAddresses` produce IDENTICAL
    ///         Avatar Safe / Manager Safe / Roles Modifier addresses for the same `(salt,
    ///         caller)` — the factory is always enabled as a setup-time Avatar Safe module
    ///         in both flows so the setup() initializer is byte-identical.
    /// @param  config  Stack deployment parameters.
    /// @param  caller  Address that would call `deployStack`. Pass `msg.sender` if you intend
    ///                 to be the deployer.
    /// @return inst    Predicted addresses of the five contracts.
    function predictStackAddresses(StackConfig calldata config, address caller)
        external
        view
        returns (StackInstance memory inst)
    {
        inst = _predictStack(config.managerSafe.owners, config.managerSafe.threshold, config.salt, caller);

        if (config.execTimelock.minDelay != 0) {
            inst.execTimelock = IKpkTimelockDeployer(_requireTimelockDeployer()).predictExecTimelock(
                inst.execRolesModifier, config.execTimelock
            );
        }
    }

    /// @notice Predicts the deterministic addresses produced by `deployOiv(config)` when called
    ///         by `caller`. All seven addresses (5 operational-stack + KpkShares impl + proxy) are
    ///         CREATE2-deployed and fully predictable from `(factory, infrastructure addresses,
    ///         caller, config.salt, manager owners/threshold, KpkShares constructor parameters)`.
    /// @dev    The five operational-stack addresses match those of `predictStackAddresses` for
    ///         the same `(salt, caller)` — see that function's NatSpec. The shares impl is deployed
    ///         via the wired `kpkSharesDeployer` using a CREATE2 salt derived from
    ///         `(caller, salt, 5)`; the ERC-1967 proxy is deployed by this factory using a salt
    ///         derived from `(caller, salt, 6)`. The proxy's CREATE2 init-code includes the
    ///         `KpkShares.initialize(params)` calldata where `params.safe` is overridden with the
    ///         predicted Avatar Safe and `params.admin` is set to `address(this)`, mirroring
    ///         `_deploySharesProxy` exactly.
    /// @param  config  Fund deployment parameters.
    /// @param  caller  Address that would call `deployOiv`.
    /// @return inst    Predicted addresses for all seven contracts.
    function predictOivAddresses(OivConfig calldata config, address caller)
        external
        view
        returns (OivInstance memory inst)
    {
        StackInstance memory stack =
            _predictStack(config.managerSafe.owners, config.managerSafe.threshold, config.salt, caller);

        (bytes32 implSalt, bytes32 proxySalt) = _deriveSharesSalts(config.salt, caller);
        address predictedImpl = IKpkSharesDeployer(kpkSharesDeployer).predictImpl(implSalt);
        address predictedProxy = _predictSharesProxy(proxySalt, predictedImpl, config.sharesParams, stack.avatarSafe);

        inst = OivInstance({
            avatarSafe: stack.avatarSafe,
            managerSafe: stack.managerSafe,
            execRolesModifier: stack.execRolesModifier,
            subRolesModifier: stack.subRolesModifier,
            managerRolesModifier: stack.managerRolesModifier,
            kpkSharesImpl: predictedImpl,
            kpkSharesProxy: predictedProxy,
            execTimelock: address(0),
            sharesTimelock: address(0)
        });

        // Both timelocks key on the address of the contract they will govern, so they are predictable
        // from the same `(caller, salt)` as everything else. Prediction mirrors deployment exactly,
        // including reverting when a timelock is configured but no deployer is wired.
        if (config.execTimelock.minDelay != 0) {
            inst.execTimelock = IKpkTimelockDeployer(_requireTimelockDeployer()).predictExecTimelock(
                stack.execRolesModifier, config.execTimelock
            );
        }
        if (config.sharesTimelock.minDelay != 0) {
            inst.sharesTimelock = IKpkTimelockDeployer(_requireTimelockDeployer()).predictSharesTimelock(
                predictedProxy, config.sharesTimelock
            );
        }
    }

    /// @dev Returns `timelockDeployer`, reverting if it has not been wired. Mirrors the
    ///      `KpkSharesDeployerNotSet` guard: the factory may be constructed with a zero deployer so
    ///      its CREATE2 address does not depend on it, and only deployments that actually configure a
    ///      timelock require it to have been set since.
    function _requireTimelockDeployer() internal view returns (address deployer) {
        deployer = timelockDeployer;
        if (deployer == address(0)) revert TimelockDeployerNotSet();
    }

    /// @dev Computes the CREATE2 address `_deploySharesProxy` will produce for the ERC-1967 proxy.
    ///      Mirrors the deployment exactly: same `params.safe` override (predicted Avatar Safe),
    ///      same `params.admin` placeholder (`address(this)`), same initializer calldata.
    function _predictSharesProxy(
        bytes32 proxySalt,
        address impl,
        KpkShares.ConstructorParams memory params,
        address avatarSafe
    ) internal view returns (address predicted) {
        params.safe = avatarSafe;
        params.admin = address(this);
        bytes memory initCode = abi.encodePacked(
            type(ERC1967Proxy).creationCode, abi.encode(impl, abi.encodeCall(KpkShares.initialize, (params)))
        );
        predicted = _create2Address(address(this), proxySalt, keccak256(initCode));
    }

    /// @dev Predicts the operational stack addresses. Mirrors the deployment paths in
    ///      `_deployAndWireStack` exactly — any change to the deployment flow that affects
    ///      addresses MUST be mirrored here. The factory is always part of the Avatar Safe's
    ///      setup-time module list, matching the unconditional inclusion in
    ///      `_deployAndWireStack`.
    function _predictStack(address[] memory managerOwners, uint256 managerThreshold, uint256 baseSalt, address caller)
        internal
        view
        returns (StackInstance memory inst)
    {
        (uint256 execSalt, uint256 subSalt, uint256 mgrSalt, uint256 avatarNonce, uint256 mgrNonce) =
            _deriveSalts(baseSalt, caller);

        inst.execRolesModifier = _predictRolesModifier(execSalt);
        inst.subRolesModifier = _predictRolesModifier(subSalt);
        inst.managerRolesModifier = _predictRolesModifier(mgrSalt);

        address[] memory avatarOwners = new address[](1);
        avatarOwners[0] = EMPTY_CONTRACT;

        address[] memory avatarModules = new address[](2);
        avatarModules[0] = inst.execRolesModifier;
        avatarModules[1] = address(this);
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

    /// @dev Disables the factory as an Avatar Safe module by routing a `disableModule(SENTINEL,
    ///      factory)` call through the factory's own module slot. The factory must currently be
    ///      at the head of the Safe's module linked list — which is guaranteed by
    ///      `_deployAndWireStack`'s use of `SafeModuleSetup.enableModules([execMod, factory])`
    ///      (modules are applied in reverse order, leaving `SENTINEL → factory → execMod`).
    ///      The post-condition `isModuleEnabled(factory) == false` is independent of list
    ///      ordering and catches any failure mode where the disableModule call returned success
    ///      without actually removing the factory.
    function _disableFactoryAsAvatarModule(address avatarSafe) internal {
        bool moduleDisabled = ISafe(avatarSafe)
            .execTransactionFromModule(
                avatarSafe, 0, abi.encodeCall(ISafe.disableModule, (SENTINEL_MODULES, address(this))), 0
            );
        require(moduleDisabled, "KpkOivFactory: failed to disable module");
        require(!ISafe(avatarSafe).isModuleEnabled(address(this)), "KpkOivFactory: factory still enabled as module");
    }

    // ── Internal: stack deployment ──────────────────────────────────────────────

    /// @dev Deploys and fully wires the five-contract operational stack. The factory is always
    ///      pre-enabled as an additional module on the Avatar Safe at setup time (SafeModuleSetup
    ///      enables modules in reverse order, so [execMod, factory] yields
    ///      `SENTINEL → factory → execMod → SENTINEL` — factory at the head). The caller is
    ///      responsible for disabling the factory module before returning, via
    ///      `_disableFactoryAsAvatarModule`. Including the factory in setup() unconditionally
    ///      (rather than only for `deployOiv`) is what guarantees the Avatar Safe's CREATE2
    ///      address is identical between `deployStack` (sidechains) and `deployOiv` (mainnet)
    ///      for the same `(salt, caller)`, which is the entire point of the multichain design.
    /// @param config Stack deployment parameters.
    /// @return inst  Addresses of the five deployed contracts.
    function _deployAndWireStack(StackConfig memory config) internal returns (StackInstance memory inst) {
        // Defense against the canonical `Empty` not occupying `EMPTY_CONTRACT` on the current chain.
        // If absent — or if a different contract squats the address — the Avatar Safe's sole owner
        // would not be the always-reverting `Empty`, breaking the Roles-Modifier-only execution
        // invariant the entire fund stack depends on. Assert the exact codehash (not merely presence)
        // so a non-`Empty` occupant fails closed. (A never-touched address has codehash 0 and an
        // existing codeless one has keccak256(""); both differ from EXPECTED, so "missing" is covered.)
        if (EMPTY_CONTRACT.codehash != EXPECTED_EMPTY_CODEHASH) revert EmptyContractMissing();

        // Defense against the MultiSend unwrapping infrastructure being absent or non-canonical on
        // the current chain. Registration makes each MultiSend an unconditional DELEGATECALL sink
        // for every role on every modifier this fund gets, so all three are asserted by exact
        // codehash — see `EXPECTED_MULTI_SEND_CODEHASH` for why presence alone is not enough.
        // (Per-chain availability history lives in docs/DEPLOYED_ADDRESSES.md, not here: editing a
        // comment in this compilation unit moves every deployed address.)
        if (MULTISEND_UNWRAPPER.codehash != EXPECTED_MULTISEND_UNWRAPPER_CODEHASH) {
            revert MultiSendUnwrapperMissing();
        }
        if (MULTI_SEND.codehash != EXPECTED_MULTI_SEND_CODEHASH) revert MultiSendMissing(MULTI_SEND);
        if (MULTI_SEND_CALLS_ONLY.codehash != EXPECTED_MULTI_SEND_CALLS_ONLY_CODEHASH) {
            revert MultiSendMissing(MULTI_SEND_CALLS_ONLY);
        }

        (uint256 execSalt, uint256 subSalt, uint256 mgrSalt, uint256 avatarNonce, uint256 mgrNonce) =
            _deriveSalts(config.salt, msg.sender);

        // Step 1 – Deploy all three roles modifiers with factory as temp owner/avatar/target.
        address execMod = _deployRolesModifier(execSalt);
        address subMod = _deployRolesModifier(subSalt);
        address managerMod = _deployRolesModifier(mgrSalt);

        // Step 2 – Deploy Avatar Safe with EMPTY_CONTRACT as sole signer.
        //          Modules enabled during setup() (in array order, but applied in reverse by
        //          SafeModuleSetup): SENTINEL → factory → execMod → SENTINEL after setup.
        //          The factory module is disabled by the caller before this entry point returns.
        address avatarSafe;
        {
            address[] memory avatarOwners = new address[](1);
            avatarOwners[0] = EMPTY_CONTRACT;

            address[] memory avatarModules = new address[](2);
            avatarModules[0] = execMod;
            avatarModules[1] = address(this);

            avatarSafe = _deploySafe(avatarOwners, 1, avatarModules, avatarNonce);
        }

        // Step 3 – Deploy Manager Safe with managerMod enabled.
        address[] memory managerOwners = config.managerSafe.owners;
        address[] memory managerModules = new address[](1);
        managerModules[0] = managerMod;
        address managerSafe = _deploySafe(managerOwners, config.managerSafe.threshold, managerModules, mgrNonce);

        // Step 4 – Deploy the exec timelock, if one was configured, and make it the modifier's
        //          owner in place of `finalOwner`. Deployed here rather than by the caller after the
        //          fact so a fund is never briefly live under an un-timelocked owner, and so its
        //          address is fixed by the same `(caller, salt)` that fixes everything else.
        address execTimelock;
        address execOwner = config.execRolesMod.finalOwner;
        if (config.execTimelock.minDelay != 0) {
            execTimelock =
                IKpkTimelockDeployer(_requireTimelockDeployer()).deployExecTimelock(execMod, config.execTimelock);
            execOwner = execTimelock;
        }

        // Steps 5-7 – Wire all three modifiers. Ownership transfer is the last act of each helper,
        //             so every unwrapper registration still happens while the factory is owner.
        _wireExecModifier(execMod, avatarSafe, managerSafe, subMod, execOwner);
        _wireSubModifier(subMod, avatarSafe, execMod, managerSafe);
        _wireManagerModifier(managerMod, managerSafe);

        inst = StackInstance({
            avatarSafe: avatarSafe,
            managerSafe: managerSafe,
            execRolesModifier: execMod,
            subRolesModifier: subMod,
            managerRolesModifier: managerMod,
            execTimelock: execTimelock
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

    /// @dev Derives the two CREATE2 salts used by `_deploySharesProxy` (KpkShares implementation
    ///      and ERC-1967 proxy). Indices 5 and 6 extend the `_deriveSalts` index space so all
    ///      seven OIV addresses are deterministic from `(caller, baseSalt)`. Same caller-mixing
    ///      rationale: prevents salt-squat front-running while keeping cross-chain determinism.
    ///      Index mapping: 5 = KpkShares implementation, 6 = ERC-1967 shares proxy.
    /// @param baseSalt The user-supplied base salt from `OivConfig.salt`.
    /// @param caller   The address calling `deployOiv`.
    /// @return implSalt  CREATE2 salt the deployer uses for the KpkShares implementation.
    /// @return proxySalt CREATE2 salt this factory uses for the ERC-1967 proxy.
    function _deriveSharesSalts(uint256 baseSalt, address caller)
        internal
        pure
        returns (bytes32 implSalt, bytes32 proxySalt)
    {
        implSalt = keccak256(abi.encode(caller, baseSalt, uint8(5)));
        proxySalt = keccak256(abi.encode(caller, baseSalt, uint8(6)));
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
        _registerMultiSendUnwrappers(mod);
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
        _registerMultiSendUnwrappers(mod);
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
        _registerMultiSendUnwrappers(mod);
        IRoles(mod).transferOwnership(managerSafe);
    }

    /// @dev Registers the Zodiac MultiSendUnwrapper against both Safe MultiSend contracts on `mod`.
    ///      A Roles Modifier permission-checks one call at a time; a `multiSend(bytes)` batch
    ///      arrives as a single opaque delegatecall, so without an unwrap adapter the modifier
    ///      cannot decompose it and rejects the whole batch. Both MultiSend variants share the
    ///      `multiSend(bytes)` selector but the adapter is keyed on `(target, selector)`, so each
    ///      needs its own registration.
    ///
    ///      MUST be called while the factory is still the modifier's owner — i.e. before the
    ///      `transferOwnership` that ends each wiring helper. `setTransactionUnwrapper` is
    ///      `onlyOwner`, and once ownership has moved to the Security Council or Manager Safe the
    ///      registration can only be done by a multisig transaction after the fact.
    /// @param mod Roles Modifier to configure (factory must still be its owner).
    function _registerMultiSendUnwrappers(address mod) internal {
        IRoles(mod).setTransactionUnwrapper(MULTI_SEND, MULTI_SEND_SELECTOR, MULTISEND_UNWRAPPER);
        IRoles(mod).setTransactionUnwrapper(MULTI_SEND_CALLS_ONLY, MULTI_SEND_SELECTOR, MULTISEND_UNWRAPPER);
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
    /// @param implSalt        CREATE2 salt forwarded to `KpkSharesDeployer.deploy(salt)` so the
    ///                        impl address is deterministic from `(caller, baseSalt)`.
    /// @param proxySalt       CREATE2 salt for the ERC-1967 proxy created by this factory so the
    ///                        proxy address is deterministic from `(caller, baseSalt)`.
    /// @return impl  Address of the newly deployed KpkShares implementation.
    /// @return proxy Address of the ERC-1967 proxy (the fund's shares token).
    function _deploySharesProxy(
        KpkShares.ConstructorParams memory params,
        address operator,
        address avatarSafe,
        address finalAdmin,
        AssetConfig[] calldata additionalAssets,
        bytes32 implSalt,
        bytes32 proxySalt,
        TimelockParams memory timelockParams
    ) internal returns (address impl, address proxy, address timelock) {
        impl = IKpkSharesDeployer(kpkSharesDeployer).deploy(implSalt);
        params.safe = avatarSafe;
        params.admin = address(this);

        proxy = address(new ERC1967Proxy{salt: proxySalt}(impl, abi.encodeCall(KpkShares.initialize, (params))));

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

        // The timelock REPLACES `finalAdmin` as the role holder — it is never granted alongside it.
        // Leaving `admin` with DEFAULT_ADMIN_ROLE would keep a delay-free path to `upgradeToAndCall`
        // and every fee setter, which is precisely what the timelock exists to close.
        if (timelockParams.minDelay != 0) {
            timelock = IKpkTimelockDeployer(_requireTimelockDeployer()).deploySharesTimelock(proxy, timelockParams);
            shares.grantRole(DEFAULT_ADMIN_ROLE, timelock);
        } else {
            shares.grantRole(DEFAULT_ADMIN_ROLE, finalAdmin);
        }

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
