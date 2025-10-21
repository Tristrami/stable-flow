// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {SFToken} from "../src/token/SFToken.sol";
import {SFTokenPool} from "../src/token/SFTokenPool.sol";
import {ConfigHelper} from "./util/ConfigHelper.sol";
import {CCIPLocalSimulatorFork, Register} from "@chainlink/local/src/ccip/CCIPLocalSimulatorFork.sol";
import {RegistryModuleOwnerCustom} from "@chainlink/contracts/src/v0.8/ccip/tokenAdminRegistry/RegistryModuleOwnerCustom.sol";
import {TokenAdminRegistry} from "@chainlink/contracts/src/v0.8/ccip/tokenAdminRegistry/TokenAdminRegistry.sol";
import {TokenPool} from "@chainlink/contracts/src/v0.8/ccip/pools/TokenPool.sol";
import {RateLimiter} from "@chainlink/contracts/src/v0.8/ccip/libraries/RateLimiter.sol";
import {Script, console2} from "forge-std/Script.sol";
import {stdJson} from "forge-std/StdJson.sol";

contract ConfigureTokenPool is Script {

    using stdJson for string;

    ConfigHelper private configHelper;

    constructor() {
        configHelper = new ConfigHelper();
    }

    function run() external {
        address tokenPoolAddress = configHelper.getLatestDeployment("SFTokenPool");
        configure(tokenPoolAddress);
    }

    function configure(address sfTokenPool) public {
        console2.log("Configure token pool using poolConfig.json");
        ConfigHelper.PoolConfig[] memory poolConfigs = configHelper.getPoolConfig();
        TokenPool.ChainUpdate[] memory chainUpdates = _convertToChainUpdates(poolConfigs);
        _applyChainUpdates(sfTokenPool, chainUpdates);
    }

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
        console2.log("Start to configure token pool, chian id:", block.chainid);
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

    function _applyChainUpdates(address localTokenPoolAddress, TokenPool.ChainUpdate[] memory chainUpdates) private {
        vm.startBroadcast();
        SFTokenPool(localTokenPoolAddress).applyChainUpdates(chainUpdates);
        vm.stopBroadcast();
    }

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