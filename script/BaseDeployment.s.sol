// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {SFToken} from "../src/token/SFToken.sol";
import {SFBridge} from "../src/bridge/SFBridge.sol";
import {DeployHelper} from "./util/DeployHelper.sol";
import {ConfigHelper} from "./util/ConfigHelper.sol";
import {Script} from "forge-std/Script.sol";
import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";
import {Register} from "@chainlink/local/src/ccip/CCIPLocalSimulatorFork.sol";

/**
 * @title BaseDeployment
 * @dev Base contract for deployment scripts in StableFlow protocol
 * @notice Provides common deployment utilities and configurations
 */
contract BaseDeployment is Script {

    /// @dev Array of token addresses used in deployments
    address[] internal tokenAddresses;
    /// @dev Array of price feed addresses corresponding to tokens
    address[] internal priceFeedAddresses;
    /// @dev Array of contract names for deployment tracking
    string[] internal names;
    /// @dev Array of deployed contract addresses
    address[] internal deployments;
    /// @dev Instance of DeployHelper utility
    DeployHelper internal deployHelper;
    /// @dev Current deployment configuration
    DeployHelper.DeployConfig internal deployConfig;
    /// @dev Instance of ConfigHelper utility
    ConfigHelper internal configHelper;
    /// @dev Current chain configuration
    ConfigHelper.ChainConfig internal chainConfig;
    /// @dev CCIP network register instance
    Register internal register;

    /**
     * @dev Constructor initializes deployment utilities
     * @notice Loads configurations from helper contracts
     * @notice Sets up CCIP network register
     */
    constructor() {
        deployHelper = new DeployHelper();
        deployConfig = deployHelper.getDeployConfig();
        configHelper = new ConfigHelper();
        chainConfig = configHelper.getChainConfig();
        register = deployConfig.ccipRegister;
    }

    /**
     * @dev Returns the current deployment configuration
     */
    function getDeployConfig() external view returns (DeployHelper.DeployConfig memory config) {
        return deployConfig;
    }

    /**
     * @dev Deploys SFBridge with proxy pattern
     * @param sfTokenAddress Address of SFToken contract
     * @return sfBridgeAddress Address of deployed SFBridge proxy
     * @notice Deployment process:
     * 1. Gets chain selectors for all supported chains
     * 2. Deploys implementation and proxy contracts
     * 3. Initializes bridge with token, CCIP and chain config
     * Requirements:
     * - Must be called with broadcast enabled
     * - deployConfig.account must have deployment privileges
     */
    function _deploySFBridge(address sfTokenAddress) internal returns (address sfBridgeAddress) {
        uint256 numOfSupportedChains = chainConfig.supportedChains.length;
        uint64[] memory chainSelectors = new uint64[](numOfSupportedChains);
        // Map chain IDs to CCIP chain selectors
        for (uint256 i = 0; i < numOfSupportedChains; i++) {
            uint256 chainId = chainConfig.supportedChains[i];
            Register.NetworkDetails memory networkDetails = register.getNetworkDetails(chainId);
            chainSelectors[i] = networkDetails.chainSelector;
        }
        Register.NetworkDetails memory currentChainNetworkDetails = register.getNetworkDetails(block.chainid);
        vm.startBroadcast(deployConfig.account);
        // Deploy implementation
        SFBridge sfBridge = new SFBridge();
        // Deploy and initialize proxy
        SFBridge sfBridgeProxy = SFBridge(address(new ERC1967Proxy(address(sfBridge), "")));
        sfBridgeProxy.initialize(
            SFToken(sfTokenAddress), 
            currentChainNetworkDetails.linkAddress, 
            currentChainNetworkDetails.routerAddress, 
            chainConfig.supportedChains, 
            chainSelectors
        );
        vm.stopBroadcast();
        return address(sfBridgeProxy);
    }
}