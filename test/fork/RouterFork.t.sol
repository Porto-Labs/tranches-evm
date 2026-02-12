// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import { BaseForkTest } from "./BaseForkTest.sol";
import { TrancheToken } from "src/core/TrancheToken.sol";
import { IERC20 } from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import { IUniswapV3Pool } from "@uniswap/v3-core/contracts/interfaces/IUniswapV3Pool.sol";
import { Math } from "@openzeppelin/contracts/utils/math/Math.sol";
import { IRouter } from "src/interfaces/IRouter.sol";
import { console, Vm } from "forge-std/Test.sol";
import { IQuoterV2 } from "@uniswap/v3-periphery/contracts/interfaces/IQuoterV2.sol";

contract RouterFork is BaseForkTest {
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
        uint256 user3Deposit = 375_000e18;

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

    function _calculateFromSrInput(uint256 srIn, uint256 userSlippageBps)
        internal
        returns (uint256 uaToBorrow, uint256 minJrOut)
    {
        // On-chain: totalSr = srIn + uaBorrowed * seniorRatio
        //   uaReceived = swap(totalSr) must >= uaBorrowed
        //
        // Closed-form: uaToBorrow = srIn * P_eff / (1 - seniorRatio * P_eff)
        // where P_eff = effective SR price after swap impact (from quoter)
        //
        // Steps:
        // 1) Get spot price, compute initial uaToBorrow estimate
        // 2) Compute totalSr at that estimate, quote the swap → get effective price
        // 3) Recompute uaToBorrow using the effective price (closed-form)

        uint256 effectivePrice;
        {
            address srToken = market.srToken();

            uint256 spotPrice;
            {
                IUniswapV3Pool pool = IUniswapV3Pool(uniswapPool);
                (uint160 sqrtPriceX96,,,,,,) = pool.slot0();
                if (address(prime) < srToken) {
                    spotPrice = (uint256(1) << 192) * 1e18 / (uint256(sqrtPriceX96) * uint256(sqrtPriceX96));
                } else {
                    spotPrice = (uint256(sqrtPriceX96) * uint256(sqrtPriceX96) * 1e18) >> 192;
                }
            }

            uint256 initialBorrow = srIn * spotPrice / (1e18 - SENIOR_RATIO * spotPrice / 1e18);
            uint256 totalSr = srIn + initialBorrow * SENIOR_RATIO / 1e18;

            IQuoterV2 quoter = IQuoterV2(UNISWAP_V3_QUOTER_V2_SEPOLIA);
            (uint256 uaFromSwap,,,) = quoter.quoteExactInputSingle(
                IQuoterV2.QuoteExactInputSingleParams({
                    tokenIn: srToken, tokenOut: address(prime), amountIn: totalSr, fee: POOL_FEE, sqrtPriceLimitX96: 0
                })
            );

            effectivePrice = uaFromSwap * 1e18 / totalSr;
        }

        uint256 numerator = srIn * effectivePrice / 1e18;
        uint256 denominator = 1e18 - (SENIOR_RATIO * effectivePrice / 1e18);
        uaToBorrow = numerator * 1e18 / denominator;

        uint256 expectedJrOut = uaToBorrow * JUNIOR_RATIO / 1e18;
        minJrOut = expectedJrOut * userSlippageBps / 10_000;
    }

    function _calculateFromUaInput(uint256 uaIn, uint256 userSlippageBps)
        internal
        returns (uint256 uaToBorrow, uint256 minJrOut)
    {
        // On-chain: totalUa = uaIn + uaToBorrow
        //   srMinted = totalUa * seniorRatio
        //   uaFromSwap = swap(srMinted) must >= uaToBorrow
        //
        // Closed-form: uaToBorrow = uaIn * seniorRatio * P_eff / (1 - seniorRatio * P_eff)
        // where P_eff = effective SR price after swap impact (from quoter)
        //
        //  P_eff  = effective SR price
        //  P_spot = spot SR price
        //
        // Steps:
        // 1) Get spot price, compute initial uaToBorrow estimate
        // 2) Compute srMinted at that estimate, quote the swap → get effective price
        // 3) Recompute uaToBorrow using the effective price (closed-form)

        uint256 effectivePrice;
        {
            address srToken = market.srToken();

            // initial spot price

            uint256 spotPrice;
            {
                IUniswapV3Pool pool = IUniswapV3Pool(uniswapPool);
                (uint160 sqrtPriceX96,,,,,,) = pool.slot0();
                if (address(prime) < srToken) {
                    spotPrice = (uint256(1) << 192) * 1e18 / (uint256(sqrtPriceX96) * uint256(sqrtPriceX96));
                } else {
                    spotPrice = (uint256(sqrtPriceX96) * uint256(sqrtPriceX96) * 1e18) >> 192;
                }
            }

            uint256 initialBorrow = uaIn * SENIOR_RATIO * spotPrice / (1e18 * 1e18 - SENIOR_RATIO * spotPrice);

            // approximates how much SR will actually be swapped
            uint256 srMinted = (uaIn + initialBorrow) * SENIOR_RATIO / 1e18;

            // this simulates the actual swap including fees and price impact
            IQuoterV2 quoter = IQuoterV2(UNISWAP_V3_QUOTER_V2_SEPOLIA);
            (uint256 uaFromSwap,,,) = quoter.quoteExactInputSingle(
                IQuoterV2.QuoteExactInputSingleParams({
                    tokenIn: srToken, tokenOut: address(prime), amountIn: srMinted, fee: POOL_FEE, sqrtPriceLimitX96: 0
                })
            );

            // P_eff
            effectivePrice = uaFromSwap * 1e18 / srMinted;
        }

        uint256 numerator = uaIn * SENIOR_RATIO / 1e18 * effectivePrice / 1e18;
        uint256 denominator = 1e18 - (SENIOR_RATIO * effectivePrice / 1e18);
        uaToBorrow = numerator * 1e18 / denominator;

        uint256 expectedJrOut = (uaIn + uaToBorrow) * JUNIOR_RATIO / 1e18;
        minJrOut = expectedJrOut * userSlippageBps / 10_000;
    }

    function _calculateFromJrInput(uint256 jrIn, uint256 userSlippageBps)
        internal
        returns (uint256 uaToBorrow, uint256 minUaOut)
    {
        // On-chain: srNeeded = jrIn * seniorRatio / juniorRatio
        //   uaSpent = swap(UA → srNeeded) exactOutput
        //   uaFromRecombine = recombine(srNeeded, jrIn) = jrIn / juniorRatio
        //   uaToUser = uaFromRecombine - uaSpent
        //
        // No circularity: srNeeded is deterministic from jrIn
        // Single quoter call gives exact uaSpent

        address srToken = market.srToken();

        uint256 srNeededOffChain = (jrIn * SENIOR_RATIO + JUNIOR_RATIO - 1) / JUNIOR_RATIO;
        uint256 srNeededRouter = router.calculateSeniorNeeded(jrIn, address(market));

        console.log("=== SR NEEDED CALCULATION ===");
        console.log("jrIn:", jrIn);
        console.log("SENIOR_RATIO:", SENIOR_RATIO);
        console.log("JUNIOR_RATIO:", JUNIOR_RATIO);
        console.log("srNeeded (off-chain):", srNeededOffChain);
        console.log("srNeeded (router):", srNeededRouter);

        console.log("");
        console.log("=== RECOMBINE RATIO CHECK PREVIEW ===");
        uint256 lhs = (srNeededRouter * JUNIOR_RATIO) / 1e18;
        uint256 rhs = (jrIn * SENIOR_RATIO) / 1e18;
        console.log("srIn * juniorRatio / 1e18:", lhs);
        console.log("jrIn * seniorRatio / 1e18:", rhs);
        console.log("Difference (should be 0):", rhs > lhs ? rhs - lhs : lhs - rhs);
        console.log("Will recombine pass?:", lhs == rhs ? "YES" : "NO");

        IQuoterV2 quoter = IQuoterV2(UNISWAP_V3_QUOTER_V2_SEPOLIA);
        (uint256 uaNeeded,,,) = quoter.quoteExactOutputSingle(
            IQuoterV2.QuoteExactOutputSingleParams({
                tokenIn: address(prime), tokenOut: srToken, amount: srNeededRouter, fee: POOL_FEE, sqrtPriceLimitX96: 0
            })
        );

        uaToBorrow = uaNeeded;

        uint256 uaFromRecombine = jrIn * 1e18 / JUNIOR_RATIO;
        uint256 expectedUaOut = uaFromRecombine - uaNeeded;
        minUaOut = expectedUaOut * userSlippageBps / 10_000;
    }

    // Pool Liquidity = [-1000t, 1000t], 3 Million liquidity PRIME/srPRIME
    // Pool ratio: 0.98:1 (PRIME/srPRIME) after price adjustment
    //
    // +-----------+---------+---------+----------+
    // | UA Input  | jrOut   | UA dust | minJrOut |
    // +-----------+---------+---------+----------+
    // |        10 |       9 |       0 |        9 |
    // |        50 |      47 |       0 |       46 |
    // |       500 |     475 |       0 |      465 |
    // |     1_000 |     950 |       0 |      931 |
    // |     4_000 |   3_800 |       0 |    3_724 |
    // |    10_000 |   9_496 |       0 |    9_306 |
    // |    20_000 |  18_974 |       0 |   18_595 |
    // |    50_000 |  47_296 |       1 |   46_350 |
    // |   100_000 |  94_131 |      10 |   92_248 |
    // |   300_000 | 277_038 |     252 |  271_497 |
    // |   450_000 | 409_808 |     802 |  401_612 |
    // |   750_000 | 664_943 |   3_364 |  651_644 |
    // | 1_000_000 | 867_865 |   7_402 |  850_507 |
    // | 1_500_000 | 768_820 | 628_479 |  753_443 | -> 50% swap of all liquidity
    // +-----------+---------+---------+----------+
    function test_BuyJunior_Success() public {
        address jrToken = market.jrToken();
        address uaToken = market.uaToken();

        address buyUser = makeAddr("buyJuniorUser");
        uint256 buyAmount = 100_000e18; // uaIn

        prime.mint(buyUser, buyAmount);

        // ~0.9803
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
    //
    // +-----------+---------+---------+----------+
    // | SR Input  | jrOut   | UA dust | minJrOut |
    // +-----------+---------+---------+----------+
    // |        10 |       9 |       0 |        9 |
    // |        50 |      46 |       0 |       45 |
    // |       500 |     465 |       0 |      456 |
    // |     1_000 |     931 |       0 |      913 |
    // |     4_000 |   3_724 |       0 |    3_650 |
    // |    10_000 |   9_300 |       0 |    9_114 |
    // |    20_000 |  18_566 |       0 |   18_194 |
    // |    50_000 |  46_149 |       3 |   45_226 |
    // |   100_000 |  91_427 |      26 |   89_599 |
    // |   200_000 | 179_465 |     198 |  175_876 |
    // |   271_000 | 240_017 |     472 |  235_216 |
    // |   500_000 | 425_027 |   2_665 |  416_527 |
    // |   750_000 | 582_901 |  42_477 |  571_243 |
    // | 1_000_000 | 385_454 | 512_706 |  377_745 |
    // +-----------+---------+---------+----------+
    function test_SwapSeniorToJunior_Success() public {
        address jrToken = market.jrToken();
        address srToken = market.srToken();
        address uaToken = market.uaToken();
        uint256 swapAmount = 1000e18;

        _adjustPoolPriceBySellingSr(600_000e18);

        uint256 userSlippage = 9800;
        (uint256 uaToBorrow, uint256 minJrOut) = _calculateFromSrInput(swapAmount, userSlippage);

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

    function test_BuyJunior_EmitEventWithUaDust() public {
        address jrToken = market.jrToken();
        address uaToken = market.uaToken();

        address buyUser = makeAddr("buyJuniorUser");
        uint256 buyAmount = 100_000e18;

        prime.mint(buyUser, buyAmount);
        _adjustPoolPriceBySellingSr(600_000e18);

        uint256 userSlippage = 9800;
        (uint256 uaToBorrow, uint256 minJrOut) = _calculateFromUaInput(buyAmount, userSlippage);

        vm.startPrank(buyUser);
        prime.approve(address(router), buyAmount);

        vm.recordLogs();
        router.buyJunior(address(market), buyAmount, uaToBorrow, minJrOut, block.timestamp + 1 minutes);
        vm.stopPrank();

        // BuyJunior is emitted in the callback; Morpho Approval + Transfer follow after repayment
        Vm.Log[] memory logs = vm.getRecordedLogs();
        (uint256 uaIn, uint256 jrOut, uint256 uaDust) =
            abi.decode(logs[logs.length - 3].data, (uint256, uint256, uint256));

        assertEq(uaIn, buyAmount);
        assertApproxEqAbs(jrOut, 94_131e18, 1e18);
        assertApproxEqAbs(uaDust, 10e18, 1e18);
        assertEq(uaDust, IERC20(uaToken).balanceOf(buyUser));
        assertEq(jrOut, IERC20(jrToken).balanceOf(buyUser));
    }

    function test_SwapSeniorToJunior_EmitEventWithUaDust() public {
        address srToken = market.srToken();
        address uaToken = market.uaToken();
        address jrToken = market.jrToken();
        uint256 swapAmount = 100_000e18;

        _adjustPoolPriceBySellingSr(600_000e18);

        uint256 userSlippage = 9800;
        (uint256 uaToBorrow, uint256 minJrOut) = _calculateFromSrInput(swapAmount, userSlippage);

        uint256 userUaBefore = IERC20(uaToken).balanceOf(user3);
        uint256 userJrBefore = IERC20(jrToken).balanceOf(user3);

        vm.startPrank(user3);
        IERC20(srToken).approve(address(router), swapAmount);

        vm.recordLogs();
        router.swapSeniorToJunior(address(market), swapAmount, uaToBorrow, minJrOut, block.timestamp + 1 minutes);
        vm.stopPrank();

        // SwapSeniorToJunior is emitted in the callback; Morpho Approval + Transfer follow after repayment
        Vm.Log[] memory logs = vm.getRecordedLogs();
        (uint256 srIn, uint256 jrOut, uint256 uaDust) =
            abi.decode(logs[logs.length - 3].data, (uint256, uint256, uint256));

        assertEq(srIn, swapAmount);
        assertApproxEqAbs(jrOut, 91_427e18, 1e18);
        assertApproxEqAbs(uaDust, 26e18, 1e18);
        assertEq(uaDust, IERC20(uaToken).balanceOf(user3) - userUaBefore);
        assertEq(jrOut, IERC20(jrToken).balanceOf(user3) - userJrBefore);
    }

    function _calculateJrToSrSwap(uint256 jrIn, uint256 userSlippageBps)
        internal
        returns (uint256 uaToBorrow, uint256 minSrOut)
    {
        address srToken = market.srToken();

        uint256 srNeededRouter = router.calculateSeniorNeeded(jrIn, address(market));

        IQuoterV2 quoter = IQuoterV2(UNISWAP_V3_QUOTER_V2_SEPOLIA);
        (uint256 uaNeeded,,,) = quoter.quoteExactOutputSingle(
            IQuoterV2.QuoteExactOutputSingleParams({
                tokenIn: address(prime),
                tokenOut: srToken,
                amount: srNeededRouter,
                fee: POOL_FEE,
                sqrtPriceLimitX96: 0
            })
        );

        uaToBorrow = uaNeeded;

        uint256 uaFromRecombine = jrIn * 1e18 / JUNIOR_RATIO;
        uint256 remainingUa = uaFromRecombine - uaNeeded;

        (uint256 expectedSrOut,,,) = quoter.quoteExactInputSingle(
            IQuoterV2.QuoteExactInputSingleParams({
                tokenIn: address(prime),
                tokenOut: srToken,
                amountIn: remainingUa,
                fee: POOL_FEE,
                sqrtPriceLimitX96: 0
            })
        );

        minSrOut = expectedSrOut * userSlippageBps / 10_000;
    }

    function test_SwapJuniorToSenior_Success() public {
        address jrToken = market.jrToken();
        address srToken = market.srToken();
        uint256 swapAmount = 10_000e18;

        _adjustPoolPriceBySellingSr(600_000e18);

        uint256 userSlippage = 9800;
        (uint256 uaToBorrow, uint256 minSrOut) = _calculateJrToSrSwap(swapAmount, userSlippage);

        uint256 userJrBefore = IERC20(jrToken).balanceOf(user1);
        uint256 userSrBefore = IERC20(srToken).balanceOf(user1);

        vm.startPrank(user1);
        IERC20(jrToken).approve(address(router), swapAmount);
        router.swapJuniorToSenior(address(market), swapAmount, uaToBorrow, minSrOut, block.timestamp + 1 minutes);
        vm.stopPrank();

        uint256 userJrAfter = IERC20(jrToken).balanceOf(user1);
        uint256 userSrAfter = IERC20(srToken).balanceOf(user1);

        assertEq(userJrBefore - userJrAfter, swapAmount);
        assertGt(userSrAfter - userSrBefore, 0);
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

    function test_SellJunior_Success() public {
        address jrToken = market.jrToken();
        address uaToken = market.uaToken();

        uint256 sellAmount = 10_000e18;

        _adjustPoolPriceBySellingSr(600_000e18);

        uint256 userSlippage = 9800; // 2%
        (uint256 uaToBorrow, uint256 minUaOut) = _calculateFromJrInput(sellAmount, userSlippage);

        console.log("=== OFF-CHAIN CALCULATION ===");
        console.log("minUaOut (with 2% slippage):", minUaOut / 1e18);
        console.log("uaToBorrow:", uaToBorrow / 1e18);

        uint256 userJrBefore = IERC20(jrToken).balanceOf(user1);
        uint256 userUaBefore = IERC20(uaToken).balanceOf(user1);

        vm.startPrank(user1);
        IERC20(jrToken).approve(address(router), sellAmount);
        router.sellJunior(address(market), sellAmount, uaToBorrow, minUaOut, block.timestamp + 1 minutes);
        vm.stopPrank();

        uint256 userJrAfter = IERC20(jrToken).balanceOf(user1);
        uint256 userUaAfter = IERC20(uaToken).balanceOf(user1);

        console.log("=== CHANGES ===");
        console.log("jrPRIME sold:", (userJrBefore - userJrAfter) / 1e18);
        console.log("UA received:", (userUaAfter - userUaBefore) / 1e18);

        assertEq(userJrBefore - userJrAfter, sellAmount);
        assertGt(userUaAfter - userUaBefore, 0);
    }

    // ============ InsufficientOutput Revert Tests ============

    function test_RevertWhen_BuySenior_InsufficientOutput() public {
        address buyUser = makeAddr("buyUser");
        uint256 buyAmount = 100_000e18;
        prime.mint(buyUser, buyAmount);

        uint256 minSrOut = buyAmount * 2;

        vm.startPrank(buyUser);
        prime.approve(address(router), buyAmount);
        vm.expectRevert();
        router.buySenior(address(market), buyAmount, minSrOut, block.timestamp + 1 hours);
        vm.stopPrank();
    }

    function test_RevertWhen_SellSenior_InsufficientOutput() public {
        uint256 sellAmount = 10_000e18;
        uint256 minUaOut = sellAmount * 2;

        vm.startPrank(user1);
        IERC20(market.srToken()).approve(address(router), sellAmount);
        vm.expectRevert();
        router.sellSenior(address(market), sellAmount, minUaOut, block.timestamp + 1 hours);
        vm.stopPrank();
    }

    function test_RevertWhen_BuyJunior_InsufficientOutput() public {
        address buyUser = makeAddr("buyJuniorUser");
        uint256 buyAmount = 100_000e18;

        prime.mint(buyUser, buyAmount);
        _adjustPoolPriceBySellingSr(600_000e18);

        (uint256 uaToBorrow, uint256 expectedJrOut) = _calculateFromUaInput(buyAmount, 10_000);
        uint256 minJrOut = expectedJrOut * 2;

        vm.startPrank(buyUser);
        prime.approve(address(router), buyAmount);
        vm.expectRevert(IRouter.InsufficientOutput.selector);
        router.buyJunior(address(market), buyAmount, uaToBorrow, minJrOut, block.timestamp + 1 minutes);
        vm.stopPrank();
    }

    function test_RevertWhen_SellJunior_InsufficientOutput() public {
        uint256 sellAmount = 10_000e18;

        _adjustPoolPriceBySellingSr(600_000e18);

        (uint256 uaToBorrow, uint256 expectedUaOut) = _calculateFromJrInput(sellAmount, 10_000);
        uint256 minUaOut = expectedUaOut * 2;

        vm.startPrank(user1);
        IERC20(market.jrToken()).approve(address(router), sellAmount);
        vm.expectRevert(IRouter.InsufficientOutput.selector);
        router.sellJunior(address(market), sellAmount, uaToBorrow, minUaOut, block.timestamp + 1 minutes);
        vm.stopPrank();
    }

    function test_RevertWhen_SwapJuniorToSenior_InsufficientOutput() public {
        uint256 swapAmount = 10_000e18;

        _adjustPoolPriceBySellingSr(600_000e18);

        (uint256 uaToBorrow, uint256 expectedSrOut) = _calculateJrToSrSwap(swapAmount, 10_000);
        uint256 minSrOut = expectedSrOut * 2;

        vm.startPrank(user1);
        IERC20(market.jrToken()).approve(address(router), swapAmount);
        vm.expectRevert();
        router.swapJuniorToSenior(address(market), swapAmount, uaToBorrow, minSrOut, block.timestamp + 1 minutes);
        vm.stopPrank();
    }

    function test_RevertWhen_SwapSeniorToJunior_InsufficientOutput() public {
        uint256 swapAmount = 1000e18;

        _adjustPoolPriceBySellingSr(600_000e18);

        (uint256 uaToBorrow, uint256 expectedJrOut) = _calculateFromSrInput(swapAmount, 10_000);
        uint256 minJrOut = expectedJrOut * 2;

        vm.startPrank(user3);
        IERC20(market.srToken()).approve(address(router), swapAmount);
        vm.expectRevert(IRouter.InsufficientOutput.selector);
        router.swapSeniorToJunior(address(market), swapAmount, uaToBorrow, minJrOut, block.timestamp + 1 minutes);
        vm.stopPrank();
    }
}
