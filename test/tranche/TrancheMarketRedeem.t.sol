// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import { Test } from "forge-std/Test.sol";
import { TrancheMarket } from "src/core/TrancheMarket.sol";
import { TrancheToken } from "src/core/TrancheToken.sol";
import { ERC20Mock } from "../mocks/ERC20Mock.sol";
import { MockChainlinkAggregator } from "../mocks/MockChainlinkAggregator.sol";

contract TrancheMarketRedeemTest is Test {
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

        vm.prank(admin);
        market.finalize(1e18, 0.01e18);
    }

    function _defaultMarketParams() internal view returns (TrancheMarket.MarketParams memory) {
        return TrancheMarket.MarketParams({
            ua: address(ua),
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

    function test_RedeemSenior_AtCalculatedRate() public {
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

    function test_RedeemJunior_AtCalculatedRate() public {
        TrancheToken jrToken = TrancheToken(market.jrToken());
        uint256 jrBalance = jrToken.balanceOf(user);
        uint256 jrRate = market.jrRateUA();
        uint256 expectedUa = _mulDown(jrBalance, jrRate);

        uint256 userUaBefore = ua.balanceOf(user);
        vm.prank(user);
        market.redeemJunior(jrBalance, user);
        uint256 userUaAfter = ua.balanceOf(user);

        assertEq(userUaAfter - userUaBefore, expectedUa);
    }
}
