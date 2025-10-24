// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {SFTokenPool} from "../src/token/SFTokenPool.sol";
import {ConfigHelper} from "./util/ConfigHelper.sol";
import {RegistryModuleOwnerCustom} from "@chainlink/contracts/src/v0.8/ccip/tokenAdminRegistry/RegistryModuleOwnerCustom.sol";
import {TokenAdminRegistry} from "@chainlink/contracts/src/v0.8/ccip/tokenAdminRegistry/TokenAdminRegistry.sol";
import {TokenPool} from "@chainlink/contracts/src/v0.8/ccip/pools/TokenPool.sol";
import {RateLimiter} from "@chainlink/contracts/src/v0.8/ccip/libraries/RateLimiter.sol";
import {Script, console2} from "forge-std/Script.sol";
import {stdJson} from "forge-std/StdJson.sol";

/**
 * @title ConfigureTokenPool
 * @dev Script contract for configuring SFTokenPool instances
 * @notice Handles pool configuration including:
 * - Cross-chain connection settings
 * - Rate limiting parameters
 * - Remote chain configurations
 * @notice Supports both file-based and parameter-based configuration
 */
contract ConfigureTokenPool is Script {
    
    using stdJson for string;

    /// @dev Configuration helper instance
    ConfigHelper private configHelper;

    /**
     * @dev Constructor initializes configuration helper
     */
    constructor() {
        configHelper = new ConfigHelper();
    }

    /**
     * @dev Main script execution function
     * @notice Loads pool address from config and configures it
     */
    function run() external {
        address tokenPoolAddress = configHelper.getLatestDeployment("SFTokenPool");
        configure(tokenPoolAddress);
    }

    /**
     * @dev Configures token pool using JSON configuration
     * @param sfTokenPool Address of SFTokenPool to configure
     * @notice Uses poolConfig.json for settings
     * @notice Converts config to ChainUpdate format and applies
     */
    function configure(address sfTokenPool) public {
        console2.log("Configure token pool using poolConfig.json");
        ConfigHelper.PoolConfig[] memory poolConfigs = configHelper.getPoolConfig();
        TokenPool.ChainUpdate[] memory chainUpdates = _convertToChainUpdates(poolConfigs);
        _applyChainUpdates(sfTokenPool, chainUpdates);
    }

    /**
     * @dev Configures token pool with detailed parameters
     * @param localTokenPoolAddress Address of local token pool
     * @param remoteChainSelector Destination chain selector
     * @param remoteTokenAddress Token address on remote chain
     * @param allowed Whether connection is enabled
     * @param remotePoolAddress Pool address on remote chain
     * @param inboundRateLimiterIsEnabled Inbound rate limiting status
     * @param inboundRateLimiterCapacity Inbound capacity limit
     * @param inboundRateLimiterRate Inbound replenish rate
     * @param outboundRateLimiterIsEnabled Outbound rate limiting status
     * @param outboundRateLimiterCapacity Outbound capacity limit
     * @param outboundRateLimiterRate Outbound replenish rate
     * @notice Creates single PoolConfig and applies it
     */
    function configure(
        address localTokenPoolAddress,
        uint64 remoteChainSelector,
        address remoteTokenAddress,
        bool allowed,
        address remotePoolAddress,
        bool inboundRateLimiterIsEnabled,
        uint128 inboundRateLimiterCapacity,
        uint128 inboundRateLimiterRate,
        bool outboundRateLimiterIsEnabled,
        uint128 outboundRateLimiterCapacity,
        uint128 outboundRateLimiterRate
    ) public {
        console2.log("Start to configure token pool, chain id:", block.chainid);
        ConfigHelper.PoolConfig memory poolConfig = ConfigHelper.PoolConfig({
            remoteChainSelector: remoteChainSelector,
            allowed: allowed,
            remotePoolAddress: remotePoolAddress,
            remoteTokenAddress: remoteTokenAddress,
            outboundRateLimiterConfig: ConfigHelper.RateLimiterConfig({
                isEnabled: outboundRateLimiterIsEnabled,
                capacity: outboundRateLimiterCapacity,
                rate: outboundRateLimiterRate
            }),
            inboundRateLimiterConfig: ConfigHelper.RateLimiterConfig({
                isEnabled: inboundRateLimiterIsEnabled,
                capacity: inboundRateLimiterCapacity,
                rate: inboundRateLimiterRate
            })
        });
        ConfigHelper.PoolConfig[] memory poolConfigs = new ConfigHelper.PoolConfig[](1);
        poolConfigs[0] = poolConfig;
        TokenPool.ChainUpdate[] memory chainUpdates = _convertToChainUpdates(poolConfigs);
        _applyChainUpdates(localTokenPoolAddress, chainUpdates);
        console2.log("Token pool configured successfully");
    }

    /**
     * @dev Simplified configuration without rate limiting
     * @param localTokenPoolAddress Address of local token pool
     * @param remoteChainSelector Destination chain selector
     * @param remoteTokenAddress Token address on remote chain
     * @param allowed Whether connection is enabled
     * @param remotePoolAddress Pool address on remote chain
     * @notice Calls full configure with rate limiting disabled
     */
    function configure(
        address localTokenPoolAddress,
        uint64 remoteChainSelector,
        address remoteTokenAddress,
        bool allowed,
        address remotePoolAddress
    ) public {
        configure(
            localTokenPoolAddress,
            remoteChainSelector,
            remoteTokenAddress,
            allowed,
            remotePoolAddress,
            false,
            0,
            0,
            false,
            0,
            0
        );
    }

    /**
     * @dev Applies chain updates to token pool
     * @param localTokenPoolAddress Pool address to configure
     * @param chainUpdates Array of ChainUpdate configurations
     * @notice Uses vm.broadcast for deployment transactions
     */
    function _applyChainUpdates(address localTokenPoolAddress, TokenPool.ChainUpdate[] memory chainUpdates) private {
        vm.startBroadcast();
        SFTokenPool(localTokenPoolAddress).applyChainUpdates(chainUpdates);
        vm.stopBroadcast();
    }

    /**
     * @dev Converts PoolConfig to ChainUpdate format
     * @param poolConfigs Array of PoolConfig structures
     * @return chainUpdates Array of ChainUpdate structures
     * @notice Handles parameter conversion between formats
     */
    function _convertToChainUpdates(ConfigHelper.PoolConfig[] memory poolConfigs) private pure returns (TokenPool.ChainUpdate[] memory) {
        TokenPool.ChainUpdate[] memory chainUpdates = new TokenPool.ChainUpdate[](poolConfigs.length);
        for (uint256 i = 0; i < poolConfigs.length; i++) {
            ConfigHelper.PoolConfig memory c = poolConfigs[i];
            TokenPool.ChainUpdate memory chainUpdate = TokenPool.ChainUpdate({
                remoteChainSelector: c.remoteChainSelector,
                allowed: c.allowed,
                remotePoolAddress: abi.encode(c.remotePoolAddress),
                remoteTokenAddress: abi.encode(c.remoteTokenAddress),
                outboundRateLimiterConfig: RateLimiter.Config({
                    isEnabled: c.outboundRateLimiterConfig.isEnabled,
                    capacity: c.outboundRateLimiterConfig.capacity,
                    rate: c.outboundRateLimiterConfig.rate
                }),
                inboundRateLimiterConfig: RateLimiter.Config({
                    isEnabled: c.inboundRateLimiterConfig.isEnabled,
                    capacity: c.inboundRateLimiterConfig.capacity,
                    rate: c.inboundRateLimiterConfig.rate
                })
            });
            chainUpdates[i] = chainUpdate;
        }
        return chainUpdates;
    }
}