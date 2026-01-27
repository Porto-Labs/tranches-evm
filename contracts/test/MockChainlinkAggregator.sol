// SPDX-License-Identifier: MIT
pragma solidity ^0.8.23;

import { AggregatorV3Interface } from "@chainlink/contracts/src/v0.8/shared/interfaces/AggregatorV3Interface.sol";

/**
 * @title MockChainlinkAggregator
 * @notice Mock implementation of Chainlink AggregatorV3Interface for testing
 * @dev Provides test helpers to simulate various oracle states (normal, stale, invalid)
 */
contract MockChainlinkAggregator is AggregatorV3Interface {
    uint8 private _decimals;
    int256 private _price;
    uint256 private _updatedAt;
    uint80 private _roundId;
    string private _description;

    constructor(uint8 decimals_, string memory description_) {
        _decimals = decimals_;
        _description = description_;
        _roundId = 1;
        _updatedAt = block.timestamp;
    }

    // ============ AggregatorV3Interface Implementation ============

    function decimals() external view override returns (uint8) {
        return _decimals;
    }

    function description() external view override returns (string memory) {
        return _description;
    }

    function version() external pure override returns (uint256) {
        return 1;
    }

    function getRoundData(
        uint80 roundId_
    )
        external
        view
        override
        returns (uint80 roundId, int256 answer, uint256 startedAt, uint256 updatedAt, uint80 answeredInRound)
    {
        // For simplicity, return current data for any round
        return (roundId_, _price, _updatedAt, _updatedAt, roundId_);
    }

    function latestRoundData()
        external
        view
        override
        returns (uint80 roundId, int256 answer, uint256 startedAt, uint256 updatedAt, uint80 answeredInRound)
    {
        return (_roundId, _price, _updatedAt, _updatedAt, _roundId);
    }

    // ============ Test Helper ============

    /**
     * @notice Set price and updatedAt timestamp
     * @param price_ New price (with configured decimals)
     * @param updatedAt_ Timestamp for when the price was updated
     */
    function setRoundData(int256 price_, uint256 updatedAt_) external {
        _price = price_;
        _updatedAt = updatedAt_;
        _roundId++;
    }
}
