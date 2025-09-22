// SPDX-License-Identifier: MIT
pragma solidity ^0.8.30;

import {SFEngine} from "../src/token/SFEngine.sol";
import {SFToken} from "../src/token/SFToken.sol";
import {DeployHelper} from "./util/DeployHelper.sol";
import {Script} from "forge-std/Script.sol";
import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";

contract DeploySFEngine is Script {

    address[] private s_tokenAddresses;
    address[] private s_priceFeedAddresses;

    function run() external {
        deploy();
    }

    function deploy() public returns (SFEngine, DeployHelper.DeployConfig memory) {
        DeployHelper deployHelper = new DeployHelper();
        DeployHelper.DeployConfig memory deployConfig = deployHelper.getDeployConfig();
        s_tokenAddresses = [deployConfig.wethTokenAddress, deployConfig.wbtcTokenAddress];
        s_priceFeedAddresses = [deployConfig.wethPriceFeedAddress, deployConfig.wbtcPriceFeedAddress];
        vm.startBroadcast();
        // Deploy SFToken and SFEngine implementation
        SFToken sfToken = new SFToken();
        SFEngine sfEngine = new SFEngine();
        // Deploy SFToken proxy
        SFToken sfTokenProxy = SFToken(address(new ERC1967Proxy(address(sfToken), "")));
        sfTokenProxy.initialize();
        // Deploy SFEngine proxy
        SFEngine sfEngineProxy = SFEngine(address(new ERC1967Proxy(address(sfEngine), "")));
        sfEngineProxy.initialize(address(sfTokenProxy), s_tokenAddresses, s_priceFeedAddresses);
        // Transfer SFToken's ownership to sfEngineProxy
        sfTokenProxy.transferOwnership(address(sfEngineProxy));
        vm.stopBroadcast();
        return (sfEngineProxy, deployConfig);
    }
}
