# Coverage Report Analysis

## Overall Coverage Summary

| Metric | Coverage | Uncovered |
|--------|----------|-----------|
| **Lines** | 98.65% (365/370) | 5 lines |
| **Statements** | 97.08% (399/411) | 12 statements |
| **Branches** | 86.59% (71/82) | **11 branches** |
| **Functions** | 100.00% (58/58) | 0 functions |

## Key Findings

### ✅ Strengths
- **100% function coverage** - All public/external functions are tested
- **98.65% line coverage** - Excellent overall code coverage
- **97.08% statement coverage** - Most statements are executed

### ⚠️ Areas for Improvement
- **86.59% branch coverage** - 11 conditional branches are not fully tested

## Why Branches Are Not Covered

The main gap is in **branch coverage (86.59%)**, meaning 11 conditional branches have not been tested in both directions (true/false paths). Here are the likely uncovered branches:

### 1. **Fee Calculation Edge Cases** (Lines 965, 979, 997)
```solidity
if (feeShares > 0) { ... }  // When feeShares == 0 (no transfer)
if (feeAmount > 0) { ... }  // When feeAmount == 0 (no mint)
if (performanceFee > 0) { ... }  // When performanceFee == 0 (no mint)
```
**Why not covered**: These branches test when fees round down to zero. This happens when:
- Fee rates are very small
- Amounts are very small
- Time elapsed is minimal

**Recommendation**: Add tests with minimal fee rates and very small amounts to trigger zero-fee scenarios.

### 2. **Performance Fee Module Zero Address Check** (Line 990)
```solidity
if (performanceFeeModule == address(0)) {
    return 0;
}
```
**Why not covered**: The branch where `performanceFeeModule` is `address(0)` during fee charging might not be fully tested in all code paths.

**Recommendation**: Ensure tests cover fee charging scenarios both with and without a performance fee module set.

### 3. **Price Deviation Early Return** (Line 900)
```solidity
if (lastPrice == 0) {
    return;  // Early return when no last price exists
}
```
**Why not covered**: The case where `_lastSettledPrice[asset]` is zero during price deviation checks might not be tested in all processing scenarios.

**Recommendation**: Test processing requests for assets that have never had a settled price.

### 4. **Asset Recovery Escrow Check** (Line 624)
```solidity
if (escrowed > 0) {
    return 0;
}
```
**Why not covered**: The branch where `subscriptionAssets[token] == 0` (no escrow) might not be tested in all recovery scenarios.

**Recommendation**: Test asset recovery for approved assets with zero escrow.

### 5. **Fee Collection Event Emission** (Line 952)
```solidity
if (managementFee > 0 || performanceFee > 0) {
    emit FeeCollection(managementFee, performanceFee);
}
```
**Why not covered**: The case where both fees are zero (no event emitted) might not be explicitly tested.

**Recommendation**: Test fee charging scenarios where both management and performance fees round to zero.

### 6. **Redemption Fee Rate Check** (Line 845)
```solidity
if (redemptionFeeRate > 0) {
    redemptionFee = _chargeRedemptionFee(request);
}
```
**Why not covered**: The branch where `redemptionFeeRate == 0` during request processing might not be fully covered.

**Recommendation**: Test processing redemptions with zero redemption fee rate.

### 7. **Management Fee Rate Check** (Line 933)
```solidity
if (managementFeeRate > 0) {
    // ... fee calculation
}
```
**Why not covered**: The branch where `managementFeeRate == 0` during fee charging might not be fully tested.

**Recommendation**: Test fee charging with zero management fee rate.

### 8. **Time Elapsed Checks** (Lines 935, 945)
```solidity
if (timeElapsed > MIN_TIME_ELAPSED) { ... }
if (perfTimeElapsed > MIN_TIME_ELAPSED) { ... }
```
**Why not covered**: The branch where `timeElapsed <= MIN_TIME_ELAPSED` (6 hours) might not be fully tested in all scenarios.

**Recommendation**: Test fee charging with time elapsed exactly at or below the minimum threshold.

### 9. **Asset Update Pending Requests Check** (Line 1023)
```solidity
if (_pendingRequestsCount[asset] > 0) {
    revert InvalidArguments();
}
```
**Why not covered**: The branch where `_pendingRequestsCount[asset] == 0` during asset removal might not be fully tested.

**Recommendation**: Test asset removal scenarios with zero pending requests.

### 10. **Complex Conditional Logic**
Some nested conditions in fee calculation and validation functions might have uncovered combinations of true/false paths.

## Recommendations

1. **Add edge case tests** for zero-fee scenarios
2. **Test boundary conditions** (exactly at thresholds like MIN_TIME_ELAPSED)
3. **Test with zero values** (zero fee rates, zero amounts, zero addresses)
4. **Test fee rounding** to ensure zero-fee branches are covered
5. **Test all conditional combinations** in complex nested if statements

## Conclusion

The codebase has **excellent overall coverage** (98.65% lines, 97.08% statements, 100% functions). The remaining gap is primarily in **branch coverage (86.59%)**, which represents edge cases and conditional logic paths that are harder to trigger but should still be tested for completeness and robustness.

## Recent Improvements

Coverage has improved significantly since the initial report:
- **Lines**: Increased from 95.68% to 98.65% (+2.97%)
- **Statements**: Increased from 94.40% to 97.08% (+2.68%)
- **Branches**: Increased from 84.15% to 86.59% (+2.44%)
- **Uncovered branches**: Reduced from 13 to 11 branches

The parameterized test framework has been implemented to help test edge cases, boundary conditions, and zero-value scenarios more systematically.

