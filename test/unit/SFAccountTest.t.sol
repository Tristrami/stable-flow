// SPDX-License-Identifier: MIT
pragma solidity ^0.8.30;

import {Vm} from "forge-std/Vm.sol";
import {Test, console2} from "forge-std/Test.sol";
import {IFreezePlugin} from "../../src/interfaces/IFreezePlugin.sol";
import {IVaultPlugin} from "../../src/interfaces/IVaultPlugin.sol";
import {ISocialRecoveryPlugin} from "../../src/interfaces/ISocialRecoveryPlugin.sol";
import {BaseSFAccountPlugin} from "../../src/account/plugins/BaseSFAccountPlugin.sol";
import {SFEngine} from "../../src/token/SFEngine.sol";
import {SFAccount} from "../../src/account/SFAccount.sol";
import {SFAccountFactory} from "../../src/account/SFAccountFactory.sol";
import {SFToken} from "../../src/token/SFToken.sol";
import {DeployHelper} from "../../script/util/DeployHelper.sol";
import {Deploy} from "../../script/Deploy.s.sol";
import {Constants} from "../../script/util/Constants.sol";
import {ERC20Mock} from "../../test/mocks/ERC20Mock.sol";
import {MockV3Aggregator} from "../../test/mocks/MockV3Aggregator.sol";
import {Logs} from "../../script/util/Logs.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {UpgradeableBeacon} from "@openzeppelin/contracts/proxy/beacon/UpgradeableBeacon.sol";
import {IPool} from "@aave/contracts/interfaces/IPool.sol";
import {Ownable} from "@aave/contracts/dependencies/openzeppelin/contracts/Ownable.sol";
import {IEntryPoint} from "account-abstraction/contracts/interfaces/IEntryPoint.sol";
import {OracleLib, AggregatorV3Interface} from "../../src/libraries/OracleLib.sol";
import "../../script/UserOperations.s.sol";

contract SFAccountTest is Test, Constants {

    using OracleLib for AggregatorV3Interface;
    using Logs for Vm;

    /* -------------------------------------------------------------------------- */
    /*                           SFAccountFactory Events                          */
    /* -------------------------------------------------------------------------- */

    event SFAccountFactory__CreateAccount(address indexed account, address indexed owner);

    /* -------------------------------------------------------------------------- */
    /*                              ISFAccount Events                             */
    /* -------------------------------------------------------------------------- */

    event ISFAccount__AccountCreated(address indexed owner);

    /* -------------------------------------------------------------------------- */
    /*                             IVaultPlugin Events                            */
    /* -------------------------------------------------------------------------- */

    event IVaultPlugin__UpdateCollateralAndPriceFeed(uint256 indexed numCollateral);
    event IVaultPlugin__Invest(
        address indexed collateralAddress, 
        uint256 indexed amountCollateral, 
        uint256 indexed sfToMint
    );
    event IVaultPlugin__Harvest(
        address indexed collateralAddress, 
        uint256 indexed amountCollateralToRedeem, 
        uint256 indexed debtToRepay
    );
    event IVaultPlugin__Liquidate(
        address indexed account, 
        address indexed collateralAddress, 
        uint256 indexed debtToCover
    );
    event IVaultPlugin__Danger(
        uint256 indexed currentCollateralRatio, 
        uint256 indexed liquidatingCollateralRatio
    );
    event IVaultPlugin__TopUpCollateral(
        address indexed collateralAddress, 
        uint256 indexed amountCollateral
    );
    event IVaultPlugin__CollateralRatioMaintained(
        uint256 indexed collateralTopedUpInUsd, 
        uint256 indexed targetCollateralRatio
    );
    event IVaultPlugin__InsufficientCollateralForTopUp(
        uint256 indexed requiredCollateralInUsd, 
        uint256 indexed currentCollateralRatio, 
        uint256 indexed targetCollateralRatio
    );
    event IVaultPlugin__Deposit(address indexed collateralAddress, uint256 indexed amount);
    event IVaultPlugin__Withdraw(address indexed collateralAddress, uint256 indexed amount);
    event IVaultPlugin__AddNewCollateral(address indexed collateralAddress);
    event IVaultPlugin__RemoveCollateral(address indexed collateralAddress);
    event IVaultPlugin__UpdateVaultConfig(bytes configData);
    event IVaultPlugin__UpdateCustomVaultConfig(bytes configData);

    /* -------------------------------------------------------------------------- */
    /*                        ISocialRecoveryPlugin Events                        */
    /* -------------------------------------------------------------------------- */

    event ISocialRecoveryPlugin__UpdateRecoveryConfig(bytes configData);
    event ISocialRecoveryPlugin__UpdateCustomRecoveryConfig(bytes configData);
    event ISocialRecoveryPlugin__UpdateGuardians(uint256 numGuardians);
    event ISocialRecoveryPlugin__RecoveryInitiated(
        address indexed initiator, 
        address indexed newOwner
    );
    event ISocialRecoveryPlugin__RecoveryApproved(address indexed guardian);
    event ISocialRecoveryPlugin__RecoveryCancelled(
        address indexed guardian, 
        bytes recordData
    );
    event ISocialRecoveryPlugin__RecoveryCompleted(
        address indexed previousOwner, 
        address indexed newOwner, 
        bytes recordData
    );

    /* -------------------------------------------------------------------------- */
    /*                                    Types                                   */
    /* -------------------------------------------------------------------------- */

    struct TestData {
        uint256 forkId;
        DeployHelper.DeployConfig deployConfig;
        SFEngine sfEngine;
        SFToken sfToken;
        SFAccount sfAccount;
        SFAccountFactory sfAccountFactory;
        UpgradeableBeacon sfAccountBeacon;
    }

    /* -------------------------------------------------------------------------- */
    /*                                  Constants                                 */
    /* -------------------------------------------------------------------------- */

    uint256 private constant INITIAL_USER_BALANCE = 100 ether;
    uint256 private constant INVEST_AMOUNT = 10 ether;
    uint256 private constant LIQUIDATOR_DEPOSIT_AMOUNT = 1000 ether;
    uint256 private constant DEFAULT_AMOUNT_COLLATERAL = 2 ether;
    uint256 private constant DEFAULT_COLLATERAL_RATIO = 2 * PRECISION_FACTOR;

    /* -------------------------------------------------------------------------- */
    /*                               State Variables                              */
    /* -------------------------------------------------------------------------- */

    address private user = vm.rememberKey(0x59c6995e998f97a5a0044966f0945389dc9e86dae88c7a8412f4603b6b78690d);
    address private guardian1 = vm.rememberKey(0x2a871d0798f97d79848a013d4936a73bf4cc922c825d33c1cf7073dff6d409c6);
    address private guardian2 = vm.rememberKey(0xdbda1821b80551c9d65939329250298aa3472ba22feea921c0cf5d620ea67b97);
    address private guardian3 = vm.rememberKey(0x4bbbf85ce3377467afe5d46f804f221813b2bb87f24d81f60f1fcdbf7cbf4356);
    TestData private localData;
    TestData private sepoliaData;
    TestData private $; // Current active test data
    address[] private guardians;

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

    modifier invested() {
        _invest(
            $.deployConfig.account, 
            address($.sfAccount), 
            $.deployConfig.wethTokenAddress, 
            INVEST_AMOUNT
        );
        _;
    }

    modifier recoveryConfigured() {
        _configureRecovery();
        _;
    }

    modifier recoveryInitiated() {
        _initiateRecovery(
            guardian1,
            guardians[0],
            address($.sfAccount),
            user
        );
        _;
    }

    function setUp() external {
        _setUpLocal();
        _setUpEthSepolia();
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
        weth.transfer(user, INITIAL_USER_BALANCE);
        wbtc.transfer(user, INITIAL_USER_BALANCE);
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
        weth.mint(user, 2 * INITIAL_USER_BALANCE);
        weth.mint(deployConfig.account, INITIAL_USER_BALANCE);
        vm.stopPrank();
        vm.startPrank(Ownable(sepoliaData.deployConfig.wbtcTokenAddress).owner());
        wbtc.mint(user, INITIAL_USER_BALANCE);
        wbtc.mint(user, 2 * INITIAL_USER_BALANCE);
        wbtc.mint(deployConfig.account, INITIAL_USER_BALANCE);
        vm.stopPrank();
        // Let random user directly supply some weth and wbtc to aave
        vm.startPrank(user);
        weth.approve(deployConfig.aavePoolAddress, INITIAL_USER_BALANCE);
        IPool(deployConfig.aavePoolAddress).supply(
            sepoliaData.deployConfig.wethTokenAddress, 
            INITIAL_USER_BALANCE, 
            user, 
            0
        );
        wbtc.approve(deployConfig.aavePoolAddress, INITIAL_USER_BALANCE);
        IPool(deployConfig.aavePoolAddress).supply(
            sepoliaData.deployConfig.wbtcTokenAddress, 
            INITIAL_USER_BALANCE, 
            user, 
            0
        );
        vm.stopPrank();
        vm.deal(localData.deployConfig.account, INITIAL_BALANCE);
    }

    /* -------------------------------------------------------------------------- */
    /*                              Create SF Account                             */
    /* -------------------------------------------------------------------------- */

    function test_RevertWhen_InitializeSFAccountFactoryWithZeroMaxAccountAmount() localTest public {
        SFAccountFactory factory = new SFAccountFactory();
        vm.expectRevert(SFAccountFactory.SFAccountFactory__MaxAccountAmountCanNotBeZero.selector);
        factory.initialize(
            $.deployConfig.entryPointAddress,
            address($.sfEngine),
            address($.sfAccountBeacon), 
            0, 
            IVaultPlugin.VaultConfig({
                collaterals: new address[](0),
                priceFeeds: new address[](0)
            }), 
            ISocialRecoveryPlugin.RecoveryConfig({
                maxGuardians: 5
            })
        );
    }

    function test_RevertWhen_ReinitializeSFAccountFactoryWithZeroMaxAccountAmount() localTest public {
        SFAccountFactory factory = new SFAccountFactory();
        factory.initialize(
            $.deployConfig.entryPointAddress,
            address($.sfEngine),
            address($.sfAccountBeacon), 
            5, 
            IVaultPlugin.VaultConfig({
                collaterals: new address[](0),
                priceFeeds: new address[](0)
            }), 
            ISocialRecoveryPlugin.RecoveryConfig({
                maxGuardians: 5
            })
        );
        vm.expectRevert(SFAccountFactory.SFAccountFactory__MaxAccountAmountCanNotBeZero.selector);
        factory.reinitialize(
            2,
            0, 
            IVaultPlugin.VaultConfig({
                collaterals: new address[](0),
                priceFeeds: new address[](0)
            }), 
            ISocialRecoveryPlugin.RecoveryConfig({
                maxGuardians: 5
            })
        );
    }

    function test_RevertWhen_AccountAmountExceedsMaxAmount() localTest public {
        address owner = $.deployConfig.account;
        uint256 maxAccountAmount = $.sfAccountFactory.getMaxAccountAmount();
        IVaultPlugin.CustomVaultConfig memory vaultConfig = IVaultPlugin.CustomVaultConfig({
            autoTopUpEnabled: false,
            autoTopUpThreshold: 0,
            collateralRatio: 2 * PRECISION_FACTOR
        });
        ISocialRecoveryPlugin.CustomRecoveryConfig memory recoveryConfig = ISocialRecoveryPlugin.CustomRecoveryConfig({
            guardians: new address[](0),
            minGuardianApprovals: 0,
            recoveryTimeLock: 0,
            socialRecoveryEnabled: false
        });
        for (uint256 i = 0; i < maxAccountAmount; i++) {
            $.sfAccountFactory.createSFAccount(owner, $.sfAccountFactory.getSFAccountSalt(owner), vaultConfig, recoveryConfig);
        }
        bytes32 salt = $.sfAccountFactory.getSFAccountSalt(owner);
        vm.expectRevert(
            abi.encodeWithSelector(
                SFAccountFactory.SFAccountFactory__AccountLimitReached.selector, 
                maxAccountAmount
            )
        );
        $.sfAccountFactory.createSFAccount(owner, salt, vaultConfig, recoveryConfig);
    }

    function testCreateAccount() public localTest {
        address owner = $.deployConfig.account;
        address calculatedAccountAddress = $.sfAccountFactory.calculateAccountAddress(
            address($.sfAccountBeacon), 
            $.sfAccountFactory.getSFAccountSalt(owner)
        );
        CreateAccount createAccount = new CreateAccount();
        vm.deal(owner, owner.balance + 1 ether);
        vm.prank(owner);
        IEntryPoint($.deployConfig.entryPointAddress).depositTo{value: 1 ether}(calculatedAccountAddress);
        vm.expectEmit(true, true, false, false);
        emit SFAccountFactory__CreateAccount(calculatedAccountAddress, owner);
        vm.expectEmit(true, false, false, false);
        emit ISFAccount__AccountCreated(owner);
        createAccount.run(
            owner,
            address($.deployConfig.entryPointAddress),
            address($.sfAccountFactory), 
            address($.sfAccountBeacon)
        );
        address[] memory storedSfAccounts = $.sfAccountFactory.getUserAccounts(owner);
        assertEq(storedSfAccounts.length, 1);
        assertEq(storedSfAccounts[0], calculatedAccountAddress);
    }

    /* -------------------------------------------------------------------------- */
    /*                         Update Custom Vault Config                         */
    /* -------------------------------------------------------------------------- */

    function test_RevertWhen_TopUpThresholdLessThanMinCollateralRatio() public localTest accountCreated {
        uint256 autoTopUpThreshold = 1 * PRECISION_FACTOR;
        IVaultPlugin.CustomVaultConfig memory customConfig = IVaultPlugin.CustomVaultConfig({
            autoTopUpEnabled: true,
            autoTopUpThreshold: autoTopUpThreshold,
            collateralRatio: 2 * PRECISION_FACTOR
        });
        vm.expectRevert(
            abi.encodeWithSelector(
                IVaultPlugin.IVaultPlugin__TopUpThresholdTooSmall.selector, 
                autoTopUpThreshold, 
                $.sfEngine.getMinimumCollateralRatio()
            )
        );
        vm.prank($.deployConfig.entryPointAddress);
        $.sfAccount.updateCustomVaultConfig(customConfig);
    }

    function test_RevertWhen_CustomCollateralRatioLessThanMinCollateralRatio() public localTest accountCreated {
        uint256 collateralRatio = 1 * PRECISION_FACTOR;
        IVaultPlugin.CustomVaultConfig memory customConfig = IVaultPlugin.CustomVaultConfig({
            autoTopUpEnabled: true,
            autoTopUpThreshold: 2 * PRECISION_FACTOR,
            collateralRatio: collateralRatio
        });
        vm.expectRevert(
            abi.encodeWithSelector(
                IVaultPlugin.IVaultPlugin__CustomCollateralRatioTooSmall.selector, 
                collateralRatio, 
                $.sfEngine.getMinimumCollateralRatio()
            )
        );
        vm.prank($.deployConfig.entryPointAddress);
        $.sfAccount.updateCustomVaultConfig(customConfig);
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

    /* -------------------------------------------------------------------------- */
    /*                            Deposit to SF Account                           */
    /* -------------------------------------------------------------------------- */

    function test_Deposit_RevertWhen_NotFromEntryPoint() public localTest accountCreated {
        vm.expectRevert(abi.encode("account: not from EntryPoint"));
        $.sfAccount.deposit($.deployConfig.wethTokenAddress, 1 * PRECISION_FACTOR);
    }

    function test_Deposit_RevertWhen_AccountIsFrozen() public localTest accountCreated {
        vm.startPrank($.deployConfig.entryPointAddress);
        $.sfAccount.freeze();
        vm.expectRevert(IFreezePlugin.IFreezePlugin__AccountIsFrozen.selector);
        $.sfAccount.deposit($.deployConfig.wethTokenAddress, 1 * PRECISION_FACTOR);
        vm.stopPrank();
    }

    function test_Deposit_RevertWhen_CollateralAddressIsZero() public localTest accountCreated {
        vm.expectRevert(
            abi.encodeWithSelector(
                IVaultPlugin.IVaultPlugin__CollateralNotSupported.selector,
                address(0)
            )
        );
        vm.prank($.deployConfig.entryPointAddress);
        $.sfAccount.deposit(address(0), 1 * PRECISION_FACTOR);
    }

    function test_Deposit_RevertWhen_AmountToDepositIsZero() public localTest accountCreated {
        vm.expectRevert(IVaultPlugin.IVaultPlugin__TokenAmountCanNotBeZero.selector);
        vm.prank($.deployConfig.entryPointAddress);
        $.sfAccount.deposit($.deployConfig.wethTokenAddress, 0);
    }

    function test_Deposit_RevertWhen_CollateralNotSupported() public localTest accountCreated {
        address collateral = address(new ERC20Mock("test", "test", $.deployConfig.account, 1 ether));
        vm.expectRevert(
            abi.encodeWithSelector(
                IVaultPlugin.IVaultPlugin__CollateralNotSupported.selector,
                collateral
            )
        );
        vm.prank($.deployConfig.entryPointAddress);
        $.sfAccount.deposit(collateral, 1 * PRECISION_FACTOR);
    }

    function test_Deposit_DepositToAccount() public localTest accountCreated {
        address collateral = $.deployConfig.wethTokenAddress;
        address account = $.deployConfig.account;
        address sfAccount = address($.sfAccount);
        uint256 amountToDeposit = 1 * PRECISION_FACTOR;
        uint256 startingCollateralBalance = $.sfAccount.getCollateralBalance(collateral);
        uint256 startingUserBalance = IERC20(collateral).balanceOf(account);
        uint256 startingSFAccountBalance = IERC20(collateral).balanceOf(sfAccount);

        vm.prank(account);
        IERC20(collateral).approve(sfAccount, amountToDeposit);
        Deposit deposit = new Deposit();

        vm.expectEmit(true, false, false, false);
        emit IVaultPlugin__AddNewCollateral(collateral);
        vm.expectEmit(true, true, false, false);
        emit IVaultPlugin__Deposit(collateral, amountToDeposit);

        deposit.run(
            address($.sfAccountFactory), 
            address($.deployConfig.entryPointAddress),
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

    /* -------------------------------------------------------------------------- */
    /*                          Withdraw from SF Account                          */
    /* -------------------------------------------------------------------------- */

    function test_Withdraw_RevertWhen_NotFromEntryPoint() public localTest accountCreated {
        vm.expectRevert(abi.encode("account: not from EntryPoint"));
        $.sfAccount.withdraw($.deployConfig.wethTokenAddress, 1 * PRECISION_FACTOR);
    }

    function test_Withdraw_RevertWhen_AccountIsFrozen() public localTest accountCreated {
        vm.startPrank($.deployConfig.entryPointAddress);
        $.sfAccount.freeze();
        vm.expectRevert(IFreezePlugin.IFreezePlugin__AccountIsFrozen.selector);
        $.sfAccount.withdraw($.deployConfig.wethTokenAddress, 1 * PRECISION_FACTOR);
        vm.stopPrank();
    }

    function test_Withdraw_RevertWhen_CollateralAddressIsZero() public localTest accountCreated {
        vm.expectRevert(
            abi.encodeWithSelector(
                IVaultPlugin.IVaultPlugin__CollateralNotSupported.selector,
                address(0)
            )
        );
        vm.prank($.deployConfig.entryPointAddress);
        $.sfAccount.withdraw(address(0), 1 * PRECISION_FACTOR);
    }

    function test_Withdraw_RevertWhen_AmountToWithdrawIsZero() public localTest accountCreated {
        vm.expectRevert(IVaultPlugin.IVaultPlugin__TokenAmountCanNotBeZero.selector);
        vm.prank($.deployConfig.entryPointAddress);
        $.sfAccount.withdraw($.deployConfig.wethTokenAddress, 0);
    }

    function test_Withdraw_RevertWhen_CollateralNotSupported() public localTest accountCreated {
        address collateral = address(new ERC20Mock("test", "test", $.deployConfig.account, 1 ether));
        vm.expectRevert(
            abi.encodeWithSelector(
                IVaultPlugin.IVaultPlugin__CollateralNotSupported.selector,
                collateral
            )
        );
        vm.prank($.deployConfig.entryPointAddress);
        $.sfAccount.withdraw(collateral, 1 * PRECISION_FACTOR);
    }

    function test_Withdraw_RevertWhen_AmountGreaterThanBalance() public localTest accountCreated {
        uint256 amountToDeposit = 1 * PRECISION_FACTOR;
        uint256 amountToWithdraw = amountToDeposit + 1 * PRECISION_FACTOR;
        address collateral = $.deployConfig.wethTokenAddress;
        vm.prank($.sfAccount.owner());
        IERC20(collateral).approve(address($.sfAccount), amountToDeposit);
        vm.startPrank($.deployConfig.entryPointAddress);
        $.sfAccount.deposit(collateral, amountToDeposit);
        vm.expectRevert(
            abi.encodeWithSelector(
                IVaultPlugin.IVaultPlugin__InsufficientCollateral.selector,
                $.sfAccount.owner(),
                collateral,
                $.sfAccount.getCollateralBalance(collateral),
                amountToWithdraw
            )
        );
        $.sfAccount.withdraw(collateral, amountToWithdraw);
        vm.stopPrank();
    }

    function test_Withdraw_WithdrawFromAccount() public localTest accountCreated deposited {
        // amount to withdraw is equal to amount deposited
        uint256 amountToWithdraw = 1 * PRECISION_FACTOR;
        address collateral = $.deployConfig.wethTokenAddress;
        address account = $.deployConfig.account;
        address sfAccount = address($.sfAccount);
        uint256 startingCollateralBalance = $.sfAccount.getCollateralBalance(collateral);
        uint256 startingUserBalance = IERC20(collateral).balanceOf(account);
        uint256 startingSFAccountBalance = IERC20(collateral).balanceOf(sfAccount);
        Withdraw withdraw = new Withdraw();

        vm.expectEmit(true, true, false, false);
        emit IVaultPlugin__Withdraw(collateral, amountToWithdraw);

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

    function test_Withdraw_WithdrawAllCollaterals() public localTest accountCreated deposited {
        // amount to withdraw is equal to amount deposited
        uint256 amountToWithdraw = INITIAL_USER_BALANCE;
        address collateral = $.deployConfig.wethTokenAddress;
        address account = $.deployConfig.account;
        address sfAccount = address($.sfAccount);
        uint256 startingCollateralBalance = $.sfAccount.getCollateralBalance(collateral);
        uint256 startingUserBalance = IERC20(collateral).balanceOf(account);
        uint256 startingSFAccountBalance = IERC20(collateral).balanceOf(sfAccount);
        Withdraw withdraw = new Withdraw();

        vm.expectEmit(true, false, false, false);
        emit IVaultPlugin__RemoveCollateral(collateral);
        vm.expectEmit(true, true, false, false);
        emit IVaultPlugin__Withdraw(collateral, amountToWithdraw);

        withdraw.run(
            address($.sfAccountFactory), 
            $.deployConfig.entryPointAddress,
            account,
            sfAccount,
            collateral,
            type(uint256).max
        );
        assertEq($.sfAccount.getCollateralBalance(collateral), startingCollateralBalance - amountToWithdraw);
        assertEq(IERC20(collateral).balanceOf(account), startingUserBalance + amountToWithdraw);
        assertEq(IERC20(collateral).balanceOf(sfAccount), startingSFAccountBalance - amountToWithdraw);
    }

    /* -------------------------------------------------------------------------- */
    /*                            Invest to SF Protocol                           */
    /* -------------------------------------------------------------------------- */

    function test_Invest_RevertWhen_NotFromEntryPoint() public localTest accountCreated {
        vm.expectRevert(abi.encode("account: not from EntryPoint"));
        $.sfAccount.invest($.deployConfig.wethTokenAddress, 1 * PRECISION_FACTOR);
    }

    function test_Invest_RevertWhen_AccountIsFrozen() public localTest accountCreated {
        vm.startPrank($.deployConfig.entryPointAddress);
        $.sfAccount.freeze();
        vm.expectRevert(IFreezePlugin.IFreezePlugin__AccountIsFrozen.selector);
        $.sfAccount.invest($.deployConfig.wethTokenAddress, 1 * PRECISION_FACTOR);
        vm.stopPrank();
    }

    function test_Invest_RevertWhen_CollateralAddressIsZero() public localTest accountCreated {
        vm.expectRevert(
            abi.encodeWithSelector(
                IVaultPlugin.IVaultPlugin__CollateralNotSupported.selector,
                address(0)
            )
        );
        vm.prank($.deployConfig.entryPointAddress);
        $.sfAccount.invest(address(0), 1 * PRECISION_FACTOR);
    }

    function test_Invest_RevertWhen_AmountToInvestIsZero() public localTest accountCreated {
        vm.expectRevert(IVaultPlugin.IVaultPlugin__TokenAmountCanNotBeZero.selector);
        vm.prank($.deployConfig.entryPointAddress);
        $.sfAccount.invest($.deployConfig.wethTokenAddress, 0);
    }

    function test_Invest_RevertWhen_CollateralNotSupported() public localTest accountCreated {
        address collateral = address(new ERC20Mock("test", "test", $.deployConfig.account, 1 ether));
        vm.expectRevert(
            abi.encodeWithSelector(
                IVaultPlugin.IVaultPlugin__CollateralNotSupported.selector,
                collateral
            )
        );
        vm.prank($.deployConfig.entryPointAddress);
        $.sfAccount.invest(collateral, 1 * PRECISION_FACTOR);
    }

    function test_Invest_RevertWhen_AmountGreaterThanBalance() public localTest accountCreated {
        uint256 amountToDeposit = 1 * PRECISION_FACTOR;
        uint256 amountToInvest = amountToDeposit + 1 * PRECISION_FACTOR;
        address collateral = $.deployConfig.wethTokenAddress;
        vm.prank($.sfAccount.owner());
        IERC20(collateral).approve(address($.sfAccount), amountToDeposit);
        vm.startPrank($.deployConfig.entryPointAddress);
        $.sfAccount.deposit(collateral, amountToDeposit);
        vm.expectRevert(
            abi.encodeWithSelector(
                IVaultPlugin.IVaultPlugin__InsufficientCollateral.selector,
                address($.sfEngine),
                collateral,
                $.sfAccount.getCollateralBalance(collateral),
                amountToInvest
            )
        );
        $.sfAccount.invest(collateral, amountToInvest);
        vm.stopPrank();
    }

    function test_Invest_InvestCollaterals() public ethSepoliaTest accountCreated deposited {
        address weth = $.deployConfig.wethTokenAddress;
        uint256 amountToInvest = 2 * PRECISION_FACTOR;
        uint256 collateralRatio = $.sfAccount.getCustomCollateralRatio();
        uint256 amountSFToMint = $.sfEngine.calculateSFTokensByCollateral(weth, amountToInvest, collateralRatio);
        uint256 amountSuppliedToAave = amountToInvest * $.sfEngine.getInvestmentRatio() / PRECISION_FACTOR;
        uint256 startingAccountSFBalance = $.sfAccount.balance();
        uint256 startingAccountWethBalance = IERC20(weth).balanceOf(address($.sfAccount));
        uint256 startingEngineWethBalance = IERC20(weth).balanceOf(address($.sfEngine));
        Invest invest = new Invest();

        vm.expectEmit(true, true, true, false);
        emit IVaultPlugin__Invest(weth, amountToInvest, amountSFToMint);

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

    function test_Invest_InvestAllCollaterals() public ethSepoliaTest accountCreated deposited {
        address weth = $.deployConfig.wethTokenAddress;
        uint256 amountToInvest = INITIAL_USER_BALANCE;
        uint256 collateralRatio = $.sfAccount.getCustomCollateralRatio();
        uint256 amountSFToMint = $.sfEngine.calculateSFTokensByCollateral(weth, amountToInvest, collateralRatio);
        uint256 amountSuppliedToAave = amountToInvest * $.sfEngine.getInvestmentRatio() / PRECISION_FACTOR;
        uint256 startingAccountSFBalance = $.sfAccount.balance();
        uint256 startingAccountWethBalance = IERC20(weth).balanceOf(address($.sfAccount));
        uint256 startingEngineWethBalance = IERC20(weth).balanceOf(address($.sfEngine));
        Invest invest = new Invest();

        vm.expectEmit(true, true, true, false);
        emit IVaultPlugin__Invest(weth, amountToInvest, amountSFToMint);

        invest.run(
            address($.sfAccountFactory), 
            $.deployConfig.entryPointAddress,
            $.deployConfig.account,
            address($.sfAccount),
            weth,
            type(uint256).max
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

    /* -------------------------------------------------------------------------- */
    /*                              Transfer SF Token                             */
    /* -------------------------------------------------------------------------- */

    function test_Transfer_RevertWhen_NotFromEntryPoint() public localTest accountCreated {
        address randomAccount = _createSFAccount(user);
        vm.expectRevert(abi.encode("account: not from EntryPoint"));
        $.sfAccount.transfer(randomAccount, 1 * PRECISION_FACTOR);
    }

    function test_Transfer_RevertWhen_AccountIsFrozen() public localTest accountCreated {
        address randomAccount = _createSFAccount(user);
        vm.startPrank($.deployConfig.entryPointAddress);
        $.sfAccount.freeze();
        vm.expectRevert(IFreezePlugin.IFreezePlugin__AccountIsFrozen.selector);
        $.sfAccount.transfer(randomAccount, 1 * PRECISION_FACTOR);
        vm.stopPrank();
    }

    function test_Transfer_RevertWhen_ReceiverIsRandomUser() public localTest accountCreated {
        vm.expectRevert(
            abi.encodeWithSelector(
                BaseSFAccountPlugin.BaseSFAccountPlugin__NotSFAccount.selector,
                user
            )
        );
        vm.prank($.deployConfig.entryPointAddress);
        $.sfAccount.transfer(user, 1 * PRECISION_FACTOR);
    }

    function test_Transfer_RevertWhen_ReceiverIsRandomContract() public localTest accountCreated {
        vm.expectRevert(
            abi.encodeWithSelector(
                BaseSFAccountPlugin.BaseSFAccountPlugin__NotSFAccount.selector,
                $.deployConfig.wethTokenAddress
            )
        );
        vm.prank($.deployConfig.entryPointAddress);
        $.sfAccount.transfer($.deployConfig.wethTokenAddress, 1 * PRECISION_FACTOR);
    }

    function test_Transfer_RevertWhen_ReceiverAddressIsZero() public localTest accountCreated {
        vm.expectRevert(
            abi.encodeWithSelector(
                BaseSFAccountPlugin.BaseSFAccountPlugin__NotSFAccount.selector,
                address(0)
            )
        );
        vm.prank($.deployConfig.entryPointAddress);
        $.sfAccount.transfer(address(0), 1 * PRECISION_FACTOR);
    }

    function test_Transfer_RevertWhen_AmountToTransferIsZero() public localTest accountCreated {
        address randomAccount = _createSFAccount(user);
        vm.expectRevert(ISFAccount.ISFAccount__TokenAmountCanNotBeZero.selector);
        vm.prank($.deployConfig.entryPointAddress);
        $.sfAccount.transfer(randomAccount, 0);
    }

    function test_Transfer_RevertWhen_AmountExceedsBalance() public localTest accountCreated {
        address randomAccount = _createSFAccount(user);
        uint256 amountToDeposit = 1 * PRECISION_FACTOR;
        address receiver = randomAccount;
        address collateral = $.deployConfig.wethTokenAddress;
        vm.prank($.sfAccount.owner());
        IERC20(collateral).approve(address($.sfAccount), amountToDeposit);
        vm.startPrank($.deployConfig.entryPointAddress);
        $.sfAccount.deposit(collateral, amountToDeposit);
        uint256 sfBalance = $.sfAccount.balance();
        uint256 amountToTransfer = sfBalance + 1 * PRECISION_FACTOR;
        vm.expectRevert(
            abi.encodeWithSelector(
                ISFAccount.ISFAccount__InsufficientBalance.selector,
                receiver,
                sfBalance,
                amountToTransfer
            )
        );
        $.sfAccount.transfer(receiver, amountToTransfer);
        vm.stopPrank();
    }

    function test_Transfer_TransferSFToken() public ethSepoliaTest accountCreated deposited invested {
        Transfer transfer = new Transfer();
        SFAccount sender = $.sfAccount;
        SFAccount receiver = SFAccount(_createSFAccount(user));
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

    function test_Transfer_TransferAllSFToken() public ethSepoliaTest accountCreated deposited invested {
        Transfer transfer = new Transfer();
        SFAccount sender = $.sfAccount;
        SFAccount receiver = SFAccount(_createSFAccount(user));
        uint256 amountToTransfer = $.sfAccount.balance();
        uint256 startingSenderBalance = sender.balance();
        uint256 startingReceiverBalance = receiver.balance();
        transfer.run(
            address($.sfAccountFactory), 
            $.deployConfig.entryPointAddress,
            $.deployConfig.account,
            address(sender),
            address(receiver),
            type(uint256).max
        );
        assertEq(sender.balance(), startingSenderBalance - amountToTransfer);
        assertEq(receiver.balance(), startingReceiverBalance + amountToTransfer);
    }

    /* -------------------------------------------------------------------------- */
    /*                          Harvest from SF Protocol                          */
    /* -------------------------------------------------------------------------- */

    function test_Harvest_RevertWhen_NotFromEntryPoint() public localTest accountCreated {
        vm.expectRevert(abi.encode("account: not from EntryPoint"));
        $.sfAccount.harvest(
            $.deployConfig.wethTokenAddress, 
            1 * PRECISION_FACTOR, 
            1 * PRECISION_FACTOR
        );
    }

    function test_Harvest_RevertWhen_AccountIsFrozen() public localTest accountCreated {
        vm.startPrank($.deployConfig.entryPointAddress);
        $.sfAccount.freeze();
        vm.expectRevert(IFreezePlugin.IFreezePlugin__AccountIsFrozen.selector);
        $.sfAccount.harvest(
            $.deployConfig.wethTokenAddress, 
            1 * PRECISION_FACTOR, 
            1 * PRECISION_FACTOR
        );
        vm.stopPrank();
    }

    function test_Harvest_RevertWhen_CollateralAddressIsZero() public localTest accountCreated {
        vm.expectRevert(
            abi.encodeWithSelector(
                IVaultPlugin.IVaultPlugin__CollateralNotSupported.selector,
                address(0)
            )
        );
        vm.prank($.deployConfig.entryPointAddress);
        $.sfAccount.harvest(
            address(0), 
            1 * PRECISION_FACTOR, 
            1 * PRECISION_FACTOR
        );
    }

    function test_Harvest_RevertWhen_AmountToRedeemIsZero() public localTest accountCreated {
        vm.expectRevert(IVaultPlugin.IVaultPlugin__TokenAmountCanNotBeZero.selector);
        vm.prank($.deployConfig.entryPointAddress);
        $.sfAccount.harvest(
            $.deployConfig.wethTokenAddress, 
            0,
            1 * PRECISION_FACTOR
        );
    }

    function test_Harvest_RevertWhen_DebtToRepayIsZero() public localTest accountCreated {
        vm.expectRevert(IVaultPlugin.IVaultPlugin__TokenAmountCanNotBeZero.selector);
        vm.prank($.deployConfig.entryPointAddress);
        $.sfAccount.harvest(
            $.deployConfig.wethTokenAddress, 
            1 * PRECISION_FACTOR,
            0
        );
    }

    function test_Harvest_RevertWhen_CollateralNotSupported() public localTest accountCreated {
        address collateral = address(new ERC20Mock("test", "test", $.deployConfig.account, 1 ether));
        vm.expectRevert(
            abi.encodeWithSelector(
                IVaultPlugin.IVaultPlugin__CollateralNotSupported.selector,
                collateral
            )
        );
        vm.prank($.deployConfig.entryPointAddress);
        $.sfAccount.harvest(
            collateral, 
            1 * PRECISION_FACTOR, 
            1 * PRECISION_FACTOR
        );
    }

    function test_Harvest_RevertWhen_DebtToRepayExceedsTotalDebt() public ethSepoliaTest accountCreated deposited invested {
        address collateral = $.deployConfig.wethTokenAddress;
        uint256 amountDeposited = $.sfAccount.getCollateralInvested(collateral);
        uint256 sfDebt = $.sfAccount.debt();
        uint256 debtToRepay = sfDebt + 1 * PRECISION_FACTOR;
        vm.expectRevert(
            abi.encodeWithSelector(
                IVaultPlugin.IVaultPlugin__DebtToRepayExceedsTotalDebt.selector,
                debtToRepay,
                sfDebt
            )
        );
        vm.prank($.deployConfig.entryPointAddress);
        $.sfAccount.harvest(
            $.deployConfig.wethTokenAddress, 
            amountDeposited, 
            debtToRepay
        );
    }

    function test_Harvest_RevertWhen_DebtToRepayExceedsBalance() public ethSepoliaTest accountCreated deposited invested {
        address randomAccount = _createSFAccount(user);
        address collateral = $.deployConfig.wethTokenAddress;
        uint256 amountDeposited = $.sfAccount.getCollateralInvested(collateral);
        uint256 sfBalance = $.sfAccount.balance();
        uint256 sfDebt = $.sfAccount.debt();
        vm.startPrank($.deployConfig.entryPointAddress);
        $.sfAccount.transfer(randomAccount, sfBalance);
        vm.expectRevert(
            abi.encodeWithSelector(
                IVaultPlugin.IVaultPlugin__InsufficientBalance.selector,
                address($.sfEngine),
                0,
                sfDebt
            )
        );
        $.sfAccount.harvest(
            $.deployConfig.wethTokenAddress, 
            amountDeposited, 
            sfDebt
        );
        vm.stopPrank();
    }

    function test_Harvest_RevertWhen_AmountToRedeemExceedsBalance() public ethSepoliaTest accountCreated deposited invested {
        address collateral = $.deployConfig.wethTokenAddress;
        // For this test, SF balance is equal to SF debts
        uint256 sfBalance = $.sfAccount.balance();
        // If all debts were repaid, the amount to redeem would change to amount deposited.
        // But we want to make sure that amount to redeem > amount deposited, so we won't
        // repay all the debts.
        uint256 debtToRepay = sfBalance - 1 * PRECISION_FACTOR;
        uint256 amountDeposited = $.sfAccount.getCollateralInvested(collateral);
        uint256 amountToRedeem = amountDeposited + 1 * PRECISION_FACTOR;
        vm.expectRevert(
            abi.encodeWithSelector(
                IVaultPlugin.IVaultPlugin__InsufficientCollateral.selector,
                address($.sfEngine),
                collateral,
                amountDeposited,
                amountToRedeem
            )
        );
        vm.startPrank($.deployConfig.entryPointAddress);
        $.sfAccount.harvest(
            $.deployConfig.wethTokenAddress, 
            amountToRedeem, 
            debtToRepay
        );
        vm.stopPrank();
    }

    function test_Harvest_HarvestInvestment() public ethSepoliaTest accountCreated deposited invested {
        address weth = $.deployConfig.wethTokenAddress;
        address account = $.deployConfig.account;
        uint256 amountToRedeem = 1 * PRECISION_FACTOR;
        uint256 debtToRepay = $.sfAccount.balance() - 1 * PRECISION_FACTOR;

        uint256 startingAccountWethBalance = $.sfAccount.getCollateralBalance(weth);
        uint256 startingEngineWethBalance = IERC20(weth).balanceOf(address($.sfEngine));
        uint256 startingWethDeposited = $.sfAccount.getCollateralInvested(weth);
        uint256 startingDebt = $.sfEngine.getSFDebt(address($.sfAccount));

        Harvest harvest = new Harvest();
        harvest.run(
            address($.sfAccountFactory), 
            $.deployConfig.entryPointAddress,
            account,
            address($.sfAccount),
            weth,
            amountToRedeem,
            debtToRepay
        );

        assertEq($.sfAccount.getCollateralBalance(weth), startingAccountWethBalance + amountToRedeem);
        assertEq(IERC20(weth).balanceOf(address($.sfEngine)), startingEngineWethBalance - amountToRedeem);
        assertEq($.sfAccount.getCollateralInvested(weth), startingWethDeposited - amountToRedeem);
        assertEq($.sfEngine.getSFDebt(address($.sfAccount)), startingDebt - debtToRepay);
    }

    function test_Harvest_HarvestAllInvestment() public ethSepoliaTest accountCreated deposited invested {
        address weth = $.deployConfig.wethTokenAddress;
        address account = $.deployConfig.account;
        uint256 collateralInvested = $.sfAccount.getCollateralInvested(weth);
        uint256 amountToRedeem = $.sfAccount.getCollateralInvested(weth);
        uint256 debtToRepay = $.sfAccount.balance();
        uint256 amountInvestedToAave = collateralInvested * $.sfEngine.getInvestmentRatio() / PRECISION_FACTOR;

        uint256 startingAccountWethBalance = $.sfAccount.getCollateralBalance(weth);
        uint256 startingEngineWethBalance = IERC20(weth).balanceOf(address($.sfEngine));
        uint256 startingWethInvested = $.sfAccount.getCollateralInvested(weth);
        uint256 startingDebt = $.sfAccount.debt();

        Harvest harvest = new Harvest();
        harvest.run(
            address($.sfAccountFactory), 
            $.deployConfig.entryPointAddress,
            account,
            address($.sfAccount),
            weth,
            type(uint256).max,
            type(uint256).max
        );

        assertEq($.sfAccount.getCollateralBalance(weth), startingAccountWethBalance + amountToRedeem);
        assertEq(IERC20(weth).balanceOf(address($.sfEngine)), startingEngineWethBalance + amountInvestedToAave - amountToRedeem);
        assertEq($.sfAccount.getCollateralInvested(weth), startingWethInvested - amountToRedeem);
        assertEq($.sfAccount.debt(), startingDebt - debtToRepay);
    }

    /* -------------------------------------------------------------------------- */
    /*                              Top-up Collateral                             */
    /* -------------------------------------------------------------------------- */

    function testTopUpCollateral() public ethSepoliaTest accountCreated deposited invested {
        address weth = $.deployConfig.wethTokenAddress;
        address account = $.deployConfig.account;
        uint256 amountToTopUp = 1 * PRECISION_FACTOR;
        uint256 amountInvested = INVEST_AMOUNT * $.sfEngine.getInvestmentRatio() / PRECISION_FACTOR;

        uint256 startingAccountCollateral = $.sfAccount.getCollateralBalance(weth);
        uint256 startingEngineCollateral = IERC20(weth).balanceOf(address($.sfEngine));
        uint256 startingAmountDeposited = $.sfAccount.getCollateralInvested(weth);

        _topUpCollateral(account, address($.sfAccount), weth, amountToTopUp);

        assertEq(
            $.sfAccount.getCollateralBalance(weth), 
            startingAccountCollateral - amountToTopUp
        );
        assertEq(
            IERC20(weth).balanceOf(address($.sfEngine)), 
            startingEngineCollateral + amountToTopUp - amountInvested
        );
        assertEq( 
            $.sfAccount.getCollateralInvested(weth), 
            startingAmountDeposited + amountToTopUp
        );
    }

    /* -------------------------------------------------------------------------- */
    /*                                  Liquidate                                 */
    /* -------------------------------------------------------------------------- */

    function testLiquidateUser() public ethSepoliaTest accountCreated deposited invested {
        address liquidator = user;
        address liquidatorAccount = _createSFAccount(liquidator);
        uint256 amountToInvest = INVEST_AMOUNT;
        uint256 amountToTopUp = 10 * INVEST_AMOUNT;
        address weth = $.deployConfig.wethTokenAddress;
        address wethPriceFeed = $.deployConfig.wethPriceFeedAddress;
        uint256 debtToCover = 3000 * PRECISION_FACTOR;
        _deposit(liquidator, liquidatorAccount, weth, amountToInvest);
        _invest(liquidator, liquidatorAccount, weth, amountToInvest);
        // Top up some collateral to make sure liquidator's collateral ratio won't be broken when eth price drops to 1900$
        _topUpCollateral(liquidator, liquidatorAccount, weth, amountToTopUp);

        uint256 startingUserDepositedAmount = $.sfAccount.getCollateralInvested(weth);
        uint256 startingLiquidatorSFBalance = ISFAccount(liquidatorAccount).balance();
        uint256 startingLiquidatorWethBalance = IVaultPlugin(liquidatorAccount).getCollateralBalance(weth);

        // Break $.sfAccount's collateral ratio
        MockV3Aggregator(wethPriceFeed).updateAnswer(int256(1900 * (10 ** PRICE_FEED_DECIMALS)));

        // Liquidate
        _liquidate(liquidator, liquidatorAccount, address($.sfAccount), weth, debtToCover);

        uint256 amountCollateral = AggregatorV3Interface(wethPriceFeed).getTokensForValue(debtToCover);
        uint256 bonus = amountCollateral * $.sfEngine.getBonusRate() / PRECISION_FACTOR;
        uint256 expectedCollateralReceived = amountCollateral + bonus;
        assertEq(
            $.sfAccount.getCollateralInvested(weth),
            startingUserDepositedAmount - expectedCollateralReceived
        );
        assertEq(
            ISFAccount(liquidatorAccount).balance(),
            startingLiquidatorSFBalance - debtToCover
        );
        assertEq(
            IVaultPlugin(liquidatorAccount).getCollateralBalance(weth),
            startingLiquidatorWethBalance + expectedCollateralReceived
        );
    }

    /* -------------------------------------------------------------------------- */
    /*                        Update Custom Recovery Config                       */
    /* -------------------------------------------------------------------------- */

    function testUpdateCustomRecoveryConfig() public localTest accountCreated {
        address guardian = _createSFAccount(user);
        address[] memory guardiansToUpdate = new address[](1);
        guardiansToUpdate[0] = guardian;
        bool socialRecoveryEnabled = true;
        uint8 minGuardianApprovals = 1;
        uint256 recoveryTimeLock = 1 days;

        ISocialRecoveryPlugin.CustomRecoveryConfig memory config = $.sfAccount.getCustomRecoveryConfig();
        config.guardians = guardiansToUpdate;
        config.socialRecoveryEnabled = socialRecoveryEnabled;
        config.minGuardianApprovals = minGuardianApprovals;
        config.recoveryTimeLock = recoveryTimeLock;

        UpdateCustomRecoveryConfig updateCustomRecoveryConfig = new UpdateCustomRecoveryConfig();
        updateCustomRecoveryConfig.run(
            address($.sfAccountFactory), 
            address($.deployConfig.entryPointAddress),
            $.deployConfig.account,
            address($.sfAccount),
            config
        );

        ISocialRecoveryPlugin.CustomRecoveryConfig memory updatedConfig = $.sfAccount.getCustomRecoveryConfig();
        assertEq(updatedConfig.guardians[0], guardian);
        assertEq(updatedConfig.socialRecoveryEnabled, socialRecoveryEnabled);
        assertEq(updatedConfig.minGuardianApprovals, minGuardianApprovals);
        assertEq(updatedConfig.recoveryTimeLock, recoveryTimeLock);
    }

    /* -------------------------------------------------------------------------- */
    /*                              Initiate Recovery                             */
    /* -------------------------------------------------------------------------- */

    function testInitiateRecovery() public localTest accountCreated recoveryConfigured {
        address previousOwner = $.sfAccount.owner();
        address newOwner = user;
        ISocialRecoveryPlugin.CustomRecoveryConfig memory config = $.sfAccount.getCustomRecoveryConfig();
        vm.expectEmit(true, true, false, false);
        emit ISocialRecoveryPlugin__RecoveryInitiated(guardians[0], newOwner);
        _initiateRecovery(guardian1, guardians[0], address($.sfAccount), newOwner);
        ISocialRecoveryPlugin.RecoveryRecord[] memory records = $.sfAccount.getRecoveryRecords();
        ISocialRecoveryPlugin.RecoveryRecord memory latestRecord = records[records.length - 1];
        (bool isInRecoveryProgress, uint256 receivedApprovals, , ) = $.sfAccount.getRecoveryProgress();
        assertEq(receivedApprovals, 0);
        assertEq(isInRecoveryProgress, true);
        assertEq($.sfAccount.isRecovering(), true);
        assertEq($.sfAccount.isFrozen(), true);
        assertEq(latestRecord.initiator, guardians[0]);
        assertEq(latestRecord.previousOwner, previousOwner);
        assertEq(latestRecord.newOwner, newOwner);
        assertEq(latestRecord.totalGuardians, guardians.length);
        assertEq(latestRecord.requiredApprovals, config.minGuardianApprovals);
        assertEq(latestRecord.approvedGuardians.length, 0);
        assertEq(latestRecord.isCompleted, false);
        assertEq(latestRecord.isCancelled, false);
        assertEq(latestRecord.completedBy, address(0));
        assertEq(latestRecord.cancelledBy, address(0));
    }

    /* -------------------------------------------------------------------------- */
    /*                              Approve Recovery                              */
    /* -------------------------------------------------------------------------- */

    function testApproveRecovery() public localTest accountCreated recoveryConfigured {
        address previousOwner = $.sfAccount.owner();
        address newOwner = user;
        ISocialRecoveryPlugin.CustomRecoveryConfig memory config = $.sfAccount.getCustomRecoveryConfig();
        _initiateRecovery(
            guardian1,
            guardians[0],
            address($.sfAccount),
            newOwner
        );
        vm.expectEmit(true, false, false, false);
        emit ISocialRecoveryPlugin__RecoveryApproved(guardians[0]);
        _approveRecovery(guardian1, guardians[0], address($.sfAccount));
        ISocialRecoveryPlugin.RecoveryRecord[] memory records = $.sfAccount.getRecoveryRecords();
        ISocialRecoveryPlugin.RecoveryRecord memory latestRecord = records[records.length - 1];
        (bool isInRecoveryProgress, uint256 receivedApprovals, , ) = $.sfAccount.getRecoveryProgress();
        assertEq(receivedApprovals, 1);
        assertEq(isInRecoveryProgress, true);
        assertEq($.sfAccount.isRecovering(), true);
        assertEq($.sfAccount.isFrozen(), true);
        assertEq(latestRecord.initiator, guardians[0]);
        assertEq(latestRecord.previousOwner, previousOwner);
        assertEq(latestRecord.newOwner, newOwner);
        assertEq(latestRecord.totalGuardians, guardians.length);
        assertEq(latestRecord.requiredApprovals, config.minGuardianApprovals);
        assertEq(latestRecord.approvedGuardians.length, 1);
        assertEq(latestRecord.approvedGuardians[0], guardians[0]);
        assertEq(latestRecord.isCompleted, false);
        assertEq(latestRecord.isCancelled, false);
        assertEq(latestRecord.completedBy, address(0));
        assertEq(latestRecord.cancelledBy, address(0));
    }

    /* -------------------------------------------------------------------------- */
    /*                              Complete Recovery                             */
    /* -------------------------------------------------------------------------- */

    function testCompleteRecovery() public localTest accountCreated recoveryConfigured {
        address previousOwner = $.sfAccount.owner();
        address newOwner = user;
        ISocialRecoveryPlugin.CustomRecoveryConfig memory config = $.sfAccount.getCustomRecoveryConfig();
        _initiateRecovery(
            guardian1,
            guardians[0],
            address($.sfAccount),
            newOwner
        );
        _approveRecovery(guardian1, guardians[0], address($.sfAccount));
        vm.expectEmit(true, true, false, false);
        emit ISocialRecoveryPlugin__RecoveryCompleted(previousOwner, newOwner, "");
        _approveRecovery(guardian2, guardians[1], address($.sfAccount));
        ISocialRecoveryPlugin.RecoveryRecord[] memory records = $.sfAccount.getRecoveryRecords();
        ISocialRecoveryPlugin.RecoveryRecord memory latestRecord = records[records.length - 1];
        (bool isInRecoveryProgress, , , ) = $.sfAccount.getRecoveryProgress();
        assertEq(isInRecoveryProgress, false);
        assertEq($.sfAccount.isRecovering(), false);
        assertEq($.sfAccount.isFrozen(), false);
        assertEq(latestRecord.initiator, guardians[0]);
        assertEq(latestRecord.previousOwner, previousOwner);
        assertEq(latestRecord.newOwner, newOwner);
        assertEq(latestRecord.totalGuardians, guardians.length);
        assertEq(latestRecord.requiredApprovals, config.minGuardianApprovals);
        assertEq(latestRecord.approvedGuardians.length, 2);
        assertEq(latestRecord.approvedGuardians[0], guardians[0]);
        assertEq(latestRecord.approvedGuardians[1], guardians[1]);
        assertEq(latestRecord.isCompleted, true);
        assertEq(latestRecord.isCancelled, false);
        assertEq(latestRecord.completedBy, guardians[1]);
        assertEq(latestRecord.cancelledBy, address(0));
    }

    function testCompleteRecoveryWithTimeLock() public localTest accountCreated recoveryConfigured {
        address previousOwner = $.sfAccount.owner();
        address newOwner = user;
        uint256 executeTimeLock = 1 days;
        ISocialRecoveryPlugin.CustomRecoveryConfig memory config = $.sfAccount.getCustomRecoveryConfig();
        config.recoveryTimeLock = executeTimeLock;
        _updateCustomRecoveryConfig($.deployConfig.account, address($.sfAccount), config);
        _initiateRecovery(
            guardian1,
            guardians[0],
            address($.sfAccount),
            newOwner
        );
        _approveRecovery(guardian1, guardians[0], address($.sfAccount));
        uint256 executableTime = block.timestamp + executeTimeLock;
        _approveRecovery(guardian2, guardians[1], address($.sfAccount));
        vm.warp(executableTime);
        _completeRecovery(guardian1, guardians[0], address($.sfAccount));
        ISocialRecoveryPlugin.RecoveryRecord[] memory records = $.sfAccount.getRecoveryRecords();
        ISocialRecoveryPlugin.RecoveryRecord memory latestRecord = records[records.length - 1];
        (bool isInRecoveryProgress, , , ) = $.sfAccount.getRecoveryProgress();
        assertEq(isInRecoveryProgress, false);
        assertEq($.sfAccount.isRecovering(), false);
        assertEq($.sfAccount.isFrozen(), false);
        assertEq(latestRecord.initiator, guardians[0]);
        assertEq(latestRecord.previousOwner, previousOwner);
        assertEq(latestRecord.newOwner, newOwner);
        assertEq(latestRecord.totalGuardians, guardians.length);
        assertEq(latestRecord.requiredApprovals, config.minGuardianApprovals);
        assertEq(latestRecord.approvedGuardians.length, 2);
        assertEq(latestRecord.approvedGuardians[0], guardians[0]);
        assertEq(latestRecord.approvedGuardians[1], guardians[1]);
        assertEq(latestRecord.isCompleted, true);
        assertEq(latestRecord.isCancelled, false);
        assertEq(latestRecord.completedBy, guardians[0]);
        assertEq(latestRecord.cancelledBy, address(0));
        assertEq(latestRecord.executableTime, executableTime);
    }

    /* -------------------------------------------------------------------------- */
    /*                               Cancel Recovery                              */
    /* -------------------------------------------------------------------------- */

    function testCancelRecovery() public localTest accountCreated recoveryConfigured {
        address previousOwner = $.sfAccount.owner();
        address newOwner = user;
        ISocialRecoveryPlugin.CustomRecoveryConfig memory config = $.sfAccount.getCustomRecoveryConfig();
        _initiateRecovery(
            guardian1,
            guardians[0],
            address($.sfAccount),
            newOwner
        );
        _approveRecovery(guardian1, guardians[0], address($.sfAccount));
        vm.expectEmit(true, false, false, false);
        emit ISocialRecoveryPlugin__RecoveryCancelled(guardians[0], "");
        _cancelRecovery(
            guardian1,
            guardians[0],
            address($.sfAccount)
        );
        ISocialRecoveryPlugin.RecoveryRecord[] memory records = $.sfAccount.getRecoveryRecords();
        ISocialRecoveryPlugin.RecoveryRecord memory latestRecord = records[records.length - 1];
        (bool isInRecoveryProgress, , , ) = $.sfAccount.getRecoveryProgress();
        assertEq(isInRecoveryProgress, false);
        assertEq($.sfAccount.isRecovering(), false);
        assertEq($.sfAccount.isFrozen(), false);
        assertEq(latestRecord.initiator, guardians[0]);
        assertEq(latestRecord.previousOwner, previousOwner);
        assertEq(latestRecord.newOwner, newOwner);
        assertEq(latestRecord.totalGuardians, guardians.length);
        assertEq(latestRecord.requiredApprovals, config.minGuardianApprovals);
        assertEq(latestRecord.approvedGuardians.length, 1);
        assertEq(latestRecord.approvedGuardians[0], guardians[0]);
        assertEq(latestRecord.isCompleted, false);
        assertEq(latestRecord.isCancelled, true);
        assertEq(latestRecord.completedBy, address(0));
        assertEq(latestRecord.cancelledBy, guardians[0]);
    }

    /* -------------------------------------------------------------------------- */
    /*                              Private Functions                             */
    /* -------------------------------------------------------------------------- */

    function _createSFAccount(address account) private returns (address) {
        CreateAccount createAccount = new CreateAccount();
        address calculatedAccountAddress = $.sfAccountFactory.calculateAccountAddress(
            address($.sfAccountBeacon), 
            $.sfAccountFactory.getSFAccountSalt(account)
        );
        vm.deal(account, account.balance + 1 ether);
        vm.prank(account);
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

    function _invest(address account, address sfAccount, address collateral, uint256 amount) private {
        Invest invest = new Invest();
        invest.run(
            address($.sfAccountFactory), 
            $.deployConfig.entryPointAddress,
            account,
            sfAccount,
            collateral,
            amount
        );
    }

    function _topUpCollateral(address account, address sfAccount, address collateral, uint256 amount) private {
        TopUpCollateral topUpCollateral = new TopUpCollateral();
        topUpCollateral.run(
            address($.sfAccountFactory), 
            $.deployConfig.entryPointAddress,
            account,
            sfAccount,
            collateral,
            amount
        );
    }

    function _liquidate(
        address account, 
        address sfAccount, 
        address accountToLiquidate, 
        address collateral, 
        uint256 debtToCover
    ) private {
        Liquidate liquidate = new Liquidate();
        liquidate.run(
            address($.sfAccountFactory), 
            address($.deployConfig.entryPointAddress),
            account,
            sfAccount,
            accountToLiquidate,
            collateral,
            debtToCover
        );
    }

    function _configureRecovery() private {
        ISocialRecoveryPlugin.CustomRecoveryConfig memory config = $.sfAccount.getCustomRecoveryConfig();
        address guardianAccount1 = _createSFAccount(guardian1);
        address guardianAccount2 = _createSFAccount(guardian2);
        address guardianAccount3 = _createSFAccount(guardian3);
        guardians = [guardianAccount1, guardianAccount2, guardianAccount3];
        config.socialRecoveryEnabled = true;
        config.guardians = guardians;
        config.minGuardianApprovals = 2;
        _updateCustomRecoveryConfig(
            $.deployConfig.account,
            address($.sfAccount),
            config
        );
    }

    function _updateCustomRecoveryConfig(
        address account, 
        address sfAccount, 
        ISocialRecoveryPlugin.CustomRecoveryConfig memory config
    ) private {
        UpdateCustomRecoveryConfig updateCustomRecoveryConfig = new UpdateCustomRecoveryConfig();
        updateCustomRecoveryConfig.run(
            address($.sfAccountFactory), 
            address($.deployConfig.entryPointAddress),
            account,
            sfAccount,
            config
        );
    }

    function _updateGuardians(
        address account, 
        address sfAccount, 
        address[] memory guardiansToUpdate,
        uint8 minGuardianApprovals
    ) public {
        ISocialRecoveryPlugin.CustomRecoveryConfig memory config = $.sfAccount.getCustomRecoveryConfig();
        config.guardians = guardiansToUpdate;
        config.minGuardianApprovals = minGuardianApprovals;
        UpdateCustomRecoveryConfig updateCustomRecoveryConfig = new UpdateCustomRecoveryConfig();
        updateCustomRecoveryConfig.run(
            address($.sfAccountFactory), 
            address($.deployConfig.entryPointAddress),
            account,
            sfAccount,
            config
        );
    }

    function _initiateRecovery(
        address guardian, 
        address guardianSFAccount, 
        address sfAccountToRecover, 
        address newOwner
    ) private {
        InitiateRecovery initiateRecovery = new InitiateRecovery();
        initiateRecovery.run(
            address($.sfAccountFactory), 
            $.deployConfig.entryPointAddress,
            guardian,
            guardianSFAccount,
            sfAccountToRecover,
            newOwner
        );
    }

    function _approveRecovery(
        address guardian, 
        address guardianSFAccount, 
        address sfAccountToRecover
    ) private {
        ApproveRecovery approveRecovery = new ApproveRecovery();
        approveRecovery.run(
            address($.sfAccountFactory), 
            $.deployConfig.entryPointAddress,
            guardian,
            guardianSFAccount,
            sfAccountToRecover
        );
    }

    function _cancelRecovery(
        address guardian, 
        address guardianSFAccount, 
        address sfAccountToRecover
    ) private {
        CancelRecovery cancelRecovery = new CancelRecovery();
        cancelRecovery.run(
            address($.sfAccountFactory), 
            $.deployConfig.entryPointAddress,
            guardian,
            guardianSFAccount,
            sfAccountToRecover
        );
    }

    function _completeRecovery(
        address guardian, 
        address guardianSFAccount, 
        address sfAccountToRecover
    ) private {
        CompleteRecovery completeRecovery = new CompleteRecovery();
        completeRecovery.run(
            address($.sfAccountFactory), 
            $.deployConfig.entryPointAddress,
            guardian,
            guardianSFAccount,
            sfAccountToRecover
        );
    }
}