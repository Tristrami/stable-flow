// SPDX-License-Identifier: MIT
pragma solidity ^0.8.30;

import {Test} from "forge-std/Test.sol";
import {SFEngine} from "../src/token/SFEngine.sol";
import {SFToken} from "../src/token/SFToken.sol";
import {DeploySFEngine} from "../script/DeploySFEngine.s.sol";
import {Constants} from "../script/util/Constants.sol";
import {DeployHelper} from "../script/util/DeployHelper.sol";

contract BaseTest is Test, Constants {
    DeploySFEngine internal deployer;
    DeployHelper.DeployConfig internal deployConfig;
    SFEngine internal sfEngine;
    SFToken internal sfToken;

    function _setUp() internal virtual {
        deployer = new DeploySFEngine();
        (sfEngine, deployConfig) = deployer.deploy();
        sfToken = SFToken(sfEngine.getSFTokenAddress());
    }
}
