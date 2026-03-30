# Open Questions

## TrancheMarket

- Should `finalize()` store the oracle price in a storage variable (e.g. `finalPrice = oraclePrice`)? Currently the finalization price is only emitted as an event and not queryable on-chain.

- What should `previewSettlement()` return when the market is already finalized? Should it return the stored `srRateUA`/`jrRateUA` instead of recomputing?

- Should `previewTranche()` be removed? It was added for the Uniswap flashloan path in the Router. Since moving to Morpho, it is no longer used by any production contract — only referenced in one test.

- Do we want `redeemBothTokens` function?

- Do you need to change/update something if Morpho introduces a fee for taking a flash loan?
