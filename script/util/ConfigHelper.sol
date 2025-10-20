// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Script, stdJson} from "forge-std/Script.sol";

contract ConfigHelper is Script {

    using stdJson for string;

    error DevOps__NameAndDeploymentsLengthNotMatch();
    error DevOps__NotDeployed(string name);

    struct ChainConfig {
        uint256 mainChainId;
        uint256[] supportedChains;
    }

    struct PoolConfig {
        bool allowed; // Whether the chain should be enabled
        RateLimiterConfig inboundRateLimiterConfig; // Inbound rate limited config, meaning the rate limits for all of the offRamps for the given chain
        RateLimiterConfig outboundRateLimiterConfig; // Outbound rate limited config, meaning the rate limits for all of the onRamps for the given chain
        uint64 remoteChainSelector; // Remote chain selector
        address remotePoolAddress; // Address of the remote pool
        address remoteTokenAddress; // Address of the remote token
    }

    struct RateLimiterConfig {
        uint128 capacity; // Specifies the capacity of the rate limiter
        bool isEnabled; // Indication whether the rate limiting should be enabled
        uint128 rate; // Specifies the rate of the rate limiter
    }

    string private constant LATEST_DEPLOYMENT_FILE_PATH = "script/config/LatestDeployment.json";
    string private constant CHAIN_CONFIG_FILE_PATH = "script/config/ChainConfig.json";
    string private constant POOL_CONFIG_FILE_PATH = "script/config/PoolConfig.json";

    function getLatestDeployment(string memory name) public view returns (address) {
        return getLatestDeployment(name, block.chainid);
    }

    function getLatestDeployment(string memory name, uint256 chainId) public view returns (address) {
        string memory json = vm.readFile(LATEST_DEPLOYMENT_FILE_PATH);
        string memory key = string.concat(".", name, vm.toString(chainId));
        if (!json.keyExists(key)) {
            revert DevOps__NotDeployed(name);
        }
        return vm.parseJsonAddress(json, key);
    }

    function saveDeployment(string[] memory names, address[] memory deployments) external {
        if (names.length != deployments.length) {
            revert DevOps__NameAndDeploymentsLengthNotMatch();
        }
        string memory developments = "developments";
        string memory development = "development";
        string memory developmentJson;
        string memory developmentsJson;
        for (uint256 i = 0; i < names.length; i++) {
            developmentJson = development.serialize(names[i], deployments[i]);
        }
        developmentsJson = developments.serialize(vm.toString(block.chainid), developmentJson);
        developmentsJson.write(LATEST_DEPLOYMENT_FILE_PATH);
    }

    function getChainConfig() external view returns (ChainConfig memory chainConfig) {
        string memory configJson = vm.readFile(CHAIN_CONFIG_FILE_PATH);
        bytes memory configBytes = vm.parseJson(configJson);
        return abi.decode(configBytes, (ChainConfig));
    }

    function getPoolConfig() external view returns (PoolConfig[] memory poolConfigs) {
        string memory poolConfigJson = vm.readFile(POOL_CONFIG_FILE_PATH);
        string memory key = string.concat(".", vm.toString(block.chainid));
        bytes memory poolConfigArrBytes = poolConfigJson.parseRaw(key);
        return abi.decode(poolConfigArrBytes, (PoolConfig[]));
    }
}