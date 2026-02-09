// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import { Test } from "forge-std/Test.sol";
import { SettlementRatioModelMock } from "./mocks/SettlementRatioModelMock.sol";
import { SettlementRatioModel } from "src/settlement/SettlementRatioModel.sol";

contract SettlementRatioModelTest is Test {
    SettlementRatioModelMock public settlementModel;

    uint256 constant ONE = 1e18;

    function setUp() public {
        settlementModel = new SettlementRatioModelMock();
    }

    function _defaultParams() internal pure returns (SettlementRatioModel.SettlementParams memory) {
        return SettlementRatioModel.SettlementParams({
            uaQuantity: 100e18,
            initialPrice: 1e18,
            maturityPrice: 1e18,
            seniorRatio: 0.7e18,
            seniorFloor: 0.0033e18,
            seniorTarget: 0.005e18
        });
    }

    function _mulDown(uint256 a, uint256 b) internal pure returns (uint256) {
        return (a * b) / ONE;
    }

    function _assertNoOverDistribution(uint256 uaQuantity, uint256 seniorRatio, uint256 srRateUA, uint256 jrRateUA)
        internal
        pure
    {
        uint256 srSupply = _mulDown(uaQuantity, seniorRatio);
        uint256 jrSupply = uaQuantity - srSupply;
        uint256 srDistributed = _mulDown(srSupply, srRateUA);
        uint256 jrDistributed = _mulDown(jrSupply, jrRateUA);
        uint256 totalDistributed = srDistributed + jrDistributed;
        assertLe(totalDistributed, uaQuantity, "Over-distribution detected");
    }

    function test_CalculatePrincipals_StandardRatio() public view {
        (uint256 srPrincipal, uint256 jrPrincipal) = settlementModel.calculatePrincipals(100e18, 1e18, 0.7e18);
        assertEq(srPrincipal, 70e18);
        assertEq(jrPrincipal, 30e18);
    }

    function test_CalculatePrincipals_DifferentPrices() public view {
        (uint256 srPrincipal, uint256 jrPrincipal) = settlementModel.calculatePrincipals(100e18, 1.5e18, 0.7e18);
        assertEq(srPrincipal, 105e18);
        assertEq(jrPrincipal, 45e18);
    }

    function test_CalculatePrincipals_FiftyFiftyRatio() public view {
        (uint256 srPrincipal, uint256 jrPrincipal) = settlementModel.calculatePrincipals(100e18, 1e18, 0.5e18);
        assertEq(srPrincipal, 50e18);
        assertEq(jrPrincipal, 50e18);
    }

    function test_CalculateThresholds_FloorAndTarget() public view {
        uint256 srPrincipal = 70e18;
        uint256 seniorFloorYield = 0.0033e18;
        uint256 seniorTargetYield = 0.005e18;
        (uint256 srFloorUsd, uint256 srTargetUsd) =
            settlementModel.calculateThresholds(srPrincipal, seniorFloorYield, seniorTargetYield);
        assertEq(srFloorUsd, 70.231e18);
        assertEq(srTargetUsd, 70.35e18);
    }

    function test_CalculateThresholds_ZeroYield() public view {
        (uint256 srFloorUsd, uint256 srTargetUsd) = settlementModel.calculateThresholds(100e18, 0, 0);
        assertEq(srFloorUsd, 100e18);
        assertEq(srTargetUsd, 100e18);
    }

    function test_CalculatePayouts_SurplusCondition() public view {
        uint256 jrPrincipalUsd = 30e18;
        uint256 srFloorUsd = 70.231e18;
        uint256 srTargetUsd = 70.35e18;
        uint256 totalValueUsd = 101e18;

        (uint256 seniorPayout, uint256 juniorPayout) =
            settlementModel.calculatePayouts(totalValueUsd, jrPrincipalUsd, srFloorUsd, srTargetUsd);
        assertEq(seniorPayout, srTargetUsd);
        assertEq(juniorPayout, totalValueUsd - srTargetUsd);
    }

    function test_CalculatePayouts_CompressionCondition() public view {
        uint256 jrPrincipalUsd = 30e18;
        uint256 srFloorUsd = 70.231e18;
        uint256 srTargetUsd = 70.35e18;
        uint256 totalValueUsd = 100.3e18;

        (uint256 seniorPayout, uint256 juniorPayout) =
            settlementModel.calculatePayouts(totalValueUsd, jrPrincipalUsd, srFloorUsd, srTargetUsd);
        assertEq(seniorPayout, totalValueUsd - jrPrincipalUsd);
        assertEq(juniorPayout, jrPrincipalUsd);
    }

    function test_CalculatePayouts_ErosionCondition() public view {
        uint256 jrPrincipalUsd = 30e18;
        uint256 srFloorUsd = 70.231e18;
        uint256 srTargetUsd = 70.35e18;
        uint256 totalValueUsd = 100e18;

        (uint256 seniorPayout, uint256 juniorPayout) =
            settlementModel.calculatePayouts(totalValueUsd, jrPrincipalUsd, srFloorUsd, srTargetUsd);
        assertEq(seniorPayout, srFloorUsd);
        assertEq(juniorPayout, totalValueUsd - srFloorUsd);
    }

    function test_CalculatePayouts_JuniorWipedOut() public view {
        uint256 jrPrincipalUsd = 30e18;
        uint256 srFloorUsd = 70.231e18;
        uint256 srTargetUsd = 70.35e18;
        uint256 totalValueUsd = 60e18;

        (uint256 seniorPayout, uint256 juniorPayout) =
            settlementModel.calculatePayouts(totalValueUsd, jrPrincipalUsd, srFloorUsd, srTargetUsd);
        assertEq(seniorPayout, totalValueUsd);
        assertEq(juniorPayout, 0);
    }

    function test_CalculatePayouts_TotalLoss() public view {
        uint256 jrPrincipalUsd = 30e18;
        uint256 srFloorUsd = 70.231e18;
        uint256 srTargetUsd = 70.35e18;
        uint256 totalValueUsd = 0;

        (uint256 seniorPayout, uint256 juniorPayout) =
            settlementModel.calculatePayouts(totalValueUsd, jrPrincipalUsd, srFloorUsd, srTargetUsd);
        assertEq(seniorPayout, 0);
        assertEq(juniorPayout, 0);
    }

    function test_CalculatePayouts_ExactBoundaryTargetPlusJunior() public view {
        uint256 jrPrincipalUsd = 30e18;
        uint256 srFloorUsd = 70.231e18;
        uint256 srTargetUsd = 70.35e18;
        uint256 totalValueUsd = srTargetUsd + jrPrincipalUsd;

        (uint256 seniorPayout, uint256 juniorPayout) =
            settlementModel.calculatePayouts(totalValueUsd, jrPrincipalUsd, srFloorUsd, srTargetUsd);
        assertEq(seniorPayout, srTargetUsd);
        assertEq(juniorPayout, jrPrincipalUsd);
    }

    function test_CalculatePayouts_ExactBoundaryFloorPlusJunior() public view {
        uint256 jrPrincipalUsd = 30e18;
        uint256 srFloorUsd = 70.231e18;
        uint256 srTargetUsd = 70.35e18;
        uint256 totalValueUsd = srFloorUsd + jrPrincipalUsd;

        (uint256 seniorPayout, uint256 juniorPayout) =
            settlementModel.calculatePayouts(totalValueUsd, jrPrincipalUsd, srFloorUsd, srTargetUsd);
        assertEq(seniorPayout, srFloorUsd);
        assertEq(juniorPayout, jrPrincipalUsd);
    }

    function test_CalculateRates_OneToOneRates() public view {
        (uint256 srRate, uint256 jrRate) = settlementModel.calculateRates(70e18, 30e18, 1e18, 100e18, 0.7e18);
        assertEq(srRate, ONE);
        assertEq(jrRate, ONE);
    }

    function test_CalculateRates_ZeroJuniorPayout() public view {
        (uint256 srRate, uint256 jrRate) = settlementModel.calculateRates(70e18, 0, 1e18, 100e18, 0.7e18);
        assertEq(srRate, ONE);
        assertEq(jrRate, 0);
    }

    function test_CalculateSettlement_SurplusScenario() public {
        SettlementRatioModel.SettlementParams memory params = _defaultParams();
        params.maturityPrice = 1.01e18;

        SettlementRatioModel.SettlementResult memory result = settlementModel.calculateSettlement(params);
        assertLt(result.srRateUA, ONE);
        assertGt(result.jrRateUA, ONE);
        _assertNoOverDistribution(params.uaQuantity, params.seniorRatio, result.srRateUA, result.jrRateUA);
    }

    function test_CalculateSettlement_CompressionScenario() public {
        SettlementRatioModel.SettlementParams memory params = _defaultParams();
        params.maturityPrice = 1.003e18;

        SettlementRatioModel.SettlementResult memory result = settlementModel.calculateSettlement(params);
        assertGt(result.srRateUA, ONE);
        _assertNoOverDistribution(params.uaQuantity, params.seniorRatio, result.srRateUA, result.jrRateUA);
    }

    function test_CalculateSettlement_ErosionScenario() public {
        SettlementRatioModel.SettlementParams memory params = _defaultParams();
        params.maturityPrice = 1e18;

        SettlementRatioModel.SettlementResult memory result = settlementModel.calculateSettlement(params);
        _assertNoOverDistribution(params.uaQuantity, params.seniorRatio, result.srRateUA, result.jrRateUA);
    }

    function test_CalculateSettlement_JuniorWipeoutScenario() public {
        SettlementRatioModel.SettlementParams memory params = _defaultParams();
        params.maturityPrice = 0.7e18;

        SettlementRatioModel.SettlementResult memory result = settlementModel.calculateSettlement(params);
        assertEq(result.jrRateUA, 0);
        _assertNoOverDistribution(params.uaQuantity, params.seniorRatio, result.srRateUA, result.jrRateUA);
    }

    function test_CalculateSettlement_SevereLossScenario() public {
        SettlementRatioModel.SettlementParams memory params = _defaultParams();
        params.maturityPrice = 0.5e18;

        SettlementRatioModel.SettlementResult memory result = settlementModel.calculateSettlement(params);
        assertEq(result.jrRateUA, 0);
        _assertNoOverDistribution(params.uaQuantity, params.seniorRatio, result.srRateUA, result.jrRateUA);
    }

    function test_CalculateSettlement_SixDecimalQuantity() public {
        SettlementRatioModel.SettlementParams memory params = _defaultParams();
        params.uaQuantity = 100e6;
        params.maturityPrice = 1.01e18;

        SettlementRatioModel.SettlementResult memory result = settlementModel.calculateSettlement(params);
        assertGt(result.srRateUA, 0);
        assertGt(result.jrRateUA, 0);
        _assertNoOverDistribution(params.uaQuantity, params.seniorRatio, result.srRateUA, result.jrRateUA);
    }

    function test_CalculateSettlement_EightDecimalQuantity() public {
        SettlementRatioModel.SettlementParams memory params = _defaultParams();
        params.uaQuantity = 100e8;
        params.maturityPrice = 1.01e18;

        SettlementRatioModel.SettlementResult memory result = settlementModel.calculateSettlement(params);
        assertGt(result.srRateUA, 0);
        assertGt(result.jrRateUA, 0);
        _assertNoOverDistribution(params.uaQuantity, params.seniorRatio, result.srRateUA, result.jrRateUA);
    }

    function test_CalculateSettlement_SixDecimalQuantityErosion() public {
        SettlementRatioModel.SettlementParams memory params = _defaultParams();
        params.uaQuantity = 100e6;
        params.maturityPrice = 1e18;

        SettlementRatioModel.SettlementResult memory result = settlementModel.calculateSettlement(params);
        _assertNoOverDistribution(params.uaQuantity, params.seniorRatio, result.srRateUA, result.jrRateUA);
    }

    function test_CalculateSettlement_EightDecimalQuantityJuniorWipeout() public {
        SettlementRatioModel.SettlementParams memory params = _defaultParams();
        params.uaQuantity = 100e8;
        params.maturityPrice = 0.7e18;

        SettlementRatioModel.SettlementResult memory result = settlementModel.calculateSettlement(params);
        assertEq(result.jrRateUA, 0);
        _assertNoOverDistribution(params.uaQuantity, params.seniorRatio, result.srRateUA, result.jrRateUA);
    }

    function test_CalculateSettlement_NoOverDistributionAcrossPrices() public {
        uint256[9] memory prices = [uint256(0.5e18), 0.7e18, 0.9e18, 1e18, 1.003e18, 1.005e18, 1.01e18, 1.1e18, 1.5e18];

        for (uint256 i = 0; i < prices.length; i++) {
            SettlementRatioModel.SettlementParams memory params = _defaultParams();
            params.maturityPrice = prices[i];

            SettlementRatioModel.SettlementResult memory result = settlementModel.calculateSettlement(params);
            _assertNoOverDistribution(params.uaQuantity, params.seniorRatio, result.srRateUA, result.jrRateUA);
        }
    }

    function test_CalculateSettlement_NoOverDistributionAcrossRatios() public {
        uint256[6] memory ratios = [uint256(0.1e18), 0.3e18, 0.5e18, 0.7e18, 0.9e18, 0.99e18];

        for (uint256 i = 0; i < ratios.length; i++) {
            SettlementRatioModel.SettlementParams memory params = _defaultParams();
            params.seniorRatio = ratios[i];
            params.maturityPrice = 1.01e18;

            SettlementRatioModel.SettlementResult memory result = settlementModel.calculateSettlement(params);
            _assertNoOverDistribution(params.uaQuantity, params.seniorRatio, result.srRateUA, result.jrRateUA);
        }
    }

    function test_RevertWhen_MaturityPriceIsZero() public {
        SettlementRatioModel.SettlementParams memory params = _defaultParams();
        params.maturityPrice = 0;

        vm.expectRevert(SettlementRatioModel.SettlementZeroPrice.selector);
        settlementModel.calculateSettlement(params);
    }

    function test_RevertWhen_InitialPriceIsZero() public {
        SettlementRatioModel.SettlementParams memory params = _defaultParams();
        params.initialPrice = 0;

        vm.expectRevert(SettlementRatioModel.SettlementZeroPrice.selector);
        settlementModel.calculateSettlement(params);
    }

    function test_RevertWhen_UaQuantityIsZero() public {
        SettlementRatioModel.SettlementParams memory params = _defaultParams();
        params.uaQuantity = 0;

        vm.expectRevert(SettlementRatioModel.SettlementZeroQuantity.selector);
        settlementModel.calculateSettlement(params);
    }

    function test_RevertWhen_SeniorRatioIsZero() public {
        SettlementRatioModel.SettlementParams memory params = _defaultParams();
        params.seniorRatio = 0;

        vm.expectRevert(SettlementRatioModel.SettlementInvalidRatio.selector);
        settlementModel.calculateSettlement(params);
    }

    function test_RevertWhen_SeniorRatioIsOne() public {
        SettlementRatioModel.SettlementParams memory params = _defaultParams();
        params.seniorRatio = 1e18;

        vm.expectRevert(SettlementRatioModel.SettlementInvalidRatio.selector);
        settlementModel.calculateSettlement(params);
    }

    function test_RevertWhen_FloorExceedsTarget() public {
        SettlementRatioModel.SettlementParams memory params = _defaultParams();
        params.seniorFloor = 0.01e18;
        params.seniorTarget = 0.005e18;

        vm.expectRevert(SettlementRatioModel.SettlementInvalidYieldRange.selector);
        settlementModel.calculateSettlement(params);
    }
}
