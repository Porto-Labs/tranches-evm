// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import { Test } from "forge-std/Test.sol";
import { TrancheMarket } from "src/core/TrancheMarket.sol";
import { TrancheToken } from "src/core/TrancheToken.sol";
import { ERC20Mock } from "../mocks/ERC20Mock.sol";
import { MockChainlinkAggregator } from "../mocks/MockChainlinkAggregator.sol";

contract TrancheMarketInvariantsTest is Test {
    address public admin;
    address public user;

    uint256 constant ONE = 1e18;
    uint256 constant MONTH = 30 days;

    function setUp() public {
        admin = makeAddr("admin");
        user = makeAddr("user");
    }

    function _mulDown(uint256 a, uint256 b) internal pure returns (uint256) {
        return (a * b) / ONE;
    }

    function test_Invariant_NoOverDistributionAcrossPrices() public {
        int256[9] memory prices = [int256(50000000), 70000000, 90000000, 100000000, 100300000, 100500000, 101000000, 110000000, 150000000];

        for (uint256 i = 0; i < prices.length; i++) {
            ERC20Mock testUa = new ERC20Mock("Test UA", "TUA");
            MockChainlinkAggregator testOracle = new MockChainlinkAggregator(8, "UA / USD");
            testOracle.setRoundData(100000000, block.timestamp);

            TrancheMarket.MarketParams memory params = TrancheMarket.MarketParams({
                ua: address(testUa),
                poolFee: 500,
                expiry: block.timestamp + MONTH,
                seniorRatio: 0.7e18,
                admin: admin,
                priceFeed: address(testOracle),
                seniorFloor: 0.0033e18,
                seniorTarget: 0.005e18,
                liquidationEnabled: false,
                liquidationBuffer: 0,
                liquidationReward: 0
            });
            TrancheMarket testMarket = new TrancheMarket(params);

            testUa.mint(user, 100e18);
            vm.startPrank(user);
            testUa.approve(address(testMarket), 100e18);
            testMarket.tranche(100e18, user);
            vm.stopPrank();

            vm.warp(block.timestamp + MONTH + 1);
            testOracle.setRoundData(prices[i], block.timestamp);

            uint256 oraclePriceWad = uint256(prices[i]) * 1e18 / 100000000;

            vm.prank(admin);
            testMarket.finalize(oraclePriceWad, 0.01e18);

            uint256 srRate = testMarket.srRateUA();
            uint256 jrRate = testMarket.jrRateUA();
            uint256 seniorRatio = testMarket.seniorRatio();
            uint256 uaQuantity = 100e18;

            uint256 srSupply = _mulDown(uaQuantity, seniorRatio);
            uint256 jrSupply = uaQuantity - srSupply;
            uint256 srDistributed = _mulDown(srSupply, srRate);
            uint256 jrDistributed = _mulDown(jrSupply, jrRate);
            uint256 totalDistributed = srDistributed + jrDistributed;

            assertLe(totalDistributed, uaQuantity, "Over-distribution detected");
        }
    }

    function test_Invariant_NoOverDistributionOnLiquidation() public {
        ERC20Mock ua = new ERC20Mock("Underlying Asset", "UA");
        MockChainlinkAggregator oracle = new MockChainlinkAggregator(8, "UA / USD");
        oracle.setRoundData(100000000, block.timestamp);

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
        TrancheMarket market = new TrancheMarket(params);

        ua.mint(user, 1000e18);
        vm.startPrank(user);
        ua.approve(address(market), 1000e18);
        market.tranche(100e18, user);
        vm.stopPrank();

        uint256 uaQuantityBefore = ua.balanceOf(address(market));

        uint256 liqPrice = market.liquidationPrice();
        uint256 belowLiqPrice = (liqPrice * 99) / 100;
        // forge-lint: disable-next-line(unsafe-typecast)
        int256 oracle8Dec = int256((belowLiqPrice * 100000000) / ONE);
        oracle.setRoundData(oracle8Dec, block.timestamp);

        vm.prank(admin);
        market.liquidate();

        TrancheToken srToken = TrancheToken(market.srToken());
        TrancheToken jrToken = TrancheToken(market.jrToken());
        uint256 srSupply = srToken.totalSupply();
        uint256 jrSupply = jrToken.totalSupply();
        uint256 srRate = market.srRateUA();
        uint256 jrRate = market.jrRateUA();

        uint256 srDistributed = _mulDown(srSupply, srRate);
        uint256 jrDistributed = _mulDown(jrSupply, jrRate);
        uint256 adminReward = ua.balanceOf(admin);
        uint256 totalDistributed = srDistributed + jrDistributed + adminReward;

        assertLe(totalDistributed, uaQuantityBefore, "Over-distribution on liquidation");
    }
}
