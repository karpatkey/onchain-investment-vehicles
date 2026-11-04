# kpkShares Contract Documentation

## Overview

The `kpkShares` contract is a tokenized fund implementation that allows users to subscribe for and receive fund shares, as well as redeem shares for underlying assets. It implements a request-based system with operator approval, comprehensive fee management, and multi-asset support.

## Contract Architecture

### Inheritance Chain
```
KpkShares
├── Initializable (OpenZeppelin)
├── UUPSUpgradeable (OpenZeppelin)
├── AccessControlUpgradeable (OpenZeppelin)
├── ERC20Upgradeable (OpenZeppelin)
├── IkpkShares (Custom Interface)
└── RecoverFunds (Custom Abstract)
```

### Key Components
- **Token Management**: ERC20-compliant shares with minting/burning capabilities
- **Request System**: Subscription and redemption requests with TTL-based cancellation
- **Fee Management**: Management, performance, and redemption fees
- **Asset Management**: Multi-asset support with configurable asset types
- **Access Control**: Role-based permissions for different operations

## Dependencies

### External Libraries
- **OpenZeppelin Contracts Upgradeable** (`5.4.0` - pinned version)
  - `ERC20Upgradeable`: Standard ERC20 token functionality
  - `AccessControlUpgradeable`: Role-based access control
  - `UUPSUpgradeable`: Upgradeable proxy pattern
  - `Initializable`: Initialization pattern for upgradeable contracts
  - `SafeERC20`: Safe ERC20 operations
  - `Math`: Mathematical operations with overflow protection

### Internal Dependencies
- `IPerfFeeModule`: Performance fee calculation interface
- `WatermarkFeeBase` and the modules built on it (`WatermarkFee`, `PostFeeWatermarkFee`, `ExactWatermarkFee`, `PeriodicWatermarkFee`, `HardHurdleFee`, `SoftHurdleFee`, `CatchUpHurdleFee`, `BenchmarkFee`, `NoWatermarkFee`): performance fee modules (see [Performance fee modules](#performance-fee-modules))
- `IkpkShares`: Main contract interface
- `RecoverFunds`: Asset recovery mechanism

## Access Control & Authorities

### Role Hierarchy
```
DEFAULT_ADMIN_ROLE (0x00)
├── Can upgrade the contract
├── Can modify fee rates and receivers
├── Can set TTL values
└── Can grant/revoke other roles

OPERATOR (0x523a704056dcd17bcf83bed8b68c59416dac1119be77755efe3bde0a64e46e0c)
├── Can process deposit/redemption requests
├── Can update asset configurations
└── Cannot cancel requests (only investors/receivers can cancel)

```

### Permission Matrix

| Function | DEFAULT_ADMIN_ROLE | OPERATOR | INVESTOR | Public |
|----------|-------------------|----------|----------|---------|
| `initialize` | ❌ | ❌ | ❌ | ✅ (initializer, one-time) |
| `_authorizeUpgrade` | ✅ | ❌ | ❌ | ❌ |
| `setSubscriptionRequestTtl` | ✅ | ❌ | ❌ | ❌ |
| `setRedemptionRequestTtl` | ✅ | ❌ | ❌ | ❌ |
| `setFeeReceiver` | ✅ | ❌ | ❌ | ❌ |
| `setManagementFeeRate` | ✅ | ❌ | ❌ | ❌ |
| `setRedemptionFeeRate` | ✅ | ❌ | ❌ | ❌ |
| `setPerformanceFeeRate` | ✅ | ❌ | ❌ | ❌ |
| `setPerformanceFeeModule` | ✅ | ❌ | ❌ | ❌ |
| `updateAsset` | ❌ | ✅ | ❌ | ❌ |
| `processRequests` | ❌ | ✅ | ❌ | ❌ |
| `requestSubscription` | ❌ | ❌ | ❌ | ✅ |
| `requestRedemption` | ❌ | ❌ | ❌ | ✅ |
| `cancelSubscription` | ❌ | ❌ | ✅ (investor or receiver, after TTL) | ❌ |
| `cancelRedemption` | ❌ | ❌ | ✅ (investor or receiver, after TTL) | ❌ |

## Core Capabilities

### 1. Asset Management
- **Multi-Asset Support**: Configure multiple assets for subscriptions and redemptions
- **Asset Configuration**: Granular control over which assets can be used for subscriptions/redemptions
- **Dynamic Updates**: Add/remove assets and modify configurations
- **Asset Removal Restrictions**: 
  - Cannot remove asset with pending subscriptions (`subscriptionAssets[asset] > 0`)
  - Cannot remove asset with pending requests (subscriptions or redemptions)
  - Cannot remove the last remaining approved asset
  - Cannot add asset with both `canDeposit = false` and `canRedeem = false`
  - Maximum 36 decimals per asset (prevents overflow risks)

### 2. Subscription System
- **Request-Based**: Users submit subscription requests that require operator approval
- **Asset Escrow**: Assets are held in escrow until request processing
- **TTL Protection**: Configurable time-to-live for request cancellation

### 3. Redemption System
- **Share Escrow**: Shares are held in escrow during redemption requests
- **Flexible Asset Selection**: Users can redeem for any approved asset
- **Fee Deduction**: Redemption fees are applied before asset distribution

### 4. Fee Management
- **Management Fees**: Time-based fees calculated on total share supply
- **Performance Fees**: Watermark-based performance fees using modular calculation system
- **Redemption Fees**: Percentage-based fees on redemption amounts
- **Fee Distribution**: All fees are distributed as shares to the configured fee receiver
- **Watermark System**: Performance fees only charged on gains above the fund's watermark
- **Modular Design**: Performance fee calculation can be upgraded by changing the fee module
- **Fee Timestamp Management**:
  - Management fees use shared `_managementFeeLastUpdate` timestamp across all assets
  - Performance fees use separate `_performanceFeeLastUpdate` timestamp (prevents gaming)
  - Performance fees only calculated for assets with `isFeeModuleAsset = true`
  - When updating fee rates, any accrued fees are charged before the rate change

### 5. Performance Fee System
- **Reference price**: The module keeps one reference price (`highWatermark`) per calling fund, keyed by `msg.sender`. Its first call seeds it at the price it is given and charges nothing; that is the first price the module is shown, not the price investors entered at
- **Profit-Only Charging**: Fees only charged on gains above the reference, which depending on the module is a watermark, a watermark plus a hurdle, or a benchmark-adjusted watermark
- **Modular Architecture**: Fee calculation logic can be upgraded via module replacement
- **Time-Gated, Price-Based Calculation**: Fees are only assessed after `MIN_TIME_ELAPSED` (6 hours) has passed. The modules keep their own clock for the hurdle and the crystallization period; `timeElapsed` is only re-emitted in an event
- **Reference Updates**: Each charge moves the reference; where it lands depends on the module

#### Performance fee modules

All modules share `WatermarkFeeBase` (seeding, per-fund keying, events). None is deployed; which one a fund uses is still open. Worked examples, diagrams and a calculator: [watermark-fee-modules.html](watermark-fee-modules.html).

**Watermark sizing.** Three modules that differ only in how a gain becomes fee shares and where the watermark lands afterwards:

| Module | Watermark after a fee | Fee shares | Effective rate at 20% configured: receiver redeems / holds its fee shares* |
|---|---|---|---|
| `WatermarkFee` | pre-fee price | gain ÷ pre-fee price, no dilution adjustment | 16.7% / 14.0–15.6% |
| `PostFeeWatermarkFee` | post-fee price | as `WatermarkFee` | 19.8–20.0% / 15.8–18.2% |
| `ExactWatermarkFee` | post-fee price | sized so every share gives up exactly `feePct` × its gain | 20.0% / 20.0% |

\* Off-chain simulation, 2026-11-04: NAV rising 0.03%–5% between charges, price reported as NAV / totalSupply. "Holds" means later mints dilute the receiver's earlier fee shares, which the first two modules do not compensate for.

**Other structures.** All size fees like `ExactWatermarkFee` and take a constructor `crystallizationPeriod` (0 = charge at every settlement):

| Module | Fee is due when the price exceeds | Fee | Constructor |
|---|---|---|---|
| `PeriodicWatermarkFee` | the watermark, and the period has run since the last charge | `feePct` of the gain above the watermark | `period` |
| `HardHurdleFee` | the watermark grown by `hurdleBps` a year (simple interest since the last charge) | `feePct` of the gain above the hurdle only | `hurdleBps, period` |
| `SoftHurdleFee` | the hurdle | `feePct` of the whole gain above the watermark | `hurdleBps, period` |
| `CatchUpHurdleFee` | the hurdle | `catchUpBps` of the gain above the hurdle, up to `feePct` of the whole gain | `hurdleBps, catchUpBps, period` |
| `BenchmarkFee` | the watermark carried forward at the benchmark's return (and, optionally, the watermark itself) | `feePct` of the outperformance | `feed, maxStaleness, requireAbsoluteGain, period` |
| `NoWatermarkFee` | the previous reference, which follows the price down after a fall | `feePct` of any gain, including the recovery of a loss | `period` |

Notes on the other structures:
- With a period, nothing accrues between charges: an investor who redeems mid-period pays none of that period's fee, and one who subscribes mid-period pays it on gains made before they joined.
- The soft and catch-up hurdles are cleared by almost any gain over the few hours between settlements, so they only bite with a period such as a year. The hard hurdle works at any period.
- `BenchmarkFee` reads a Chainlink-style feed. A stale, non-positive or reverting feed makes the call a no-op that defers the fee rather than reverting the settlement. Without `requireAbsoluteGain`, a fund that loses less than a falling benchmark is charged.
- `NoWatermarkFee` is not investor-protective and exists for comparison only.

Every module except `WatermarkFee` reads `totalSupply()` from the calling fund and assumes the reported price is NAV / totalSupply() at call time.

The module address is hashed into a fund's shares salt (`KpkOivFactory._deriveSharesSalt`), so a fund whose shares live on several chains needs the module at the same address on each. Constructor arguments are part of a module's creation code, so each parameter set is a different address, and `BenchmarkFee` with a different feed address per chain cannot land at one address everywhere. There is no deterministic deploy script for these modules yet.

`kpkShares` behaviour that applies whichever module is used:
- Requests approved in the batch that charges the fee are priced at the pre-fee price, so redeemers in that batch pay none of it and the holders who stay pay all of it.
- The module is not called while `performanceFeeRate` is 0 or the module is unset, so the watermark freezes; once fees are re-enabled, gains made in the meantime are charged.
- Every `isFeeModuleAsset` asset feeds the same watermark, each in its own price unit, and the first settlement in a newly added asset skips the 30% price-deviation check.

### 6. Request Lifecycle
```
Request Creation → Pending → Processing → Approved/Rejected/Expired
       ↓              ↓          ↓           ↓
   User Action   TTL Window  Operator    Final State
   (Subscription/ (Cancellation  Review    (Shares Minted/
    Redeem)      Available)    Required   Assets Transferred)
                                    ↓
                              Expiry Check
                              (7 days max)
                                    ↓
                            Auto-Reject if Expired
```

**Request Lifetime vs Cancellation TTL:**
- **Request Lifetime**: All requests expire after 7 days (`expiryAt = timestamp + MAX_TTL`)
- **Cancellation TTL**: Configurable time window (max 7 days) before user can cancel
- **Expiry Handling**: Expired requests in `approveRequests` are automatically rejected during processing
- **Expiry Events**: `SubscriptionRequestExpired` or `RedemptionRequestExpired` emitted when requests expire

## Asset and Shares Flow Analysis

The kpkShares contract manages a tokenized fund with asynchronous subscription and redemption processes. Below is a detailed breakdown of asset and shares flows for each user interaction:

### Key Components

| Component | Description |
|-----------|-------------|
| **Investor** | User requesting subscription/redemption |
| **Receiver** | Address that receives shares (subscription) or assets (redemption) |
| **Contract** | kpkShares contract (holds assets in escrow during pending requests) |
| **Portfolio Safe** | Main fund vault where approved assets are transferred |
| **Fee Receiver** | Address that receives management, performance, and redemption fees |

### Subscription Flow

| Function | Asset Origin | Asset Destination | Asset Amount | Shares Origin | Shares Destination | Shares Amount | State Changes |
|----------|--------------|-------------------|--------------|---------------|-------------------|---------------|---------------|
| `requestSubscription` | Investor's wallet | kpkShares contract (escrow) | Full asset amount | None (not minted yet) | None | None | Assets transferred to escrow, `subscriptionAssets[asset]` increased, request PENDING (shares calculated during approval) |
| `cancelSubscription` | kpkShares contract (escrow) | Investor's wallet | Full original amount | None | None | None | `subscriptionAssets[asset]` decreased, request CANCELLED |
| `processRequests` (approve) | kpkShares contract (escrow) | Portfolio Safe | Full asset amount | None (newly minted) | Receiver's wallet | Calculated shares | `subscriptionAssets[asset]` decreased, request PROCESSED, shares minted |
| `processRequests` (reject) | kpkShares contract (escrow) | Investor's wallet | Full original amount | None | None | None | `subscriptionAssets[asset]` decreased, request REJECTED |

### Redemption Flow

| Function | Asset Origin | Asset Destination | Asset Amount | Shares Origin | Shares Destination | Shares Amount | State Changes |
|----------|--------------|-------------------|--------------|---------------|-------------------|---------------|---------------|
| `requestRedemption` | None (not transferred yet) | None | None | Investor's wallet | kpkShares contract (escrow) | Full shares amount | Shares transferred to escrow, request PENDING (assets calculated during approval) |
| `cancelRedemption` | None | None | None | kpkShares contract (escrow) | Investor's wallet | Full original amount | Request CANCELLED |
| `processRequests` (approve) | Portfolio Safe | Receiver's wallet | Net assets (after fees) | kpkShares contract (escrow) | Fee Receiver + Burned | Fee shares transferred + Net shares burned | Request PROCESSED, net shares burned, fee shares transferred |
| `processRequests` (reject) | None | None | None | kpkShares contract (escrow) | Investor's wallet | Full original amount | Request REJECTED |

### Fee Collection Patterns

| Fee Type | Trigger | Calculation Method | Collection Method | Frequency | Destination | Event Emission |
|----------|---------|-------------------|-------------------|-----------|-------------|----------------|
| **Management Fee** | Any request processing | `(totalSupply - feeReceiverBalance) * managementFeeRate * timeElapsed / (10_000 * SECONDS_PER_YEAR)` | New shares minted | Only when `timeElapsed > MIN_TIME_ELAPSED` | Fee Receiver | Only when fee > 0 |
| **Performance Fee** | Any request processing | Via performance fee module based on price appreciation | New shares minted | Only when `timeElapsed > MIN_TIME_ELAPSED` and `asset.isFeeModuleAsset == true` | Fee Receiver | Only when fee > 0 |
| **Redemption Fee** | Redemption request processing only | `request.shares * redemptionFeeRate / 10000` | Shares transferred from escrow | Every redemption approval | Fee Receiver | `RedemptionApproval` event (includes `redemptionFee` parameter) |

### Request Status Transitions

| Current Status | Possible Actions | New Status | Asset/Shares Movement |
|----------------|------------------|------------|----------------------|
| **PENDING** | Operator approval | PROCESSED | Assets/shares transferred according to request type |
| **PENDING** | Operator rejection | REJECTED | Assets/shares returned to investor |
| **PENDING** | User cancellation (after TTL) | CANCELLED | Assets/shares returned to investor |
| **PENDING** | Request expiry (after 7 days) | REJECTED | Assets/shares returned to investor, expiry event emitted |
| **PROCESSED** | None | PROCESSED | Final state - no further changes |
| **REJECTED** | None | REJECTED | Final state - no further changes |
| **CANCELLED** | None | CANCELLED | Final state - no further changes |

### Key Design Principles

1. **Asynchronous Processing**: All requests are two-step (request → approve/reject)
2. **Escrow Mechanism**: Assets/shares held in contract during pending state
3. **Fee Separation**: Different fee types collected at different stages
4. **Flexible Receivers**: Investor and receiver can be different addresses
5. **TTL Protection**: Requests can be cancelled after TTL expires

## Safety Considerations

### 1. Reentrancy Protection
- **SafeERC20**: Uses OpenZeppelin's SafeERC20 for all token transfers
- **State Updates**: State changes occur before external calls
- **Request Status Tracking**: Comprehensive status management prevents double-processing

### 2. Access Control
- **Role-Based Security**: Granular permissions for different operations
- **Admin Controls**: Critical functions restricted to admin role
- **Operator Limits**: Operators can only process requests, not modify core parameters

### 3. Asset Safety
- **Escrow Protection**: Assets/shares held in escrow during request processing
- **Asset Validation**: Asset configuration validation before operations
- **Asset Recovery**: RecoverFunds mechanism for emergency asset recovery

### 4. Request Security
- **TTL Enforcement**: Time-based restrictions prevent indefinite holds
- **Authorization Checks**: Users can only cancel their own requests

### 5. Fee Safety
- **Rate Limits**: Maximum fee rates capped at 20% (2,000 basis points)
- **Time-Based Calculation**: Management fees calculated based on elapsed time
- **Fee Receiver Protection**: Dedicated fee receiver address for fee collection
- **Event Optimization**: Fee collection events only emitted when actual fees are charged

### 6. Upgrade Safety
- **UUPS Pattern**: Upgradeable proxy with admin-only upgrade authorization
- **Storage Gaps**: Proper storage layout management for upgrades
- **Initialization Protection**: Initializer pattern prevents double initialization

### 7. Price Deviation Protection
- **Automatic Validation**: Price changes validated during `processRequests()`
- **Deviation Limit**: Maximum 30% deviation from last settled price
- **First-Time Exception**: No validation on first price submission (no previous price exists)
- **Error Handling**: Reverts with `PriceDeviationTooLarge` if exceeded
- **Purpose**: Prevents operator errors or manipulation through extreme price changes

## Configuration Parameters

### TTL Settings
- **Subscription Request TTL**: Maximum 7 days, configurable by admin (1 day recommended)
- **Redemption Request TTL**: Maximum 7 days, configurable by admin (1 day recommended)

### Fee Rates (Basis Points)
- **Management Fee**: 0-2000 (0%-20%), configurable by admin
- **Performance Fee**: 0-2000 (0%-20%), configurable by admin
- **Redemption Fee**: 0-2000 (0%-20%), configurable by admin

### System Constants
- **Precision**: 18 decimal places (WAD)
- **Normalized Precision (USD)**: 8 decimal places
- **Basis Points Precision**: 10,000 (1 BPS = 0.01%)
- **Minimum Time Elapsed**: 6 hours for fee calculations
- **Seconds Per Year**: 365 days for annualized calculations
- **Maximum Price Deviation**: 30% (3,000 basis points)
- **Maximum Request Lifetime**: 7 days (MAX_TTL)
- **Maximum Asset Decimals**: 36 (overflow protection)

## Events & Monitoring

### Key Events
- **Request Events**: Creation, approval, rejection, cancellation, expiry, updates
- **Fee Events**: Fee collection (only when fees > 0), rate updates (only when values change), receiver changes
- **Asset Events**: Asset addition, removal, configuration updates
- **System Events**: TTL updates (only when values change), parameter changes
- **Expiry Events**: `SubscriptionRequestExpired` and `RedemptionRequestExpired` emitted when requests expire during processing

### Event Indexing
- Critical events are indexed for efficient filtering
- Request IDs and addresses are indexed for easy tracking
- Timestamp information included for audit trails

### Event Optimization
- **Conditional Emission**: Events are only emitted when meaningful changes occur
- **Fee Events**: `FeeCollection` only emitted when fees > 0
- **Rate Updates**: Rate update events only emitted when values actually change
- **TTL Updates**: TTL update events only emitted when values actually change
- **Gas Efficiency**: Reduces unnecessary gas costs and event log noise

## Price Management

### Last Settled Price
- **Per-Asset Tracking**: Each asset maintains its own last settled price
- **Price Updates**: Updated during `processRequests()` after successful processing
- **Price Format**: Stored in normalized USD units (8 decimals)
- **First-Time Processing**: No price validation on first submission (no previous price exists)

### Price Deviation Validation
- **Automatic Check**: Validated during `processRequests()` before processing requests
- **Deviation Limit**: Maximum 30% deviation from last settled price
- **Calculation**: `deviationBps = (abs(newPrice - lastPrice) * 10000) / lastPrice`
- **Error**: Reverts with `PriceDeviationTooLarge` if limit exceeded
- **Purpose**: Prevents operator errors and price manipulation

### Preview Functions with Last Settled Price
- **Fallback Mechanism**: Both `previewSubscription()` and `previewRedemption()` accept `sharesPrice = 0`
- **Behavior**: When `sharesPrice = 0`, automatically uses last settled price for the asset
- **Error Handling**: Reverts with `NoStoredPrice()` if no price has been settled yet
- **Use Case**: Allows users to preview transactions without knowing current price

## Integration Points

### External Contracts
- **Safe**: Main fund vault for asset storage
- **Performance Fee Module**: Custom fee calculation logic (one of the [performance fee modules](#performance-fee-modules))
- **Asset Tokens**: ERC20 tokens for deposits/redemptions

### Interface Compliance
- **ERC20**: Standard token interface
- **ERC165**: Interface detection support
- **Custom Interface**: IkpkShares for fund-specific operations

## Deployment & Initialization

### Constructor Parameters
```solidity
struct ConstructorParams {
    address asset;           // Base asset address
    address admin;           // Initial admin address
    string name;             // Share token name
    string symbol;           // Share token symbol
    address safe;            // Fund safe address
    uint64 subscriptionRequestTtl; // Subscription request TTL
    uint64 redemptionRequestTtl;  // Redemption request TTL
    address feeReceiver;      // Fee receiver address
    uint256 managementFeeRate;   // Management fee rate
    uint256 redemptionFeeRate;    // Redemption fee rate
    address performanceFeeModule;    // Performance fee module
    uint256 performanceFeeRate;      // Performance fee rate
}
```

### Initialization Flow
1. Contract deployment via proxy
2. Parameter validation
3. Asset configuration setup (base asset configured with isFeeModuleAsset=true)
4. Role assignment
5. State initialization

**Important**: The base asset (`asset` parameter) is automatically configured with `isFeeModuleAsset=true` during initialization. Performance fees are only calculated when processing requests for assets that have `isFeeModuleAsset=true` enabled. The base asset must have this flag enabled to ensure performance fees can be calculated for that asset.

## Testing & Verification

### Test Coverage
- Comprehensive unit tests for all functions
- Integration tests for request workflows
- Edge case testing for fee calculations
- Access control verification

### Security Considerations
- Reentrancy attack prevention
- Access control validation
- Fee calculation accuracy
- Asset escrow integrity

## Security Audits

Security audit reports are published in the repository's `audit-reports/` folder:

- `cantina-kpk-oivs-oct-2025.pdf` — Cantina audit (October 2025)
- `team-omega-kpk-oivs-oct-2025.pdf` — Team Omega audit (October 2025)

## Gas Optimization

### Efficient Operations
- **Batch Processing**: Processing 5 requests costs ~30,533 gas per subscription and ~22,238 gas per redemption (vs ~102,334 and ~48,021 for single requests)
- **Optimized Storage Layout**: Efficient struct packing and storage access patterns
- **Minimal External Calls**: Reduced oracle calls and token transfers
- **Efficient Loop Implementations**: Optimized batch processing algorithms
- **Event Optimization**: Conditional event emission reduces gas costs when no state changes occur

### Gas Costs
*Based on actual gas measurements from test suite*

#### Core Operations
- **Subscription request**: 250,756 gas
- **Redemption request**: 186,385 gas
- **Subscription processing (approve)**: 102,334 gas
- **Subscription processing (reject)**: 47,448 gas
- **Redemption processing (approve)**: 48,021 gas
- **Redemption processing (reject)**: 12,157 gas

#### Batch Operations
- **Process 5 subscription requests**: 152,667 gas (30,533 gas per request)
- **Process 5 redemption requests**: 111,191 gas (22,238 gas per request)

#### Request Cancellation
- **Cancel subscription**: 9,840 gas
- **Cancel redemption**: 8,649 gas

#### Asset Management
- **Update asset configuration**: 118,600 gas

#### Fee Management
- **Set management fee rate**: 33,706 gas
- **Set redemption fee rate**: 23,728 gas
- **Set performance fee rate**: 22,237 gas
- **Set fee receiver**: 22,407 gas
- **Set subscription request TTL**: 24,149 gas
- **Set redemption request TTL**: 24,198 gas

#### View Functions
- **Get request details**: 4,395 gas
- **Convert assets to shares**: 21,246 gas
- **Convert shares to assets**: 20,332 gas
- **Get approved assets list**: 15,998 gas
- **Get approved asset details**: 21,445 gas

#### Preview Functions
- **Preview subscription**: Calculates shares that would be received for given assets
  - If `sharesPrice = 0`, uses last settled price for the asset
  - Reverts with `NoStoredPrice()` if no price has been settled yet
  - Returns shares before fees (fees are not included in preview)
- **Preview redemption**: Calculates assets that would be received for given shares
  - If `sharesPrice = 0`, uses last settled price for the asset
  - Reverts with `NoStoredPrice()` if no price has been settled yet
  - Returns assets after redemption fees (fees are deducted in preview)

#### Fee Collection
- **Process requests (with management fee)**: 144,834 gas
- **Process requests (with redemption fee)**: 48,021 gas

### Running Gas Tests
To get current gas measurements, run the gas test suite:

```bash
forge test --match-contract kpkSharesGasTest -vv
```

The tests will output detailed gas usage for each operation, allowing you to verify current gas costs and identify any changes after code modifications.

## Future Considerations

### Potential Enhancements
- **Additional Fee Modules**: More performance fee calculation strategies beyond watermark-based

### Upgrade Path
- **UUPS Pattern**: Allows for future contract upgrades
- **Storage Layout**: Maintains compatibility across upgrades
- **Interface Evolution**: Backward-compatible interface updates
