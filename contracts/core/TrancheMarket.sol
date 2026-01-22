// SPDX-License-Identifier: MIT
pragma solidity ^0.8.23;

import "@openzeppelin/contracts/security/ReentrancyGuard.sol";
import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import "../interfaces/ITrancheMarket.sol";
import "../core/TrancheToken.sol";
import "../errors/Errors.sol";
import "../libraries/math/PortoMath.sol";

/**
 * @title TrancheMarket
 * @notice Core tranching mechanism: UA → srUA (senior) + jrUA (junior)
 * @dev V1 implementation with admin-controlled finalization
 *      Pre-maturity: Fixed ratio minting/redeeming
 *      At maturity: Admin sets redemption rates
 *      Post-maturity: Unilateral redemption at fixed rates
 */
contract TrancheMarket is ITrancheMarket, ReentrancyGuard {
    using SafeERC20 for IERC20;
    using PortoMath for uint256;

    // ============ State Variables ============

    /// @notice Admin address (can call finalize with rates)
    address public admin;

    /// @notice Underlying Asset token (internal - use ua() getter for external access)
    IERC20 internal immutable uaToken;

    /// @notice Senior tranche token (internal - use srToken() getter for external access)
    TrancheToken internal immutable srTokenContract;

    /// @notice Junior tranche token (internal - use jrToken() getter for external access)
    TrancheToken internal immutable jrTokenContract;

    /// @notice Maturity timestamp
    uint256 public immutable expiry;

    /// @notice Senior tranche ratio (WAD precision, e.g., 0.8e18 for 80%)
    uint256 public immutable seniorRatio;

    /// @notice Junior tranche ratio (WAD precision, e.g., 0.2e18 for 20%)
    uint256 public immutable juniorRatio;

    /// @notice Whether the market has been finalized
    bool public finalized;

    /// @notice Senior redemption rate (UA per srUA, set at finalization)
    uint256 public srRateUA;

    /// @notice Junior redemption rate (UA per jrUA, set at finalization)
    uint256 public jrRateUA;

    // ============ Modifiers ============

    /**
     * @notice Restricts function access to admin only
     */
    modifier onlyAdmin() {
        if (msg.sender != admin) revert Errors.OnlyAdmin();
        _;
    }

    // ============ Constructor ============

    /**
     * @notice Creates a new TrancheMarket
     * @param _ua Underlying Asset token address
     * @param _expiry Maturity timestamp
     * @param _seniorRatio Senior tranche ratio (WAD precision, e.g., 0.8e18 for 80%)
     * @param _juniorRatio Junior tranche ratio (WAD precision, e.g., 0.2e18 for 20%)
     * @param _admin Admin address
     * @param _srName Senior token name
     * @param _srSymbol Senior token symbol
     * @param _jrName Junior token name
     * @param _jrSymbol Junior token symbol
     */
    constructor(
        address _ua,
        uint256 _expiry,
        uint256 _seniorRatio,
        uint256 _juniorRatio,
        address _admin,
        string memory _srName,
        string memory _srSymbol,
        string memory _jrName,
        string memory _jrSymbol
    ) {
        // Validation
        if (_ua == address(0) || _admin == address(0)) revert Errors.ZeroAddress();
        if (_expiry <= block.timestamp) revert Errors.TrancheInvalidExpiry();
        if (_seniorRatio + _juniorRatio != 1e18) revert Errors.TrancheInvalidWeights();

        // Set immutables
        uaToken = IERC20(_ua);
        expiry = _expiry;
        seniorRatio = _seniorRatio;
        juniorRatio = _juniorRatio;
        admin = _admin;

        // Deploy TrancheToken contracts
        srTokenContract = new TrancheToken(_srName, _srSymbol, address(this));
        jrTokenContract = new TrancheToken(_jrName, _jrSymbol, address(this));
    }

    // ============ Pre-Maturity Functions ============

    /**
     * @notice Tokenize UA into tranches at fixed ratio (pre-maturity only)
     * @param uaIn Amount of UA to lock
     * @param receiver Address to receive tranche tokens
     * @return srOut Amount of senior tokens minted
     * @return jrOut Amount of junior tokens minted
     */
    function tokenize(uint256 uaIn, address receiver)
        external
        nonReentrant
        returns (uint256 srOut, uint256 jrOut)
    {
        if (block.timestamp >= expiry) revert Errors.TrancheMarketExpired();
        if (uaIn == 0) revert Errors.TrancheZeroAmount();
        if (receiver == address(0)) revert Errors.ZeroAddress();

        // Transfer UA from caller
        IERC20(address(uaToken)).safeTransferFrom(msg.sender, address(this), uaIn);

        // Calculate tranche amounts
        srOut = uaIn.mulDown(seniorRatio);
        jrOut = uaIn.mulDown(juniorRatio);

        // Mint tranches
        srTokenContract.mint(receiver, srOut);
        jrTokenContract.mint(receiver, jrOut);

        emit Tokenize(msg.sender, receiver, uaIn, srOut, jrOut);
    }

    /**
     * @notice Redeem UA by burning both tranches in correct ratio (pre-maturity only)
     * @param srIn Amount of senior tokens to burn
     * @param jrIn Amount of junior tokens to burn
     * @param receiver Address to receive UA
     * @return uaOut Amount of UA returned
     */
    function redeemPreMaturity(uint256 srIn, uint256 jrIn, address receiver)
        external
        nonReentrant
        returns (uint256 uaOut)
    {
        if (block.timestamp >= expiry) revert Errors.TrancheMarketExpired();
        if (srIn == 0 || jrIn == 0) revert Errors.TrancheZeroAmount();
        if (receiver == address(0)) revert Errors.ZeroAddress();

        // Validate ratio: srIn / seniorRatio == jrIn / juniorRatio
        // Equivalent: srIn * juniorRatio == jrIn * seniorRatio
        if (srIn.mulDown(juniorRatio) != jrIn.mulDown(seniorRatio)) revert Errors.TrancheRatioMismatch();

        // Burn tranches from caller
        srTokenContract.burn(msg.sender, srIn);
        jrTokenContract.burn(msg.sender, jrIn);

        // Calculate UA output
        uaOut = srIn.divDown(seniorRatio);  // or jrIn.divDown(juniorRatio) - same result

        // Transfer UA to receiver
        IERC20(address(uaToken)).safeTransfer(receiver, uaOut);

        emit RedeemPreMaturity(msg.sender, receiver, srIn, jrIn, uaOut);
    }

    // ============ Finalization (V1 Simplified) ============

    /**
     * @notice Finalize redemption rates at maturity (admin-controlled)
     * @dev Admin provides rates, contract validates total <= available UA
     *      Can only be called once, after expiry
     * @param _srRateUA Senior redemption rate (UA per srUA, WAD precision)
     * @param _jrRateUA Junior redemption rate (UA per jrUA, WAD precision)
     */
    function finalize(uint256 _srRateUA, uint256 _jrRateUA)
        external
        onlyAdmin
        nonReentrant
    {
        if (block.timestamp < expiry) revert Errors.TrancheMarketNotExpired();
        if (finalized) revert Errors.TrancheMarketAlreadyFinalized();

        // Validation: total redemption doesn't exceed available UA
        uint256 uaBal = IERC20(address(uaToken)).balanceOf(address(this));
        uint256 srSupply = srTokenContract.totalSupply();
        uint256 jrSupply = jrTokenContract.totalSupply();

        uint256 totalRedemption = srSupply.mulDown(_srRateUA) + jrSupply.mulDown(_jrRateUA);
        if (totalRedemption > uaBal) revert Errors.TotalRedemptionExceedsBalance();

        srRateUA = _srRateUA;
        jrRateUA = _jrRateUA;
        finalized = true;

        emit Finalize(_srRateUA, _jrRateUA);
    }

    // ============ Post-Maturity Functions ============

    /**
     * @notice Redeem senior tokens for UA (post-maturity only)
     * @param srIn Amount of senior tokens to burn
     * @param receiver Address to receive UA
     * @return uaOut Amount of UA returned
     */
    function redeemSenior(uint256 srIn, address receiver)
        external
        nonReentrant
        returns (uint256 uaOut)
    {
        if (!finalized) revert Errors.TrancheMarketNotFinalized();
        if (srIn == 0) revert Errors.TrancheZeroAmount();
        if (receiver == address(0)) revert Errors.ZeroAddress();

        // Burn senior tokens from caller
        srTokenContract.burn(msg.sender, srIn);

        // Calculate UA output
        uaOut = srIn.mulDown(srRateUA);

        // Transfer UA to receiver
        IERC20(address(uaToken)).safeTransfer(receiver, uaOut);

        emit RedeemSenior(msg.sender, receiver, srIn, uaOut);
    }

    /**
     * @notice Redeem junior tokens for UA (post-maturity only)
     * @param jrIn Amount of junior tokens to burn
     * @param receiver Address to receive UA
     * @return uaOut Amount of UA returned (may be 0 if jrRateUA is 0)
     */
    function redeemJunior(uint256 jrIn, address receiver)
        external
        nonReentrant
        returns (uint256 uaOut)
    {
        if (!finalized) revert Errors.TrancheMarketNotFinalized();
        if (jrIn == 0) revert Errors.TrancheZeroAmount();
        if (receiver == address(0)) revert Errors.ZeroAddress();

        // Burn junior tokens from caller
        jrTokenContract.burn(msg.sender, jrIn);

        // Calculate UA output (may be 0 if jrRateUA is 0)
        uaOut = jrIn.mulDown(jrRateUA);

        // Transfer UA to receiver (if uaOut > 0)
        if (uaOut > 0) {
            IERC20(address(uaToken)).safeTransfer(receiver, uaOut);
        }

        emit RedeemJunior(msg.sender, receiver, jrIn, uaOut);
    }

    // ============ Admin Functions ============

    /**
     * @notice Change the admin address
     * @param _newAdmin The new admin address
     */
    function setAdmin(address _newAdmin) external onlyAdmin {
        if (_newAdmin == address(0)) revert Errors.ZeroAddress();
        admin = _newAdmin;
        emit AdminChanged(_newAdmin);
    }

    // ============ View Functions ============

    /// @notice Returns the Underlying Asset token address
    function ua() external view returns (address) {
        return address(uaToken);
    }

    /// @notice Returns the senior tranche token address
    function srToken() external view returns (address) {
        return address(srTokenContract);
    }

    /// @notice Returns the junior tranche token address
    function jrToken() external view returns (address) {
        return address(jrTokenContract);
    }
}
