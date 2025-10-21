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
import {Register} from "@chainlink/local/src/ccip/CCIPLocalSimulatorFork.sol";

/**
 * @title DeployHelper
 * @dev Deployment configuration helper for cross-chain setups
 * @notice Manages chain-specific configurations and mock deployments
 * @notice Supports Ethereum Sepolia and Avalanche Fuji testnets
 */
contract DeployHelper is Script, Constants {
    
    /**
     * @dev Error thrown when attempting to use an unsupported chain
     * @param chainId The unsupported chain ID
     */
    error DeployHelper__ChainNotSupported(uint256 chainId);
    
    /**
     * @dev Deployment configuration structure
     * @param account Default deployer account
     * @param wethTokenAddress WETH token contract address
     * @param wethPriceFeedAddress WETH price feed address
     * @param wbtcTokenAddress WBTC token contract address
     * @param wbtcPriceFeedAddress WBTC price feed address
     * @param aavePoolAddress Aave pool contract address
     * @param aaveDataProviderAddress Aave data provider address
     * @param aaveInterestRateStrategyAddress Aave interest rate strategy
     * @param investmentRatio Base investment ratio (1e18 precision)
     * @param bonusRate Bonus rate for early harvesters (1e18 precision)
     * @param autoHarvestDuration Duration between auto-harvests (seconds)
     * @param automationRegistrarAddress Chainlink Automation registrar
     * @param linkTokenAddress LINK token contract address
     * @param entryPointAddress Account Abstraction EntryPoint
     * @param maxUserAccount Maximum accounts per user
     * @param vaultConfig Vault plugin configuration
     * @param recoveryConfig Social recovery configuration
     * @param ccipRegister CCIP network register
     * @param chainSelector CCIP chain selector
     */
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
        uint32 upkeepGasLimit;
        address linkTokenAddress;
        address entryPointAddress;
        uint256 maxUserAccount;
        IVaultPlugin.VaultConfig vaultConfig;
        ISocialRecoveryPlugin.RecoveryConfig recoveryConfig;
        Register ccipRegister;
        uint64 chainSelector;
    }

    /// @dev Active deployment configuration
    DeployConfig private activeConfig;
    /// @dev Array of supported collateral addresses
    address[] private collaterals;
    /// @dev Array of price feed addresses
    address[] private priceFeeds;
    /// @dev Array of deployment names
    string[] private names;
    /// @dev Array of deployment addresses
    address[] private deployments;
    /// @dev Configuration helper instance
    ConfigHelper configHelper = new ConfigHelper();

    /**
     * @dev Constructor that initializes chain-specific configuration
     */
    constructor() {
        _initialize();
    }

    /**
     * @dev Returns the active deployment configuration
     * @return DeployConfig Current deployment settings
     */
    function getDeployConfig() public view returns (DeployConfig memory) {
        return activeConfig;
    }

    /**
     * @dev Initializes chain-specific configuration
     * @notice Selects appropriate config based on current chain ID
     * @notice Reverts with DeployHelper__ChainNotSupported for unsupported chains
     */
    function _initialize() private {
        if (block.chainid == ETH_SEPOLIA_CHAIN_ID) {
            activeConfig = _createEthSepoliaConfig();
        } else if (block.chainid == AVA_FUJI_CHAIN_ID) {
            activeConfig = _createAvaFujiConfig();
        } else {
            revert DeployHelper__ChainNotSupported(block.chainid);
        }
    }

    /**
     * @dev Creates Ethereum Sepolia testnet configuration
     * @return config Complete Sepolia deployment configuration
     * @notice Deploys mock price feeds and interest rate strategy
     * @notice Configures Aave pool with test parameters
     */
    function _createEthSepoliaConfig() private returns (DeployConfig memory config) {
        // Add a private key to the local forge wallet in convenience of `vm.sign()`
        address account = vm.rememberKey(0xac0974bec39a17e36ba4a6b4d238ff944bacb478cbed5efcae784d7bf4f2ff80);
        (
            address wethPriceFeed, 
            address wbtcPriceFeed,
            address aaveInterestRateStrategy
        ) = _deploySepoliaMocks(account);
        address aavePoolAddress = AaveV3Sepolia.POOL_ADDRESSES_PROVIDER.getPool();
        // https://app.aave.com/
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
        Register register = new Register();
        return DeployConfig({
            account: account,
            wethTokenAddress: wethTokenAddress,
            wethPriceFeedAddress: wethPriceFeed,
            wbtcTokenAddress: wbtcTokenAddress,
            wbtcPriceFeedAddress: wbtcPriceFeed,
            aavePoolAddress: aavePoolAddress,
            aaveDataProviderAddress: address(AaveV3Sepolia.AAVE_PROTOCOL_DATA_PROVIDER),
            aaveInterestRateStrategyAddress: aaveInterestRateStrategy,
            investmentRatio: 2 * 10 ** (PRECISION - 1),
            bonusRate: 1 * 10 ** (PRECISION - 1),
            autoHarvestDuration: 7 days,
            automationRegistrarAddress: 0xb0E49c5D0d05cbc241d68c05BC5BA1d1B7B72976,
            upkeepGasLimit: 500_000,
            linkTokenAddress: 0x779877A7B0D9E8603169DdbD7836e478b4624789,
            entryPointAddress: 0x305F5521ed2376d19001E65C51e8Ba7895BD01aE,
            maxUserAccount: 10,
            vaultConfig: IVaultPlugin.VaultConfig({
                collaterals: collaterals, 
                priceFeeds: priceFeeds
            }),
            recoveryConfig: ISocialRecoveryPlugin.RecoveryConfig({
                maxGuardians: 5
            }),
            ccipRegister: register,
            chainSelector: register.getNetworkDetails(block.chainid).chainSelector
        });
    }

    /**
     * @dev Creates Avalanche Fuji testnet configuration
     * @return config Basic Fuji deployment configuration
     * @notice Initializes CCIP register and LINK token address
     */
    function _createAvaFujiConfig() private returns (DeployConfig memory config) {
        // Add a private key to the local forge wallet in convenience of `vm.sign()`
        address account = vm.rememberKey(0xac0974bec39a17e36ba4a6b4d238ff944bacb478cbed5efcae784d7bf4f2ff80);
        Register register = new Register();
        config.account = account;
        config.linkTokenAddress = 0x0b9d5D9136855f6FEc3c0993feE6E9CE8a297846;
        config.ccipRegister = register;
        config.chainSelector = register.getNetworkDetails(block.chainid).chainSelector;
    }

    /**
     * @dev Deploys mock contracts for Sepolia testnet
     * @param deployer Address that will deploy the contracts
     * @return wethPriceFeed WETH price feed address
     * @return wbtcPriceFeed WBTC price feed address
     * @return aaveInterestRateStrategy Aave strategy address
     */
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

    /**
     * @dev Saves Sepolia mock deployments to config
     * @param wethPriceFeed WETH price feed address
     * @param wbtcPriceFeed WBTC price feed address
     * @param aaveInterestRateStrategy Aave strategy address
     */
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