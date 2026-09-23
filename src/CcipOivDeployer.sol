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
import {IRoles} from "./interfaces/IRoles.sol";

/// @title  CcipOivDeployer
/// @author KPK
/// @notice Cross-chain orchestrator for `KpkOivFactory`. A single transaction on ANY wired chain
///         deploys that chain's part of the fund and, via Chainlink CCIP, fans out the operational
///         stack (`deployStack`) to every other wired chain — yielding the SAME Avatar Safe /
///         Manager Safe / Roles Modifier addresses on all of them. There is no designated source
///         chain. The local half is conditional: the full OIV (`deployOiv`) when the origin appears
///         in `sharesChains`, the operational stack alone when it does not.
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
///           (b) the source chain selector is ANY entry in this orchestrator's baked registry
///           (`_isKnownSelector`) — not a single designated source; that restriction is gone — and
///           (c) the source sender equals `address(this)`, which by the same-address-everywhere
///           property is the sibling orchestrator on whichever chain originated. (c) is the
///           load-bearing guard: only a contract at THIS address can be the source sender, and that
///           address is a deterministic function of this contract's creation code. (b) narrows the
///           set further, to chains actually wired, so it is defence in depth over (c) rather than a
///           substitute for it.
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

    /// @notice One chain that carries this fund's shares token, and the base asset it uses there.
    /// @dev    The fund's cross-chain topology, made a first-class parameter. Its absence was the
    ///         single root cause of three defects: the per-chain asset leaked into the salt (so the
    ///         same config file produced different addresses per chain), the fan-out bombed every
    ///         chain with a stack including the ones meant to carry shares, and `ccipReceive` could
    ///         not refuse a stack aimed at a chain reserved for `deployOiv`.
    struct SharesChain {
        /// @notice Chain id that runs `deployOiv` for this fund.
        uint256 chainId;
        /// @notice The base asset on that chain. Chain-specific by nature — a fund uses a different
        ///         stablecoin on each chain — which is exactly why it must not be hashed verbatim.
        address asset;
    }

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

    /// @notice Emitted when this chain's operational stack is deployed locally, with no CCIP involved.
    /// @dev    Distinct from `StackReceived`, which means "a stack arrived over CCIP". Reusing that
    ///         one with a zero selector and zero message id put phantom deliveries in front of any
    ///         indexer counting them.
    /// @param  instance The five stack addresses plus the exec timelock.
    event LocalStackDeployed(KpkOivFactory.StackInstance instance);

    /// @notice Emitted when a chain outside the fund's declared topology gains its shares token.
    /// @param  chainId  The promoted chain.
    /// @param  instance The fund's addresses there. Asset approvals are already in place: since the
    ///                  precondition landed, `promoteShares` REQUIRES maximum allowances on the base
    ///                  asset and every redeemable `additionalAssets` entry before it calls
    ///                  `deployShares`, so this event cannot signal an approval-pending state. It
    ///                  said the opposite while the approvals were still described as deferred.
    event SharesPromoted(uint256 indexed chainId, KpkOivFactory.OivInstance instance);

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

    /// @notice Emitted on a destination chain when an inbound CCIP message deploys the stack, OR
    ///         finds it already present at the fund's canonical addresses. The two cases are
    ///         indistinguishable to a consumer by design: the stack is byte-identical either way,
    ///         because every field the addresses depend on is bound into the salt.
    /// @param sourceChainSelector Selector of the chain the message originated from.
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

    /// @notice Thrown when `sharesChains` is not strictly ascending by `chainId`. Ordering is part of
    ///         the contract: the topology is hashed into the salt, so two orderings of one topology
    ///         would otherwise describe two different funds.
    /// @param  chainId The out-of-order entry.
    error SharesChainsNotAscending(uint256 chainId);

    /// @notice Thrown when a `sharesChains` entry has a zero chain id or a zero asset.
    error InvalidSharesChain();

    /// @notice Thrown when the topology is longer than `MAX_SHARES_CHAINS`.
    /// @param  count The configured length.
    /// @param  max   `MAX_SHARES_CHAINS`.
    error TooManySharesChains(uint256 count, uint256 max);

    /// @notice Thrown when promoting a fund to a chain where one of its salt-bound `additionalAssets`
    ///         has no code. Those addresses are fixed at the fund's birth and cannot be restated per
    ///         chain, so promotion only works where the same address is a live token.
    /// @param  asset The entry with no code on this chain.
    error AdditionalAssetHasNoCodeHere(address asset);

    /// @notice Thrown when a CCIP chain selector is already mapped to a different chain id. Two ids
    ///         sharing one selector would make a fan-out pay for two deliveries to the same chain.
    /// @param  selector The selector already in use.
    /// @param  chainId  The chain id that already holds it.
    error SelectorAlreadyMapped(uint64 selector, uint256 chainId);

    /// @notice Thrown when the manager Safe has more owners than a destination can afford to set up
    ///         within CCIP's 3,000,000-gas execution cap.
    /// @param  count The configured owner count.
    /// @param  max   `MAX_CCIP_MANAGER_OWNERS`.
    error ManagerOwnersExceedCcipBudget(uint256 count, uint256 max);

    /// @notice Thrown when `sharesChains` is empty. A fund with no shares chain is not a fund: every
    ///         chain would take the stack-only branch, those stacks are wired, and the canonical
    ///         addresses are then unreachable — `deployLocal` reverts `StackAlreadyDeployedHere` and
    ///         `promoteShares` cannot reach them either, since it calls the factory with a different
    ///         caller and salt. The Foundry parser has always refused this; the contract did not, and
    ///         the contract is the entry point a third party actually reaches.
    error EmptySharesChains();

    /// @notice Thrown when the local chain carries shares but `config.sharesParams.asset` disagrees
    ///         with what the topology names for it. The topology commits to each chain's asset;
    ///         without this check that commitment would be decorative.
    /// @param  expected The asset the topology names for this chain.
    /// @param  actual   The asset the config supplied.
    error AssetMismatch(address expected, address actual);

    /// @notice Thrown when an explicit destination list names a chain that carries shares. Landing a
    ///         stack there would permanently occupy the addresses its `deployOiv` needs.
    /// @param  chainId The offending destination.
    error SharesChainNotAStackDestination(uint256 chainId);

    /// @notice Thrown when `promoteShares` is called on a chain the topology already declares. Use
    ///         `deployLocal` there — promotion would bypass the asset the topology committed to.
    error SharesChainAlreadyDeclared();

    /// @notice Thrown when `promoteShares` is called before the Avatar Safe has approved the shares
    ///         proxy for the base asset. Promotion cannot grant that approval itself, and a promoted
    ///         fund is immediately subscribable while redemption settlement would revert — so the
    ///         approval is required FIRST rather than left as a follow-up someone might not make.
    /// @param  asset The base asset whose allowance is missing.
    error ApprovalNotGranted(address asset);

    /// @notice Thrown when a fund declares more than one shares chain AND any `additionalAssets`.
    /// @dev    Those asset addresses are chain-specific but salt-bound, and `SharesChain` has no
    ///         field to express them per chain — so the fund could not be deployed on its second
    ///         shares chain by any means. Lifting this needs the topology to carry the additional
    ///         assets too, which would change every fund address.
    error AdditionalAssetsNeedASingleSharesChain();

    /// @notice Thrown when an explicit destination list names the same chain twice. The duplicate
    ///         would be priced and dispatched twice, spending a second non-refundable fee on a
    ///         message whose delivery reverts.
    error DuplicateDestination(uint256 chainId);

    /// @notice Thrown when `promoteShares` is called by anyone other than the fund's `admin` or its
    ///         exec timelock. The base asset is the one field the salt deliberately does not bind, so
    ///         an open promotion would let anyone holding the true config land a hostile-denominated
    ///         shares token at the fund's canonical address.
    /// @param  caller The rejected caller.
    error NotFundAdmin(address caller);

    /// @notice Thrown by `ccipReceive` when an inbound stack targets a chain this fund's topology
    ///         reserves for shares — the receiver-side half of the same guard.
    error SharesChainRefusesStack();
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
            // Correcting an existing entry: the old selector stops being a trusted source — but only
            // if no OTHER live chain id still maps to it. Clearing unconditionally silently stopped a
            // lane the registry still advertises from accepting inbound stacks.
            _forgetSelectorIfUnused(chainSelectorOf[chainId], chainId);
        }
        // Two chain ids must never share a selector. `_stackSelectors` and `_resolveStackSelectors`
        // emit one destination per CHAIN ID, so a shared selector means two paid messages to the same
        // chain: the first deploys, the second reverts `StackAlreadyDeployedHere`, and its fee is
        // spent either way. `_forgetSelectorIfUnused` already treated this as a reachable state —
        // it is now unreachable instead. The scan is over the registry (tens of entries) and runs
        // only on the constructor and owner `configure` paths.
        uint256 n = _chainIds.length;
        for (uint256 i = 0; i < n; i++) {
            uint256 other = _chainIds[i];
            if (other != chainId && chainSelectorOf[other] == ccipChainSelector) {
                revert SelectorAlreadyMapped(ccipChainSelector, other);
            }
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
    ///      `keccak256(abi.encode(config-with-zeroed-base-asset, sharesChains))` — see
    ///      `_effectiveConfig` — composed once on the origin chain and shipped, so the origin never
    ///      entered the derivation. (This line described the pre-topology
    ///      `keccak256(abi.encode(config))` until now, omitting both the zeroed asset and the
    ///      topology that is part of fund identity.) A fund fanned out from Base lands at exactly the
    ///      addresses it would have from Ethereum.
    ///
    ///      The check that remains is worth keeping: fanning out from a chain absent from the
    ///      registry would produce messages every sibling rejects, after the fees were already paid.
    ///
    ///      It is applied ONLY to the CCIP-emitting entry points. `deployLocal` and `promoteShares`
    ///      make no CCIP call at all, and gating them here would have blocked them on exactly the
    ///      chains they exist to serve: the registry is baked at construction, so an orchestrator on a
    ///      chain onboarded later does not contain its own id, and `promoteShares` — whose whole
    ///      purpose is a chain nobody could have declared in advance — would have needed an owner
    ///      `setChainSelector` transaction first. That is the pre-handover seeding step this design
    ///      retired, resurfacing.
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
        // Retiring a lane must also stop it being an accepted CCIP source, not merely a destination —
        // unless another live chain id still maps to the same selector.
        _forgetSelectorIfUnused(chainSelectorOf[chainId], chainId);
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
    /// @param gasLimit       Destination `ccipReceive` gas limit. Measured 2026-09-04 on this
    ///                       branch: `deployStack` ~1.58M, ~1.95M with an exec timelock, and the
    ///                       destination pays for the whole `ccipReceive` frame around that (payload
    ///                       decode, the shares-chain loop, event).
    ///
    ///                       Those figures were measured on a SMALL timelock role set, and the
    ///                       "at least 2.5M" floor they justified is wrong for a fund at
    ///                       `KpkTimelockDeployer.MAX_ROLE_MEMBERS`: `deployStack` alone then costs
    ///                       2,608,449 with one manager owner and 2,778,274 at
    ///                       `MAX_CCIP_MANAGER_OWNERS`, plus ~80k for the frame, against a 3M cap.
    ///                       **Pass 3,000,000 for any timelocked fund**; 2.0M remains ample for a
    ///                       fund with no exec timelock (~1.58M measured). This function bounds the
    ///                       owner count but NOT `gasLimit`, so an under-size is caught by nothing
    ///                       here and is not refundable.
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
        // Sugar for the single-shares-chain case: this chain carries the shares, every other wired
        // chain gets a stack. Matches the semantics this overload always had.
        //
        // WARNING: the topology is inside the salt, so calling this from a different chain describes a
        // DIFFERENT fund at different addresses — not the same fund homed elsewhere.
        SharesChain[] memory local = _localTopology(config);
        return _deployEverywhere(
            _effectiveConfig(config, local),
            _stackSelectors(local),
            _sharesChainIds(local),
            config.sharesParams.asset,
            config.sharesParams.asset,
            gasLimit
        );
    }

    /// @notice Deploys the fund on this chain and fans stacks out to every wired chain that does NOT
    ///         carry shares.
    /// @dev    Shares chains are skipped rather than messaged: a stack landing on one would take the
    ///         addresses its own `deployOiv` needs, permanently. Each additional shares chain is
    ///         filled by its own `deployLocal` call — shares never travel over CCIP, because
    ///         `deployOiv` measures at ~2.88M gas against a 3,000,000 destination cap on half the
    ///         lanes, which one extra timelock member would erase.
    /// @param  config       Fund parameters. `sharesParams.asset` must match what `sharesChains` names
    ///                      for this chain, if this chain carries shares.
    /// @param  sharesChains The fund's topology, strictly ascending by chain id. Declaring a chain is
    ///                      not free: a declared chain is skipped by this fan-out and refuses inbound
    ///                      stacks, so it is shares-or-nothing until its own `deployOiv` runs. Declare
    ///                      the chains you intend to use — `promoteShares` covers the ones you could
    ///                      not have known about.
    /// @param  gasLimit     Destination `ccipReceive` gas limit.
    function deployEverywhere(
        KpkOivFactory.OivConfig calldata config,
        SharesChain[] calldata sharesChains,
        uint256 gasLimit
    )
        external
        payable
        nonReentrant
        onlyWiredChain
        returns (KpkOivFactory.OivInstance memory instance, bytes32[] memory messageIds)
    {
        _validateSharesChains(sharesChains);
        return _deployEverywhere(
            _effectiveConfig(config, sharesChains),
            _stackSelectors(sharesChains),
            _sharesChainIds(sharesChains),
            _assetFor(sharesChains, block.chainid),
            config.sharesParams.asset,
            gasLimit
        );
    }

    /// @notice Same as `deployEverywhere(config, gasLimit)` but fans out only to the given `destChainIds`
    ///         (each resolved via `chainSelectorOf`; an unconfigured id reverts `UnknownChain`; the
    ///         local chain, if present, is skipped). Structural preconditions are enforced once inside
    ///         `_deployEverywhere`, matching the no-array overload.
    /// @notice As above, but to an explicit destination subset — for a partial or retried rollout.
    /// @dev    Naming a shares chain here reverts `SharesChainNotAStackDestination` rather than being
    ///         silently skipped: in an explicit list it is a caller error worth surfacing.
    function deployEverywhere(
        KpkOivFactory.OivConfig calldata config,
        SharesChain[] calldata sharesChains,
        uint256[] calldata destChainIds,
        uint256 gasLimit
    )
        external
        payable
        nonReentrant
        onlyWiredChain
        returns (KpkOivFactory.OivInstance memory instance, bytes32[] memory messageIds)
    {
        _validateSharesChains(sharesChains);
        return _deployEverywhere(
            _effectiveConfig(config, sharesChains),
            _resolveStackSelectors(destChainIds, sharesChains),
            _sharesChainIds(sharesChains),
            _assetFor(sharesChains, block.chainid),
            config.sharesParams.asset,
            gasLimit
        );
    }

    /// @notice Deploys this chain's part of the fund with no CCIP at all — the shares token if this
    ///         chain carries it, the operational stack otherwise.
    /// @dev    This is what makes a SECOND shares chain reachable: the fan-out deliberately skips
    ///         shares chains, so each one is filled by its own call here. Permissionless and
    ///         idempotent in effect — anyone may run it, ordering against the fan-out is irrelevant,
    ///         and because the whole config is salt-bound the result is byte-identical whoever pays.
    /// @param  config       Fund parameters, with this chain's base asset.
    /// @param  sharesChains The same topology used everywhere else for this fund.
    function deployLocal(KpkOivFactory.OivConfig calldata config, SharesChain[] calldata sharesChains)
        external
        nonReentrant
        returns (KpkOivFactory.OivInstance memory instance)
    {
        _validateSharesChains(sharesChains);
        KpkOivFactory.OivConfig memory eff = _effectiveConfig(config, sharesChains);
        address expected = _assetFor(sharesChains, block.chainid);

        if (expected == address(0)) {
            // Validate the WHOLE config, not just the half this branch deploys. The salt commits to
            // `feeReceiver`, the fee rates, the TTL and the shares timelock even on a chain that
            // carries no shares, so `deployStack` accepts a config whose shares half can never
            // deploy: every later shares-chain call reverts, and correcting the offending field
            // changes the salt and abandons this stack at addresses nothing can reuse. Same check
            // `_deployEverywhere` runs before either of its branches.
            factory.predictOivAddresses(eff, address(this));

            KpkOivFactory.StackInstance memory stack = factory.deployStack(factory.oivToStackConfig(eff));
            emit LocalStackDeployed(stack);
            // Populated rather than returned zeroed: a successful deploy that reports nine zero
            // addresses tells the operator nothing. The two shares fields stay zero, which is the
            // signal that this chain carries no shares.
            return _instanceFromStack(stack);
        }

        if (expected != config.sharesParams.asset) revert AssetMismatch(expected, config.sharesParams.asset);
        instance = factory.deployOiv(eff);
        emit LocalOivDeployed(instance);
    }

    /// @dev Local full OIV (`msg.sender` to the factory is this orchestrator — the uniform caller on
    ///      every chain, so all addresses align) then CCIP fan-out. `config` is already the
    ///      config-bound-salt `_effectiveConfig`. The fee is priced and checked against `msg.value`
    ///      BEFORE the (~7M-gas) deployOiv, so an underfunded call fails fast without burning it.
    /// @dev The local half is `deployOiv` when this chain carries shares and `deployStack` when it
    ///      does not, so a fan-out started from a stack-only chain is still coherent.
    function _deployEverywhere(
        KpkOivFactory.OivConfig memory config,
        uint64[] memory destSelectors,
        uint256[] memory sharesChainIds,
        address expectedAsset,
        address suppliedAsset,
        uint256 gasLimit
    ) internal returns (KpkOivFactory.OivInstance memory instance, bytes32[] memory messageIds) {
        if (destSelectors.length == 0) revert NoDestinations();

        // Validate the WHOLE config before pricing, whichever branch runs locally. The stack branch
        // below calls `deployStack`, which validates only the stack half — yet the shares half is
        // salt-bound, so a fan-out originating from a stack-only chain with (say) a zero
        // `feeReceiver` would land every remote stack, spend every non-refundable fee, and only then
        // fail on the first `deployLocal`. Correcting the field afterwards changes the salt, so every
        // stack already landed is orphaned. `predictOivAddresses` validates exactly what `deployOiv`
        // would, which is the same pre-check `dispatchTo` uses.
        factory.predictOivAddresses(config, address(this));

        (Client.EVM2AnyMessage memory message, uint256 totalFee, uint256[] memory fees) =
            _price(config, destSelectors, sharesChainIds, gasLimit);
        if (msg.value < totalFee) revert InsufficientFee(totalFee, msg.value);

        if (expectedAsset == address(0)) {
            KpkOivFactory.StackInstance memory stack = factory.deployStack(factory.oivToStackConfig(config));
            emit LocalStackDeployed(stack);
            instance = _instanceFromStack(stack);
        } else {
            if (expectedAsset != suppliedAsset) revert AssetMismatch(expectedAsset, suppliedAsset);
            instance = factory.deployOiv(config);
            emit LocalOivDeployed(instance);
        }

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
    ///         at the fund's existing operational addresses. A destination whose stack is already
    ///         WIRED reverts `KpkOivFactory.StackAlreadyDeployedHere` when its message executes, so
    ///         do not re-dispatch to a completed chain — the source-chain fee is spent either way.
    ///         A destination where only some components exist is fine: the factory adopts them.
    function dispatchTo(
        KpkOivFactory.OivConfig calldata config,
        SharesChain[] calldata sharesChains,
        uint256[] calldata destChainIds,
        uint256 gasLimit
    ) external payable nonReentrant onlyWiredChain returns (bytes32[] memory messageIds) {
        _validateSharesChains(sharesChains);
        uint64[] memory destSelectors = _resolveStackSelectors(destChainIds, sharesChains);
        if (destSelectors.length == 0) revert NoDestinations();

        KpkOivFactory.OivConfig memory eff = _effectiveConfig(config, sharesChains);
        // Validate the timelock configuration HERE, on the source chain, before a single fee is
        // spent. Unlike `deployEverywhere`, `dispatchTo` runs no local `deployOiv`, so nothing on
        // this chain otherwise looks at `execTimelock` — a proposer array that is not strictly
        // ascending (a reformatted or regenerated config reorders it easily), a `minDelay` outside
        // the deployer's band, or a canceller that is also a proposer all sail through here, every
        // lane's non-refundable fee is paid, and every destination reverts inside
        // `KpkTimelockDeployer._validate`.
        //
        // `predictOivAddresses`, not `predictStackAddresses`. The narrower check validates exactly
        // what this function SENDS, which is what an earlier version of this comment argued for —
        // but the fund's identity is wider than its payload. The effective salt commits to
        // `feeReceiver`, the fee rates, the TTL and the shares timelock, so dispatching first with
        // one of those invalid lands every destination stack successfully and leaves a fund whose
        // shares chains can never complete; correcting the field moves the salt and orphans every
        // stack just paid for. It costs a wired shares mastercopy on the SOURCE chain, which every
        // onboarded chain has.
        factory.predictOivAddresses(eff, address(this));

        (Client.EVM2AnyMessage memory message, uint256 totalFee, uint256[] memory fees) =
            _price(eff, destSelectors, _sharesChainIds(sharesChains), gasLimit);
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
        SharesChain[] memory local = _localTopology(config);
        (, totalFee, feePerDestination) =
            _price(_effectiveConfig(config, local), _stackSelectors(local), _sharesChainIds(local), gasLimit);
    }

    /// @notice Same, for an explicit subset of `destChainIds` — matches the 3-arg `deployEverywhere`.
    function quoteDeployEverywhere(
        KpkOivFactory.OivConfig calldata config,
        SharesChain[] calldata sharesChains,
        uint256 gasLimit
    ) external view returns (uint256 totalFee, uint256[] memory feePerDestination) {
        _validateSharesChains(sharesChains);
        (, totalFee, feePerDestination) = _price(
            _effectiveConfig(config, sharesChains),
            _stackSelectors(sharesChains),
            _sharesChainIds(sharesChains),
            gasLimit
        );
    }

    /// @notice Fee quote for an explicit destination subset.
    function quoteDeployEverywhere(
        KpkOivFactory.OivConfig calldata config,
        SharesChain[] calldata sharesChains,
        uint256[] calldata destChainIds,
        uint256 gasLimit
    ) external view returns (uint256 totalFee, uint256[] memory feePerDestination) {
        _validateSharesChains(sharesChains);
        (, totalFee, feePerDestination) = _price(
            _effectiveConfig(config, sharesChains),
            _resolveStackSelectors(destChainIds, sharesChains),
            _sharesChainIds(sharesChains),
            gasLimit
        );
    }

    /// @notice Predicts the seven fund addresses a `deployEverywhere`/`dispatchTo` for `config` would
    ///         produce, using the SAME config-bound salt the deploy path uses (`_effectiveConfig`).
    ///         Off-chain callers MUST use this rather than the factory's raw `predictOivAddresses`,
    ///         which would key on the un-derived `config.salt`.
    function predictOiv(KpkOivFactory.OivConfig calldata config, SharesChain[] calldata sharesChains)
        external
        view
        returns (KpkOivFactory.OivInstance memory)
    {
        _validateSharesChains(sharesChains);
        return factory.predictOivAddresses(_effectiveConfig(config, sharesChains), address(this));
    }

    /// @dev Single source of truth for fee computation: builds the (loop-invariant) CCIP message once
    ///      and prices it per destination. Shared by `quoteDeployEverywhere`, `deployEverywhere` and
    ///      `dispatchTo` so the quoted and charged fees can never drift. The `StackConfig` payload comes
    ///      from `factory.oivToStackConfig` so it also cannot drift from `deployOiv`'s mapping. Reverts
    ///      `NotConfigured` if the router is unset.
    /// @notice Upper bound on `managerSafe.owners` for anything sent over CCIP.
    /// @dev    `KpkTimelockDeployer.MAX_ROLE_MEMBERS` bounds the timelock arrays and was described as
    ///         making the largest ACCEPTED `deployStack` fit the 3M destination cap. It does not, on
    ///         its own: `managerSafe.owners` was unbounded and Safe setup does storage work per owner.
    ///         Measured 2026-09-23 on the worst timelock `MAX_ROLE_MEMBERS` permits, `deployStack`
    ///         alone costs
    ///
    ///             10 owners 2,824,669 | 15 owners 2,881,927 | 18 owners 2,954,033 | 20 owners 3,002,113
    ///
    ///         `_validateManagerOwners`' dedup used to be O(n^2) and this comment cited that as a
    ///         contributing cause. It is O(n) now, and the figures did not fall — at n=20 the
    ///         quadratic form was 190 comparisons, well inside the noise below. The per-owner Safe
    ///         storage work is the whole cost.
    ///
    ///         and the destination pays a further ~80k for the `ccipReceive` frame around it. So a
    ///         perfectly valid config with ~15 owners passes every source-side check, spends every
    ///         lane's non-refundable fee, and then runs out of gas on arrival. (Figures carry ~35k of
    ///         address-dependent storage noise; pinned by
    ///         `test_deployStack_worstPermittedConfigStillFitsTheCcipGasCap`.)
    ///
    ///         10 leaves roughly 140k of headroom. Bounded HERE rather than in the factory on
    ///         purpose: the 3M cap is a CCIP constraint, and a fund deployed directly on one chain
    ///         has no reason to be limited by it.
    uint256 public constant MAX_CCIP_MANAGER_OWNERS = 10;

    function _price(
        KpkOivFactory.OivConfig memory config,
        uint64[] memory destSelectors,
        uint256[] memory sharesChainIds,
        uint256 gasLimit
    ) internal view returns (Client.EVM2AnyMessage memory message, uint256 totalFee, uint256[] memory fees) {
        if (router == address(0)) revert NotConfigured();
        // Here, not only in the two deploy paths. The explicit-array quote resolves its own
        // selectors and never reached their `NoDestinations` check, so a `destChainIds` of `[]` — or
        // one naming only the local chain, which `_resolveStackSelectors` skips — quoted a fee of
        // ZERO while the matching `deployEverywhere` reverted. A quote that answers where execution
        // refuses is the wrong direction to disagree in: it reads as "this fan-out is free".
        if (destSelectors.length == 0) revert NoDestinations();
        // Every send AND every quote reaches this function, which is why the bound lives here: a
        // quote that cannot be delivered should fail loudly at quote time rather than return a fee
        // for a fan-out that dies on arrival.
        uint256 ownerCount = config.managerSafe.owners.length;
        if (ownerCount > MAX_CCIP_MANAGER_OWNERS) {
            revert ManagerOwnersExceedCcipBudget(ownerCount, MAX_CCIP_MANAGER_OWNERS);
        }
        // The topology rides along so every destination can refuse a stack aimed at a shares chain,
        // independently of the source having excluded it.
        message = _buildMessage(abi.encode(factory.oivToStackConfig(config), sharesChainIds), gasLimit);
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
    function ccipReceive(Client.Any2EVMMessage calldata message) external override nonReentrant {
        if (msg.sender != router) revert InvalidRouter(msg.sender);
        // Any chain in the registry may be a source, not just Ethereum. The registry is seeded at
        // construction with the same 19 chains everywhere, so every orchestrator accepts every other
        // one and a fan-out can be initiated from any of them.
        //
        // The load-bearing guard is the sender check below, not this one: only a contract at THIS
        // address can be the source sender, and that address is a deterministic function of the
        // orchestrator's creation code. This check narrows it further, to the chains we actually
        // wired — without it, anyone could CREATE2 the same bytecode on any CCIP-supported chain and
        // send from there.
        //
        // Two earlier versions of this comment were wrong, in opposite directions. The first claimed
        // the blast radius was bounded because "a forged message can only do what any caller can
        // already do directly". The correction over-reached: it said a direct caller can NEVER reach
        // orchestrator-derived addresses because `_deriveSalts` mixes `msg.sender`. That holds only
        // for the shares impl and proxy, which the factory CREATE2s itself. The Avatar Safe, Manager
        // Safe and three Roles Modifiers are deployed by the permissionless third-party
        // `safeProxyFactory` / `moduleProxyFactory`, whose salts are `keccak256(keccak256(initializer),
        // nonce)` — public functions of the config — so anyone can land those five addresses.
        //
        // What the guards below actually buy: the sender check stops a forged message entirely, and
        // the shares-chain refusal stops a GENUINE sibling being used to occupy a fund's addresses.
        // Third-party squatting of those five addresses is no longer a denial — `KpkOivFactory`
        // ADOPTS pristine components instead of colliding with them (see `_deployRolesModifier`),
        // which is sound because CREATE2 binds each address to the factory's own initializer. What
        // it refuses is a stack that has already been wired.
        if (!_isKnownSelector[message.sourceChainSelector]) {
            revert InvalidSourceChain(message.sourceChainSelector);
        }
        // By the same-address-on-every-chain property, the trusted source sender is this very
        // address — the sibling orchestrator on whichever chain initiated.
        address sourceSender = abi.decode(message.sender, (address));
        if (sourceSender != address(this)) revert InvalidSourceSender(sourceSender);

        (KpkOivFactory.StackConfig memory stackConfig, uint256[] memory sharesChainIds) =
            abi.decode(message.data, (KpkOivFactory.StackConfig, uint256[]));

        // The receiver-side half of the shares-chain guard, and the reason this is not merely
        // belt-and-braces: the fan-out that excludes shares chains runs on the SOURCE, and any wired
        // chain may now be a source. Without this, anyone who knew a fund's config could dispatch a
        // stack at the chain meant to run `deployOiv`, permanently occupying the addresses that fund
        // needs — a fund config denied forever, recoverable only by changing the config and moving
        // every address on every chain.
        for (uint256 i = 0; i < sharesChainIds.length; i++) {
            if (sharesChainIds[i] == block.chainid) revert SharesChainRefusesStack();
        }

        // IDEMPOTENT, and this is a security fix rather than a convenience. `deployLocal` is
        // permissionless and the orchestrator is the factory's uniform `msg.sender`, so any stranger
        // holding a fund's config — which is public in the victim's own calldata — can land that
        // fund's fully WIRED stack on a destination chain before delivery arrives. A strict
        // `deployStack` then reverts `StackAlreadyDeployedHere`, CCIP manual re-execution replays the
        // same revert for ever, and every lane's non-refundable fee is lost. Destination gas on an L2
        // is cheap relative to the source fee for a 3M-gas execution, so the economics favoured the
        // griefer. (Distinct from third-party occupation through the Safe/Zodiac factories, which the
        // factory ADOPTS: that lands unwired components, and a wired stack is the one state adoption
        // refuses.)
        //
        // Treating "already there" as success is sound because the pre-wired stack is not merely at
        // the right addresses, it IS this fund's stack: the salt binds the whole config, and the one
        // field left out — the base asset — is not used by the stack half at all. A griefer cannot
        // wire different owners or a different admin at these addresses without changing the salt and
        // therefore the addresses. The destination ends in exactly the state the message asked for.
        //
        // It also makes an honest duplicate delivery succeed instead of failing.
        // Structured so the HAPPY path pays nothing for it — which is also why the catch branch's
        // owner assert below is free. Predicting first, unconditionally, cost ~108k on every delivery
        // and pushed the worst permitted config from 2,862,999 to 2,970,960 against the 3,000,000 cap
        // — measured, and it failed an at-the-cap delivery outright. The already-wired case is the
        // rare one, so it is the one that should pay.
        //
        // Worst permitted frame, measured 2026-09-23 by `test/poc/CcipDestinationBudget.t.sol`:
        // 2,868,869, i.e. 131,131 of headroom. `nonReentrant` on this function accounts for 5,154 of
        // that; the catch branch accounts for none of it.
        try factory.deployStack(stackConfig) returns (KpkOivFactory.StackInstance memory inst) {
            emit StackReceived(message.sourceChainSelector, message.messageId, inst);
        } catch (bytes memory err) {
            // ONLY `StackAlreadyDeployedHere` is absorbed. Everything else — including an
            // out-of-gas, which returns empty data and therefore cannot match — is re-thrown with its
            // original revert data, so no other failure is masked by this.
            bytes4 reason;
            if (err.length >= 4) {
                assembly {
                    reason := mload(add(err, 0x20))
                }
            }
            if (reason != KpkOivFactory.StackAlreadyDeployedHere.selector) {
                assembly {
                    revert(add(err, 0x20), mload(err))
                }
            }
            // Already present — but NOT necessarily in the state the message asked for, and an
            // earlier version of this comment claimed the opposite ("necessarily THIS fund's stack
            // ... nobody can wire different owners or a different admin at these addresses without
            // changing the salt"). That is false for the one field that matters here: the five stack
            // addresses derive from `(salt, manager owners, threshold)`, and `execRolesMod.finalOwner`
            // is NOT among them. So a stack can sit at exactly these addresses under DIFFERENT exec
            // governance than the payload describes, and absorbing the revert then reported a capture
            // as a success, emitting `StackReceived` with the message's governance rather than the
            // owner actually in place. That silence is what made it covert: the fund extends here
            // later, sees a green delivery, and nobody reads `owner()`.
            //
            // So verify the one thing the addresses do not pin. If the present exec modifier is owned
            // by someone other than the governance this message describes, re-throw the original
            // `StackAlreadyDeployedHere` — a FAILED lane is the correct outcome, because the
            // destination is genuinely not in the requested state.
            //
            // This removes the silence, not the capture. The root causes are upstream — a re-callable
            // `configure` and `finalOwner` not being salt-bound — and the precondition is the
            // orchestrator owner or a compromised router, so this is a trusted-role escalation with a
            // covert path rather than an external-attacker hole.
            KpkOivFactory.StackInstance memory present = factory.predictStackAddresses(stackConfig, address(this));
            // A timelocked stack's modifier is owned by the timelock, not by `finalOwner` directly —
            // `predictStackAddresses` fills in `execTimelock` exactly when `minDelay != 0`, which is
            // the same condition `deployStack` wires on.
            address expectedOwner = present.execTimelock == address(0)
                ? stackConfig.execRolesMod.finalOwner
                : present.execTimelock;
            if (IRoles(present.execRolesModifier).owner() != expectedOwner) {
                assembly {
                    revert(add(err, 0x20), mload(err))
                }
            }
            emit StackReceived(message.sourceChainSelector, message.messageId, present);
        }
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
    function _effectiveConfig(KpkOivFactory.OivConfig calldata config, SharesChain[] memory sharesChains)
        internal
        pure
        returns (KpkOivFactory.OivConfig memory eff)
    {
        eff = config;

        // The base asset is the one field the TOPOLOGY can express per chain, so hashing it verbatim
        // made the same config file produce different addresses on different chains — silently
        // breaking the invariant this whole design exists to provide. It is zeroed for the hash and
        // committed to through `sharesChains` instead, which is identical everywhere.
        //
        // Everything else stays bound verbatim, and that is deliberate: a salt that omitted
        // `sharesParams` would let anyone replay this fund at its CANONICAL addresses with a hostile
        // `feeReceiver`, hostile fee rates, or no `sharesTimelock`. Binding the whole config is what
        // keeps a hostile replay an availability problem rather than a capture of the fund's economics.
        //
        // The factory now commits to the shares half in its OWN proxy salt too
        // (`KpkOivFactory._deriveSharesSalt`), which closed the direct-path drain this comment used to
        // describe as unreachable from here. These are two independent bindings of the same fields, not
        // one made redundant by the other: this one covers the orchestrator's cross-chain salt, that one
        // covers a direct `deployShares` against an already-live stack, and neither implies the other.
        // `additionalAssets[i].asset` is just as chain-specific as the base asset, and unlike the
        // base asset the topology has nowhere to put it — `SharesChain` carries one address per
        // chain. It therefore stays in the salt, which makes the combination undeployable rather
        // than merely awkward: on a second shares chain you must either pass that chain's token
        // (a different salt, so `deployLocal` silently builds a SEPARATE fund at non-canonical
        // addresses) or the first chain's token (codeless there, so `updateAsset`'s `symbol()` call
        // and `_grantApprovals`' `approve` both revert). Refused here rather than discovered after
        // the fan-out has spent every lane's fee. A single shares chain is unaffected.
        if (sharesChains.length > 1 && config.additionalAssets.length != 0) {
            revert AdditionalAssetsNeedASingleSharesChain();
        }

        // `_validateOivConfig`'s duplicate check compares `additionalAssets` against
        // `config.sharesParams.asset` — the ONE field deliberately left out of the salt because it
        // differs per chain. On a stack-only origin that field holds whatever this chain resolves to,
        // not what the topology commits the fund's shares chain to, so the check runs against an
        // asset the fund will never use.
        //
        // Concretely: topology says Gnosis/DAI, `additionalAssets` contains DAI, origin is mainnet
        // where the field falls back to USDC. `USDC != DAI` passes, every lane's non-refundable fee
        // is spent, every stack lands — and then Gnosis forces the asset to DAI (`AssetMismatch`
        // otherwise) and `deployOiv` reverts `DuplicateAsset` forever. No value of the one field the
        // caller may still vary helps, and `additionalAssets` is salt-bound, so correcting it moves
        // every address and orphans every stack already paid for.
        //
        // Checked here because `_effectiveConfig` is the choke point every entry point passes
        // through, so the failure lands before the first fee instead of after the last.
        for (uint256 i = 0; i < config.additionalAssets.length; i++) {
            for (uint256 j = 0; j < sharesChains.length; j++) {
                if (config.additionalAssets[i].asset == sharesChains[j].asset) {
                    revert KpkOivFactory.DuplicateAsset();
                }
            }
        }

        eff.sharesParams.asset = address(0);
        eff.salt = uint256(keccak256(abi.encode(eff, sharesChains)));
        eff.sharesParams.asset = config.sharesParams.asset;
    }

    /// @notice Adds this fund's shares token to a chain its topology does NOT declare, without moving
    ///         a single address.
    /// @dev    The escape hatch for the one thing the salt-bound topology cost us: a fund could not
    ///         gain a shares chain after birth, because the topology is hashed into the salt.
    ///         "Declare generously" was the mitigation and it has real limits — it cannot cover a
    ///         chain that does not exist yet, nor one whose dominant stablecoin is unknowable today,
    ///         and a declared chain is shares-or-nothing until its `deployOiv` runs.
    ///
    ///         Promotion reuses the ORIGINAL topology and therefore the original salt, so the promoted
    ///         shares token lands at the same address as every other shares chain's. See
    ///         `KpkOivFactory.deployShares` for why the slot is free and why approvals are deferred.
    ///
    ///         WHY THIS IS GATED, when everything else here is permissionless. `_effectiveConfig`
    ///         zeroes `sharesParams.asset` before hashing, because it legitimately differs per chain.
    ///         For declared chains the topology commits to each one's asset, so nothing is unbound.
    ///         A promoted chain has no such commitment — the asset is free — so an open promotion
    ///         would let anyone holding the true config deploy a shares token denominated in a
    ///         worthless asset at the fund's canonical address. That is the same economic-capture
    ///         failure that ruled out narrowing the salt, shrunk to one field. `config.admin` is
    ///         salt-bound, so forging it produces a different salt and a different address: the gate
    ///         cannot be sidestepped by lying about who the admin is.
    ///
    ///         The exec timelock is accepted as an alternate caller because it exists at the fund's
    ///         canonical address on EVERY stack chain (`deployStack` deploys it), which covers funds
    ///         whose `admin` is a contract that only exists on one chain.
    /// @param  config       Fund parameters, with THIS chain's base asset and the original salt.
    /// @param  sharesChains The fund's ORIGINAL topology — the same array used at birth.
    /// @return instance     The fund's addresses on this chain.
    function promoteShares(KpkOivFactory.OivConfig calldata config, SharesChain[] calldata sharesChains)
        external
        nonReentrant
        returns (KpkOivFactory.OivInstance memory instance)
    {
        _validateSharesChains(sharesChains);
        if (_assetFor(sharesChains, block.chainid) != address(0)) revert SharesChainAlreadyDeclared();
        // `additionalAssets` entries are salt-bound, so their addresses are fixed at birth and cannot
        // be restated per chain the way the base asset can. On the promoted chain they are therefore
        // whatever address the original chain used, which usually has no code there — and the
        // resulting failure was a bare revert on undecodable empty returndata: a `canRedeem` entry
        // dies in the allowance loop below, a deposit-only entry survives as far as
        // `KpkShares._updateAsset`'s `symbol()` call and dies there.
        //
        // Not refused outright, because a token deployed at the SAME address on both chains is
        // legitimate and promotion should still work for it — `_effectiveConfig`'s
        // `AdditionalAssetsNeedASingleSharesChain` bans the multi-chain TOPOLOGY case, which is
        // different: there the asset cannot be expressed per chain at all. Checked for every entry,
        // not just `canRedeem` ones, because `_updateAsset` calls `symbol()` on all of them.
        for (uint256 i = 0; i < config.additionalAssets.length; i++) {
            address extra = config.additionalAssets[i].asset;
            if (extra.code.length == 0) revert AdditionalAssetHasNoCodeHere(extra);
        }

        KpkOivFactory.OivConfig memory eff = _effectiveConfig(config, sharesChains);

        if (msg.sender != config.admin) {
            KpkOivFactory.StackInstance memory stack =
                factory.predictStackAddresses(factory.oivToStackConfig(eff), address(this));
            if (stack.execTimelock == address(0) || msg.sender != stack.execTimelock) {
                revert NotFundAdmin(msg.sender);
            }
        }

        // The approval must already exist, because promotion cannot grant it and the intermediate
        // state is NOT harmless: `requestSubscription` has no admin, operator or pause gate and pulls
        // from the investor, so a promoted fund takes deposits at once — while redemption settlement
        // pulls from the Avatar Safe and reverts on a zero allowance. An investor could therefore be
        // settled into the Safe and left unable to redeem until an off-chain admin transaction
        // landed. The proxy address is predictable before promotion, so the admin can approve first
        // and there is no window at all. Documented as "deferred" previously; requiring it here is
        // what actually closes the gap.
        KpkOivFactory.OivInstance memory predicted = factory.predictOivAddresses(eff, address(this));
        // Checked here as well as in the factory so the more fundamental failure reports first: on a
        // chain with no stack at all, "no approval" would be a confusing thing to be told.
        if (predicted.avatarSafe.code.length == 0) revert KpkOivFactory.StackNotDeployed();
        // MAXIMUM, not merely non-zero: `_grantApprovals` sets `type(uint256).max` on a normal
        // deployment and asserts it, so anything less here would let a promoted fund settle a few
        // redemptions and then start reverting — a slower version of the failure this prevents.
        if (
            IERC20(config.sharesParams.asset).allowance(predicted.avatarSafe, predicted.kpkSharesProxy)
                != type(uint256).max
        ) {
            revert ApprovalNotGranted(config.sharesParams.asset);
        }
        // The base asset is not the only one redemption can pull. `deployShares` registers every
        // entry in `additionalAssets` but grants no allowances at all (only `deployOiv` calls
        // `_grantApprovals`), and settlement transfers `request.asset` — any asset registered with
        // `canRedeem` — out of the Avatar Safe. Checking only the base asset would leave exactly the
        // hole this precondition exists to close, one asset over.
        for (uint256 i = 0; i < config.additionalAssets.length; i++) {
            if (!config.additionalAssets[i].canRedeem) continue;
            address redeemable = config.additionalAssets[i].asset;
            if (IERC20(redeemable).allowance(predicted.avatarSafe, predicted.kpkSharesProxy) != type(uint256).max) {
                revert ApprovalNotGranted(redeemable);
            }
        }

        instance = factory.deployShares(eff);
        emit SharesPromoted(block.chainid, instance);
    }

    /// @dev Widens a `StackInstance` into the `OivInstance` shape the entry points return, leaving the
    ///      two shares fields zero as the "this chain carries no shares" signal.
    function _instanceFromStack(KpkOivFactory.StackInstance memory stack)
        internal
        pure
        returns (KpkOivFactory.OivInstance memory instance)
    {
        instance = KpkOivFactory.OivInstance({
            avatarSafe: stack.avatarSafe,
            managerSafe: stack.managerSafe,
            execRolesModifier: stack.execRolesModifier,
            subRolesModifier: stack.subRolesModifier,
            managerRolesModifier: stack.managerRolesModifier,
            kpkSharesImpl: address(0),
            kpkSharesProxy: address(0),
            execTimelock: stack.execTimelock,
            sharesTimelock: address(0)
        });
    }

    /// @dev The single-shares-chain topology the 2-arg overloads imply, VALIDATED like any other.
    ///
    ///      Skipping validation here was not cosmetic. `_assetFor` returns `address(0)` both for "this
    ///      chain carries no shares" and for "the declared asset is zero", and only
    ///      `_validateSharesChains` separates them. Unvalidated, a config with a zero
    ///      `sharesParams.asset` took the stack branch: 18 non-refundable CCIP messages went out, no
    ///      fund was created, and the salt was derived from a topology that validation rejects — so
    ///      neither `deployLocal` nor `promoteShares` could ever re-derive it. The fund was
    ///      unrecoverable. Pinned by `test_deployEverywhere_sugarRejectsAZeroBaseAsset`.
    function _localTopology(KpkOivFactory.OivConfig calldata config) internal view returns (SharesChain[] memory t) {
        t = new SharesChain[](1);
        t[0] = SharesChain({chainId: block.chainid, asset: config.sharesParams.asset});
        _validateSharesChains(t);
    }

    /// @dev Rejects a topology that is unordered, degenerate, or would make one fund's addresses
    ///      ambiguous. Strictly ascending by `chainId` gives one canonical encoding per topology and
    ///      kills duplicates in the same pass.
    /// @notice Upper bound on topology length.
    /// @dev    `sharesChainIds` rides in the CCIP payload and is decoded and looped in
    ///         `ccipReceive`, so it spends destination gas like the other two bounded arrays —
    ///         measured at ~290 gas per entry, with roughly 480 entries enough to exhaust the
    ///         3,000,000 cap alongside a worst-case stack. Not a third-party hazard, because the
    ///         topology is salt-bound and a bloated one describes only the sender's own fund; bounded
    ///         because it was the one member of the family (`MAX_CCIP_MANAGER_OWNERS`,
    ///         `KpkTimelockDeployer.MAX_ROLE_MEMBERS`) left open. 20 sits above the 19 wired chains.
    uint256 public constant MAX_SHARES_CHAINS = 20;

    function _validateSharesChains(SharesChain[] memory sharesChains) internal pure {
        // A bare loop accepts a zero-length array by doing nothing, so every one of this function's
        // call sites — including three public `deployEverywhere` overloads — took `[]` as valid.
        // None of them has a legitimate empty case: `promoteShares` wants the topology the fund was
        // born with, and `effectiveSalt`'s own comment says validation exists so the helper cannot
        // answer for a topology no deployment can use.
        if (sharesChains.length == 0) revert EmptySharesChains();
        if (sharesChains.length > MAX_SHARES_CHAINS) {
            revert TooManySharesChains(sharesChains.length, MAX_SHARES_CHAINS);
        }

        uint256 previous;
        for (uint256 i = 0; i < sharesChains.length; i++) {
            uint256 chainId = sharesChains[i].chainId;
            if (chainId == 0 || sharesChains[i].asset == address(0)) revert InvalidSharesChain();
            if (chainId <= previous) revert SharesChainsNotAscending(chainId);
            previous = chainId;
        }
    }

    /// @dev Drops `selector` from the trusted-source set unless some chain id other than `except`
    ///      still maps to it. Two chain ids sharing a selector is a misconfiguration rather than a
    ///      normal state, but clearing unconditionally made it fail OPEN in the confusing direction:
    ///      a destination the registry still lists would quietly reject every inbound stack.
    function _forgetSelectorIfUnused(uint64 selector, uint256 except) private {
        if (selector == 0) return;
        uint256 n = _chainIds.length;
        for (uint256 i = 0; i < n; i++) {
            uint256 cid = _chainIds[i];
            if (cid != except && chainSelectorOf[cid] == selector) return;
        }
        _isKnownSelector[selector] = false;
    }

    /// @dev The asset the topology names for `chainId`, or `address(0)` if it carries no shares.
    function _assetFor(SharesChain[] memory sharesChains, uint256 chainId) internal pure returns (address) {
        for (uint256 i = 0; i < sharesChains.length; i++) {
            if (sharesChains[i].chainId == chainId) return sharesChains[i].asset;
        }
        return address(0);
    }

    /// @dev The chain ids alone, for the CCIP payload. Destinations need to know which chains are
    ///      reserved for shares; they have no use for the assets.
    function _sharesChainIds(SharesChain[] memory sharesChains) internal pure returns (uint256[] memory ids) {
        ids = new uint256[](sharesChains.length);
        for (uint256 i = 0; i < sharesChains.length; i++) {
            ids[i] = sharesChains[i].chainId;
        }
    }

    /// @dev Selectors for every configured chain id EXCEPT the local chain — so an all-chains fan-out
    ///      never tries to CCIP-message its own chain (which the router would reject). Reverts
    ///      `NoDestinations` if no remote chain is configured.
    /// @dev Every wired chain except the local one AND every shares chain. Shares chains are skipped
    ///      silently here — in the all-chains path their exclusion is the intended behaviour, not a
    ///      caller mistake. A stack landing on one would take the addresses its `deployOiv` needs.
    function _stackSelectors(SharesChain[] memory sharesChains) internal view returns (uint64[] memory selectors) {
        uint256 n = _chainIds.length;
        uint256 count;
        for (uint256 i = 0; i < n; i++) {
            uint256 cid = _chainIds[i];
            if (cid != block.chainid && _assetFor(sharesChains, cid) == address(0)) count++;
        }
        if (count == 0) revert NoDestinations();
        selectors = new uint64[](count);
        uint256 j;
        for (uint256 i = 0; i < n; i++) {
            uint256 cid = _chainIds[i];
            if (cid == block.chainid || _assetFor(sharesChains, cid) != address(0)) continue;
            selectors[j++] = chainSelectorOf[cid];
        }
    }

    /// @dev Resolves an EXPLICIT destination list, rejecting any shares chain. Unlike the all-chains
    ///      path this reverts rather than skipping: naming a shares chain by hand is a caller error,
    ///      and swallowing it would send a fund's rollout somewhere it can never complete.
    function _resolveStackSelectors(uint256[] calldata chainIds, SharesChain[] memory sharesChains)
        internal
        view
        returns (uint64[] memory selectors)
    {
        uint256 count;
        for (uint256 i = 0; i < chainIds.length; i++) {
            // The local chain is skipped BEFORE the shares check, preserving the long-standing "you
            // never CCIP-message your own chain" rule. It is normally also a shares chain, and
            // rejecting a caller for naming it would turn a harmless no-op into a revert.
            if (chainIds[i] == block.chainid) continue;
            if (_assetFor(sharesChains, chainIds[i]) != address(0)) {
                revert SharesChainNotAStackDestination(chainIds[i]);
            }
            // A repeated chain id would otherwise be priced and sent twice: the second fee is spent
            // non-refundably and its delivery reverts `StackAlreadyDeployedHere` on arrival. Rejected
            // rather than silently de-duplicated, because a duplicate in an explicit destination list
            // is a mistake in the list, and quietly accepting it hides the mistake.
            for (uint256 k = 0; k < i; k++) {
                if (chainIds[k] == chainIds[i]) revert DuplicateDestination(chainIds[i]);
            }
            count++;
        }
        selectors = new uint64[](count);
        uint256 j;
        for (uint256 i = 0; i < chainIds.length; i++) {
            if (chainIds[i] == block.chainid) continue;
            uint64 sel = chainSelectorOf[chainIds[i]];
            if (sel == 0) revert UnknownChain(chainIds[i]);
            selectors[j++] = sel;
        }
    }

    /// @dev The effective salt for a `(config, topology)` pair, exposed so off-chain tooling and tests
    ///      can check the derivation without reimplementing it. `view` only because `_effectiveConfig`
    ///      is; it reads no state.
    function effectiveSalt(KpkOivFactory.OivConfig calldata config, SharesChain[] calldata sharesChains)
        external
        view
        returns (uint256)
    {
        // Validated like every deploy and quote entry point. Without this the helper answers for
        // duplicate, unordered or zero-valued topologies that no deployment can ever use, which is
        // worse than not answering: the caller gets an address set that will never exist.
        _validateSharesChains(sharesChains);
        return _effectiveConfig(config, sharesChains).salt;
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
