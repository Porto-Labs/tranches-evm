# Porto Tranches - Implementation Progress

**Repository:** /Users/kotashki/Documents/dev/porto/tranches-evm
**Spec:** [docs/porto_tranching_layer.md](docs/porto_tranching_layer.md)
**Last Updated:** 2026-01-25

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
| **PortoMath.sol** | ✅ Done | Fixed-point math (mulDown/Up, divDown/Up) |
| **Spec Document** | ✅ Done | `docs/porto_tranching_layer.md` |
| **SettlementRatioModel.sol** | ✅ Done | Waterfall logic library |

### V1 Implementation Summary

Current TrancheMarket implements:
- `tokenize(uaIn, receiver)` - deposit UA, mint srUA + jrUA at fixed ratio
- `redeemPreMaturity(srIn, jrIn, receiver)` - redeem UA by burning both tranches in ratio
- `finalize(srRateUA, jrRateUA)` - admin sets redemption rates post-expiry
- `redeemSenior(srIn, receiver)` - redeem senior post-finalization
- `redeemJunior(jrIn, receiver)` - redeem junior post-finalization

---

## Remaining Work

### Phase 1: SettlementRatioModel

**Status:** ✅ Complete

Stateless library that calculates senior/junior redemption rates using waterfall logic:
- Condition A (Surplus): Senior capped at target, junior gets excess
- Condition B (Compression): Senior takes all yield, junior at principal
- Condition C (Erosion): Senior protected at floor, junior eroded

**Files:**
- `contracts/settlement/SettlementRatioModel.sol`
- `test/settlement/SettlementRatioModel.test.ts` (27 tests)

---

### Phase 2: Oracle Integration

| Task | Description | Status |
|------|-------------|--------|
| **2.1** | Add Chainlink `AggregatorV3Interface` | ⬚ Pending |
| **2.2** | Create `MockChainlinkAggregator.sol` for testing | ⬚ Pending |
| **2.3** | Refactor `finalize(referencePrice, deviationThreshold)` | ⬚ Pending |
| **2.4** | Add `previewSettlement()` function | ⬚ Pending |
| **2.5** | Add new constructor params (priceFeed) | ⬚ Pending |

### Phase 3: Factory & Router

| Task | Description | Status |
|------|-------------|--------|
| **3.1** | Implement `TrancheMarketFactory.sol` (Optional or maybe not needed for POC) | ⬚ Pending |
| **3.2** | Implement `TrancheRouter.sol` (Optinal as for the POC it could be a simple Multicall contract) | ⬚ Pending |

### Phase 4: Integration Testing

| Task | Description | Status |
|------|-------------|--------|
| **4.1** | Unit tests for TrancheMarket (updated) | ⬚ Pending |
| **4.2** | Integration tests (E2E with mock oracle) | ⬚ Pending |
| **4.3** | Edge case tests (all 3 waterfall conditions) | ⬚ Pending |

---

## Definition of Done

### Phase 1: SettlementRatioModel
✅ `SettlementRatioModel.sol` with waterfall logic and unit tests

### Full Implementation
1. ✅ Deposit UA → srUA/jrUA at fixed ratio
2. ✅ Pre-maturity recomposition works only in fixed ratio
3. ⬚ `previewSettlement()` returns projected rates from current oracle price
4. ⬚ After expiry, multisig calls `finalize(referencePrice, deviationThreshold)`
5. ⬚ Finalize validates oracle price within threshold, calculates rates via SettlementRatioModel
6. ✅ Post-maturity unilateral redemption works for both srUA and jrUA
7. ⬚ All integration tests pass with mock Chainlink oracle

---

## Notes

- Using yarn for package management
- Solidity 0.8.23, Hardhat, TypeChain, ethers v6
- OpenZeppelin contracts for ERC20 base
