// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Script} from "forge-std/Script.sol";
import {ConfigHelper} from "./ConfigHelper.sol";
import {MockERC20} from "../../test/mocks/MockERC20.sol";
import {MockV3Aggregator} from "../../test/mocks/MockV3Aggregator.sol";
import {MockAutomationRegistrar} from "../../test/mocks/MockAutomationRegistrar.sol";
import {Constants} from "./Constants.sol";
import {IVaultPlugin} from "../../src/interfaces/IVaultPlugin.sol"; 
import {ISocialRecoveryPlugin} from "../../src/interfaces/ISocialRecoveryPlugin.sol"; 
import {AaveV3Sepolia} from "aave-address-book/src/AaveV3Sepolia.sol";
import {MockReserveInterestRateStrategy} from "@aave/v3/core/contracts/mocks/tests/MockReserveInterestRateStrategy.sol";
import {IPoolAddressesProvider} from "@aave/v3/core/contracts/interfaces/IPoolAddressesProvider.sol";
import {IPool} from "@aave/v3/core/contracts/interfaces/IPool.sol";
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
        address aaveInterestRateStrategyAddress;
        uint256 investmentRatio;
        uint256 bonusRate;
        uint256 autoHarvestDuration;
        address automationRegistrarAddress;
        address linkTokenAddress;
        address entryPointAddress;
        uint256 maxUserAccount;
        IVaultPlugin.VaultConfig vaultConfig;
        ISocialRecoveryPlugin.RecoveryConfig recoveryConfig;
    }

    DeployConfig private activeConfig;
    address[] private collaterals;
    address[] private priceFeeds;
    string[] private names;
    address[] private deployments;
    ConfigHelper configHelper = new ConfigHelper();

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
        // Add a private key to the local forge wallet in convenience of `vm.sign()`
        address account = vm.rememberKey(0xac0974bec39a17e36ba4a6b4d238ff944bacb478cbed5efcae784d7bf4f2ff80);
        (
            address wethPriceFeed, 
            address wbtcPriceFeed,
            address aaveInterestRateStrategy
        ) = _deploySepoliaMocks(account);
        address aavePoolAddress = AaveV3Sepolia.POOL_ADDRESSES_PROVIDER.getPool();
        address wethTokenAddress = 0xC558DBdd856501FCd9aaF1E62eae57A9F0629a3c;
        address wbtcTokenAddress = 0x29f2D40B0605204364af54EC677bD022dA425d03;
        // 5% liquidity rate
        MockReserveInterestRateStrategy(aaveInterestRateStrategy).setLiquidityRate(5e25);
        vm.startPrank(address(AaveV3Sepolia.POOL_ADDRESSES_PROVIDER.getPoolConfigurator()));
        IPool(aavePoolAddress).setReserveInterestRateStrategyAddress(wethTokenAddress, aaveInterestRateStrategy);
        IPool(aavePoolAddress).setReserveInterestRateStrategyAddress(wbtcTokenAddress, aaveInterestRateStrategy);
        vm.stopPrank();
        collaterals = [wethTokenAddress, wbtcTokenAddress];
        priceFeeds = [wethPriceFeed, wbtcPriceFeed];
        return DeployConfig({
            account: account,
            wethTokenAddress: 0xC558DBdd856501FCd9aaF1E62eae57A9F0629a3c,
            wethPriceFeedAddress: wethPriceFeed, // Real price feed: 0x694AA1769357215DE4FAC081bf1f309aDC325306,
            wbtcTokenAddress: 0x29f2D40B0605204364af54EC677bD022dA425d03,
            wbtcPriceFeedAddress: wbtcPriceFeed, // Real price feed: 0x1b44F3514812d835EB1BDB0acB33d3fA3351Ee43,
            aavePoolAddress: aavePoolAddress,
            aaveDataProviderAddress: address(AaveV3Sepolia.AAVE_PROTOCOL_DATA_PROVIDER),
            aaveInterestRateStrategyAddress: aaveInterestRateStrategy,
            investmentRatio: 2 * 10 ** (PRECISION - 1), // 0.2
            bonusRate: 1 * 10 ** (PRECISION - 1), // 0.1
            autoHarvestDuration: 7 days,
            automationRegistrarAddress: 0xb0E49c5D0d05cbc241d68c05BC5BA1d1B7B72976,
            linkTokenAddress: 0x779877A7B0D9E8603169DdbD7836e478b4624789,
            entryPointAddress: 0x305F5521ed2376d19001E65C51e8Ba7895BD01aE,
            maxUserAccount: 10,
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
        // Add a private key to the local forge wallet in convenience of `vm.sign()`
        address account = vm.rememberKey(0xac0974bec39a17e36ba4a6b4d238ff944bacb478cbed5efcae784d7bf4f2ff80);
        (
            address wrappedEth,
            address wethPriceFeed,
            address wrappedBtc,
            address wbtcPriceFeed,
            address linkToken,
            address entryPoint,
            address automationRegistrar
        ) = _deployLocalMocks(account);
        collaterals = [wrappedEth, wrappedBtc];
        priceFeeds = [wethPriceFeed, wbtcPriceFeed];
        return DeployConfig({
            account: account, 
            wethTokenAddress: wrappedEth,
            wethPriceFeedAddress: wethPriceFeed,
            wbtcTokenAddress: wrappedBtc,
            wbtcPriceFeedAddress: wbtcPriceFeed,
            aavePoolAddress: address(0),
            aaveDataProviderAddress: address(0),
            aaveInterestRateStrategyAddress: address(0),
            investmentRatio: 2 * 10 ** (PRECISION - 1), // 0.2
            bonusRate: 1 * 10 ** (PRECISION - 1), // 0.1
            autoHarvestDuration: 7 days,
            automationRegistrarAddress: automationRegistrar,
            linkTokenAddress: linkToken,
            entryPointAddress: entryPoint,
            maxUserAccount: 10,
            vaultConfig: IVaultPlugin.VaultConfig({
                collaterals: collaterals, 
                priceFeeds: priceFeeds
            }),
            recoveryConfig: ISocialRecoveryPlugin.RecoveryConfig({
                maxGuardians: 5
            })
        });
    }

    function _deployLocalMocks(address deployer) private returns (
        address wrappedEth,
        address wethPriceFeed,
        address wrappedBtc,
        address wbtcPriceFeed,
        address linkToken,
        address entryPoint,
        address automationRegistrar
    ) {
        vm.startBroadcast(deployer);
        wrappedEth = address(new MockERC20("WETH", "WETH", deployer, INITIAL_BALANCE));
        wethPriceFeed = address(new MockV3Aggregator(PRICE_FEED_DECIMALS, int256(WETH_USD_PRICE)));
        wrappedBtc = address(new MockERC20("WBTC", "WBTC", deployer, INITIAL_BALANCE));
        wbtcPriceFeed = address(new MockV3Aggregator(PRICE_FEED_DECIMALS, int256(WBTC_USD_PRICE)));
        linkToken =  address(new MockERC20("LINK", "LINK", deployer, INITIAL_BALANCE));
        entryPoint = address(new EntryPoint());
        automationRegistrar = address(new MockAutomationRegistrar());
        vm.stopBroadcast();
        _saveLocalDeployment(wrappedEth, wethPriceFeed, wrappedBtc, wbtcPriceFeed, linkToken, entryPoint, automationRegistrar);
    }

    function _deploySepoliaMocks(address deployer) private returns (
        address wethPriceFeed,
        address wbtcPriceFeed,
        address aaveInterestRateStrategy
    ) {
        vm.startBroadcast(deployer);
        wethPriceFeed = address(new MockV3Aggregator(PRICE_FEED_DECIMALS, int256(WETH_USD_PRICE)));
        wbtcPriceFeed = address(new MockV3Aggregator(PRICE_FEED_DECIMALS, int256(WBTC_USD_PRICE)));
        MockReserveInterestRateStrategy strategy = new MockReserveInterestRateStrategy(
            IPoolAddressesProvider(address(AaveV3Sepolia.POOL_ADDRESSES_PROVIDER)), 0, 0, 0, 0, 0, 0
        );
        vm.stopBroadcast();
        aaveInterestRateStrategy = address(strategy);
        _saveSepoliaDeployment(wethPriceFeed, wbtcPriceFeed, aaveInterestRateStrategy);
    }

    function _saveLocalDeployment(
        address wrappedEth,
        address wethPriceFeed,
        address wrappedBtc,
        address wbtcPriceFeed,
        address linkToken,
        address entryPoint,
        address automationRegistrar
    ) private {
        names = ["WrappedEth", "WethPriceFeed", "WrappedBtc", "WbtcPriceFeed", "LinkToken", "EntryPoint", "AutomationRegistrar"];
        deployments = [wrappedEth, wethPriceFeed, wrappedBtc, wbtcPriceFeed, linkToken, entryPoint, automationRegistrar];
        configHelper.saveDeployment(names, deployments);
    }

    function _saveSepoliaDeployment(
        address wethPriceFeed,
        address wbtcPriceFeed,
        address aaveInterestRateStrategy
    ) private {
        names = ["WethPriceFeed", "WbtcPriceFeed", "AaveInterestRateStrategy"];
        deployments = [wethPriceFeed, wbtcPriceFeed, aaveInterestRateStrategy];
        configHelper.saveDeployment(names, deployments);
    }
}
