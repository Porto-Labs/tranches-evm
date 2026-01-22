# Porto Tranches

Fixed-rate senior/junior tranching mechanism for yield-bearing assets.

[![License: BUSL-1.1](https://img.shields.io/badge/License-BUSL--1.1-blue.svg)](https://spdx.org/licenses/BUSL-1.1.html)
[![Solidity](https://img.shields.io/badge/Solidity-0.8.23-blue)](https://soliditylang.org/)
[![Hardhat](https://img.shields.io/badge/Built%20with-Hardhat-orange)](https://hardhat.org/)

**Status:** Pre-audit - Not for production use

---

## Overview

Porto Tranches splits yield-bearing assets (UA - Underlying Asset) into senior (srUA) and junior (jrUA) tranches at a fixed ratio. Senior receives a fixed target return, junior receives the residual. At maturity, the contract finalizes redemption rates on-chain, enabling unilateral redemption.

For detailed mechanism specification, see our docs.

---

## Installation

```bash
# Clone repository
git clone https://github.com/Porto-Labs/tranches-evm
cd tranches-evm

# Install dependencies
yarn install

# Compile contracts
yarn compile
```

---

## Testing

```bash
# Run all tests
yarn test

# Run specific test file
yarn test test/TrancheMarket.test.ts

# Run with gas reporting
REPORT_GAS=true yarn test

# Run with coverage
yarn coverage
```

---

## Development

### Compile Contracts

```bash
yarn compile
```

### Clean Build Artifacts

```bash
yarn clean
```

### Lint Solidity Code

```bash
yarn lint
```

### Format Code

```bash
yarn format
```

---

## Project Structure

```
contracts/          # Solidity contracts
  core/            # TrancheMarket, TrancheToken
  interfaces/      # ITrancheMarket
  libraries/       # Math and helper libraries
  errors/          # Error definitions

test/              # Test files
docs/              # Technical documentation
```

---

## Security

**This code is pre-audit and NOT ready for production use.**

For security disclosures, contact: security@porto.finance

---

## License

BUSL License - See [LICENSE](./LICENSE)
