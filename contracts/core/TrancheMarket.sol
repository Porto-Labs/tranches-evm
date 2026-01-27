// SPDX-License-Identifier: MIT
pragma solidity ^0.8.23;

import { ReentrancyGuard } from "@openzeppelin/contracts/security/ReentrancyGuard.sol";
import { IERC20 } from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import { SafeERC20 } from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import { ITrancheMarket } from "../interfaces/ITrancheMarket.sol";
import { TrancheToken } from "./TrancheToken.sol";
import { Errors } from "../errors/Errors.sol";
import { PortoMath } from "../libraries/math/PortoMath.sol";

/**
 * @title TrancheMarket
 * @notice Core tranching mechanism: UA → srUA (senior) + jrUA (junior)
 * @dev Admin-controlled finalization
 *      Pre-maturity: Fixed ratio minting/redeeming
 *      At maturity: Admin sets redemption rates
 *      Post-maturity: Unilateral redemption at fixed rates
 */
contract TrancheMarket is ITrancheMarket, ReentrancyGuard {
    using SafeERC20 for IERC20;
    using PortoMath for uint256;

    // ============ Immutables ============

    /// @notice Underlying Asset token (internal - use ua() getter for external access)
    IERC20 internal immutable _uaToken;

    /// @notice Senior tranche token (internal - use srToken() getter for external access)
    TrancheToken internal immutable _srTokenContract;

    /// @notice Junior tranche token (internal - use jrToken() getter for external access)
    TrancheToken internal immutable _jrTokenContract;

    /// @notice Maturity timestamp
    uint256 public immutable expiry;

    /// @notice Senior tranche ratio (e.g., 0.8e18 for 80%)
    uint256 public immutable seniorRatio;

    /// @notice Junior tranche ratio (e.g., 0.2e18 for 20%)
    uint256 public immutable juniorRatio;

    // ============ State Variables ============

    /// @notice Admin address (can call finalize with rates)
    address public admin;

    /// @notice Whether the market has been finalized
    bool public finalized;

    /// @notice Senior redemption rate (UA per srUA, set at finalization)
    uint256 public srRateUA;

    /// @notice Junior redemption rate (UA per jrUA, set at finalization)
    uint256 public jrRateUA;

    /// @notice Uniswap V3 pool fee tier for Router swaps (e.g., 3000 = 0.3%)
    uint24 public poolFee;

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
     * @param _seniorRatio Senior tranche ratio (e.g., 0.8e18 for 80%)
     * @param _juniorRatio Junior tranche ratio (e.g., 0.2e18 for 20%)
     * @param _admin Admin address
     * @param _poolFee Uniswap V3 pool fee tier (e.g., 3000 for 0.3%)
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
        uint24 _poolFee,
        string memory _srName,
        string memory _srSymbol,
        string memory _jrName,
        string memory _jrSymbol
    ) {
        if (_ua == address(0) || _admin == address(0)) revert Errors.ZeroAddress();
        if (_expiry <= block.timestamp) revert Errors.TrancheInvalidExpiry();
        if (_seniorRatio + _juniorRatio != 1e18) revert Errors.TrancheInvalidWeights();

        _uaToken = IERC20(_ua);
        expiry = _expiry;
        seniorRatio = _seniorRatio;
        juniorRatio = _juniorRatio;
        admin = _admin;
        poolFee = _poolFee;

        _srTokenContract = new TrancheToken(_srName, _srSymbol, address(this));
        _jrTokenContract = new TrancheToken(_jrName, _jrSymbol, address(this));
    }

    // ============ Pre-Maturity Functions ============

    /**
     * @notice Tokenize UA into tranches at fixed ratio (pre-maturity only)
     * @param uaIn Amount of UA to lock
     * @param receiver Address to receive tranche tokens
     * @return srOut Amount of senior tokens minted
     * @return jrOut Amount of junior tokens minted
     */
    function tokenize(uint256 uaIn, address receiver) external nonReentrant returns (uint256 srOut, uint256 jrOut) {
        if (block.timestamp >= expiry) revert Errors.TrancheMarketExpired();
        if (uaIn == 0) revert Errors.TrancheZeroAmount();
        if (receiver == address(0)) revert Errors.ZeroAddress();

        IERC20(address(_uaToken)).safeTransferFrom(msg.sender, address(this), uaIn);

        srOut = uaIn.mulDown(seniorRatio);
        jrOut = uaIn.mulDown(juniorRatio);

        _srTokenContract.mint(receiver, srOut);
        _jrTokenContract.mint(receiver, jrOut);

        emit Tokenize(msg.sender, receiver, uaIn, srOut, jrOut);
    }

    /**
     * @notice Redeem UA by burning both tranches in correct ratio (pre-maturity only)
     * @param srIn Amount of senior tokens to burn
     * @param jrIn Amount of junior tokens to burn
     * @param receiver Address to receive UA
     * @return uaOut Amount of UA returned
     */
    function redeemPreMaturity(
        uint256 srIn,
        uint256 jrIn,
        address receiver
    ) external nonReentrant returns (uint256 uaOut) {
        if (block.timestamp >= expiry) revert Errors.TrancheMarketExpired();
        if (srIn == 0 || jrIn == 0) revert Errors.TrancheZeroAmount();
        if (receiver == address(0)) revert Errors.ZeroAddress();

        // Validate ratio: srIn / seniorRatio == jrIn / juniorRatio
        // Equivalent: srIn * juniorRatio == jrIn * seniorRatio
        if (srIn.mulDown(juniorRatio) != jrIn.mulDown(seniorRatio)) revert Errors.TrancheRatioMismatch();

        _srTokenContract.burn(msg.sender, srIn);
        _jrTokenContract.burn(msg.sender, jrIn);

        uaOut = srIn.divDown(seniorRatio); // or jrIn.divDown(juniorRatio) - same result

        IERC20(address(_uaToken)).safeTransfer(receiver, uaOut);

        emit RedeemPreMaturity(msg.sender, receiver, srIn, jrIn, uaOut);
    }

    // ============ Finalization ============

    /**
     * @notice Finalize redemption rates at maturity (admin-controlled)
     * @dev Admin provides rates, contract validates total <= available UA
     *      Can only be called once, after expiry
     * @param _srRateUA Senior redemption rate (UA per srUA)
     * @param _jrRateUA Junior redemption rate (UA per jrUA)
     */
    function finalize(uint256 _srRateUA, uint256 _jrRateUA) external onlyAdmin nonReentrant {
        if (block.timestamp < expiry) revert Errors.TrancheMarketNotExpired();
        if (finalized) revert Errors.TrancheMarketAlreadyFinalized();

        // Validation: total redemption doesn't exceed available UA
        uint256 uaBal = IERC20(address(_uaToken)).balanceOf(address(this));
        uint256 srSupply = _srTokenContract.totalSupply();
        uint256 jrSupply = _jrTokenContract.totalSupply();

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
    function redeemSenior(uint256 srIn, address receiver) external nonReentrant returns (uint256 uaOut) {
        if (!finalized) revert Errors.TrancheMarketNotFinalized();
        if (srIn == 0) revert Errors.TrancheZeroAmount();
        if (receiver == address(0)) revert Errors.ZeroAddress();

        _srTokenContract.burn(msg.sender, srIn);   
        uaOut = srIn.mulDown(srRateUA);
        IERC20(address(_uaToken)).safeTransfer(receiver, uaOut);

        emit RedeemSenior(msg.sender, receiver, srIn, uaOut);
    }

    /**
     * @notice Redeem junior tokens for UA (post-maturity only)
     * @param jrIn Amount of junior tokens to burn
     * @param receiver Address to receive UA
     * @return uaOut Amount of UA returned (may be 0 if jrRateUA is 0)
     */
    function redeemJunior(uint256 jrIn, address receiver) external nonReentrant returns (uint256 uaOut) {
        if (!finalized) revert Errors.TrancheMarketNotFinalized();
        if (jrIn == 0) revert Errors.TrancheZeroAmount();
        if (receiver == address(0)) revert Errors.ZeroAddress();

        _jrTokenContract.burn(msg.sender, jrIn);
        uaOut = jrIn.mulDown(jrRateUA);

        if (uaOut > 0) {
            IERC20(address(_uaToken)).safeTransfer(receiver, uaOut);
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
        return address(_uaToken);
    }

    /// @notice Returns the senior tranche token address
    function srToken() external view returns (address) {
        return address(_srTokenContract);
    }

    /// @notice Returns the junior tranche token address
    function jrToken() external view returns (address) {
        return address(_jrTokenContract);
    }

    /// @notice Returns swap parameters for Router in a single call
    /// @return uaAddress Underlying Asset token address
    /// @return srAddress Senior tranche token address
    /// @return jrAddress Junior tranche token address
    /// @return fee Uniswap V3 pool fee tier
    function getSwapParameters()
        external
        view
        returns (address uaAddress, address srAddress, address jrAddress, uint24 fee)
    {
        return (address(_uaToken), address(_srTokenContract), address(_jrTokenContract), poolFee);
    }
}
