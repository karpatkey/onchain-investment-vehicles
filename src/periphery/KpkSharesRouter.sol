// SPDX-License-Identifier: MIT
pragma solidity 0.8.34;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {AccessControl} from "@openzeppelin/contracts/access/AccessControl.sol";
import {Pausable} from "@openzeppelin/contracts/utils/Pausable.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {EIP712} from "@openzeppelin/contracts/utils/cryptography/EIP712.sol";
import {ECDSA} from "@openzeppelin/contracts/utils/cryptography/ECDSA.sol";
import {SignatureChecker} from "@openzeppelin/contracts/utils/cryptography/SignatureChecker.sol";

import {IkpkShares} from "../IkpkShares.sol";
import {IKpkSharesRouter, NAV_ATTESTATION_TYPEHASH, REDEMPTION_INTENT_TYPEHASH} from "./IKpkSharesRouter.sol";

/// @notice Minimal view of the high-watermark performance fee module.
/// @dev    Declared locally rather than importing `WatermarkFee` because the fund's fee module is
///         admin-settable to any `IPerfFeeModule`, so the router must probe for this getter rather
///         than assume it exists. Reads are wrapped in `try`/`catch`.
interface IWatermarkFeeView {
    function highWatermark(address fund) external view returns (uint256);
}

/// @title  KpkSharesRouter
/// @author kpk
/// @notice Creates and settles a `KpkShares` subscription or redemption request in a single
///         transaction, pricing it from an off-chain NAV quote supplied as calldata.
/// @dev    ## Why this contract carries the fund's pricing integrity
///
///         `KpkShares` settles at a price its `OPERATOR` passes as a raw argument. Its per-request
///         guards (`kpkShares.sol:776` for subscriptions, `:856` for redemptions) have teeth only
///         because, in the two-step flow, the investor authors `minSharesOut` at one time and the
///         operator authors the price later. When a single call authors both — which is exactly what
///         atomic settlement means — those guards pass at equality by construction.
///
///         The residual asymmetry is that a price which is *worse* for the transacting user reverts
///         while a price which is *better* succeeds and dilutes everyone else. So the audited guards
///         protect only the one party who is never at risk. Every protection for continuing
///         shareholders lives here:
///
///         - the price must carry an EIP-712 signature from a `NAV_SIGNER_ROLE` key, so the investor
///           cannot choose it even though the investor broadcasts the transaction;
///         - `priceFloor` / `priceCeil` are absolute and admin-set. They do not track
///           `getLastSettledPrice`, which `processRequests` rewrites unconditionally
///           (`kpkShares.sol:428`) and which any `OPERATOR` can therefore walk 30% per call;
///         - `navRound` is monotonic per asset, so an older-but-unexpired quote cannot be
///           cherry-picked out of a published strip;
///         - `maxNavTtl` bounds the free option the quote represents, and doubles as the kill switch:
///           if the pricing service stops signing, settlement stops;
///         - per-transaction and per-day caps bound the damage a mispriced or compromised quote can do
///           within one monitoring interval.
///
///         ## What this contract deliberately does not do
///
///         It exposes no `updateAsset` passthrough and no generic call forwarder. The `OPERATOR` role
///         it holds also gates `KpkShares.updateAsset`, whose add branch (`kpkShares.sol:1041-1060`)
///         registers an arbitrary token from nothing but `symbol()`/`decimals()`, and whose first
///         settlement skips the deviation guard entirely (`:903`). Keeping that path behind the
///         Manager Safe multisig is deliberate; the router must never reopen it.
///
///         It never reads a NAV contract on-chain. `onchain-accounting`'s ADR 0017 values LP positions
///         at instantaneous reserves on the explicit condition that no atomic on-chain NAV consumer
///         exists. Passing the price as signed calldata keeps that condition satisfied; a live read
///         would import reserve manipulation into settlement, and would in any case bound only one
///         chain's slice of a portfolio spread across roughly 25 chains.
///
///         The router is intentionally **not upgradeable**. Users grant it ERC-20 allowances, and an
///         upgradeable contract holding those allowances would make the proxy admin an unconditional
///         custodian.
contract KpkSharesRouter is IKpkSharesRouter, AccessControl, Pausable, ReentrancyGuard, EIP712 {
    using SafeERC20 for IERC20;

    //
    // Constants
    //

    /// @notice Basis-point denominator.
    uint256 private constant _PRECISION_BPS = 10_000;

    /// @notice Signs `NavAttestation` quotes. Held by the off-chain pricing service key.
    bytes32 public constant NAV_SIGNER_ROLE = keccak256("NAV_SIGNER");

    /// @notice May trigger redemptions once liquidity has landed in the fund Safe. Held by the bot.
    /// @dev    Deliberately separate from `NAV_SIGNER_ROLE`: requiring an attestation on the redemption
    ///         path as well means neither key on its own can settle at a price of its choosing.
    bytes32 public constant RELAYER_ROLE = keccak256("RELAYER");

    /// @notice May pause settlement. Held by fast-reacting operators as well as the admin Safe, because
    ///         atomic settlement leaves no window between a bad price becoming visible and it applying.
    bytes32 public constant GUARDIAN_ROLE = keccak256("GUARDIAN");

    //
    // Immutables
    //

    /// @notice The `KpkShares` proxy this router serves.
    /// @dev    One router per fund. `OPERATOR` is granted per fund by that fund's own
    ///         `DEFAULT_ADMIN_ROLE` holder, and those holders differ between funds, so a shared router
    ///         would require every fund's admin to trust one contract and would turn every per-fund
    ///         limit into a mapping.
    IkpkShares public immutable SHARES_CONTRACT;

    //
    // State
    //

    /// @notice Highest NAV round already applied on this router.
    /// @dev    Router-wide rather than per-asset. `sharesPrice` is a fund-wide USD-per-share figure and
    ///         the asset only selects the decimals used to convert it, so a round consumed on one asset
    ///         must retire that round everywhere. Keyed per asset, a superseded quote stayed usable on
    ///         any sibling asset that happened not to transact — settle USDC at round N after a price
    ///         drop and the pre-drop round N-1 quote was still live on USDT.
    uint256 public lastNavRound;

    /// @notice Redemption intent digests already executed or cancelled.
    mapping(bytes32 digest => bool consumed) public consumedIntent;

    /// @notice Per-owner intent epoch. Bumping invalidates every outstanding intent for that owner.
    mapping(address owner => uint256 epoch) public intentEpoch;

    /// @notice When an address last received shares through this router.
    /// @dev    Basis for `minHoldingPeriod`. Two honest limitations, both documented rather than
    ///         papered over: shares are freely transferable, so a determined arbitrageur can move them
    ///         to a fresh address whose clock is unset and redeem immediately; and anyone can subscribe
    ///         a dust amount to a third party's address and reset their clock. Neither is a lock-out —
    ///         `KpkShares.requestRedemption` remains permissionless and unaffected, so a griefed user
    ///         can always exit through the fund's own two-step path. The holding period is a cost on
    ///         automated round-tripping, not a hard barrier; `maxNavTtl` and the volume caps are.
    mapping(address receiver => uint64 timestamp) public sharesHeldSince;

    /// @dev Per-asset, per-UTC-day usage against the daily budgets.
    mapping(address asset => mapping(uint256 day => DailyUsage usage)) private _dailyUsage;

    /// @dev Per-asset limits.
    mapping(address asset => AssetConfig config) private _assetConfig;

    /// @notice Shares minted and assets paid out for one asset within one UTC day.
    struct DailyUsage {
        uint256 sharesMinted;
        uint256 assetsPaid;
    }

    //
    // Constructor
    //

    /// @param shares   The `KpkShares` proxy this router will settle against.
    /// @param admin    Receives `DEFAULT_ADMIN_ROLE`. Should be the same Safe that holds
    ///                 `DEFAULT_ADMIN_ROLE` on `shares`, since that Safe is the only party able to
    ///                 grant and revoke this router's `OPERATOR` role — splitting the two creates a
    ///                 configuration no single party can unwind.
    /// @param guardian Receives `GUARDIAN_ROLE`. May be the Manager Safe or an ops key.
    constructor(address shares, address admin, address guardian) EIP712("KpkSharesRouter", "1") {
        if (shares == address(0) || admin == address(0) || guardian == address(0)) revert ZeroAddress();

        SHARES_CONTRACT = IkpkShares(shares);
        _grantRole(DEFAULT_ADMIN_ROLE, admin);
        _grantRole(GUARDIAN_ROLE, guardian);
    }

    //
    // Subscription
    //

    /// @inheritdoc IKpkSharesRouter
    function subscribe(
        address asset,
        uint256 assetsIn,
        uint256 minSharesOut,
        address receiver,
        NavAttestation calldata nav,
        bytes calldata navSig
    ) external whenNotPaused nonReentrant returns (uint256 requestId, uint256 sharesOut) {
        AssetConfig memory cfg = _assetConfig[asset];
        if (!cfg.subscribeEnabled) revert AssetNotEnabled(asset);
        if (assetsIn == 0) revert InvalidAmount();
        if (assetsIn > cfg.maxAssetsInPerTx) revert PerTxCapExceeded(assetsIn, cfg.maxAssetsInPerTx);
        _validateReceiver(receiver);

        _verifyNav(nav, navSig, asset, cfg);
        _requireNoBlockingFee(asset, nav.sharesPrice, cfg);

        // Exact, not an estimate: `assetsToShares` depends only on (amount, price, decimals) and never
        // reads `totalSupply` (`kpkShares.sol:536-555`), so the fee shares that `_chargeFees` mints
        // earlier in the same `processRequests` call cannot move it. Passing this as the request's own
        // `minSharesOut` therefore makes the guard at `kpkShares.sol:776` an equality.
        sharesOut = SHARES_CONTRACT.assetsToShares(assetsIn, nav.sharesPrice, asset);
        // `KpkShares._requireValidRequestParams` rejects a zero `minSharesOut`, and a zero mint would
        // hand the fund free assets.
        if (sharesOut == 0) revert InvalidAmount();
        if (sharesOut < minSharesOut) revert InsufficientOutput(sharesOut, minSharesOut);

        _consumeMintBudget(asset, sharesOut, cfg.maxSharesMintedPerDay);
        sharesHeldSince[receiver] = uint64(block.timestamp);

        uint256 balanceBefore = IERC20(asset).balanceOf(address(this));

        IERC20(asset).safeTransferFrom(msg.sender, address(this), assetsIn);
        // Exact amount, and `forceApprove` because USDT-family tokens revert on a non-zero to non-zero
        // approval. The pull inside `requestSubscription` (`kpkShares.sol:228`) consumes all of it, so
        // no standing allowance survives the call — asserted below.
        IERC20(asset).forceApprove(address(SHARES_CONTRACT), assetsIn);

        requestId = SHARES_CONTRACT.requestSubscription(assetsIn, sharesOut, asset, receiver);
        _settleSingle(requestId, asset, nav.sharesPrice);

        _assertSettled(requestId);
        _assertNoResidualAsset(asset, balanceBefore);

        emit Subscribed(asset, msg.sender, receiver, assetsIn, sharesOut, nav.sharesPrice, requestId);
    }

    //
    // Redemption
    //

    /// @inheritdoc IKpkSharesRouter
    function redeem(
        RedemptionIntent calldata intent,
        bytes calldata intentSig,
        NavAttestation calldata nav,
        bytes calldata navSig
    ) external onlyRole(RELAYER_ROLE) whenNotPaused nonReentrant returns (uint256 requestId, uint256 assetsOut) {
        AssetConfig memory cfg = _assetConfig[intent.asset];
        if (!cfg.redeemEnabled) revert AssetNotEnabled(intent.asset);

        _verifyNav(nav, navSig, intent.asset, cfg);
        _requireNoBlockingFee(intent.asset, nav.sharesPrice, cfg);

        (requestId, assetsOut) = _redeemOne(intent, intentSig, nav, cfg);
    }

    /// @dev Body of the single-redemption path, split out purely to keep `redeem`'s stack shallow
    ///      enough for via-IR. Snapshots, creates, settles, asserts and emits for exactly one intent.
    function _redeemOne(
        RedemptionIntent calldata intent,
        bytes calldata intentSig,
        NavAttestation calldata nav,
        AssetConfig memory cfg
    ) private returns (uint256 requestId, uint256 assetsOut) {
        uint256 shareBalanceBefore = IERC20(address(SHARES_CONTRACT)).balanceOf(address(this));
        uint256 receiverBefore = IERC20(intent.asset).balanceOf(intent.receiver);

        (requestId, assetsOut) = _prepareRedemption(intent, intentSig, nav, cfg);
        _settleSingle(requestId, intent.asset, nav.sharesPrice);

        _assertSettled(requestId);
        _assertNoResidualShares(shareBalanceBefore);
        _assertDelivered(intent.asset, intent.receiver, receiverBefore, assetsOut);

        _emitRedeemed(intent, assetsOut, nav.sharesPrice, requestId);
    }

    /// @dev Emits {Redeemed}. Factored out so neither `_redeemOne` nor `redeemBatch`'s loop carries the
    ///      event's eight arguments plus the intent digest on the stack at once.
    function _emitRedeemed(RedemptionIntent calldata intent, uint256 assetsOut, uint256 sharesPrice, uint256 requestId)
        private
    {
        emit Redeemed(
            intent.asset,
            intent.owner,
            intent.receiver,
            intent.sharesIn,
            assetsOut,
            sharesPrice,
            requestId,
            hashRedemptionIntent(intent)
        );
    }

    /// @inheritdoc IKpkSharesRouter
    function redeemBatch(
        RedemptionIntent[] calldata intents,
        bytes[] calldata intentSigs,
        NavAttestation calldata nav,
        bytes calldata navSig
    )
        external
        onlyRole(RELAYER_ROLE)
        whenNotPaused
        nonReentrant
        returns (uint256[] memory requestIds, uint256[] memory assetsOut)
    {
        uint256 count = intents.length;
        if (count == 0 || count != intentSigs.length) revert InvalidBatch();

        AssetConfig memory cfg = _assetConfig[nav.asset];
        if (!cfg.redeemEnabled) revert AssetNotEnabled(nav.asset);

        _verifyNav(nav, navSig, nav.asset, cfg);
        _requireNoBlockingFee(nav.asset, nav.sharesPrice, cfg);

        uint256 shareBalanceBefore = IERC20(address(SHARES_CONTRACT)).balanceOf(address(this));

        requestIds = new uint256[](count);
        assetsOut = new uint256[](count);
        for (uint256 i = 0; i < count; i++) {
            (requestIds[i], assetsOut[i]) = _prepareRedemption(intents[i], intentSigs[i], nav, cfg);
        }

        // One `processRequests` for the whole batch, so `_chargeFees` runs once and
        // `_lastSettledPrice` is written once.
        SHARES_CONTRACT.processRequests(requestIds, new uint256[](0), nav.asset, nav.sharesPrice);

        for (uint256 i = 0; i < count; i++) {
            _assertSettled(requestIds[i]);
            _emitRedeemed(intents[i], assetsOut[i], nav.sharesPrice, requestIds[i]);
        }

        // No per-receiver delta check here: all payouts land in one `processRequests`, so if two
        // intents share a receiver their individual deltas are not separable. The `PROCESSED`
        // assertion plus `KpkShares`' own floor check at `:856` already cover the amounts.
        _assertNoResidualShares(shareBalanceBefore);
    }

    /// @inheritdoc IKpkSharesRouter
    function cancelIntent(RedemptionIntent calldata intent) external {
        if (msg.sender != intent.owner) revert NotIntentOwner(intent.owner, msg.sender);

        bytes32 digest = hashRedemptionIntent(intent);
        if (consumedIntent[digest]) revert IntentAlreadyConsumed(digest);
        consumedIntent[digest] = true;

        emit IntentCancelled(intent.owner, digest);
    }

    /// @inheritdoc IKpkSharesRouter
    function bumpEpoch() external returns (uint256 newEpoch) {
        newEpoch = ++intentEpoch[msg.sender];
        emit EpochBumped(msg.sender, newEpoch);
    }

    //
    // Views
    //

    /// @inheritdoc IKpkSharesRouter
    function SHARES() external view returns (address) {
        return address(SHARES_CONTRACT);
    }

    /// @inheritdoc IKpkSharesRouter
    function previewSubscribe(address asset, uint256 assetsIn, uint256 sharesPrice)
        external
        view
        returns (uint256 sharesOut)
    {
        return SHARES_CONTRACT.assetsToShares(assetsIn, sharesPrice, asset);
    }

    /// @inheritdoc IKpkSharesRouter
    function previewRedeem(address asset, uint256 sharesIn, uint256 sharesPrice)
        external
        view
        returns (uint256 assetsOut)
    {
        return SHARES_CONTRACT.previewRedemption(sharesIn, sharesPrice, asset);
    }

    /// @inheritdoc IKpkSharesRouter
    function previewPendingPerformanceFee(address asset, uint256 sharesPrice)
        public
        view
        returns (uint256 feeShares, bool blocking)
    {
        return _previewPendingPerformanceFee(asset, sharesPrice, _assetConfig[asset]);
    }

    /// @inheritdoc IKpkSharesRouter
    function hashNavAttestation(NavAttestation calldata nav) public view returns (bytes32) {
        return _hashTypedDataV4(
            keccak256(
                abi.encode(
                    NAV_ATTESTATION_TYPEHASH,
                    nav.fund,
                    nav.asset,
                    nav.sharesPrice,
                    nav.navRound,
                    nav.issuedAt,
                    nav.validUntil
                )
            )
        );
    }

    /// @inheritdoc IKpkSharesRouter
    function hashRedemptionIntent(RedemptionIntent calldata intent) public view returns (bytes32) {
        return _hashTypedDataV4(
            keccak256(
                abi.encode(
                    REDEMPTION_INTENT_TYPEHASH,
                    intent.fund,
                    intent.owner,
                    intent.receiver,
                    intent.asset,
                    intent.sharesIn,
                    intent.minAssetsOut,
                    intent.nonce,
                    intent.epoch,
                    intent.deadline
                )
            )
        );
    }

    /// @inheritdoc IKpkSharesRouter
    function isIntentConsumed(bytes32 digest) external view returns (bool) {
        return consumedIntent[digest];
    }

    /// @inheritdoc IKpkSharesRouter
    function remainingDailyBudget(address asset) external view returns (uint256 sharesMintable, uint256 assetsPayable) {
        AssetConfig memory cfg = _assetConfig[asset];
        DailyUsage memory usage = _dailyUsage[asset][block.timestamp / 1 days];

        sharesMintable =
            cfg.maxSharesMintedPerDay > usage.sharesMinted ? cfg.maxSharesMintedPerDay - usage.sharesMinted : 0;
        assetsPayable = cfg.maxAssetsOutPerDay > usage.assetsPaid ? cfg.maxAssetsOutPerDay - usage.assetsPaid : 0;
    }

    /// @inheritdoc IKpkSharesRouter
    function assetConfig(address asset) external view returns (AssetConfig memory) {
        return _assetConfig[asset];
    }

    /// @notice The EIP-712 domain separator signatures for this router must be built against.
    function DOMAIN_SEPARATOR() external view returns (bytes32) {
        return _domainSeparatorV4();
    }

    //
    // Admin
    //

    /// @inheritdoc IKpkSharesRouter
    function setAssetConfig(address asset, AssetConfig calldata config) external onlyRole(DEFAULT_ADMIN_ROLE) {
        if (asset == address(0)) revert ZeroAddress();

        // An enabled asset must be fully bounded. Leaving any limit at zero would either brick the
        // asset or, in the price bounds' case, remove the only constraint that does not track a value
        // an operator can walk.
        if (config.subscribeEnabled || config.redeemEnabled) {
            if (
                config.maxNavTtl == 0 || config.maxDeviationBps == 0 || config.priceFloor == 0
                    || config.priceCeil < config.priceFloor
            ) {
                revert InvalidAmount();
            }
            if (config.subscribeEnabled && (config.maxAssetsInPerTx == 0 || config.maxSharesMintedPerDay == 0)) {
                revert InvalidAmount();
            }
            if (config.redeemEnabled && (config.maxSharesInPerTx == 0 || config.maxAssetsOutPerDay == 0)) {
                revert InvalidAmount();
            }
        }

        _assetConfig[asset] = config;
        emit AssetConfigSet(asset, config);
    }

    /// @inheritdoc IKpkSharesRouter
    function pause() external onlyRole(GUARDIAN_ROLE) {
        _pause();
    }

    /// @inheritdoc IKpkSharesRouter
    function unpause() external onlyRole(DEFAULT_ADMIN_ROLE) {
        _unpause();
    }

    /// @inheritdoc IKpkSharesRouter
    function rescue(address token, address to, uint256 amount) external onlyRole(DEFAULT_ADMIN_ROLE) {
        if (to == address(0)) revert ZeroAddress();

        IERC20(token).safeTransfer(to, amount);
        emit Rescued(token, to, amount);
    }

    /// @inheritdoc IKpkSharesRouter
    function revokeSharesAllowance(address asset) external onlyRole(DEFAULT_ADMIN_ROLE) {
        IERC20(asset).forceApprove(address(SHARES_CONTRACT), 0);
        emit SharesAllowanceRevoked(asset);
    }

    /// @inheritdoc IKpkSharesRouter
    function resetNavRound(uint256 round) external onlyRole(DEFAULT_ADMIN_ROLE) {
        uint256 previous = lastNavRound;
        lastNavRound = round;

        emit NavRoundReset(previous, round);
    }

    /// @inheritdoc IKpkSharesRouter
    function emergencyCancelSubscription(uint256 requestId, address refundTo)
        external
        onlyRole(DEFAULT_ADMIN_ROLE)
        nonReentrant
    {
        if (refundTo == address(0)) revert ZeroAddress();

        address asset = _requireOwnRequest(requestId);

        uint256 before = IERC20(asset).balanceOf(address(this));
        SHARES_CONTRACT.cancelSubscription(requestId);
        uint256 refunded = IERC20(asset).balanceOf(address(this)) - before;

        IERC20(asset).safeTransfer(refundTo, refunded);
        emit EmergencyCancelled(requestId, refundTo);
    }

    /// @inheritdoc IKpkSharesRouter
    function emergencyCancelRedemption(uint256 requestId, address refundTo)
        external
        onlyRole(DEFAULT_ADMIN_ROLE)
        nonReentrant
    {
        if (refundTo == address(0)) revert ZeroAddress();

        _requireOwnRequest(requestId);

        IERC20 shares = IERC20(address(SHARES_CONTRACT));

        uint256 before = shares.balanceOf(address(this));
        SHARES_CONTRACT.cancelRedemption(requestId);
        uint256 returned = shares.balanceOf(address(this)) - before;

        shares.safeTransfer(refundTo, returned);
        emit EmergencyCancelled(requestId, refundTo);
    }

    //
    // Internal — validation
    //

    /// @dev Verifies a NAV quote and consumes its round. Reverts unless the quote is signed by a
    ///      `NAV_SIGNER_ROLE` key, is for this fund and asset, is inside its validity window, sits
    ///      within the asset's absolute price bounds, and is not older than the last round used.
    function _verifyNav(NavAttestation calldata nav, bytes calldata navSig, address asset, AssetConfig memory cfg)
        private
    {
        if (nav.fund != address(SHARES_CONTRACT)) revert FundMismatch(address(SHARES_CONTRACT), nav.fund);
        if (nav.asset != asset) revert AssetMismatch(asset, nav.asset);

        if (nav.issuedAt > block.timestamp) revert NavAttestationNotYetValid(nav.issuedAt, block.timestamp);
        if (block.timestamp > nav.validUntil) revert NavAttestationExpired(nav.validUntil, block.timestamp);

        uint256 maxAllowed = block.timestamp + cfg.maxNavTtl;
        if (nav.validUntil > maxAllowed) revert NavTtlTooLong(nav.validUntil, maxAllowed);

        // Bound the age of the PRICE, not just the remaining life of the quote. The check above alone
        // is satisfied by a week-old quote during its final `maxNavTtl` seconds, which would settle at
        // a week-old NAV — making the contract's headline anti-stale-NAV control vacuous and `issuedAt`
        // decorative despite being signed.
        if (block.timestamp - nav.issuedAt > cfg.maxNavTtl) {
            revert NavQuoteTooOld(nav.issuedAt, block.timestamp, cfg.maxNavTtl);
        }

        _verifyNavPriceAndRound(nav, asset, cfg);

        address signer = ECDSA.recover(hashNavAttestation(nav), navSig);
        if (!hasRole(NAV_SIGNER_ROLE, signer)) revert InvalidNavSigner(signer);
    }

    /// @dev Price bounds and round monotonicity. Split from `_verifyNav` purely to keep the stack
    ///      shallow enough for via-IR.
    function _verifyNavPriceAndRound(NavAttestation calldata nav, address asset, AssetConfig memory cfg) private {
        // Absolute bounds first. These do not move with settlements, which is what makes them
        // resistant to the `_lastSettledPrice` ratchet described in the contract-level docs.
        if (nav.sharesPrice < cfg.priceFloor || nav.sharesPrice > cfg.priceCeil) {
            revert PriceOutOfBounds(nav.sharesPrice, cfg.priceFloor, cfg.priceCeil);
        }

        // Relative band. Advisory: another `OPERATOR` can move the anchor outside this router.
        uint256 lastSettled = SHARES_CONTRACT.getLastSettledPrice(asset);
        if (lastSettled != 0) {
            uint256 deviation =
                nav.sharesPrice > lastSettled ? nav.sharesPrice - lastSettled : lastSettled - nav.sharesPrice;
            if ((deviation * _PRECISION_BPS) / lastSettled > cfg.maxDeviationBps) {
                revert PriceDeviationTooLarge(nav.sharesPrice, lastSettled, cfg.maxDeviationBps);
            }
        }

        // Monotonic rounds, router-wide. `>=` rather than `>` so one quote can serve every investor in
        // its window; a newer round landing first simply forces in-flight callers to re-quote.
        uint256 lastRound = lastNavRound;
        if (nav.navRound < lastRound) revert StaleNavRound(nav.navRound, lastRound);
        if (nav.navRound != lastRound) lastNavRound = nav.navRound;
    }

    /// @dev Reverts when a material uncharged performance fee is outstanding.
    ///
    ///      `_chargeFees` runs before `_processApproved` (`kpkShares.sol:423`), minting fee shares to
    ///      the fee receiver, while the pricing service computed its quote from a pre-mint supply. In
    ///      the daily-batch flow that dilution spreads across a whole batch; settling one user at a
    ///      time concentrates it on whichever user happens to cross the fund's six-hour fee gate. The
    ///      fund's fee clocks are private with no getter, so the router cannot tell whether the gate
    ///      will trip and treats a material outstanding fee as blocking.
    function _requireNoBlockingFee(address asset, uint256 sharesPrice, AssetConfig memory cfg) private view {
        (uint256 feeShares, bool blocking) = _previewPendingPerformanceFee(asset, sharesPrice, cfg);
        if (blocking) revert FeeSettlementRequired(feeShares, cfg.maxFeeDilutionBps);
    }

    /// @dev Mirrors `WatermarkFee.calculatePerformanceFee`. Returns `(0, false)` when the fee cannot
    ///      fire, or when the module does not expose a readable watermark — the router fails open on
    ///      an unrecognised module rather than bricking a fund whose admin swapped it.
    function _previewPendingPerformanceFee(address asset, uint256 sharesPrice, AssetConfig memory cfg)
        private
        view
        returns (uint256 feeShares, bool blocking)
    {
        address module = SHARES_CONTRACT.performanceFeeModule();
        uint256 rate = SHARES_CONTRACT.performanceFeeRate();
        if (module == address(0) || rate == 0) return (0, false);

        // The fund charges a performance fee only when settling in a fee-module asset
        // (`kpkShares.sol:943`).
        if (!SHARES_CONTRACT.getApprovedAsset(asset).isFeeModuleAsset) return (0, false);

        uint256 watermark;
        try IWatermarkFeeView(module).highWatermark(address(SHARES_CONTRACT)) returns (uint256 hwm) {
            watermark = hwm;
        } catch {
            return (0, false);
        }

        // A zero watermark means the module seeds on its next call and charges nothing.
        if (watermark == 0 || sharesPrice <= watermark) return (0, false);

        IERC20 shares = IERC20(address(SHARES_CONTRACT));
        uint256 netSupply = shares.totalSupply() - shares.balanceOf(SHARES_CONTRACT.feeReceiver());
        if (netSupply == 0) return (0, false);

        uint256 totalProfit = ((sharesPrice - watermark) * netSupply) / sharesPrice;
        feeShares = (totalProfit * rate) / _PRECISION_BPS;
        blocking = (feeShares * _PRECISION_BPS) / netSupply > cfg.maxFeeDilutionBps;
    }

    /// @dev Rejects receivers that would corrupt accounting or confound the conservation assertions.
    ///      The fee receiver is excluded because minting subscriber shares there would distort the net
    ///      supply the fund uses as its fee base. The portfolio Safe is excluded on BOTH paths: minting
    ///      into it creates self-referential treasury shares that an off-chain NAV service valuing the
    ///      Safe's holdings can double-count, and those shares are then stuck, since the redemption path
    ///      refuses to pay that address.
    function _validateReceiver(address receiver) private view {
        if (
            receiver == address(0) || receiver == address(this) || receiver == address(SHARES_CONTRACT)
                || receiver == SHARES_CONTRACT.feeReceiver() || receiver == SHARES_CONTRACT.portfolioSafe()
        ) {
            revert InvalidReceiver(receiver);
        }
    }

    //
    // Internal — redemption
    //

    /// @dev Validates one intent, escrows the owner's shares and creates the redemption request.
    ///      Does not settle: the caller settles one or many requests in a single `processRequests`.
    function _prepareRedemption(
        RedemptionIntent calldata intent,
        bytes calldata intentSig,
        NavAttestation calldata nav,
        AssetConfig memory cfg
    ) private returns (uint256 requestId, uint256 assetsOut) {
        if (intent.fund != address(SHARES_CONTRACT)) {
            revert FundMismatch(address(SHARES_CONTRACT), intent.fund);
        }
        if (intent.asset != nav.asset) revert AssetMismatch(nav.asset, intent.asset);
        if (intent.sharesIn == 0) revert InvalidAmount();
        if (intent.sharesIn > cfg.maxSharesInPerTx) revert PerTxCapExceeded(intent.sharesIn, cfg.maxSharesInPerTx);
        if (block.timestamp > intent.deadline) revert IntentExpired(intent.deadline, block.timestamp);

        uint256 currentEpoch = intentEpoch[intent.owner];
        if (intent.epoch != currentEpoch) revert IntentEpochMismatch(intent.epoch, currentEpoch);

        _validateReceiver(intent.receiver);

        if (cfg.minHoldingPeriod != 0) {
            uint64 heldSince = sharesHeldSince[intent.owner];
            if (heldSince != 0) {
                uint64 requiredUntil = heldSince + cfg.minHoldingPeriod;
                if (block.timestamp < requiredUntil) revert HoldingPeriodNotElapsed(heldSince, requiredUntil);
            }
        }

        // Consume the digest before any external call, so an ERC-1271 owner or a hostile token cannot
        // replay this intent from inside a callback.
        bytes32 digest = hashRedemptionIntent(intent);
        if (consumedIntent[digest]) revert IntentAlreadyConsumed(digest);
        consumedIntent[digest] = true;

        if (!SignatureChecker.isValidSignatureNow(intent.owner, digest, intentSig)) {
            revert InvalidIntentSignature();
        }

        // `previewRedemption` applies the redemption fee and then `sharesToAssets`, exactly as
        // `_approveRedeemRequest` does (`kpkShares.sol:845-855`), so this equals what settlement will
        // compute at the same price.
        assetsOut = SHARES_CONTRACT.previewRedemption(intent.sharesIn, nav.sharesPrice, intent.asset);
        if (assetsOut == 0) revert InvalidAmount();
        if (assetsOut < intent.minAssetsOut) revert InsufficientOutput(assetsOut, intent.minAssetsOut);

        _consumePayoutBudget(intent.asset, assetsOut, cfg.maxAssetsOutPerDay);

        // The router must OWN the shares: `requestRedemption` escrows them with an internal
        // `_transfer` from `msg.sender` (`kpkShares.sol:342`), not a `transferFrom`.
        IERC20(address(SHARES_CONTRACT)).safeTransferFrom(intent.owner, address(this), intent.sharesIn);

        requestId = SHARES_CONTRACT.requestRedemption(intent.sharesIn, assetsOut, intent.asset, intent.receiver);
    }

    //
    // Internal — settlement and invariants
    //

    /// @dev Approves exactly one request at the attested price.
    function _settleSingle(uint256 requestId, address asset, uint256 sharesPrice) private {
        uint256[] memory approveRequests = new uint256[](1);
        approveRequests[0] = requestId;

        SHARES_CONTRACT.processRequests(approveRequests, new uint256[](0), asset, sharesPrice);
    }

    /// @dev The atomicity invariant: no request this router created may outlive the transaction in a
    ///      non-`PROCESSED` state.
    ///
    ///      `processRequests` returns successfully while leaving a request `PENDING` if the asset
    ///      argument does not match the request's asset (`kpkShares.sol:723`). Since `investor` on a
    ///      router-created request is the router, every refund path (`:293`, `:809`, `:404`, `:882`)
    ///      would pay this contract rather than the user, leaving their principal stranded and
    ///      unattributed. Reverting deletes the just-created request, so the violation is made
    ///      impossible rather than recovered from.
    function _assertSettled(uint256 requestId) private view {
        IkpkShares.RequestStatus status = SHARES_CONTRACT.getRequest(requestId).requestStatus;
        if (status != IkpkShares.RequestStatus.PROCESSED) revert RequestNotSettled(requestId, uint8(status));
    }

    /// @dev Asserts the router kept none of the subscription asset and left no standing allowance to the
    ///      shares proxy. The exact-amount `forceApprove` is fully consumed by the pull inside
    ///      `requestSubscription` (`kpkShares.sol:228`), so any remainder means the flow diverged.
    function _assertNoResidualAsset(address asset, uint256 balanceBefore) private view {
        uint256 balanceAfter = IERC20(asset).balanceOf(address(this));
        if (balanceAfter != balanceBefore) revert ResidualBalance(asset, balanceBefore, balanceAfter);

        uint256 residual = IERC20(asset).allowance(address(this), address(SHARES_CONTRACT));
        if (residual != 0) revert ResidualAllowance(residual);
    }

    /// @dev Requires that `requestId` is a request this router itself created, and returns its asset.
    ///
    ///      `KpkShares._requireCancellationAuthorization` (`:707`) authorises the investor OR the
    ///      receiver, so anyone can call `requestSubscription` directly on the fund naming this router
    ///      as receiver, which makes the router an authorised canceller of their request. Without this
    ///      check an admin could cancel a stranger's pending subscription: the fund refunds the real
    ///      investor so nothing is stolen, but a third party's request dies and an `EmergencyCancelled`
    ///      event misattributes it to this router.
    function _requireOwnRequest(uint256 requestId) private view returns (address asset) {
        IkpkShares.UserRequest memory request = SHARES_CONTRACT.getRequest(requestId);
        if (request.investor != address(this)) revert NotRouterRequest(requestId, request.investor);

        return request.asset;
    }

    /// @dev Verifies what the receiver ACTUALLY got, against the quoted payout rather than the owner's
    ///      floor. Comparing against `intent.minAssetsOut` would be near-vacuous: an owner who signs a
    ///      permissive floor — commonly 1 wei, as the app does when it trusts the quote — would accept
    ///      almost any shortfall. `KpkShares` only ever compares numbers it computed itself (`:856`), so
    ///      this is the sole check on a token that delivers less than it reports.
    function _assertDelivered(address asset, address receiver, uint256 balanceBefore, uint256 expected) private view {
        uint256 delivered = IERC20(asset).balanceOf(receiver) - balanceBefore;
        if (delivered < expected) revert InsufficientOutput(delivered, expected);
    }

    /// @dev Asserts the router ends the call holding no more shares than it started with.
    function _assertNoResidualShares(uint256 expected) private view {
        uint256 actual = IERC20(address(SHARES_CONTRACT)).balanceOf(address(this));
        if (actual != expected) revert ResidualBalance(address(SHARES_CONTRACT), expected, actual);
    }

    //
    // Internal — volume budgets
    //

    /// @dev Charges `amount` against the asset's daily share-mint budget.
    function _consumeMintBudget(address asset, uint256 amount, uint256 cap) private {
        DailyUsage storage usage = _dailyUsage[asset][block.timestamp / 1 days];

        uint256 used = usage.sharesMinted;
        if (used + amount > cap) revert DailyCapExceeded(amount, cap > used ? cap - used : 0);

        usage.sharesMinted = used + amount;
    }

    /// @dev Charges `amount` against the asset's daily payout budget.
    function _consumePayoutBudget(address asset, uint256 amount, uint256 cap) private {
        DailyUsage storage usage = _dailyUsage[asset][block.timestamp / 1 days];

        uint256 used = usage.assetsPaid;
        if (used + amount > cap) revert DailyCapExceeded(amount, cap > used ? cap - used : 0);

        usage.assetsPaid = used + amount;
    }
}
