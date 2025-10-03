// SPDX-License-Identifier: MIT
pragma solidity ^0.8.30;

import {Test} from "forge-std/Test.sol";
import {IVaultPlugin} from "../../src/interfaces/IVaultPlugin.sol";
import {ISocialRecoveryPlugin} from "../../src/interfaces/ISocialRecoveryPlugin.sol";
import {SFEngine} from "../../src/token/SFEngine.sol";
import {SFAccount} from "../../src/account/SFAccount.sol";
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
import {OracleLib, AggregatorV3Interface} from "../../src/libraries/OracleLib.sol";
import "../../script/UserOperations.s.sol";

contract SFAccountTest is Test, Constants {

    using OracleLib for AggregatorV3Interface;

    event SFAccount__AccountCreated(address indexed owner);

    struct TestData {
        uint256 forkId;
        DeployHelper.DeployConfig deployConfig;
        SFEngine sfEngine;
        SFToken sfToken;
        SFAccount sfAccount;
        SFAccountFactory sfAccountFactory;
        UpgradeableBeacon sfAccountBeacon;
    }

    uint256 private constant INITIAL_USER_BALANCE = 100 ether;
    uint256 private constant LIQUIDATOR_DEPOSIT_AMOUNT = 1000 ether;
    uint256 private constant DEFAULT_AMOUNT_COLLATERAL = 2 ether;
    uint256 private constant DEFAULT_COLLATERAL_RATIO = 2 * PRECISION_FACTOR;

    address private user = makeAddr("user");
    address private randomUser = makeAddr("randomUser");
    address private walletAccount = vm.rememberKey(0x5de4111afa1a4b94908f83103eb1f1706367c2e68ca870fc3fb9a804cdab365a);
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
        _setUpEthSepolia();
    }

    modifier accountCreated() {
        address sfAccountAddress = _createSFAccount($.deployConfig.account);
        $.sfAccount = SFAccount(sfAccountAddress);
        _;
    }

    modifier deposited() {
        _deposit(
            $.deployConfig.account, 
            address($.sfAccount), 
            $.deployConfig.wethTokenAddress, 
            INITIAL_USER_BALANCE
        );
        _;
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
        weth.transfer(deployConfig.account, INITIAL_USER_BALANCE);
        wbtc.transfer(deployConfig.account, INITIAL_USER_BALANCE);
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
        weth.mint(deployConfig.account, INITIAL_USER_BALANCE);
        vm.stopPrank();
        vm.startPrank(Ownable(sepoliaData.deployConfig.wbtcTokenAddress).owner());
        wbtc.mint(user, INITIAL_USER_BALANCE);
        wbtc.mint(randomUser, INITIAL_USER_BALANCE);
        wbtc.mint(deployConfig.account, INITIAL_USER_BALANCE);
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
        address account = $.deployConfig.account;
        CreateAccount createAccount = new CreateAccount();
        address calculatedAccountAddress = createAccount.calculateAccountAddress(
            address($.sfAccountFactory), 
            address($.sfAccountBeacon), 
            createAccount.getSalt(account)
        );
        IEntryPoint($.deployConfig.entryPointAddress).depositTo{value: 1 ether}(calculatedAccountAddress);
        vm.expectEmit(true, false, false, false);
        emit SFAccount__AccountCreated($.deployConfig.account);
        address actualAccountAddress = createAccount.run(
            address(account),
            address($.deployConfig.entryPointAddress),
            address($.sfAccountFactory), 
            address($.sfAccountBeacon)
        );
        address[] memory storedSfAccounts = $.sfAccountFactory.getUserAccounts(account);
        assertEq(calculatedAccountAddress, actualAccountAddress);
        assertEq(storedSfAccounts.length, 1);
        assertEq(storedSfAccounts[0], actualAccountAddress);
    }

    function testUpdateCustomVaultConfig() public localTest accountCreated {
        bool autoTopUpEnabled = false;
        uint256 collateralRatio = 4 * PRECISION_FACTOR;
        uint256 autoTopUpThreshold = collateralRatio;
        IVaultPlugin.CustomVaultConfig memory config = $.sfAccount.getCustomVaultConfig();
        config.autoTopUpEnabled = autoTopUpEnabled;
        config.collateralRatio = collateralRatio;
        config.autoTopUpThreshold = autoTopUpThreshold;
        UpdateCustomVaultConfig updateCustomVaultConfig = new UpdateCustomVaultConfig();
        updateCustomVaultConfig.run(
            address($.sfAccountFactory),
            $.deployConfig.entryPointAddress,
            $.deployConfig.account,
            address($.sfAccount),
            config
        );
        IVaultPlugin.CustomVaultConfig memory updatedConfig = $.sfAccount.getCustomVaultConfig();
        assertEq(updatedConfig.autoTopUpEnabled, autoTopUpEnabled);
        assertEq(updatedConfig.collateralRatio, collateralRatio);
        assertEq(updatedConfig.autoTopUpThreshold, autoTopUpThreshold);
    }

    function testDepositToSFAccount() public localTest accountCreated {
        address collateral = $.deployConfig.wethTokenAddress;
        address account = $.deployConfig.account;
        address sfAccount = address($.sfAccount);
        uint256 amountToDeposit = 1 * PRECISION_FACTOR;
        uint256 startingCollateralBalance = $.sfAccount.getCollateralBalance(collateral);
        uint256 startingUserBalance = IERC20(collateral).balanceOf(account);
        uint256 startingSFAccountBalance = IERC20(collateral).balanceOf(sfAccount);
        _deposit(
            account, 
            sfAccount, 
            collateral, 
            amountToDeposit
        );
        assertEq(
            $.sfAccount.getCollateralBalance(collateral), 
            startingCollateralBalance + amountToDeposit
        );
        assertEq(IERC20(collateral).balanceOf(account), startingUserBalance - amountToDeposit);
        assertEq(IERC20(collateral).balanceOf(sfAccount), startingSFAccountBalance + amountToDeposit);
    }

    function testWithdrawFromSFAccount() public localTest accountCreated deposited {
        address collateral = $.deployConfig.wethTokenAddress;
        address account = $.deployConfig.account;
        address sfAccount = address($.sfAccount);
        uint256 amountToWithdraw = 1 * PRECISION_FACTOR;
        uint256 startingCollateralBalance = $.sfAccount.getCollateralBalance(collateral);
        uint256 startingUserBalance = IERC20(collateral).balanceOf(account);
        uint256 startingSFAccountBalance = IERC20(collateral).balanceOf(sfAccount);
        Withdraw withdraw = new Withdraw();
        withdraw.run(
            address($.sfAccountFactory), 
            $.deployConfig.entryPointAddress,
            account,
            sfAccount,
            collateral,
            amountToWithdraw
        );
        assertEq($.sfAccount.getCollateralBalance(collateral), startingCollateralBalance - amountToWithdraw);
        assertEq(IERC20(collateral).balanceOf(account), startingUserBalance + amountToWithdraw);
        assertEq(IERC20(collateral).balanceOf(sfAccount), startingSFAccountBalance - amountToWithdraw);
    }

    function testInvestToSFProtocol() public ethSepoliaTest accountCreated deposited {
        address weth = $.deployConfig.wethTokenAddress;
        uint256 amountToInvest = 2 * PRECISION_FACTOR;
        uint256 collateralRatio = $.sfAccount.getCustomCollateralRatio();
        uint256 amountSFToMint = $.sfEngine.calculateSFTokensByCollateral(weth, amountToInvest, collateralRatio);
        uint256 amountSuppliedToAave = amountToInvest * $.sfEngine.getInvestmentRatio() / PRECISION_FACTOR;
        uint256 startingAccountSFBalance = $.sfAccount.balance();
        uint256 startingAccountWethBalance = IERC20(weth).balanceOf(address($.sfAccount));
        uint256 startingEngineWethBalance = IERC20(weth).balanceOf(address($.sfEngine));
        Invest invest = new Invest();
        invest.run(
            address($.sfAccountFactory), 
            $.deployConfig.entryPointAddress,
            $.deployConfig.account,
            address($.sfAccount),
            weth,
            amountToInvest
        );
        assertEq($.sfAccount.balance(), startingAccountSFBalance + amountSFToMint);
        assertEq(
            IERC20(weth).balanceOf(address($.sfAccount)), 
            startingAccountWethBalance - amountToInvest
        );
        assertEq(
            IERC20(weth).balanceOf(address($.sfEngine)), 
            startingEngineWethBalance + amountToInvest - amountSuppliedToAave
        );
    }

    function testTransfer() public localTest accountCreated deposited {
        Transfer transfer = new Transfer();
        SFAccount sender = $.sfAccount;
        SFAccount receiver = SFAccount(_createSFAccount(walletAccount));


        uint256 amountToTransfer = 2 * PRECISION_FACTOR;
        uint256 startingSenderBalance = sender.balance();
        uint256 startingReceiverBalance = receiver.balance();
        transfer.run(
            address($.sfAccountFactory), 
            $.deployConfig.entryPointAddress,
            $.deployConfig.account,
            address(sender),
            address(receiver),
            amountToTransfer
        );
        assertEq(sender.balance(), startingSenderBalance - amountToTransfer);
        assertEq(receiver.balance(), startingReceiverBalance + amountToTransfer);
    }

    function _createSFAccount(address account) private returns (address) {
        CreateAccount createAccount = new CreateAccount();
        address calculatedAccountAddress = createAccount.calculateAccountAddress(
            address($.sfAccountFactory), 
            address($.sfAccountBeacon), 
            createAccount.getSalt(account)
        );
        IEntryPoint($.deployConfig.entryPointAddress).depositTo{value: 1 ether}(calculatedAccountAddress);
        return createAccount.run(
            account,
            address($.deployConfig.entryPointAddress),
            address($.sfAccountFactory), 
            address($.sfAccountBeacon)
        );
    }

    function _deposit(address account, address sfAccount, address collateral, uint256 amount) private {
        vm.prank(account);
        IERC20(collateral).approve(sfAccount, amount);
        Deposit deposit = new Deposit();
        deposit.run(
            address($.sfAccountFactory), 
            address($.deployConfig.entryPointAddress),
            account,
            sfAccount,
            collateral,
            amount
        );
    }
}