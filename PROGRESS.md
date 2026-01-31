# Porto Tranches - Implementation Progress

**Spec:** [docs/porto_tranching_layer.md](docs/porto_tranching_layer.md)
**Last Updated:** 2026-01-30

---

## Overview

Building a tranching mechanism (UA → srUA + jrUA) for yield-bearing assets.

---

## Completed

| Phase | Description                                            | Status                         |
| ----- | ------------------------------------------------------ | ------------------------------ |
| 1     | SettlementRatioModel - Waterfall logic library         | ✅                             |
| 2     | Oracle Integration - Chainlink with decimal conversion | ✅                             |
| 3     | Liquidation Trigger - Opt-in premature finalization    | ✅                             |
| 4a    | Router - Tranche swap operations                       | ✅                             |
| 4b    | Factory                                                | ⬚ Skipped (not needed for POC) |
| 5     | Foundry Migration - 104 Solidity tests                 | ✅                             |

---

## Phase 6: Foundry Migration

**Status:** ✅ Complete

| Task | Description                                    | Status |
| ---- | ---------------------------------------------- | ------ |
| 6.1  | Project setup (foundry.toml, remappings, deps) | ✅     |
| 6.2  | Move contracts to src/                         | ✅     |
| 6.3  | Update CLAUDE.md for Foundry conventions       | ✅     |
| 6.4  | Migrate unit tests to Solidity (104 tests)     | ✅     |
| 6.5  | Remove Hardhat artifacts                       | ✅     |

---

## Phase 7: Deployment & Fork Testing

**Status:** 🔄 In Progress

| Task | Description                              | Status    |
| ---- | ---------------------------------------- | --------- |
| 7.1  | Create deployment scripts                | ✅        |
| 7.2  | Fork tests for deployment validation     | ⬚ Pending |
| 7.3  | Fork tests for router trading scenarios  | ⬚ Pending |
| 7.4  | Achieve 100% line and statement coverage | ⬚ Pending |

---

## Pre-Deployment Checklist

**Script:** `script/DeployTrancheRWATestnet.s.sol`

| Item | Description                                                                          | Status |
| ---- | ------------------------------------------------------------------------------------ | ------ |
| ⬚    | Use 0.05% fee tier (500) for PRIME/srPRIME pool - stable pair like ETH/stETH         | TODO   |
| ⬚    | Adjust `tickLower` and `tickUpper` for concentrated liquidity (currently full range) | TODO   |
| ⬚    | Verify oracle price decimals work correctly (currently 8 decimals)                   | TODO   |
| ⬚    | Update `MATURITY` from 1 hour to production value (e.g., 30 days)                    | TODO   |
| ⬚    | Review `liquidationBuffer` and `liquidationReward` values (currently 2.5% each)      | TODO   |
| ⬚    | Verify Uniswap V3 contract addresses for target network                              | TODO   |
| ⬚    | Replace `ERC20Mock` with real PRIME token address                                    | TODO   |
| ⬚    | Replace `MockChainlinkAggregator` with real Chainlink price feed                     | TODO   |
| ⬚    | Set appropriate `sqrtPriceX96` if pool ratio is not 1:1                              | TODO   |
| ⬚    | Configure admin address (currently deployer)                                         | TODO   |

---

## Phase 8: Solidity Version Upgrade

**Status:** ⬚ Pending

| Task | Description                                     | Status    |
| ---- | ----------------------------------------------- | --------- |
| 8.1  | Upgrade all contracts to latest stable Solidity | ⬚ Pending |
| 8.2  | Update compiler settings and dependencies       | ⬚ Pending |
| 8.3  | Verify all tests pass with new version          | ⬚ Pending |

---

## Notes

- Solidity 0.8.28 with `cancun` EVM (transient storage support)
- Foundry framework with `via_ir` compilation
- OpenZeppelin contracts for ERC20 base
- Chainlink contracts for oracle integration
