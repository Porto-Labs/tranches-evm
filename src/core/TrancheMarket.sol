// SPDX-License-Identifier: MIT
pragma solidity ^0.8.23;

import { ReentrancyGuard } from "@openzeppelin/contracts/security/ReentrancyGuard.sol";
import { IERC20 } from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import { IERC20Metadata } from "@openzeppelin/contracts/token/ERC20/extensions/IERC20Metadata.sol";
import { SafeERC20 } from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import { AggregatorV3Interface } from "@chainlink/contracts/src/v0.8/shared/interfaces/AggregatorV3Interface.sol";
import { ITrancheMarket } from "../interfaces/ITrancheMarket.sol";
import { TrancheToken } from "./TrancheToken.sol";
import { PortoMath } from "../libraries/math/PortoMath.sol";
import { SettlementRatioModel } from "../settlement/SettlementRatioModel.sol";

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

    // ============ Structs ============

    /**
     * @notice Constructor parameters for TrancheMarket
     * @dev Used to avoid stack too deep errors
     */
    struct MarketParams {
        address ua;
        uint24 poolFee;
        uint256 expiry;
        uint256 seniorRatio;
        address admin;
        address priceFeed;
        uint256 seniorFloor;
        uint256 seniorTarget;
        bool liquidationEnabled;
        uint256 liquidationBuffer;
        uint256 liquidationReward;
    }

    // ============ Immutables ============

    /// @notice Underlying Asset token (internal - use uaToken() getter for external access)
    IERC20 internal immutable _uaToken;

    /// @notice Uniswap V3 pool fee tier (e.g., 500 = 0.05%)
    uint24 internal immutable _poolFee;

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

    /// @notice Chainlink price feed for UA (internal - use priceFeed() getter for external access)
    AggregatorV3Interface internal immutable _priceFeed;

    /// @notice Initial UA price at market creation (1e18 precision)
    uint256 public immutable initialPrice;

    /// @notice Senior floor yield for the period (1e18 precision, e.g., 0.0033e18 = 0.33%)
    uint256 public immutable seniorFloor;

    /// @notice Senior target yield for the period (1e18 precision, e.g., 0.005e18 = 0.5%)
    uint256 public immutable seniorTarget;

    /// @notice Price feed decimals (cached for gas efficiency)
    uint8 private immutable _priceFeedDecimals;

    /// @notice Whether liquidation is enabled for this market
    bool public immutable liquidationEnabled;

    /// @notice Price threshold below which liquidation can be triggered (1e18 precision)
    uint256 public immutable liquidationPrice;

    /// @notice Extra senior protection from junior principal (1e18 precision)
    uint256 public immutable liquidationBuffer;

    /// @notice Reward for liquidator from junior principal (1e18 precision)
    uint256 public immutable liquidationReward;

    // ============ Constants ============

    /// @notice Staleness threshold for oracle data (24 hours)
    uint256 private constant STALENESS_THRESHOLD = 24 hours;

    /// @notice protocol default decimal precision (18 decimals)
    uint8 private constant PROTOCOL_DEFAULT_DECIMALS = 18;

    /// @notice one in PROTOCOL_DEFAULT_DECIMALS precision (1e18)
    uint256 private constant ONE = 1e18;

    /// @notice Maximum allowed liquidation buffer/reward (2.5%)
    uint256 private constant MAX_LIQUIDATION_PARAM = 0.025e18;

    // ============ State Variables ============

    /// @notice Admin address (can call finalize with rates)
    address public admin;

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
        if (msg.sender != admin) revert OnlyAdmin();
        _;
    }

    // ============ Constructor ============

    /**
     * @notice Creates a new TrancheMarket
     * @param params Market initialization parameters
     */
    constructor(MarketParams memory params) {
        if (params.ua == address(0) || params.admin == address(0)) revert ZeroAddress();
        if (params.priceFeed == address(0)) revert ZeroAddress();
        if (params.expiry <= block.timestamp) revert TrancheInvalidExpiry();
        if (params.seniorRatio == 0 || params.seniorRatio >= ONE) revert TrancheInvalidWeights();
        if (params.seniorFloor > params.seniorTarget) revert SettlementRatioModel.SettlementInvalidYieldRange();

        _uaToken = IERC20(params.ua);
        _poolFee = params.poolFee;
        expiry = params.expiry;
        seniorRatio = params.seniorRatio;
        juniorRatio = ONE - params.seniorRatio;
        admin = params.admin;

        _priceFeed = AggregatorV3Interface(params.priceFeed);
        _priceFeedDecimals = AggregatorV3Interface(params.priceFeed).decimals();
        uint256 fetchedPrice = _getOraclePrice();
        initialPrice = fetchedPrice;
        seniorFloor = params.seniorFloor;
        seniorTarget = params.seniorTarget;

        if (params.liquidationBuffer > MAX_LIQUIDATION_PARAM) revert LiquidationInvalidBuffer();
        if (params.liquidationReward > MAX_LIQUIDATION_PARAM) revert LiquidationInvalidReward();

        liquidationEnabled = params.liquidationEnabled;
        liquidationBuffer = params.liquidationBuffer;
        liquidationReward = params.liquidationReward;

        if (params.liquidationEnabled) {
            uint256 _juniorRatio = ONE - params.seniorRatio;
            liquidationPrice = fetchedPrice.mulDown(
                params.seniorRatio.mulDown(ONE + params.seniorFloor) +
                    _juniorRatio.mulDown(params.liquidationBuffer + params.liquidationReward)
            );
        }

        emit InitialPriceSet(fetchedPrice);

        IERC20Metadata uaMetadata = IERC20Metadata(params.ua);
        string memory uaSymbol = uaMetadata.symbol();
        uint8 uaDecimals = uaMetadata.decimals();
        string memory srSymbol = string(abi.encodePacked("sr", uaSymbol));
        string memory jrSymbol = string(abi.encodePacked("jr", uaSymbol));
        string memory srName = string(abi.encodePacked("Porto ", srSymbol));
        string memory jrName = string(abi.encodePacked("Porto ", jrSymbol));

        _srTokenContract = new TrancheToken(srName, srSymbol, address(this), uaDecimals);
        _jrTokenContract = new TrancheToken(jrName, jrSymbol, address(this), uaDecimals);
    }

    // ============ Pre-Maturity Functions ============

    /**
     * @notice Divide UA into tranches at fixed ratio (pre-maturity only)
     * @dev Both srOut and jrOut round down, so srOut + jrOut <= uaIn.
     *      Any dust remains in the contract and is distributed at finalization.
     * @param uaIn Amount of UA to lock
     * @param receiver Address to receive tranche tokens
     * @return srOut Amount of senior tokens minted
     * @return jrOut Amount of junior tokens minted
     */
    function tranche(
        uint256 uaIn,
        address receiver
    ) external override nonReentrant returns (uint256 srOut, uint256 jrOut) {
        if (block.timestamp >= expiry) revert TrancheMarketExpired();
        if (uaIn == 0) revert TrancheZeroAmount();
        if (receiver == address(0)) revert ZeroAddress();

        _uaToken.safeTransferFrom(msg.sender, address(this), uaIn);

        srOut = uaIn.mulDown(seniorRatio);
        jrOut = uaIn.mulDown(juniorRatio);

        _srTokenContract.mint(receiver, srOut);
        _jrTokenContract.mint(receiver, jrOut);

        emit Tranche(msg.sender, receiver, uaIn, srOut, jrOut);
    }

    /**
     * @notice Recombine tranches into UA by burning both in correct ratio (pre-maturity only)
     * @param srIn Amount of senior tokens to burn
     * @param jrIn Amount of junior tokens to burn
     * @param receiver Address to receive UA
     * @return uaOut Amount of UA returned
     */
    function recombine(
        uint256 srIn,
        uint256 jrIn,
        address receiver
    ) external override nonReentrant returns (uint256 uaOut) {
        if (block.timestamp >= expiry) revert TrancheMarketExpired();
        if (srIn == 0 || jrIn == 0) revert TrancheZeroAmount();
        if (receiver == address(0)) revert ZeroAddress();

        // Validate ratio: srIn / seniorRatio == jrIn / juniorRatio
        // Equivalent equation without precision loss: srIn * juniorRatio == jrIn * seniorRatio
        if (srIn.mulDown(juniorRatio) != jrIn.mulDown(seniorRatio)) revert TrancheRatioMismatch();

        _srTokenContract.burn(msg.sender, srIn);
        _jrTokenContract.burn(msg.sender, jrIn);

        uaOut = srIn.divDown(seniorRatio);

        _uaToken.safeTransfer(receiver, uaOut);

        emit Recombine(msg.sender, receiver, srIn, jrIn, uaOut);
    }

    // ============ Finalization ============

    /**
     * @notice Finalize redemption rates at maturity using oracle price
     * @dev Admin provides reference price for deviation check, oracle price is fetched on-chain
     *      Contract calculates rates using SettlementRatioModel waterfall logic
     * @param referencePrice Expected price for deviation validation (PROTOCOL_DEFAULT_DECIMALS precision)
     * @param deviationThreshold Maximum allowed deviation from oracle price (1e18 precision, e.g., 0.01e18 = 1%)
     */
    function finalize(uint256 referencePrice, uint256 deviationThreshold) external override onlyAdmin nonReentrant {
        if (block.timestamp < expiry) revert TrancheMarketNotExpired();
        if (finalized) revert TrancheMarketAlreadyFinalized();
        if (deviationThreshold > 1e18) revert OracleInvalidDeviationThreshold();
        if (referencePrice == 0) revert SettlementRatioModel.SettlementZeroPrice();

        uint256 oraclePrice = _getOraclePrice();
        uint256 deviation;
        if (oraclePrice >= referencePrice) {
            deviation = (oraclePrice - referencePrice).divDown(referencePrice);
        } else {
            deviation = (referencePrice - oraclePrice).divDown(referencePrice);
        }
        if (deviation > deviationThreshold) revert OraclePriceDeviationExceeded();

        uint256 uaQuantity = _uaToken.balanceOf(address(this));
        SettlementRatioModel.SettlementParams memory params = SettlementRatioModel.SettlementParams({
            uaQuantity: uaQuantity,
            initialPrice: initialPrice,
            maturityPrice: oraclePrice,
            seniorRatio: seniorRatio,
            seniorFloor: seniorFloor,
            seniorTarget: seniorTarget
        });

        SettlementRatioModel.SettlementResult memory result = SettlementRatioModel.calculateSettlement(params);

        srRateUA = result.srRateUA;
        jrRateUA = result.jrRateUA;
        finalized = true;

        emit Finalize(oraclePrice, referencePrice, result.srRateUA, result.jrRateUA);
    }

    // ============ Post-Maturity Functions ============

    /**
     * @notice Redeem senior tokens for UA (post-maturity only)
     * @param srIn Amount of senior tokens to burn
     * @param receiver Address to receive UA
     * @return uaOut Amount of UA returned
     */
    function redeemSenior(uint256 srIn, address receiver) external override nonReentrant returns (uint256 uaOut) {
        if (!finalized) revert TrancheMarketNotFinalized();
        if (srIn == 0) revert TrancheZeroAmount();
        if (receiver == address(0)) revert ZeroAddress();

        _srTokenContract.burn(msg.sender, srIn);   
        uaOut = srIn.mulDown(srRateUA);
        _uaToken.safeTransfer(receiver, uaOut);

        emit RedeemSenior(msg.sender, receiver, srIn, uaOut);
    }

    /**
     * @notice Redeem junior tokens for UA (post-maturity only)
     * @param jrIn Amount of junior tokens to burn
     * @param receiver Address to receive UA
     * @return uaOut Amount of UA returned (may be 0 if jrRateUA is 0)
     */
    function redeemJunior(uint256 jrIn, address receiver) external override nonReentrant returns (uint256 uaOut) {
        if (!finalized) revert TrancheMarketNotFinalized();
        if (jrIn == 0) revert TrancheZeroAmount();
        if (receiver == address(0)) revert ZeroAddress();

        _jrTokenContract.burn(msg.sender, jrIn);
        uaOut = jrIn.mulDown(jrRateUA);

        if (uaOut > 0) {
            _uaToken.safeTransfer(receiver, uaOut);
        }

        emit RedeemJunior(msg.sender, receiver, jrIn, uaOut);
    }

    // ============ Admin Functions ============

    /**
     * @notice Change the admin address
     * @param _newAdmin The new admin address
     */
    function setAdmin(address _newAdmin) external override onlyAdmin {
        if (_newAdmin == address(0)) revert ZeroAddress();
        admin = _newAdmin;
        emit AdminChanged(_newAdmin);
    }

    // ============ Liquidation ============

    /**
     * @notice Trigger liquidation when conditions are met (pre-maturity only)
     * @dev Admin-only. Transfers reward to caller, sets jrRateUA to 0, finalizes market
     * @return _liquidatorReward Amount of UA transferred to liquidator
     */
    function liquidate() external override onlyAdmin nonReentrant returns (uint256 _liquidatorReward) {
        if (!liquidationEnabled) revert LiquidationNotEnabled();
        if (block.timestamp >= expiry) revert LiquidationAfterExpiry();
        if (finalized) revert TrancheMarketAlreadyFinalized();

        uint256 oraclePrice = _getOraclePrice();
        if (oraclePrice >= liquidationPrice) revert LiquidationConditionNotMet();

        uint256 uaQuantity = _uaToken.balanceOf(address(this));
        if (uaQuantity == 0) revert SettlementRatioModel.SettlementZeroQuantity();

        uint256 srSupply = _srTokenContract.totalSupply();
        uint256 jrSupply = _jrTokenContract.totalSupply();

        _liquidatorReward = jrSupply.mulDown(liquidationReward);

        uint256 remainingUA = uaQuantity - _liquidatorReward;
        srRateUA = remainingUA.divDown(srSupply);
        jrRateUA = 0;
        finalized = true;

        if (_liquidatorReward > 0) {
            _uaToken.safeTransfer(msg.sender, _liquidatorReward);
        }

        emit Liquidate(oraclePrice, liquidationPrice, srRateUA, _liquidatorReward, msg.sender);
    }

    // ============ Preview Functions ============

    /**
     * @notice Preview settlement rates based on current oracle price
     * @dev Read-only function that calculates what rates would be at finalization.
     *      Uses current oracle price and SettlementRatioModel waterfall logic.
     *      Returns projected rates based on CURRENT oracle price.
     *      Actual rates at finalize() may differ if called in a different block.
     * @return _srRateUA Projected senior redemption rate (UA per srUA)
     * @return _jrRateUA Projected junior redemption rate (UA per jrUA)
     * @return oraclePrice Current price from oracle (1e18 precision)
     */
    function previewSettlement()
        external
        view
        override
        returns (uint256 _srRateUA, uint256 _jrRateUA, uint256 oraclePrice)
    {
        oraclePrice = _getOraclePrice();
        uint256 uaQuantity = _uaToken.balanceOf(address(this));

        SettlementRatioModel.SettlementParams memory params = SettlementRatioModel.SettlementParams({
            uaQuantity: uaQuantity,
            initialPrice: initialPrice,
            maturityPrice: oraclePrice,
            seniorRatio: seniorRatio,
            seniorFloor: seniorFloor,
            seniorTarget: seniorTarget
        });

        SettlementRatioModel.SettlementResult memory result = SettlementRatioModel.calculateSettlement(params);
        _srRateUA = result.srRateUA;
        _jrRateUA = result.jrRateUA;
    }

    /**
     * @notice Preview liquidation state and potential outcomes
     * @dev Read-only function that calculates liquidation parameters
     * @return canLiquidate Whether liquidation conditions are currently met
     * @return currentPrice Current oracle price (1e18 precision)
     * @return liquidationPriceValue Price threshold for liquidation (1e18 precision)
     * @return _srRateUA Projected senior redemption rate if liquidated
     * @return _liquidatorReward Projected reward for liquidator in UA
     */
    function previewLiquidation()
        external
        view
        override
        returns (
            bool canLiquidate,
            uint256 currentPrice,
            uint256 liquidationPriceValue,
            uint256 _srRateUA,
            uint256 _liquidatorReward
        )
    {
        liquidationPriceValue = liquidationPrice;

        if (!liquidationEnabled || block.timestamp >= expiry || finalized) {
            return (false, 0, liquidationPriceValue, 0, 0);
        }

        currentPrice = _getOraclePrice();
        canLiquidate = currentPrice < liquidationPrice;

        if (canLiquidate) {
            uint256 uaQuantity = _uaToken.balanceOf(address(this));
            uint256 srSupply = _srTokenContract.totalSupply();
            uint256 jrSupply = _jrTokenContract.totalSupply();

            _liquidatorReward = jrSupply.mulDown(liquidationReward);
            uint256 remainingUA = uaQuantity - _liquidatorReward;
            _srRateUA = remainingUA.divDown(srSupply);
        }
    }

    // ============ Internal Functions ============

    /**
     * @notice Scale price from oracle decimals to target decimals
     * @dev Uses Chainlink's recommended pattern for decimal conversion
     * @param _price Raw price from oracle
     * @param _priceDecimals Oracle's decimal precision
     * @param _targetDecimals Target decimal precision (PROTOCOL_DEFAULT_DECIMALS = 18)
     * @return Scaled price in target decimals
     */
    function _scalePrice(int256 _price, uint8 _priceDecimals, uint8 _targetDecimals) internal pure returns (uint256) {
        if (_priceDecimals < _targetDecimals) {
            // forge-lint: disable-next-line(unsafe-typecast)
            return uint256(_price) * 10 ** uint256(_targetDecimals - _priceDecimals);
        } else if (_priceDecimals > _targetDecimals) {
            // forge-lint: disable-next-line(unsafe-typecast)
            return uint256(_price) / 10 ** uint256(_priceDecimals - _targetDecimals);
        }
        // forge-lint: disable-next-line(unsafe-typecast)
        return uint256(_price);
    }

    /**
     * @notice Fetch and validate oracle price
     * @dev Validates: price > 0, data not stale (24h threshold)
     * @return price Oracle price scaled to 1e18 precision
     */
    function _getOraclePrice() internal view returns (uint256 price) {
        (, int256 answer, , uint256 updatedAt, ) = _priceFeed.latestRoundData();

        // Validate price is positive
        if (answer <= 0) revert OracleInvalidPrice();

        // Validate data is not stale
        if (block.timestamp - updatedAt > STALENESS_THRESHOLD) revert OracleStalePrice();

        // Scale to 1e18 precision
        price = _scalePrice(answer, _priceFeedDecimals, PROTOCOL_DEFAULT_DECIMALS);
    }

    // ============ View Functions ============

    /// @notice Returns the Underlying Asset token address
    function uaToken() external view override returns (address) {
        return address(_uaToken);
    }

    /// @notice Returns the senior tranche token address
    function srToken() external view override returns (address) {
        return address(_srTokenContract);
    }

    /// @notice Returns the junior tranche token address
    function jrToken() external view override returns (address) {
        return address(_jrTokenContract);
    }

    /// @notice Returns the Chainlink price feed address
    function priceFeed() external view override returns (address) {
        return address(_priceFeed);
    }

    /// @notice Returns swap parameters for Router in a single call
    /// @return uaAddress Underlying Asset token address
    /// @return srAddress Senior tranche token address
    /// @return jrAddress Junior tranche token address
    /// @return poolFee Uniswap V3 pool fee tier
    function getSwapParameters()
        external
        view
        override
        returns (address uaAddress, address srAddress, address jrAddress, uint24 poolFee)
    {
        return (address(_uaToken), address(_srTokenContract), address(_jrTokenContract), _poolFee);
    }

    /**
     * @notice Preview the amounts of senior and junior tokens that would be minted for a given UA input
     * @param uaIn Amount of UA to tranche
     * @return srOut Amount of senior tokens that would be minted
     * @return jrOut Amount of junior tokens that would be minted
     */
    function previewTranche(uint256 uaIn) external view override returns (uint256 srOut, uint256 jrOut) {
        srOut = uaIn.mulDown(seniorRatio);
        jrOut = uaIn.mulDown(juniorRatio);
    }
}
