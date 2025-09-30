// SPDX-License-Identifier: MIT
pragma solidity ^0.8.30;

import {Script} from "forge-std/Script.sol";
import {ERC20Mock} from "../../test/mocks/ERC20Mock.sol";
import {MockV3Aggregator} from "../../test/mocks/MockV3Aggregator.sol";
import {Constants} from "./Constants.sol";
import {IVaultPlugin} from "../../src/interfaces/IVaultPlugin.sol"; 
import {ISocialRecoveryPlugin} from "../../src/interfaces/ISocialRecoveryPlugin.sol"; 
import {MockLinkToken} from "@chainlink/contracts/src/v0.8/mocks/MockLinkToken.sol";
import {AaveV3Sepolia, IPoolAddressesProvider} from "aave-address-book/src/AaveV3Sepolia.sol";
import {EntryPoint} from "account-abstraction/contracts/core/EntryPoint.sol";

contract DeployHelper is Script, Constants {

    error DeployHelper__ChainNotSupported(uint256 chainId);
    
    struct DeployConfig {
        address account;
        address wethTokenAddress;
        address wethPriceFeedAddress;
        address wbtcTokenAddress;
        address wbtcPriceFeedAddress;
        address aavePoolAddress;
        address aaveDataProviderAddress;
        uint256 investmentRatio;
        uint256 bonusRate;
        uint256 autoHarvestDuration;
        address automationRegistryAddress;
        address linkTokenAddress;
        address entryPointAddress;
        IVaultPlugin.VaultConfig vaultConfig;
        ISocialRecoveryPlugin.RecoveryConfig recoveryConfig;
    }

    DeployConfig private activeConfig;
    address[] private collaterals;
    address[] private priceFeeds;

    constructor() {
        _initialize();
    }

    function getDeployConfig() public view returns (DeployConfig memory) {
        return activeConfig;
    }

    function _initialize() private {
        if (block.chainid == ANVIL_CHAIN_ID) {
            activeConfig = _createAnvilConfig();
        } else if (block.chainid == ANVIL_SEPOLIA_CHAIN_ID) {
            activeConfig = _getAnvilEthSepoliaConfig();
        } else {
            revert DeployHelper__ChainNotSupported(block.chainid);
        }
    }

    function _getAnvilEthSepoliaConfig() private returns (DeployConfig memory) {
        (address wethPriceFeed, address wbtcPriceFeed) = _deploySepoliaMocks();
        address aavePoolAddress = AaveV3Sepolia.POOL_ADDRESSES_PROVIDER.getPool();
        address wethTokenAddress = 0xC558DBdd856501FCd9aaF1E62eae57A9F0629a3c;
        address wbtcTokenAddress = 0x29f2D40B0605204364af54EC677bD022dA425d03;
        collaterals = [wethTokenAddress, wbtcTokenAddress];
        priceFeeds = [wethPriceFeed, wbtcPriceFeed];
        return DeployConfig({
            account: 0xf39Fd6e51aad88F6F4ce6aB8827279cffFb92266, // If I use my sepolia account, it will revert CreateCollision when deploying, don't know why, so change this to anvil rich account
            wethTokenAddress: 0xC558DBdd856501FCd9aaF1E62eae57A9F0629a3c,
            wethPriceFeedAddress: wethPriceFeed, // Real price feed: 0x694AA1769357215DE4FAC081bf1f309aDC325306,
            wbtcTokenAddress: 0x29f2D40B0605204364af54EC677bD022dA425d03,
            wbtcPriceFeedAddress: wbtcPriceFeed, // Real price feed: 0x1b44F3514812d835EB1BDB0acB33d3fA3351Ee43,
            aavePoolAddress: aavePoolAddress,
            aaveDataProviderAddress: address(AaveV3Sepolia.AAVE_PROTOCOL_DATA_PROVIDER),
            investmentRatio: 2 * 10 ** (PRECISION - 1), // 0.2
            bonusRate: 1 * 10 ** (PRECISION - 1), // 0.1
            autoHarvestDuration: 7 days,
            automationRegistryAddress: 0x86EFBD0b6736Bed994962f9797049422A3A8E8Ad,
            linkTokenAddress: 0x779877A7B0D9E8603169DdbD7836e478b4624789,
            entryPointAddress: 0x5FF137D4b0FDCD49DcA30c7CF57E578a026d2789,
            vaultConfig: IVaultPlugin.VaultConfig({
                collaterals: collaterals, 
                priceFeeds: priceFeeds
            }),
            recoveryConfig: ISocialRecoveryPlugin.RecoveryConfig({
                maxGuardians: 5
            })
        });
    }

    function _createAnvilConfig() private returns (DeployConfig memory) {
        (
            address wrappedEth,
            address wethPriceFeed,
            address wrappedBtc,
            address wbtcPriceFeed,
            address linkToken,
            address entryPoint
        ) = _deployLocalMocks();
        collaterals = [wrappedEth, wrappedBtc];
        priceFeeds = [wethPriceFeed, wbtcPriceFeed];
        return DeployConfig({
            account: 0xf39Fd6e51aad88F6F4ce6aB8827279cffFb92266,
            wethTokenAddress: wrappedEth,
            wethPriceFeedAddress: wethPriceFeed,
            wbtcTokenAddress: wrappedBtc,
            wbtcPriceFeedAddress: wbtcPriceFeed,
            aavePoolAddress: address(0),
            aaveDataProviderAddress: address(0),
            investmentRatio: 2 * 10 ** (PRECISION - 1), // 0.2
            bonusRate: 1 * 10 ** (PRECISION - 1), // 0.1
            autoHarvestDuration: 7 days,
            automationRegistryAddress: address(0),
            linkTokenAddress: linkToken,
            entryPointAddress: entryPoint,
            vaultConfig: IVaultPlugin.VaultConfig({
                collaterals: collaterals, 
                priceFeeds: priceFeeds
            }),
            recoveryConfig: ISocialRecoveryPlugin.RecoveryConfig({
                maxGuardians: 5
            })
        });
    }

    function _deployLocalMocks() private returns (
        address wrappedEth,
        address wethPriceFeed,
        address wrappedBtc,
        address wbtcPriceFeed,
        address linkToken,
        address entryPoint
    ) {
        vm.startBroadcast();
        wrappedEth = address(new ERC20Mock("WETH", "WETH", msg.sender, INITIAL_BALANCE));
        wethPriceFeed = address(new MockV3Aggregator(PRICE_FEED_DECIMALS, int256(WETH_USD_PRICE)));
        wrappedBtc = address(new ERC20Mock("WBTC", "WBTC", msg.sender, INITIAL_BALANCE));
        wbtcPriceFeed = address(new MockV3Aggregator(PRICE_FEED_DECIMALS, int256(WBTC_USD_PRICE)));
        linkToken =  address(new MockLinkToken());
        entryPoint = address(new EntryPoint());
        vm.stopBroadcast();
    }

    function _deploySepoliaMocks() private returns (
        address wethPriceFeed,
        address wbtcPriceFeed
    ) {
        wethPriceFeed = address(new MockV3Aggregator(PRICE_FEED_DECIMALS, int256(WETH_USD_PRICE)));
        wbtcPriceFeed = address(new MockV3Aggregator(PRICE_FEED_DECIMALS, int256(WBTC_USD_PRICE)));
    }
}
