// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import { Test } from "forge-std/Test.sol";
import { TrancheMarket } from "src/core/TrancheMarket.sol";
import { TrancheToken } from "src/core/TrancheToken.sol";
import { ERC20Mock, ERC20Mock6Decimals, ERC20Mock8Decimals } from "../mocks/ERC20Mock.sol";
import { IERC20 } from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import { MockChainlinkAggregator } from "../mocks/MockChainlinkAggregator.sol";
import { ITrancheMarket } from "src/interfaces/ITrancheMarket.sol";
import { SettlementRatioModel } from "src/settlement/SettlementRatioModel.sol";

contract TrancheMarketLiquidationTest is Test {
    TrancheMarket public market;
    ERC20Mock public ua;
    MockChainlinkAggregator public oracle;

    address public admin;
    address public user;
    address public other;

    uint256 constant ONE = 1e18;
    uint256 constant MONTH = 30 days;

    function setUp() public {
        admin = makeAddr("admin");
        user = makeAddr("user");
        other = makeAddr("other");

        ua = new ERC20Mock("Underlying Asset", "UA");
        oracle = new MockChainlinkAggregator(8, "UA / USD");
        oracle.setRoundData(100_000_000, block.timestamp);

        TrancheMarket.MarketParams memory params = _liquidationMarketParams();
        market = new TrancheMarket(params);

        ua.mint(user, 1000e18);
        vm.prank(user);
        ua.approve(address(market), 1000e18);
    }

    function _liquidationMarketParams() internal view returns (TrancheMarket.MarketParams memory) {
        return TrancheMarket.MarketParams({
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

    function _mulDown(uint256 a, uint256 b) internal pure returns (uint256) {
        return (a * b) / ONE;
    }

    function _setBelowLiquidationPrice() internal {
        uint256 liqPrice = market.liquidationPrice();
        uint256 belowLiqPrice = (liqPrice * 99) / 100;
        // forge-lint: disable-next-line(unsafe-typecast)
        int256 oracle8Dec = int256((belowLiqPrice * 100_000_000) / ONE);
        oracle.setRoundData(oracle8Dec, block.timestamp);
    }

    function test_Constructor_LiquidationEnabled() public view {
        assertTrue(market.liquidationEnabled());
        assertEq(market.liquidationBuffer(), 0.025e18);
        assertEq(market.liquidationReward(), 0.025e18);
    }

    function test_Constructor_LiquidationDisabled() public {
        TrancheMarket disabledMarket = new TrancheMarket(_defaultMarketParams());
        assertFalse(disabledMarket.liquidationEnabled());
        assertEq(disabledMarket.liquidationPrice(), 0);
    }

    function test_Constructor_CalculateLiquidationPrice() public view {
        uint256 initialPrice = market.initialPrice();
        uint256 seniorRatio = market.seniorRatio();
        uint256 juniorRatio = market.juniorRatio();
        uint256 seniorFloor = market.seniorFloor();
        uint256 buffer = market.liquidationBuffer();
        uint256 reward = market.liquidationReward();

        uint256 expectedLiqPrice =
            _mulDown(initialPrice, _mulDown(seniorRatio, ONE + seniorFloor) + _mulDown(juniorRatio, buffer + reward));

        assertEq(market.liquidationPrice(), expectedLiqPrice);
    }

    function test_RevertWhen_Constructor_BufferExceedsMax() public {
        TrancheMarket.MarketParams memory params = _liquidationMarketParams();
        params.liquidationBuffer = 0.026e18;

        vm.expectRevert(ITrancheMarket.LiquidationInvalidBuffer.selector);
        new TrancheMarket(params);
    }

    function test_RevertWhen_Constructor_RewardExceedsMax() public {
        TrancheMarket.MarketParams memory params = _liquidationMarketParams();
        params.liquidationReward = 0.026e18;

        vm.expectRevert(ITrancheMarket.LiquidationInvalidReward.selector);
        new TrancheMarket(params);
    }

    function test_Liquidate_WhenPriceBelowThreshold() public {
        vm.prank(user);
        market.tranche(100e18, user);

        _setBelowLiquidationPrice();

        vm.prank(admin);
        market.liquidate();

        assertTrue(market.finalized());
    }

    function test_Liquidate_SetJrRateToZero() public {
        vm.prank(user);
        market.tranche(100e18, user);

        _setBelowLiquidationPrice();

        vm.prank(admin);
        market.liquidate();

        assertEq(market.jrRateUA(), 0);
    }

    function test_Liquidate_TransferRewardToAdmin() public {
        vm.prank(user);
        market.tranche(100e18, user);

        TrancheToken jrToken = TrancheToken(market.jrToken());
        uint256 jrSupply = jrToken.totalSupply();
        uint256 rewardRate = market.liquidationReward();
        uint256 expectedReward = _mulDown(jrSupply, rewardRate);

        _setBelowLiquidationPrice();

        uint256 adminBalanceBefore = ua.balanceOf(admin);
        vm.prank(admin);
        market.liquidate();
        uint256 adminBalanceAfter = ua.balanceOf(admin);

        assertEq(adminBalanceAfter - adminBalanceBefore, expectedReward);
    }

    function test_Liquidate_AllowSeniorRedemption() public {
        vm.prank(user);
        market.tranche(100e18, user);

        _setBelowLiquidationPrice();

        vm.prank(admin);
        market.liquidate();

        TrancheToken srToken = TrancheToken(market.srToken());
        uint256 srBalance = srToken.balanceOf(user);
        uint256 srRate = market.srRateUA();
        uint256 expectedUa = _mulDown(srBalance, srRate);

        uint256 userUaBefore = ua.balanceOf(user);
        vm.prank(user);
        market.redeemSenior(srBalance, user);
        uint256 userUaAfter = ua.balanceOf(user);

        assertEq(userUaAfter - userUaBefore, expectedUa);
    }

    function test_Liquidate_JuniorGetsZero() public {
        vm.prank(user);
        market.tranche(100e18, user);

        _setBelowLiquidationPrice();

        vm.prank(admin);
        market.liquidate();

        TrancheToken jrToken = TrancheToken(market.jrToken());
        uint256 jrBalance = jrToken.balanceOf(user);

        uint256 userUaBefore = ua.balanceOf(user);
        vm.prank(user);
        market.redeemJunior(jrBalance, user);
        uint256 userUaAfter = ua.balanceOf(user);

        assertEq(userUaAfter - userUaBefore, 0);
    }

    function test_RevertWhen_Liquidate_NotEnabled() public {
        TrancheMarket disabledMarket = new TrancheMarket(_defaultMarketParams());

        vm.startPrank(user);
        ua.approve(address(disabledMarket), 100e18);
        disabledMarket.tranche(100e18, user);
        vm.stopPrank();

        oracle.setRoundData(50_000_000, block.timestamp);

        vm.prank(admin);
        vm.expectRevert(ITrancheMarket.LiquidationNotEnabled.selector);
        disabledMarket.liquidate();
    }

    function test_RevertWhen_Liquidate_PriceAboveThreshold() public {
        vm.prank(user);
        market.tranche(100e18, user);

        oracle.setRoundData(100_000_000, block.timestamp);

        vm.prank(admin);
        vm.expectRevert(ITrancheMarket.LiquidationConditionNotMet.selector);
        market.liquidate();
    }

    function test_RevertWhen_Liquidate_AfterExpiry() public {
        vm.prank(user);
        market.tranche(100e18, user);

        vm.warp(block.timestamp + MONTH + 1);
        _setBelowLiquidationPrice();

        vm.prank(admin);
        vm.expectRevert(ITrancheMarket.LiquidationAfterExpiry.selector);
        market.liquidate();
    }

    function test_RevertWhen_Liquidate_AlreadyLiquidated() public {
        vm.prank(user);
        market.tranche(100e18, user);

        _setBelowLiquidationPrice();

        vm.prank(admin);
        market.liquidate();

        vm.prank(admin);
        vm.expectRevert(ITrancheMarket.TrancheMarketAlreadyFinalized.selector);
        market.liquidate();
    }

    function test_RevertWhen_Liquidate_NonAdmin() public {
        vm.prank(user);
        market.tranche(100e18, user);

        _setBelowLiquidationPrice();

        vm.prank(other);
        vm.expectRevert(ITrancheMarket.OnlyAdmin.selector);
        market.liquidate();
    }

    function test_RevertWhen_Liquidate_ZeroUaBalance() public {
        _setBelowLiquidationPrice();

        vm.prank(admin);
        vm.expectRevert(SettlementRatioModel.SettlementZeroQuantity.selector);
        market.liquidate();
    }

    function test_PreviewLiquidation_CanLiquidateTrue() public {
        vm.prank(user);
        market.tranche(100e18, user);

        _setBelowLiquidationPrice();

        (bool canLiquidate,,,,) = market.previewLiquidation();
        assertTrue(canLiquidate);
    }

    function test_PreviewLiquidation_CanLiquidateFalseWhenPriceAbove() public {
        vm.prank(user);
        market.tranche(100e18, user);

        oracle.setRoundData(100_000_000, block.timestamp);

        (bool canLiquidate,,,,) = market.previewLiquidation();
        assertFalse(canLiquidate);
    }

    function test_PreviewLiquidation_CanLiquidateFalseAfterExpiry() public {
        vm.prank(user);
        market.tranche(100e18, user);

        vm.warp(block.timestamp + MONTH + 1);
        _setBelowLiquidationPrice();

        (bool canLiquidate,,,,) = market.previewLiquidation();
        assertFalse(canLiquidate);
    }

    function test_PreviewLiquidation_CanLiquidateFalseWhenDisabled() public {
        TrancheMarket disabledMarket = new TrancheMarket(_defaultMarketParams());

        vm.startPrank(user);
        ua.approve(address(disabledMarket), 100e18);
        disabledMarket.tranche(100e18, user);
        vm.stopPrank();

        oracle.setRoundData(50_000_000, block.timestamp);

        (bool canLiquidate,,,,) = disabledMarket.previewLiquidation();
        assertFalse(canLiquidate);
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


    function _setupAndLiquidateDecimals(uint8 uaDec, uint8 oracleDec) internal returns (TrancheMarket) {
        address _ua = _deployUa(uaDec);
        MockChainlinkAggregator _oracle = new MockChainlinkAggregator(oracleDec, "UA / USD");
        _oracle.setRoundData(_oraclePrice(oracleDec, 1e18), block.timestamp);

        TrancheMarket.MarketParams memory params = TrancheMarket.MarketParams({
            ua: _ua,
            poolFee: 500,
            expiry: block.timestamp + MONTH,
            seniorRatio: 0.8e18,
            admin: admin,
            priceFeed: address(_oracle),
            seniorFloor: 0.005e18,
            seniorTarget: 0.01e18,
            liquidationEnabled: true,
            liquidationBuffer: 0.025e18,
            liquidationReward: 0.025e18
        });
        TrancheMarket _market = new TrancheMarket(params);

        uint256 trancheAmount = 100 * (10 ** uaDec);
        ERC20Mock(_ua).mint(user, trancheAmount);

        vm.startPrank(user);
        IERC20(_ua).approve(address(_market), trancheAmount);
        _market.tranche(trancheAmount, user);
        vm.stopPrank();

        uint256 liqPrice = _market.liquidationPrice();
        uint256 belowLiqPrice = (liqPrice * 99) / 100;
        _oracle.setRoundData(_oraclePrice(oracleDec, belowLiqPrice), block.timestamp);

        uint256 adminBalBefore = IERC20(_ua).balanceOf(admin);

        vm.prank(admin);
        _market.liquidate();

        uint256 adminBalAfter = IERC20(_ua).balanceOf(admin);

        assertTrue(_market.finalized());
        assertEq(_market.jrRateUA(), 0);
        assertGt(adminBalAfter - adminBalBefore, 0);
        assertGt(_market.srRateUA(), ONE);

        return _market;
    }

    // ============ Liquidation - Decimal Combinations ============

    function test_Liquidate_Ua6_Oracle6() public {
        _setupAndLiquidateDecimals(6, 6);
    }

    function test_Liquidate_Ua6_Oracle8() public {
        _setupAndLiquidateDecimals(6, 8);
    }

    function test_Liquidate_Ua6_Oracle18() public {
        _setupAndLiquidateDecimals(6, 18);
    }

    function test_Liquidate_Ua8_Oracle6() public {
        _setupAndLiquidateDecimals(8, 6);
    }

    function test_Liquidate_Ua8_Oracle8() public {
        _setupAndLiquidateDecimals(8, 8);
    }

    function test_Liquidate_Ua8_Oracle18() public {
        _setupAndLiquidateDecimals(8, 18);
    }

}
