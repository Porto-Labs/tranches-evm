// SPDX-License-Identifier: MIT
pragma solidity ^0.8.23;

/**
 * @title PortoTranches
 * @notice Placeholder contract for initial setup verification
 * @dev This will be replaced with actual tranche implementation
 */
contract PortoTranches {
    string public constant VERSION = "0.1.0";

    event Initialized(address indexed initializer);

    constructor() {
        emit Initialized(msg.sender);
    }

    function getVersion() external pure returns (string memory) {
        return VERSION;
    }
}
