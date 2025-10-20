// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test} from "forge-std/Test.sol";
import {SFEngine} from "../src/token/SFEngine.sol";
import {SFToken} from "../src/token/SFToken.sol";
import {DeployOnMainChain} from "../script/DeployOnMainChain.s.sol";
import {Constants} from "../script/util/Constants.sol";
import {DeployHelper} from "../script/util/DeployHelper.sol";

contract BaseTest is Test, Constants {
    
    DeployOnMainChain internal deployer;
    DeployHelper.DeployConfig internal deployConfig;
    SFEngine internal sfEngine;
    SFToken internal sfToken;
    uint256 private sepoliaForkId;

    function _setUp() internal virtual {
        deployer = new DeployOnMainChain();
        (
            address sfTokenAddress, 
            address sfEngineAddress, , , , ,
            DeployHelper.DeployConfig memory config
        ) = deployer.deploy();
        deployConfig = config;
        sfEngine = SFEngine(sfEngineAddress);
        sfToken = SFToken(sfTokenAddress);
        sepoliaForkId = vm.createFork("ethSepolia");
    }
}
