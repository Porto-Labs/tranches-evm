// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import { Test } from "forge-std/Test.sol";
import { TrancheMarket } from "src/core/TrancheMarket.sol";
import { TrancheToken } from "src/core/TrancheToken.sol";
import { ERC20Mock } from "../mocks/ERC20Mock.sol";
import { MockChainlinkAggregator } from "../mocks/MockChainlinkAggregator.sol";
import { ITrancheMarket } from "src/interfaces/ITrancheMarket.sol";
import { SettlementRatioModel } from "src/settlement/SettlementRatioModel.sol";

contract TrancheMarketTest is Test {
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

    function test_Constructor_SetOracleImmutables() public view {
        assertEq(market.priceFeed(), address(oracle));
        assertEq(market.initialPrice(), 1e18);
        assertEq(market.seniorFloor(), 0.0033e18);
        assertEq(market.seniorTarget(), 0.005e18);
    }

    function test_Constructor_CalculateJuniorRatio() public view {
        assertEq(market.seniorRatio(), 0.7e18);
        assertEq(market.juniorRatio(), 0.3e18);
    }

    function test_Constructor_DeriveTokenNames() public view {
        TrancheToken srToken = TrancheToken(market.srToken());
        TrancheToken jrToken = TrancheToken(market.jrToken());
        assertEq(srToken.symbol(), "srUA");
        assertEq(jrToken.symbol(), "jrUA");
        assertEq(srToken.name(), "Porto srUA");
        assertEq(jrToken.name(), "Porto jrUA");
    }

    function test_RevertWhen_Constructor_PriceFeedZeroAddress() public {
        TrancheMarket.MarketParams memory params = _defaultMarketParams();
        params.priceFeed = address(0);

        vm.expectRevert(ITrancheMarket.ZeroAddress.selector);
        new TrancheMarket(params);
    }

    function test_RevertWhen_Constructor_OracleReturnsZeroPrice() public {
        MockChainlinkAggregator zeroOracle = new MockChainlinkAggregator(8, "UA / USD");
        zeroOracle.setRoundData(0, block.timestamp);

        TrancheMarket.MarketParams memory params = _defaultMarketParams();
        params.priceFeed = address(zeroOracle);

        vm.expectRevert(ITrancheMarket.OracleInvalidPrice.selector);
        new TrancheMarket(params);
    }

    function test_RevertWhen_Constructor_FloorExceedsTarget() public {
        TrancheMarket.MarketParams memory params = _defaultMarketParams();
        params.seniorFloor = 0.01e18;
        params.seniorTarget = 0.005e18;

        vm.expectRevert(SettlementRatioModel.SettlementInvalidYieldRange.selector);
        new TrancheMarket(params);
    }

    function test_RevertWhen_Constructor_SeniorRatioZero() public {
        TrancheMarket.MarketParams memory params = _defaultMarketParams();
        params.seniorRatio = 0;

        vm.expectRevert(ITrancheMarket.TrancheInvalidWeights.selector);
        new TrancheMarket(params);
    }

    function test_RevertWhen_Constructor_SeniorRatioHundredPercent() public {
        TrancheMarket.MarketParams memory params = _defaultMarketParams();
        params.seniorRatio = 1e18;

        vm.expectRevert(ITrancheMarket.TrancheInvalidWeights.selector);
        new TrancheMarket(params);
    }

    function test_OracleScaling_EightDecimalsTo18() public {
        vm.prank(user);
        market.tranche(100e18, user);

        vm.warp(block.timestamp + MONTH + 1);
        oracle.setRoundData(150_000_000, block.timestamp);

        (,, uint256 oraclePrice) = market.previewSettlement();
        assertEq(oraclePrice, 1.5e18);
    }

    function test_OracleScaling_18Decimals() public {
        MockChainlinkAggregator oracle18 = new MockChainlinkAggregator(18, "UA / USD");
        oracle18.setRoundData(int256(1.25e18), block.timestamp);

        TrancheMarket.MarketParams memory params = _defaultMarketParams();
        params.priceFeed = address(oracle18);
        TrancheMarket market18 = new TrancheMarket(params);

        vm.startPrank(user);
        ua.approve(address(market18), 100e18);
        market18.tranche(100e18, user);
        vm.stopPrank();

        vm.warp(block.timestamp + MONTH + 1);
        oracle18.setRoundData(int256(1.25e18), block.timestamp);

        (,, uint256 oraclePrice) = market18.previewSettlement();
        assertEq(oraclePrice, 1.25e18);
    }

    function test_OracleScaling_6Decimals() public {
        MockChainlinkAggregator oracle6 = new MockChainlinkAggregator(6, "UA / USD");
        oracle6.setRoundData(2_000_000, block.timestamp);

        TrancheMarket.MarketParams memory params = _defaultMarketParams();
        params.priceFeed = address(oracle6);
        TrancheMarket market6 = new TrancheMarket(params);

        vm.startPrank(user);
        ua.approve(address(market6), 100e18);
        market6.tranche(100e18, user);
        vm.stopPrank();

        vm.warp(block.timestamp + MONTH + 1);
        oracle6.setRoundData(2_000_000, block.timestamp);

        (,, uint256 oraclePrice) = market6.previewSettlement();
        assertEq(oraclePrice, 2e18);
    }

    function test_OracleScaling_HigherDecimalsThanTarget() public {
        MockChainlinkAggregator oracle20 = new MockChainlinkAggregator(20, "UA / USD");
        oracle20.setRoundData(int256(1.5e20), block.timestamp);

        TrancheMarket.MarketParams memory params = _defaultMarketParams();
        params.priceFeed = address(oracle20);
        TrancheMarket market20 = new TrancheMarket(params);

        assertEq(market20.initialPrice(), 1.5e18);
    }

    // ============ Constructor Revert Tests ============

    function test_RevertWhen_Constructor_UaOrAdminZeroAddress() public {
        TrancheMarket.MarketParams memory params = _defaultMarketParams();
        params.ua = address(0);

        vm.expectRevert(ITrancheMarket.ZeroAddress.selector);
        new TrancheMarket(params);

        params = _defaultMarketParams();
        params.admin = address(0);

        vm.expectRevert(ITrancheMarket.ZeroAddress.selector);
        new TrancheMarket(params);
    }

    function test_RevertWhen_Constructor_ExpiryInPast() public {
        TrancheMarket.MarketParams memory params = _defaultMarketParams();
        params.expiry = block.timestamp;

        vm.expectRevert(ITrancheMarket.TrancheInvalidExpiry.selector);
        new TrancheMarket(params);
    }

    // ============ Tranche Guard Tests ============

    function test_RevertWhen_Tranche_AfterExpiry() public {
        vm.warp(block.timestamp + MONTH + 1);

        vm.prank(user);
        vm.expectRevert(ITrancheMarket.TrancheMarketExpired.selector);
        market.tranche(100e18, user);
    }

    function test_RevertWhen_Tranche_ZeroAmount() public {
        vm.prank(user);
        vm.expectRevert(ITrancheMarket.TrancheZeroAmount.selector);
        market.tranche(0, user);
    }

    function test_RevertWhen_Tranche_ZeroReceiver() public {
        vm.prank(user);
        vm.expectRevert(ITrancheMarket.ZeroAddress.selector);
        market.tranche(100e18, address(0));
    }

    // ============ Recombine Guard Tests ============

    function test_RevertWhen_Recombine_AfterExpiry() public {
        vm.prank(user);
        market.tranche(100e18, user);

        vm.warp(block.timestamp + MONTH + 1);

        vm.prank(user);
        vm.expectRevert(ITrancheMarket.TrancheMarketExpired.selector);
        market.recombine(70e18, 30e18, user);
    }

    function test_RevertWhen_Recombine_ZeroSrAmount() public {
        vm.prank(user);
        market.tranche(100e18, user);

        vm.prank(user);
        vm.expectRevert(ITrancheMarket.TrancheZeroAmount.selector);
        market.recombine(0, 30e18, user);
    }

    function test_RevertWhen_Recombine_ZeroJrAmount() public {
        vm.prank(user);
        market.tranche(100e18, user);

        vm.prank(user);
        vm.expectRevert(ITrancheMarket.TrancheZeroAmount.selector);
        market.recombine(70e18, 0, user);
    }

    function test_RevertWhen_Recombine_ZeroReceiver() public {
        vm.prank(user);
        market.tranche(100e18, user);

        vm.prank(user);
        vm.expectRevert(ITrancheMarket.ZeroAddress.selector);
        market.recombine(70e18, 30e18, address(0));
    }

    function test_RevertWhen_Recombine_RatioMismatch() public {
        vm.prank(user);
        market.tranche(100e18, user);

        vm.prank(user);
        vm.expectRevert(ITrancheMarket.TrancheRatioMismatch.selector);
        market.recombine(50e18, 30e18, user);
    }

    // ============ Redeem Guard Tests ============

    function test_RevertWhen_RedeemSenior_NotFinalized() public {
        vm.prank(user);
        market.tranche(100e18, user);

        vm.prank(user);
        vm.expectRevert(ITrancheMarket.TrancheMarketNotFinalized.selector);
        market.redeemSenior(70e18, user);
    }

    function test_RevertWhen_RedeemJunior_NotFinalized() public {
        vm.prank(user);
        market.tranche(100e18, user);

        vm.prank(user);
        vm.expectRevert(ITrancheMarket.TrancheMarketNotFinalized.selector);
        market.redeemJunior(30e18, user);
    }

    function test_RevertWhen_RedeemSenior_ZeroAmount() public {
        vm.prank(user);
        market.tranche(100e18, user);

        vm.warp(block.timestamp + MONTH + 1);
        oracle.setRoundData(100_000_000, block.timestamp);
        vm.prank(admin);
        market.finalize(1e18, 0.01e18);

        vm.prank(user);
        vm.expectRevert(ITrancheMarket.TrancheZeroAmount.selector);
        market.redeemSenior(0, user);
    }

    function test_RevertWhen_RedeemJunior_ZeroAmount() public {
        vm.prank(user);
        market.tranche(100e18, user);

        vm.warp(block.timestamp + MONTH + 1);
        oracle.setRoundData(100_000_000, block.timestamp);
        vm.prank(admin);
        market.finalize(1e18, 0.01e18);

        vm.prank(user);
        vm.expectRevert(ITrancheMarket.TrancheZeroAmount.selector);
        market.redeemJunior(0, user);
    }

    function test_RevertWhen_RedeemSenior_ZeroReceiver() public {
        vm.prank(user);
        market.tranche(100e18, user);

        vm.warp(block.timestamp + MONTH + 1);
        oracle.setRoundData(100_000_000, block.timestamp);
        vm.prank(admin);
        market.finalize(1e18, 0.01e18);

        vm.prank(user);
        vm.expectRevert(ITrancheMarket.ZeroAddress.selector);
        market.redeemSenior(70e18, address(0));
    }

    function test_RevertWhen_RedeemJunior_ZeroReceiver() public {
        vm.prank(user);
        market.tranche(100e18, user);

        vm.warp(block.timestamp + MONTH + 1);
        oracle.setRoundData(100_000_000, block.timestamp);
        vm.prank(admin);
        market.finalize(1e18, 0.01e18);

        vm.prank(user);
        vm.expectRevert(ITrancheMarket.ZeroAddress.selector);
        market.redeemJunior(30e18, address(0));
    }

    // ============ SetAdmin Tests ============

    function test_SetAdmin_Success() public {
        address newAdmin = makeAddr("newAdmin");

        vm.prank(admin);
        vm.expectEmit(true, false, false, false);
        emit ITrancheMarket.AdminChanged(newAdmin);
        market.setAdmin(newAdmin);

        assertEq(market.admin(), newAdmin);
    }

    function test_RevertWhen_SetAdmin_NotAdmin() public {
        vm.prank(user);
        vm.expectRevert(ITrancheMarket.OnlyAdmin.selector);
        market.setAdmin(user);
    }

    function test_RevertWhen_SetAdmin_ZeroAddress() public {
        vm.prank(admin);
        vm.expectRevert(ITrancheMarket.ZeroAddress.selector);
        market.setAdmin(address(0));
    }

    // ============ Oracle Validation Tests ============

    function test_RevertWhen_Finalize_OracleNegativePrice() public {
        vm.prank(user);
        market.tranche(100e18, user);

        vm.warp(block.timestamp + MONTH + 1);
        oracle.setRoundData(-1, block.timestamp);

        vm.prank(admin);
        vm.expectRevert(ITrancheMarket.OracleInvalidPrice.selector);
        market.finalize(1e18, 0.01e18);
    }

    function test_RevertWhen_Liquidation_OracleStalePrice() public {
        TrancheMarket.MarketParams memory params = TrancheMarket.MarketParams({
            ua: address(ua),
            poolFee: 500,
            expiry: block.timestamp + MONTH,
            seniorRatio: 0.8e18,
            admin: admin,
            priceFeed: address(oracle),
            seniorFloor: 0.005e18,
            seniorTarget: 0.01e18,
            liquidationEnabled: true,
            liquidationBuffer: 0.025e18,
            liquidationReward: 0.025e18
        });
        TrancheMarket liqMarket = new TrancheMarket(params);

        ua.mint(user, 100e18);
        vm.startPrank(user);
        ua.approve(address(liqMarket), 100e18);
        liqMarket.tranche(100e18, user);
        vm.stopPrank();

        vm.warp(block.timestamp + 26 hours);
        oracle.setRoundData(50_000_000, block.timestamp - 25 hours);

        vm.prank(admin);
        vm.expectRevert(ITrancheMarket.OracleStalePrice.selector);
        liqMarket.liquidate();
    }

    // ============ PreviewLiquidation After Finalized ============

    function test_PreviewLiquidation_ReturnsFalseWhenFinalized() public {
        TrancheMarket.MarketParams memory params = TrancheMarket.MarketParams({
            ua: address(ua),
            poolFee: 500,
            expiry: block.timestamp + MONTH,
            seniorRatio: 0.8e18,
            admin: admin,
            priceFeed: address(oracle),
            seniorFloor: 0.005e18,
            seniorTarget: 0.01e18,
            liquidationEnabled: true,
            liquidationBuffer: 0.025e18,
            liquidationReward: 0.025e18
        });
        TrancheMarket liqMarket = new TrancheMarket(params);

        ua.mint(user, 100e18);
        vm.startPrank(user);
        ua.approve(address(liqMarket), 100e18);
        liqMarket.tranche(100e18, user);
        vm.stopPrank();

        vm.warp(block.timestamp + MONTH + 1);
        oracle.setRoundData(100_000_000, block.timestamp);
        vm.prank(admin);
        liqMarket.finalize(1e18, 0.01e18);

        (bool canLiquidate,,,,) = liqMarket.previewLiquidation();
        assertFalse(canLiquidate);
    }

    // ============ View Function Tests ============

    function test_GetSwapParameters() public view {
        (address uaAddr, address srAddr, address jrAddr, uint24 poolFee) = market.getSwapParameters();

        assertEq(uaAddr, address(ua));
        assertEq(srAddr, market.srToken());
        assertEq(jrAddr, market.jrToken());
        assertEq(poolFee, 500);
    }

    function test_PreviewTranche() public view {
        (uint256 srOut, uint256 jrOut) = market.previewTranche(100e18);

        assertEq(srOut, 70e18);
        assertEq(jrOut, 30e18);
    }

    // ============ Uncovered Branch Tests ============

    function _createLiquidationMarket() internal returns (TrancheMarket) {
        TrancheMarket.MarketParams memory params = TrancheMarket.MarketParams({
            ua: address(ua),
            poolFee: 500,
            expiry: block.timestamp + MONTH,
            seniorRatio: 0.8e18,
            admin: admin,
            priceFeed: address(oracle),
            seniorFloor: 0.005e18,
            seniorTarget: 0.01e18,
            liquidationEnabled: true,
            liquidationBuffer: 0.025e18,
            liquidationReward: 0.025e18
        });
        return new TrancheMarket(params);
    }

    function test_RedeemJunior_ZeroUaOutAfterLiquidation() public {
        TrancheMarket liqMarket = _createLiquidationMarket();

        ua.mint(user, 100e18);
        vm.startPrank(user);
        ua.approve(address(liqMarket), 100e18);
        liqMarket.tranche(100e18, user);
        vm.stopPrank();

        oracle.setRoundData(50_000_000, block.timestamp);

        vm.prank(admin);
        liqMarket.liquidate();

        assertEq(liqMarket.jrRateUA(), 0);

        uint256 jrBalance = TrancheToken(liqMarket.jrToken()).balanceOf(user);
        uint256 userUaBefore = ua.balanceOf(user);

        vm.prank(user);
        liqMarket.redeemJunior(jrBalance, user);

        assertEq(ua.balanceOf(user), userUaBefore);
    }

    function test_PreviewLiquidation_ReturnsFalseWhenNotEnabled() public view {
        (bool canLiquidate,,,,) = market.previewLiquidation();
        assertFalse(canLiquidate);
    }

    function test_Finalize_DeviationWhenOracleBelowReference() public {
        vm.prank(user);
        market.tranche(100e18, user);

        vm.warp(block.timestamp + MONTH + 1);
        oracle.setRoundData(99_000_000, block.timestamp);

        vm.prank(admin);
        market.finalize(1e18, 0.02e18);

        assertTrue(market.finalized());
    }
}
