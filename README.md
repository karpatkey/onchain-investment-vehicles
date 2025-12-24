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
- `WatermarkFee`: Watermark-based performance fee implementation
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
| `initialize` | ❌ | ❌ | ❌ | ✅ (reinitializer) |
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
- **Watermark System**: Performance fees only charged on profits above the highest previous share price
- **Modular Design**: Performance fee calculation can be upgraded by changing the fee module

### 5. Performance Fee System
- **Watermark Mechanism**: Tracks the highest share price achieved
- **Profit-Only Charging**: Fees only charged on gains above the watermark
- **Modular Architecture**: Fee calculation logic can be upgraded via module replacement
- **Time-Based Calculation**: Performance fees calculated based on time elapsed and price appreciation
- **Automatic Watermark Updates**: Watermark is updated when new high prices are achieved

### 6. Request Lifecycle
```
Request Creation → Pending → Processing → Approved/Rejected
       ↓              ↓          ↓           ↓
   User Action   TTL Window  Operator    Final State
   (Subscription/ (Cancellation  Review    (Shares Minted/
    Redeem)      Available)    Required   Assets Transferred)
```

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
- **Initialization Protection**: Reinitializer pattern prevents double initialization

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
- **Minimum Time Elapsed**: 1 day for fee calculations
- **Seconds Per Year**: 365 days for annualized calculations

## Events & Monitoring

### Key Events
- **Request Events**: Creation, approval, rejection, cancellation, updates
- **Fee Events**: Fee collection (only when fees > 0), rate updates (only when values change), receiver changes
- **Asset Events**: Asset addition, removal, configuration updates
- **System Events**: TTL updates (only when values change), parameter changes

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

## Integration Points

### External Contracts
- **Safe**: Main fund vault for asset storage
- **Performance Fee Module**: Custom fee calculation logic (WatermarkFee implementation)
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

## Gas Optimization

### Efficient Operations
- **Batch Processing**: Processing 5 requests costs ~22,400 gas per subscription and ~24,168 gas per redemption (vs ~70,891 and ~51,319 for single requests)
- **Optimized Storage Layout**: Efficient struct packing and storage access patterns
- **Minimal External Calls**: Reduced oracle calls and token transfers
- **Efficient Loop Implementations**: Optimized batch processing algorithms
- **Event Optimization**: Conditional event emission reduces gas costs when no state changes occur

### Gas Costs
*Based on actual gas measurements from test suite*

#### Core Operations
- **Subscription request**: 205,010 gas
- **Redemption request**: 143,991 gas
- **Subscription processing (approve)**: 72,297 gas
- **Subscription processing (reject)**: 17,413 gas
- **Redemption processing (approve)**: 51,231 gas
- **Redemption processing (reject)**: 30,284 gas

#### Batch Operations
- **Process 5 subscription requests**: 117,976 gas (23,595 gas per request)
- **Process 5 redemption requests**: 116,258 gas (23,251 gas per request)

#### Request Cancellation
- **Cancel subscription**: 8,253 gas
- **Cancel redemption**: 27,181 gas

#### Asset Management
- **Update asset configuration**: 118,601 gas

#### Fee Management
- **Set management fee rate**: 24,498 gas
- **Set redemption fee rate**: 23,750 gas
- **Set performance fee rate**: 19,648 gas
- **Set fee receiver**: 22,407 gas
- **Set subscription request TTL**: 24,168 gas

#### View Functions
- **Get request details**: 4,218 gas
- **Convert assets to shares**: 20,543 gas
- **Convert shares to assets**: 20,312 gas
- **Get approved assets list**: 16,042 gas
- **Get approved asset details**: 21,469 gas

#### Fee Collection
- **Process requests (with management fee)**: 121,159 gas
- **Process requests (with redemption fee)**: 51,231 gas

### Running Gas Tests
To get current gas measurements, run the gas test suite:

```bash
cd contracts
forge test --match-contract kpkSharesGasTest -vv
```

The tests will output detailed gas usage for each operation, allowing you to verify current gas costs and identify any changes after code modifications.

## Future Considerations

### Potential Enhancements
- **Cross-Chain Support**: Bridge integration for multi-chain operations
- **Governance Integration**: DAO-based parameter management
- **Additional Fee Modules**: More performance fee calculation strategies beyond watermark-based
- **Request Batching Improvements**: Further optimization of batch processing gas costs
- **Advanced Asset Management**: Dynamic asset weight management and rebalancing

### Upgrade Path
- **UUPS Pattern**: Allows for future contract upgrades
- **Storage Layout**: Maintains compatibility across upgrades
- **Interface Evolution**: Backward-compatible interface updates

## Support & Maintenance

### Monitoring
- Regular event monitoring for system health
- Fee collection verification
- Asset balance reconciliation
- Request processing metrics

### Maintenance
- Regular parameter reviews
- Fee rate adjustments
- Asset configuration updates
- Security audits and updates

---

*This documentation covers the core functionality and safety considerations of the kpkShares contract. For specific implementation details, refer to the contract source code and test files.*
