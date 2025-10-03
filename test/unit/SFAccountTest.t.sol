// SPDX-License-Identifier: MIT
pragma solidity ^0.8.30;

import {Test} from "forge-std/Test.sol";
import {SFEngine} from "../../src/token/SFEngine.sol";
import {SFAccountFactory} from "../../src/account/SFAccountFactory.sol";
import {SFToken} from "../../src/token/SFToken.sol";
import {DeployHelper} from "../../script/util/DeployHelper.sol";
import {Deploy} from "../../script/Deploy.s.sol";
import {Constants} from "../../script/util/Constants.sol";
import {ERC20Mock} from "../../test/mocks/ERC20Mock.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {UpgradeableBeacon} from "@openzeppelin/contracts/proxy/beacon/UpgradeableBeacon.sol";
import {IPool} from "@aave/contracts/interfaces/IPool.sol";
import {Ownable} from "@aave/contracts/dependencies/openzeppelin/contracts/Ownable.sol";
import {IEntryPoint} from "account-abstraction/contracts/interfaces/IEntryPoint.sol";
import "../../script/UserOperations.s.sol";

contract SFAccountTest is Test, Constants {

    event SFAccount__AccountCreated(address indexed owner);

    struct TestData {
        uint256 forkId;
        DeployHelper.DeployConfig deployConfig;
        SFEngine sfEngine;
        SFToken sfToken;
        SFAccountFactory sfAccountFactory;
        UpgradeableBeacon sfAccountBeacon;
    }

    uint256 private constant INITIAL_USER_BALANCE = 100 ether;
    uint256 private constant LIQUIDATOR_DEPOSIT_AMOUNT = 1000 ether;
    uint256 private constant DEFAULT_AMOUNT_COLLATERAL = 2 ether;
    uint256 private constant DEFAULT_COLLATERAL_RATIO = 2 * PRECISION_FACTOR;

    address private user = makeAddr("user");
    address private randomUser = makeAddr("randomUser");
    TestData private localData;
    TestData private sepoliaData;
    TestData private $; // Current active test data

    modifier localTest() {
        $ = localData;
        vm.selectFork($.forkId);
        _;
    }

    modifier ethSepoliaTest() {
        $ = sepoliaData;
        vm.selectFork($.forkId);
        _;
    }

    function setUp() external {
        _setUpLocal();
        // _setUpEthSepolia();
    }

    function _setUpLocal() private {
        localData.forkId = vm.createSelectFork("local");
        Deploy deployer = new Deploy();
        (
            address sfTokenAddress, 
            address sfEngineAddress, 
            address sfAccountFactoryAddress,
            address sfAccountBeaconAddress,
            DeployHelper.DeployConfig memory deployConfig
        ) = deployer.deploy();
        localData.sfEngine = SFEngine(sfEngineAddress);
        localData.sfToken = SFToken(sfTokenAddress);
        localData.sfAccountFactory = SFAccountFactory(sfAccountFactoryAddress);
        localData.sfAccountBeacon = UpgradeableBeacon(sfAccountBeaconAddress);
        localData.deployConfig = deployConfig;
        IERC20 weth = IERC20(localData.deployConfig.wethTokenAddress);
        IERC20 wbtc = IERC20(localData.deployConfig.wbtcTokenAddress);
        vm.startPrank(address(deployer));
        weth.transfer(user, INITIAL_USER_BALANCE);
        wbtc.transfer(user, INITIAL_USER_BALANCE);
        weth.transfer(randomUser, INITIAL_USER_BALANCE);
        wbtc.transfer(randomUser, INITIAL_USER_BALANCE);
        vm.stopPrank();
        vm.deal(localData.deployConfig.account, INITIAL_BALANCE);
    }

    function _setUpEthSepolia() private {
        sepoliaData.forkId = vm.createSelectFork("ethSepolia");
        Deploy deployer = new Deploy();
        (
            address sfTokenAddress, 
            address sfEngineAddress, 
            address sfAccountFactoryAddress,
            address sfAccountBeaconAddress,
            DeployHelper.DeployConfig memory deployConfig
        ) = deployer.deploy();
        sepoliaData.sfEngine = SFEngine(sfEngineAddress);
        sepoliaData.sfToken = SFToken(sfTokenAddress);
        sepoliaData.sfAccountFactory = SFAccountFactory(sfAccountFactoryAddress);
        sepoliaData.sfAccountBeacon = UpgradeableBeacon(sfAccountBeaconAddress);
        sepoliaData.deployConfig = deployConfig;
        ERC20Mock weth = ERC20Mock(sepoliaData.deployConfig.wethTokenAddress);
        ERC20Mock wbtc = ERC20Mock(sepoliaData.deployConfig.wbtcTokenAddress);
        vm.startPrank(Ownable(sepoliaData.deployConfig.wethTokenAddress).owner());
        weth.mint(user, INITIAL_USER_BALANCE);
        weth.mint(randomUser, INITIAL_USER_BALANCE);
        vm.stopPrank();
        vm.startPrank(Ownable(sepoliaData.deployConfig.wbtcTokenAddress).owner());
        wbtc.mint(user, INITIAL_USER_BALANCE);
        wbtc.mint(randomUser, INITIAL_USER_BALANCE);
        vm.stopPrank();
        // Let random user directly supply some weth and wbtc to aave
        vm.startPrank(randomUser);
        weth.approve(deployConfig.aavePoolAddress, INITIAL_USER_BALANCE);
        IPool(deployConfig.aavePoolAddress).supply(
            sepoliaData.deployConfig.wethTokenAddress, 
            INITIAL_USER_BALANCE, 
            randomUser, 
            0
        );
        wbtc.approve(deployConfig.aavePoolAddress, INITIAL_USER_BALANCE);
        IPool(deployConfig.aavePoolAddress).supply(
            sepoliaData.deployConfig.wbtcTokenAddress, 
            INITIAL_USER_BALANCE, 
            randomUser, 
            0
        );
        vm.stopPrank();
        vm.deal(localData.deployConfig.account, INITIAL_BALANCE);
    }

    function testCreateAccount() public localTest {
        CreateAccount createAccount = new CreateAccount();
        address calculatedAccountAddress = createAccount.calculateAccountAddress(
            address($.sfAccountFactory), 
            address($.sfAccountBeacon), 
            createAccount.getSalt($.deployConfig.account)
        );
        IEntryPoint($.deployConfig.entryPointAddress).depositTo{value: 1 ether}(calculatedAccountAddress);
        vm.expectEmit(true, false, false, false);
        emit SFAccount__AccountCreated($.deployConfig.account);
        address actualAccountAddress = createAccount.createAccount(
            address($.deployConfig.account),
            address($.deployConfig.entryPointAddress),
            address($.sfAccountFactory), 
            address($.sfAccountBeacon)
        );
        assertEq(calculatedAccountAddress, actualAccountAddress);
    }

    
}