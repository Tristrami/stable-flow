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

contract DeployOnOtherChain is BaseDeployment {

    error DeployOnOtherChain__CanNotDeployOnMainChain();

    function run() external {
        if (block.chainid == chainConfig.mainChainId) {
            revert DeployOnOtherChain__CanNotDeployOnMainChain();
        }
        deploy();
    }

    function deploy() public returns (
        address sfTokenAddress,
        address sfTokenPoolAddress,
        address sfBridgeAddress,
        DeployHelper.DeployConfig memory config
    ) {
        config = deployConfig;
        (sfTokenAddress, sfTokenPoolAddress) = _deploySFTokenAndTokenPool();
        sfBridgeAddress = _deploySFBridge(sfTokenAddress);
        _saveDeployment(sfTokenAddress, sfTokenPoolAddress, sfBridgeAddress);
    }

    function _deploySFTokenAndTokenPool() private returns (
        address sfTokenAddress, 
        address sfTokenPoolAddress
    ) {
        Register.NetworkDetails memory networkDetails = register.getNetworkDetails(block.chainid);
        vm.startBroadcast(deployConfig.account);
        SFToken sfToken = new SFToken();
        SFToken sfTokenProxy = SFToken(address(new ERC1967Proxy(address(sfToken), "")));
        sfTokenProxy.initialize();
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
        sfTokenProxy.addMinter(address(sfTokenPool));
        vm.stopBroadcast();
        return (address(sfTokenProxy), address(sfTokenPool));
    }

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