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
| sellJunior (flash)  | ~338,167 |
| + ERC20 approve     | ~30,000  |
| **Total with approve** | **~368,000** |

### Test Conditions

- Pool: PRIME/srPRIME (0.05% fee tier)
- Pool ratio: ~1.05:1 (PRIME/srPRIME) after price adjustment
- Flash loan: Morpho PRIME/USDC market (30M PRIME liquidity)
- Input: 5,500 jrPRIME
- Output: ~4,701 PRIME

### Internal Variables

| Variable               | Value         |
| ---------------------- | ------------- |
| jrIn                   | 5,500         |
| uaBorrowed             | 20,000 PRIME  |
| srNeeded               | 14,500 srPRIME|
| uaSpentOnSwap          | 15,298 PRIME  |
| uaFromRecombine        | 20,000 PRIME  |
| totalUa                | 24,701 PRIME  |
| uaBorrowed - uaSpentOnSwap | 4,701 PRIME |
| uaToUser               | 4,701 PRIME   |

---

## swapJuniorToSenior

| Operation               | Gas Used |
| ----------------------- | -------- |
| swapJuniorToSenior      | ~358,563 |
| + ERC20 approve         | ~30,000  |
| **Total with approve**  | **~389,000** |

### Test Conditions

- Pool: PRIME/srPRIME (0.05% fee tier)
- Pool ratio: ~1.05:1 (PRIME/srPRIME) after price adjustment
- Flash loan: Morpho PRIME/USDC market (30M PRIME liquidity)
- Input: 11,000 jrPRIME
- Output: ~8,661 srPRIME

### Internal Variables

| Variable                   | Value          |
| -------------------------- | -------------- |
| jrIn                       | 11,000         |
| uaBorrowed                 | 40,000 PRIME   |
| srNeeded                   | 29,000 srPRIME |
| uaSpentOnSwap              | 30,724 PRIME   |
| uaFromRecombine            | 40,000 PRIME   |
| totalUa                    | 49,275 PRIME   |
| uaBorrowed - uaSpentOnSwap | 9,275 PRIME    |
| remainingUa                | 9,275 PRIME    |
| srToUser                   | 8,661 srPRIME  |

---

## swapSeniorToJunior

| Operation               | Gas Used |
| ----------------------- | -------- |
| swapSeniorToJunior      | ~336,844 |
| + ERC20 approve         | ~30,000  |
| **Total with approve**  | **~367,000** |

### Test Conditions

- Pool: PRIME/srPRIME (0.05% fee tier)
- Pool ratio: ~1.05:1 (PRIME/srPRIME) after price adjustment
- Flash loan: Morpho PRIME/USDC market (30M PRIME liquidity)
- Input: 7,250 srPRIME
- Output: 2,750 jrPRIME

### Internal Variables

| Variable               | Value           |
| ---------------------- | --------------- |
| srIn                   | 7,250           |
| uaBorrowed             | 10,000 PRIME    |
| srMinted               | 7,250 srPRIME   |
| jrMinted               | 2,750 jrPRIME   |
| totalSr                | 14,500 srPRIME  |
| srSpentOnSwap          | 9,552 srPRIME   |
| srDust (unused)        | 4,947 srPRIME   |
| jrToUser               | 2,750 jrPRIME   |
