// SPDX-License-Identifier: MIT
pragma solidity ^0.8;

import {
    IERC20,
    ERC20Upgradeable,
    IERC20Metadata
} from "@openzeppelin/contracts-upgradeable/token/ERC20/ERC20Upgradeable.sol";
import {AccessControlUpgradeable} from "@openzeppelin/contracts-upgradeable/access/AccessControlUpgradeable.sol";
import {ReentrancyGuardUpgradeable} from "@openzeppelin/contracts-upgradeable/utils/ReentrancyGuardUpgradeable.sol";
import {IERC165} from "@openzeppelin/contracts/utils/introspection/IERC165.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {UUPSUpgradeable} from "@openzeppelin/contracts-upgradeable/proxy/utils/UUPSUpgradeable.sol";
import {Initializable} from "@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol";
import {IPerfFeeModule} from "./FeeModules/IPerfFeeModule.sol";
import {IKpkSharesNav} from "./IKpkSharesNav.sol";
import {INavCalculator} from "./interfaces/INavCalculator.sol";
import {NavPricingLib} from "./utils/NavPricingLib.sol";
import {RecoverFunds} from "./utils/RecoverFunds.sol";

/// @title  KpkSharesNav - NAV-priced Onchain Investment Vehicle
/// @author kpk
/// @notice Fund shares whose price is derived on-chain from karpatkey's NAV calculator, for a fund
///         whose assets live entirely on one chain.
/// @dev    This is a sibling of `KpkShares`, not a replacement, and deliberately shares no code with
///         it: `KpkSharesDeployer` hardcodes `type(KpkShares).creationCode` and `KpkOivFactory`
///         embeds `KpkShares.ConstructorParams`, so any edit to those files — NatSpec included —
///         would move CREATE2 addresses that are already live and Safe-owned on 19 chains.
///
///         WHAT CHANGES, AND WHY IT MATTERS
///         `KpkShares` takes the price per share as a calldata argument from the OPERATOR, bounded
///         only by a +/-30% deviation guard and each request's own slippage bound. This contract
///         takes no price from anyone. It reads the fund's NAV from the NAV calculator and divides
///         by the share supply, in the same transaction as the mint or burn it prices. The operator
///         keeps the power to decide WHICH requests settle and WHEN, but not at WHAT price — so the
///         deviation guard, which existed only to bound operator error, is gone with the parameter
///         it was guarding.
///
///         SINGLE-CHAIN ONLY. `getAccountNav` values one account on one chain. A fund holding assets
///         on several chains would price itself off a fraction of its own book and systematically
///         misprice every subscription and redemption. Do not deploy this for a multi-chain fund.
///
///         FAIL-CLOSED BY DESIGN. If any price behind the NAV is stale, irregular, or the sequencer
///         is down, pricing REVERTS rather than falling back to anything remembered. A recorded
///         price is kept for observability only and is never read back as an input. The cost is
///         liveness: while the NAV is unhealthy the fund cannot mint or burn. Escrow stays
///         refundable throughout — cancellations need no price, and a `processRequests` call with an
///         empty approve list skips the NAV read entirely so the operator can always return funds.
///
///         TRUST ASSUMPTION: THE NAV CALCULATOR IS TAKEN TO BE CORRECT.
///         A NAV that reports itself healthy is accepted and settled against without any bound on
///         the resulting price. This is a deliberate decision, not an oversight, and it is the load-
///         bearing assumption of the whole contract — so be clear about what it does and does not
///         cover.
///
///         What it means in practice: a NAV that is WRONG BUT HEALTHY — a balance adapter that
///         double-counts a position, a feed that is fresh and mispriced, a newly registered adapter
///         with a decimals slip — passes every gate here and mints or burns at that price. Nothing
///         in this contract caps how far a single settlement may move. `KpkShares` incidentally
///         bounded that class with its +/-30% deviation guard; this contract has no equivalent, by
///         design, because the guard bounded an OPERATOR-supplied price and there no longer is one.
///
///         What it does NOT waive: the health flags. Those are the NAV telling us it cannot vouch
///         for itself right now, and trusting the calculator includes trusting that signal — which
///         is why the gate in `NavPricingLib` is strict rather than advisory.
///
///         The consequence to hold in mind: this fund's share price is exactly as trustworthy as
///         the NAV stack behind it, so the NAV calculator's access control is effectively this
///         fund's access control. Whoever holds MANAGER there can re-point feeds and register
///         adapters, and therefore reprice every share here. Treat a change of custody over that
///         role as equivalent in impact to a change of custody over this contract's admin.
contract KpkSharesNav is
    Initializable,
    UUPSUpgradeable,
    AccessControlUpgradeable,
    ERC20Upgradeable,
    ReentrancyGuardUpgradeable,
    IKpkSharesNav,
    RecoverFunds
{
    //
    // Libraries
    //
    using SafeERC20 for IERC20;

    //
    // Constants
    //

    /// @notice The NAV calculator's USD scale, asserted whenever a NAV calculator is accepted
    /// @dev All prices in this contract — the share price and every asset price — are USD with this
    ///      many decimals, which is what lets them be divided against each other directly.
    uint8 private constant _EXPECTED_USD_DECIMALS = 8;

    uint256 private constant _PRECISION_BPS = 10_000;

    /// @notice Maximum time-to-live for requests (7 days)
    uint64 public constant MAX_TTL = 7 days;

    /// @notice Maximum fee rate allowed (2000 = 20%)
    uint256 public constant MAX_FEE_RATE = 2000;

    /// @notice Number of seconds in a year (365 days)
    uint256 public constant SECONDS_PER_YEAR = 365 days;

    /// @notice Minimum time elapsed required for fee calculations (6 hours)
    uint256 public constant MIN_TIME_ELAPSED = 6 hours;

    /// @notice Maximum asset decimals accepted, to bound the conversion arithmetic
    uint8 private constant MAX_ASSET_DECIMALS = 36;

    /// @notice Role identifier for operators
    bytes32 public constant OPERATOR = keccak256("OPERATOR");

    //
    // State Variables
    //

    /// @notice List of added assets
    address[] private _approvedAssets;

    /// @notice Asset configurations mapped by asset address
    mapping(address => ApprovedAsset) private _approvedAssetsMap;

    /// @notice Unique identifier for requests
    uint256 public requestId;

    /// @notice Portfolio safe address where assets are held, and the account the NAV is read for
    address public portfolioSafe;

    /// @notice Performance fee module address
    address public performanceFeeModule;

    /// @notice Total assets pending in subscription requests
    mapping(address => uint256) public subscriptionAssets;

    /// @notice Counter of pending requests (subscriptions + redemptions) per asset
    mapping(address => uint256) private _pendingRequestsCount;

    /// @notice Time-to-live for subscription requests before they can be cancelled
    uint64 public subscriptionRequestTtl;

    /// @notice Time-to-live for redemption requests before they can be cancelled
    uint64 public redemptionRequestTtl;

    /// @notice Address that receives fee shares
    address public feeReceiver;

    /// @notice Management fee rate (in basis points, 2000 = 20%)
    uint256 public managementFeeRate;

    /// @notice Redemption fee rate (in basis points, 2000 = 20%)
    uint256 public redemptionFeeRate;

    /// @notice Performance fee rate (in basis points, 2000 = 20%)
    uint256 public performanceFeeRate;

    /// @notice Management fee last update timestamp
    uint256 private _managementFeeLastUpdate;

    /// @notice Performance fee last update timestamp
    uint256 private _performanceFeeLastUpdate;

    /// @notice Requests indexed by request ID
    mapping(uint256 requestId => UserRequest request) private _requests;

    /// @notice The NAV calculator this fund prices itself from
    address public navCalculator;

    /// @notice Whether the synchronous deposit path is open
    /// @dev Starts false. Enabling it is a deliberate admin act, which is what keeps the bootstrap
    ///      window (see `initialSharePrice`) closed until the fund has been seeded.
    bool public syncDepositsEnabled;

    /// @notice Timestamp of the most recent pricing event (observability only)
    uint64 public lastPricedAt;

    /// @notice Price per share used while no shares are outstanding (USD, 8 decimals)
    uint256 public initialSharePrice;

    /// @notice Most recently settled price per share (USD, 8 decimals), observability only
    /// @dev NEVER read back as a pricing input. Recording a price and reusing it is exactly the
    ///      stale-price behaviour this contract exists to remove.
    uint256 public lastSharePriceUsd;

    /// @notice Reserved storage to allow future variables without shifting an upgraded layout
    uint256[50] private __gap;

    //
    // Constructor
    //

    /// @custom:oz-upgrades-unsafe-allow constructor
    constructor() {
        _disableInitializers();
    }

    //
    // Initialization
    //

    /// @notice Parameters for fund initialization
    /// @param asset The address of the base asset, auto-listed for deposits and redemptions
    /// @param admin The address of the initial default admin
    /// @param name The name of the shares
    /// @param symbol The symbol of the shares
    /// @param safe The portfolio safe: holds the assets, and is the account the NAV is read for
    /// @param subscriptionRequestTtl The time-to-live for subscription requests
    /// @param redemptionRequestTtl The time-to-live for redemption requests
    /// @param feeReceiver The address that receives fee shares
    /// @param managementFeeRate The management fee rate (in basis points, 2000 = 20%)
    /// @param redemptionFeeRate The redemption fee rate (in basis points, 2000 = 20%)
    /// @param performanceFeeModule The performance fee module address
    /// @param performanceFeeRate The performance fee rate (in basis points, 2000 = 20%)
    /// @param navCalculator The NAV calculator proxy this fund prices itself from
    /// @param initialSharePrice The price per share to use while no shares exist (USD, 8 decimals)
    struct ConstructorParams {
        address asset;
        address admin;
        string name;
        string symbol;
        address safe;
        uint64 subscriptionRequestTtl;
        uint64 redemptionRequestTtl;
        address feeReceiver;
        uint256 managementFeeRate;
        uint256 redemptionFeeRate;
        address performanceFeeModule;
        uint256 performanceFeeRate;
        address navCalculator;
        uint256 initialSharePrice;
    }

    /// @notice Initialize the contract with fund parameters
    /// @param params Initialization parameters
    function initialize(ConstructorParams memory params) external initializer {
        __UUPSUpgradeable_init();
        __AccessControl_init();
        __ERC20_init(params.name, params.symbol);
        __Context_init();
        __ERC165_init();
        __ReentrancyGuard_init();
        _validateInitializationParams(params);
        _initializeState(params);
        _setupRoles(params.admin);
    }

    //
    // Authorization Functions
    //

    /// @notice Modifier to check if the caller is an admin
    modifier isAdmin() {
        if (!hasRole(DEFAULT_ADMIN_ROLE, msg.sender)) revert NotAuthorized();
        _;
    }

    /// @notice Modifier to check if the caller is an operator
    modifier isOperator() {
        if (!hasRole(OPERATOR, msg.sender)) revert NotAuthorized();
        _;
    }

    //
    // Pricing
    //

    /// @inheritdoc IKpkSharesNav
    function getSharePriceUsd() external view returns (uint256) {
        uint256 sharesSupply = totalSupply();
        if (sharesSupply == 0) return initialSharePrice;

        (uint256 sharePriceUsd,) =
            NavPricingLib.sharePriceUsd(navCalculator, portfolioSafe, sharesSupply, 10 ** decimals());
        if (sharePriceUsd == 0) revert SharePriceZero();
        return sharePriceUsd;
    }

    /// @notice Take a full pricing snapshot for one asset
    /// @param asset The asset the batch or deposit is denominated in
    /// @return pricing The snapshot
    /// @return navValue The NAV the share price came from
    /// @return sharesSupply The supply the share price was derived against
    function _snapshot(address asset)
        internal
        view
        returns (NavPricingLib.Pricing memory pricing, int256 navValue, uint256 sharesSupply)
    {
        sharesSupply = totalSupply();
        uint256 shareUnit = 10 ** decimals();

        (uint256 sharePriceUsd, uint256 assetPriceUsd, int256 navValue_) =
            NavPricingLib.snapshot(navCalculator, portfolioSafe, asset, sharesSupply, shareUnit, initialSharePrice);
        if (sharePriceUsd == 0) revert SharePriceZero();

        navValue = navValue_;
        pricing = NavPricingLib.Pricing({
            sharePriceUsd: sharePriceUsd,
            assetPriceUsd: assetPriceUsd,
            assetDecimals: _approvedAssetsMap[asset].decimals,
            shareUnit: shareUnit
        });
    }

    /// @notice Re-derives the settlement price after fee shares have been minted
    /// @param pricing The snapshot taken before the fee accrual, updated in place
    /// @param navValue The NAV that snapshot came from
    /// @param preFeeSupply The supply the snapshot priced against
    /// @dev Fee shares dilute: they raise the supply while leaving the NAV untouched, so the price
    ///      that was correct a moment ago is now too high. Settling requests at the pre-fee price
    ///      splits that dilution unfairly in BOTH directions — a subscriber pays for fees that
    ///      accrued before they joined, and a redeemer leaves without bearing fees they did accrue.
    ///      The management fee makes this negligible (rate-capped and throttled to once per six
    ///      hours), but the PERFORMANCE fee is a share of gains rather than a rate, so after a long
    ///      interval it can be a large fraction of supply: a fund up 100% since its watermark mints
    ///      ~10% of supply in one event, and a subscriber in that batch would be short-changed ~9%.
    ///      Re-deriving costs one division and no second adapter scan, because the NAV has not moved.
    /// @return pricedSupply The supply the returned price actually corresponds to, so the caller can
    ///         report a price and a supply that agree with each other
    function _repriceAfterFees(NavPricingLib.Pricing memory pricing, int256 navValue, uint256 preFeeSupply)
        internal
        view
        returns (uint256 pricedSupply)
    {
        // Nothing was outstanding to dilute (the bootstrap batch), so there is nothing to re-derive.
        if (preFeeSupply == 0) return preFeeSupply;

        uint256 postFeeSupply = totalSupply();
        if (postFeeSupply == preFeeSupply) return preFeeSupply;

        uint256 repriced = NavPricingLib.sharePriceFrom(navValue, postFeeSupply, pricing.shareUnit);
        if (repriced == 0) revert SharePriceZero();
        pricing.sharePriceUsd = repriced;
        return postFeeSupply;
    }

    /// @notice Record a pricing event for observability
    /// @param sharePriceUsd The price settled at
    /// @param navValue The NAV it came from
    /// @param sharesSupply The supply it was derived against
    function _recordPricing(uint256 sharePriceUsd, int256 navValue, uint256 sharesSupply) internal {
        lastSharePriceUsd = sharePriceUsd;
        lastPricedAt = uint64(block.timestamp);
        emit SharePriceSettlement(sharePriceUsd, navValue, sharesSupply);
    }

    //
    // Conversions
    //

    //
    // Subscription Operations
    //

    /// @inheritdoc IKpkSharesNav
    function previewSubscription(uint256 assets, address subscriptionAsset) external view returns (uint256) {
        if (!_approvedAssetsMap[subscriptionAsset].canDeposit) revert NotAnApprovedAsset();
        (NavPricingLib.Pricing memory pricing,,) = _snapshot(subscriptionAsset);
        return NavPricingLib.assetsToShares(assets, pricing);
    }

    /// @inheritdoc IKpkSharesNav
    function requestSubscription(uint256 assetsIn, uint256 minSharesOut, address subscriptionAsset, address receiver)
        external
        nonReentrant
        returns (uint256)
    {
        _requireValidRequestParams(assetsIn, minSharesOut, receiver);

        if (!_approvedAssetsMap[subscriptionAsset].canDeposit) revert NotAnApprovedAsset();

        // Record the escrow BEFORE pulling the assets. `RecoverFunds.recoverAssets` is permissionless
        // and carries no reentrancy guard of its own, so `nonReentrant` here does not cover it: with a
        // callback-bearing token, the transfer's hook lands in a window where the fund's balance has
        // already risen while `subscriptionAssets` and `_pendingRequestsCount` still read zero — and
        // both of those are exactly what `_assetRecoverableAmount` consults before allowing a sweep.
        // Crediting first collapses the window. (`KpkShares` has the opposite order; it is frozen and
        // cannot be corrected there.)
        subscriptionAssets[subscriptionAsset] += assetsIn;
        _pendingRequestsCount[subscriptionAsset]++;
        uint256 currentRequestId = ++requestId;

        IERC20(subscriptionAsset).safeTransferFrom(msg.sender, address(this), assetsIn);

        uint64 currentTimestamp = uint64(block.timestamp);
        uint64 expiryAt = currentTimestamp + MAX_TTL;
        uint64 cancelableFrom = currentTimestamp + subscriptionRequestTtl;

        _requests[currentRequestId] = UserRequest({
            requestType: RequestType.SUBSCRIPTION,
            requestStatus: RequestStatus.PENDING,
            asset: subscriptionAsset,
            assetAmount: assetsIn,
            sharesAmount: minSharesOut,
            investor: msg.sender,
            receiver: receiver,
            timestamp: currentTimestamp,
            expiryAt: expiryAt
        });

        emit SubscriptionRequest(
            msg.sender,
            currentRequestId,
            receiver,
            subscriptionAsset,
            assetsIn,
            minSharesOut,
            currentTimestamp,
            cancelableFrom,
            expiryAt
        );

        return currentRequestId;
    }

    /// @inheritdoc IKpkSharesNav
    /// @dev DONATION HAZARD. The price is `NAV / totalSupply`, and the NAV measures a safe that
    ///      anyone can send tokens to. Rounding-to-zero theft is blocked because `minSharesOut` must
    ///      be non-zero, so a caller quoted too few shares reverts rather than donating. The residual
    ///      is that while the supply is dust — at launch, or after a full redemption that leaves the
    ///      safe holding assets — a donation moves the price for whoever is left. The control is
    ///      operational: `syncDepositsEnabled` starts false, so seed the fund through an
    ///      operator-approved request before opening this path, and close it again if the supply is
    ///      ever fully redeemed.
    function subscribe(uint256 assetsIn, uint256 minSharesOut, address subscriptionAsset, address receiver)
        external
        nonReentrant
        returns (uint256 sharesOut)
    {
        if (!syncDepositsEnabled) revert SyncDepositsDisabled();

        // The bootstrap branch prices at `initialSharePrice` WITHOUT reading the NAV — so while the
        // supply is zero there is no health gate and no relationship between the price and what the
        // safe actually holds. That window is not only the fund's launch: it re-arms every time the
        // supply returns to zero, which a full redemption does while the safe still carries anything
        // a payout could not drain. Left open, the next caller mints 100% of the supply at a
        // constant price and captures the residual. Bootstrapping is therefore operator-only; the
        // permissionless path refuses to be the one that opens a fund.
        if (totalSupply() == 0) revert BootstrapRequiresOperator();

        _requireValidRequestParams(assetsIn, minSharesOut, receiver);
        if (!_approvedAssetsMap[subscriptionAsset].canDeposit) revert NotAnApprovedAsset();

        // Price BEFORE the assets move. The NAV is read for the portfolio safe, so pricing after the
        // transfer would value the deposit against its own contribution and mint against it twice.
        (NavPricingLib.Pricing memory pricing, int256 navValue, uint256 sharesSupply) = _snapshot(subscriptionAsset);
        _chargeFees(pricing.sharePriceUsd);
        // Fees just diluted the supply; price this deposit at the rate that reflects it.
        sharesSupply = _repriceAfterFees(pricing, navValue, sharesSupply);

        sharesOut = NavPricingLib.assetsToShares(assetsIn, pricing);
        if (sharesOut < minSharesOut) revert SlippageBoundNotMet();

        _mint(receiver, sharesOut);
        _recordPricing(pricing.sharePriceUsd, navValue, sharesSupply);

        // Straight to the safe: a synchronous deposit never enters request escrow, so
        // `subscriptionAssets` and `_pendingRequestsCount` stay untouched and the fund-recovery
        // accounting that reads them keeps its meaning.
        IERC20(subscriptionAsset).safeTransferFrom(msg.sender, portfolioSafe, assetsIn);

        emit SyncSubscription(msg.sender, receiver, subscriptionAsset, assetsIn, sharesOut, pricing.sharePriceUsd);
    }

    /// @inheritdoc IKpkSharesNav
    function cancelSubscription(uint256 id) external nonReentrant {
        UserRequest memory request = _requests[id];

        if (!_checkValidRequest(request.investor, request.requestStatus)) revert RequestNotPending();
        if (request.requestType != RequestType.SUBSCRIPTION) revert RequestTypeMismatch();
        if (block.timestamp < request.timestamp + subscriptionRequestTtl) revert RequestNotPastTtl();

        _requireCancellationAuthorization(request.investor, request.receiver);

        uint256 totalAssets = request.assetAmount;
        subscriptionAssets[request.asset] -= totalAssets;
        _pendingRequestsCount[request.asset]--;
        _requests[id].requestStatus = RequestStatus.CANCELLED;

        IERC20(request.asset).safeTransfer(request.investor, totalAssets);

        emit SubscriptionCancellation(id, msg.sender);
    }

    //
    // Redemption Operations
    //

    /// @inheritdoc IKpkSharesNav
    function previewRedemption(uint256 shares, address redemptionAsset) external view returns (uint256) {
        if (!_approvedAssetsMap[redemptionAsset].canRedeem) revert UnredeemableAsset();
        (NavPricingLib.Pricing memory pricing,,) = _snapshot(redemptionAsset);

        uint256 redemptionFee;
        if (redemptionFeeRate > 0) {
            redemptionFee = (shares * redemptionFeeRate) / _PRECISION_BPS;
        }

        return NavPricingLib.sharesToAssets(shares - redemptionFee, pricing);
    }

    /// @inheritdoc IKpkSharesNav
    function requestRedemption(uint256 sharesIn, uint256 minAssetsOut, address redemptionAsset, address receiver)
        external
        nonReentrant
        returns (uint256)
    {
        _requireValidRequestParams(sharesIn, minAssetsOut, receiver);

        if (!_approvedAssetsMap[redemptionAsset].canRedeem) revert NotAnApprovedAsset();

        // Escrow the shares on this contract until the request settles
        _transfer(msg.sender, address(this), sharesIn);

        uint256 currentRequestId = ++requestId;

        uint64 currentTimestamp = uint64(block.timestamp);
        uint64 expiryAt = currentTimestamp + MAX_TTL;
        uint64 cancelableFrom = currentTimestamp + redemptionRequestTtl;

        _requests[currentRequestId] = UserRequest({
            requestType: RequestType.REDEMPTION,
            requestStatus: RequestStatus.PENDING,
            asset: redemptionAsset,
            assetAmount: minAssetsOut,
            sharesAmount: sharesIn,
            investor: msg.sender,
            receiver: receiver,
            timestamp: currentTimestamp,
            expiryAt: expiryAt
        });
        _pendingRequestsCount[redemptionAsset]++;

        emit RedemptionRequest(
            msg.sender,
            currentRequestId,
            receiver,
            redemptionAsset,
            minAssetsOut,
            sharesIn,
            currentTimestamp,
            cancelableFrom,
            expiryAt
        );

        return currentRequestId;
    }

    /// @inheritdoc IKpkSharesNav
    function cancelRedemption(uint256 id) external nonReentrant {
        UserRequest memory request = _requests[id];

        if (!_checkValidRequest(request.investor, request.requestStatus)) revert RequestNotPending();
        if (request.requestType != RequestType.REDEMPTION) revert RequestTypeMismatch();
        if (block.timestamp < request.timestamp + redemptionRequestTtl) revert RequestNotPastTtl();

        _requireCancellationAuthorization(request.investor, request.receiver);

        _pendingRequestsCount[request.asset]--;
        _requests[id].requestStatus = RequestStatus.CANCELLED;

        // Return shares from escrow to investor
        _transfer(address(this), request.investor, request.sharesAmount);

        emit RedemptionCancellation(id, msg.sender);
    }

    //
    // Operator Functions
    //

    /// @inheritdoc IKpkSharesNav
    function processRequests(uint256[] calldata approveRequests, uint256[] calldata rejectRequests, address asset)
        external
        isOperator
        nonReentrant
    {
        // Rejections move no value at a price, so they must stay available when the fund cannot be
        // priced. Only reach for the NAV when something is actually being approved.
        if (approveRequests.length != 0) {
            (NavPricingLib.Pricing memory pricing, int256 navValue, uint256 sharesSupply) = _snapshot(asset);
            _chargeFees(pricing.sharePriceUsd);
            // Fees just diluted the supply; settle the batch at the price that reflects it.
            sharesSupply = _repriceAfterFees(pricing, navValue, sharesSupply);
            _processApproved(approveRequests, asset, pricing);
            _recordPricing(pricing.sharePriceUsd, navValue, sharesSupply);
        }

        _processRejected(rejectRequests, asset);
    }

    /// @inheritdoc IKpkSharesNav
    function updateAsset(address asset, bool canDeposit, bool canRedeem) external isOperator {
        _updateAsset(asset, canDeposit, canRedeem);
    }

    //
    // Admin Functions
    //

    /// @inheritdoc IKpkSharesNav
    function setSubscriptionRequestTtl(uint64 ttl) external isAdmin {
        if (ttl == 0) revert InvalidArguments();
        _setSubscriptionRequestTtl(ttl);
    }

    /// @inheritdoc IKpkSharesNav
    function setRedemptionRequestTtl(uint64 ttl) external isAdmin {
        if (ttl == 0) revert InvalidArguments();
        _setRedemptionRequestTtl(ttl);
    }

    /// @inheritdoc IKpkSharesNav
    function setFeeReceiver(address newFeeReceiver) external isAdmin {
        if (newFeeReceiver == address(0)) revert InvalidArguments();
        _setFeeReceiver(newFeeReceiver);
    }

    /// @inheritdoc IKpkSharesNav
    function setManagementFeeRate(uint256 newRate) external isAdmin {
        if (newRate > MAX_FEE_RATE) revert FeeRateLimitExceeded();
        if (managementFeeRate != newRate) {
            _setManagementFeeRate(newRate);
        }
    }

    /// @inheritdoc IKpkSharesNav
    function setRedemptionFeeRate(uint256 newRate) external isAdmin {
        if (newRate > MAX_FEE_RATE) revert FeeRateLimitExceeded();
        if (redemptionFeeRate != newRate) {
            _setRedemptionFeeRate(newRate);
        }
    }

    /// @inheritdoc IKpkSharesNav
    function setPerformanceFeeRate(uint256 newRate) external isAdmin {
        if (newRate > MAX_FEE_RATE) revert FeeRateLimitExceeded();
        // Same pairing the initializer enforces: a rate with no module to compute it is inert, and
        // `performanceFeeRate()` would report a fee that can never accrue.
        if (newRate > 0 && performanceFeeModule == address(0)) revert InvalidArguments();
        if (performanceFeeRate != newRate) {
            _setPerformanceFeeRate(newRate);
        }
    }

    /// @inheritdoc IKpkSharesNav
    function setPerformanceFeeModule(address newPerfFeeModule) external isAdmin {
        // address(0) disables performance fees, but only once the rate is zero too — otherwise the
        // pairing enforced at initialization could be walked back into in two admin calls.
        if (newPerfFeeModule == address(0) && performanceFeeRate > 0) revert InvalidArguments();
        _setPerformanceFeeModule(newPerfFeeModule);
    }

    /// @inheritdoc IKpkSharesNav
    function setNavCalculator(address newNavCalculator) external isAdmin {
        _validateNavCalculator(newNavCalculator);

        // Refuse a NAV that cannot price what this fund already lists, which would leave the fund
        // unable to settle anything until the asset were delisted — and the last asset cannot be
        // delisted at all. This applies exactly the same test the listing path applies, against the
        // CANDIDATE: registration alone is not enough. A registry that merely knows an asset but has
        // no feed for it bricks settlement, and one that disagrees with the token's decimals is
        // worse than bricked — it silently rescales the safe's valuation by a power of ten.
        uint256 length = _approvedAssets.length;
        for (uint256 i; i < length; i++) {
            address listed = _approvedAssets[i];
            _requireNavSupportsAsset(newNavCalculator, listed, _approvedAssetsMap[listed].decimals);
        }

        if (navCalculator != newNavCalculator) {
            emit NavCalculatorUpdate(navCalculator, newNavCalculator);
            navCalculator = newNavCalculator;
        }
    }

    /// @inheritdoc IKpkSharesNav
    function setSyncDepositsEnabled(bool enabled) external isAdmin {
        if (syncDepositsEnabled != enabled) {
            syncDepositsEnabled = enabled;
            emit SyncDepositsEnabledUpdate(enabled);
        }
    }

    //
    // View Functions
    //

    /// @inheritdoc IKpkSharesNav
    function getApprovedAssets() external view returns (address[] memory) {
        uint256 length = _approvedAssets.length;
        address[] memory assets = new address[](length);
        for (uint256 i = 0; i < length; i++) {
            assets[i] = _approvedAssets[i];
        }
        return assets;
    }

    /// @inheritdoc IKpkSharesNav
    function getApprovedAsset(address asset) external view returns (ApprovedAsset memory) {
        return _approvedAssetsMap[asset];
    }

    /// @inheritdoc IKpkSharesNav
    function isApprovedAsset(address asset) external view returns (bool) {
        ApprovedAsset memory assetConfig = _approvedAssetsMap[asset];
        return assetConfig.asset != address(0) && (assetConfig.canDeposit || assetConfig.canRedeem);
    }

    /// @inheritdoc IKpkSharesNav
    function assetDecimals(address asset) external view returns (uint8) {
        return _approvedAssetsMap[asset].decimals;
    }

    /// @inheritdoc IKpkSharesNav
    function getRequest(uint256 id) external view returns (UserRequest memory) {
        return _requests[id];
    }

    //
    // Overrides
    //

    /// @inheritdoc UUPSUpgradeable
    // solhint-disable-next-line no-empty-blocks
    function _authorizeUpgrade(
        address /* newImpl */
    )
        internal
        view
        override(UUPSUpgradeable)
        isAdmin
    {
        // Authorization is handled by the isAdmin modifier
    }

    /// @inheritdoc IERC165
    function supportsInterface(bytes4 interfaceId)
        public
        view
        override(IERC165, AccessControlUpgradeable)
        returns (bool)
    {
        return interfaceId == type(IKpkSharesNav).interfaceId || super.supportsInterface(interfaceId);
    }

    /// @inheritdoc RecoverFunds
    /// @dev WARNING: This function assumes tokens are not rebasing or fee-on-transfer.
    function _assetRecoverableAmount(address token) internal view override(RecoverFunds) returns (uint256) {
        // Hard-block the share token from being recovered
        if (token == address(this)) return 0;

        // Never sweep an asset with live requests, even if its config has been deleted
        if (_hasPendingRequests(token)) return 0;

        // Never sweep recorded escrow, even if its config has been deleted
        if (subscriptionAssets[token] > 0) return 0;

        return super._assetRecoverableAmount(token);
    }

    /// @inheritdoc RecoverFunds
    function _assetRecoverer() internal view override(RecoverFunds) returns (address) {
        return portfolioSafe;
    }

    //
    // Internal Functions
    //

    /// @notice Validate initialization parameters
    /// @param params The initialization parameters
    function _validateInitializationParams(ConstructorParams memory params) internal view {
        if (
            params.asset == address(0) || params.admin == address(0) || params.safe == address(0)
                || params.feeReceiver == address(0) || params.subscriptionRequestTtl == 0
                || params.redemptionRequestTtl == 0 || params.initialSharePrice == 0
        ) {
            revert InvalidArguments();
        }

        if (params.managementFeeRate > MAX_FEE_RATE) revert FeeRateLimitExceeded();
        if (params.performanceFeeRate > MAX_FEE_RATE) revert FeeRateLimitExceeded();
        if (params.redemptionFeeRate > MAX_FEE_RATE) revert FeeRateLimitExceeded();

        // A performance fee rate with no module to compute it is silently inert:
        // `_chargePerformanceFee` returns 0 on every call while `performanceFeeRate()` keeps
        // reporting the configured rate. Refuse the pairing rather than ship a fund whose stated
        // fee never accrues.
        if (params.performanceFeeRate > 0 && params.performanceFeeModule == address(0)) {
            revert InvalidArguments();
        }

        _validateNavCalculator(params.navCalculator);
    }

    /// @notice Validate that an address can serve as this fund's NAV calculator
    /// @param candidate The address to validate
    /// @dev Confirms it is a contract that answers `usdDecimals()` with the 8-decimal USD scale this
    ///      contract's arithmetic assumes. This catches misconfiguration — a wrong address, or the
    ///      superseded NAV proxy — but it cannot constrain a malicious admin, who already holds
    ///      `_authorizeUpgrade` and can replace this logic wholesale.
    function _validateNavCalculator(address candidate) internal view {
        if (candidate == address(0) || candidate.code.length == 0) revert InvalidNavCalculator();

        try INavCalculator(candidate).usdDecimals() returns (uint8 usdDecimals) {
            if (usdDecimals != _EXPECTED_USD_DECIMALS) revert InvalidNavCalculator();
        } catch {
            revert InvalidNavCalculator();
        }
    }

    /// @notice Initialize contract state variables
    /// @param params The initialization parameters
    /// @dev The NAV calculator is set first: listing the base asset consults it.
    function _initializeState(ConstructorParams memory params) internal {
        navCalculator = params.navCalculator;
        initialSharePrice = params.initialSharePrice;
        portfolioSafe = params.safe;

        _updateAsset(params.asset, true, true);

        _setFeeReceiver(params.feeReceiver);
        _setManagementFeeRate(params.managementFeeRate);
        _setRedemptionFeeRate(params.redemptionFeeRate);
        _setPerformanceFeeRate(params.performanceFeeRate);
        _setPerformanceFeeModule(params.performanceFeeModule);

        _setSubscriptionRequestTtl(params.subscriptionRequestTtl);
        _setRedemptionRequestTtl(params.redemptionRequestTtl);

        _managementFeeLastUpdate = block.timestamp;
        _performanceFeeLastUpdate = block.timestamp;
    }

    /// @notice Setup access control roles
    /// @param admin The initial admin address
    function _setupRoles(address admin) internal {
        _grantRole(DEFAULT_ADMIN_ROLE, admin);
    }

    /// @notice Require valid request parameters (reverts on invalid)
    /// @param amountIn The amount (assets or shares) supplied
    /// @param amountOut The caller's minimum acceptable output
    /// @param receiver The receiver address
    /// @dev A zero `amountOut` is rejected, so no caller can waive slippage protection entirely.
    ///      That is what makes a round-to-zero mint impossible on both the request and sync paths.
    function _requireValidRequestParams(uint256 amountIn, uint256 amountOut, address receiver) internal pure {
        if (amountIn == 0 || amountOut == 0 || receiver == address(0)) revert InvalidArguments();
    }

    /// @notice Require the caller may cancel this request
    /// @param investor The request's investor
    /// @param receiver The request's receiver
    function _requireCancellationAuthorization(address investor, address receiver) internal view {
        if (investor != msg.sender && receiver != msg.sender) revert NotAuthorized();
    }

    /// @notice Whether a request is live and actionable
    /// @param investor The request's investor
    /// @param requestStatus The request's status
    /// @return True if the request exists and is pending
    function _checkValidRequest(address investor, RequestStatus requestStatus) internal pure returns (bool) {
        return investor != address(0) && requestStatus == RequestStatus.PENDING;
    }

    /// @notice Whether an asset has live requests against it
    /// @param asset The asset to check
    /// @return True if any request for this asset is pending
    function _hasPendingRequests(address asset) internal view returns (bool) {
        return _pendingRequestsCount[asset] > 0;
    }

    //
    // Request Processing
    //

    /// @notice Process approved requests at one snapshot price
    /// @param approveRequests Array of request IDs to approve
    /// @param asset The asset to process requests for
    /// @param pricing The batch's price snapshot
    function _processApproved(uint256[] calldata approveRequests, address asset, NavPricingLib.Pricing memory pricing)
        internal
    {
        uint256 length = approveRequests.length;
        for (uint256 i; i < length; i++) {
            uint256 id = approveRequests[i];
            UserRequest memory request = _requests[id];
            if (!_checkValidRequest(request.investor, request.requestStatus)) continue;
            if (request.asset != asset) continue;

            if (block.timestamp > request.expiryAt) {
                if (request.requestType == RequestType.SUBSCRIPTION) {
                    _rejectSubscriptionRequest(id, request);
                    emit SubscriptionRequestExpired(id, request.expiryAt);
                } else {
                    _rejectRedeemRequest(id, request);
                    emit RedemptionRequestExpired(id, request.expiryAt);
                }
                continue;
            }

            if (request.requestType == RequestType.SUBSCRIPTION) {
                _approveSubscriptionRequest(id, request, pricing);
            } else {
                _approveRedeemRequest(id, request, pricing);
            }
        }
    }

    /// @notice Process rejected requests
    /// @param rejectRequests Array of request IDs to reject
    /// @param asset The asset to reject requests for
    function _processRejected(uint256[] calldata rejectRequests, address asset) internal {
        uint256 length = rejectRequests.length;
        for (uint256 i; i < length; i++) {
            uint256 id = rejectRequests[i];
            UserRequest memory request = _requests[id];
            if (!_checkValidRequest(request.investor, request.requestStatus)) continue;
            if (request.asset != asset) continue;

            if (request.requestType == RequestType.SUBSCRIPTION) {
                _rejectSubscriptionRequest(id, request);
            } else {
                _rejectRedeemRequest(id, request);
            }
        }
    }

    /// @notice Approve a subscription request
    /// @param id The ID of the request to approve
    /// @param request The request being approved
    /// @param pricing The batch's price snapshot
    /// @dev A request whose slippage bound the derived price cannot meet is SKIPPED, not reverted.
    ///      Reverting made sense when the operator supplied the price and could simply submit a
    ///      better one; it cannot re-price a NAV, so a single unsatisfiable request would otherwise
    ///      brick every batch that contained it. The request stays PENDING for explicit rejection or
    ///      expiry, and the bound itself is never violated.
    function _approveSubscriptionRequest(uint256 id, UserRequest memory request, NavPricingLib.Pricing memory pricing)
        internal
    {
        uint256 sharesOut = NavPricingLib.assetsToShares(request.assetAmount, pricing);
        if (sharesOut < request.sharesAmount) {
            emit RequestSkippedForSlippage(id, request.sharesAmount, sharesOut);
            return;
        }

        // --- Effects ---
        _requests[id].requestStatus = RequestStatus.PROCESSED;
        subscriptionAssets[request.asset] -= request.assetAmount;
        _pendingRequestsCount[request.asset]--;
        _mint(request.receiver, sharesOut);

        // --- Interaction ---
        IERC20(request.asset).safeTransfer(portfolioSafe, request.assetAmount);

        emit SubscriptionApproval(id, request.assetAmount, sharesOut);
    }

    /// @notice Reject a subscription request and return the escrowed assets
    /// @param id The ID of the request to reject
    /// @param request The request being rejected
    /// @dev ACCEPTED: a refund transfer that reverts — an investor added to a token's blocklist while
    ///      their request was in flight, say — reverts the whole batch, unlike the slippage path
    ///      which skips. The operator's remedy is to exclude that id from the batch; the escrow then
    ///      stays stranded and its pending count keeps the asset from being delisted. Isolating each
    ///      refund would need a try/catch per request and a place to record the failure, which does
    ///      not fit the remaining size budget. Revisit if a blocklisting asset is ever listed.
    function _rejectSubscriptionRequest(uint256 id, UserRequest memory request) internal {
        // --- Effects ---
        _requests[id].requestStatus = RequestStatus.REJECTED;
        subscriptionAssets[request.asset] -= request.assetAmount;
        _pendingRequestsCount[request.asset]--;

        // --- Interaction ---
        IERC20(request.asset).safeTransfer(request.investor, request.assetAmount);

        emit SubscriptionDenial(id, request.assetAmount, request.sharesAmount);
    }

    /// @notice Approve a redemption request
    /// @param id The ID of the request to approve
    /// @param request The request being approved
    /// @param pricing The batch's price snapshot
    /// @dev Skips rather than reverts on an unmet slippage bound, for the reason given on
    ///      `_approveSubscriptionRequest`. The redemption fee is only charged once the request is
    ///      known to settle, so a skipped request keeps its full escrow.
    function _approveRedeemRequest(uint256 id, UserRequest memory request, NavPricingLib.Pricing memory pricing)
        internal
    {
        uint256 redemptionFee;
        if (redemptionFeeRate > 0) {
            redemptionFee = (request.sharesAmount * redemptionFeeRate) / _PRECISION_BPS;
        }
        uint256 netShares = request.sharesAmount - redemptionFee;

        uint256 assetsOutNet = NavPricingLib.sharesToAssets(netShares, pricing);
        if (assetsOutNet < request.assetAmount) {
            emit RequestSkippedForSlippage(id, request.assetAmount, assetsOutNet);
            return;
        }

        // --- Effects ---
        _requests[id].requestStatus = RequestStatus.PROCESSED;
        _pendingRequestsCount[request.asset]--;
        if (redemptionFee > 0) {
            // Fee shares are transferred out of escrow, not burned
            _transfer(address(this), feeReceiver, redemptionFee);
        }
        _burn(address(this), netShares);

        // --- Interaction ---
        IERC20(request.asset).safeTransferFrom(portfolioSafe, request.receiver, assetsOutNet);

        emit RedemptionApproval(id, assetsOutNet, request.sharesAmount, redemptionFee);
    }

    /// @notice Reject a redemption request and return the escrowed shares
    /// @param id The ID of the request to reject
    /// @param request The request being rejected
    function _rejectRedeemRequest(uint256 id, UserRequest memory request) internal {
        // --- Effects ---
        _requests[id].requestStatus = RequestStatus.REJECTED;
        _pendingRequestsCount[request.asset]--;

        // --- Interaction ---
        _transfer(address(this), request.investor, request.sharesAmount);

        emit RedemptionDenial(id, request.assetAmount, request.sharesAmount);
    }

    //
    // Fees
    //

    /// @notice Charge management and performance fees based on time elapsed
    /// @param sharePriceUsd The PRE-dilution price, i.e. the snapshot the fee is measured against —
    ///        not the price the batch goes on to settle at
    /// @dev Called after the price snapshot and before any request settles. The fee must be measured
    ///      against the pre-dilution price, because that is the price the high-watermark series is
    ///      expressed in; the requests themselves then settle at the post-fee price, which
    ///      `_repriceAfterFees` derives immediately after this returns.
    ///      Unlike `KpkShares` there is no fee-module asset gate: the price is genuinely USD now, so
    ///      the high-watermark is one series across every asset rather than one asset's alone.
    ///
    ///      TWO MEASURED PROPERTIES OF THE PERFORMANCE FEE, both accepted rather than fixed:
    ///
    ///      1. It is PATH-DEPENDENT. Because the fee is denominated in shares, each crystallization
    ///         divides the gain by the price at that moment, so sampling the same rise more often
    ///         collects more: measured, a $1 -> $2 climb taken in eight steps mints ~14.3% more fee
    ///         than the same climb taken in one. Anyone who can cause a pricing event can therefore
    ///         raise total fees — and that is not only the operator, since a 1-unit `subscribe` is
    ///         enough once synchronous deposits are enabled. This is inherent to share-denominated
    ///         high-watermark fees and lives in the unchanged `WatermarkFee`; the mitigations are
    ///         operational, not structural (launch with the rate at zero, and keep synchronous
    ///         deposits closed).
    ///      2. The fee base EXCLUDES the receiver's balance but not its escrow. `netSupply` subtracts
    ///         `balanceOf(feeReceiver)`, and shares the receiver has placed in redemption escrow are
    ///         held by this contract rather than by the receiver — so they inflate the base and the
    ///         receiver is charged a fee on its own pending shares, at other holders' expense
    ///         (measured at ~0.8% of a holder's value in a realistic case). Tracking per-owner escrow
    ///         to net it out does not fit the remaining size budget; the operational rule is that the
    ///         fee receiver should not leave a redemption pending across a fee event.
    function _chargeFees(uint256 sharePriceUsd) internal {
        uint256 managementFee;
        uint256 performanceFee;

        if (managementFeeRate > 0) {
            uint256 timeElapsed = block.timestamp - _managementFeeLastUpdate;
            if (timeElapsed > MIN_TIME_ELAPSED) {
                _managementFeeLastUpdate = block.timestamp;
                managementFee = _chargeManagementFee(timeElapsed);
            }
        }

        if (performanceFeeRate > 0) {
            uint256 perfTimeElapsed = block.timestamp - _performanceFeeLastUpdate;
            if (perfTimeElapsed > MIN_TIME_ELAPSED) {
                _performanceFeeLastUpdate = block.timestamp;
                performanceFee = _chargePerformanceFee(sharePriceUsd, perfTimeElapsed);
            }
        }

        if (managementFee > 0 || performanceFee > 0) {
            emit FeeCollection(managementFee, performanceFee);
        }
    }

    /// @notice Calculate and charge management fees based on time elapsed and total supply
    /// @param timeElapsed The time elapsed since the last fee calculation
    /// @return The amount of management fee charged, in shares
    function _chargeManagementFee(uint256 timeElapsed) internal returns (uint256) {
        uint256 feeReceiverBalance = balanceOf(feeReceiver);
        uint256 feeAmount = ((totalSupply() - feeReceiverBalance) * managementFeeRate * timeElapsed)
            / (_PRECISION_BPS * SECONDS_PER_YEAR);
        if (feeAmount > 0) {
            _mint(feeReceiver, feeAmount);
        }
        return feeAmount;
    }

    /// @notice Calculate and charge performance fees using the performance fee module
    /// @param sharePriceUsd The current price per share in USD (8 decimals)
    /// @param timeElapsed The time elapsed since the last fee calculation
    /// @return The amount of performance fee charged, in shares
    function _chargePerformanceFee(uint256 sharePriceUsd, uint256 timeElapsed) internal returns (uint256) {
        if (performanceFeeModule == address(0)) return 0;

        uint256 feeReceiverBalance = balanceOf(feeReceiver);
        uint256 netSupply = totalSupply() - feeReceiverBalance;
        uint256 performanceFee = IPerfFeeModule(performanceFeeModule)
            .calculatePerformanceFee(sharePriceUsd, timeElapsed, performanceFeeRate, netSupply);
        if (performanceFee > 0) {
            _mint(feeReceiver, performanceFee);
        }
        return performanceFee;
    }

    //
    // Asset Management
    //

    /// @notice Add, update or remove an approved asset
    /// @param asset The asset address to configure
    /// @param canDeposit Whether the asset is approved for deposits
    /// @param canRedeem Whether the asset is approved for redemptions
    /// @dev WARNING: rebasing and fee-on-transfer tokens are not supported.
    ///      Listing consults the NAV calculator: an asset it does not know, or cannot price, would
    ///      make every subsequent batch in that asset revert, so it is rejected up front rather than
    ///      discovered at settlement. Delisting deliberately skips those checks — an asset must
    ///      remain removable even after the NAV calculator has stopped supporting it.
    function _updateAsset(address asset, bool canDeposit, bool canRedeem) internal {
        if (asset == address(0)) revert InvalidArguments();
        if (asset == address(this)) revert InvalidArguments();

        bool listing = canDeposit || canRedeem;

        if (_approvedAssetsMap[asset].asset != address(0)) {
            if (!listing) {
                if (subscriptionAssets[asset] != 0) revert InvalidArguments();
                if (_pendingRequestsCount[asset] > 0) revert InvalidArguments();
                if (_approvedAssets.length <= 1) revert InvalidArguments();

                _shadowAsset(asset);
                delete _approvedAssetsMap[asset];
                emit AssetRemove(asset);
            } else {
                _requireNavSupportsAsset(navCalculator, asset, _approvedAssetsMap[asset].decimals);
                _approvedAssetsMap[asset].canDeposit = canDeposit;
                _approvedAssetsMap[asset].canRedeem = canRedeem;
                emit AssetUpdate(asset, canDeposit, canRedeem);
            }
        } else {
            if (!listing) revert InvalidArguments();

            uint8 thisDecimals = IERC20Metadata(asset).decimals();
            if (thisDecimals > MAX_ASSET_DECIMALS) revert InvalidArguments();

            _requireNavSupportsAsset(navCalculator, asset, thisDecimals);

            _approvedAssetsMap[asset].asset = asset;
            _approvedAssetsMap[asset].decimals = thisDecimals;
            _approvedAssetsMap[asset].canDeposit = canDeposit;
            _approvedAssetsMap[asset].canRedeem = canRedeem;
            _approvedAssets.push(asset);

            emit AssetAdd(asset);
            emit AssetUpdate(asset, canDeposit, canRedeem);
        }
    }

    /// @notice Require the NAV calculator knows and can price an asset
    /// @param asset The asset to check
    /// @param expectedDecimals The decimals this contract has recorded for the asset
    /// @dev The decimals cross-check catches a NAV registry that disagrees with the token itself,
    ///      which would silently scale every conversion for that asset by a power of ten.
    ///      `nav` is a parameter rather than the stored calculator so `setNavCalculator` can apply
    ///      this same test to a CANDIDATE before adopting it.
    function _requireNavSupportsAsset(address nav, address asset, uint8 expectedDecimals) internal view {
        (INavCalculator.Asset memory info, bool found) = INavCalculator(nav).getRegisteredAsset(asset);
        if (!found) revert AssetNotRegisteredInNav();
        if (info.decimals != expectedDecimals) revert InvalidArguments();

        // An unregistered asset, one with no feed, and one whose feed is currently unhealthy all
        // mean the same thing for listing purposes: this fund could not settle a batch in it.
        if (!NavPricingLib.isAssetPriceable(nav, asset)) revert AssetNotPriceable();
    }

    /// @notice Remove an asset from the approved assets list
    /// @param asset The asset address to remove
    function _shadowAsset(address asset) internal {
        uint256 len = _approvedAssets.length;
        for (uint256 i = 0; i < len; i++) {
            if (_approvedAssets[i] == asset) {
                _approvedAssets[i] = _approvedAssets[len - 1];
                _approvedAssets.pop();
                break;
            }
        }
    }

    //
    // Setters
    //

    /// @notice Set subscription request TTL with 7-day maximum limit
    /// @param ttl New TTL value
    function _setSubscriptionRequestTtl(uint64 ttl) internal {
        uint64 newTtl = ttl > MAX_TTL ? MAX_TTL : ttl;
        if (subscriptionRequestTtl != newTtl) {
            subscriptionRequestTtl = newTtl;
            emit SubscriptionRequestTtlUpdate(newTtl);
        }
    }

    /// @notice Set redemption request TTL with 7-day maximum limit
    /// @param ttl New TTL value
    function _setRedemptionRequestTtl(uint64 ttl) internal {
        uint64 newTtl = ttl > MAX_TTL ? MAX_TTL : ttl;
        if (redemptionRequestTtl != newTtl) {
            redemptionRequestTtl = newTtl;
            emit RedemptionRequestTtlUpdate(newTtl);
        }
    }

    /// @notice Set the fee receiver address
    /// @param newFeeReceiver The new fee receiver address
    function _setFeeReceiver(address newFeeReceiver) internal {
        feeReceiver = newFeeReceiver;
        emit FeeReceiverUpdate(newFeeReceiver);
    }

    /// @notice Set the management fee rate, settling anything accrued under the old rate first
    /// @param newRate The new management fee rate in basis points
    /// @dev ACCEPTED: unlike every other minting path, this one reads no NAV and so is not health
    ///      gated — it can mint fee shares while the fund is unpriceable and holders cannot exit.
    ///      That is tolerable because the management fee is purely time-based: nothing here is
    ///      *mispriced*, it is dilution that had already accrued. Gating it on NAV health would let
    ///      an oracle outage silently forgive fees instead.
    function _setManagementFeeRate(uint256 newRate) internal {
        if (managementFeeRate > 0) {
            _chargeManagementFee(block.timestamp - _managementFeeLastUpdate);
        }
        _managementFeeLastUpdate = block.timestamp;
        managementFeeRate = newRate;
        emit ManagementFeeRateUpdate(newRate);
    }

    /// @notice Set the redemption fee rate
    /// @param newRate The new redemption fee rate in basis points
    function _setRedemptionFeeRate(uint256 newRate) internal {
        redemptionFeeRate = newRate;
        emit RedemptionFeeRateUpdate(newRate);
    }

    /// @notice Set the performance fee rate, settling anything accrued under the old rate first
    /// @param newRate The new performance fee rate in basis points
    /// @dev Settling requires a price, so this reverts while the NAV is unhealthy. That is the
    ///      intended trade: the alternative is minting fee shares at a price the contract cannot
    ///      currently justify. When the old rate is zero there is nothing to settle and no NAV is
    ///      read — which is also what keeps `initialize` from touching the NAV.
    function _setPerformanceFeeRate(uint256 newRate) internal {
        if (performanceFeeRate > 0) {
            uint256 sharesSupply = totalSupply();
            uint256 sharePriceUsd = initialSharePrice;
            if (sharesSupply > 0) {
                (sharePriceUsd,) =
                    NavPricingLib.sharePriceUsd(navCalculator, portfolioSafe, sharesSupply, 10 ** decimals());
            }
            _chargePerformanceFee(sharePriceUsd, block.timestamp - _performanceFeeLastUpdate);
        }
        _performanceFeeLastUpdate = block.timestamp;
        performanceFeeRate = newRate;
        emit PerformanceFeeRateUpdate(newRate);
    }

    /// @notice Set the performance fee module address
    /// @param newPerformanceFeeModule The new performance fee module address
    function _setPerformanceFeeModule(address newPerformanceFeeModule) internal {
        performanceFeeModule = newPerformanceFeeModule;
        emit PerformanceFeeModuleUpdate(newPerformanceFeeModule);
    }
}
