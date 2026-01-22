# Porto Tranches - Implementation Progress

**Repository:** /Users/kotashki/Documents/dev/porto/tranches-evm
**Spec:** [docs/porto_tranching_layer.md](docs/porto_tranching_layer.md)
**Last Updated:** 2026-01-22

---

## Overview

Building a tranching mechanism (UA → srUA + jrUA) for yield-bearing assets.

**Core Concept:**
- Users deposit UA (Underlying Asset) and receive Senior + Junior tranche tokens
- Fixed ratio minting (e.g., 80% senior : 20% junior)
- Pre-maturity: ratio-based redemption only (requires both tranches)
- Post-maturity: unilateral redemption at finalized rates
- Senior protected; junior residual (can be wiped in loss scenarios)

---

## Current State

### Completed

| Component | Status | Notes |
|-----------|--------|-------|
| **TrancheToken.sol** | ✅ Done | Minimal ERC20 with market-only mint/burn |
| **TrancheMarket.sol** | ✅ Done (V1) | Admin-controlled finalization |
| **ITrancheMarket.sol** | ✅ Done | Interface for V1 |
| **Errors.sol** | ✅ Done | Centralized error definitions |
| **PortoMath.sol** | ✅ Done | Minimal fixed-point math |
| **Spec Document** | ✅ Done | `docs/porto_tranching_layer.md` |

### V1 Implementation Summary

Current TrancheMarket implements:
- `tokenize(uaIn, receiver)` - deposit UA, mint srUA + jrUA at fixed ratio
- `redeemPreMaturity(srIn, jrIn, receiver)` - redeem UA by burning both tranches in ratio
- `finalize(srRateUA, jrRateUA)` - admin sets redemption rates post-expiry
- `redeemSenior(srIn, receiver)` - redeem senior post-finalization
- `redeemJunior(jrIn, receiver)` - redeem junior post-finalization

---

## Remaining Work

### Phase 1: Oracle-Based Settlement (Spec Compliance)

The spec requires on-chain rate calculation via oracle, not admin-provided rates.

| Task | Description | Status |
|------|-------------|--------|
| **1.1** | Add Chainlink `AggregatorV3Interface` | ⬚ Pending |
| **1.2** | Create `MockChainlinkAggregator.sol` for testing | ⬚ Pending |
| **1.3** | Implement `ISettlementRatioModel` interface | ⬚ Pending |
| **1.4** | Implement `SettlementRatioModel.sol` (waterfall logic) | ⬚ Pending |
| **1.5** | Add exponential math to PortoMath (`(1 + r)^t`) | ⬚ Pending |
| **1.6** | Refactor `finalize(referencePrice, deviationThreshold)` | ⬚ Pending |
| **1.7** | Add `previewSettlement()` function | ⬚ Pending |
| **1.8** | Add new constructor params (priceFeed, settlementModel, APYs) | ⬚ Pending |

### Phase 2: Factory & Router

| Task | Description | Status |
|------|-------------|--------|
| **2.1** | Implement `TrancheMarketFactory.sol` | ⬚ Pending |
| **2.2** | Implement `TrancheRouter.sol` | ⬚ Pending |

### Phase 3: Testing

| Task | Description | Status |
|------|-------------|--------|
| **3.1** | Unit tests for TrancheMarket | ⬚ Pending |
| **3.2** | Unit tests for SettlementRatioModel | ⬚ Pending |
| **3.3** | Integration tests (E2E with mock oracle) | ⬚ Pending |
| **3.4** | Edge case tests (all 3 waterfall conditions) | ⬚ Pending |

---

## Settlement Model (From Spec)

### Waterfall Logic (Section 8.3)

```
totalValueUsd = uaQuantity × oraclePrice
seniorFloorValue = seniorPrincipal × (1 + floorApy)^t
seniorTargetValue = seniorPrincipal × (1 + targetApy)^t

Condition A (Surplus): totalValueUsd >= seniorTargetValue + juniorPrincipal
  → Senior: seniorTargetValue, Junior: residual

Condition B (Target Compression): seniorFloorValue + juniorPrincipal <= totalValueUsd < seniorTargetValue + juniorPrincipal
  → Senior: totalValueUsd - juniorPrincipal, Junior: principal only

Condition C (Junior Erosion): totalValueUsd < seniorFloorValue + juniorPrincipal
  → Senior: min(totalValueUsd, seniorFloorValue), Junior: residual (may be 0)
```

### New finalize() Signature

```solidity
function finalize(uint256 referencePrice, uint256 deviationThreshold) external;
```

- Multisig provides reference price + deviation threshold
- On-chain oracle provides actual price
- Reverts if `|oraclePrice - referencePrice| > deviationThreshold`
- Rates calculated on-chain via SettlementRatioModel

---

## File Structure (Target)

```
contracts/
├── core/
│   ├── TrancheMarket.sol          ✅ (needs Phase 1 updates)
│   └── TrancheToken.sol           ✅
├── interfaces/
│   ├── ITrancheMarket.sol         ✅ (needs Phase 1 updates)
│   ├── ISettlementRatioModel.sol  ⬚ NEW
│   └── AggregatorV3Interface.sol  ⬚ NEW (Chainlink)
├── settlement/
│   └── SettlementRatioModel.sol   ⬚ NEW
├── test/
│   ├── ERC20Mock.sol              ✅
│   └── MockChainlinkAggregator.sol ⬚ NEW
├── libraries/
│   └── math/PortoMath.sol         ✅ (may need exp math)
├── errors/
│   └── Errors.sol                 ✅ (needs new oracle errors)
├── factory/
│   └── TrancheMarketFactory.sol   ⬚ NEW
└── router/
    └── TrancheRouter.sol          ⬚ NEW
```

---

## Definition of Done

The implementation is complete when:

1. ✅ Deposit UA → srUA/jrUA at fixed ratio
2. ✅ Pre-maturity recomposition works only in fixed ratio
3. ⬚ `previewSettlement()` returns projected rates from current oracle price
4. ⬚ After expiry, multisig calls `finalize(referencePrice, deviationThreshold)`
5. ⬚ Finalize validates oracle price within threshold, calculates rates via SettlementRatioModel
6. ✅ Post-maturity unilateral redemption works for both srUA and jrUA
7. ⬚ Waterfall logic works correctly (Conditions A, B, C)
8. ⬚ All tests pass with mock Chainlink oracle

---

## Notes

- Using yarn for package management
- Solidity 0.8.23, Hardhat, TypeChain
- OpenZeppelin contracts for ERC20 base
