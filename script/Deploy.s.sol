// SPDX-License-Identifier: MIT
pragma solidity ^0.8.30;

import {SFEngine} from "../src/token/SFEngine.sol";
import {SFToken} from "../src/token/SFToken.sol";
import {SFAccount} from "../src/account/SFAccount.sol";
import {SFAccountFactory} from "../src/account/SFAccountFactory.sol";
import {DeployHelper} from "./util/DeployHelper.sol";
import {DevOps} from "./util/DevOps.s.sol";
import {Script} from "forge-std/Script.sol";
import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";
import {UpgradeableBeacon} from "@openzeppelin/contracts/proxy/beacon/UpgradeableBeacon.sol";

contract Deploy is Script {

    address[] private tokenAddresses;
    address[] private priceFeedAddresses;
    string[] private names;
    address[] private deployments;
    DeployHelper private deployHelper;
    DevOps private devOps;

    constructor() {
        deployHelper = new DeployHelper();
        devOps = new DevOps();
    }

    function run() external {
        deploy();
    }

    function deploy() public returns (
        address sfTokenAddress, 
        address sfEngineAddress,
        address sfAccountFactoryAddress,
        address sfAccountBeaconAddress,
        DeployHelper.DeployConfig memory deployConfig
    ) {
        deployConfig = deployHelper.getDeployConfig();
        (sfTokenAddress, sfEngineAddress) = _deploySFTokenAndEngine();
        sfAccountBeaconAddress = _deploySFAccountBeacon();
        sfAccountFactoryAddress = _deployAccountFactory(sfEngineAddress, sfAccountBeaconAddress);
        _saveDeployment(
            sfTokenAddress,
            sfEngineAddress, 
            sfAccountFactoryAddress, 
            sfAccountBeaconAddress
        );
    }

    function _deploySFTokenAndEngine() private returns (address sfTokenAddress, address sfEngineAddress) {
        DeployHelper.DeployConfig memory deployConfig = deployHelper.getDeployConfig();
        bytes32 salt = _salt();
        tokenAddresses = [deployConfig.wethTokenAddress, deployConfig.wbtcTokenAddress];
        priceFeedAddresses = [deployConfig.wethPriceFeedAddress, deployConfig.wbtcPriceFeedAddress];
        vm.startBroadcast(deployConfig.account);
        // Deploy SFToken and SFEngine implementation
        SFToken sfToken = new SFToken{salt: salt}();
        SFEngine sfEngine = new SFEngine{salt: salt}();
        // Deploy SFToken proxy
        SFToken sfTokenProxy = SFToken(address(new ERC1967Proxy(address(sfToken), "")));
        sfTokenProxy.initialize();
        // Deploy SFEngine proxy
        SFEngine sfEngineProxy = SFEngine(address(new ERC1967Proxy(address(sfEngine), "")));
        sfEngineProxy.initialize(
            address(sfTokenProxy), 
            deployConfig.aavePoolAddress,
            deployConfig.investmentRatio,
            deployConfig.autoHarvestDuration,
            deployConfig.bonusRate,
            tokenAddresses, 
            priceFeedAddresses
        );
        // Transfer SFToken's ownership to sfEngineProxy
        sfTokenProxy.transferOwnership(address(sfEngineProxy));
        vm.stopBroadcast();
        return (address(sfTokenProxy), address(sfEngineProxy));
    }

    function _deploySFAccountBeacon() private returns (address beaconAddress) {
        DeployHelper.DeployConfig memory deployConfig = deployHelper.getDeployConfig();
        bytes32 salt = _salt();
        vm.startBroadcast(deployConfig.account);
        SFAccount sfAccount = new SFAccount{salt: salt}();
        UpgradeableBeacon beacon = new UpgradeableBeacon{salt: salt}(address(sfAccount), deployConfig.account);
        vm.stopBroadcast();
        return address(beacon);
    }

    function _deployAccountFactory(address sfEngine, address beacon) private returns (address accountFactoryAddress) {
        DeployHelper.DeployConfig memory deployConfig = deployHelper.getDeployConfig();
        bytes32 salt = _salt();
        vm.startBroadcast(deployConfig.account);
        SFAccountFactory factory = new SFAccountFactory{salt: salt}();
        SFAccountFactory factoryProxy = SFAccountFactory(address(new ERC1967Proxy{salt: salt}(address(factory), "")));
        factoryProxy.initialize(
            deployConfig.entryPointAddress, 
            sfEngine, 
            beacon, 
            deployConfig.maxUserAccount,
            deployConfig.vaultConfig, 
            deployConfig.recoveryConfig
        );
        vm.stopBroadcast();
        return address(factoryProxy);
    }

    function _saveDeployment(
        address sfTokenAddress, 
        address sfEngineAddress,
        address sfAccountFactoryAddress,
        address sfAccountBeaconAddress
    ) private {
        names = ["SFToken", "SFEngine", "SFAccountBeacon", "SFAccountFactory"];
        deployments = [sfTokenAddress, sfEngineAddress, sfAccountBeaconAddress, sfAccountFactoryAddress];
        devOps.saveDeployment(names, deployments);
    }

    function _salt() private view returns (bytes32) {
        DeployHelper.DeployConfig memory deployConfig = deployHelper.getDeployConfig();
        return keccak256(abi.encode(deployConfig.account, block.timestamp));
    }
}
