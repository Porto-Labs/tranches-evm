// SPDX-License-Identifier: MIT
pragma solidity ^0.8.23;

import { Errors } from "../../errors/Errors.sol";

/**
 * @title PortoMath
 * @notice Minimal fixed-point math library for Porto Tranches
 * @dev All operations use 18 decimal precision (1e18)
 */
library PortoMath {
    uint256 internal constant ONE = 1e18; // 18 decimal places

    /**
     * @notice Multiply two 18 decimal numbers and divide by ONE (rounds down)
     * @dev Equivalent to (a * b) / 1e18
     * @param a First number (18 decimal precision)
     * @param b Second number (18 decimal precision)
     * @return result The result (18 decimal precision, rounded down)
     */
    function mulDown(uint256 a, uint256 b) internal pure returns (uint256) {
        return (a * b) / ONE;
    }

    /**
     * @notice Divide an 18 decimal number by another (rounds down)
     * @dev Equivalent to (a * 1e18) / b
     * @param a Numerator (18 decimal precision)
     * @param b Denominator (18 decimal precision)
     * @return result The result (18 decimal precision, rounded down)
     */
    function divDown(uint256 a, uint256 b) internal pure returns (uint256) {
        if (b == 0) revert Errors.DivisionByZero();
        return (a * ONE) / b;
    }

    /**
     * @notice Multiply two 18 decimal numbers, round UP
     * @dev Equivalent to ceil((a * b) / 1e18)
     * @param a First number (18 decimal precision)
     * @param b Second number (18 decimal precision)
     * @return result The result (18 decimal precision, rounded up)
     */
    function mulUp(uint256 a, uint256 b) internal pure returns (uint256) {
        uint256 product = a * b;
        if (product == 0) return 0;
        return ((product - 1) / ONE) + 1;
    }

    /**
     * @notice Divide 18 decimal numbers, round UP
     * @dev Equivalent to ceil((a * 1e18) / b)
     * @param a Numerator (18 decimal precision)
     * @param b Denominator (18 decimal precision)
     * @return result The result (18 decimal precision, rounded up)
     */
    function divUp(uint256 a, uint256 b) internal pure returns (uint256) {
        if (b == 0) revert Errors.DivisionByZero();
        if (a == 0) return 0;
        return ((a * ONE) - 1) / b + 1;
    }

    /**
     * @notice Returns the minimum of two numbers
     * @param a First number
     * @param b Second number
     * @return result The minimum value
     */
    function min(uint256 a, uint256 b) internal pure returns (uint256) {
        return a < b ? a : b;
    }
}
