// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {IERC165} from "@openzeppelin/contracts/utils/introspection/IERC165.sol";
import {IRouterClient} from "chainlink-brownie-contracts/contracts/src/v0.8/ccip/interfaces/IRouterClient.sol";
import {
    IAny2EVMMessageReceiver
} from "chainlink-brownie-contracts/contracts/src/v0.8/ccip/interfaces/IAny2EVMMessageReceiver.sol";
import {Client} from "chainlink-brownie-contracts/contracts/src/v0.8/ccip/libraries/Client.sol";
import {KpkOivFactory} from "./KpkOivFactory.sol";

/// @title  CcipOivDeployer
/// @author KPK
/// @notice Cross-chain orchestrator for `KpkOivFactory`. A single mainnet transaction deploys the
///         full OIV (`deployOiv`) on mainnet and, via Chainlink CCIP, fans out the operational
///         stack (`deployStack`) to a set of sidechains — yielding the SAME Avatar Safe / Manager
///         Safe / Roles Modifier addresses on every chain.
///
///         ── Why this contract exists ──────────────────────────────────────────────────────────
///         `KpkOivFactory` mixes `msg.sender` into every CREATE2 salt (see `_deriveSalts`). Its
///         cross-chain address invariant therefore holds only when the SAME caller invokes the
///         factory on every chain. A raw CCIP integration breaks this: on the destination chain
///         the factory's caller would be the CCIP Router, not the original mainnet account.
///
///         This contract solves it by being the single, uniform caller of the factory on every
///         chain. Because it is deployed at the SAME address on all chains (deterministic CREATE2
///         with identical creation code — see below), the factory observes one identical
///         `msg.sender` everywhere, and the address invariant is preserved with the factory
///         left completely untouched.
///
///         ── Deterministic-address constraint ──────────────────────────────────────────────────
///         The orchestrator's CREATE2 creation code must be byte-identical across chains, so NO
///         constructor argument may differ per chain. The CCIP Router and LINK token addresses DO
///         differ per chain, so — unlike Chainlink's stock `CCIPReceiver`, which stores the router
///         as a constructor immutable — they are held in mutable storage and wired post-deploy via
///         `configure()`. Only `_owner` and `_factory` (identical on every chain) are constructor
///         arguments. The `onlyRouter` / source-chain / source-sender checks are re-implemented
///         here against that storage router.
///
///         ── Trust & security ──────────────────────────────────────────────────────────────────
///         - `deployEverywhere` / `dispatchTo` are PERMISSIONLESS and `payable`: the caller funds the
///           CCIP fees in native gas via `msg.value` (the message's `feeToken` is `address(0)`), so
///           there is no shared balance to drain — anyone may deploy a fund and pay for their own
///           fan-out. Surplus `msg.value` is refunded. `configure` / `withdrawLink` / `withdrawNative`
///           remain `onlyOwner`.
///         - Anti-front-running: the factory mixes its caller into every CREATE2 salt to stop
///           salt-squatting, but THIS contract is the factory's uniform caller on every chain, which
///           would neutralise that protection for permissionless callers. To restore it the
///           orchestrator binds the FULL fund config into the salt (`_effectiveConfig`:
///           `salt = keccak256(abi.encode(config))`). Any config difference (notably `admin`) changes
///           every deployed address, so an attacker cannot land a fund at another config's addresses;
///           an identical config still yields identical addresses on every chain. Off-chain code MUST
///           predict via `predictOiv(config)` (which applies the same derivation), not the factory's
///           raw `predictOivAddresses`.
///         - `ccipReceive` accepts a message only when (a) `msg.sender` is the configured router,
///           (b) the source chain selector is the configured mainnet selector, and (c) the source
///           sender equals `address(this)` — which, by the same-address-everywhere property, is the
///           sibling orchestrator on mainnet. (c) blocks a forged message from pre-occupying the
///           deterministic CREATE2 addresses for a salt and griefing the legitimate deployment.
///         - The factory's exec Roles Modifier (owned by `config.admin`) remains the authoritative
///           gatekeeper of Avatar Safe execution. This contract never gains a privileged role on
///           any deployed fund — it is purely a deployment conduit.
contract CcipOivDeployer is Ownable, ReentrancyGuard, IAny2EVMMessageReceiver, IERC165 {
    using SafeERC20 for IERC20;

    // ── Immutable config (identical on every chain) ────────────────────────────

    /// @notice The `KpkOivFactory` this orchestrator drives. Deployed at the same address on every
    ///         chain, so it is safe to bake into the constructor (init-code stays chain-identical).
    KpkOivFactory public immutable factory;

    // ── Per-chain config (wired post-deploy via `configure`) ────────────────────

    /// @notice CCIP Router for the current chain. Differs per chain, so set after construction.
    address public router;

    /// @notice LINK token used to pay CCIP fees on the current chain. Differs per chain.
    address public linkToken;

    /// @dev True for every selector currently in the registry. `ccipReceive` needs to answer "is this
    ///      a chain I know?" in O(1); iterating `_chainIds` would cost ~19 cold SLOADs on a path that
    ///      has to fit inside CCIP's destination gas budget. Maintained in lockstep with
    ///      `chainSelectorOf`.
    mapping(uint64 => bool) private _isKnownSelector;

    /// @notice CCIP chain selector for a destination chain id. This is the lookup that lets callers of
    ///         `deployEverywhere`/`dispatchTo` pass plain chain IDs instead of raw CCIP selectors.
    ///         Owner-managed via `setChainSelector(s)` / `removeChainSelector` (so a selector can be
    ///         corrected, or chains added/removed, without redeploying). Zero means the chain id is
    ///         not configured — deploying to it reverts `UnknownChain`.
    mapping(uint256 => uint64) public chainSelectorOf;

    /// @notice Enumerable list of every configured destination chain id (the "selected chains"). Lets
    ///         `getChainIds()` surface the set and the no-array `deployEverywhere(config, gasLimit)`
    ///         fan out to all of them. Maintained in lockstep with `chainSelectorOf`.
    uint256[] private _chainIds;

    /// @dev 1-based index of a chain id within `_chainIds` (0 = not present), for O(1) swap-pop removal.
    mapping(uint256 => uint256) private _chainIdIndex;

    // ── Events ───────────────────────────────────────────────────────────────────

    /// @notice Emitted when `configure` wires the per-chain CCIP parameters.
    event Configured(address indexed router, address indexed linkToken);

    /// @notice Emitted when the owner sets or updates a chain id → CCIP selector mapping.
    event ChainSelectorSet(uint256 indexed chainId, uint64 indexed ccipChainSelector);

    /// @notice Emitted when the owner removes a chain id → CCIP selector mapping.
    event ChainSelectorRemoved(uint256 indexed chainId);

    /// @notice Emitted on mainnet for the locally deployed full OIV.
    event LocalOivDeployed(KpkOivFactory.OivInstance instance);

    /// @notice Emitted for each sidechain CCIP message dispatched by `deployEverywhere`.
    /// @param destChainSelector Destination chain selector.
    /// @param messageId         CCIP message id returned by the router.
    /// @param fee               Native fee paid for this message.
    event StackDispatched(uint64 indexed destChainSelector, bytes32 indexed messageId, uint256 fee);

    /// @notice Emitted on a sidechain when an inbound CCIP message deploys the stack.
    /// @param sourceChainSelector Source chain selector (always the mainnet selector).
    /// @param messageId           CCIP message id of the inbound message.
    /// @param instance            Addresses of the five stack contracts deployed.
    event StackReceived(
        uint64 indexed sourceChainSelector, bytes32 indexed messageId, KpkOivFactory.StackInstance instance
    );

    // ── Errors ─────────────────────────────────────────────────────────────────

    error ZeroAddress();
    error ZeroChainSelector();
    error NotConfigured();
    error InvalidRouter(address caller);
    error InvalidSourceChain(uint64 sourceChainSelector);
    error InvalidSourceSender(address sender);
    error NoDestinations();
    /// @notice Thrown when the native `msg.value` sent to cover CCIP fees is below the total required.
    error InsufficientFee(uint256 required, uint256 provided);
    /// @notice Thrown when refunding surplus `msg.value` back to the caller fails.
    error RefundFailed();
    /// @notice Thrown when a destination chain id has no configured CCIP selector.
    error UnknownChain(uint256 chainId);
    /// @notice Thrown when a chain id of zero is supplied to a selector setter.
    error ZeroChainId();
    /// @notice Thrown when `setChainSelectors` is given arrays of differing lengths.
    error LengthMismatch();
    /// @notice Thrown when `withdrawLink` is called but no LINK token is configured (native fees).
    error NoLinkToken();

    // ── Constructor ────────────────────────────────────────────────────────────

    /// @param _owner   Owner of the orchestrator. MUST be identical on every chain (it is baked
    ///                 into the creation code), so the same value must be used for every deploy to
    ///                 keep the CREATE2 address identical. Hand off to a governance multisig after
    ///                 deployment via `transferOwnership`.
    /// @param _factory `KpkOivFactory` address — identical on every chain by construction.
    constructor(address _owner, address _factory) Ownable(_owner) {
        if (_factory == address(0)) revert ZeroAddress();
        factory = KpkOivFactory(_factory);
        _seedKnownChains();
    }

    /// @dev Seeds the destination registry with every wired chain, at construction.
    ///
    ///      This used to be an owner-only step after deployment, and it was the sharpest operational
    ///      edge in the rollout: a freshly CREATE2'd orchestrator started with an EMPTY registry, the
    ///      seeding had to happen from the EOA before ownership moved to the Safe, and getting it
    ///      wrong was not hypothetical — the first attempt wrote 20 entries including two chains with
    ///      no infrastructure, which had to be removed before handover or the no-array
    ///      `deployEverywhere` would have spent non-refundable CCIP fees on messages whose delivery
    ///      reverts.
    ///
    ///      Seeding in the constructor removes the step, and with it that whole failure class. The
    ///      list is identical on every chain, so it does not disturb the orchestrator's
    ///      same-address-everywhere property. `setChainSelector` / `removeChainSelector` still work
    ///      exactly as before, for chains added or lanes retired later.
    ///
    ///      COUPLING: this list is the wired subset of `script/ccip-networks.json` — every entry whose
    ///      verdict is READY* and which is not `excluded`. `test/CcipNetworksSync.t.sol` asserts the
    ///      two agree, so editing the registry file without editing this list fails CI.
    function _seedKnownChains() private {
        _seed(1, 5009297550715157269); // ethereum
        _seed(10, 3734403246176062136); // optimism
        _seed(100, 465200170687744372); // gnosis
        _seed(8453, 15971525489660198786); // base
        _seed(42161, 4949039107694359620); // arbitrum
        _seed(56, 11344663589394136015); // bnb
        _seed(137, 4051577828743386545); // polygon
        _seed(43114, 6433500567565415381); // avalanche
        _seed(42220, 1346049177634351622); // celo
        _seed(59144, 4627098889531055414); // linea
        _seed(534352, 13204309965629103672); // scroll
        _seed(146, 1673871237479749969); // sonic
        _seed(130, 1923510103922296319); // unichain
        _seed(480, 2049429975587534727); // worldchain
        _seed(999, 2442541497099098535); // hyperevm
        _seed(5000, 1556008542357238666); // mantle
        _seed(9745, 9335212494177455608); // plasma
        _seed(57073, 3461204551265785888); // ink
        _seed(80094, 1294465214383781161); // berachain
    }

    /// @dev Registry write shared by the constructor and `setChainSelector`. Keeps `chainSelectorOf`,
    ///      the enumerable `_chainIds` set and `_isKnownSelector` in step; separated out so the
    ///      constructor path cannot drift from the owner path.
    function _seed(uint256 chainId, uint64 ccipChainSelector) private {
        if (chainSelectorOf[chainId] == 0) {
            _chainIds.push(chainId);
            _chainIdIndex[chainId] = _chainIds.length; // 1-based
        } else {
            // Correcting an existing entry: the old selector stops being a trusted source.
            _isKnownSelector[chainSelectorOf[chainId]] = false;
        }
        chainSelectorOf[chainId] = ccipChainSelector;
        _isKnownSelector[ccipChainSelector] = true;
    }

    /// @dev The fan-out entry points require only that the LOCAL chain is one this orchestrator
    ///      knows. Previously they were pinned to Ethereum, which made the whole system
    ///      hub-and-spoke: a fund could only be fanned out from mainnet.
    ///
    ///      Nothing about the address invariant depended on that. The orchestrator is the uniform
    ///      `msg.sender` into the factory on every chain, and the salt is
    ///      `keccak256(abi.encode(config))` composed once on the origin chain and shipped — so the
    ///      origin never entered the derivation. A fund fanned out from Base lands at exactly the
    ///      addresses it would have from Ethereum.
    ///
    ///      The check that remains is worth keeping: fanning out from a chain absent from the
    ///      registry would produce messages every sibling rejects, after the fees were already paid.
    modifier onlyWiredChain() {
        if (chainSelectorOf[block.chainid] == 0) revert UnknownChain(block.chainid);
        _;
    }

    // ── Configuration ────────────────────────────────────────────────────────────

    /// @notice Wires the per-chain CCIP parameters. Owner-only; idempotent (re-callable to update
    ///         the router if Chainlink migrates it). Kept out of the constructor so the
    ///         orchestrator's creation code — and therefore its CREATE2 address — is identical on
    ///         every chain.
    /// @param _router               CCIP Router on the current chain.
    /// @param _linkToken            LINK token, retained only for the `withdrawLink` sweep escape hatch
    ///                              — fees are paid in native, so this MAY be `address(0)` on a lane
    ///                              with no LINK fee token (the chain is still usable).
    function configure(address _router, address _linkToken) external onlyOwner {
        // Only the router is mandatory; LINK is no longer the fee mechanism (native fees), so a zero
        // linkToken is allowed (just disables `withdrawLink`).
        if (_router == address(0)) revert ZeroAddress();
        router = _router;
        linkToken = _linkToken;
        emit Configured(_router, _linkToken);
    }

    // ── Destination-chain selector registry (owner-managed) ──────────────────────

    /// @notice Sets or updates the CCIP chain selector for a destination `chainId`, so callers can
    ///         target that chain by its id. Owner-only; idempotent (re-callable to correct a selector).
    /// @param chainId           Destination chain id (e.g. 10 for Optimism). Must be non-zero.
    /// @param ccipChainSelector That chain's CCIP selector. Must be non-zero (use `removeChainSelector`
    ///                          to unset a chain).
    function setChainSelector(uint256 chainId, uint64 ccipChainSelector) public onlyOwner {
        if (chainId == 0) revert ZeroChainId();
        if (ccipChainSelector == 0) revert ZeroChainSelector();
        _seed(chainId, ccipChainSelector);
        emit ChainSelectorSet(chainId, ccipChainSelector);
    }

    /// @notice Batch form of `setChainSelector` — populate or update many chains in one call. Owner-only.
    /// @param chainIds          Destination chain ids, index-aligned with `ccipChainSelectors`.
    /// @param ccipChainSelectors The matching CCIP selectors.
    function setChainSelectors(uint256[] calldata chainIds, uint64[] calldata ccipChainSelectors) external onlyOwner {
        if (chainIds.length != ccipChainSelectors.length) revert LengthMismatch();
        for (uint256 i = 0; i < chainIds.length; i++) {
            setChainSelector(chainIds[i], ccipChainSelectors[i]);
        }
    }

    /// @notice Removes a destination `chainId` so it can no longer be targeted. Owner-only.
    /// @param chainId The chain id to unset; reverts `UnknownChain` if it was not configured.
    function removeChainSelector(uint256 chainId) external onlyOwner {
        if (chainSelectorOf[chainId] == 0) revert UnknownChain(chainId);

        // Swap-pop the chain id out of the enumerable set in O(1).
        uint256 idx = _chainIdIndex[chainId]; // 1-based
        uint256 lastChainId = _chainIds[_chainIds.length - 1];
        _chainIds[idx - 1] = lastChainId;
        _chainIdIndex[lastChainId] = idx;
        _chainIds.pop();
        delete _chainIdIndex[chainId];
        // Retiring a lane must also stop it being an accepted CCIP source, not merely a destination.
        _isKnownSelector[chainSelectorOf[chainId]] = false;
        delete chainSelectorOf[chainId];

        emit ChainSelectorRemoved(chainId);
    }

    /// @notice The full set of configured destination chain ids — the "selected chains" that the
    ///         no-array `deployEverywhere(config, gasLimit)` fans out to. Read this on a block explorer
    ///         to see / confirm the targets before deploying. Order is not guaranteed (swap-pop on
    ///         removal). The local chain, if present, is skipped at fan-out time.
    function getChainIds() external view returns (uint256[] memory) {
        return _chainIds;
    }

    /// @notice Count of configured destination chain ids.
    function getChainIdCount() external view returns (uint256) {
        return _chainIds.length;
    }

    // ── Source side: deploy everywhere ───────────────────────────────────────────

    /// @notice Deploys the full OIV locally (intended to be called on mainnet) and dispatches a
    ///         CCIP message to each destination chain to deploy the matching operational stack.
    ///         CCIP fees are paid in NATIVE gas from `msg.value`, so the caller must send enough to
    ///         cover the total fee (use `quoteDeployEverywhere` to size it); any surplus is refunded.
    /// @dev    Permissionless and `payable`. Asynchronous: this transaction confirms once the messages
    ///         are dispatched; each sidechain stack materialises later (after source finality) when
    ///         CCIP delivers to `ccipReceive`. A destination message can fail (e.g. gas underestimate,
    ///         missing `EMPTY_CONTRACT`) and then be manually re-executed via CCIP within its retry
    ///         window.
    /// @param config         Full OIV config — passed verbatim to `factory.deployOiv`. The
    ///                       `StackConfig` sent to each sidechain is derived via
    ///                       `factory.oivToStackConfig` (the factory's own mapping), so the five
    ///                       operational-stack addresses match the local OIV.
    /// @param gasLimit       Destination `ccipReceive` gas limit (must cover `deployStack`, ~1.55M,
    ///                       or ~1.86M with an exec timelock configured; ~1.55M
    ///                       measured; a 2.0M–2.2M value is recommended). Capped at 3M by CCIP.
    ///                       The measured figure rose from ~1.38M when the factory began registering
    ///                       MultiSend unwrap adapters (six `setTransactionUnwrapper` writes across
    ///                       the three Roles Modifiers, ~155k gas). An under-sized `gasLimit` is not
    ///                       refundable: the CCIP fee is paid on the source chain and the destination
    ///                       `ccipReceive` reverts, so the fund lands on every chain but that one.
    /// @return instance      Addresses of the seven contracts deployed locally.
    /// @return messageIds    CCIP message id per destination, in `getChainIds()` order (local skipped).
    ///
    /// @dev    This no-array overload fans out to ALL configured chains (`getChainIds()`) — the easiest
    ///         call from a block explorer: just the config, the gas limit, and the native fee as
    ///         `msg.value`. The local chain is skipped automatically. Use the 3-arg overload to target
    ///         an explicit subset instead.
    function deployEverywhere(KpkOivFactory.OivConfig calldata config, uint256 gasLimit)
        external
        payable
        nonReentrant
        onlyWiredChain
        returns (KpkOivFactory.OivInstance memory instance, bytes32[] memory messageIds)
    {
        return _deployEverywhere(_effectiveConfig(config), _allConfiguredSelectors(), gasLimit);
    }

    /// @notice Same as `deployEverywhere(config, gasLimit)` but fans out only to the given `destChainIds`
    ///         (each resolved via `chainSelectorOf`; an unconfigured id reverts `UnknownChain`; the
    ///         local chain, if present, is skipped). Structural preconditions are enforced once inside
    ///         `_deployEverywhere`, matching the no-array overload.
    function deployEverywhere(
        KpkOivFactory.OivConfig calldata config,
        uint256[] calldata destChainIds,
        uint256 gasLimit
    )
        external
        payable
        nonReentrant
        onlyWiredChain
        returns (KpkOivFactory.OivInstance memory instance, bytes32[] memory messageIds)
    {
        return _deployEverywhere(_effectiveConfig(config), _resolveSelectors(destChainIds), gasLimit);
    }

    /// @dev Local full OIV (`msg.sender` to the factory is this orchestrator — the uniform caller on
    ///      every chain, so all addresses align) then CCIP fan-out. `config` is already the
    ///      config-bound-salt `_effectiveConfig`. The fee is priced and checked against `msg.value`
    ///      BEFORE the (~7M-gas) deployOiv, so an underfunded call fails fast without burning it.
    function _deployEverywhere(KpkOivFactory.OivConfig memory config, uint64[] memory destSelectors, uint256 gasLimit)
        internal
        returns (KpkOivFactory.OivInstance memory instance, bytes32[] memory messageIds)
    {
        if (destSelectors.length == 0) revert NoDestinations();
        (Client.EVM2AnyMessage memory message, uint256 totalFee, uint256[] memory fees) =
            _price(config, destSelectors, gasLimit);
        if (msg.value < totalFee) revert InsufficientFee(totalFee, msg.value);

        instance = factory.deployOiv(config);
        emit LocalOivDeployed(instance);

        messageIds = _send(message, destSelectors, fees, totalFee);
    }

    /// @notice Dispatch-only: CCIP-send the operational stack to `destChainIds` WITHOUT deploying a
    ///         local OIV. Use after `deployEverywhere` has already run for this `config` — to extend
    ///         the fund to a sidechain that was not in the original set, or to re-dispatch to one
    ///         whose prior message permanently failed (CCIP manual re-execution can replay an
    ///         existing message; a fresh message needs this). Permissionless and `payable`; the caller
    ///         funds the CCIP fees in native via `msg.value` (surplus refunded). Source-chain only.
    /// @dev    `config` MUST be the SAME config (notably the same `salt`, manager owners/threshold,
    ///         and `admin`) used in the original `deployEverywhere`, so the dispatched stack lands
    ///         at the fund's existing operational addresses. A destination that already has the
    ///         stack will revert on the CREATE2 collision when its message executes — do not
    ///         re-dispatch to an already-deployed chain.
    function dispatchTo(KpkOivFactory.OivConfig calldata config, uint256[] calldata destChainIds, uint256 gasLimit)
        external
        payable
        nonReentrant
        onlyWiredChain
        returns (bytes32[] memory messageIds)
    {
        uint64[] memory destSelectors = _resolveSelectors(destChainIds);
        if (destSelectors.length == 0) revert NoDestinations();
        (Client.EVM2AnyMessage memory message, uint256 totalFee, uint256[] memory fees) =
            _price(_effectiveConfig(config), destSelectors, gasLimit);
        if (msg.value < totalFee) revert InsufficientFee(totalFee, msg.value);
        messageIds = _send(message, destSelectors, fees, totalFee);
    }

    /// @notice Total NATIVE fee to fan out to ALL configured chains, plus the per-destination
    ///         breakdown — matches `deployEverywhere(config, gasLimit)`. Read this on a block explorer
    ///         to size the `msg.value` to send. Uses the exact derived `StackConfig` payload so the fee
    ///         — which scales with calldata length and gas limit — is accurate.
    /// @dev    The all-configured set is read at call time; if the owner mutates the chain registry
    ///         between this quote and your deploy, the fee / chain set can differ. Use the explicit
    ///         `destChainIds` overload when you need a fixed set.
    function quoteDeployEverywhere(KpkOivFactory.OivConfig calldata config, uint256 gasLimit)
        external
        view
        returns (uint256 totalFee, uint256[] memory feePerDestination)
    {
        (, totalFee, feePerDestination) = _price(_effectiveConfig(config), _allConfiguredSelectors(), gasLimit);
    }

    /// @notice Same, for an explicit subset of `destChainIds` — matches the 3-arg `deployEverywhere`.
    function quoteDeployEverywhere(
        KpkOivFactory.OivConfig calldata config,
        uint256[] calldata destChainIds,
        uint256 gasLimit
    ) external view returns (uint256 totalFee, uint256[] memory feePerDestination) {
        (, totalFee, feePerDestination) = _price(_effectiveConfig(config), _resolveSelectors(destChainIds), gasLimit);
    }

    /// @notice Predicts the seven fund addresses a `deployEverywhere`/`dispatchTo` for `config` would
    ///         produce, using the SAME config-bound salt the deploy path uses (`_effectiveConfig`).
    ///         Off-chain callers MUST use this rather than the factory's raw `predictOivAddresses`,
    ///         which would key on the un-derived `config.salt`.
    function predictOiv(KpkOivFactory.OivConfig calldata config)
        external
        view
        returns (KpkOivFactory.OivInstance memory)
    {
        return factory.predictOivAddresses(_effectiveConfig(config), address(this));
    }

    /// @dev Single source of truth for fee computation: builds the (loop-invariant) CCIP message once
    ///      and prices it per destination. Shared by `quoteDeployEverywhere`, `deployEverywhere` and
    ///      `dispatchTo` so the quoted and charged fees can never drift. The `StackConfig` payload comes
    ///      from `factory.oivToStackConfig` so it also cannot drift from `deployOiv`'s mapping. Reverts
    ///      `NotConfigured` if the router is unset.
    function _price(KpkOivFactory.OivConfig memory config, uint64[] memory destSelectors, uint256 gasLimit)
        internal
        view
        returns (Client.EVM2AnyMessage memory message, uint256 totalFee, uint256[] memory fees)
    {
        if (router == address(0)) revert NotConfigured();
        message = _buildMessage(abi.encode(factory.oivToStackConfig(config)), gasLimit);
        IRouterClient ccipRouter = IRouterClient(router);
        uint256 n = destSelectors.length;
        fees = new uint256[](n);
        for (uint256 i = 0; i < n; i++) {
            fees[i] = ccipRouter.getFee(destSelectors[i], message);
            totalFee += fees[i];
        }
    }

    /// @dev Sends one CCIP message per destination, paying each fee in native from `msg.value`, then
    ///      refunds the surplus to the caller (checks-effects-interactions: refund is the final action).
    ///      Callers MUST have verified `msg.value >= totalFee` before calling.
    function _send(
        Client.EVM2AnyMessage memory message,
        uint64[] memory destSelectors,
        uint256[] memory fees,
        uint256 totalFee
    ) internal returns (bytes32[] memory messageIds) {
        IRouterClient ccipRouter = IRouterClient(router);
        uint256 n = destSelectors.length;
        messageIds = new bytes32[](n);
        for (uint256 i = 0; i < n; i++) {
            bytes32 messageId = ccipRouter.ccipSend{value: fees[i]}(destSelectors[i], message);
            messageIds[i] = messageId;
            emit StackDispatched(destSelectors[i], messageId, fees[i]);
        }

        uint256 refund = msg.value - totalFee;
        if (refund > 0) {
            (bool ok,) = payable(msg.sender).call{value: refund}("");
            if (!ok) revert RefundFailed();
        }
    }

    // ── Destination side: receive and deploy stack ───────────────────────────────

    /// @inheritdoc IAny2EVMMessageReceiver
    /// @dev Called by the CCIP Router on the destination chain. Validates the router, source chain,
    ///      and source sender, then deploys the operational stack. Reverts propagate so a failed
    ///      delivery enters CCIP's FAILED state and can be manually re-executed.
    function ccipReceive(Client.Any2EVMMessage calldata message) external override {
        if (msg.sender != router) revert InvalidRouter(msg.sender);
        // Any chain in the registry may be a source, not just Ethereum. The registry is seeded at
        // construction with the same 19 chains everywhere, so every orchestrator accepts every other
        // one and a fan-out can be initiated from any of them.
        //
        // The load-bearing guard is the sender check below, not this one: only a contract at THIS
        // address can be the source sender, and that address is a deterministic function of the
        // orchestrator's creation code. This check narrows it further, to the chains we actually
        // wired — without it, anyone could CREATE2 the same bytecode on any CCIP-supported chain and
        // send from there. Worth noting the blast radius either way is bounded: `deployStack` is
        // permissionless, so a forged message can only do what any caller can already do directly.
        if (!_isKnownSelector[message.sourceChainSelector]) {
            revert InvalidSourceChain(message.sourceChainSelector);
        }
        // By the same-address-on-every-chain property, the trusted source sender is this very
        // address — the sibling orchestrator on whichever chain initiated.
        address sourceSender = abi.decode(message.sender, (address));
        if (sourceSender != address(this)) revert InvalidSourceSender(sourceSender);

        KpkOivFactory.StackConfig memory stackConfig = abi.decode(message.data, (KpkOivFactory.StackConfig));
        KpkOivFactory.StackInstance memory inst = factory.deployStack(stackConfig);
        emit StackReceived(message.sourceChainSelector, message.messageId, inst);
    }

    // ── Treasury management ──────────────────────────────────────────────────────

    /// @notice Withdraws LINK from the orchestrator to `to`. Owner-only.
    function withdrawLink(address to, uint256 amount) external onlyOwner {
        if (to == address(0)) revert ZeroAddress();
        // Distinct from NotConfigured (router): linkToken may legitimately be zero under native fees.
        if (linkToken == address(0)) revert NoLinkToken();
        IERC20(linkToken).safeTransfer(to, amount);
    }

    /// @notice Sweeps native to `to`. Owner-only. The deploy path sends the exact per-message CCIP fee
    ///         and refunds surplus, so nothing should normally accrue — this recovers any native a
    ///         router happens to return to the orchestrator (which `receive()` accepts).
    function withdrawNative(address to, uint256 amount) external onlyOwner {
        if (to == address(0)) revert ZeroAddress();
        (bool ok,) = payable(to).call{value: amount}("");
        if (!ok) revert RefundFailed();
    }

    /// @notice Accepts native so a CCIP router returning fee change to the orchestrator cannot revert a
    ///         dispatch. Anything received this way is recoverable via `withdrawNative`.
    receive() external payable {}

    // ── ERC165 ─────────────────────────────────────────────────────────────────

    /// @inheritdoc IERC165
    /// @dev Lets the CCIP Router confirm this contract implements `ccipReceive` before delivery.
    function supportsInterface(bytes4 interfaceId) external pure override returns (bool) {
        return interfaceId == type(IAny2EVMMessageReceiver).interfaceId || interfaceId == type(IERC165).interfaceId;
    }

    // ── Internal helpers ─────────────────────────────────────────────────────────

    /// @dev Binds the FULL fund config into the CREATE2 salt: `salt = keccak256(abi.encode(config))`.
    ///      Restores the factory's caller-in-salt anti-front-running protection, which the orchestrator
    ///      (the factory's uniform caller on every chain) would otherwise neutralise: any config
    ///      difference — notably `admin` — changes every deployed address, so a permissionless caller
    ///      cannot land a fund at another config's addresses, while an identical config still yields
    ///      identical addresses on every chain. The local deploy and the dispatched `StackConfig` both
    ///      use this derived salt, so cross-chain stack addresses still match.
    function _effectiveConfig(KpkOivFactory.OivConfig calldata config)
        internal
        pure
        returns (KpkOivFactory.OivConfig memory eff)
    {
        eff = config;
        eff.salt = uint256(keccak256(abi.encode(config)));
    }

    /// @dev Resolves caller-supplied destination chain ids to their CCIP selectors via the
    ///      owner-managed `chainSelectorOf` registry, reverting `UnknownChain` for any unconfigured id.
    ///      The local chain is skipped (you never CCIP-message your own chain) — same rule as
    ///      `_allConfiguredSelectors`, so the explicit-subset and all-chains paths behave consistently.
    function _resolveSelectors(uint256[] calldata chainIds) internal view returns (uint64[] memory selectors) {
        uint256 count;
        for (uint256 i = 0; i < chainIds.length; i++) {
            if (chainIds[i] != block.chainid) count++;
        }
        selectors = new uint64[](count);
        uint256 j;
        for (uint256 i = 0; i < chainIds.length; i++) {
            if (chainIds[i] == block.chainid) continue;
            uint64 selector = chainSelectorOf[chainIds[i]];
            if (selector == 0) revert UnknownChain(chainIds[i]);
            selectors[j++] = selector;
        }
    }

    /// @dev Selectors for every configured chain id EXCEPT the local chain — so an all-chains fan-out
    ///      never tries to CCIP-message its own chain (which the router would reject). Reverts
    ///      `NoDestinations` if no remote chain is configured.
    function _allConfiguredSelectors() internal view returns (uint64[] memory selectors) {
        uint256 n = _chainIds.length;
        uint256 count;
        for (uint256 i = 0; i < n; i++) {
            if (_chainIds[i] != block.chainid) count++;
        }
        if (count == 0) revert NoDestinations();
        selectors = new uint64[](count);
        uint256 j;
        for (uint256 i = 0; i < n; i++) {
            uint256 cid = _chainIds[i];
            if (cid == block.chainid) continue;
            selectors[j++] = chainSelectorOf[cid];
        }
    }

    /// @dev Builds the CCIP message: receiver is this contract's sibling on the destination chain
    ///      (same address), no token transfer, NATIVE fee token (`feeToken == address(0)`) so the
    ///      caller pays the fee in the chain's gas token, EVMExtraArgsV2 with the given gas limit and
    ///      out-of-order execution allowed (stack deployments are mutually independent).
    function _buildMessage(bytes memory payload, uint256 gasLimit)
        internal
        view
        returns (Client.EVM2AnyMessage memory)
    {
        return Client.EVM2AnyMessage({
            receiver: abi.encode(address(this)),
            data: payload,
            tokenAmounts: new Client.EVMTokenAmount[](0),
            feeToken: address(0),
            extraArgs: Client._argsToBytes(Client.EVMExtraArgsV2({gasLimit: gasLimit, allowOutOfOrderExecution: true}))
        });
    }
}
