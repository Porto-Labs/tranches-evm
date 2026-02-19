// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import { Test } from "forge-std/Test.sol";
import { TrancheMarket } from "src/core/TrancheMarket.sol";
import { ERC20Mock, ERC20Mock6Decimals, ERC20Mock8Decimals } from "../mocks/ERC20Mock.sol";
import { MockChainlinkAggregator } from "../mocks/MockChainlinkAggregator.sol";
import { SettlementRatioModelMock } from "../mocks/SettlementRatioModelMock.sol";
import { ITrancheMarket } from "src/interfaces/ITrancheMarket.sol";
import { SettlementRatioModel } from "src/settlement/SettlementRatioModel.sol";

contract TrancheMarketFinalizeTest is Test {
    TrancheMarket public market;
    ERC20Mock public ua;
    MockChainlinkAggregator public oracle;

    address public admin;
    address public user;

    uint256 constant ONE = 1e18;
    uint256 constant MONTH = 30 days;

    function setUp() public {
        admin = makeAddr("admin");
        user = makeAddr("user");

        ua = new ERC20Mock("Underlying Asset", "UA");
        oracle = new MockChainlinkAggregator(8, "UA / USD");
        oracle.setRoundData(100_000_000, block.timestamp);

        TrancheMarket.MarketParams memory params = _defaultMarketParams();
        market = new TrancheMarket(params);

        ua.mint(user, 1000e18);
        vm.prank(user);
        ua.approve(address(market), 1000e18);

        vm.prank(user);
        market.tranche(100e18, user);

        vm.warp(block.timestamp + MONTH + 1);
        oracle.setRoundData(100_000_000, block.timestamp);
    }

    function _defaultMarketParams() internal view returns (TrancheMarket.MarketParams memory) {
        return TrancheMarket.MarketParams({
            ua: address(ua),
            poolFee: 500,
            matureAt: block.timestamp + MONTH,
            seniorRatio: 0.7e18,
            admin: admin,
            priceFeed: address(oracle),
            seniorFloor: 0.0033e18,
            seniorTarget: 0.005e18,
            liquidationEnabled: false,
            liquidationBuffer: 0,
            liquidationReward: 0
        });
    }

    function test_Finalize_WithValidReferencePrice() public {
        vm.prank(admin);
        market.finalize(1e18, 0.01e18);

        assertTrue(market.finalized());
        assertGt(market.srRateUA(), 0);
    }

    function test_Finalize_AcceptPriceWithinDeviation() public {
        oracle.setRoundData(105_000_000, block.timestamp);

        vm.prank(admin);
        market.finalize(1e18, 0.1e18);

        assertTrue(market.finalized());
    }

    function test_Finalize_HandleNegativeDeviation() public {
        oracle.setRoundData(95_000_000, block.timestamp);

        vm.prank(admin);
        market.finalize(1e18, 0.1e18);

        assertTrue(market.finalized());
    }

    function test_Finalize_EmitEvent() public {
        oracle.setRoundData(101_000_000, block.timestamp);

        vm.prank(admin);
        vm.expectEmit(false, false, false, false);
        emit ITrancheMarket.Finalize(1.01e18, 1e18, 0, 0);
        market.finalize(1e18, 0.05e18);
    }

    function test_RevertWhen_Finalize_DeviationExceeded() public {
        oracle.setRoundData(110_000_000, block.timestamp);

        vm.prank(admin);
        vm.expectRevert(ITrancheMarket.OraclePriceDeviationExceeded.selector);
        market.finalize(1e18, 0.05e18);
    }

    function test_RevertWhen_Finalize_DeviationThresholdExceeds100() public {
        vm.prank(admin);
        vm.expectRevert(ITrancheMarket.OracleInvalidDeviationThreshold.selector);
        market.finalize(1e18, 1.01e18);
    }

    function test_RevertWhen_Finalize_ReferencePriceZero() public {
        vm.prank(admin);
        vm.expectRevert(SettlementRatioModel.SettlementZeroPrice.selector);
        market.finalize(0, 0.01e18);
    }

    function test_RevertWhen_Finalize_OracleReturnsZeroPrice() public {
        oracle.setRoundData(0, block.timestamp);

        vm.prank(admin);
        vm.expectRevert(ITrancheMarket.OracleInvalidPrice.selector);
        market.finalize(1e18, 0.01e18);
    }

    function test_RevertWhen_Finalize_OracleReturnsNegativePrice() public {
        oracle.setRoundData(-100_000_000, block.timestamp);

        vm.prank(admin);
        vm.expectRevert(ITrancheMarket.OracleInvalidPrice.selector);
        market.finalize(1e18, 0.01e18);
    }

    function test_RevertWhen_Finalize_OraclePriceStale() public {
        oracle.setRoundData(100_000_000, block.timestamp - 25 hours);

        vm.prank(admin);
        vm.expectRevert(ITrancheMarket.OracleStalePrice.selector);
        market.finalize(1e18, 0.01e18);
    }

    function test_RevertWhen_Finalize_BeforeExpiry() public {
        TrancheMarket freshMarket = new TrancheMarket(_defaultMarketParams());

        vm.prank(admin);
        vm.expectRevert(ITrancheMarket.TrancheMarketNotMature.selector);
        freshMarket.finalize(1e18, 0.01e18);
    }

    function test_RevertWhen_Finalize_AlreadyFinalized() public {
        vm.prank(admin);
        market.finalize(1e18, 0.01e18);

        vm.prank(admin);
        vm.expectRevert(ITrancheMarket.TrancheMarketAlreadyFinalized.selector);
        market.finalize(1e18, 0.01e18);
    }

    function test_RevertWhen_Finalize_NonAdmin() public {
        vm.prank(user);
        vm.expectRevert(ITrancheMarket.OnlyAdmin.selector);
        market.finalize(1e18, 0.01e18);
    }

    function test_Waterfall_SurplusScenario() public {
        oracle.setRoundData(101_000_000, block.timestamp);

        vm.prank(admin);
        market.finalize(1.01e18, 0.01e18);

        assertLt(market.srRateUA(), ONE);
        assertGt(market.jrRateUA(), ONE);
    }

    function test_Waterfall_CompressionScenario() public {
        oracle.setRoundData(100_400_000, block.timestamp);

        vm.prank(admin);
        market.finalize(1.004e18, 0.01e18);

        assertGt(market.srRateUA(), 0);
        assertGt(market.jrRateUA(), 0);
    }

    function test_Waterfall_ErosionScenario() public {
        vm.prank(admin);
        market.finalize(1e18, 0.01e18);

        assertGt(market.srRateUA(), 0);
        assertLt(market.jrRateUA(), ONE);
    }

    function test_Waterfall_SevereLossScenario() public {
        oracle.setRoundData(70_000_000, block.timestamp);

        vm.prank(admin);
        market.finalize(0.7e18, 0.01e18);

        assertEq(market.jrRateUA(), 0);
        assertGt(market.srRateUA(), 0);
    }

    function test_PreviewSettlement_ReturnProjectedRates() public {
        oracle.setRoundData(101_000_000, block.timestamp);

        (uint256 srRate, uint256 jrRate, uint256 oraclePrice) = market.previewSettlement();

        assertEq(oraclePrice, 1.01e18);
        assertGt(srRate, 0);
        assertGt(jrRate, 0);
    }

    function test_PreviewSettlement_DoesNotModifyState() public {
        oracle.setRoundData(101_000_000, block.timestamp);

        market.previewSettlement();
        market.previewSettlement();

        assertFalse(market.finalized());
        assertEq(market.srRateUA(), 0);
        assertEq(market.jrRateUA(), 0);
    }

    function test_PreviewSettlement_MatchFinalizeRates() public {
        oracle.setRoundData(101_000_000, block.timestamp);

        (uint256 previewSrRate, uint256 previewJrRate, uint256 previewPrice) = market.previewSettlement();

        vm.prank(admin);
        market.finalize(previewPrice, 0.01e18);

        assertEq(market.srRateUA(), previewSrRate);
        assertEq(market.jrRateUA(), previewJrRate);
    }

    function test_RevertWhen_PreviewSettlement_InvalidOraclePrice() public {
        oracle.setRoundData(0, block.timestamp);

        vm.expectRevert(ITrancheMarket.OracleInvalidPrice.selector);
        market.previewSettlement();
    }

    function test_RevertWhen_PreviewSettlement_StaleOraclePrice() public {
        oracle.setRoundData(100_000_000, block.timestamp - 25 hours);

        vm.expectRevert(ITrancheMarket.OracleStalePrice.selector);
        market.previewSettlement();
    }

    function test_Finalize_Ua6_SurplusScenario() public {
        ERC20Mock6Decimals _ua = new ERC20Mock6Decimals("Underlying Asset", "UA");
        MockChainlinkAggregator _oracle = new MockChainlinkAggregator(18, "UA / USD");
        _oracle.setRoundData(int256(1e18), block.timestamp);

        TrancheMarket.MarketParams memory params = TrancheMarket.MarketParams({
            ua: address(_ua),
            poolFee: 500,
            matureAt: block.timestamp + MONTH,
            seniorRatio: 0.725e18,
            admin: admin,
            priceFeed: address(_oracle),
            seniorFloor: 0.04e18,
            seniorTarget: 0.06e18,
            liquidationEnabled: false,
            liquidationBuffer: 0,
            liquidationReward: 0
        });
        TrancheMarket _market = new TrancheMarket(params);

        uint256 totalUa = 10_000_000e6; // $10,000,000
        _ua.mint(user, totalUa);
        vm.startPrank(user);
        _ua.approve(address(_market), totalUa);
        _market.tranche(totalUa, user);
        vm.stopPrank();

        uint256 maturityPrice = 1.065e18; // // Price up 6.5%
        vm.warp(block.timestamp + MONTH + 1);
        _oracle.setRoundData(int256(maturityPrice), block.timestamp);

        vm.prank(admin);
        _market.finalize(maturityPrice, 0.01e18);

        SettlementRatioModelMock model = new SettlementRatioModelMock();

        (uint256 srPrincipalUsd, uint256 jrPrincipalUsd) =
            model.calculatePrincipals(totalUa, _market.initialPrice(), _market.seniorRatio());

        (uint256 srFloorUsd, uint256 srTargetUsd) =
            model.calculateThresholds(srPrincipalUsd, _market.seniorFloor(), _market.seniorTarget());

        uint256 totalValueUsd = totalUa * maturityPrice / 1e18;
        (uint256 srUsdPayout, uint256 jrUsdPayout) = model.calculatePayouts(totalValueUsd, jrPrincipalUsd, srFloorUsd, srTargetUsd);

        assertApproxEqRel(srUsdPayout, 7_685_000e6, 0.001e18);
        assertApproxEqRel(jrUsdPayout, 2_965_000e6, 0.001e18);

        // Required for 6% target: $435,000 = 435000e6
        assertApproxEqRel(srUsdPayout - srPrincipalUsd, 435_000e6, 0.001e18);

        // Residual Income: $215,000 = 215000e6
        assertApproxEqRel(jrUsdPayout - jrPrincipalUsd, 215_000e6, 0.001e18);

        uint256 jrApy = (jrUsdPayout - jrPrincipalUsd) * 1e18 / jrPrincipalUsd;
        assertApproxEqRel(jrApy, 0.0782e18, 0.001e18); // Junior Yield: ~7.82%
    }

    function test_Finalize_Ua8_SurplusScenario() public {
        ERC20Mock8Decimals _ua = new ERC20Mock8Decimals("Underlying Asset", "UA");
        MockChainlinkAggregator _oracle = new MockChainlinkAggregator(18, "UA / USD");
        _oracle.setRoundData(int256(1e18), block.timestamp);

        TrancheMarket.MarketParams memory params = TrancheMarket.MarketParams({
            ua: address(_ua),
            poolFee: 500,
            matureAt: block.timestamp + MONTH,
            seniorRatio: 0.725e18,
            admin: admin,
            priceFeed: address(_oracle),
            seniorFloor: 0.04e18,
            seniorTarget: 0.06e18,
            liquidationEnabled: false,
            liquidationBuffer: 0,
            liquidationReward: 0
        });
        TrancheMarket _market = new TrancheMarket(params);
        
        uint256 totalUa = 10_000_000e8;
        _ua.mint(user, totalUa);
        vm.startPrank(user);
        _ua.approve(address(_market), totalUa);
        _market.tranche(totalUa, user);
        vm.stopPrank();

        uint256 maturityPrice = 1.075e18; // Price up 7.5%
        vm.warp(block.timestamp + MONTH + 1);
        _oracle.setRoundData(int256(maturityPrice), block.timestamp);

        vm.prank(admin);
        _market.finalize(maturityPrice, 0.01e18);

        SettlementRatioModelMock model = new SettlementRatioModelMock();

        (uint256 srPrincipalUsd, uint256 jrPrincipalUsd) =
            model.calculatePrincipals(totalUa, _market.initialPrice(), _market.seniorRatio());

        (uint256 srFloorUsd, uint256 srTargetUsd) =
            model.calculateThresholds(srPrincipalUsd, _market.seniorFloor(), _market.seniorTarget());

        uint256 totalValueUsd = totalUa * maturityPrice / 1e18;
        (uint256 srUsdPayout, uint256 jrUsdPayout) =
            model.calculatePayouts(totalValueUsd, jrPrincipalUsd, srFloorUsd, srTargetUsd);

        assertApproxEqRel(srUsdPayout, 7_685_000e8, 0.001e18);
        assertApproxEqRel(jrUsdPayout, 3_065_000e8, 0.001e18);

        // Required for 6% target: $435,000 = 435_000e8
        assertApproxEqRel(srUsdPayout - srPrincipalUsd, 435_000e8, 0.001e18);

        // Residual Income: $315,000 = 315_000e8
        assertApproxEqRel(jrUsdPayout - jrPrincipalUsd, 315_000e8, 0.001e18);

        uint256 jrApy = (jrUsdPayout - jrPrincipalUsd) * 1e18 / jrPrincipalUsd;
        assertApproxEqRel(jrApy, 0.1145e18, 0.001e18); // Junior Yield: ~11.45%
    }

    function test_Finalize_Ua8_100InitPrice_SurplusScenario() public {
        ERC20Mock8Decimals _ua = new ERC20Mock8Decimals("Underlying Asset", "UA");
        MockChainlinkAggregator _oracle = new MockChainlinkAggregator(18, "UA / USD");
        _oracle.setRoundData(int256(100e18), block.timestamp);

        TrancheMarket.MarketParams memory params = TrancheMarket.MarketParams({
            ua: address(_ua),
            poolFee: 500,
            matureAt: block.timestamp + MONTH,
            seniorRatio: 0.725e18,
            admin: admin,
            priceFeed: address(_oracle),
            seniorFloor: 0.04e18,
            seniorTarget: 0.06e18,
            liquidationEnabled: false,
            liquidationBuffer: 0,
            liquidationReward: 0
        });
        TrancheMarket _market = new TrancheMarket(params);

        // ($100/token), pool = $10M 
        // totalUa = 100_000e8 (100k tokens × $100)
        uint256 totalUa = 100_000e8; // $10,000,000
        _ua.mint(user, totalUa);
        vm.startPrank(user);
        _ua.approve(address(_market), totalUa);
        _market.tranche(totalUa, user);
        vm.stopPrank();

        uint256 maturityPrice = 108.5e18; // Price up 8.5%
        vm.warp(block.timestamp + MONTH + 1);
        _oracle.setRoundData(int256(maturityPrice), block.timestamp);

        vm.prank(admin);
        _market.finalize(maturityPrice, 0.01e18);

        SettlementRatioModelMock model = new SettlementRatioModelMock();

        (uint256 srPrincipalUsd, uint256 jrPrincipalUsd) =
            model.calculatePrincipals(totalUa, _market.initialPrice(), _market.seniorRatio());

        (uint256 srFloorUsd, uint256 srTargetUsd) =
            model.calculateThresholds(srPrincipalUsd, _market.seniorFloor(), _market.seniorTarget());

        uint256 totalValueUsd = totalUa * maturityPrice / 1e18;
        (uint256 srUsdPayout, uint256 jrUsdPayout) =
            model.calculatePayouts(totalValueUsd, jrPrincipalUsd, srFloorUsd, srTargetUsd);

        assertApproxEqRel(srUsdPayout, 7_685_000e8, 0.001e18);
        assertApproxEqRel(jrUsdPayout, 3_165_000e8, 0.001e18);

        // Required for 6% target: $435,000 = 435_000e8
        assertApproxEqRel(srUsdPayout - srPrincipalUsd, 435_000e8, 0.001e18);

        // Residual Income: $415,000 = 415_000e8
        assertApproxEqRel(jrUsdPayout - jrPrincipalUsd, 415_000e8, 0.001e18);

        uint256 jrApy = (jrUsdPayout - jrPrincipalUsd) * 1e18 / jrPrincipalUsd;
        assertApproxEqRel(jrApy, 0.1509e18, 0.001e18); // Junior Yield: ~15.09%
    }

    function test_Finalize_Ua18_10kInitPrice_SurplusScenario() public {
        ERC20Mock _ua = new ERC20Mock("Underlying Asset", "UA");
        MockChainlinkAggregator _oracle = new MockChainlinkAggregator(18, "UA / USD");
        _oracle.setRoundData(int256(10_000e18), block.timestamp);

        TrancheMarket.MarketParams memory params = TrancheMarket.MarketParams({
            ua: address(_ua),
            poolFee: 500,
            matureAt: block.timestamp + MONTH,
            seniorRatio: 0.725e18,
            admin: admin,
            priceFeed: address(_oracle),
            seniorFloor: 0.04e18,
            seniorTarget: 0.06e18,
            liquidationEnabled: false,
            liquidationBuffer: 0,
            liquidationReward: 0
        });
        TrancheMarket _market = new TrancheMarket(params);

        // ($10,000/token), pool = $10M
        // totalUa = 1_000e18 (1k tokens × $10,000)
        uint256 totalUa = 1_000e18; // $10,000,000
        _ua.mint(user, totalUa);
        vm.startPrank(user);
        _ua.approve(address(_market), totalUa);
        _market.tranche(totalUa, user);
        vm.stopPrank();

        uint256 maturityPrice = 10_950e18; // Price up 9.5%
        vm.warp(block.timestamp + MONTH + 1);
        _oracle.setRoundData(int256(maturityPrice), block.timestamp);

        vm.prank(admin);
        _market.finalize(maturityPrice, 0.01e18);

        SettlementRatioModelMock model = new SettlementRatioModelMock();

        (uint256 srPrincipalUsd, uint256 jrPrincipalUsd) =
            model.calculatePrincipals(totalUa, _market.initialPrice(), _market.seniorRatio());

        (uint256 srFloorUsd, uint256 srTargetUsd) =
            model.calculateThresholds(srPrincipalUsd, _market.seniorFloor(), _market.seniorTarget());

        uint256 totalValueUsd = totalUa * maturityPrice / 1e18;
        (uint256 srUsdPayout, uint256 jrUsdPayout) =
            model.calculatePayouts(totalValueUsd, jrPrincipalUsd, srFloorUsd, srTargetUsd);

        assertApproxEqRel(srUsdPayout, 7_685_000e18, 0.001e18);
        assertApproxEqRel(jrUsdPayout, 3_265_000e18, 0.001e18);

        // Required for 6% target: $435,000 = 435_000e18
        assertApproxEqRel(srUsdPayout - srPrincipalUsd, 435_000e18, 0.001e18);

        // Residual Income: $515,000 = 515_000e18
        assertApproxEqRel(jrUsdPayout - jrPrincipalUsd, 515_000e18, 0.001e18);

        uint256 jrApy = (jrUsdPayout - jrPrincipalUsd) * 1e18 / jrPrincipalUsd;
        assertApproxEqRel(jrApy, 0.1873e18, 0.001e18); // Junior Yield: ~18.73%
    }

    function test_Finalize_Ua8_8dOracle_1kInitPrice_SurplusScenario() public {
        ERC20Mock8Decimals _ua = new ERC20Mock8Decimals("Underlying Asset", "UA");
        MockChainlinkAggregator _oracle = new MockChainlinkAggregator(8, "UA / USD");
        _oracle.setRoundData(int256(1_000e8), block.timestamp);

        TrancheMarket.MarketParams memory params = TrancheMarket.MarketParams({
            ua: address(_ua),
            poolFee: 500,
            matureAt: block.timestamp + MONTH,
            seniorRatio: 0.725e18,
            admin: admin,
            priceFeed: address(_oracle),
            seniorFloor: 0.04e18,
            seniorTarget: 0.06e18,
            liquidationEnabled: false,
            liquidationBuffer: 0,
            liquidationReward: 0
        });
        TrancheMarket _market = new TrancheMarket(params);

        // ($1,000/token), pool = $10M
        // totalUa = 10_000e8 (10k tokens × $1,000)
        uint256 totalUa = 10_000e8; // $10,000,000
        _ua.mint(user, totalUa);
        vm.startPrank(user);
        _ua.approve(address(_market), totalUa);
        _market.tranche(totalUa, user);
        vm.stopPrank();

        uint256 maturityPrice = 1_105e18; // Price up 10.5%
        vm.warp(block.timestamp + MONTH + 1);
        _oracle.setRoundData(int256(1_105e8), block.timestamp);

        vm.prank(admin);
        _market.finalize(maturityPrice, 0.01e18);

        SettlementRatioModelMock model = new SettlementRatioModelMock();

        (uint256 srPrincipalUsd, uint256 jrPrincipalUsd) =
            model.calculatePrincipals(totalUa, _market.initialPrice(), _market.seniorRatio());

        (uint256 srFloorUsd, uint256 srTargetUsd) =
            model.calculateThresholds(srPrincipalUsd, _market.seniorFloor(), _market.seniorTarget());

        uint256 totalValueUsd = totalUa * maturityPrice / 1e18;
        (uint256 srUsdPayout, uint256 jrUsdPayout) =
            model.calculatePayouts(totalValueUsd, jrPrincipalUsd, srFloorUsd, srTargetUsd);

        assertApproxEqRel(srUsdPayout, 7_685_000e8, 0.001e18);
        assertApproxEqRel(jrUsdPayout, 3_365_000e8, 0.001e18);

        // Required for 6% target: $435,000 = 435_000e8
        assertApproxEqRel(srUsdPayout - srPrincipalUsd, 435_000e8, 0.001e18);

        // Residual Income: $615,000 = 615_000e8
        assertApproxEqRel(jrUsdPayout - jrPrincipalUsd, 615_000e8, 0.001e18);

        uint256 jrApy = (jrUsdPayout - jrPrincipalUsd) * 1e18 / jrPrincipalUsd;
        assertApproxEqRel(jrApy, 0.2236e18, 0.001e18); // Junior Yield: ~22.36%
    }

    function test_Finalize_Ua8_8dOracle_ErosionScenario() public {
        ERC20Mock8Decimals _ua = new ERC20Mock8Decimals("Underlying Asset", "UA");
        MockChainlinkAggregator _oracle = new MockChainlinkAggregator(8, "UA / USD");
        _oracle.setRoundData(int256(10e8), block.timestamp);

        TrancheMarket.MarketParams memory params = TrancheMarket.MarketParams({
            ua: address(_ua),
            poolFee: 500,
            matureAt: block.timestamp + MONTH,
            seniorRatio: 0.725e18,
            admin: admin,
            priceFeed: address(_oracle),
            seniorFloor: 0.04e18,
            seniorTarget: 0.06e18,
            liquidationEnabled: false,
            liquidationBuffer: 0,
            liquidationReward: 0
        });
        TrancheMarket _market = new TrancheMarket(params);

        // ($10/token), pool = $10M
        // totalUa = 1_000_000e8 (1M tokens × $10)
        uint256 totalUa = 1_000_000e8; // $10,000,000
        _ua.mint(user, totalUa);
        vm.startPrank(user);
        _ua.approve(address(_market), totalUa);
        _market.tranche(totalUa, user);
        vm.stopPrank();

        // Portfolio: -15% price loss + 4% yield income → net $8.90/token
        uint256 maturityPrice = 8.9e18;
        vm.warp(block.timestamp + MONTH + 1);
        _oracle.setRoundData(int256(890_000_000), block.timestamp);

        vm.prank(admin);
        _market.finalize(maturityPrice, 0.01e18);

        SettlementRatioModelMock model = new SettlementRatioModelMock();

        (uint256 srPrincipalUsd, uint256 jrPrincipalUsd) =
            model.calculatePrincipals(totalUa, _market.initialPrice(), _market.seniorRatio());

        (uint256 srFloorUsd, uint256 srTargetUsd) =
            model.calculateThresholds(srPrincipalUsd, _market.seniorFloor(), _market.seniorTarget());

        uint256 totalValueUsd = totalUa * maturityPrice / 1e18;
        (uint256 srUsdPayout, uint256 jrUsdPayout) =
            model.calculatePayouts(totalValueUsd, jrPrincipalUsd, srFloorUsd, srTargetUsd);

        // Condition C (Junior Erosion): senior protected at floor, junior absorbs all loss
        // Senior: fully solvent — principal + 4% floor yield = $7,540,000
        assertEq(srUsdPayout, srFloorUsd);
        assertApproxEqRel(srUsdPayout, 7_540_000e8, 0.001e18);

        // Junior: absorbs portfolio shock — recovers $1,360,000 of $2,750,000 principal
        assertApproxEqRel(jrUsdPayout, 1_360_000e8, 0.001e18);

        // Junior loss: $1,390,000 — approximately -50.55% ROI
        uint256 jrLossRatio = (jrPrincipalUsd - jrUsdPayout) * 1e18 / jrPrincipalUsd;
        assertApproxEqRel(jrLossRatio, 0.5055e18, 0.001e18); // Junior Loss: ~50.55%
    }


    function test_Finalize_Ua6_100InitPrice_CompressionScenario() public {
        ERC20Mock6Decimals _ua = new ERC20Mock6Decimals("Underlying Asset", "UA");
        MockChainlinkAggregator _oracle = new MockChainlinkAggregator(18, "UA / USD");
        _oracle.setRoundData(int256(100e18), block.timestamp);

        TrancheMarket.MarketParams memory params = TrancheMarket.MarketParams({
            ua: address(_ua),
            poolFee: 500,
            matureAt: block.timestamp + MONTH,
            seniorRatio: 0.725e18,
            admin: admin,
            priceFeed: address(_oracle),
            seniorFloor: 0.04e18,
            seniorTarget: 0.06e18,
            liquidationEnabled: false,
            liquidationBuffer: 0,
            liquidationReward: 0
        });
        TrancheMarket _market = new TrancheMarket(params);

        // ($100/token), pool = $10M
        // totalUa = 100_000e6 (100k tokens × $100)
        uint256 totalUa = 100_000e6; // $10,000,000
        _ua.mint(user, totalUa);
        vm.startPrank(user);
        _ua.approve(address(_market), totalUa);
        _market.tranche(totalUa, user);
        vm.stopPrank();

        uint256 maturityPrice = 103e18; // Price up 3%
        vm.warp(block.timestamp + MONTH + 1);
        _oracle.setRoundData(int256(maturityPrice), block.timestamp);

        vm.prank(admin);
        _market.finalize(maturityPrice, 0.01e18);

        SettlementRatioModelMock model = new SettlementRatioModelMock();

        (uint256 srPrincipalUsd, uint256 jrPrincipalUsd) =
            model.calculatePrincipals(totalUa, _market.initialPrice(), _market.seniorRatio());

        (uint256 srFloorUsd, uint256 srTargetUsd) =
            model.calculateThresholds(srPrincipalUsd, _market.seniorFloor(), _market.seniorTarget());

        uint256 totalValueUsd = totalUa * maturityPrice / 1e18;
        (uint256 srUsdPayout, uint256 jrUsdPayout) =
            model.calculatePayouts(totalValueUsd, jrPrincipalUsd, srFloorUsd, srTargetUsd);

        // Condition B (Target APY Compression): senior capped at floor, junior earns residual
        // Senior earns $290,000 = exactly 4% floor yield
        assertEq(srUsdPayout, 7_540_000e6);
        assertEq(srUsdPayout - srPrincipalUsd, 290_000e6);

        uint256 srApy = (srUsdPayout - srPrincipalUsd) * 1e18 / srPrincipalUsd;
        assertEq(srApy, 0.04e18);

        // Junior earns residual: $10,000 = ~0.3636% APY
        assertEq(jrUsdPayout, 2_760_000e6);
        assertEq(jrUsdPayout - jrPrincipalUsd, 10_000e6);

        uint256 jrApy = (jrUsdPayout - jrPrincipalUsd) * 1e18 / jrPrincipalUsd;
        assertApproxEqRel(jrApy, 0.003636e18, 0.001e18); // Junior Yield: ~0.3636%
    }
}
