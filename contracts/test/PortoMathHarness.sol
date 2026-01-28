// SPDX-License-Identifier: MIT
pragma solidity ^0.8.23;

import { PortoMath } from "../libraries/math/PortoMath.sol";

contract PortoMathHarness {
    using PortoMath for uint256;

    function mulDown(uint256 a, uint256 b) external pure returns (uint256) {
        return a.mulDown(b);
    }

    function mulUp(uint256 a, uint256 b) external pure returns (uint256) {
        return a.mulUp(b);
    }

    function divDown(uint256 a, uint256 b) external pure returns (uint256) {
        return a.divDown(b);
    }

    function divUp(uint256 a, uint256 b) external pure returns (uint256) {
        return a.divUp(b);
    }

    function min(uint256 a, uint256 b) external pure returns (uint256) {
        return PortoMath.min(a, b);
    }
}
