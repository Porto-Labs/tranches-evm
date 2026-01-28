// SPDX-License-Identifier: MIT
pragma solidity ^0.8.23;

// No imports needed - using address types for maximum simplicity

/**
 * @title ITrancheMarket
 * @notice Interface for the Porto Tranching mechanism (UA → srUA + jrUA) - V1
 * @dev Defines the complete lifecycle: tokenize, redeem pre-maturity, finalize (admin-controlled), redeem post-maturity
 */
interface ITrancheMarket {
    // ============ Events ============

    /**
     * @notice Emitted when UA is divided into tranches
     * @param caller Address that called tranche
     * @param receiver Address receiving the tranche tokens
     * @param uaIn Amount of UA locked
     * @param srOut Amount of senior tokens minted
     * @param jrOut Amount of junior tokens minted
     */
    event Tranche(address indexed caller, address indexed receiver, uint256 uaIn, uint256 srOut, uint256 jrOut);

    /**
     * @notice Emitted when tranches are recombined into UA before maturity
     * @param caller Address that called recombine
     * @param receiver Address receiving the UA
     * @param srIn Amount of senior tokens burned
     * @param jrIn Amount of junior tokens burned
     * @param uaOut Amount of UA returned
     */
    event Recombine(address indexed caller, address indexed receiver, uint256 srIn, uint256 jrIn, uint256 uaOut);

    /**
     * @notice Emitted when the market is finalized with oracle-calculated rates
     * @param oraclePrice Price from Chainlink oracle at finalization
     * @param referencePrice Reference price provided by admin for deviation check
     * @param srRateUA Senior redemption rate (UA per srUA)
     * @param jrRateUA Junior redemption rate (UA per jrUA)
     */
    event Finalize(uint256 oraclePrice, uint256 referencePrice, uint256 srRateUA, uint256 jrRateUA);

    /**
     * @notice Emitted when senior tokens are redeemed post-maturity
     * @param caller Address that called redeemSenior
     * @param receiver Address receiving the UA
     * @param srIn Amount of senior tokens burned
     * @param uaOut Amount of UA returned
     */
    event RedeemSenior(address indexed caller, address indexed receiver, uint256 srIn, uint256 uaOut);

    /**
     * @notice Emitted when junior tokens are redeemed post-maturity
     * @param caller Address that called redeemJunior
     * @param receiver Address receiving the UA
     * @param jrIn Amount of junior tokens burned
     * @param uaOut Amount of UA returned
     */
    event RedeemJunior(address indexed caller, address indexed receiver, uint256 jrIn, uint256 uaOut);

    /**
     * @notice Emitted when the admin address is changed
     * @param newAdmin The new admin address
     */
    event AdminChanged(address indexed newAdmin);

    /**
     * @notice Emitted when the initial price is set during market creation
     * @param price Initial UA price from oracle (1e18 precision)
     */
    event InitialPriceSet(uint256 price);

    // ============ Core Functions ============

    /**
     * @notice Divide UA into srUA + jrUA at fixed ratio (pre-maturity only)
     * @dev Transfers uaIn from caller, mints tranches to receiver
     *      Ratio: srOut = uaIn * seniorRatio, jrOut = uaIn * juniorRatio
     * @param uaIn Amount of UA to lock
     * @param receiver Address to receive tranche tokens
     * @return srOut Amount of senior tokens minted
     * @return jrOut Amount of junior tokens minted
     */
    function tranche(uint256 uaIn, address receiver) external returns (uint256 srOut, uint256 jrOut);

    /**
     * @notice Recombine tranches into UA by burning both in correct ratio (pre-maturity only)
     * @dev Burns srIn and jrIn from caller, transfers UA to receiver
     *      Requires: srIn / seniorRatio == jrIn / juniorRatio (fixed ratio)
     * @param srIn Amount of senior tokens to burn
     * @param jrIn Amount of junior tokens to burn
     * @param receiver Address to receive UA
     * @return uaOut Amount of UA returned
     */
    function recombine(uint256 srIn, uint256 jrIn, address receiver) external returns (uint256 uaOut);

    /**
     * @notice Finalize redemption rates at maturity using oracle price
     * @dev Admin provides reference price for deviation check, oracle price is fetched on-chain
     *      Contract calculates rates using SettlementRatioModel waterfall logic
     * @param referencePrice Expected price for deviation validation (1e18 precision)
     * @param deviationThreshold Maximum allowed deviation from oracle price (1e18 precision, e.g., 0.01e18 = 1%)
     */
    function finalize(uint256 referencePrice, uint256 deviationThreshold) external;

    /**
     * @notice Redeem senior tokens for UA (post-maturity only)
     * @dev Burns srIn from caller, transfers UA to receiver
     *      Returns: srIn * srRateUA (fixed rate set at finalization)
     * @param srIn Amount of senior tokens to burn
     * @param receiver Address to receive UA
     * @return uaOut Amount of UA returned
     */
    function redeemSenior(uint256 srIn, address receiver) external returns (uint256 uaOut);

    /**
     * @notice Redeem junior tokens for UA (post-maturity only)
     * @dev Burns jrIn from caller, transfers UA to receiver
     *      Returns: jrIn * jrRateUA (fixed rate set at finalization)
     *      Note: jrRateUA may be 0 if underlying underperformed
     * @param jrIn Amount of junior tokens to burn
     * @param receiver Address to receive UA
     * @return uaOut Amount of UA returned
     */
    function redeemJunior(uint256 jrIn, address receiver) external returns (uint256 uaOut);

    /**
     * @notice Change the admin address
     * @dev Only callable by current admin
     * @param _newAdmin The new admin address
     */
    function setAdmin(address _newAdmin) external;

    // ============ View Functions ============

    /// @notice Returns the Underlying Asset token address
    function ua() external view returns (address);

    /// @notice Returns the senior tranche token address
    function srToken() external view returns (address);

    /// @notice Returns the junior tranche token address
    function jrToken() external view returns (address);

    /// @notice Returns the maturity timestamp
    function expiry() external view returns (uint256);

    /// @notice Returns whether the market has been finalized
    function finalized() external view returns (bool);

    /// @notice Returns the senior tranche ratio (1e18 precision, e.g., 0.8e18 for 80%)
    function seniorRatio() external view returns (uint256);

    /// @notice Returns the junior tranche ratio (1e18 precision, e.g., 0.2e18 for 20%)
    function juniorRatio() external view returns (uint256);

    /// @notice Returns the senior redemption rate (UA per srUA, set at finalization)
    function srRateUA() external view returns (uint256);

    /// @notice Returns the junior redemption rate (UA per jrUA, set at finalization)
    function jrRateUA() external view returns (uint256);

    /// @notice Returns the admin address
    function admin() external view returns (address);

    /// @notice Returns the Chainlink price feed address
    function priceFeed() external view returns (address);

    /// @notice Returns the initial UA price at market creation (1e18 precision)
    function initialPrice() external view returns (uint256);

    /// @notice Returns the senior floor yield (1e18 precision, e.g., 0.0033e18 = 0.33%)
    function seniorFloor() external view returns (uint256);

    /// @notice Returns the senior target yield (1e18 precision, e.g., 0.005e18 = 0.5%)
    function seniorTarget() external view returns (uint256);

    /**
     * @notice Preview settlement rates based on current oracle price
     * @dev Read-only function that calculates what rates would be at finalization
     *      Uses current oracle price and SettlementRatioModel waterfall logic
     * @return srRateUA Projected senior redemption rate (UA per srUA)
     * @return jrRateUA Projected junior redemption rate (UA per jrUA)
     * @return oraclePrice Current price from oracle (1e18 precision)
     */
    function previewSettlement() external view returns (uint256 srRateUA, uint256 jrRateUA, uint256 oraclePrice);

    /// @notice Returns swap parameters for Router in a single call
    /// @return uaAddress Underlying Asset token address
    /// @return srAddress Senior tranche token address
    /// @return jrAddress Junior tranche token address
    function getSwapParameters()
        external
        view
        returns (address uaAddress, address srAddress, address jrAddress);

    /**
     * @notice Preview the amounts of senior and junior tokens that would be minted for a given UA input
     * @param uaIn Amount of UA to tranche
     * @return srOut Amount of senior tokens that would be minted
     * @return jrOut Amount of junior tokens that would be minted
     */
    function previewTranche(uint256 uaIn) external view returns (uint256 srOut, uint256 jrOut);
}
