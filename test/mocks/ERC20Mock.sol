// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import { ERC20 } from "@openzeppelin/contracts/token/ERC20/ERC20.sol";

/**
 * @title ERC20Mock
 * @notice Simple ERC20 mock for testing - allows anyone to mint
 */
contract ERC20Mock is ERC20 {
    constructor(string memory name, string memory symbol) ERC20(name, symbol) { }

    /**
     * @notice Mint tokens to any address (for testing only)
     * @param to Address to mint to
     * @param amount Amount to mint
     */
    function mint(address to, uint256 amount) external {
        _mint(to, amount);
    }
}

/**
 * @title ERC20Mock6Decimals
 * @notice ERC20 mock with 6 decimals for USDC-like tokens
 */
contract ERC20Mock6Decimals is ERC20 {
    constructor(string memory name, string memory symbol) ERC20(name, symbol) { }

    function decimals() public pure override returns (uint8) {
        return 6;
    }

    function mint(address to, uint256 amount) external {
        _mint(to, amount);
    }
}

/**
 * @title ERC20Mock8Decimals
 * @notice ERC20 mock with 8 decimals for WBTC-like tokens
 */
contract ERC20Mock8Decimals is ERC20 {
    constructor(string memory name, string memory symbol) ERC20(name, symbol) { }

    function decimals() public pure override returns (uint8) {
        return 8;
    }

    function mint(address to, uint256 amount) external {
        _mint(to, amount);
    }
}
