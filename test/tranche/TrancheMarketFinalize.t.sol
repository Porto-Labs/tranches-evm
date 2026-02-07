// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import { Test } from "forge-std/Test.sol";
import { TrancheMarket } from "src/core/TrancheMarket.sol";
import { ERC20Mock } from "../mocks/ERC20Mock.sol";
import { MockChainlinkAggregator } from "../mocks/MockChainlinkAggregator.sol";
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
        oracle.setRoundData(100000000, block.timestamp);

        TrancheMarket.MarketParams memory params = _defaultMarketParams();
        market = new TrancheMarket(params);

        ua.mint(user, 1000e18);
        vm.prank(user);
        ua.approve(address(market), 1000e18);

        vm.prank(user);
        market.tranche(100e18, user);

        vm.warp(block.timestamp + MONTH + 1);
        oracle.setRoundData(100000000, block.timestamp);
    }

    function _defaultMarketParams() internal view returns (TrancheMarket.MarketParams memory) {
        return TrancheMarket.MarketParams({
            ua: address(ua),
            poolFee: 500,
            expiry: block.timestamp + MONTH,
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
        oracle.setRoundData(105000000, block.timestamp);

        vm.prank(admin);
        market.finalize(1e18, 0.10e18);

        assertTrue(market.finalized());
    }

    function test_Finalize_HandleNegativeDeviation() public {
        oracle.setRoundData(95000000, block.timestamp);

        vm.prank(admin);
        market.finalize(1e18, 0.10e18);

        assertTrue(market.finalized());
    }

    function test_Finalize_EmitEvent() public {
        oracle.setRoundData(101000000, block.timestamp);

        vm.prank(admin);
        vm.expectEmit(false, false, false, false);
        emit ITrancheMarket.Finalize(1.01e18, 1e18, 0, 0);
        market.finalize(1e18, 0.05e18);
    }

    function test_RevertWhen_Finalize_DeviationExceeded() public {
        oracle.setRoundData(110000000, block.timestamp);

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
        oracle.setRoundData(-100000000, block.timestamp);

        vm.prank(admin);
        vm.expectRevert(ITrancheMarket.OracleInvalidPrice.selector);
        market.finalize(1e18, 0.01e18);
    }

    function test_RevertWhen_Finalize_OraclePriceStale() public {
        oracle.setRoundData(100000000, block.timestamp - 25 hours);

        vm.prank(admin);
        vm.expectRevert(ITrancheMarket.OracleStalePrice.selector);
        market.finalize(1e18, 0.01e18);
    }

    function test_RevertWhen_Finalize_BeforeExpiry() public {
        TrancheMarket freshMarket = new TrancheMarket(_defaultMarketParams());

        vm.prank(admin);
        vm.expectRevert(ITrancheMarket.TrancheMarketNotExpired.selector);
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
        oracle.setRoundData(101000000, block.timestamp);

        vm.prank(admin);
        market.finalize(1.01e18, 0.01e18);

        assertLt(market.srRateUA(), ONE);
        assertGt(market.jrRateUA(), ONE);
    }

    function test_Waterfall_CompressionScenario() public {
        oracle.setRoundData(100400000, block.timestamp);

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
        oracle.setRoundData(70000000, block.timestamp);

        vm.prank(admin);
        market.finalize(0.70e18, 0.01e18);

        assertEq(market.jrRateUA(), 0);
        assertGt(market.srRateUA(), 0);
    }

    function test_PreviewSettlement_ReturnProjectedRates() public {
        oracle.setRoundData(101000000, block.timestamp);

        (uint256 srRate, uint256 jrRate, uint256 oraclePrice) = market.previewSettlement();

        assertEq(oraclePrice, 1.01e18);
        assertGt(srRate, 0);
        assertGt(jrRate, 0);
    }

    function test_PreviewSettlement_DoesNotModifyState() public {
        oracle.setRoundData(101000000, block.timestamp);

        market.previewSettlement();
        market.previewSettlement();

        assertFalse(market.finalized());
        assertEq(market.srRateUA(), 0);
        assertEq(market.jrRateUA(), 0);
    }

    function test_PreviewSettlement_MatchFinalizeRates() public {
        oracle.setRoundData(101000000, block.timestamp);

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
        oracle.setRoundData(100000000, block.timestamp - 25 hours);

        vm.expectRevert(ITrancheMarket.OracleStalePrice.selector);
        market.previewSettlement();
    }
}
