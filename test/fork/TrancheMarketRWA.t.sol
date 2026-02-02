// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import { BaseForkTest } from "./BaseForkTest.sol";
import { TrancheToken } from "src/core/TrancheToken.sol";
import { IERC20 } from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import { IUniswapV3Pool } from "@uniswap/v3-core/contracts/interfaces/IUniswapV3Pool.sol";
import { IRouter } from "src/interfaces/IRouter.sol";
import { Errors } from "src/errors/Errors.sol";
import { console } from "forge-std/Test.sol";

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

        // 3,625,000 srPRIME : 3,625,000 PRIME
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

        IUniswapV3Pool pool = IUniswapV3Pool(uniswapPool);

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

    // User deposits 10,000 PRIME and receives ~5,500 jrPRIME via Morpho flash loan.
    // The leverage math:
    // 1. User provides uaIn = 10,000 PRIME
    // 2. expectedSrOut = uaIn × seniorRatio = 10,000 × 0.725 = 7,250 srPRIME
    // 3. uaToBorrow = expectedSrOut / seniorRatio = 7,250 / 0.725 = 10,000 PRIME (equals uaIn)
    // 4. Total tranched = uaIn + uaToBorrow = 20,000 PRIME
    // 5. Junior received = totalTranched × juniorRatio = 20,000 × 0.275 = 5,500 jrPRIME
    // 6. Senior minted (14,500 srPRIME) is sold on Uniswap to repay the flash loan
    function test_BuyJunior_Success() public {
        address buyUser = makeAddr("buyJuniorUser");
        address jrToken = market.jrToken();
        address srToken = market.srToken();
        uint256 buyAmount = 10_000e18;
        prime.mint(buyUser, buyAmount);

        uint256 userJrBefore = IERC20(jrToken).balanceOf(buyUser);
        uint256 userPrimeBefore = prime.balanceOf(buyUser);
        uint256 poolPrimeBefore = prime.balanceOf(uniswapPool);
        uint256 poolSrBefore = IERC20(srToken).balanceOf(uniswapPool);

        console.log("=== BEFORE BUY JUNIOR ===");
        console.log("User PRIME balance:", userPrimeBefore / 1e18);
        console.log("User jrPRIME balance:", userJrBefore / 1e18);
        console.log("Pool PRIME balance:", poolPrimeBefore / 1e18);
        console.log("Pool srPRIME balance:", poolSrBefore / 1e18);

        vm.startPrank(buyUser);
        uint256 gasBefore = gasleft();

        prime.approve(address(router), buyAmount);
        router.buyJunior(buyAmount, 0, block.timestamp + 1 hours);

        uint256 gasUsed = gasBefore - gasleft();
        console.log("Gas used for buyJunior:", gasUsed);

        vm.stopPrank();

        uint256 userJrAfter = IERC20(jrToken).balanceOf(buyUser);
        uint256 userPrimeAfter = prime.balanceOf(buyUser);
        uint256 poolPrimeAfter = prime.balanceOf(uniswapPool);
        uint256 poolSrAfter = IERC20(srToken).balanceOf(uniswapPool);

        console.log("");
        console.log("=== AFTER BUY JUNIOR ===");
        console.log("User PRIME balance:", userPrimeAfter / 1e18);
        console.log("User jrPRIME balance:", userJrAfter / 1e18);
        console.log("Pool PRIME balance:", poolPrimeAfter / 1e18);
        console.log("Pool srPRIME balance:", poolSrAfter / 1e18);

        console.log("");
        console.log("=== CHANGES ===");
        console.log("PRIME spent:", (userPrimeBefore - userPrimeAfter) / 1e18);
        console.log("jrPRIME received:", (userJrAfter - userJrBefore) / 1e18);

        assertGt(userJrAfter - userJrBefore, 0);
    }

    // ============ SellJunior Tests ============

    // User sells 5,500 jrPRIME and receives ~5,500 PRIME via Morpho flash loan.
    // The sellJunior math:
    // 1. User provides jrIn = 5,500 jrPRIME
    // 2. srNeeded = jrIn × seniorRatio / juniorRatio = 5,500 × 0.725 / 0.275 = 14,500 srPRIME
    // 3. uaToBorrow = srNeeded / seniorRatio = 14,500 / 0.725 = 20,000 PRIME
    // 4. Swap ~14,500 PRIME for 14,500 srPRIME on Uniswap (exactOutput)
    // 5. Recombine 14,500 srPRIME + 5,500 jrPRIME = 20,000 PRIME
    // 6. Repay 20,000 PRIME flash loan, user receives remaining ~5,500 PRIME
    function test_SellJunior_Success() public {
        // TODO: change the ratio PRIME/srPRIME
        address jrToken = market.jrToken();
        address srToken = market.srToken();
        uint256 sellAmount = 5_500e18;

        uint256 userJrBefore = IERC20(jrToken).balanceOf(user1);
        uint256 userPrimeBefore = prime.balanceOf(user1);
        uint256 poolPrimeBefore = prime.balanceOf(uniswapPool);
        uint256 poolSrBefore = IERC20(srToken).balanceOf(uniswapPool);

        console.log("=== BEFORE SELL JUNIOR ===");
        console.log("User jrPRIME balance:", userJrBefore / 1e18);
        console.log("User PRIME balance:", userPrimeBefore / 1e18);
        console.log("Pool PRIME balance:", poolPrimeBefore / 1e18);
        console.log("Pool srPRIME balance:", poolSrBefore / 1e18);

        vm.startPrank(user1);
        uint256 gasBefore = gasleft();

        IERC20(jrToken).approve(address(router), sellAmount);
        router.sellJunior(sellAmount, 0, block.timestamp + 1 hours);

        uint256 gasUsed = gasBefore - gasleft();
        console.log("Gas used for sellJunior:", gasUsed);

        vm.stopPrank();

        uint256 userJrAfter = IERC20(jrToken).balanceOf(user1);
        uint256 userPrimeAfter = prime.balanceOf(user1);
        uint256 poolPrimeAfter = prime.balanceOf(uniswapPool);
        uint256 poolSrAfter = IERC20(srToken).balanceOf(uniswapPool);

        console.log("");
        console.log("=== AFTER SELL JUNIOR ===");
        console.log("User jrPRIME balance:", userJrAfter / 1e18);
        console.log("User PRIME balance:", userPrimeAfter / 1e18);
        console.log("Pool PRIME balance:", poolPrimeAfter / 1e18);
        console.log("Pool srPRIME balance:", poolSrAfter / 1e18);

        console.log("");
        console.log("=== CHANGES ===");
        console.log("jrPRIME sold:", (userJrBefore - userJrAfter) / 1e18);
        console.log("PRIME received:", (userPrimeAfter - userPrimeBefore) / 1e18);

        assertEq(userJrBefore - userJrAfter, sellAmount);
        assertGt(userPrimeAfter - userPrimeBefore, 0);
    }
}
