// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {SFEngine} from "../src/token/SFEngine.sol";
import {SFToken} from "../src/token/SFToken.sol";
import {SFTokenPool} from "../src/token/SFTokenPool.sol";
import {SFAccount} from "../src/account/SFAccount.sol";
import {SFAccountFactory} from "../src/account/SFAccountFactory.sol";
import {ConfigHelper} from "./util/ConfigHelper.sol";
import {BaseDeployment} from "./BaseDeployment.s.sol";

import {Script, console2} from "forge-std/Script.sol";
import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";
import {UpgradeableBeacon} from "@openzeppelin/contracts/proxy/beacon/UpgradeableBeacon.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {Register} from "@chainlink/local/src/ccip/CCIPLocalSimulatorFork.sol";
import {RegistryModuleOwnerCustom} from "@chainlink/contracts/src/v0.8/ccip/tokenAdminRegistry/RegistryModuleOwnerCustom.sol";
import {TokenAdminRegistry} from "@chainlink/contracts/src/v0.8/ccip/tokenAdminRegistry/TokenAdminRegistry.sol";

/**
 * @title DeployOnMainChain
 * @dev Deployment script for main chain components
 * @notice Handles deployment of core protocol contracts on the main chain
 * @notice Inherits from BaseDeployment for shared functionality
 */
contract DeployOnMainChain is BaseDeployment {
    
    /**
     * @dev Error thrown when deployment attempted on non-main chain
     */
    error DeployOnMainChain__NotOnMainChain();

    /**
     * @dev Main deployment script entry point
     * @notice Verifies chain is main chain before deployment
     * @notice Calls full deployment process
     */
    function run() external {
        if (block.chainid != chainConfig.mainChainId) {
            revert DeployOnMainChain__NotOnMainChain();
        }
        deploy();
    }

    /**
     * @dev Executes full main chain deployment
     * @return sfTokenAddress Deployed SFToken address
     * @return sfEngineAddress Deployed SFEngine address
     * @return sfTokenPoolAddress Deployed SFTokenPool address
     * @return sfBridgeAddress Deployed SFBridge address
     * @return sfAccountFactoryAddress Deployed SFAccountFactory address
     * @return sfAccountBeaconAddress Deployed SFAccount beacon address
     * @notice Coordinates deployment of all main chain components
     */
    function deploy() public returns (
        address sfTokenAddress, 
        address sfEngineAddress,
        address sfTokenPoolAddress,
        address sfBridgeAddress,
        address sfAccountFactoryAddress,
        address sfAccountBeaconAddress
    ) {
        (sfTokenAddress, sfEngineAddress, sfTokenPoolAddress) = _deploySFTokenAndPoolAndEngine();
        sfBridgeAddress = _deploySFBridge(sfTokenAddress);
        sfAccountBeaconAddress = _deploySFAccountBeacon();
        sfAccountFactoryAddress = _deployAccountFactory(sfEngineAddress, sfAccountBeaconAddress);
        _saveDeployment(
            sfTokenAddress,
            sfEngineAddress, 
            sfTokenPoolAddress,
            sfBridgeAddress,
            sfAccountFactoryAddress, 
            sfAccountBeaconAddress
        );
    }

    /**
     * @dev Deploys token, engine and pool contracts
     * @return sfTokenAddress Deployed SFToken address
     * @return sfEngineAddress Deployed SFEngine address
     * @return sfTokenPoolAddress Deployed SFTokenPool address
     * @notice Uses proxy patterns for upgradeability
     * @notice Configures token admin registry and permissions
     */
    function _deploySFTokenAndPoolAndEngine() private returns (
        address sfTokenAddress, 
        address sfEngineAddress,
        address sfTokenPoolAddress
    ) {
        bytes32 salt = _salt();
        tokenAddresses = [deployConfig.wethTokenAddress, deployConfig.wbtcTokenAddress];
        priceFeedAddresses = [deployConfig.wethPriceFeedAddress, deployConfig.wbtcPriceFeedAddress];
        vm.startBroadcast(deployConfig.account);
        // Deploy SFToken and SFEngine implementation
        SFToken sfToken = new SFToken{salt: salt}();
        SFEngine sfEngine = new SFEngine{salt: salt}();
        // Deploy SFToken proxy
        SFToken sfTokenProxy = SFToken(address(new ERC1967Proxy{salt: salt}(address(sfToken), "")));
        sfTokenProxy.initialize();
        // Deploy SFEngine proxy
        SFEngine sfEngineProxy = SFEngine(address(new ERC1967Proxy{salt: salt}(address(sfEngine), "")));
        // Allow SFEngine spend deployer's link to fund upkeep
        uint256 initialUpkeepLinkAmount = sfEngine.getUpkeepInitialLinkAmount();
        IERC20(deployConfig.linkTokenAddress).approve(address(sfEngineProxy), initialUpkeepLinkAmount);
        sfEngineProxy.initialize(
            address(sfTokenProxy), 
            deployConfig.aavePoolAddress,
            deployConfig.investmentRatio,
            deployConfig.autoHarvestDuration,
            deployConfig.bonusRate,
            deployConfig.automationRegistrarAddress,
            deployConfig.linkTokenAddress,
            deployConfig.upkeepGasLimit,
            tokenAddresses, 
            priceFeedAddresses
        );
        // Deploy token pool
        Register.NetworkDetails memory networkDetails = register.getNetworkDetails(block.chainid);
        SFTokenPool sfTokenPool = new SFTokenPool(
            chainConfig.mainChainId,
            sfTokenProxy,
            new address[](0),
            networkDetails.rmnProxyAddress,
            networkDetails.routerAddress
        );
        // Set token admin as the token owner
        RegistryModuleOwnerCustom(
            networkDetails.registryModuleOwnerCustomAddress
        ).registerAdminViaOwner(address(sfTokenProxy));
        // Complete the registration process
        TokenAdminRegistry tokenAdminRegistry = TokenAdminRegistry(networkDetails.tokenAdminRegistryAddress);
        TokenAdminRegistry(networkDetails.tokenAdminRegistryAddress).acceptAdminRole(address(sfTokenProxy));
        // Link token to the pool
        tokenAdminRegistry.setPool(address(sfTokenProxy), address(sfTokenPool));
        // Grant minter role to SF Engine and SF token pool
        sfTokenProxy.addMinter(address(sfEngineProxy));
        sfTokenProxy.addMinter(address(sfTokenPool));
        vm.stopBroadcast();
        return (address(sfTokenProxy), address(sfEngineProxy), address(sfTokenPool));
    }

    /**
     * @dev Deploys upgradeable beacon for SFAccount contracts
     * @return beaconAddress Address of deployed beacon
     * @notice Uses salt for deterministic deployment
     */
    function _deploySFAccountBeacon() private returns (address beaconAddress) {
        bytes32 salt = _salt();
        vm.startBroadcast(deployConfig.account);
        SFAccount sfAccount = new SFAccount{salt: salt}();
        UpgradeableBeacon beacon = new UpgradeableBeacon{salt: salt}(address(sfAccount), deployConfig.account);
        vm.stopBroadcast();
        return address(beacon);
    }

    /**
     * @dev Deploys account factory with proxy
     * @param sfEngine Address of SFEngine contract
     * @param beacon Address of SFAccount beacon
     * @return accountFactoryAddress Deployed factory address
     * @notice Initializes factory with core dependencies
     */
    function _deployAccountFactory(address sfEngine, address beacon) private returns (address accountFactoryAddress) {
        bytes32 salt = _salt();
        vm.startBroadcast(deployConfig.account);
        SFAccountFactory factory = new SFAccountFactory{salt: salt}();
        SFAccountFactory factoryProxy = SFAccountFactory(address(new ERC1967Proxy{salt: salt}(address(factory), "")));
        factoryProxy.initialize(
            deployConfig.entryPointAddress, 
            sfEngine, 
            beacon, 
            deployConfig.maxUserAccount,
            deployConfig.automationRegistrarAddress,
            deployConfig.linkTokenAddress,
            deployConfig.vaultConfig, 
            deployConfig.recoveryConfig
        );
        vm.stopBroadcast();
        return address(factoryProxy);
    }

    /**
     * @dev Saves deployment addresses to config
     * @param sfTokenAddress SFToken address
     * @param sfEngineAddress SFEngine address
     * @param sfTokenPoolAddress SFTokenPool address
     * @param sfBridgeAddress SFBridge address
     * @param sfAccountFactoryAddress SFAccountFactory address
     * @param sfAccountBeaconAddress SFAccount beacon address
     */
    function _saveDeployment(
        address sfTokenAddress, 
        address sfEngineAddress,
        address sfTokenPoolAddress,
        address sfBridgeAddress,
        address sfAccountFactoryAddress,
        address sfAccountBeaconAddress
    ) private {
        names = ["SFToken", "SFEngine", "SFTokenPool", "SFBridge", "SFAccountBeacon", "SFAccountFactory"];
        deployments = [sfTokenAddress, sfEngineAddress, sfTokenPoolAddress, sfBridgeAddress, sfAccountBeaconAddress, sfAccountFactoryAddress];
        configHelper.saveDeployment(names, deployments);
    }

    /**
     * @dev Generates deployment salt
     * @return bytes32 Salt value for deterministic deployment
     * @notice Combines deployer address and timestamp
     */
    function _salt() private view returns (bytes32) {
        return keccak256(abi.encode(deployConfig.account, block.timestamp));
    }
}