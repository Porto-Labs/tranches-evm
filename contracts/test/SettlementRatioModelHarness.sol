// SPDX-License-Identifier: MIT
pragma solidity ^0.8.23;

import { SettlementRatioModel } from "../settlement/SettlementRatioModel.sol";

/**
 * @title SettlementRatioModelHarness
 * @notice Test wrapper to expose internal library functions for testing
 */
contract SettlementRatioModelHarness {
    /**
     * @notice Expose calculateSettlement for testing
     */
    function calculateSettlement(
        SettlementRatioModel.SettlementParams memory params
    ) external pure returns (SettlementRatioModel.SettlementResult memory) {
        return SettlementRatioModel.calculateSettlement(params);
    }

    /**
     * @notice Expose _calculatePrincipals for testing
     */
    function calculatePrincipals(
        uint256 uaQuantity,
        uint256 initialPrice,
        uint256 seniorRatio
    ) external pure returns (uint256 pSr, uint256 pJr) {
        return SettlementRatioModel._calculatePrincipals(uaQuantity, initialPrice, seniorRatio);
    }

    /**
     * @notice Expose _calculateThresholds for testing
     */
    function calculateThresholds(
        uint256 pSr,
        uint256 seniorFloor,
        uint256 seniorTarget
    ) external pure returns (uint256 vFloor, uint256 vTarget) {
        return SettlementRatioModel._calculateThresholds(pSr, seniorFloor, seniorTarget);
    }

    /**
     * @notice Expose _calculatePayouts for testing
     */
    function calculatePayouts(
        uint256 vTotal,
        uint256 pJr,
        uint256 vFloor,
        uint256 vTarget
    ) external pure returns (uint256 seniorPayout, uint256 juniorPayout) {
        return SettlementRatioModel._calculatePayouts(vTotal, pJr, vFloor, vTarget);
    }

    /**
     * @notice Expose _calculateRates for testing
     */
    function calculateRates(
        uint256 seniorPayoutUsd,
        uint256 juniorPayoutUsd,
        uint256 maturityPrice,
        uint256 uaQuantity,
        uint256 seniorRatio
    ) external pure returns (uint256 srRateUA, uint256 jrRateUA) {
        return
            SettlementRatioModel._calculateRates(
                seniorPayoutUsd,
                juniorPayoutUsd,
                maturityPrice,
                uaQuantity,
                seniorRatio
            );
    }

    /**
     * @notice Helper constant for tests
     */
    function one() external pure returns (uint256) {
        return 1e18;
    }
}
