## Liquidity & Secondary Markets

Porto Protocol employs a unified liquidity model that concentrates secondary market activity into a single primary pool per tranche series. This design avoids liquidity fragmentation and enables seamless entry and exit for both Senior (srUA) and Junior (jrUA) positions via a "Single-Pool" Atomic Router.

The router adapts the _Flash Swap_ pattern used in Pendle for PT/YT yield strips to the Senior/Junior structure. While the pool only holds the Senior Tranche (SrUA) and a counterpart, Junior liquidity is synthesized atomically by combining pool swaps with the Tranching Contract's mint/redeem functions.

To maximize capital efficiency, the liquidity architecture is split into two distinct models based on the volatility of the Underlying Asset.

### 8.1 Model A: Stable Underlying Assets

For stable-value assets, liquidity is established via a **SrUA / UA** Automated Market Maker (AMM).

#### Architecture

- **Structure:** `[ Senior Tranche (srUA) + Underlying Asset (UA) ]`
- **Rationale:** Since the Senior Tranche is principal-protected and yield-bearing, its value is highly correlated with the stable Underlying Asset. Pairing them creates a capital-efficient pool with minimal Impermanent Loss (IL).
- **Implementation:** Uniswap V3 pool with configurable fee tier

#### Entry and Exit Pathways

**1. Senior Position (SrUA)**

- **Entry (`buySenior`):** User swaps UA → **SrUA** directly via Uniswap V3 SwapRouter.
- **Exit (`sellSenior`):** User swaps **SrUA** → UA directly via Uniswap V3 SwapRouter.

**2. Junior Position (JrUA)**

- **Entry (`buyJunior`) - Flash Swap Strategy:**
  1. **Transfer:** User's UA is transferred to the Router.
  2. **Flash Swap:** Router initiates Uniswap V3 flash swap to borrow UA from the pool (negative `amountSpecified`).
  3. **Tranche:** In callback: Total UA (user's + borrowed) is tranched into SR + JR via TrancheMarket.
  4. **Repay:** In callback: Minted SR tokens are sold for UA to repay the flash loan.
  5. **Deliver:** In callback: Minted JR tokens are sent to the user.

- **Exit (`sellJunior`) - Flash Swap Strategy:**
  1. **Transfer:** User's JR tokens are transferred to the Router.
  2. **Flash Swap:** Router initiates Uniswap V3 flash swap to borrow SR from the pool.
  3. **Recombine:** In callback: Borrowed SR + user's JR are recombined into UA via TrancheMarket.
  4. **Repay:** In callback: A portion of the redeemed UA is used to buy SR (via exactOutputSingle) to repay the flash loan.
  5. **Deliver:** In callback: Remaining UA profit is sent to the user.

**3. Direct Tranche Swaps**

- **JR → SR (`swapJuniorToSenior`):**
  1. **Flash Swap:** Borrow SR from pool.
  2. **Recombine:** SR + JR → UA.
  3. **Swap:** All UA → SR (via exactInputSingle).
  4. **Repay:** Return borrowed SR to pool.
  5. **Deliver:** Remaining SR profit to user.

- **SR → JR (`swapSeniorToJunior`):**
  1. **Flash Swap:** Borrow UA from pool.
  2. **Tranche:** UA → SR + JR.
  3. **Swap:** User's SR + minted SR → UA (via exactOutputSingle) to repay loan.
  4. **Deliver:** Minted JR to user.

#### Pricing Logic (Model A)

Since both assets are denominated in the same unit (UA), pricing is purely internal to the AMM.

1. **SrUA Price ($P_{sr}$):** Determined by the pool exchange rate (e.g., 1 srUA = 0.98 UA).
2. **JrUA Price ($P_{jr}$):** Derived as the residual of the unit:
   $$P_{jr} = (1 + R) - (P_{sr} \times R)$$
   _(Where $R$ is the Senior:Junior Ratio, e.g., 4:1, and prices are in UA terms)._

### 8.2 Model B: Volatile Underlying Assets

For volatile assets, where the Senior Tranche acts as a stable-value claim against volatile collateral, liquidity is established via a **SrUA / Stablecoin** pool.

#### Architecture

- **Structure:** `[ Senior Tranche (srUA) + Stablecoin (USD) ]`
- **Rationale:** The Senior Tranche behaves like a stable instrument (a USD-denominated debt claim). Pairing it with the volatile UA (e.g., SrwstETH/wstETH) would expose Liquidity Providers to massive Impermanent Loss. Pairing it with a Stablecoin (e.g., SrwstETH/USDC) isolates the yield/credit risk from the asset's price volatility.
- **Status:** Not yet implemented in Router - requires external aggregator integration for UA ↔ USD swaps.

#### Entry and Exit Pathways

**1. Senior Position (SrUA)**

- **Entry:** User swaps USD → **SrUA** directly in the LP.
- **Exit:** User swaps **SrUA** → USD directly in the LP.

**2. Junior Position (JrUA)**

- **Entry:**
  1. **Tranche:** User deposits UA (e.g., wstETH) to mint `SrUA + JrUA`.
  2. **Sell Senior:** Protocol atomically sells `SrUA` into the LP for **USD**.
  3. **Swap:** Protocol swaps the **USD** for **UA** (via external aggregator like 1inch/CowSwap).
  4. **Offset:** The acquired UA is returned to the user, offsetting the initial deposit cost.
- **Exit:**
  1. **Flash Swap:** Protocol flash-borrows `SrUA` from the LP (incurring a debt in `USD`).
  2. **Recompose:** The borrowed `SrUA` is combined with the user's `JrUA` and atomically burned to redeem `UA`.
  3. **Repay:** A portion of the redeemed `UA` is sold for `USD` (via aggregator) to repay the flash swap debt. The user keeps the remaining `UA`.

#### Pricing Logic (Model B)

Pricing requires an external Oracle for the UA because the pool trades against USD, but the JrUA represents a residual claim on the volatile UA.

- **SrUA Price (Pₛᵣᵘˢᵈ):** Determined by the LP (e.g., 1 srETH = $2000 USDC).
- **UA Price (Pᵤₐᵘˢᵈ):** Determined by Oracle (e.g., 1 ETH = $2500 USDC).
- **JrUA Price (Pⱼᵣᵘˢᵈ):** Derived as the difference between the Total Collateral Value and the Senior Liability Value:
  Pⱼᵣᵘˢᵈ = [ Pᵤₐᵘˢᵈ × (1 + R) ] - [ Pₛᵣᵘˢᵈ × R ]
