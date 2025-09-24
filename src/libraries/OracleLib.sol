// SPDX-License-Identifier: MIT
pragma solidity ^0.8.30;

import {AggregatorV3Interface} from "@chainlink/contracts/src/v0.8/interfaces/AggregatorV3Interface.sol";

library OracleLib {

    uint256 private constant TIME_OUT = 3 hours;
    uint256 private constant PRECISION = 18;
    uint256 private constant PRECISION_FACTOR = 1e18;

    error OracleLib__StalePrice();

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

    function getPrice(AggregatorV3Interface aggregator) internal view returns (uint256) {
        (, int256 answer, , , ) = getStaleCheckedLatestRoundData(aggregator);   
        return uint256(answer) * 10 ** (PRECISION - aggregator.decimals());
    }

    function getTokenValue(
        AggregatorV3Interface aggregator, 
        uint256 tokenAmount
    ) internal view returns (uint256) {
        return tokenAmount * getPrice(aggregator) / PRECISION_FACTOR;
    }

    function getTokensForValue(
        AggregatorV3Interface aggregator, 
        uint256 value
    ) internal view returns (uint256) {
        return value * PRECISION_FACTOR / getPrice(aggregator);
    }
}