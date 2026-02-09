// SPDX-License-Identifier: MIT
pragma solidity ^0.8.23;

import { FixedPointMathLib } from "solady/utils/FixedPointMathLib.sol";

/**
 * @title SettlementRatioModel
 * @notice Stateless library for calculating senior/junior redemption rates
 * @dev Implements waterfall logic for tranche settlements:
 *      - Condition A (Surplus): Senior capped at target, junior gets excess
 *      - Condition B (Compression): Senior takes all yield, junior at principal
 *      - Condition C (Erosion): Senior protected at floor, junior eroded
 *
 *      All values use 18 decimal precision (1e18 = 1.0)
 */
library SettlementRatioModel {
    using FixedPointMathLib for uint256;

    /// @notice Thrown when settlement price is zero
    error SettlementZeroPrice();

    /// @notice Thrown when settlement quantity is zero
    error SettlementZeroQuantity();

    /// @notice Thrown when settlement ratio is invalid
    error SettlementInvalidRatio();

    /// @notice Thrown when yield range is invalid (floor exceeds target)
    error SettlementInvalidYieldRange();

    /**
     * @notice Input parameters for settlement calculation
     * @param uaQuantity Current UA in the tranche at settlement
     * @param initialPrice UA price at tokenization (USD per UA)
     * @param maturityPrice UA price at settlement from oracle (USD per UA)
     * @param seniorRatio Senior allocation ratio (e.g., 0.7e18 = 70%)
     * @param seniorFloor Senior floor yield for the period (e.g., 0.0033e18 = 0.33%)
     * @param seniorTarget Senior target yield for the period (e.g., 0.005e18 = 0.5%)
     */
    struct SettlementParams {
        uint256 uaQuantity;
        uint256 initialPrice;
        uint256 maturityPrice;
        uint256 seniorRatio;
        uint256 seniorFloor;
        uint256 seniorTarget;
    }

    /**
     * @notice Output from settlement calculation
     * @param srRateUA UA per senior token (redemption rate)
     * @param jrRateUA UA per junior token (redemption rate)
     */
    struct SettlementResult {
        uint256 srRateUA;
        uint256 jrRateUA;
    }

    uint256 internal constant ONE = 1e18;

    /**
     * @notice Calculate settlement rates based on waterfall logic
     * @param params Settlement parameters
     * @return result Settlement result with redemption rates
     */
    function calculateSettlement(SettlementParams memory params)
        internal
        pure
        returns (SettlementResult memory result)
    {
        _validateParams(params);

        (uint256 srPrincipalUsd, uint256 jrPrincipalUsd) =
            _calculatePrincipals(params.uaQuantity, params.initialPrice, params.seniorRatio);

        (uint256 srFloorUsd, uint256 srTargetUsd) =
            _calculateThresholds(srPrincipalUsd, params.seniorFloor, params.seniorTarget);

        uint256 totalValueUsd = params.uaQuantity.mulWad(params.maturityPrice);

        (uint256 seniorPayoutUsd, uint256 juniorPayoutUsd) =
            _calculatePayouts(totalValueUsd, jrPrincipalUsd, srFloorUsd, srTargetUsd);

        (result.srRateUA, result.jrRateUA) = _calculateRates(
            seniorPayoutUsd, juniorPayoutUsd, params.maturityPrice, params.uaQuantity, params.seniorRatio
        );
    }

    /**
     * @notice Calculate senior and junior principals from inputs and initial price snapshot.
     * @dev Senior principal rounds UP to protect seniors; junior is remainder for exact sum
     * @param uaQuantity Total UA in the tranche
     * @param initialPrice UA price at tokenization
     * @param seniorRatio Senior allocation ratio
     * @return srPrincipalUsd Senior principal in USD
     * @return jrPrincipalUsd Junior principal in USD
     */
    function _calculatePrincipals(uint256 uaQuantity, uint256 initialPrice, uint256 seniorRatio)
        internal
        pure
        returns (uint256 srPrincipalUsd, uint256 jrPrincipalUsd)
    {
        uint256 totalValue = uaQuantity.mulWad(initialPrice);
        srPrincipalUsd = totalValue.mulWadUp(seniorRatio);
        jrPrincipalUsd = totalValue - srPrincipalUsd;
    }

    /**
     * @notice Calculate floor and target thresholds in USD
     * @dev Both floor and target round UP to favor seniors:
     *      - Floor APY rounds UP
     *      - Target APY rounds UP
     * @param srPrincipalUsd Senior principal in USD
     * @param seniorFloor Floor yield for the period
     * @param seniorTarget Target yield for the period
     * @return srFloorUsd Senior floor value in USD (minimum guaranteed)
     * @return srTargetUsd Senior target value in USD (maximum cap)
     */
    function _calculateThresholds(uint256 srPrincipalUsd, uint256 seniorFloor, uint256 seniorTarget)
        internal
        pure
        returns (uint256 srFloorUsd, uint256 srTargetUsd)
    {
        srFloorUsd = srPrincipalUsd.mulWadUp(ONE + seniorFloor);
        srTargetUsd = srPrincipalUsd.mulWadUp(ONE + seniorTarget);
    }

    /**
     * @notice Apply waterfall logic to determine payouts
     * @param totalValueUsd Total value at maturity in USD
     * @param jrPrincipalUsd Junior principal in USD
     * @param srFloorUsd Senior floor value in USD
     * @param srTargetUsd Senior target value in USD
     * @return seniorPayout Senior payout in USD
     * @return juniorPayout Junior payout in USD
     */
    function _calculatePayouts(uint256 totalValueUsd, uint256 jrPrincipalUsd, uint256 srFloorUsd, uint256 srTargetUsd)
        internal
        pure
        returns (uint256 seniorPayout, uint256 juniorPayout)
    {
        // Condition A: Surplus
        if (totalValueUsd >= srTargetUsd + jrPrincipalUsd) {
            seniorPayout = srTargetUsd;
            juniorPayout = totalValueUsd - srTargetUsd;
            // Condition B: Target APY Compression
        } else if (totalValueUsd >= srFloorUsd + jrPrincipalUsd) {
            seniorPayout = totalValueUsd - jrPrincipalUsd;
            juniorPayout = jrPrincipalUsd;
            // Condition C: Junior Erosion
        } else {
            seniorPayout = FixedPointMathLib.min(totalValueUsd, srFloorUsd);
            juniorPayout = totalValueUsd > seniorPayout ? totalValueUsd - seniorPayout : 0;
        }
    }

    /**
     * @notice Calculate redemption rates (UA per token)
     * @dev Derives junior rate from remainder to ensure exact sum (no dust/bad debt)
     *      Senior operations round UP to protect seniors; juniors absorb rounding
     * @param seniorPayoutUsd Senior payout in USD
     * @param juniorPayoutUsd Junior payout in USD
     * @param maturityPrice UA price at maturity
     * @param uaQuantity Total UA in the tranche
     * @param seniorRatio Senior allocation ratio
     * @return srRateUA Senior redemption rate (UA per token)
     * @return jrRateUA Junior redemption rate (UA per token)
     */
    function _calculateRates(
        uint256 seniorPayoutUsd,
        uint256 juniorPayoutUsd,
        uint256 maturityPrice,
        uint256 uaQuantity,
        uint256 seniorRatio
    ) internal pure returns (uint256 srRateUA, uint256 jrRateUA) {
        uint256 srSupply = uaQuantity.mulWad(seniorRatio);
        uint256 jrSupply = uaQuantity - srSupply;

        uint256 totalUaAvailable = (seniorPayoutUsd + juniorPayoutUsd).divWad(maturityPrice);

        uint256 srPayoutUA = seniorPayoutUsd.divWadUp(maturityPrice);
        srRateUA = srSupply > 0 ? srPayoutUA.divWadUp(srSupply) : 0;

        uint256 srWillReceive = srSupply.mulWad(srRateUA);

        if (srWillReceive > totalUaAvailable) {
            srWillReceive = totalUaAvailable;
            srRateUA = srSupply > 0 ? totalUaAvailable.divWad(srSupply) : 0;
        }

        uint256 jrWillReceive = totalUaAvailable - srWillReceive;
        jrRateUA = jrSupply > 0 ? jrWillReceive.divWad(jrSupply) : 0;
    }

    /**
     * @notice Validate settlement parameters
     * @param params Parameters to validate
     */
    function _validateParams(SettlementParams memory params) internal pure {
        if (params.maturityPrice == 0 || params.initialPrice == 0) {
            revert SettlementZeroPrice();
        }
        if (params.uaQuantity == 0) {
            revert SettlementZeroQuantity();
        }
        if (params.seniorRatio == 0 || params.seniorRatio >= ONE) {
            revert SettlementInvalidRatio();
        }
        if (params.seniorFloor > params.seniorTarget) {
            revert SettlementInvalidYieldRange();
        }
    }
}
