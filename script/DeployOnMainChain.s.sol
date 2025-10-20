// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {SFEngine} from "../src/token/SFEngine.sol";
import {SFToken} from "../src/token/SFToken.sol";
import {SFTokenPool} from "../src/token/SFTokenPool.sol";
import {SFBridge} from "../src/bridge/SFBridge.sol";
import {SFAccount} from "../src/account/SFAccount.sol";
import {SFAccountFactory} from "../src/account/SFAccountFactory.sol";
import {DeployHelper} from "./util/DeployHelper.sol";
import {ConfigHelper} from "./util/ConfigHelper.sol";
import {Script} from "forge-std/Script.sol";
import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";
import {UpgradeableBeacon} from "@openzeppelin/contracts/proxy/beacon/UpgradeableBeacon.sol";
import {BaseDeployment} from "./BaseDeployment.s.sol";
import {Register} from "@chainlink/local/src/ccip/CCIPLocalSimulatorFork.sol";

contract DeployOnMainChain is BaseDeployment {

    error DeployOnMainChain__NotOnMainChain();

    function run() external {
        if (block.chainid != chainConfig.mainChainId) {
            revert DeployOnMainChain__NotOnMainChain();
        }
        deploy();
    }

    function deploy() public returns (
        address sfTokenAddress, 
        address sfEngineAddress,
        address sfTokenPoolAddress,
        address sfBridgeAddress,
        address sfAccountFactoryAddress,
        address sfAccountBeaconAddress,
        DeployHelper.DeployConfig memory deployConfig
    ) {
        deployConfig = deployHelper.getDeployConfig();
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

    function _deploySFTokenAndPoolAndEngine() private returns (
        address sfTokenAddress, 
        address sfEngineAddress,
        address sfTokenPoolAddress
    ) {
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
        // Deploy token pool
        Register.NetworkDetails memory networkDetails = register.getNetworkDetails(block.chainid);
        SFTokenPool sfTokenPool = new SFTokenPool(
            chainConfig.mainChainId,
            sfTokenProxy,
            new address[](0),
            networkDetails.rmnProxyAddress,
            networkDetails.routerAddress
        );
        // Grant minter role to SF Engine and SF token pool
        sfTokenProxy.addMinter(address(sfEngineProxy));
        sfTokenProxy.addMinter(address(sfTokenPool));
        vm.stopBroadcast();
        return (address(sfTokenProxy), address(sfEngineProxy), address(sfTokenPool));
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
            deployConfig.automationRegistrarAddress,
            deployConfig.linkTokenAddress,
            deployConfig.vaultConfig, 
            deployConfig.recoveryConfig
        );
        vm.stopBroadcast();
        return address(factoryProxy);
    }

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

    function _salt() private view returns (bytes32) {
        DeployHelper.DeployConfig memory deployConfig = deployHelper.getDeployConfig();
        return keccak256(abi.encode(deployConfig.account, block.timestamp));
    }
}
