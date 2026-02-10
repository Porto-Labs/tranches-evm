// SPDX-License-Identifier: MIT
pragma solidity ^0.8.23;

/**
 * @title IRouter
 * @notice Interface for the Router contract for buying and selling tranche tokens via Uniswap V3
 * @dev Pool structure: UA/srToken pair on Uniswap V3
 */
interface IRouter {
    // ============ Events ============

    /**
     * @notice Emitted when senior tokens are bought
     * @param buyer Address that bought the tokens
     * @param uaIn Amount of UA deposited
     * @param srOut Amount of senior tokens received
     */
    event BuySenior(address indexed buyer, uint256 uaIn, uint256 srOut);

    /**
     * @notice Emitted when senior tokens are sold
     * @param seller Address that sold the tokens
     * @param srIn Amount of senior tokens sold
     * @param uaOut Amount of UA received
     */
    event SellSenior(address indexed seller, uint256 srIn, uint256 uaOut);

    /**
     * @notice Emitted when junior tokens are sold via flash swap
     * @param seller Address that sold the tokens
     * @param jrIn Amount of junior tokens sold
     * @param uaOut Amount of UA received
     */
    event SellJunior(address indexed seller, uint256 jrIn, uint256 uaOut);

    /**
     * @notice Emitted when junior tokens are bought
     * @param buyer Address that bought the tokens
     * @param uaIn Amount of UA deposited
     * @param jrOut Amount of junior tokens received
     * @param uaDust Amount of leftover UA returned to buyer
     */
    event BuyJunior(address indexed buyer, uint256 uaIn, uint256 jrOut, uint256 uaDust);

    /**
     * @notice Emitted when junior tokens are swapped for senior tokens
     * @param user Address that performed the swap
     * @param jrIn Amount of junior tokens swapped
     * @param srOut Amount of senior tokens received
     */
    event SwapJuniorToSenior(address indexed user, uint256 jrIn, uint256 srOut);

    /**
     * @notice Emitted when senior tokens are swapped for junior tokens
     * @param user Address that performed the swap
     * @param srIn Amount of senior tokens swapped
     * @param jrOut Amount of junior tokens received
     * @param uaDust Amount of leftover UA returned to user
     */
    event SwapSeniorToJunior(address indexed user, uint256 srIn, uint256 jrOut, uint256 uaDust);

    // ============ Errors ============

    /// @notice Thrown when transaction deadline has passed
    error RouterDeadlineExpired();

    /// @notice Thrown when callback caller is not Morpho
    error RouterUnauthorizedCallback();

    /// @notice Thrown when output is less than minimum required
    error InsufficientOutput();

    /// @notice Thrown when a zero address is provided where not allowed
    error ZeroAddress();

    /// @notice Thrown when input amount is zero
    error ZeroAmount();

    // ============ Core Functions ============

    /**
     * @notice Buy senior tranche tokens by depositing UA
     * @dev Strategy: Swap UA for srToken on Uniswap V3 pool
     * @param market TrancheMarket contract address
     * @param uaIn Amount of UA to deposit
     * @param minSrOut Minimum amount of senior tokens to receive (slippage protection)
     * @param deadline Transaction deadline timestamp
     * @return srOut Amount of senior tokens received
     */
    function buySenior(address market, uint256 uaIn, uint256 minSrOut, uint256 deadline)
        external
        returns (uint256 srOut);

    /**
     * @notice Sell senior tranche tokens for UA
     * @dev Strategy: Swap srToken for UA on Uniswap V3 pool
     * @param market TrancheMarket contract address
     * @param srIn Amount of senior tokens to sell
     * @param minUaOut Minimum amount of UA to receive (slippage protection)
     * @param deadline Transaction deadline timestamp
     * @return uaOut Amount of UA received
     */
    function sellSenior(address market, uint256 srIn, uint256 minUaOut, uint256 deadline)
        external
        returns (uint256 uaOut);

    /**
     * @notice Buy junior tranche tokens by depositing UA
     * @dev Flash loan strategy:
     *      1. Transfer UA from user
     *      2. Borrow additional UA from Morpho flash loan
     *      3. In callback: Tranche (user UA + borrowed UA) into Senior + Junior
     *      4. In callback: Swap Senior tokens for UA to repay flash loan
     *      5. In callback: Send Junior tokens to user
     * @param market TrancheMarket contract address
     * @param uaIn Amount of UA to deposit
     * @param uaToBorrow Amount of UA to borrow from flash loan (calculated off-chain)
     * @param minJrOut Minimum amount of junior tokens to receive (slippage protection)
     * @param deadline Transaction deadline timestamp
     */
    function buyJunior(address market, uint256 uaIn, uint256 uaToBorrow, uint256 minJrOut, uint256 deadline) external;

    /**
     * @notice Sell junior tranche tokens for UA using flash loan
     * @dev Flash loan strategy:
     *      1. Transfer junior tokens from user
     *      2. Borrow UA from Morpho flash loan
     *      3. In callback: Swap UA for SR on Uniswap
     *      4. In callback: Redeem SR + JR for UA via TrancheMarket
     *      5. In callback: Repay borrowed UA to Morpho
     *      6. In callback: Send remaining UA profit to user
     * @param market TrancheMarket contract address
     * @param jrIn Amount of junior tokens to sell
     * @param uaToBorrow Amount of UA to borrow from flash loan (calculated off-chain)
     * @param minUaOut Minimum amount of UA to receive (slippage protection)
     * @param deadline Transaction deadline timestamp
     */
    function sellJunior(address market, uint256 jrIn, uint256 uaToBorrow, uint256 minUaOut, uint256 deadline) external;

    /**
     * @notice Swap junior tranche tokens for senior tranche tokens
     * @dev Flash loan strategy:
     *      1. Transfer junior tokens from user
     *      2. Borrow UA from Morpho flash loan
     *      3. In callback: Swap UA for SR on Uniswap
     *      4. In callback: Redeem SR + JR for UA via TrancheMarket
     *      5. In callback: Repay borrowed UA to Morpho
     *      6. In callback: Swap remaining UA for SR
     *      7. In callback: Send SR to user
     * @param market TrancheMarket contract address
     * @param jrIn Amount of junior tokens to swap
     * @param uaToBorrow Amount of UA to borrow from flash loan (calculated off-chain)
     * @param minSrOut Minimum amount of senior tokens to receive (slippage protection)
     * @param deadline Transaction deadline timestamp
     */
    function swapJuniorToSenior(address market, uint256 jrIn, uint256 uaToBorrow, uint256 minSrOut, uint256 deadline)
        external;

    /**
     * @notice Swap senior tranche tokens for junior tranche tokens
     * @dev Flash loan strategy:
     *      1. Transfer senior tokens from user
     *      2. Borrow UA from Morpho flash loan
     *      3. In callback: Tranche borrowed UA into SR + JR
     *      4. In callback: Sell (user SR + minted SR) for UA to repay flash loan
     *      5. In callback: Send minted JR to user
     * @param market TrancheMarket contract address
     * @param srIn Amount of senior tokens to swap
     * @param uaToBorrow Amount of UA to borrow from flash loan (calculated off-chain)
     * @param minJrOut Minimum amount of junior tokens to receive (slippage protection)
     * @param deadline Transaction deadline timestamp
     */
    function swapSeniorToJunior(address market, uint256 srIn, uint256 uaToBorrow, uint256 minJrOut, uint256 deadline)
        external;

    // ============ View Functions ============

    /**
     * @notice Calculate the amount of senior tokens needed to match junior tokens for recombination
     * @param jrAmount Amount of junior tokens
     * @param market TrancheMarket contract address
     * @return srNeeded Amount of senior tokens needed
     */
    function calculateSeniorNeeded(uint256 jrAmount, address market) external view returns (uint256 srNeeded);
}
