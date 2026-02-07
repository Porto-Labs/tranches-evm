// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import { Test } from "forge-std/Test.sol";
import { PortoMathMock } from "./mocks/PortoMathMock.sol";
import { PortoMath } from "src/libraries/math/PortoMath.sol";

contract PortoMathTest is Test {
    PortoMathMock public portoMath;

    function setUp() public {
        portoMath = new PortoMathMock();
    }

    function test_MulDown_MultiplyAndRoundDown() public view {
        uint256 a = 2e18;
        uint256 b = 3e18;
        assertEq(portoMath.mulDown(a, b), 6e18);
    }

    function test_MulDown_HandleRoundingDown() public view {
        uint256 a = 1;
        uint256 b = 0.5e18;
        assertEq(portoMath.mulDown(a, b), 0);
    }

    function test_MulDown_ReturnZeroWhenNumeratorIsZero() public view {
        assertEq(portoMath.mulDown(0, 1e18), 0);
    }

    function test_MulUp_MultiplyAndRoundUp() public view {
        uint256 a = 2e18;
        uint256 b = 3e18;
        assertEq(portoMath.mulUp(a, b), 6e18);
    }

    function test_MulUp_RoundUpOnFractionalResult() public view {
        uint256 a = 1e18;
        uint256 b = 1;
        assertEq(portoMath.mulUp(a, b), 1);
    }

    function test_MulUp_ReturnZeroWhenProductIsZero() public view {
        assertEq(portoMath.mulUp(0, 1e18), 0);
    }

    function test_DivDown_DivideAndRoundDown() public view {
        uint256 a = 6e18;
        uint256 b = 2e18;
        assertEq(portoMath.divDown(a, b), 3e18);
    }

    function test_DivDown_HandleRoundingDown() public view {
        uint256 a = 1e18;
        uint256 b = 3e18;
        uint256 result = portoMath.divDown(a, b);
        assertLt(result, 0.333333333333333334e18);
    }

    function test_DivDown_ReturnZeroWhenNumeratorIsZero() public view {
        assertEq(portoMath.divDown(0, 1e18), 0);
    }

    function test_RevertWhen_DivDownByZero() public {
        vm.expectRevert(PortoMath.DivisionByZero.selector);
        portoMath.divDown(1e18, 0);
    }

    function test_DivUp_DivideAndRoundUp() public view {
        uint256 a = 6e18;
        uint256 b = 2e18;
        assertEq(portoMath.divUp(a, b), 3e18);
    }

    function test_DivUp_RoundUpOnFractionalResult() public view {
        uint256 a = 1e18;
        uint256 b = 3e18;
        uint256 result = portoMath.divUp(a, b);
        assertGt(result, 0.333333333333333333e18);
    }

    function test_DivUp_ReturnZeroWhenNumeratorIsZero() public view {
        assertEq(portoMath.divUp(0, 1e18), 0);
    }

    function test_RevertWhen_DivUpByZero() public {
        vm.expectRevert(PortoMath.DivisionByZero.selector);
        portoMath.divUp(1e18, 0);
    }

    function test_RevertWhen_DivUpZeroByZero() public {
        vm.expectRevert(PortoMath.DivisionByZero.selector);
        portoMath.divUp(0, 0);
    }

    function test_Min_ReturnSmallerValue() public view {
        assertEq(portoMath.min(5e18, 10e18), 5e18);
        assertEq(portoMath.min(10e18, 5e18), 5e18);
    }
}
