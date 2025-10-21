// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

interface IUpkeepIntegration {

    /**
     * @dev Returns the Chainlink Upkeep ID for this SF Engine contract
     * @return uint256 The unique identifier of the registered upkeep
     */
    function getUpkeepId() external view returns (uint256);

    /**
     * @dev Gets the current gas limit for upkeep executions
     * @return uint32 The current gas limit setting (in wei)
     * @notice This value determines maximum gas consumption per upkeep run
     */
    function getUpkeepGasLimit() external view returns (uint32);

    /**
     * @dev Returns the initial amount of LINK tokens required for Initial upkeep funding
     * @return uint256 The amount of LINK tokens
     */
    function getUpkeepInitialLinkAmount() external view returns (uint256);
}