// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {SFEngine} from "../src/token/SFEngine.sol";
import {SFToken} from "../src/token/SFToken.sol";
import {SFAccount} from "../src/account/SFAccount.sol";
import {SFBridge} from "../src/bridge/SFBridge.sol";
import {SFAccountFactory} from "../src/account/SFAccountFactory.sol";
import {DeployHelper} from "./util/DeployHelper.sol";
import {ConfigHelper} from "./util/ConfigHelper.sol";
import {Script} from "forge-std/Script.sol";
import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";
import {Register} from "@chainlink/local/src/ccip/CCIPLocalSimulatorFork.sol";

contract BaseDeployment is Script {

    address[] internal tokenAddresses;
    address[] internal priceFeedAddresses;
    string[] internal names;
    address[] internal deployments;
    DeployHelper internal deployHelper;
    ConfigHelper internal configHelper;
    ConfigHelper.ChainConfig internal chainConfig;
    Register internal register;

    constructor() {
        deployHelper = new DeployHelper();
        configHelper = new ConfigHelper();
        register = new Register();
        chainConfig = configHelper.getChainConfig();
        register = new Register();
    }

    function _deploySFBridge(address sfTokenAddress) internal returns (address sfBridgeAddress) {
        DeployHelper.DeployConfig memory deployConfig = deployHelper.getDeployConfig();
        uint256 numOfSupportedChains = chainConfig.supportedChains.length;
        uint64[] memory chainSelectors = new uint64[](numOfSupportedChains);
        for (uint256 i = 0; i < numOfSupportedChains; i++) {
            uint256 chainId = chainConfig.supportedChains[i];
            Register.NetworkDetails memory networkDetails = register.getNetworkDetails(chainId);
            chainSelectors[i] = networkDetails.chainSelector;
        }
        Register.NetworkDetails memory currentChainNetworkDetails = register.getNetworkDetails(block.chainid);
        vm.startBroadcast(deployConfig.account);
        SFBridge sfBridge = new SFBridge();
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