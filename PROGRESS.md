# Porto Tranches - Implementation Progress Tracker

**Repository:** /Users/kotashki/Documents/dev/porto/tranches-evm
**Reference (Pendle):** /Users/kotashki/Documents/dev/porto/pendle-core-v2-public
**Started:** 2025-12-14

---

## Overview

Building a tranching mechanism (SY → srSY + jrSY) following the spec in `tranching_mechanism.md`.

**Key Principles:**
- Fixed ratio minting (e.g., 80% senior : 20% junior)
- Pre-maturity: ratio-based redemption only
- At maturity: snapshot growth factor G on-chain
- Post-maturity: unilateral redemption with fixed rates
- Senior protected; junior residual (can be wiped)

---

## Milestone Status

### 0. Bootstrap Hardhat Repo
- [x] **Task 0.1** — Initialize Hardhat + TS + TypeChain ✅ COMPLETED (2025-12-14)

### 1. Pendle-style Reusable Libs
- [ ] **Task 1.1** — Copy/adapt common libraries (math, errors, token helpers)

### 2. Specs + Interfaces
- [ ] **Task 2.1** — Write protocol spec docs (auditor-grade)
- [ ] **Task 2.2** — Define ISY interface
- [ ] **Task 2.3** — Define tranche market interface

### 3. Core ERC20 Tranche Tokens
- [ ] **Task 3.1** — Implement TrancheToken.sol (mint/burn restricted ERC20)

### 4. Core Tranche Market Contract
- [ ] **Task 4.1** — Implement TrancheMarket.sol (per-expiry instance)

### 5. Factory
- [ ] **Task 5.1** — Implement TrancheMarketFactory.sol

### 6. Router
- [ ] **Task 6.1** — Implement TrancheRouter.sol

### 7. SY Adapters
- [ ] **Task 7.1** — SY adapter: ERC-4626
- [ ] **Task 7.2** — SY adapter: rate-index receipt token

### 8. Tests
- [ ] **Task 8.1** — Unit tests for TrancheMarket
- [ ] **Task 8.2** — Router integration tests (E2E)
- [ ] **Task 8.3** — Invariant tests

### 9. Hardhat Scripts + Tasks
- [ ] **Task 9.1** — Deployment scripts
- [ ] **Task 9.2** — Hardhat tasks

### 10. Pendle Reuse Guidance
- [ ] **Task 10.1** — Document reuse list (what to copy, what NOT to copy)

---

## Definition of Done (Full System)

The implementation is complete when:

1. ✅ Deploy SY adapter for mock yield-bearing token
2. ✅ Create market (expiry, weights, senior target)
3. ✅ Deposit underlying → SY → srSY/jrSY
4. ✅ Pre-maturity recomposition works only in fixed ratio
5. ✅ After expiry, finalize() computes on-chain using exchangeRate() delta
6. ✅ Post-maturity unilateral redemption works for both srSY and jrSY
7. ✅ Underperformance scenario wipes jrSY to protect srSY
8. ✅ All tests and tasks pass

---

## Current Task Details

### Task 0.1 — Initialize Hardhat + TS + TypeChain

**Status:** ✅ COMPLETED (2025-12-14)

**Files Created/Configured:**
- [x] `/Users/kotashki/Documents/dev/porto/tranches-evm/package.json`
- [x] `/Users/kotashki/Documents/dev/porto/tranches-evm/hardhat.config.ts`
- [x] `/Users/kotashki/Documents/dev/porto/tranches-evm/tsconfig.json`
- [x] `/Users/kotashki/Documents/dev/porto/tranches-evm/.env.example`
- [x] `/Users/kotashki/Documents/dev/porto/tranches-evm/.prettierrc`
- [x] `/Users/kotashki/Documents/dev/porto/tranches-evm/.eslintrc.cjs`
- [x] `/Users/kotashki/Documents/dev/porto/tranches-evm/.solhint.json`
- [x] `/Users/kotashki/Documents/dev/porto/tranches-evm/.gitignore`
- [x] Directory structure: `contracts/{core,interfaces,libraries,errors,router,sy}`, `test/{market,router,invariants}`, `scripts`, `tasks`
- [x] Placeholder contract: `contracts/core/PortoTranches.sol`
- [x] Basic test file: `test/PortoTranches.test.ts`

**Acceptance Criteria:**
- [x] `yarn compile` succeeds ✅
- [x] `yarn test` succeeds ✅ (3 passing tests)
- [x] TypeChain output generated into `/Users/kotashki/Documents/dev/porto/tranches-evm/typechain-types` ✅

**Notes:**
- Used ethers v5 with @nomiclabs/hardhat-ethers and @nomiclabs/hardhat-waffle
- Solidity compiler version: 0.8.23 (shanghai EVM)
- Optimizer enabled with 1,000,000 runs for gas optimization

---

### Next Task: Task 1.1 — Copy/adapt common libraries

**Status:** 🔜 READY TO START

**Description:** Copy and adapt common libraries (math, errors, token helpers) from Pendle repo, removing PT/YT-specific dependencies.

---

## Task Log

### 2025-12-14

#### Task 0.1 Completed ✅
- Created PROGRESS.md tracking template
- Examined Pendle repo Hardhat configuration for reference patterns
- Created complete Hardhat + TypeScript + TypeChain setup:
  - `package.json` with dependencies (Hardhat 2.19.4, TypeChain, ethers v5, OpenZeppelin 4.9.3)
  - `hardhat.config.ts` with TypeChain, optimizer (1M runs), shanghai EVM target
  - `tsconfig.json` for TypeScript compilation
  - Config files: `.env.example`, `.prettierrc`, `.eslintrc.cjs`, `.solhint.json`, `.gitignore`
- Created directory structure:
  - `contracts/`: core, interfaces, libraries, errors, router, sy
  - `test/`: market, router, invariants
  - `scripts/` and `tasks/`
- Created placeholder contract and test to verify setup
- Installed all dependencies (resolving ethers v5 compatibility)
- Verified with `yarn compile` - Successfully compiled 1 contract, generated TypeChain types
- Verified with `yarn test` - All 3 tests passing

**Time to completion:** ~1 hour
**Key decisions:**
- Using ethers v5 (not v6) for compatibility with existing tooling
- Using @nomiclabs packages instead of @nomicfoundation for ethers v5 compatibility
- Solidity 0.8.23 (matches Pendle's later contracts)
- High optimizer runs (1M) for production-ready gas optimization

#### README.md Created ✅ (2025-12-14)

- Created comprehensive README.md (518 lines)
- **Balanced dual-track structure** for developers + auditors
- **High-level conceptual explanations** (no formulas, links to docs/)
- **Three detailed example scenarios:**
  - Scenario A: Underlying outperforms (6% growth)
  - Scenario B: Underlying underperforms (1% growth)
  - Scenario C: Underlying loses value (-2% loss)
- **ASCII architecture diagram** showing 4-layer flow
- **Clear signposting** to technical documentation
- Quick start, installation, and development workflow
- Core security invariants (conceptual, without mathematical proofs)
- Current status tracker and security disclaimers

**Content strategy:**
- Target audience: Balanced (developers + security auditors)
- Detail level: High-level conceptual (formulas in docs/math.md)
- Tone: Professional, educational, accessible
- Structure: "Guided tour" of repository (What? Why? How? Where to start? Where to learn more?)
- Length: 518 lines (within 400-600 target range ✓)

**Key sections:**
1. Overview (what/why/innovation)
2. How It Works (3-phase narrative)
3. Example Scenarios (3 concrete outcomes)
4. Key Features (6 major capabilities)
5. Architecture (ASCII diagram + separation of concerns)
6. Quick Start (installation, testing, development)
7. Repository Structure (annotated tree)
8. Core Security Invariants (6 MUST-hold properties)
9. Documentation (audience-specific signposting)
10. Status, Security, License, Contributing

---

## Architecture Decisions

### Core Invariants (MUST HOLD)
**Pre-maturity:**
- Fixed ratio minting: `mint(srSY):mint(jrSY) == w_s:w_j`
- Recomposition: Holding both in correct proportion ≡ holding underlying SY
- Ratio-based redemption: Requires exact configured ratio

**Post-maturity:**
- Finalization sets immutable redemption rates: `srRedeemRate` and `jrRedeemRate`
- Unilateral redemption: srSY and jrSY redeem independently
- Senior protection: jrSY is residual, may be wiped to satisfy senior

### Rounding Rules
- Senior never overpaid (round DOWN for senior redemption rate calculation)
- Junior residual (round DOWN for junior redemption rate)
- Total redeemed never exceeds SY balance

---

## Dependencies

### From Pendle (patterns to reuse):
- ✅ Common math / fixed point helpers
- ✅ ERC20 helper patterns
- ✅ Error + revert style
- ✅ Router structuring patterns
- ✅ Deployment script conventions

### NOT copying from Pendle:
- ❌ PT/YT tokenization index logic
- ❌ Pendle AMM market math/curves
- ❌ Reward distribution logic tied to YT

---

## Issues / Blockers

None currently.

---

## Next Steps

1. Complete Task 0.1 (Hardhat bootstrap)
2. Reference Pendle repo for library patterns (Task 1.1)
3. Write spec docs before implementing contracts (Task 2.1-2.3)
