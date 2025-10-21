// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Script, stdJson} from "forge-std/Script.sol";

/**
 * @title ConfigHelper
 * @dev Configuration management utility for cross-chain deployments
 * @notice Provides tools for:
 * - Managing deployment addresses
 * - Loading chain configurations
 * - Handling pool rate limiting settings
 * @notice Uses Forge's scripting and JSON utilities for file operations
 */
contract ConfigHelper is Script {
    using stdJson for string;

    /**
     * @dev Error thrown when names and deployments arrays length mismatch
     * @notice Prevents inconsistent deployment records
     */
    error DevOps__NameAndDeploymentsLengthNotMatch();

    /**
     * @dev Error thrown when requested deployment not found
     * @param name Contract name that wasn't deployed
     * @notice Used when querying non-existent deployments
     */
    error DevOps__NotDeployed(string name);

    /**
     * @dev Chain network configuration structure
     * @param mainChainId Primary chain identifier
     * @param supportedChains Array of supported chain IDs
     */
    struct ChainConfig {
        uint256 mainChainId;
        uint256[] supportedChains;
    }

    /**
     * @dev Cross-chain pool configuration structure
     * @param allowed Whether the chain connection is enabled
     * @param inboundRateLimiterConfig Rate limits for incoming transfers
     * @param outboundRateLimiterConfig Rate limits for outgoing transfers
     * @param remoteChainSelector Destination chain selector
     * @param remotePoolAddress Pool address on destination chain
     * @param remoteTokenAddress Token address on destination chain
     */
    struct PoolConfig {
        bool allowed;
        RateLimiterConfig inboundRateLimiterConfig;
        RateLimiterConfig outboundRateLimiterConfig;
        uint64 remoteChainSelector;
        address remotePoolAddress;
        address remoteTokenAddress;
    }

    /**
     * @dev Rate limiter configuration parameters
     * @param capacity Maximum token capacity
     * @param isEnabled Whether rate limiting is active
     * @param rate Tokens allowed per time unit
     */
    struct RateLimiterConfig {
        uint128 capacity;
        bool isEnabled;
        uint128 rate;
    }

    /// @dev Path to deployment records file
    string private constant LATEST_DEPLOYMENT_FILE_PATH = "script/config/LatestDeployment.json";
    /// @dev Path to chain configuration file
    string private constant CHAIN_CONFIG_FILE_PATH = "script/config/ChainConfig.json";
    /// @dev Path to pool configuration file
    string private constant POOL_CONFIG_FILE_PATH = "script/config/PoolConfig.json";

    /**
     * @dev Gets latest deployment address for current chain
     * @param name Contract name to lookup
     * @return address Deployment address
     * @notice Reverts with DevOps__NotDeployed if not found
     */
    function getLatestDeployment(string memory name) public view returns (address) {
        return getLatestDeployment(name, block.chainid);
    }

    /**
     * @dev Gets latest deployment address for specific chain
     * @param name Contract name to lookup
     * @param chainId Chain ID to query
     * @return address Deployment address
     * @notice Reverts with DevOps__NotDeployed if not found
     */
    function getLatestDeployment(string memory name, uint256 chainId) public view returns (address) {
        string memory json = vm.readFile(LATEST_DEPLOYMENT_FILE_PATH);
        string memory key = string.concat(".", name, vm.toString(chainId));
        if (!json.keyExists(key)) {
            revert DevOps__NotDeployed(name);
        }
        return vm.parseJsonAddress(json, key);
    }

    /**
     * @dev Saves new deployment records
     * @param names Array of contract names
     * @param deployments Array of deployment addresses
     * @notice Updates LatestDeployment.json file
     * @notice Reverts with DevOps__NameAndDeploymentsLengthNotMatch on array mismatch
     */
    function saveDeployment(string[] memory names, address[] memory deployments) external {
        if (names.length != deployments.length) {
            revert DevOps__NameAndDeploymentsLengthNotMatch();
        }
        string memory chainId = vm.toString(block.chainid);
        string memory developments = string.concat("developments");
        string memory development = string.concat("development", chainId);
        string memory developmentJson;
        string memory developmentsJson;
        for (uint256 i = 0; i < names.length; i++) {
            developmentJson = development.serialize(names[i], deployments[i]);
        }
        developmentsJson = developments.serialize(chainId, developmentJson);
        developmentsJson.write(LATEST_DEPLOYMENT_FILE_PATH);
    }

    /**
     * @dev Loads chain network configuration
     * @return chainConfig ChainConfig structure
     */
    function getChainConfig() external view returns (ChainConfig memory chainConfig) {
        string memory configJson = vm.readFile(CHAIN_CONFIG_FILE_PATH);
        bytes memory configBytes = vm.parseJson(configJson);
        return abi.decode(configBytes, (ChainConfig));
    }

    /**
     * @dev Loads pool configurations for current chain
     * @return poolConfigs Array of PoolConfig structures
     */
    function getPoolConfig() external view returns (PoolConfig[] memory poolConfigs) {
        string memory poolConfigJson = vm.readFile(POOL_CONFIG_FILE_PATH);
        string memory key = string.concat(".", vm.toString(block.chainid));
        bytes memory poolConfigArrBytes = poolConfigJson.parseRaw(key);
        return abi.decode(poolConfigArrBytes, (PoolConfig[]));
    }
}