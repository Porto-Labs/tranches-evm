// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import { BaseForkTest } from "./BaseForkTest.sol";
import { TrancheToken } from "src/core/TrancheToken.sol";
import { IERC20 } from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import { IUniswapV3Pool } from "@uniswap/v3-core/contracts/interfaces/IUniswapV3Pool.sol";
import { Math } from "@openzeppelin/contracts/utils/math/Math.sol";
import { IRouter } from "src/interfaces/IRouter.sol";
import { Errors } from "src/errors/Errors.sol";
import { console } from "forge-std/Test.sol";

interface IQuoterV2 {
    struct QuoteExactInputSingleParams {
        address tokenIn;
        address tokenOut;
        uint256 amountIn;
        uint24 fee;
        uint160 sqrtPriceLimitX96;
    }

    function quoteExactInputSingle(
        QuoteExactInputSingleParams memory params
    ) external returns (uint256 amountOut, uint160 sqrtPriceX96After, uint32 initializedTicksCrossed, uint256 gasEstimate);
}

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

        // 5,000,000 srPRIME : 5,000,000 PRIME
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
        router.sellSenior(sellAmount, 0, block.timestamp + 1 hours);
        vm.stopPrank();
    }

    function _calculateUnderlyingToBorrow(
        uint256 swapAmount,
        uint256 userSlippageBps
    ) internal view returns (uint256 uaToBorrow, uint256 minJrOut) {
        //@note Do we need uaAmtOut = quoteExactInputSingle(srUAToken, uaToken, fee, srIn, 0)
        // for calculating of the P_sr = uaAmtOut / srIn, since we have
        // seniorPrice from pool.slot0();

        address srToken = market.srToken();

        IUniswapV3Pool pool = IUniswapV3Pool(uniswapPool);
        (uint160 sqrtPriceX96, , , , , , ) = pool.slot0();

        uint256 seniorPrice;
        if (address(prime) < srToken) {
            seniorPrice = (uint256(1) << 192) * 1e18 / (uint256(sqrtPriceX96) * uint256(sqrtPriceX96));
        } else {
            seniorPrice = (uint256(sqrtPriceX96) * uint256(sqrtPriceX96) * 1e18) >> 192;
        }

        uint256 R = (SENIOR_RATIO * 1e18) / JUNIOR_RATIO;
        uint256 juniorPrice = (1e18 + R) - (seniorPrice * R / 1e18);

        uint256 expectedJrOut = (swapAmount * seniorPrice) / juniorPrice;
        minJrOut = expectedJrOut * userSlippageBps / 10000;

        // uaToBorrow = (srIn × P_sr) / (1 - srWeight × P_sr)
        uint256 denominator = 1e18 - (SENIOR_RATIO * seniorPrice / 1e18);
        uaToBorrow = (swapAmount * seniorPrice) / denominator;

        uaToBorrow = uaToBorrow * 99 / 100; // 1% buffer
    }

    function _calculateFromUaInput(
        uint256 uaIn,
        uint256 userSlippageBps
    ) internal view returns (uint256 uaToBorrow, uint256 minJrOut) {
        address srToken = market.srToken();

        IUniswapV3Pool pool = IUniswapV3Pool(uniswapPool);
        (uint160 sqrtPriceX96, , , , , , ) = pool.slot0();

        uint256 seniorPrice;
        if (address(prime) < srToken) {
            seniorPrice = (uint256(1) << 192) * 1e18 / (uint256(sqrtPriceX96) * uint256(sqrtPriceX96));
        } else {
            seniorPrice = (uint256(sqrtPriceX96) * uint256(sqrtPriceX96) * 1e18) >> 192;
        }

        uint256 R = (SENIOR_RATIO * 1e18) / JUNIOR_RATIO;
        uint256 juniorPrice = (1e18 + R) - (seniorPrice * R / 1e18);

        // jrOut = uaIn / P_jr
        uint256 expectedJrOut = uaIn * 1e18 / juniorPrice;
        minJrOut = expectedJrOut * userSlippageBps / 10000;

        // uaToBorrow = (uaIn × srWeight × P_sr) / (1 - srWeight × P_sr)
        uint256 denominator = 1e18 - (SENIOR_RATIO * seniorPrice / 1e18);
        uaToBorrow = (uaIn * SENIOR_RATIO / 1e18 * seniorPrice) / denominator;

        uaToBorrow = uaToBorrow * 99 / 100; // 1% buffer
    }

    function _calculateFromJrInput(
        uint256 jrIn,
        uint256 userSlippageBps
    ) internal view returns (uint256 uaToBorrow, uint256 minUaOut) {
        address srToken = market.srToken();

        IUniswapV3Pool pool = IUniswapV3Pool(uniswapPool);
        (uint160 sqrtPriceX96, , , , , , ) = pool.slot0();

        uint256 seniorPrice;
        if (address(prime) < srToken) {
            seniorPrice = (uint256(1) << 192) * 1e18 / (uint256(sqrtPriceX96) * uint256(sqrtPriceX96));
        } else {
            seniorPrice = (uint256(sqrtPriceX96) * uint256(sqrtPriceX96) * 1e18) >> 192;
        }

        // srNeeded = jrIn × R (where R = srWeight/jrWeight)
        uint256 srNeeded = jrIn * SENIOR_RATIO / JUNIOR_RATIO;

        // uaToBorrow = srNeeded / P_sr (to buy senior on Uniswap)
        uaToBorrow = srNeeded * 1e18 / seniorPrice;

        // uaFromRedeem = jrIn / jrWeight
        uint256 uaFromRedeem = jrIn * 1e18 / JUNIOR_RATIO;

        // expectedUaOut = uaFromRedeem - uaToBorrow
        uint256 expectedUaOut = uaFromRedeem - uaToBorrow;
        minUaOut = expectedUaOut * userSlippageBps / 10000;

        uaToBorrow = uaToBorrow * 101 / 100; // 1% buffer (borrow slightly more to ensure we can buy enough SR)
    }

    // ============ Tests ============

    function test_SetupComplete() public view {
        TrancheToken srToken = TrancheToken(market.srToken());
        TrancheToken jrToken = TrancheToken(market.jrToken());

        assertGt(srToken.balanceOf(user1), 0);
        assertGt(jrToken.balanceOf(user1), 0);
        assertGt(srToken.balanceOf(user2), 0);
        assertGt(jrToken.balanceOf(user2), 0);
        assertGt(srToken.balanceOf(user3), 0);
        assertGt(jrToken.balanceOf(user3), 0);

        assertEq(address(router.trancheMarket()), address(market));
        assertEq(address(router.morpho()), morpho);
    }

    // User buy 100,000 srPRIME from Uniswap pool, the price impact changes the PRIME/srPRIME ratio
    // Initial ratio is 1:1, after buy it should be > 1:1. Result: ~1.056:1
    // This simulates a user buying senior tranche tokens from the liquidity pool
    function test_BuySenior_RatioChange() public {
        address buyUser = makeAddr("buyUser");
        uint256 buyAmount = 100_000e18;
        prime.mint(buyUser, buyAmount);

        IUniswapV3Pool pool = IUniswapV3Pool(uniswapPool);
        address srToken = market.srToken();

        (uint160 sqrtPriceX96Before, , , , , , ) = pool.slot0();
        uint256 poolPrimeBefore = prime.balanceOf(uniswapPool);
        uint256 poolSrBefore = IERC20(srToken).balanceOf(uniswapPool);

        console.log("=== BEFORE BUY SENIOR ===");
        console.log("sqrtPriceX96:", sqrtPriceX96Before);
        console.log("Pool PRIME balance:", poolPrimeBefore / 1e18);  // 3625000
        console.log("Pool srPRIME balance:", poolSrBefore / 1e18);   // 3625000
        console.log("Ratio (PRIME/srPRIME):", (poolPrimeBefore * 1e18) / poolSrBefore); // 1:1 = 1e18

        vm.startPrank(buyUser);
        prime.approve(address(router), buyAmount);
        uint256 srOut = router.buySenior(buyAmount, 0, block.timestamp + 1 hours);
        vm.stopPrank();

        (uint160 sqrtPriceX96After, , , , , , ) = pool.slot0();
        uint256 poolPrimeAfter = prime.balanceOf(uniswapPool);
        uint256 poolSrAfter = IERC20(srToken).balanceOf(uniswapPool);

        console.log("");
        console.log("=== AFTER BUY SENIOR ===");

        // Uniswap 0.05% fee: ~50 PRIME worth
        // Price impact/slippage: ~2.68% due to moving the price as you swap
        // User loss is ~2.73% total, so for 100,000 PRIME in, they get ~97,268 srPRIME out
        console.log("User bought srPRIME:", srOut / 1e18);  // 97268

        console.log("sqrtPriceX96:", sqrtPriceX96After);    // 81412674195174881191349275439
        console.log("Pool PRIME balance:", poolPrimeAfter / 1e18); // 3725000
        console.log("Pool srPRIME balance:", poolSrAfter / 1e18);  // 3527731
        console.log("Ratio (PRIME/srPRIME):", (poolPrimeAfter * 1e18) / poolSrAfter); // ~1.056 = 1055919239001189060

        console.log("");
        console.log("=== CHANGES ===");
        console.log("PRIME added to pool:", (poolPrimeAfter - poolPrimeBefore) / 1e18); // 100000
        console.log("srPRIME removed from pool:", (poolSrBefore - poolSrAfter) / 1e18); // 97268

        assertGt(srOut, 0);
        assertGt(poolPrimeAfter, poolPrimeBefore);
        assertLt(poolSrAfter, poolSrBefore);
    }

    // ============ SellSenior Tests ============

    // User sells 10,000 srPRIME to Uniswap pool for PRIME
    // This is the reverse of buySenior - selling srTokens back to the pool
    function test_SellSenior_Success() public {
        address srToken = market.srToken();
        uint256 sellAmount = 10_000e18;

        uint256 userSrBefore = IERC20(srToken).balanceOf(user1);
        uint256 userPrimeBefore = prime.balanceOf(user1);
        uint256 poolPrimeBefore = prime.balanceOf(uniswapPool);
        uint256 poolSrBefore = IERC20(srToken).balanceOf(uniswapPool);

        console.log("=== BEFORE SELL SENIOR ===");
        console.log("User srPRIME balance:", userSrBefore / 1e18);
        console.log("User PRIME balance:", userPrimeBefore / 1e18);
        console.log("Pool PRIME balance:", poolPrimeBefore / 1e18);
        console.log("Pool srPRIME balance:", poolSrBefore / 1e18);

        vm.startPrank(user1);
        uint256 gasBefore = gasleft();

        IERC20(srToken).approve(address(router), sellAmount);
        uint256 uaOut = router.sellSenior(sellAmount, 0, block.timestamp + 1 hours);

        uint256 gasUsed = gasBefore - gasleft();
        console.log("Gas used for sellSenior:", gasUsed);

        vm.stopPrank();

        uint256 userSrAfter = IERC20(srToken).balanceOf(user1);
        uint256 userPrimeAfter = prime.balanceOf(user1);
        uint256 poolPrimeAfter = prime.balanceOf(uniswapPool);
        uint256 poolSrAfter = IERC20(srToken).balanceOf(uniswapPool);

        console.log("");
        console.log("=== AFTER SELL SENIOR ===");
        // Uniswap 0.05% fee + price impact
        console.log("User received PRIME:", uaOut / 1e18);
        console.log("User srPRIME balance:", userSrAfter / 1e18);
        console.log("User PRIME balance:", userPrimeAfter / 1e18);
        console.log("Pool PRIME balance:", poolPrimeAfter / 1e18);
        console.log("Pool srPRIME balance:", poolSrAfter / 1e18);

        console.log("");
        console.log("=== CHANGES ===");
        console.log("srPRIME sold:", sellAmount / 1e18);
        console.log("PRIME received:", uaOut / 1e18);
        console.log("Loss from swap:", (sellAmount - uaOut) * 100 / sellAmount, "% (fee + slippage)");

        assertEq(userSrBefore - userSrAfter, sellAmount);
        assertEq(userPrimeAfter - userPrimeBefore, uaOut);
        assertGt(uaOut, 0);
    }

    // ============ BuyJunior Tests ============

    // Pool Liquidity = [-1000t, 1000t], 5 Million liquidity PRIME/srPRIME
    // Pool ratio: 0.98:1 (PRIME/srPRIME) after price adjustment
    // Input:       10,000 PRIME
    // Output:      9,901  jrPRIME
    // minJrOut: 	9,774  jrPRIME (2% slippage
    // UA dust:     52     PRIME
    function test_BuyJunior_Success() public {
        // forge test --match-test test_BuyJunior_Success -vvv
        address jrToken = market.jrToken();
        address uaToken = market.uaToken();

        address buyUser = makeAddr("buyJuniorUser");
        uint256 buyAmount = 10_000e18; // uaIn
        prime.mint(buyUser, buyAmount);

        // Move the ratio to 0.98
        _adjustPoolPriceBySellingSr(51_000e18);

        uint256 userSlippage = 9800; // 2%

        (uint256 uaToBorrow, uint256 minJrOut) = _calculateFromUaInput(buyAmount, userSlippage);

        console.log("=== OFF-CHAIN CALCULATION ===");
        console.log("minJrOut (with 2% slippage):", minJrOut / 1e18);
        console.log("uaToBorrow:", uaToBorrow / 1e18);

        uint256 userJrBefore = IERC20(jrToken).balanceOf(buyUser);

        vm.startPrank(buyUser);
        prime.approve(address(router), buyAmount);
        router.buyJunior(buyAmount, uaToBorrow, minJrOut, block.timestamp + 1 minutes);
        vm.stopPrank();

        uint256 userJrAfter = IERC20(jrToken).balanceOf(buyUser);
        uint256 userUaAfter = IERC20(uaToken).balanceOf(buyUser);

        console.log("=== CHANGES ===");
        console.log("UA input:", buyAmount / 1e18);
        console.log("jrPRIME received:", (userJrAfter - userJrBefore) / 1e18);
        console.log("Dust UA received:", userUaAfter / 1e18);

        assertGt(userJrAfter - userJrBefore, 0);
    }

    // Pool Liquidity = [-1000t, 1000t], 5 Million liquidity PRIME/srPRIME
    // Pool ratio: 0.98:1 (PRIME/srPRIME) after price adjustment
    // Input:    1,000  srPRIME
    // Output:   ~986   jrPRIME
    // UA dust:  8      PRIME 
    function test_SwapSeniorToJunior_Success() public {
        address jrToken = market.jrToken();
        address srToken = market.srToken();
        address uaToken = market.uaToken();
        uint256 swapAmount = 1000e18;

        // Move the ratio to 0.98
        _adjustPoolPriceBySellingSr(51_000e18);

        uint256 userSlippage = 9800; // 2% slippage | selected from UI
        (uint256 uaToBorrow, uint256 minJrOut) = _calculateUnderlyingToBorrow(swapAmount, userSlippage);

        console.log("=== OFF-CHAIN CALCULATION ===");
        console.log("minJrOut (with 2% slippage):", minJrOut / 1e18);
        console.log("uaToBorrow:", uaToBorrow / 1e18);

        uint256 userJrBefore = IERC20(jrToken).balanceOf(user1);
        uint256 userSrBefore = IERC20(srToken).balanceOf(user1);
        uint256 userUaBefore = IERC20(uaToken).balanceOf(user1);

        vm.startPrank(user1);
        IERC20(srToken).approve(address(router), swapAmount);
        router.swapSeniorToJunior(swapAmount, minJrOut, uaToBorrow, block.timestamp + 1 minutes);
        vm.stopPrank();

        uint256 userJrAfter = IERC20(jrToken).balanceOf(user1);
        uint256 userSrAfter = IERC20(srToken).balanceOf(user1);
        uint256 userUaAfter = IERC20(uaToken).balanceOf(user1);

        console.log("=== CHANGES ===");
        console.log("srPRIME swapped:", (userSrBefore - userSrAfter) / 1e18);
        console.log("jrPRIME received:", (userJrAfter - userJrBefore) / 1e18);
        console.log("Dust UA received:", (userUaAfter - userUaBefore) / 1e18);

        assertEq(userSrBefore - userSrAfter, swapAmount);
        assertGt(userJrAfter - userJrBefore, 0);
    }

    function test_ComparePriceEstimationMethods() public {
        address srToken = market.srToken();
        IUniswapV3Pool pool = IUniswapV3Pool(uniswapPool);
        IQuoterV2 quoter = IQuoterV2(UNISWAP_V3_QUOTER_V2_SEPOLIA);

        _adjustPoolPriceBySellingSr(51_000e18);

        address buyUser = makeAddr("buyUser");
        uint256 uaIn = 10_000e18;
        prime.mint(buyUser, uaIn);

        (uint160 sqrtPriceX96, , , , , , ) = pool.slot0();

        uint256 slot0SrOut;
        if (address(prime) < srToken) {
            slot0SrOut = Math.mulDiv(Math.mulDiv(uaIn, sqrtPriceX96, 1 << 96), sqrtPriceX96, 1 << 96);
        } else {
            slot0SrOut = Math.mulDiv(Math.mulDiv(uaIn, 1 << 96, sqrtPriceX96), 1 << 96, sqrtPriceX96);
        }

        uint256 slot0WithBufferSrOut = slot0SrOut * 99 / 100;

        IQuoterV2.QuoteExactInputSingleParams memory quoteParams = IQuoterV2.QuoteExactInputSingleParams({
            tokenIn: address(prime),
            tokenOut: srToken,
            amountIn: uaIn,
            fee: POOL_FEE,
            sqrtPriceLimitX96: 0
        });
        (uint256 quoterSrOut, , , ) = quoter.quoteExactInputSingle(quoteParams);

        vm.startPrank(buyUser);
        prime.approve(address(router), uaIn);
        uint256 actualSrOut = router.buySenior(uaIn, 0, block.timestamp + 1 hours);
        vm.stopPrank();

        console.log("=== PRICE ESTIMATION COMPARISON ===");
        console.log("Input: %s PRIME", uaIn / 1e18);
        console.log("");
        console.log("--- SR Output Estimates ---");
        console.log("slot0 price calculation:    %s", slot0SrOut / 1e18);
        console.log("slot0 with 1%% buffer:       %s", slot0WithBufferSrOut / 1e18);
        console.log("Quoter estimate:            %s", quoterSrOut / 1e18);
        console.log("Actual execution:           %s", actualSrOut / 1e18);
        console.log("");
        console.log("--- Differences from Actual ---");

        int256 slot0Diff = int256(slot0SrOut) - int256(actualSrOut);
        int256 slot0BufferedDiff = int256(slot0WithBufferSrOut) - int256(actualSrOut);
        int256 quoterDiff = int256(quoterSrOut) - int256(actualSrOut);

        console.log("slot0 vs actual:");
        if (slot0Diff >= 0) {
            console.log("  +%s", uint256(slot0Diff) / 1e18);
        } else {
            console.log("  -%s", uint256(-slot0Diff) / 1e18);
        }

        console.log("slot0 buffered vs actual:");
        if (slot0BufferedDiff >= 0) {
            console.log("  +%s (BUFFER INSUFFICIENT)", uint256(slot0BufferedDiff) / 1e18);
        } else {
            console.log("  -%s (buffer OK)", uint256(-slot0BufferedDiff) / 1e18);
        }

        console.log("Quoter vs actual:");
        if (quoterDiff >= 0) {
            console.log("  +%s", uint256(quoterDiff) / 1e18);
        } else {
            console.log("  -%s", uint256(-quoterDiff) / 1e18);
        }

        console.log("");
        console.log("--- Percentage Differences ---");
        uint256 slot0PctDiff = slot0Diff >= 0
            ? (uint256(slot0Diff) * 10000) / actualSrOut
            : (uint256(-slot0Diff) * 10000) / actualSrOut;
        uint256 slot0BufferedPctDiff = slot0BufferedDiff >= 0
            ? (uint256(slot0BufferedDiff) * 10000) / actualSrOut
            : (uint256(-slot0BufferedDiff) * 10000) / actualSrOut;
        uint256 quoterPctDiff = quoterDiff >= 0
            ? (uint256(quoterDiff) * 10000) / actualSrOut
            : (uint256(-quoterDiff) * 10000) / actualSrOut;

        console.log("slot0 difference:         %s.%s%s%%", slot0PctDiff / 100, (slot0PctDiff % 100) / 10, slot0PctDiff % 10);
        console.log("slot0 buffered difference: %s.%s%s%%", slot0BufferedPctDiff / 100, (slot0BufferedPctDiff % 100) / 10, slot0BufferedPctDiff % 10);
        console.log("Quoter difference:        %s.%s%s%%", quoterPctDiff / 100, (quoterPctDiff % 100) / 10, quoterPctDiff % 10);

        console.log("");
        console.log("--- Raw Values (18 decimals) ---");
        console.log("slot0SrOut:           %s", slot0SrOut);
        console.log("slot0WithBufferSrOut: %s", slot0WithBufferSrOut);
        console.log("quoterSrOut:          %s", quoterSrOut);
        console.log("actualSrOut:          %s", actualSrOut);
    }

    function test_BufferAccuracyAcrossAmounts() public {
        address srToken = market.srToken();
        IUniswapV3Pool pool = IUniswapV3Pool(uniswapPool);
        IQuoterV2 quoter = IQuoterV2(UNISWAP_V3_QUOTER_V2_SEPOLIA);

        _adjustPoolPriceBySellingSr(51_000e18);

        uint256[5] memory amounts = [uint256(1_000e18), 10_000e18, 50_000e18, 100_000e18, 500_000e18];

        console.log("=== BUFFER ACCURACY ANALYSIS ===");
        console.log("Testing 1%% buffer effectiveness across swap amounts");
        console.log("Pool state: After selling 51,000 srPRIME (ratio ~0.98:1)");
        console.log("");
        console.log("Amount (UA) | slot0 Est | Buffered | Quoter | Actual | slot0 Err | Buffered Err | Buffer OK?");
        console.log("------------|-----------|----------|--------|--------|-----------|--------------|----------");

        for (uint256 i = 0; i < amounts.length; i++) {
            uint256 uaIn = amounts[i];

            address buyUser = makeAddr(string(abi.encodePacked("buyer", i)));
            prime.mint(buyUser, uaIn);

            (uint160 sqrtPriceX96, , , , , , ) = pool.slot0();

            uint256 slot0SrOut;
            if (address(prime) < srToken) {
                slot0SrOut = Math.mulDiv(Math.mulDiv(uaIn, sqrtPriceX96, 1 << 96), sqrtPriceX96, 1 << 96);
            } else {
                slot0SrOut = Math.mulDiv(Math.mulDiv(uaIn, 1 << 96, sqrtPriceX96), 1 << 96, sqrtPriceX96);
            }

            uint256 slot0WithBufferSrOut = slot0SrOut * 99 / 100;

            IQuoterV2.QuoteExactInputSingleParams memory quoteParams = IQuoterV2.QuoteExactInputSingleParams({
                tokenIn: address(prime),
                tokenOut: srToken,
                amountIn: uaIn,
                fee: POOL_FEE,
                sqrtPriceLimitX96: 0
            });
            (uint256 quoterSrOut, , , ) = quoter.quoteExactInputSingle(quoteParams);

            vm.startPrank(buyUser);
            prime.approve(address(router), uaIn);
            uint256 actualSrOut = router.buySenior(uaIn, 0, block.timestamp + 1 hours);
            vm.stopPrank();

            int256 slot0Err = int256(slot0SrOut) - int256(actualSrOut);
            int256 bufferedErr = int256(slot0WithBufferSrOut) - int256(actualSrOut);

            uint256 slot0ErrPct = slot0Err >= 0
                ? (uint256(slot0Err) * 10000) / actualSrOut
                : (uint256(-slot0Err) * 10000) / actualSrOut;
            uint256 bufferedErrPct = bufferedErr >= 0
                ? (uint256(bufferedErr) * 10000) / actualSrOut
                : (uint256(-bufferedErr) * 10000) / actualSrOut;

            bool bufferOk = bufferedErr <= 0;

            console.log("--- Amount: %s UA ---", uaIn / 1e18);
            console.log("  slot0 Est:    %s | Buffered: %s", slot0SrOut / 1e18, slot0WithBufferSrOut / 1e18);
            console.log("  Quoter Est:   %s | Actual:   %s", quoterSrOut / 1e18, actualSrOut / 1e18);

            if (slot0Err >= 0) {
                console.log("  slot0 Error:  +%s.%s%s%%", slot0ErrPct / 100, (slot0ErrPct % 100) / 10, slot0ErrPct % 10);
            } else {
                console.log("  slot0 Error:  -%s.%s%s%%", slot0ErrPct / 100, (slot0ErrPct % 100) / 10, slot0ErrPct % 10);
            }

            if (bufferedErr >= 0) {
                console.log("  Buffered Err: +%s.%s%s%% (BUFFER INSUFFICIENT)", bufferedErrPct / 100, (bufferedErrPct % 100) / 10, bufferedErrPct % 10);
            } else {
                console.log("  Buffered Err: -%s.%s%s%% (buffer OK)", bufferedErrPct / 100, (bufferedErrPct % 100) / 10, bufferedErrPct % 10);
            }

            console.log("  Buffer OK: %s", bufferOk ? "YES" : "NO");
            console.log("");
        }

        console.log("=== RAW DATA (18 decimals) ===");

        for (uint256 i = 0; i < amounts.length; i++) {
            uint256 uaIn = amounts[i];

            (uint160 sqrtPriceX96, , , , , , ) = pool.slot0();

            uint256 slot0SrOut;
            if (address(prime) < srToken) {
                slot0SrOut = Math.mulDiv(Math.mulDiv(uaIn, sqrtPriceX96, 1 << 96), sqrtPriceX96, 1 << 96);
            } else {
                slot0SrOut = Math.mulDiv(Math.mulDiv(uaIn, 1 << 96, sqrtPriceX96), 1 << 96, sqrtPriceX96);
            }

            IQuoterV2.QuoteExactInputSingleParams memory quoteParams = IQuoterV2.QuoteExactInputSingleParams({
                tokenIn: address(prime),
                tokenOut: srToken,
                amountIn: uaIn,
                fee: POOL_FEE,
                sqrtPriceLimitX96: 0
            });
            (uint256 quoterSrOut, , , ) = quoter.quoteExactInputSingle(quoteParams);

            console.log("Amount: %s", uaIn);
            console.log("  slot0:    %s", slot0SrOut);
            console.log("  buffered: %s", slot0SrOut * 99 / 100);
            console.log("  quoter:   %s", quoterSrOut);
        }
    }
}
