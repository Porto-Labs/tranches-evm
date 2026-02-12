// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import { Test } from "forge-std/Test.sol";
import { TrancheMarket } from "src/core/TrancheMarket.sol";
import { ERC20Mock, ERC20Mock6Decimals, ERC20Mock8Decimals } from "../mocks/ERC20Mock.sol";
import { IERC20 } from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
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

    // ============ Decimal Combination Helpers ============

    function _deployUa(uint8 decimals_) internal returns (address) {
        if (decimals_ == 6) return address(new ERC20Mock6Decimals("UA", "UA"));
        if (decimals_ == 8) return address(new ERC20Mock8Decimals("UA", "UA"));
        return address(new ERC20Mock("UA", "UA"));
    }

    function _oraclePrice(uint8 oracleDecimals_, uint256 price1e18) internal pure returns (int256) {
        if (oracleDecimals_ < 18) {
            return int256(price1e18 / 10 ** (18 - oracleDecimals_));
        }
        return int256(price1e18);
    }

    function _amount(uint8 decimals_, uint256 wholeUnits) internal pure returns (uint256) {
        return wholeUnits * 10 ** decimals_;
    }

    function _mulDown(uint256 a, uint256 b) internal pure returns (uint256) {
        return (a * b) / ONE;
    }

    function _setupAndFinalizeDecimals(uint8 uaDec, uint8 oracleDec, uint256 maturityPrice1e18)
        internal
        returns (TrancheMarket)
    {
        address _ua = _deployUa(uaDec);

        MockChainlinkAggregator _oracle = new MockChainlinkAggregator(oracleDec, "UA / USD");
        _oracle.setRoundData(_oraclePrice(oracleDec, 1e18), block.timestamp);

        TrancheMarket.MarketParams memory params = TrancheMarket.MarketParams({
            ua: _ua,
            poolFee: 500,
            expiry: block.timestamp + MONTH,
            seniorRatio: 0.7e18,
            admin: admin,
            priceFeed: address(_oracle),
            seniorFloor: 0.0033e18,
            seniorTarget: 0.005e18,
            liquidationEnabled: false,
            liquidationBuffer: 0,
            liquidationReward: 0
        });
        TrancheMarket _market = new TrancheMarket(params);

        uint256 trancheAmount = 100 * 10 ** uaDec;
        ERC20Mock(_ua).mint(user, trancheAmount);

        vm.startPrank(user);
        IERC20(_ua).approve(address(_market), trancheAmount);
        _market.tranche(trancheAmount, user);
        vm.stopPrank();

        vm.warp(block.timestamp + MONTH + 1);
        _oracle.setRoundData(_oraclePrice(oracleDec, maturityPrice1e18), block.timestamp);

        vm.prank(admin);
        _market.finalize(maturityPrice1e18, 0.1e18);

        return _market;
    }

    function _assertConservation(TrancheMarket m) internal view {
        uint256 weightedSum = _mulDown(m.srRateUA(), m.seniorRatio()) + _mulDown(m.jrRateUA(), m.juniorRatio());
        assertApproxEqRel(weightedSum, ONE, 0.01e18);
    }

    // ============ Finalize Win (1.05) - Decimal Combinations ============

    function test_Finalize_Win_Ua6_Oracle6() public {
        TrancheMarket m = _setupAndFinalizeDecimals(6, 6, 1.05e18);
        assertTrue(m.finalized());
        assertLt(m.srRateUA(), ONE);
        assertGt(m.jrRateUA(), ONE);
        _assertConservation(m);
    }

    function test_Finalize_Win_Ua6_Oracle8() public {
        TrancheMarket m = _setupAndFinalizeDecimals(6, 8, 1.05e18);
        assertTrue(m.finalized());
        assertLt(m.srRateUA(), ONE);
        assertGt(m.jrRateUA(), ONE);
        _assertConservation(m);
    }

    function test_Finalize_Win_Ua6_Oracle18() public {
        TrancheMarket m = _setupAndFinalizeDecimals(6, 18, 1.05e18);
        assertTrue(m.finalized());
        assertLt(m.srRateUA(), ONE);
        assertGt(m.jrRateUA(), ONE);
        _assertConservation(m);
    }

    function test_Finalize_Win_Ua8_Oracle6() public {
        TrancheMarket m = _setupAndFinalizeDecimals(8, 6, 1.05e18);
        assertTrue(m.finalized());
        assertLt(m.srRateUA(), ONE);
        assertGt(m.jrRateUA(), ONE);
        _assertConservation(m);
    }

    function test_Finalize_Win_Ua8_Oracle8() public {
        TrancheMarket m = _setupAndFinalizeDecimals(8, 8, 1.05e18);
        assertTrue(m.finalized());
        assertLt(m.srRateUA(), ONE);
        assertGt(m.jrRateUA(), ONE);
        _assertConservation(m);
    }

    function test_Finalize_Win_Ua8_Oracle18() public {
        TrancheMarket m = _setupAndFinalizeDecimals(8, 18, 1.05e18);
        assertTrue(m.finalized());
        assertLt(m.srRateUA(), ONE);
        assertGt(m.jrRateUA(), ONE);
        _assertConservation(m);
    }

    function test_Finalize_Win_Ua18_Oracle6() public {
        TrancheMarket m = _setupAndFinalizeDecimals(18, 6, 1.05e18);
        assertTrue(m.finalized());
        assertLt(m.srRateUA(), ONE);
        assertGt(m.jrRateUA(), ONE);
        _assertConservation(m);
    }

    function test_Finalize_Win_Ua18_Oracle8() public {
        TrancheMarket m = _setupAndFinalizeDecimals(18, 8, 1.05e18);
        assertTrue(m.finalized());
        assertLt(m.srRateUA(), ONE);
        assertGt(m.jrRateUA(), ONE);
        _assertConservation(m);
    }

    function test_Finalize_Win_Ua18_Oracle18() public {
        TrancheMarket m = _setupAndFinalizeDecimals(18, 18, 1.05e18);
        assertTrue(m.finalized());
        assertLt(m.srRateUA(), ONE);
        assertGt(m.jrRateUA(), ONE);
        _assertConservation(m);
    }

    // ============ Finalize Loss (0.95) - Decimal Combinations ============

    function test_Finalize_Loss_Ua6_Oracle6() public {
        TrancheMarket m = _setupAndFinalizeDecimals(6, 6, 0.95e18);
        assertTrue(m.finalized());
        assertGt(m.srRateUA(), ONE);
        assertLt(m.jrRateUA(), ONE);
        assertGt(m.jrRateUA(), 0);
        _assertConservation(m);
    }

    function test_Finalize_Loss_Ua6_Oracle8() public {
        TrancheMarket m = _setupAndFinalizeDecimals(6, 8, 0.95e18);
        assertTrue(m.finalized());
        assertGt(m.srRateUA(), ONE);
        assertLt(m.jrRateUA(), ONE);
        assertGt(m.jrRateUA(), 0);
        _assertConservation(m);
    }

    function test_Finalize_Loss_Ua6_Oracle18() public {
        TrancheMarket m = _setupAndFinalizeDecimals(6, 18, 0.95e18);
        assertTrue(m.finalized());
        assertGt(m.srRateUA(), ONE);
        assertLt(m.jrRateUA(), ONE);
        assertGt(m.jrRateUA(), 0);
        _assertConservation(m);
    }

    function test_Finalize_Loss_Ua8_Oracle6() public {
        TrancheMarket m = _setupAndFinalizeDecimals(8, 6, 0.95e18);
        assertTrue(m.finalized());
        assertGt(m.srRateUA(), ONE);
        assertLt(m.jrRateUA(), ONE);
        assertGt(m.jrRateUA(), 0);
        _assertConservation(m);
    }

    function test_Finalize_Loss_Ua8_Oracle8() public {
        TrancheMarket m = _setupAndFinalizeDecimals(8, 8, 0.95e18);
        assertTrue(m.finalized());
        assertGt(m.srRateUA(), ONE);
        assertLt(m.jrRateUA(), ONE);
        assertGt(m.jrRateUA(), 0);
        _assertConservation(m);
    }

    function test_Finalize_Loss_Ua8_Oracle18() public {
        TrancheMarket m = _setupAndFinalizeDecimals(8, 18, 0.95e18);
        assertTrue(m.finalized());
        assertGt(m.srRateUA(), ONE);
        assertLt(m.jrRateUA(), ONE);
        assertGt(m.jrRateUA(), 0);
        _assertConservation(m);
    }

    function test_Finalize_Loss_Ua18_Oracle6() public {
        TrancheMarket m = _setupAndFinalizeDecimals(18, 6, 0.95e18);
        assertTrue(m.finalized());
        assertGt(m.srRateUA(), ONE);
        assertLt(m.jrRateUA(), ONE);
        assertGt(m.jrRateUA(), 0);
        _assertConservation(m);
    }

    function test_Finalize_Loss_Ua18_Oracle8() public {
        TrancheMarket m = _setupAndFinalizeDecimals(18, 8, 0.95e18);
        assertTrue(m.finalized());
        assertGt(m.srRateUA(), ONE);
        assertLt(m.jrRateUA(), ONE);
        assertGt(m.jrRateUA(), 0);
        _assertConservation(m);
    }

    function test_Finalize_Loss_Ua18_Oracle18() public {
        TrancheMarket m = _setupAndFinalizeDecimals(18, 18, 0.95e18);
        assertTrue(m.finalized());
        assertGt(m.srRateUA(), ONE);
        assertLt(m.jrRateUA(), ONE);
        assertGt(m.jrRateUA(), 0);
        _assertConservation(m);
    }
}
