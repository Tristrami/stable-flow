// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Script} from "forge-std/Script.sol";
import {SFToken} from "../src/token/SFToken.sol";
import {SFTokenPool} from "../src/token/SFTokenPool.sol";
import {SFBridge} from "../src/bridge/SFBridge.sol";
import {DeployHelper} from "./util/DeployHelper.sol";
import {ConfigHelper} from "./util/ConfigHelper.sol";
import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";
import {BaseDeployment} from "./BaseDeployment.s.sol";
import {Register} from "@chainlink/local/src/ccip/CCIPLocalSimulatorFork.sol";
import {RegistryModuleOwnerCustom} from "@chainlink/contracts/src/v0.8/ccip/tokenAdminRegistry/RegistryModuleOwnerCustom.sol";
import {TokenAdminRegistry} from "@chainlink/contracts/src/v0.8/ccip/tokenAdminRegistry/TokenAdminRegistry.sol";

/**
 * @title DeployOnOtherChain
 * @dev Deployment script for other chains components
 * @notice Handles deployment of bridge contracts on non-main chains
 * @notice Inherits from BaseDeployment for shared functionality
 */
contract DeployOnOtherChain is BaseDeployment {
    /**
     * @dev Error thrown when deployment attempted on main chain
     */
    error DeployOnOtherChain__CannotDeployOnMainChain();

    /**
     * @dev Main deployment script entry point
     * @notice Verifies chain is not main chain before deployment
     * @notice Calls full deployment process
     */
    function run() external {
        if (block.chainid == chainConfig.mainChainId) {
            revert DeployOnOtherChain__CannotDeployOnMainChain();
        }
        deploy();
    }

    /**
     * @dev Executes secondary chain deployment
     * @return sfTokenAddress Deployed SFToken address
     * @return sfTokenPoolAddress Deployed SFTokenPool address
     * @return sfBridgeAddress Deployed SFBridge address
     * @notice Coordinates deployment of bridge components on secondary chains
     */
    function deploy() public returns (
        address sfTokenAddress,
        address sfTokenPoolAddress,
        address sfBridgeAddress
    ) {
        (sfTokenAddress, sfTokenPoolAddress) = _deploySFTokenAndTokenPool();
        sfBridgeAddress = _deploySFBridge(sfTokenAddress);
        _saveDeployment(sfTokenAddress, sfTokenPoolAddress, sfBridgeAddress);
    }

    /**
     * @dev Deploys token and token pool contracts
     * @return sfTokenAddress Deployed SFToken address
     * @return sfTokenPoolAddress Deployed SFTokenPool address
     * @notice Uses proxy pattern for SFToken
     * @notice Configures token admin registry and permissions
     */
    function _deploySFTokenAndTokenPool() private returns (
        address sfTokenAddress, 
        address sfTokenPoolAddress
    ) {
        Register.NetworkDetails memory networkDetails = register.getNetworkDetails(block.chainid);
        vm.startBroadcast(deployConfig.account);
        
        // Deploy SFToken with proxy
        SFToken sfToken = new SFToken();
        SFToken sfTokenProxy = SFToken(address(new ERC1967Proxy(address(sfToken), "")));
        sfTokenProxy.initialize();
        
        // Deploy token pool
        SFTokenPool sfTokenPool = new SFTokenPool(
            chainConfig.mainChainId,
            sfTokenProxy,
            new address[](0),
            networkDetails.rmnProxyAddress,
            networkDetails.routerAddress
        );
        
        // Configure token admin permissions
        RegistryModuleOwnerCustom(
            networkDetails.registryModuleOwnerCustomAddress
        ).registerAdminViaOwner(address(sfTokenProxy));
        
        TokenAdminRegistry tokenAdminRegistry = TokenAdminRegistry(networkDetails.tokenAdminRegistryAddress);
        tokenAdminRegistry.acceptAdminRole(address(sfTokenProxy));
        tokenAdminRegistry.setPool(address(sfTokenProxy), address(sfTokenPool));
        
        // Grant minter role to token pool
        sfTokenProxy.addMinter(address(sfTokenPool));
        
        vm.stopBroadcast();
        return (address(sfTokenProxy), address(sfTokenPool));
    }

    /**
     * @dev Saves deployment addresses to config
     * @param sfTokenAddress SFToken address
     * @param sfTokenPoolAddress SFTokenPool address
     * @param sfBridgeAddress SFBridge address
     */
    function _saveDeployment(
        address sfTokenAddress,
        address sfTokenPoolAddress,
        address sfBridgeAddress
    ) private {
        names = ["SFToken", "SFTokenPool", "SFBridge"];
        deployments = [sfTokenAddress, sfTokenPoolAddress, sfBridgeAddress];
        configHelper.saveDeployment(names, deployments);
    }
}