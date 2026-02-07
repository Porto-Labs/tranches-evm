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
        oracle.setRoundData(100000000, block.timestamp);

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
        oracle.setRoundData(150000000, block.timestamp);

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
        oracle6.setRoundData(2000000, block.timestamp);

        TrancheMarket.MarketParams memory params = _defaultMarketParams();
        params.priceFeed = address(oracle6);
        TrancheMarket market6 = new TrancheMarket(params);

        vm.startPrank(user);
        ua.approve(address(market6), 100e18);
        market6.tranche(100e18, user);
        vm.stopPrank();

        vm.warp(block.timestamp + MONTH + 1);
        oracle6.setRoundData(2000000, block.timestamp);

        (,, uint256 oraclePrice) = market6.previewSettlement();
        assertEq(oraclePrice, 2e18);
    }
}
