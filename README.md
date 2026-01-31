# Porto Tranches

Fixed-rate senior/junior tranching mechanism for yield-bearing assets.

[![License: BUSL-1.1](https://img.shields.io/badge/License-BUSL--1.1-blue.svg)](https://spdx.org/licenses/BUSL-1.1.html)
[![Solidity](https://img.shields.io/badge/Solidity-0.8.28-blue)](https://soliditylang.org/)
[![Foundry](https://img.shields.io/badge/Built%20with-Foundry-orange)](https://getfoundry.sh/)

**Status:** Pre-audit - Not for production use

---

## Overview

Porto Tranches splits yield-bearing assets (UA - Underlying Asset) into senior (srUA) and junior (jrUA) tranches at a fixed ratio. Senior receives a fixed target return, junior receives the residual. At maturity, the contract finalizes redemption rates on-chain, enabling unilateral redemption.

For detailed mechanism specification, see [docs/](./docs/).

---

## Prerequisites

- [Foundry](https://getfoundry.sh/) - Install via:
  ```bash
  curl -L https://foundry.paradigm.xyz | bash
  foundryup
  ```
- [Node.js](https://nodejs.org/) (v18+) and Yarn

---

## Installation

```bash
# Clone repository
git clone https://github.com/Porto-Labs/tranches-evm
cd tranches-evm

# Install npm dependencies (OpenZeppelin, Chainlink, Uniswap)
yarn install

# Install Foundry dependencies
forge install

# Build contracts
forge build
```

---

## Testing

```bash
# Run all tests
forge test

# Run with verbosity (show logs)
forge test -vvv

# Run specific test file
forge test --match-path test/tranche/TrancheMarket.t.sol

# Run specific test function
forge test --match-test test_Finalize_WithValidReferencePrice

# Run with gas reporting
forge test --gas-report

# Run coverage
forge coverage
```

---

## Development

### Build Contracts

```bash
forge build
```

### Clean Build Artifacts

```bash
forge clean
```

### Format Code

```bash
forge fmt
```

### Lint Solidity

```bash
yarn lint
```

---

## Project Structure

```
src/                    # Solidity contracts
  core/                 # TrancheMarket, TrancheToken, Router
  interfaces/           # ITrancheMarket, IRouter
  libraries/            # PortoMath, SettlementRatioModel
  errors/               # Error definitions

test/                   # Foundry tests
  tranche/              # TrancheMarket tests
  invariants/           # Invariant tests
  mocks/                # Mock contracts

docs/                   # Technical documentation
```

---

## Configuration

Key settings in `foundry.toml`:

| Setting | Value | Description |
|---------|-------|-------------|
| `solc` | 0.8.28 | Solidity compiler version |
| `evm_version` | cancun | EVM version (transient storage support) |
| `optimizer_runs` | 1,000,000 | Optimizer iterations |
| `via_ir` | true | IR-based compilation |

---

## Security

**This code is pre-audit and NOT ready for production use.**

For security disclosures, contact: security@porto.finance

---

## License

BUSL License - See [LICENSE](./LICENSE)
