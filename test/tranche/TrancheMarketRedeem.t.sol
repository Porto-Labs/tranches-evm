// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import { Test } from "forge-std/Test.sol";
import { TrancheMarket } from "src/core/TrancheMarket.sol";
import { TrancheToken } from "src/core/TrancheToken.sol";
import { ERC20Mock, ERC20Mock6Decimals, ERC20Mock8Decimals } from "../mocks/ERC20Mock.sol";
import { IERC20 } from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
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

        vm.prank(admin);
        market.finalize(1e18, 0.01e18);
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

    function _setupAndFinalizeDecimals(uint8 uaDec, uint8 oracleDec, uint256 maturityPrice1e18)
        internal
        returns (TrancheMarket _market, address _ua)
    {
        _ua = _deployUa(uaDec);

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
        _market = new TrancheMarket(params);

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
    }

    function _testRedeemDecimals(uint8 uaDec, uint8 oracleDec) internal {
        (TrancheMarket _market, address _ua) = _setupAndFinalizeDecimals(uaDec, oracleDec, 1.05e18);

        TrancheToken srToken = TrancheToken(_market.srToken());
        TrancheToken jrToken = TrancheToken(_market.jrToken());
        uint256 srBalance = srToken.balanceOf(user);
        uint256 jrBalance = jrToken.balanceOf(user);

        uint256 expectedSr = _mulDown(srBalance, _market.srRateUA());
        uint256 expectedJr = _mulDown(jrBalance, _market.jrRateUA());
        uint256 marketBalBefore = IERC20(_ua).balanceOf(address(_market));

        vm.startPrank(user);
        _market.redeemSenior(srBalance, user);
        _market.redeemJunior(jrBalance, user);
        vm.stopPrank();

        uint256 userUa = IERC20(_ua).balanceOf(user);
        uint256 marketBalAfter = IERC20(_ua).balanceOf(address(_market));

        assertEq(userUa, expectedSr + expectedJr);
        assertLe(marketBalBefore - marketBalAfter, marketBalBefore);
        assertGt(userUa, 0);
    }

    // ============ Redeem - Decimal Combinations ============

    function test_Redeem_Ua6_Oracle6() public {
        _testRedeemDecimals(6, 6);
    }

    function test_Redeem_Ua6_Oracle8() public {
        _testRedeemDecimals(6, 8);
    }

    function test_Redeem_Ua6_Oracle18() public {
        _testRedeemDecimals(6, 18);
    }

    function test_Redeem_Ua8_Oracle6() public {
        _testRedeemDecimals(8, 6);
    }

    function test_Redeem_Ua8_Oracle8() public {
        _testRedeemDecimals(8, 8);
    }

    function test_Redeem_Ua8_Oracle18() public {
        _testRedeemDecimals(8, 18);
    }
}
