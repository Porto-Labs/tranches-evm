// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import { BaseForkTest } from "./BaseForkTest.sol";
import { TrancheToken } from "src/core/TrancheToken.sol";
import { IERC20 } from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import { IUniswapV3Pool } from "@uniswap/v3-core/contracts/interfaces/IUniswapV3Pool.sol";
import { Math } from "@openzeppelin/contracts/utils/math/Math.sol";
import { IRouter } from "src/interfaces/IRouter.sol";
import { console } from "forge-std/Test.sol";
import { IQuoterV2 } from "@uniswap/v3-periphery/contracts/interfaces/IQuoterV2.sol";

contract TrancheMarketRWATest is BaseForkTest {
    address public user1;
    address public user2;
    address public user3;

    function setUp() public {
        _forkSepolia();
        _setupBaseAddresses();

        user1 = makeAddr("user1");
        user2 = makeAddr("user2");
        user3 = makeAddr("user3");

        _deployTokenAndOracle();
        _deployTrancheMarket();
        _setupLiquidityProvider();
        _createUniswapPool();

        // 3,000,000 srPRIME : 3,000,000 PRIME
        _addLiquidity(); // Setup UniswapV3 PRIME/srPRIME pool with initial liquidity

        _setupMorphoMarket(); // Setup Morpho PRIME/USDC market

        _deployRouter();
        _setupUsers();
    }

    function _setupUsers() internal {
        uint256 user1Deposit = 100_000e18;
        uint256 user2Deposit = 50_000e18;
        uint256 user3Deposit = 3_75_000e18;

        prime.mint(user1, user1Deposit);
        vm.startPrank(user1);
        prime.approve(address(market), user1Deposit);
        market.tranche(user1Deposit, user1);
        vm.stopPrank();

        prime.mint(user2, user2Deposit);
        vm.startPrank(user2);
        prime.approve(address(market), user2Deposit);
        market.tranche(user2Deposit, user2);
        vm.stopPrank();

        prime.mint(user3, user3Deposit);
        vm.startPrank(user3);
        prime.approve(address(market), user3Deposit);
        market.tranche(user3Deposit, user3);
        vm.stopPrank();
    }

    // ============ Off-chain helpers ============
    function _adjustPoolPriceBySellingSr(uint256 sellAmount) internal {
        address srToken = market.srToken();
        address priceAdjuster = makeAddr("priceAdjuster");

        prime.mint(priceAdjuster, sellAmount * 2);
        vm.startPrank(priceAdjuster);
        prime.approve(address(market), sellAmount * 2);
        market.tranche(sellAmount * 2, priceAdjuster);

        IERC20(srToken).approve(address(router), sellAmount);
        router.sellSenior(address(market), sellAmount, 0, block.timestamp + 1 hours);
        vm.stopPrank();
    }

    function _calculateUnderlyingToBorrow(
        uint256 srIn,
        uint256 userSlippageBps
    ) internal returns (uint256 uaToBorrow, uint256 minJrOut) {
        //note is it going to work better with slot price? quoter apply fee
        address srToken = market.srToken();
        IQuoterV2 quoter = IQuoterV2(UNISWAP_V3_QUOTER_V2_SEPOLIA);

        IQuoterV2.QuoteExactInputSingleParams memory quoteParams = IQuoterV2.QuoteExactInputSingleParams({
            tokenIn: srToken,
            tokenOut: address(prime),
            amountIn: srIn,
            fee: POOL_FEE,
            sqrtPriceLimitX96: 0
        });
        (uint256 uaAmtOut, , , ) = quoter.quoteExactInputSingle(quoteParams);

        uint256 seniorPrice = uaAmtOut * 1e18 / srIn;

        uint256 R = SENIOR_RATIO * 1e18 / JUNIOR_RATIO;
        uint256 juniorPrice = (1e18 + R) - (seniorPrice * R / 1e18);

        uint256 jrOut = srIn * seniorPrice / juniorPrice;

        uint256 denominator = 1e18 - (SENIOR_RATIO * seniorPrice / 1e18);
        uaToBorrow = srIn * seniorPrice / denominator;

        uaToBorrow = uaToBorrow * 99 / 100; 
        // without buffer swapSeniorToJunior fails

        minJrOut = jrOut * userSlippageBps / 10000;
    }


    function _calculateFromUaInput(
        uint256 uaIn,
        uint256 userSlippageBps
    ) internal returns (uint256 uaToBorrow, uint256 minJrOut) {

        // 1) initialPriceSenior = AMM.slot  UA/SR = 0.98
        // 2) juniorPrice = P_jr = (1 + R) - (P_sr * R), where R = srWeight/jrWeight
        // 3) Calculate amountToBorrow from uaIn and jrPrice using senior ratio
        // 4) Calculate price impact:
        //   4.1) using quoter to sell all seniorMinted tokens (uaAmountOut)
        //   4.2) adjustedPrice = uaAmountOut / seniorAmountIn
        //   4.3) slippage price impact % = (initialPriceSenior - adjustedPrice) / initialPriceSenior
        // 5) if slippage price impact bigger than zero, apply slippage to juniorPrice
        // 6) calculate totalUa from new juniorPrice,  uaToBorrow  = totalUa - uaIn
        // 7) calculate minJrOut from uaIn juniorPrice and user slippage bps
        //

        uint256 juniorPrice;
        uint256 totalUaToTranche;
        uint256 priceImpactPct;

        {
            uint256 initialPriceSenior;
            {
                address srToken = market.srToken();
                IUniswapV3Pool pool = IUniswapV3Pool(uniswapPool);

                // 1) initialPriceSenior from slot0
                (uint160 sqrtPriceX96, , , , , , ) = pool.slot0();
                if (address(prime) < srToken) {
                    initialPriceSenior = (uint256(1) << 192) * 1e18 / (uint256(sqrtPriceX96) * uint256(sqrtPriceX96));
                } else {
                    initialPriceSenior = (uint256(sqrtPriceX96) * uint256(sqrtPriceX96) * 1e18) >> 192;
                }
            }

            // 2) juniorPrice = (1 + R) - (P_sr * R)
            uint256 R = SENIOR_RATIO * 1e18 / JUNIOR_RATIO;
            juniorPrice = (1e18 + R) - (initialPriceSenior * R / 1e18);

            // 3) Calculate initial amountToBorrow from uaIn and jrPrice using senior ratio
            uint256 denominator = 1e18 - (SENIOR_RATIO * initialPriceSenior / 1e18);
            uint256 initialUaToBorrow = (uaIn * SENIOR_RATIO / 1e18) * initialPriceSenior / denominator;

            // 4) Calculate price impact
            // 4.1) seniorMinted from tranching (uaIn + initialUaToBorrow)
            totalUaToTranche = uaIn + initialUaToBorrow;
            uint256 seniorMinted = totalUaToTranche * SENIOR_RATIO / 1e18;

            // 4.1) using quoter to sell all seniorMinted tokens
            IQuoterV2 quoter = IQuoterV2(UNISWAP_V3_QUOTER_V2_SEPOLIA);
            IQuoterV2.QuoteExactInputSingleParams memory quoteParams = IQuoterV2.QuoteExactInputSingleParams({
                tokenIn: market.srToken(),
                tokenOut: address(prime),
                amountIn: seniorMinted,
                fee: POOL_FEE,
                sqrtPriceLimitX96: 0
            });
            (uint256 uaAmountOut, , , ) = quoter.quoteExactInputSingle(quoteParams);

            // 4.2) adjustedPrice = uaAmountOut / seniorAmountIn
            uint256 adjustedPrice = uaAmountOut * 1e18 / seniorMinted;

            // 4.3) slippage price impact % = (initialPriceSenior - adjustedPrice) / initialPriceSenior
            priceImpactPct = 0;
            if (initialPriceSenior > adjustedPrice) {
                priceImpactPct = (initialPriceSenior - adjustedPrice) * 1e18 / initialPriceSenior;
            }
        }

        // 5) if slippage price impact > 0, apply slippage to juniorPrice
        uint256 adjustedJuniorPrice = juniorPrice;
        if (priceImpactPct > 0) {
            adjustedJuniorPrice = juniorPrice + (juniorPrice * priceImpactPct / 1e18);
        }

        // 6) calculate expectedJrOut and minJrOut from uaIn, juniorPrice and user slippage bps
        uint256 expectedJrOut = uaIn * 1e18 / adjustedJuniorPrice;
        minJrOut = expectedJrOut * userSlippageBps / 10000;

        // 7) calculate totalUa from new juniorPrice, uaToBorrow = totalUa - uaIn

        // uint256 totalUa = (totalUaToTranche * (1e18 - priceImpactPct)) / 1e18;
        uint256 totalUa = totalUaToTranche * 99 / 100;

        uaToBorrow = totalUa - uaIn;
    }

    // Pool Liquidity = [-1000t, 1000t], 5 Million liquidity PRIME/srPRIME
    // Pool ratio: 0.98:1 (PRIME/srPRIME) after price adjustment
    function test_BuyJunior_Success() public {
        address jrToken = market.jrToken();
        address uaToken = market.uaToken();

        address buyUser = makeAddr("buyJuniorUser");
        uint256 buyAmount = 10_000e18; // uaIn
        prime.mint(buyUser, buyAmount);

        _adjustPoolPriceBySellingSr(600_000e18);

        uint256 userSlippage = 9800; // 2%
        (uint256 uaToBorrow, uint256 minJrOut) = _calculateFromUaInput(buyAmount, userSlippage);

        console.log("=== OFF-CHAIN CALCULATION ===");
        console.log("minJrOut (with 2% slippage):", minJrOut / 1e18);
        console.log("uaToBorrow:", uaToBorrow / 1e18);

        uint256 userJrBefore = IERC20(jrToken).balanceOf(buyUser);

        vm.startPrank(buyUser);
        prime.approve(address(router), buyAmount);
        router.buyJunior(address(market), buyAmount, uaToBorrow, minJrOut, block.timestamp + 1 minutes);
        vm.stopPrank();

        uint256 userJrAfter = IERC20(jrToken).balanceOf(buyUser);
        uint256 userUaAfter = IERC20(uaToken).balanceOf(buyUser);

        console.log("=== CHANGES ===");
        console.log("UA input:", buyAmount / 1e18);
        console.log("jrPRIME received:", (userJrAfter - userJrBefore) / 1e18);
        console.log("Dust UA received:", userUaAfter / 1e18);

        assertGt(userJrAfter - userJrBefore, 0);
    }

    // Pool Liquidity = [-1000t, 1000t], 3 Million liquidity PRIME/srPRIME
    // Pool ratio: ~0.98:1 (PRIME/srPRIME) after price adjustment
    function test_SwapSeniorToJunior_Success() public {
        address jrToken = market.jrToken();
        address srToken = market.srToken();
        address uaToken = market.uaToken();
        uint256 swapAmount = 1_000e18;

        _adjustPoolPriceBySellingSr(600_000e18);

        uint256 userSlippage = 9850;
        (uint256 uaToBorrow, uint256 minJrOut) = _calculateUnderlyingToBorrow(swapAmount, userSlippage);

        console.log("=== OFF-CHAIN CALCULATION ===");
        console.log("minJrOut (with 1.5% slippage):", minJrOut / 1e18);
        console.log("uaToBorrow:", uaToBorrow / 1e18);

        uint256 userJrBefore = IERC20(jrToken).balanceOf(user3);
        uint256 userSrBefore = IERC20(srToken).balanceOf(user3);
        uint256 userUaBefore = IERC20(uaToken).balanceOf(user3);

        vm.startPrank(user3);
        IERC20(srToken).approve(address(router), swapAmount);
        router.swapSeniorToJunior(address(market), swapAmount, uaToBorrow, minJrOut, block.timestamp + 1 minutes);
        vm.stopPrank();

        uint256 userJrAfter = IERC20(jrToken).balanceOf(user3);
        uint256 userSrAfter = IERC20(srToken).balanceOf(user3);
        uint256 userUaAfter = IERC20(uaToken).balanceOf(user3);

        console.log("=== CHANGES ===");
        console.log("srPRIME swapped:", (userSrBefore - userSrAfter) / 1e18);
        console.log("jrPRIME received:", (userJrAfter - userJrBefore) / 1e18);
        console.log("Dust UA received:", (userUaAfter - userUaBefore) / 1e18);

        assertEq(userSrBefore - userSrAfter, swapAmount);
        assertGt(userJrAfter - userJrBefore, 0);
    }   

    function test_BuySenior_Success() public {
        address buyUser = makeAddr("buyUser");
        uint256 buyAmount = 100_000e18;
        prime.mint(buyUser, buyAmount);

        address srToken = market.srToken();

        uint256 poolPrimeBefore = prime.balanceOf(uniswapPool);
        uint256 poolSrBefore = IERC20(srToken).balanceOf(uniswapPool);

        vm.startPrank(buyUser);
        prime.approve(address(router), buyAmount);
        uint256 srOut = router.buySenior(address(market), buyAmount, 0, block.timestamp + 1 hours);
        vm.stopPrank();

        uint256 poolPrimeAfter = prime.balanceOf(uniswapPool);
        uint256 poolSrAfter = IERC20(srToken).balanceOf(uniswapPool);

        assertGt(srOut, 0);
        assertGt(poolPrimeAfter, poolPrimeBefore);
        assertLt(poolSrAfter, poolSrBefore);
    }

    function test_SellSenior_Success() public {
        address srToken = market.srToken();
        uint256 sellAmount = 10_000e18;

        uint256 userSrBefore = IERC20(srToken).balanceOf(user1);
        uint256 userPrimeBefore = prime.balanceOf(user1);
        vm.startPrank(user1);
        IERC20(srToken).approve(address(router), sellAmount);
        uint256 uaOut = router.sellSenior(address(market), sellAmount, 0, block.timestamp + 1 hours);
        vm.stopPrank();

        uint256 userSrAfter = IERC20(srToken).balanceOf(user1);
        uint256 userPrimeAfter = prime.balanceOf(user1);

        assertEq(userSrBefore - userSrAfter, sellAmount);
        assertEq(userPrimeAfter - userPrimeBefore, uaOut);
        assertGt(uaOut, 0);
    }
}