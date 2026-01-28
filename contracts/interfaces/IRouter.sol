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

    // ============ Errors ============

    /// @notice Thrown when transaction deadline has passed
    error RouterDeadlineExpired();

    /// @notice Thrown when callback caller is not the Uniswap pool
    error RouterUnauthorizedCallback();

    /// @notice Thrown when output is less than minimum required
    error InsufficientOutput();

    // ============ Core Functions ============

    /**
     * @notice Buy senior tranche tokens by depositing UA
     * @dev Strategy: Swap UA for srToken on Uniswap V3 pool
     * @param uaIn Amount of UA to deposit
     * @param minSrOut Minimum amount of senior tokens to receive (slippage protection)
     * @param deadline Transaction deadline timestamp
     * @return srOut Amount of senior tokens received
     */
    function buySenior(uint256 uaIn, uint256 minSrOut, uint256 deadline) external returns (uint256 srOut);

    /**
     * @notice Sell senior tranche tokens for UA
     * @dev Strategy: Swap srToken for UA on Uniswap V3 pool
     * @param srIn Amount of senior tokens to sell
     * @param minUaOut Minimum amount of UA to receive (slippage protection)
     * @param deadline Transaction deadline timestamp
     * @return uaOut Amount of UA received
     */
    function sellSenior(uint256 srIn, uint256 minUaOut, uint256 deadline) external returns (uint256 uaOut);

    /**
     * @notice Sell junior tranche tokens for UA using flash swap
     * @dev Flash swap strategy:
     *      1. Transfer junior tokens from user
     *      2. Initiate flash swap to borrow SR tokens from Uniswap pool
     *      3. In callback: Redeem SR + JR for UA via TrancheMarket
     *      4. In callback: Repay pool with the UA owed
     *      5. In callback: Send remaining UA profit to user
     * @param jrIn Amount of junior tokens to sell
     * @param minUaOut Minimum amount of UA to receive (slippage protection)
     * @param deadline Transaction deadline timestamp
     */
    function sellJunior(uint256 jrIn, uint256 minUaOut, uint256 deadline) external;

    // ============ View Functions ============

    /**
     * @notice Calculate the amount of senior tokens needed to match junior tokens for recombination
     * @param jrAmount Amount of junior tokens
     * @return srNeeded Amount of senior tokens needed
     */
    function calculateSeniorNeeded(uint256 jrAmount) external view returns (uint256 srNeeded);
}
