// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import { Test, console2 } from "forge-std/Test.sol";
import { TrancheMarket } from "src/core/TrancheMarket.sol";
import { TrancheToken } from "src/core/TrancheToken.sol";
import { ERC20Mock, ERC20Mock6Decimals, ERC20Mock8Decimals } from "../mocks/ERC20Mock.sol";
import { IERC20 } from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import { MockChainlinkAggregator } from "../mocks/MockChainlinkAggregator.sol";
import { SettlementRatioModelMock } from "../mocks/SettlementRatioModelMock.sol";

contract TrancheMarketRedeemTest is Test {
    TrancheMarket public market;
    ERC20Mock public ua;
    MockChainlinkAggregator public oracle;
    SettlementRatioModelMock public model;

    address public admin;
    address public user;

    uint256 constant ONE = 1e18;
    uint256 constant MONTH = 30 days;

    function setUp() public {
        admin = makeAddr("admin");
        user = makeAddr("user");
        model = new SettlementRatioModelMock();

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

    // Two depositors (50%, 50%) tranche into a $10M pool.
    // UA has 6 decimals, $100/token initial price → 100,000 tokens total.
    // Price rises 2.9% at maturity → Condition B exact floor boundary.
    // Waterfall: senior earns exactly 4% floor yield, junior returns principal (0% APY).
    // Both users redeem both tranches; APYs are verified in USD terms.
    function test_Finalize_MultiUser_FloorBoundaryScenario() public {
        TrancheMarket _market;
        address user1;
        address user2;

        uint256 initialPrice = 100e18;
        uint256 maturityPrice = 102.9e18; // +2.9%, exact floor boundary
        uint256 seniorRatio = 0.725e18;

        {
            ERC20Mock6Decimals _ua = new ERC20Mock6Decimals("Underlying Asset", "UA");
            MockChainlinkAggregator _oracle = new MockChainlinkAggregator(18, "UA / USD");
            _oracle.setRoundData(int256(initialPrice), block.timestamp);

            _market = new TrancheMarket(
                TrancheMarket.MarketParams({
                    ua: address(_ua),
                    poolFee: 500,
                    matureAt: block.timestamp + MONTH,
                    seniorRatio: seniorRatio,
                    admin: admin,
                    priceFeed: address(_oracle),
                    seniorFloor: 0.04e18,
                    seniorTarget: 0.06e18,
                    liquidationEnabled: false,
                    liquidationBuffer: 0,
                    liquidationReward: 0
                })
            );

            user1 = makeAddr("floor_user1");
            user2 = makeAddr("floor_user2");

            _ua.mint(user1, 50_000e6);
            vm.startPrank(user1);
            _ua.approve(address(_market), 50_000e6);
            _market.tranche(50_000e6, user1);
            vm.stopPrank();

            _ua.mint(user2, 50_000e6);
            vm.startPrank(user2);
            _ua.approve(address(_market), 50_000e6);
            _market.tranche(50_000e6, user2);
            vm.stopPrank();

            vm.warp(block.timestamp + MONTH + 1);
            _oracle.setRoundData(int256(maturityPrice), block.timestamp);
        }

        vm.prank(admin);
        _market.finalize(maturityPrice, 0.01e18);
        assertTrue(_market.finalized());

        address srToken = _market.srToken();
        address jrToken = _market.jrToken();

        {
            vm.startPrank(user1);
            uint256 srUa = _market.redeemSenior(IERC20(srToken).balanceOf(user1), user1);
            uint256 jrUa = _market.redeemJunior(IERC20(jrToken).balanceOf(user1), user1);
            vm.stopPrank();

            (uint256 srPrincipalUsd, uint256 jrPrincipalUsd) = model.calculatePrincipals(50_000e6, initialPrice, seniorRatio);
            uint256 srUsdReceived = srUa * maturityPrice / 1e18;
            uint256 jrUsdReceived = jrUa * maturityPrice / 1e18;
            assertGt(srUsdReceived, srPrincipalUsd);
            assertApproxEqRel((srUsdReceived - srPrincipalUsd) * 1e18 / srPrincipalUsd, 0.04e18, 0.001e18);
            assertApproxEqRel(jrUsdReceived, jrPrincipalUsd, 0.001e18);
        }

        {
            vm.startPrank(user2);
            uint256 srUa = _market.redeemSenior(IERC20(srToken).balanceOf(user2), user2);
            uint256 jrUa = _market.redeemJunior(IERC20(jrToken).balanceOf(user2), user2);
            vm.stopPrank();

            (uint256 srPrincipalUsd, uint256 jrPrincipalUsd) = model.calculatePrincipals(50_000e6, initialPrice, seniorRatio);
            uint256 srUsdReceived = srUa * maturityPrice / 1e18;
            uint256 jrUsdReceived = jrUa * maturityPrice / 1e18;
            assertGt(srUsdReceived, srPrincipalUsd);
            assertApproxEqRel((srUsdReceived - srPrincipalUsd) * 1e18 / srPrincipalUsd, 0.04e18, 0.001e18);
            assertApproxEqRel(jrUsdReceived, jrPrincipalUsd, 0.001e18);
        }
    }

    // Three depositors (30%, 30%, 40%) tranche into a $10M pool.
    // UA has 8 decimals, $100/token initial price → 100,000 tokens total.
    // Price rises 7.5% at maturity → Condition A (Surplus).
    // Waterfall: senior capped at 6% target, junior earns residual ~11.45%.
    // All users redeem both tranches; APYs are verified in USD terms.
    function test_Finalize_MultiUser_SurplusScenario() public {
        TrancheMarket _market;
        address user1;
        address user2;
        address user3;

        uint256 initialPrice = 100e18;
        uint256 maturityPrice = 107.5e18; // +7.5%
        uint256 seniorRatio = 0.725e18;

        // Setup block: _ua and _oracle freed after this scope to keep stack depth safe
        {
            ERC20Mock8Decimals _ua = new ERC20Mock8Decimals("Underlying Asset", "UA");
            MockChainlinkAggregator _oracle = new MockChainlinkAggregator(18, "UA / USD");
            _oracle.setRoundData(int256(initialPrice), block.timestamp);

            _market = new TrancheMarket(
                TrancheMarket.MarketParams({
                    ua: address(_ua),
                    poolFee: 500,
                    matureAt: block.timestamp + MONTH,
                    seniorRatio: seniorRatio,
                    admin: admin,
                    priceFeed: address(_oracle),
                    seniorFloor: 0.04e18,
                    seniorTarget: 0.06e18,
                    liquidationEnabled: false,
                    liquidationBuffer: 0,
                    liquidationReward: 0
                })
            );

            user1 = makeAddr("surplus_user1");
            user2 = makeAddr("surplus_user2");
            user3 = makeAddr("surplus_user3");

            _ua.mint(user1, 30_000e8);
            vm.startPrank(user1);
            _ua.approve(address(_market), 30_000e8);
            _market.tranche(30_000e8, user1);
            vm.stopPrank();

            _ua.mint(user2, 30_000e8);
            vm.startPrank(user2);
            _ua.approve(address(_market), 30_000e8);
            _market.tranche(30_000e8, user2);
            vm.stopPrank();

            _ua.mint(user3, 40_000e8);
            vm.startPrank(user3);
            _ua.approve(address(_market), 40_000e8);
            _market.tranche(40_000e8, user3);
            vm.stopPrank();

            vm.warp(block.timestamp + MONTH + 1);
            _oracle.setRoundData(int256(maturityPrice), block.timestamp);
        }

        vm.prank(admin);
        _market.finalize(maturityPrice, 0.01e18);
        assertTrue(_market.finalized());

        address srToken = _market.srToken();
        address jrToken = _market.jrToken();

        {
            vm.startPrank(user1);
            uint256 srUa = _market.redeemSenior(IERC20(srToken).balanceOf(user1), user1);
            uint256 jrUa = _market.redeemJunior(IERC20(jrToken).balanceOf(user1), user1);
            vm.stopPrank();

            (uint256 srPrincipalUsd, uint256 jrPrincipalUsd) = model.calculatePrincipals(30_000e8, initialPrice, seniorRatio);
            uint256 srUsdReceived = srUa * maturityPrice / 1e18;
            uint256 jrUsdReceived = jrUa * maturityPrice / 1e18;
            assertGt(srUsdReceived, srPrincipalUsd);
            assertApproxEqRel((srUsdReceived - srPrincipalUsd) * 1e18 / srPrincipalUsd, 0.06e18, 0.001e18);
            assertGt(jrUsdReceived, jrPrincipalUsd);
            assertApproxEqRel((jrUsdReceived - jrPrincipalUsd) * 1e18 / jrPrincipalUsd, 0.1145e18, 0.001e18);
        }

        {
            vm.startPrank(user2);
            uint256 srUa = _market.redeemSenior(IERC20(srToken).balanceOf(user2), user2);
            uint256 jrUa = _market.redeemJunior(IERC20(jrToken).balanceOf(user2), user2);
            vm.stopPrank();

            (uint256 srPrincipalUsd, uint256 jrPrincipalUsd) = model.calculatePrincipals(30_000e8, initialPrice, seniorRatio);
            uint256 srUsdReceived = srUa * maturityPrice / 1e18;
            uint256 jrUsdReceived = jrUa * maturityPrice / 1e18;
            assertGt(srUsdReceived, srPrincipalUsd);
            assertApproxEqRel((srUsdReceived - srPrincipalUsd) * 1e18 / srPrincipalUsd, 0.06e18, 0.001e18);
            assertGt(jrUsdReceived, jrPrincipalUsd);
            assertApproxEqRel((jrUsdReceived - jrPrincipalUsd) * 1e18 / jrPrincipalUsd, 0.1145e18, 0.001e18);
        }

        {
            vm.startPrank(user3);
            uint256 srUa = _market.redeemSenior(IERC20(srToken).balanceOf(user3), user3);
            uint256 jrUa = _market.redeemJunior(IERC20(jrToken).balanceOf(user3), user3);
            vm.stopPrank();

            (uint256 srPrincipalUsd, uint256 jrPrincipalUsd) = model.calculatePrincipals(40_000e8, initialPrice, seniorRatio);
            uint256 srUsdReceived = srUa * maturityPrice / 1e18;
            uint256 jrUsdReceived = jrUa * maturityPrice / 1e18;
            assertGt(srUsdReceived, srPrincipalUsd);
            assertApproxEqRel((srUsdReceived - srPrincipalUsd) * 1e18 / srPrincipalUsd, 0.06e18, 0.001e18);
            assertGt(jrUsdReceived, jrPrincipalUsd);
            assertApproxEqRel((jrUsdReceived - jrPrincipalUsd) * 1e18 / jrPrincipalUsd, 0.1145e18, 0.001e18);
        }
    }
}
