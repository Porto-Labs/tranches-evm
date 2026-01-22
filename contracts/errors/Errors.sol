// SPDX-License-Identifier: MIT
pragma solidity ^0.8.23;

/**
 * @title Errors
 * @notice Centralized error definitions for Porto Tranches
 */
library Errors {
    // ============ TrancheMarket Errors ============

    /// @notice Thrown when attempting to tokenize or redeem pre-maturity after expiry
    error TrancheMarketExpired();

    /// @notice Thrown when attempting to finalize or redeem post-maturity before expiry
    error TrancheMarketNotExpired();

    /// @notice Thrown when attempting post-maturity redemption before finalize() is called
    error TrancheMarketNotFinalized();

    /// @notice Thrown when attempting to finalize a market that's already been finalized
    error TrancheMarketAlreadyFinalized();

    /// @notice Thrown when srIn/jrIn ratio doesn't match the market's fixed ratio
    error TrancheRatioMismatch();

    /// @notice Thrown when attempting to tokenize or redeem with zero amount
    error TrancheZeroAmount();

    /// @notice Thrown when non-admin attempts to call admin-only functions
    error OnlyAdmin();

    /// @notice Thrown when admin provides redemption rates that exceed available UA balance
    error TotalRedemptionExceedsBalance();

    // ============ TrancheToken Errors ============

    /// @notice Thrown when non-market address attempts to mint or burn
    error OnlyMarket();

    // ============ Factory Errors ============

    /// @notice Thrown when attempting to create a market that already exists
    error TrancheMarketAlreadyExists();

    /// @notice Thrown when expiry is in the past or invalid
    error TrancheInvalidExpiry();

    /// @notice Thrown when weight sum doesn't equal ONE or weights are zero
    error TrancheInvalidWeights();

    // ============ General Errors ============

    /// @notice Thrown when a zero address is provided where not allowed
    error ZeroAddress();

    /// @notice Thrown when user has insufficient balance for operation
    error InsufficientBalance();
}
