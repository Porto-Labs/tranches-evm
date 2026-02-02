# Router Gas Usage

Gas measurements from Sepolia fork tests with 0.05% fee tier pool.

---

## buySenior

| Operation          | Gas Used |
| ------------------ | -------- |
| buySenior (swap)   | ~155,438 |
| + ERC20 approve    | ~30,000  |
| **Total with approve** | **~185,500** |

### Test Conditions

- Pool: PRIME/srPRIME (0.05% fee tier)
- Pool liquidity: 3,625,000 PRIME : 3,625,000 srPRIME
- Swap amount: 100,000 PRIME
- Output: ~97,268 srPRIME (~2.73% loss from fee + slippage)

---

## sellSenior

| Operation          | Gas Used |
| ------------------ | -------- |
| sellSenior (swap)  | ~168,600 |
| + ERC20 approve    | ~30,000  |
| **Total with approve** | **~198,600** |

### Test Conditions

- Pool: PRIME/srPRIME (0.05% fee tier)
- Pool liquidity: 3,625,000 PRIME : 3,625,000 srPRIME
- Swap amount: 10,000 srPRIME
- Output: ~9,967 PRIME (~0.33% loss from fee + slippage)

---

## buyJunior

| Operation           | Gas Used |
| ------------------- | -------- |
| buyJunior (flash)   | ~380,978 |
| + ERC20 approve     | ~30,000  |
| **Total with approve** | **~411,000** |

### Test Conditions

- Pool: PRIME/srPRIME (0.05% fee tier)
- Pool liquidity: 3,625,000 PRIME : 3,625,000 srPRIME
- Flash loan: Morpho PRIME/USDC market (30M PRIME liquidity)
- Input: 10,000 PRIME
- Output: ~5,500 jrPRIME (~2x leverage on junior tranche)

---

## sellJunior

| Operation           | Gas Used |
| ------------------- | -------- |
| sellJunior (flash)  | TBD      |
| + ERC20 approve     | ~30,000  |
| **Total with approve** | **TBD** |

---

## swapJuniorToSenior

| Operation               | Gas Used |
| ----------------------- | -------- |
| swapJuniorToSenior      | TBD      |
| + ERC20 approve         | ~30,000  |
| **Total with approve**  | **TBD** |

---

## swapSeniorToJunior

| Operation               | Gas Used |
| ----------------------- | -------- |
| swapSeniorToJunior      | TBD      |
| + ERC20 approve         | ~30,000  |
| **Total with approve**  | **TBD** |
