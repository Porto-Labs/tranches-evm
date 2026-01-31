// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import { BaseForkTest } from "./BaseForkTest.sol";
import { TrancheToken } from "src/core/TrancheToken.sol";
import { IERC20 } from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import { IUniswapV3Pool } from "@uniswap/v3-core/contracts/interfaces/IUniswapV3Pool.sol";
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
        _addLiquidity();
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
        assertEq(address(router.uniswapPool()), uniswapPool);
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
}
