// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import { Test } from "forge-std/Test.sol";
import { Router } from "src/core/Router.sol";
import { IRouter } from "src/interfaces/IRouter.sol";

contract RouterTest is Test {
    Router public router;

    address public admin;
    address public user;
    address public marketAddress;

    function setUp() public {
        admin = makeAddr("admin");
        user = makeAddr("user");
        marketAddress = makeAddr("market");

        address swapRouter = makeAddr("swapRouter");
        address morpho = makeAddr("morpho");

        router = new Router(swapRouter, morpho, admin);
    }

    // ============ Whitelist Tests ============

    function test_SetMarketWhitelisted_ToTrue() public {
        vm.prank(admin);
        vm.expectEmit(true, false, false, true);
        emit IRouter.MarketWhitelistChanged(marketAddress, true);
        router.setMarketWhitelisted(marketAddress, true);

        assertTrue(router.whitelistedMarkets(marketAddress));
    }

    function test_SetMarketWhitelisted_ToFalse() public {
        vm.startPrank(admin);
        router.setMarketWhitelisted(marketAddress, true);
        assertTrue(router.whitelistedMarkets(marketAddress));

        vm.expectEmit(true, false, false, true);
        emit IRouter.MarketWhitelistChanged(marketAddress, false);
        router.setMarketWhitelisted(marketAddress, false);
        vm.stopPrank();

        assertFalse(router.whitelistedMarkets(marketAddress));
    }

    function test_RevertWhen_SetMarketWhitelisted_NotAdmin() public {
        vm.prank(user);
        vm.expectRevert(IRouter.OnlyAdmin.selector);
        router.setMarketWhitelisted(marketAddress, true);
    }

    function test_RevertWhen_SetMarketWhitelisted_ZeroAddress() public {
        vm.prank(admin);
        vm.expectRevert(IRouter.ZeroAddress.selector);
        router.setMarketWhitelisted(address(0), true);
    }

    // ============ Deadline Tests ============

    function test_RevertWhen_DeadlineExpired_AllFunctions() public {
        vm.prank(admin);
        router.setMarketWhitelisted(marketAddress, true);

        uint256 expiredDeadline = block.timestamp - 1;

        vm.expectRevert(IRouter.RouterDeadlineExpired.selector);
        router.buySenior(marketAddress, 1e18, 0, expiredDeadline);

        vm.expectRevert(IRouter.RouterDeadlineExpired.selector);
        router.sellSenior(marketAddress, 1e18, 0, expiredDeadline);

        vm.expectRevert(IRouter.RouterDeadlineExpired.selector);
        router.buyJunior(marketAddress, 1e18, 1e18, 0, expiredDeadline);

        vm.expectRevert(IRouter.RouterDeadlineExpired.selector);
        router.sellJunior(marketAddress, 1e18, 1e18, 0, expiredDeadline);

        vm.expectRevert(IRouter.RouterDeadlineExpired.selector);
        router.swapJuniorToSenior(marketAddress, 1e18, 1e18, 0, expiredDeadline);

        vm.expectRevert(IRouter.RouterDeadlineExpired.selector);
        router.swapSeniorToJunior(marketAddress, 1e18, 1e18, 0, expiredDeadline);
    }

    // ============ Market Not Whitelisted Tests ============

    function test_RevertWhen_MarketNotWhitelisted_AllFunctions() public {
        uint256 deadline = block.timestamp + 1 hours;

        vm.expectRevert(IRouter.MarketNotWhitelisted.selector);
        router.buySenior(marketAddress, 1e18, 0, deadline);

        vm.expectRevert(IRouter.MarketNotWhitelisted.selector);
        router.sellSenior(marketAddress, 1e18, 0, deadline);

        vm.expectRevert(IRouter.MarketNotWhitelisted.selector);
        router.buyJunior(marketAddress, 1e18, 1e18, 0, deadline);

        vm.expectRevert(IRouter.MarketNotWhitelisted.selector);
        router.sellJunior(marketAddress, 1e18, 1e18, 0, deadline);

        vm.expectRevert(IRouter.MarketNotWhitelisted.selector);
        router.swapJuniorToSenior(marketAddress, 1e18, 1e18, 0, deadline);

        vm.expectRevert(IRouter.MarketNotWhitelisted.selector);
        router.swapSeniorToJunior(marketAddress, 1e18, 1e18, 0, deadline);
    }

    // ============ Callback Authorization Test ============

    function test_RevertWhen_FlashLoanCallbackFromExternal() public {
        vm.prank(user);
        vm.expectRevert(IRouter.RouterUnauthorizedCallback.selector);
        router.onMorphoFlashLoan(1e18, abi.encode(marketAddress, user, 1e18, 0, uint8(0)));
    }

    function test_RevertWhen_MorphoCallsWithoutFlashLoanInitiated() public {
        vm.prank(makeAddr("morpho"));
        vm.expectRevert(IRouter.FlashLoanNotInitiated.selector);
        router.onMorphoFlashLoan(1e18, abi.encode(marketAddress, user, 1e18, 0, uint8(0)));
    }
}
