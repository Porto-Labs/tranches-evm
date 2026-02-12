// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import { Test } from "forge-std/Test.sol";
import { TrancheToken } from "src/core/TrancheToken.sol";

contract TrancheTokenTest is Test {
    TrancheToken public token;

    address public market;
    address public user;

    function setUp() public {
        market = makeAddr("market");
        user = makeAddr("user");

        token = new TrancheToken("Porto srUA", "srUA", market, 18);
    }

    function test_Constructor_SetImmutables() public view {
        assertEq(token.name(), "Porto srUA");
        assertEq(token.symbol(), "srUA");
        assertEq(token.market(), market);
        assertEq(token.decimals(), 18);
    }

    function test_Constructor_CustomDecimals() public {
        TrancheToken token6 = new TrancheToken("Porto srUSDC", "srUSDC", market, 6);
        assertEq(token6.decimals(), 6);

        TrancheToken token8 = new TrancheToken("Porto srWBTC", "srWBTC", market, 8);
        assertEq(token8.decimals(), 8);
    }

    function test_RevertWhen_Constructor_ZeroAddress() public {
        vm.expectRevert(TrancheToken.ZeroAddress.selector);
        new TrancheToken("Porto srUA", "srUA", address(0), 18);
    }

    function test_Mint_ByMarket() public {
        vm.prank(market);
        token.mint(user, 100e18);

        assertEq(token.balanceOf(user), 100e18);
        assertEq(token.totalSupply(), 100e18);
    }

    function test_Burn_ByMarket() public {
        vm.prank(market);
        token.mint(user, 100e18);

        vm.prank(market);
        token.burn(user, 40e18);

        assertEq(token.balanceOf(user), 60e18);
        assertEq(token.totalSupply(), 60e18);
    }

    function test_RevertWhen_Mint_NotMarket() public {
        vm.prank(user);
        vm.expectRevert(TrancheToken.OnlyMarket.selector);
        token.mint(user, 100e18);
    }

    function test_RevertWhen_Burn_NotMarket() public {
        vm.prank(market);
        token.mint(user, 100e18);

        vm.prank(user);
        vm.expectRevert(TrancheToken.OnlyMarket.selector);
        token.burn(user, 50e18);
    }
}
