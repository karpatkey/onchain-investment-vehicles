// SPDX-License-Identifier: MIT
pragma solidity ^0.8;

import {IERC165} from "@openzeppelin/contracts/utils/introspection/IERC165.sol";

/// @title  IKpkSharesNav
/// @author KPK
/// @notice Interface for `KpkSharesNav`, a single-chain fund whose share price is derived on-chain
///         from karpatkey's NAV calculator rather than supplied by an operator.
/// @dev    Differs from `IkpkShares` in one structural way: NO function anywhere on this interface
///         accepts a share price. Every mint and burn is priced from a NAV snapshot the contract
///         reads itself, in the same transaction. That is what makes the operator unable to misprice
///         the fund, and it is why the price-deviation guard and the stored-price fallbacks that
///         `IkpkShares` needs do not exist here.
interface IKpkSharesNav is IERC165 {
    //
    // Errors
    //

    /// @notice Error when attempting to cancel a request that hasn't passed his TTL yet
    error RequestNotPastTtl();

    /// @notice Error when attempting to cancel a request that is not pending
    error RequestNotPending();

    /// @notice Error when the asset is not approved for redemptions
    error UnredeemableAsset();

    /// @notice Error when invalid arguments are provided
    error InvalidArguments();

    /// @notice Error when the caller is not authorized to perform the action
    error NotAuthorized();

    /// @notice Error when the asset is not approved for deposits
    error NotAnApprovedAsset();

    /// @notice Error when the fee rate is too high
    error FeeRateLimitExceeded();

    /// @notice Error when the request type does not match the expected type
    error RequestTypeMismatch();

    /// @notice Error when the NAV snapshot's prices are not healthy enough to price shares
    error NavUnhealthy();

    /// @notice Error when the fund's NAV is zero or negative while shares are outstanding
    error NavNotPositive();

    /// @notice Error when the derived share price rounds to zero
    error SharePriceZero();

    /// @notice Error when an asset cannot be listed because the NAV calculator does not know it
    error AssetNotRegisteredInNav();

    /// @notice Error when an asset cannot be listed because the NAV calculator cannot price it
    error AssetNotPriceable();

    /// @notice Error when an asset's price is stale, irregular or otherwise unusable
    error AssetPriceUnhealthy();

    /// @notice Error when a synchronous deposit is attempted while the admin has them disabled
    error SyncDepositsDisabled();

    /// @notice Error when a synchronous deposit would be the one to bootstrap the fund
    /// @dev While the supply is zero the price is `initialSharePrice` and the NAV is never read, so
    ///      there is no health gate and no link between the price and the safe's contents. Opening a
    ///      fund is an operator decision, not a permissionless one.
    error BootstrapRequiresOperator();

    /// @notice Error when the proposed NAV calculator address fails validation
    error InvalidNavCalculator();

    /// @notice Error when the amount produced is below the caller's slippage bound
    error SlippageBoundNotMet();

    //
    // Structs
    //

    /// @notice Struct representing an approved asset for deposits and redemptions
    /// @param asset The address of the asset
    /// @param decimals The number of decimal places for the asset, cached at listing time
    /// @param canDeposit Whether the asset is approved for deposits
    /// @param canRedeem Whether the asset is approved for redemptions
    /// @dev   There is no `isFeeModuleAsset` flag here, unlike `IkpkShares.ApprovedAsset`. That flag
    ///        existed only to confine performance fees to a USD-pegged asset, because the price fed
    ///        to the fee module was asset-denominated while the module treats it as USD. This fund
    ///        prices shares in USD directly, so the high-watermark is one coherent series across
    ///        every asset and the flag has nothing left to protect.
    struct ApprovedAsset {
        address asset;
        uint8 decimals;
        bool canDeposit;
        bool canRedeem;
    }

    /// @notice Struct representing a request for subscription or redemption.
    /// @param requestType The type of request (SUBSCRIPTION or REDEMPTION)
    /// @param requestStatus The current status of the request
    /// @param asset The address of the asset involved in the request
    /// @param assetAmount For a subscription, the assets deposited; for a redemption, the caller's
    ///        minimum acceptable assets out
    /// @param sharesAmount For a subscription, the caller's minimum acceptable shares out; for a
    ///        redemption, the shares held in escrow
    /// @param investor The submitter of the request
    /// @param receiver The receiver of the assets or shares in a successful request
    /// @param timestamp The timestamp when the request was created
    /// @param expiryAt The timestamp when the request expires (cannot be approved after this time)
    /// @dev   Requests deliberately carry no price. They record only the caller's slippage bound;
    ///        the price is derived from the NAV when the request is processed.
    struct UserRequest {
        // Request metadata
        RequestType requestType;
        RequestStatus requestStatus;
        // Financial details
        address asset;
        uint256 assetAmount;
        uint256 sharesAmount;
        // User details
        address investor;
        address receiver;
        // Timestamps
        uint64 timestamp;
        uint64 expiryAt;
    }

    //
    // Enums
    //

    /// @notice Enum representing the type of request
    enum RequestType {
        SUBSCRIPTION,
        REDEMPTION
    }

    /// @notice Enum representing the status of a request
    enum RequestStatus {
        PENDING,
        PROCESSED,
        REJECTED,
        CANCELLED
    }

    //
    // Events
    //

    /// @notice Event emitted when a subscription request is made.
    /// @param investor The investor of the shares being subscribed.
    /// @param requestId The unique identifier for the request.
    /// @param receiver The receiver of the shares in a successful request.
    /// @param subscriptionAsset The address of the asset being subscribed.
    /// @param assetsAmount The number of assets being subscribed.
    /// @param minSharesOut The caller's minimum acceptable shares out.
    /// @param timestamp The timestamp when the request was created
    /// @param cancelableFrom The timestamp from which the request can be cancelled
    /// @param expiryAt The timestamp when the request expires
    event SubscriptionRequest(
        address indexed investor,
        uint256 requestId,
        address indexed receiver,
        address indexed subscriptionAsset,
        uint256 assetsAmount,
        uint256 minSharesOut,
        uint64 timestamp,
        uint64 cancelableFrom,
        uint64 expiryAt
    );

    /// @notice Event emitted when a subscription request is fulfilled.
    /// @param requestId The unique identifier for the request.
    /// @param assets The number of assets subscribed.
    /// @param shares The number of shares issued.
    event SubscriptionApproval(uint256 requestId, uint256 assets, uint256 shares);

    /// @notice Event emitted when a subscription is cancelled
    /// @param requestId The unique identifier for the request.
    /// @param canceller account who cancelled the subscription
    event SubscriptionCancellation(uint256 requestId, address canceller);

    /// @notice Event emitted when a subscription request is denied.
    /// @param requestId The unique identifier for the request.
    /// @param assets The number of assets involved in the request.
    /// @param shares The number of shares requested.
    event SubscriptionDenial(uint256 requestId, uint256 assets, uint256 shares);

    /// @notice Event emitted when a redemption request is made.
    /// @param investor The investor of the shares being redeemed.
    /// @param requestId The unique identifier for the request.
    /// @param receiver The receiver of the assets in a successful request.
    /// @param redemptionAsset The address of the asset being redeemed.
    /// @param minAssetsOut The caller's minimum acceptable assets out.
    /// @param sharesAmount The number of shares being escrowed.
    /// @param timestamp The timestamp when the request was created
    /// @param cancelableFrom The timestamp from which the request can be cancelled
    /// @param expiryAt The timestamp when the request expires
    event RedemptionRequest(
        address indexed investor,
        uint256 requestId,
        address indexed receiver,
        address indexed redemptionAsset,
        uint256 minAssetsOut,
        uint256 sharesAmount,
        uint64 timestamp,
        uint64 cancelableFrom,
        uint64 expiryAt
    );

    /// @notice Event emitted when a redemption request is fulfilled.
    /// @param requestId The unique identifier for the request.
    /// @param assets The number of assets redeemed.
    /// @param shares The number of shares returned.
    /// @param redemptionFee The amount of shares charged as redemption fee
    event RedemptionApproval(uint256 requestId, uint256 assets, uint256 shares, uint256 redemptionFee);

    /// @notice Event emitted when a redemption request is denied.
    /// @param requestId The unique identifier for the request.
    /// @param assets The number of assets involved in the request.
    /// @param shares The number of shares requested.
    event RedemptionDenial(uint256 requestId, uint256 assets, uint256 shares);

    /// @notice Event emitted when a redemption is cancelled
    /// @param requestId The unique identifier for the request.
    /// @param canceller account who cancelled the request
    event RedemptionCancellation(uint256 requestId, address canceller);

    /// @notice Event emitted when a request could not be settled within the caller's slippage bound
    /// @param requestId The unique identifier for the request.
    /// @param required The amount the caller required at minimum.
    /// @param produced The amount the derived price would have produced.
    /// @dev   The request is left PENDING rather than reverting the batch. With an operator-supplied
    ///        price the operator could re-price to clear such a request; with a NAV-derived price it
    ///        cannot, so reverting would let one unsatisfiable request brick every batch containing
    ///        it. The operator may reject the request explicitly, or let it expire.
    event RequestSkippedForSlippage(uint256 requestId, uint256 required, uint256 produced);

    /// @notice Event emitted when subscriptionRequestTtl is updated (only when value changes)
    /// @param ttl The new ttl
    event SubscriptionRequestTtlUpdate(uint64 ttl);

    /// @notice Event emitted when redemptionRequestTtl is updated (only when value changes)
    /// @param ttl The new ttl
    event RedemptionRequestTtlUpdate(uint64 ttl);

    /// @notice Event emitted when a subscription request is skipped due to expiry
    /// @param requestId The unique identifier for the expired request
    /// @param expiryAt The timestamp when the request expired
    event SubscriptionRequestExpired(uint256 requestId, uint64 expiryAt);

    /// @notice Event emitted when a redemption request is skipped due to expiry
    /// @param requestId The unique identifier for the expired request
    /// @param expiryAt The timestamp when the request expired
    event RedemptionRequestExpired(uint256 requestId, uint64 expiryAt);

    /// @notice Event emitted when fees are collected (only when at least one fee > 0)
    /// @param managementFee The amount of shares charged as management fee
    /// @param performanceFee The amount of shares charged as performance fee
    event FeeCollection(uint256 managementFee, uint256 performanceFee);

    /// @notice Event emitted when fee receiver is updated
    /// @param newFeeReceiver The new fee receiver address
    event FeeReceiverUpdate(address indexed newFeeReceiver);

    /// @notice Event emitted when management fee rate is updated (only when value changes)
    /// @param newRate The new management fee rate (in basis points, 2000 = 20%)
    event ManagementFeeRateUpdate(uint256 newRate);

    /// @notice Event emitted when redemption fee is updated (only when value changes)
    /// @param newRate The new redemption fee (in basis points, 2000 = 20%)
    event RedemptionFeeRateUpdate(uint256 newRate);

    /// @notice Event emitted when performance fee is updated (only when value changes)
    /// @param newRate The new performance fee (in basis points, 2000 = 20%)
    event PerformanceFeeRateUpdate(uint256 newRate);

    /// @notice Event emitted when performance fee module is updated
    /// @param newPerformanceFeeModule The new performance fee module address
    event PerformanceFeeModuleUpdate(address indexed newPerformanceFeeModule);

    /// @notice Event emitted when an asset's direction flags are updated
    /// @param asset The address of the asset
    /// @param canDeposit Whether the asset is approved for deposits
    /// @param canRedeem Whether the asset is approved for redemptions
    event AssetUpdate(address indexed asset, bool canDeposit, bool canRedeem);

    /// @notice Event emitted when an asset is added
    /// @param asset The address of the asset
    event AssetAdd(address indexed asset);

    /// @notice Event emitted when an asset is removed
    /// @param asset The address of the asset
    event AssetRemove(address indexed asset);

    /// @notice Event emitted when the NAV calculator address is updated
    /// @param oldNavCalculator The previous NAV calculator
    /// @param newNavCalculator The new NAV calculator
    event NavCalculatorUpdate(address indexed oldNavCalculator, address indexed newNavCalculator);

    /// @notice Event emitted when synchronous deposits are enabled or disabled
    /// @param enabled The new state
    event SyncDepositsEnabledUpdate(bool enabled);

    /// @notice Event emitted once per pricing event, recording the price the fund settled at
    /// @param sharePriceUsd The derived price per share in USD (8 decimals)
    /// @param navValue The NAV the price was derived from, in USD (8 decimals)
    /// @param sharesSupply The share supply the price was derived against
    /// @dev   Observability only. Nothing in this contract ever reads a recorded price back as a
    ///        pricing input — doing so would reintroduce the stale-price risk this design removes.
    event SharePriceSettlement(uint256 sharePriceUsd, int256 navValue, uint256 sharesSupply);

    /// @notice Event emitted when a synchronous deposit is executed
    /// @param investor The account that supplied the assets
    /// @param receiver The account that received the shares
    /// @param asset The asset deposited
    /// @param assets The amount of assets deposited
    /// @param shares The amount of shares minted
    /// @param sharePriceUsd The price per share the deposit settled at (USD, 8 decimals)
    event SyncSubscription(
        address indexed investor,
        address indexed receiver,
        address indexed asset,
        uint256 assets,
        uint256 shares,
        uint256 sharePriceUsd
    );

    //
    // View Functions
    //

    /// @notice Returns the asset configuration for a specific asset
    /// @param asset The address of the asset
    /// @return The asset configuration
    function getApprovedAsset(address asset) external view returns (ApprovedAsset memory);

    /// @notice Returns the list of approved assets
    /// @return An array of approved asset addresses
    function getApprovedAssets() external view returns (address[] memory);

    /// @notice Checks if an asset is approved for deposits or redemptions
    /// @param asset The address of the asset to check
    /// @return True if the asset is approved for deposits or redemptions
    function isApprovedAsset(address asset) external view returns (bool);

    /// @notice Returns the number of decimals for an asset
    /// @param asset The address of the asset
    /// @return The number of decimals for the asset
    function assetDecimals(address asset) external view returns (uint8);

    /// @notice Returns the fund's current price per share, derived live from the NAV calculator.
    /// @dev    Reverts if the NAV is unhealthy or non-positive — it never falls back to a recorded
    ///         price. Returns the configured `initialSharePrice` while no shares are outstanding.
    /// @return The price per share in USD with 8 decimals.
    function getSharePriceUsd() external view returns (uint256);

    //
    // Subscription Functions
    //

    /// @notice Preview the shares a subscription would produce at the current live price.
    /// @param assets The amount of assets to subscribe (in the asset's native decimals)
    /// @param subscriptionAsset The address of the asset being subscribed
    /// @return shares The amount of shares that would be received (18 decimals)
    /// @dev Pre-fee-accrual, as for `previewRedemption` — but a fee moves the price DOWN, so a
    ///      subscriber quoted here receives at least this many shares. The bound binds safely.
    function previewSubscription(uint256 assets, address subscriptionAsset) external view returns (uint256 shares);

    /// @notice Request a subscription of assets
    /// @param assetsIn The amount of assets to subscribe
    /// @param minSharesOut The minimum amount of shares to accept (slippage protection, must be > 0)
    /// @param subscriptionAsset The address of the asset being subscribed
    /// @param receiver The address that will receive the shares
    /// @return requestId The ID of the created subscription request
    /// @dev The shares minted are computed from the NAV-derived price at approval time.
    function requestSubscription(uint256 assetsIn, uint256 minSharesOut, address subscriptionAsset, address receiver)
        external
        returns (uint256 requestId);

    /// @notice Deposit assets and receive shares in the same transaction.
    /// @param assetsIn The amount of assets to deposit
    /// @param minSharesOut The minimum amount of shares to accept (slippage protection, must be > 0)
    /// @param subscriptionAsset The address of the asset being deposited
    /// @param receiver The address that will receive the shares
    /// @return sharesOut The amount of shares minted
    /// @dev Only callable while the admin has synchronous deposits enabled. Assets go straight to
    ///      the portfolio safe without passing through request escrow. The NAV is read BEFORE the
    ///      assets move, so a deposit is never priced against its own contribution.
    function subscribe(uint256 assetsIn, uint256 minSharesOut, address subscriptionAsset, address receiver)
        external
        returns (uint256 sharesOut);

    /// @notice Cancel a subscription request
    /// @param id The ID of the subscription request to cancel
    function cancelSubscription(uint256 id) external;

    /// @notice Process requests (approve/reject) at the fund's current NAV-derived price
    /// @param approveRequests Array of request IDs to approve
    /// @param rejectRequests Array of request IDs to reject
    /// @param asset The asset to process requests for
    /// @dev Takes no price: the price is derived from the NAV calculator inside this call and one
    ///      snapshot governs the fee accrual and every request in the batch. Passing an empty
    ///      `approveRequests` skips the NAV read entirely, so escrow stays refundable even while the
    ///      fund cannot be priced.
    function processRequests(uint256[] calldata approveRequests, uint256[] calldata rejectRequests, address asset)
        external;

    //
    // Redemption Functions
    //

    /// @notice Preview the assets a redemption would produce at the current live price.
    /// @param shares The amount of shares to redeem (18 decimals)
    /// @param redemptionAsset The address of the asset to redeem for
    /// @return assets The amount of assets that would be received, after the redemption fee
    /// @dev PREVIEWS ARE PRE-FEE-ACCRUAL. This quotes the price as it stands now; a management or
    ///      performance fee crystallizing in the batch that settles the request mints shares and
    ///      moves the price down before the request converts. A `minAssetsOut` taken straight from
    ///      this figure will therefore be SKIPPED whenever a fee lands in the settling batch — which
    ///      is exactly when redemptions cluster. Pad the bound. The contract cannot simulate the
    ///      accrual here because `IPerfFeeModule.calculatePerformanceFee` is non-view.
    function previewRedemption(uint256 shares, address redemptionAsset) external view returns (uint256 assets);

    /// @notice Request to redeem shares for assets
    /// @param sharesIn The amount of shares to redeem
    /// @param minAssetsOut The minimum amount of assets to accept (slippage protection, must be > 0)
    /// @param redemptionAsset The address of the asset to redeem for
    /// @param receiver The address that will receive the assets
    /// @return requestId The ID of the redemption request
    function requestRedemption(uint256 sharesIn, uint256 minAssetsOut, address redemptionAsset, address receiver)
        external
        returns (uint256 requestId);

    /// @notice Cancel a redemption request
    /// @param id The ID of the redemption request to cancel
    function cancelRedemption(uint256 id) external;

    //
    // Admin Functions
    //

    /// @notice Sets the subscription request TTL for all pending subscription requests
    /// @param ttl The new TTL to apply (max 7 days)
    function setSubscriptionRequestTtl(uint64 ttl) external;

    /// @notice Sets the redemption request TTL for all pending redemption requests
    /// @param ttl The new TTL to apply (max 7 days)
    function setRedemptionRequestTtl(uint64 ttl) external;

    /// @notice Sets the fee receiver address
    /// @param newFeeReceiver The new fee receiver address
    function setFeeReceiver(address newFeeReceiver) external;

    /// @notice Sets the management fee rate (only emits event when value changes)
    /// @param newRate The new management rate (in basis points, max 2000 = 20%)
    function setManagementFeeRate(uint256 newRate) external;

    /// @notice Sets the redemption fee rate (only emits event when value changes)
    /// @param newRate The new redemption fee (in basis points, max 2000 = 20%)
    function setRedemptionFeeRate(uint256 newRate) external;

    /// @notice Sets the performance fee rate (only emits event when value changes)
    /// @param newRate The new performance fee (in basis points, max 2000 = 20%)
    /// @dev Settles any performance fee accrued under the old rate at the fund's current live price
    ///      first, so it reverts while the NAV is unhealthy. That is deliberate: the alternative is
    ///      minting fee shares at a price the contract cannot currently justify.
    function setPerformanceFeeRate(uint256 newRate) external;

    /// @notice Sets the performance fee module
    /// @param newPerformanceFeeModule The new performance fee module address
    function setPerformanceFeeModule(address newPerformanceFeeModule) external;

    /// @notice Points the fund at a different NAV calculator
    /// @param newNavCalculator The new NAV calculator address
    /// @dev Validates that the target is a contract, reports 8-decimal USD, and already knows every
    ///      asset this fund currently lists — otherwise the fund would be left unable to price
    ///      itself. This is a highly privileged action: a NAV calculator determines what every share
    ///      is worth.
    function setNavCalculator(address newNavCalculator) external;

    /// @notice Enables or disables the synchronous deposit path
    /// @param enabled Whether `subscribe` may be called
    function setSyncDepositsEnabled(bool enabled) external;

    /// @notice Updates an asset's configuration for deposits and redemptions
    /// @param asset The asset address to configure
    /// @param canDeposit Whether the asset is approved for deposits
    /// @param canRedeem Whether the asset is approved for redemptions
    /// @dev Listing an asset requires the NAV calculator to have it registered and priceable.
    ///      Delisting (both flags false) skips those checks so an asset can always be removed.
    function updateAsset(address asset, bool canDeposit, bool canRedeem) external;

    /// @notice Returns a request (subscription or redemption) by ID
    /// @param id The request ID
    /// @return The request details
    function getRequest(uint256 id) external view returns (UserRequest memory);

    /// @notice Returns the current redemption fee rate
    /// @return The redemption fee rate in basis points (1000 = 10%)
    function redemptionFeeRate() external view returns (uint256);

    /// @notice Returns the current management fee rate
    /// @return The management fee rate in basis points (1000 = 10%)
    function managementFeeRate() external view returns (uint256);

    /// @notice Returns the portfolio safe address where assets are held and valued
    /// @return The portfolio safe address
    function portfolioSafe() external view returns (address);

    /// @notice Returns the performance fee module address
    /// @return The performance fee module address
    function performanceFeeModule() external view returns (address);

    /// @notice Returns the fee receiver address
    /// @return The fee receiver address
    function feeReceiver() external view returns (address);

    /// @notice Returns the performance fee rate
    /// @return The performance fee rate in basis points (1000 = 10%)
    function performanceFeeRate() external view returns (uint256);

    /// @notice Returns the current request ID counter
    /// @return The current request ID
    function requestId() external view returns (uint256);

    /// @notice Returns the subscription request TTL
    /// @return The subscription request TTL in seconds
    function subscriptionRequestTtl() external view returns (uint64);

    /// @notice Returns the redemption request TTL
    /// @return The redemption request TTL in seconds
    function redemptionRequestTtl() external view returns (uint64);

    /// @notice Returns the assets pending in subscription requests for an asset
    /// @param asset The address of the asset
    /// @return The amount of assets held in escrow for this asset
    function subscriptionAssets(address asset) external view returns (uint256);

    /// @notice Returns the NAV calculator this fund prices itself from
    /// @return The NAV calculator address
    function navCalculator() external view returns (address);

    /// @notice Returns whether synchronous deposits are currently enabled
    /// @return True if `subscribe` may be called
    function syncDepositsEnabled() external view returns (bool);

    /// @notice Returns the price per share used while no shares are outstanding
    /// @return The bootstrap price per share in USD (8 decimals)
    function initialSharePrice() external view returns (uint256);

    /// @notice Returns the price the fund most recently settled at
    /// @return The last settled price per share in USD (8 decimals), or 0 if never priced
    /// @dev Observability only — never used as a pricing input.
    function lastSharePriceUsd() external view returns (uint256);

    /// @notice Returns when the fund most recently settled a price
    /// @return The timestamp of the last pricing event, or 0 if never priced
    function lastPricedAt() external view returns (uint64);
}
