// SPDX-License-Identifier: MIT
pragma solidity ^0.8;

// EIP-712 type hash for `IKpkSharesRouter.NavAttestation`.
//
// Frozen: the off-chain pricing service, the frontend and the test suite all hash against this exact
// string. Changing it invalidates every signature ever issued.
bytes32 constant NAV_ATTESTATION_TYPEHASH = keccak256(
    "NavAttestation(address fund,address asset,uint256 sharesPrice,uint256 navRound,uint64 issuedAt,uint64 validUntil)"
);

// EIP-712 type hash for `IKpkSharesRouter.RedemptionIntent`. Frozen for the same reason.
bytes32 constant REDEMPTION_INTENT_TYPEHASH = keccak256(
    "RedemptionIntent(address fund,address owner,address receiver,address asset,uint256 sharesIn,uint256 minAssetsOut,uint256 nonce,uint256 epoch,uint64 deadline)"
);

/// @title  IKpkSharesRouter
/// @author kpk
/// @notice Interface for the periphery router that creates and settles a `KpkShares` subscription or
///         redemption request in a single transaction.
/// @dev    The router holds the `OPERATOR` role on a single `KpkShares` proxy. Because it authors both
///         the request's own min-out bound and the settlement price, the audited per-request guards at
///         `kpkShares.sol:776` / `:856` pass at equality by construction and therefore provide no
///         protection to continuing shareholders. All such protection lives in this contract's
///         price-provenance checks: a mandatory EIP-712 attestation from a `NAV_SIGNER_ROLE` key,
///         absolute (non-walking) price bounds, monotonic NAV rounds, and volume caps.
interface IKpkSharesRouter {
    //
    // Errors
    //

    /// @notice Thrown when a zero address is supplied where a real address is required.
    error ZeroAddress();

    /// @notice Thrown when an amount argument is zero, or a bound would round the output to zero.
    error InvalidAmount();

    /// @notice Thrown when the asset is not enabled on this router for the attempted direction.
    error AssetNotEnabled(address asset);

    /// @notice Thrown when `receiver` is an address that must never receive shares or assets
    ///         (zero, the router, the shares proxy, the fee receiver, or the portfolio Safe).
    error InvalidReceiver(address receiver);

    /// @notice Thrown when an attestation or intent names a fund other than this router's.
    error FundMismatch(address expected, address supplied);

    /// @notice Thrown when the attestation's asset does not match the asset being transacted.
    error AssetMismatch(address expected, address supplied);

    /// @notice Thrown when the recovered attestation signer does not hold `NAV_SIGNER_ROLE`.
    error InvalidNavSigner(address recovered);

    /// @notice Thrown when the redemption intent signature does not verify for `intent.owner`.
    error InvalidIntentSignature();

    /// @notice Thrown when an attestation is used outside its `[issuedAt, validUntil]` window.
    error NavAttestationExpired(uint64 validUntil, uint256 nowTs);

    /// @notice Thrown when the *price* an attestation carries is older than `maxNavTtl`.
    /// @dev    Distinct from {NavAttestationExpired}, which bounds when a quote stops being usable.
    ///         This bounds how stale the price may be at the moment it is applied. Without it a quote
    ///         signed a week ago with a fresh `validUntil` would settle at a week-old NAV during its
    ///         final `maxNavTtl` seconds.
    error NavQuoteTooOld(uint64 issuedAt, uint256 nowTs, uint64 maxAge);

    /// @notice Thrown when an attestation is post-dated relative to the current block.
    error NavAttestationNotYetValid(uint64 issuedAt, uint256 nowTs);

    /// @notice Thrown when `validUntil` exceeds `block.timestamp + maxNavTtl`, i.e. the signer tried
    ///         to mint a longer-lived option than the fund's configuration allows.
    error NavTtlTooLong(uint64 validUntil, uint256 maxAllowed);

    /// @notice Thrown when the attestation's `navRound` is older than the last round used for the asset.
    error StaleNavRound(uint256 supplied, uint256 lastUsed);

    /// @notice Thrown when the attested price falls outside the admin-set absolute bounds.
    error PriceOutOfBounds(uint256 price, uint256 floor, uint256 ceil);

    /// @notice Thrown when the attested price deviates from `getLastSettledPrice` by more than
    ///         `maxDeviationBps`.
    error PriceDeviationTooLarge(uint256 price, uint256 lastSettled, uint16 maxDeviationBps);

    /// @notice Thrown when an uncharged performance fee large enough to materially misprice this
    ///         settlement is outstanding.
    /// @dev    Remedy: run a fee-only settlement **once the fund's six-hour fee gate has reopened**,
    ///         then re-quote at the post-dilution NAV.
    ///
    ///         The gate qualifier is load-bearing. `KpkShares._chargeFees` only charges — and only then
    ///         advances the watermark — when `perfTimeElapsed > MIN_TIME_ELAPSED` (6 h), and
    ///         `_performanceFeeLastUpdate` is written only inside that branch. A fee-only settlement
    ///         attempted earlier mints nothing, moves no watermark, and leaves this block in place.
    ///
    ///         So this error can persist for up to six hours in **both** directions, and the router arms
    ///         it itself: a router settlement charges the fee, resets the fund's clock, and any
    ///         subsequent price move past `maxFeeDilutionBps` blocks until the gate reopens. It is
    ///         availability only — no fund loss, and `KpkShares.requestRedemption` stays permissionless
    ///         so nobody is locked out of the fund itself — but the timing is adverse, because the block
    ///         fires exactly when NAV has moved sharply. The only lever that shortens it today is a
    ///         `DEFAULT_ADMIN_ROLE` `setAssetConfig` widening the tolerance, i.e. relaxing the control
    ///         that is blocking.
    error FeeSettlementRequired(uint256 pendingFeeShares, uint16 maxFeeDilutionBps);

    /// @notice Thrown when the caller's requested output is worse than their own bound.
    error InsufficientOutput(uint256 actual, uint256 required);

    /// @notice Thrown when a single transaction exceeds the per-transaction size cap.
    error PerTxCapExceeded(uint256 requested, uint256 cap);

    /// @notice Thrown when a settlement would exceed the asset's rolling daily budget.
    error DailyCapExceeded(uint256 requested, uint256 remaining);

    /// @notice Thrown when the redeemer has not held their shares for `minHoldingPeriod`.
    error HoldingPeriodNotElapsed(uint64 heldSince, uint64 requiredUntil);

    /// @notice Thrown when a redemption intent has already been executed or cancelled.
    error IntentAlreadyConsumed(bytes32 digest);

    /// @notice Thrown when a redemption intent is used after its deadline.
    error IntentExpired(uint64 deadline, uint256 nowTs);

    /// @notice Thrown when a redemption intent's epoch no longer matches the owner's current epoch.
    error IntentEpochMismatch(uint256 supplied, uint256 current);

    /// @notice Thrown when someone other than the intent's owner tries to cancel it.
    error NotIntentOwner(address owner, address caller);

    /// @notice Thrown when batch inputs have mismatched lengths, or the batch is empty.
    error InvalidBatch();

    /// @notice Thrown when a request the router created did not end in the `PROCESSED` state.
    /// @dev    This is the atomicity invariant. `KpkShares.processRequests` returns successfully while
    ///         leaving a request `PENDING` if the asset argument does not match the request's asset
    ///         (`kpkShares.sol:723`). Because `investor` on a router-created request is the router,
    ///         a surviving `PENDING` request would route the user's refund to this contract.
    error RequestNotSettled(uint256 requestId, uint8 status);

    /// @notice Thrown when an emergency-cancel targets a request this router did not create.
    /// @dev    `KpkShares` authorises cancellation by investor OR receiver, so a third party naming this
    ///         router as their receiver would otherwise be cancellable by this router's admin.
    error NotRouterRequest(uint256 requestId, address investor);

    /// @notice Thrown when the router did not end the call with a zero balance of the token it moved.
    error ResidualBalance(address token, uint256 expected, uint256 actual);

    /// @notice Thrown when the transient allowance granted to the shares proxy was not fully consumed.
    error ResidualAllowance(uint256 remaining);

    //
    // Structs
    //

    /// @notice An off-chain NAV quote, signed by a `NAV_SIGNER_ROLE` key.
    /// @dev    Every field is load-bearing. `fund` and `asset` prevent a quote for one fund or asset
    ///         being replayed on another (differing decimals yield different share counts). `navRound`
    ///         prevents an older-but-unexpired quote from being cherry-picked. `validUntil` bounds the
    ///         free option the quote represents and is the system's fail-closed kill switch: if the
    ///         pricing service stops signing, atomic settlement stops.
    ///
    ///         Attestations are deliberately reusable within their window so one quote can serve every
    ///         investor in that window; replay protection is the window plus the monotonic round, not
    ///         single-use consumption.
    /// @param fund        The `KpkShares` proxy this quote prices. Must equal the router's `SHARES`.
    /// @param asset       The asset the price is denominated against. `KpkShares` tracks its last
    ///                    settled price per asset, so a quote is only meaningful for one asset.
    /// @param sharesPrice Price per share in normalized USD units (8 decimals), passed verbatim as
    ///                    `processRequests`' `sharesPriceInAsset`.
    /// @param navRound    Monotonically increasing sequence number from the pricing service.
    /// @param issuedAt    When the quote was produced. Must not be in the future.
    /// @param validUntil  When the quote expires. Bounded by the asset's `maxNavTtl`.
    struct NavAttestation {
        address fund;
        address asset;
        uint256 sharesPrice;
        uint256 navRound;
        uint64 issuedAt;
        uint64 validUntil;
    }

    /// @notice A share owner's signed authorisation for the automation to redeem on their behalf.
    /// @dev    Because `KpkShares.requestRedemption` escrows shares with an internal `_transfer` from
    ///         `msg.sender` (`kpkShares.sol:342`), the router must *own* the shares to create the
    ///         request, which requires an ERC-20 allowance from the owner. This intent is what stops
    ///         that allowance from becoming a blank cheque: it binds the size, the floor, the
    ///         destination and the expiry, so a compromised relayer key can only execute what the owner
    ///         already authorised.
    /// @param owner        The share owner and the signer. Shares are pulled from this address.
    /// @param receiver     Where the redeemed assets are paid. Bound so a relayer cannot redirect them.
    /// @param asset        The asset to redeem into.
    /// @param sharesIn     Exact share amount to redeem. Bound so a relayer cannot resize the trade.
    /// @param minAssetsOut The owner's floor on assets received, net of the redemption fee. Bound so a
    ///                     relayer cannot settle at an arbitrary price.
    /// @param nonce        Uniqueness salt, letting an owner sign two otherwise identical intents.
    /// @param epoch        Must equal the owner's current epoch; `bumpEpoch` mass-cancels outstanding
    ///                     intents.
    /// @param deadline     Latest timestamp at which the intent may be executed.
    struct RedemptionIntent {
        address fund;
        address owner;
        address receiver;
        address asset;
        uint256 sharesIn;
        uint256 minAssetsOut;
        uint256 nonce;
        uint256 epoch;
        uint64 deadline;
    }

    /// @notice Per-asset limits. Set by `DEFAULT_ADMIN_ROLE`; every bound is per-fund tunable because
    ///         the acceptable free-option cost scales with portfolio volatility.
    /// @param subscribeEnabled    Whether `subscribe` accepts this asset. An all-zero config therefore
    ///                            disables the asset, so a newly enabled fund asset is inert here until
    ///                            an admin configures it explicitly.
    /// @param redeemEnabled       Whether `redeem` accepts this asset.
    /// @param maxNavTtl           Bounds a quote in both directions, in seconds: `validUntil` may not
    ///                            exceed `now + maxNavTtl`, and the price may not be older than
    ///                            `maxNavTtl` at the moment it is applied. Both halves are needed — the
    ///                            forward bound alone would still admit a week-old price during its
    ///                            final `maxNavTtl` seconds. This is the primary lever on stale-NAV
    ///                            arbitrage; the option's value scales with the square root of the
    ///                            window.
    /// @param minHoldingPeriod    Seconds a receiver must wait after a router subscription before the
    ///                            router will redeem for them. Blocks the atomic round-trip loop.
    /// @param maxDeviationBps     Maximum deviation from `KpkShares.getLastSettledPrice`. Advisory only:
    ///                            that value is rewritten on every settlement (`kpkShares.sol:428`) and
    ///                            can be walked by any other `OPERATOR`, so it cannot be relied on
    ///                            alone — `priceFloor`/`priceCeil` are the real constraint.
    /// @param maxFeeDilutionBps   Largest uncharged **performance**-fee dilution, in bps of net supply,
    ///                            tolerated before `subscribe`/`redeem` refuse to settle.
    ///
    ///                            Two limits are deliberate and must be understood before relying on
    ///                            this. It does NOT cover management-fee dilution: that accrues on every
    ///                            asset with no fee-module gate, and the fund's `_managementFeeLastUpdate`
    ///                            is private with no getter, so the router cannot compute it. On a fund
    ///                            with no performance-fee module — the live kUSD configuration — this
    ///                            guard is therefore entirely inert while management fees still mint
    ///                            ahead of pricing. And it fails open on a fee module that does not
    ///                            expose `highWatermark(address)`.
    ///
    ///                            Management-fee dilution is bounded operationally, by settlement
    ///                            cadence, not on-chain: at a 300 bps annual rate a one-day gap is
    ///                            ~0.8 bps but a 30-day gap is ~25 bps, landing on whichever single
    ///                            user crosses the fund's six-hour fee gate.
    /// @param priceFloor          Absolute lower bound on the attested price, 8 decimals. Does not move
    ///                            with settlements, which is what makes it resistant to the ratchet.
    /// @param priceCeil           Absolute upper bound on the attested price, 8 decimals.
    /// @param maxAssetsInPerTx    Largest single subscription, in asset units.
    /// @param maxSharesInPerTx    Largest single redemption, in shares.
    /// @param maxSharesMintedPerDay Budget for shares minted through this router, per **fixed UTC day**.
    ///                            Fixed windows reset at a publicly known instant, so the true bound on
    ///                            any 24-hour period is **2x** this value — a full budget at 23:59 and
    ///                            another at 00:00. Size accordingly: to bound a rolling day at X, set
    ///                            this to X/2. The budget is also **per asset**, so a fund with two
    ///                            enabled assets has twice this again in aggregate.
    /// @param maxAssetsOutPerDay  Budget for assets paid out through this router, per fixed UTC day.
    ///                            Same 2x-across-midnight and per-asset caveats as above.
    struct AssetConfig {
        bool subscribeEnabled;
        bool redeemEnabled;
        uint64 maxNavTtl;
        uint64 minHoldingPeriod;
        uint16 maxDeviationBps;
        uint16 maxFeeDilutionBps;
        uint256 priceFloor;
        uint256 priceCeil;
        uint256 maxAssetsInPerTx;
        uint256 maxSharesInPerTx;
        uint256 maxSharesMintedPerDay;
        uint256 maxAssetsOutPerDay;
    }

    //
    // Events
    //

    /// @notice Emitted when a subscription is created and settled.
    /// @dev    This event is the attribution record. On a router-created request the shares contract
    ///         records `investor` as the router, so indexers must read this event to learn who actually
    ///         subscribed.
    event Subscribed(
        address indexed asset,
        address indexed investor,
        address indexed receiver,
        uint256 assetsIn,
        uint256 sharesOut,
        uint256 sharesPrice,
        uint256 requestId
    );

    /// @notice Emitted when a redemption is created and settled.
    /// @dev    Attribution record, as for {Subscribed}.
    event Redeemed(
        address indexed asset,
        address indexed owner,
        address indexed receiver,
        uint256 sharesIn,
        uint256 assetsOut,
        uint256 sharesPrice,
        uint256 requestId,
        bytes32 intentDigest
    );

    /// @notice Emitted when an owner cancels a specific redemption intent.
    event IntentCancelled(address indexed owner, bytes32 indexed digest);

    /// @notice Emitted when an owner invalidates all of their outstanding intents.
    event EpochBumped(address indexed owner, uint256 newEpoch);

    /// @notice Emitted when an asset's limits are set or changed.
    event AssetConfigSet(address indexed asset, AssetConfig config);

    /// @notice Emitted when stranded tokens are recovered by the admin.
    event Rescued(address indexed token, address indexed to, uint256 amount);

    /// @notice Emitted when the router's allowance to the shares proxy is manually zeroed.
    event SharesAllowanceRevoked(address indexed asset);

    /// @notice Emitted when the admin rewinds or advances the NAV round counter.
    event NavRoundReset(uint256 previousRound, uint256 newRound);

    /// @notice Emitted when the admin force-cancels a router-created request that survived a
    ///         transaction, and forwards the refund.
    event EmergencyCancelled(uint256 indexed requestId, address indexed refundTo);

    //
    // Subscription
    //

    /// @notice Creates and settles a subscription request in one transaction, minting shares to
    ///         `receiver` at the attested price.
    /// @dev    Permissionless: assets are pulled only from `msg.sender`, so there is nothing to
    ///         authorise beyond the attestation. The caller must have approved this router for
    ///         `assetsIn` of `asset`.
    ///
    ///         The share count is computed with `KpkShares.assetsToShares` and passed as the request's
    ///         own `minSharesOut`. That is exact rather than an estimate because the conversion depends
    ///         only on `(amount, price, decimals)` and never reads `totalSupply`, so the fee shares
    ///         minted earlier in the same `processRequests` call cannot shift it.
    /// @param asset        The subscription asset. Must be `canDeposit` on the fund and enabled here.
    /// @param assetsIn     Amount of `asset` to subscribe.
    /// @param minSharesOut The caller's own floor on shares received. Checked before any transfer.
    /// @param receiver     Who receives the minted shares.
    /// @param nav          The signed NAV quote.
    /// @param navSig       Signature over `nav` by a `NAV_SIGNER_ROLE` key.
    /// @return requestId   The settled request's id in the shares contract.
    /// @return sharesOut   Shares minted to `receiver`.
    function subscribe(
        address asset,
        uint256 assetsIn,
        uint256 minSharesOut,
        address receiver,
        NavAttestation calldata nav,
        bytes calldata navSig
    ) external returns (uint256 requestId, uint256 sharesOut);

    //
    // Redemption
    //

    /// @notice Creates and settles one redemption in a single transaction on behalf of the intent's
    ///         owner, paying assets from the fund's portfolio Safe to `intent.receiver`.
    /// @dev    Restricted to `RELAYER_ROLE` *and* gated on the owner's signature: the relayer chooses
    ///         when to settle (after liquidity has landed in the Safe), the owner chose what may be
    ///         settled. The owner must have approved this router for `intent.sharesIn` shares.
    /// @param intent    The owner's signed redemption authorisation.
    /// @param intentSig Signature over `intent` by `intent.owner`. ERC-1271 contract owners supported.
    /// @param nav       The signed NAV quote. `nav.asset` must equal `intent.asset`.
    /// @param navSig    Signature over `nav` by a `NAV_SIGNER_ROLE` key.
    /// @return requestId The settled request's id.
    /// @return assetsOut Assets paid to `intent.receiver`, net of the redemption fee.
    function redeem(
        RedemptionIntent calldata intent,
        bytes calldata intentSig,
        NavAttestation calldata nav,
        bytes calldata navSig
    ) external returns (uint256 requestId, uint256 assetsOut);

    /// @notice Settles many redemptions for one asset through a single `processRequests` call.
    /// @dev    Batching is what keeps `_chargeFees` and the `_lastSettledPrice` write to once per
    ///         transaction. The trade-off is coupled failure: one intent whose floor is breached
    ///         reverts at `kpkShares.sol:856` and unwinds the entire batch, so the relayer must
    ///         simulate before broadcasting.
    /// @param intents    Intents to settle. All must name the same asset as `nav`.
    /// @param intentSigs Signatures, index-aligned with `intents`.
    /// @param nav        The signed NAV quote applied to every intent in the batch.
    /// @param navSig     Signature over `nav` by a `NAV_SIGNER_ROLE` key.
    /// @return requestIds The settled request ids, index-aligned with `intents`.
    /// @return assetsOut  Assets paid per intent, index-aligned with `intents`.
    function redeemBatch(
        RedemptionIntent[] calldata intents,
        bytes[] calldata intentSigs,
        NavAttestation calldata nav,
        bytes calldata navSig
    ) external returns (uint256[] memory requestIds, uint256[] memory assetsOut);

    /// @notice Cancels a single outstanding redemption intent.
    /// @dev    Callable only by the intent's owner, so a griefer cannot burn someone else's digest.
    /// @param intent The intent to invalidate.
    function cancelIntent(RedemptionIntent calldata intent) external;

    /// @notice Invalidates every outstanding redemption intent signed by the caller.
    /// @return newEpoch The caller's new epoch.
    function bumpEpoch() external returns (uint256 newEpoch);

    //
    // Views
    //

    /// @notice The `KpkShares` proxy this router serves.
    function SHARES() external view returns (address);

    /// @notice Shares that `subscribe` would mint for `assetsIn` at `sharesPrice`.
    function previewSubscribe(address asset, uint256 assetsIn, uint256 sharesPrice)
        external
        view
        returns (uint256 sharesOut);

    /// @notice Assets that `redeem` would pay for `sharesIn` at `sharesPrice`, net of the redemption fee.
    function previewRedeem(address asset, uint256 sharesIn, uint256 sharesPrice)
        external
        view
        returns (uint256 assetsOut);

    /// @notice Performance-fee shares that would be minted if a settlement at `sharesPrice` crossed the
    ///         fund's fee gate, and whether that dilution exceeds the asset's tolerance.
    /// @dev    Mirrors `WatermarkFee.calculatePerformanceFee` exactly. The fund's fee clocks are private
    ///         with no getter, so the router cannot tell whether the 6-hour gate will actually trip and
    ///         must treat a material outstanding fee as blocking.
    function previewPendingPerformanceFee(address asset, uint256 sharesPrice)
        external
        view
        returns (uint256 feeShares, bool blocking);

    /// @notice The EIP-712 digest for a NAV attestation under this router's domain.
    function hashNavAttestation(NavAttestation calldata nav) external view returns (bytes32);

    /// @notice The EIP-712 digest for a redemption intent under this router's domain.
    function hashRedemptionIntent(RedemptionIntent calldata intent) external view returns (bytes32);

    /// @notice Whether a redemption intent digest has been executed or cancelled.
    function isIntentConsumed(bytes32 digest) external view returns (bool);

    /// @notice The current intent epoch for `owner`.
    function intentEpoch(address owner) external view returns (uint256);

    /// @notice The highest NAV round already applied on this router.
    /// @dev    Router-wide, not per-asset. `sharesPrice` is a fund-wide USD-per-share figure — the asset
    ///         only selects the decimals used to convert it — so a round consumed while settling one
    ///         asset must also retire that round for every sibling asset. Keying this per asset would
    ///         let a superseded quote be replayed on an asset that happened not to transact.
    function lastNavRound() external view returns (uint256);

    /// @notice When `receiver` last received shares through this router, for holding-period checks.
    function sharesHeldSince(address receiver) external view returns (uint64);

    /// @notice Remaining daily budgets for `asset` in the current UTC day.
    function remainingDailyBudget(address asset) external view returns (uint256 sharesMintable, uint256 assetsPayable);

    /// @notice The configured limits for `asset`.
    function assetConfig(address asset) external view returns (AssetConfig memory);

    //
    // Admin
    //

    /// @notice Sets the limits for `asset`.
    function setAssetConfig(address asset, AssetConfig calldata config) external;

    /// @notice Halts `subscribe` and `redeem`. Held by fast-reacting operators, not just the admin Safe.
    function pause() external;

    /// @notice Resumes settlement. Admin only, deliberately slower than pausing.
    function unpause() external;

    /// @notice Recovers tokens stranded on the router.
    /// @dev    Deliberately admin-gated and destination-explicit, unlike the repo's `RecoverFunds`
    ///         pattern which sweeps permissionlessly to the portfolio Safe. On a router any stranded
    ///         balance is some individual user's in-flight principal; sweeping it into the fund would
    ///         socialise it into NAV, and anyone could trigger that.
    function rescue(address token, address to, uint256 amount) external;

    /// @notice Zeroes the router's allowance to the shares proxy for `asset`.
    function revokeSharesAllowance(address asset) external;

    /// @notice Rewinds or advances the NAV round counter.
    /// @dev    Recovery lever for the one piece of irreversible state in this contract. `lastNavRound`
    ///         ratchets monotonically from an unbounded `uint256` carried in a signed quote, so a single
    ///         attestation with an absurd round — a compromised signer, or a pricing service emitting
    ///         milliseconds, a hash, or a `u64::MAX` sentinel — would otherwise exhaust the sequence and
    ///         permanently disable settlement, with no upgrade path and no way to recover but to
    ///         redeploy and have every user re-approve.
    ///
    ///         Safe to expose: the round is a replay-ordering device, not a price control. Rewinding it
    ///         cannot change what a quote is worth — `priceFloor`, `priceCeil`, `maxDeviationBps` and
    ///         `validUntil` all still bind — it can only make an old, still-unexpired quote usable
    ///         again, and quote lifetimes are bounded by `maxNavTtl`.
    function resetNavRound(uint256 round) external;

    /// @notice Force-cancels a router-created subscription request that survived its transaction and
    ///         forwards the refund to `refundTo`.
    /// @dev    Unreachable against the current shares implementation, where the atomicity invariant
    ///         reverts instead. Retained because each fund's implementation is independently
    ///         upgradeable, so `processRequests` semantics could change beneath an already-deployed
    ///         router. Only works once the fund's cancellation TTL has elapsed.
    function emergencyCancelSubscription(uint256 requestId, address refundTo) external;

    /// @notice Force-cancels a router-created redemption request and forwards the returned shares.
    function emergencyCancelRedemption(uint256 requestId, address refundTo) external;
}
