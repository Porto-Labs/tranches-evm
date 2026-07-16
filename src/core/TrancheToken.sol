// SPDX-License-Identifier: MIT
pragma solidity ^0.8.23;

import { ERC20 } from "@openzeppelin/contracts/token/ERC20/ERC20.sol";

/**
 * @title TrancheToken
 * @notice ERC20 token representing either senior (srSY) or junior (jrSY) tranche
 * @dev Only the market contract can mint and burn tokens
 */
contract TrancheToken is ERC20 {
    /// @notice Thrown when non-market address attempts to mint or burn
    error OnlyMarket();

    /// @notice Thrown when a zero address is provided where not allowed
    error ZeroAddress();

    /// @notice The TrancheMarket contract that owns this token
    address public immutable market;

    /// @notice Token decimals (should match UA decimals)
    uint8 private immutable _decimals;

    /**
     * @notice Restricts function access to the market contract only
     */
    modifier onlyMarket() {
        if (msg.sender != market) revert OnlyMarket();
        _;
    }

    /**
     * @notice Creates a new tranche token
     * @param _name Token name (e.g., "Porto Senior Tranche UA")
     * @param _symbol Token symbol (e.g., "Porto Senior UA")
     * @param _market Address of the TrancheMarket contract
     * @param decimals_ Token decimals
     */
    constructor(string memory _name, string memory _symbol, address _market, uint8 decimals_) ERC20(_name, _symbol) {
        if (_market == address(0)) revert ZeroAddress();
        market = _market;
        _decimals = decimals_;
    }

    /**
     * @notice Returns the number of decimals
     */
    function decimals() public view override returns (uint8) {
        return _decimals;
    }

    /**
     * @notice Mints new tokens (callable only by market)
     * @param to Address to receive the minted tokens
     * @param amount Amount of tokens to mint
     */
    function mint(address to, uint256 amount) external onlyMarket {
        _mint(to, amount);
    }

    /**
     * @notice Burns tokens (callable only by market)
     * @param from Address to burn tokens from
     * @param amount Amount of tokens to burn
     */
    function burn(address from, uint256 amount) external onlyMarket {
        _burn(from, amount);
    }
}
