// SPDX-License-Identifier: MIT
pragma solidity ^0.8.30;

import {AggregatorV3Interface} from "@chainlink/contracts/src/v0.8/shared/interfaces/AggregatorV3Interface.sol";

/**
 * @title OracleLib
 * @dev Library for secure Chainlink price oracle interactions
 * @notice Provides:
 * - Stale price detection with configurable timeout
 * - Precision-adjusted price conversions
 * - Token value calculations with safety checks
 * @notice Key features:
 * - Automatic stale price detection (3-hour timeout)
 * - Precision normalization (18 decimals standard)
 * - Safe type conversions between int256/uint256
 * - Reverts on invalid oracle states
 * @notice Designed for:
 * - ERC20 token valuation
 * - Collateral ratio calculations
 * - Debt position monitoring
 */
library OracleLib {

    uint256 private constant TIME_OUT = 3 hours;
    uint256 private constant PRECISION = 18;
    uint256 private constant PRECISION_FACTOR = 1e18;

    error OracleLib__StalePrice();

    /**
     * @dev Fetches and validates the latest round data from Chainlink aggregator
     * @param aggregator Chainlink price aggregator contract interface
     * @return roundId The round identifier
     * @return answer Latest price value
     * @return startedAt Timestamp when round started
     * @return updatedAt Timestamp when price was last updated
     * @return answeredInRound The round ID of the round in which the answer was computed
     * @notice Performs three validation checks:
     * 1. updatedAt timestamp must not be zero
     * 2. answeredInRound must be >= current roundId
     * 3. Price must not be older than TIME_OUT (3 hours)
     * @notice Reverts with OracleLib__StalePrice if any check fails
     */
    function getStaleCheckedLatestRoundData(AggregatorV3Interface aggregator)
        internal 
        view
        returns (uint80 roundId, int256 answer, uint256 startedAt, uint256 updatedAt, uint80 answeredInRound) 
    {
        (roundId, answer, startedAt, updatedAt, answeredInRound) =  aggregator.latestRoundData();
        if (updatedAt == 0 || answeredInRound < roundId) {
            revert OracleLib__StalePrice();
        }
        uint256 timeElapsed = block.timestamp - updatedAt;
        if (timeElapsed > TIME_OUT) {
            revert OracleLib__StalePrice();
        }
        return (roundId, answer, startedAt, updatedAt, answeredInRound);
    }

    /**
     * @dev Gets the latest price normalized to 18 decimals
     * @param aggregator Chainlink price aggregator contract interface
     * @return Price normalized to 18 decimal places (uint256)
     * @notice Handles:
     * - Stale price checks via getStaleCheckedLatestRoundData
     * - Safe int256 to uint256 conversion
     * - Precision adjustment based on aggregator decimals
     */
    function getPrice(AggregatorV3Interface aggregator) internal view returns (uint256) {
        (, int256 answer, , , ) = getStaleCheckedLatestRoundData(aggregator);   
        return uint256(answer) * 10 ** (PRECISION - aggregator.decimals());
    }

    /**
     * @dev Calculates value (eg. USD value) of a token amount
     * @param aggregator Token's price aggregator contract
     * @param tokenAmount Amount of tokens in native precision
     * @return Value with 18 decimal precision
     * @notice Calculation formula:
     * (tokenAmount * price) / 1e18
     * @notice Automatically handles precision adjustments
     */
    function getTokenValue(
        AggregatorV3Interface aggregator, 
        uint256 tokenAmount
    ) internal view returns (uint256) {
        return tokenAmount * getPrice(aggregator) / PRECISION_FACTOR;
    }

    /**
     * @dev Calculates token amount for a given value (eg. USD value)
     * @param aggregator Token's price aggregator contract
     * @param value Value with 18 decimal precision
     * @return Token amount in native precision
     * @notice Calculation formula:
     * (value * 1e18) / price
     * @notice Automatically handles precision adjustments
     */
    function getTokensForValue(
        AggregatorV3Interface aggregator, 
        uint256 value
    ) internal view returns (uint256) {
        uint256 price = getPrice(aggregator);
        return (value * PRECISION_FACTOR + price - 1) / price;
    }
}