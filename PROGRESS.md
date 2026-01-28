# Porto Tranches - Implementation Progress

**Repository:** /Users/kotashki/Documents/dev/porto/tranches-evm
**Spec:** [docs/porto_tranching_layer.md](docs/porto_tranching_layer.md)
**Last Updated:** 2026-01-28

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
| **TrancheMarket.sol** | ✅ Done (V2) | Oracle-integrated finalization |
| **ITrancheMarket.sol** | ✅ Done | Interface with oracle support |
| **Errors.sol** | ✅ Done | Centralized error definitions (incl. oracle errors) |
| **PortoMath.sol** | ✅ Done | Fixed-point math with division-by-zero protection |
| **Spec Document** | ✅ Done | `docs/porto_tranching_layer.md` |
| **SettlementRatioModel.sol** | ✅ Done | Waterfall logic library |
| **MockChainlinkAggregator.sol** | ✅ Done | Test mock for Chainlink oracle |

### V2 Implementation Summary

Current TrancheMarket implements:
- `tranche(uaIn, receiver)` - deposit UA, mint srUA + jrUA at fixed ratio
- `recombine(srIn, jrIn, receiver)` - recombine tranches into UA (pre-maturity)
- `finalize(referencePrice, deviationThreshold)` - oracle-based finalization with deviation check
- `previewSettlement()` - preview rates based on current oracle price
- `liquidate()` - premature finalization when liquidation conditions are met
- `previewLiquidation()` - preview liquidation state and outcomes
- `redeemSenior(srIn, receiver)` - redeem senior post-finalization
- `redeemJunior(jrIn, receiver)` - redeem junior post-finalization

**Oracle Features:**
- Chainlink AggregatorV3Interface integration
- Automatic decimal conversion (supports 6, 8, 18 decimal oracles)
- 24-hour staleness validation
- Deviation threshold for reference price validation
- `InitialPriceSet` event emitted at market creation

**Liquidation Features:**
- Opt-in feature enabled via `liquidationEnabled` in MarketParams
- Configurable `liquidationBuffer` and `liquidationReward` (each max 2.5%)
- Pre-calculated `liquidationPrice` stored at market creation
- Admin-only trigger with immediate reward distribution
- Junior gets 0, senior gets remaining UA

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

**Status:** ✅ Complete

Chainlink oracle integration for automated settlement rate calculation using waterfall logic.

**Files:**
- `contracts/core/TrancheMarket.sol` (updated with oracle support)
- `contracts/interfaces/ITrancheMarket.sol` (updated interface)
- `contracts/errors/Errors.sol` (oracle error definitions)
- `contracts/test/MockChainlinkAggregator.sol` (test mock)
- `test/core/TrancheMarket.test.ts` (81 tests, includes 43 liquidation tests)

**Features:**
- `finalize(referencePrice, deviationThreshold)` - uses oracle price, validates deviation
- `previewSettlement()` - preview rates from current oracle price
- Decimal scaling for any oracle precision (6, 8, 18 decimals)
- 24-hour staleness check
- Constructor uses `MarketParams` struct for cleaner initialization

### Phase 3: Liquidation Trigger

**Status:** ✅ Complete

**Spec:** [docs/liquidation_trigger_feature.md](docs/liquidation_trigger_feature.md)

Premature finalization mechanism triggered when junior tranche is wiped out.

**Core Concept:**
- Opt-in feature enabled at market creation
- Triggers when oracle price falls below liquidation price (before junior fully wiped out)
- Two configurable parameters (each max 2.5% of junior principal):
  - `liquidationBuffer` → Extra senior protection
  - `liquidationReward` → Liquidator incentive
- Sets `jrRateUA = 0`, senior gets floor + buffer
- Admin-only - same access control as `finalize()`

| Task | Description | Status |
|------|-------------|--------|
| **3.1** | Add `liquidationEnabled`, `liquidationBuffer`, `liquidationReward` to MarketParams | ✅ Done |
| **3.2** | Calculate and store `liquidationPrice` at construction | ✅ Done |
| **3.3** | Implement `liquidate()` function with reward distribution | ✅ Done |
| **3.4** | Implement `previewLiquidation()` view | ✅ Done |
| **3.5** | Update interface and add errors | ✅ Done |
| **3.6** | Unit tests for liquidation feature (43 tests) | ✅ Done |
| **3.7** | Update spec document (`docs/porto_tranching_layer.md`) with liquidation section | ✅ Done |

---

### Phase 4: Factory & Router

| Task | Description | Status |
|------|-------------|--------|
| **4.1** | Implement `TrancheMarketFactory.sol` (Optional, may not be needed for POC) | ⬚ Pending |
| **4.2** | Implement `TrancheRouter.sol` (Optional, could be a simple Multicall for POC) | ⬚ Pending |

---

### Phase 5: Integration Testing

**Status:** ✅ Complete (merged with Phase 2)

| Task | Description | Status |
|------|-------------|--------|
| **5.1** | Unit tests for TrancheMarket (updated) | ✅ Done |
| **5.2** | Integration tests (E2E with mock oracle) | ✅ Done |
| **5.3** | Edge case tests (all 3 waterfall conditions) | ✅ Done |

**Test Coverage:**
- Constructor validation (oracle address, initial price, yield range)
- Oracle decimal conversion (6, 8, 18 decimals)
- Staleness validation (24h threshold)
- Deviation threshold enforcement
- All 3 waterfall conditions (Surplus, Compression, Erosion)
- No over-distribution invariant across various prices

---

## Definition of Done

### Phase 1: SettlementRatioModel
✅ `SettlementRatioModel.sol` with waterfall logic and unit tests

### Full Implementation
1. ✅ Deposit UA → srUA/jrUA at fixed ratio
2. ✅ Pre-maturity recomposition works only in fixed ratio
3. ✅ `previewSettlement()` returns projected rates from current oracle price
4. ✅ After expiry, multisig calls `finalize(referencePrice, deviationThreshold)`
5. ✅ Finalize validates oracle price within threshold, calculates rates via SettlementRatioModel
6. ✅ Post-maturity unilateral redemption works for both srUA and jrUA
7. ✅ Liquidation trigger feature with buffer/reward parameters
8. ✅ All integration tests pass with mock Chainlink oracle (124 total tests)

---

## Notes

- Using yarn for package management
- Solidity 0.8.23, Hardhat, TypeChain, ethers v6
- OpenZeppelin contracts for ERC20 base
- Chainlink contracts for oracle integration (@chainlink/contracts ^1.3.0)
