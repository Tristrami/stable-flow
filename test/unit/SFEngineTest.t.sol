// SPDX-License-Identifier: MIT
pragma solidity ^0.8.30;

import {Test, Vm, console2} from "forge-std/Test.sol";
import {SFEngine} from "../../src/token/SFEngine.sol";
import {SFToken} from "../../src/token/SFToken.sol";
import {Deploy} from "../../script/Deploy.s.sol";
import {Constants} from "../../script/util/Constants.sol";
import {DeployHelper} from "../../script/util/DeployHelper.sol";
import {ERC20Mock} from "../../test/mocks/ERC20Mock.sol";
import {MockV3Aggregator} from "../../test/mocks/MockV3Aggregator.sol";
import {OracleLib, AggregatorV3Interface} from "../../src/libraries/OracleLib.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IPoolDataProvider} from "aave-address-book/src/AaveV3.sol";
import {IPool} from "@aave/contracts/interfaces/IPool.sol";
import {Ownable} from "@aave/contracts/dependencies/openzeppelin/contracts/Ownable.sol";

contract SFEngineTest is Test, Constants {

    using Precisions for uint256;
    using OracleLib for AggregatorV3Interface;

    struct TestData {
        uint256 forkId;
        DeployHelper.DeployConfig deployConfig;
        SFEngine sfEngine;
        SFToken sfToken;
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

    address[] private tokenAddresses;
    address[] private priceFeedAddresses;

    event SFEngine__CollateralDeposited(
        address indexed user, address indexed collateralAddress, uint256 indexed amountCollateral
    );
    event SFEngine__CollateralRedeemed(
        address indexed user, address indexed collateralAddress, uint256 indexed amountCollateral
    );
    event SFEngine__SFTokenMinted(address indexed user, uint256 indexed amountToken);
    event SFEngine__UpdateInvestmentRatio(uint256 investmentRatio);
    event SFEngine__Harvest(address indexed asset, uint256 indexed amount, uint256 indexed interest);

    modifier depositedCollateral(TestData storage data, address collateralAddress, uint256 collateralRatio) {
        IERC20 collateral = IERC20(collateralAddress);
        vm.startPrank(user);
        collateral.approve(address(data.sfEngine), INITIAL_USER_BALANCE);
        uint256 amountToMint = data.sfEngine.calculateSFTokensByCollateral(
            collateralAddress, 
            DEFAULT_AMOUNT_COLLATERAL, 
            collateralRatio
        );
        data.sfEngine.depositCollateralAndMintSFToken(collateralAddress, DEFAULT_AMOUNT_COLLATERAL, amountToMint);
        vm.stopPrank();
        _;
    }

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

    function _setUpLocal() private {
        localData.forkId = vm.createSelectFork("local");
        Deploy deployer = new Deploy();
        (
            address sfTokenAddress, 
            address sfEngineAddress, , ,
            DeployHelper.DeployConfig memory deployConfig
        ) = deployer.deploy();
        localData.sfEngine = SFEngine(sfEngineAddress);
        localData.sfToken = SFToken(sfTokenAddress);
        localData.deployConfig = deployConfig;
        IERC20 weth = IERC20(localData.deployConfig.wethTokenAddress);
        IERC20 wbtc = IERC20(localData.deployConfig.wbtcTokenAddress);
        vm.startPrank(address(deployer));
        weth.transfer(user, INITIAL_USER_BALANCE);
        wbtc.transfer(user, INITIAL_USER_BALANCE);
        weth.transfer(randomUser, INITIAL_USER_BALANCE);
        wbtc.transfer(randomUser, INITIAL_USER_BALANCE);
        vm.stopPrank();
    }

    function _setUpEthSepolia() private {
        sepoliaData.forkId = vm.createSelectFork("ethSepolia");
        Deploy deployer = new Deploy();
        (
            address sfTokenAddress, 
            address sfEngineAddress, , ,
            DeployHelper.DeployConfig memory deployConfig
        ) = deployer.deploy();
        sepoliaData.sfEngine = SFEngine(sfEngineAddress);
        sepoliaData.sfToken = SFToken(sfTokenAddress);
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
    }

    function testGetTokenUsdPrice() public localTest {
        assertEq(
            AggregatorV3Interface($.deployConfig.wethPriceFeedAddress).getPrice(),
            WETH_USD_PRICE.convert()
        );
        assertEq(
            AggregatorV3Interface($.deployConfig.wbtcPriceFeedAddress).getPrice(),
            WBTC_USD_PRICE.convert()
        );
    }

    function testGetTokenValue() public localTest {
        uint256 amountToken = 2 ether;
        assertEq(
            AggregatorV3Interface($.deployConfig.wethPriceFeedAddress).getTokenValue(amountToken),
            (amountToken * WETH_USD_PRICE.convert()) / PRECISION_FACTOR
        );
        assertEq(
            AggregatorV3Interface($.deployConfig.wbtcPriceFeedAddress).getTokenValue(amountToken),
            (amountToken * WBTC_USD_PRICE.convert()) / PRECISION_FACTOR
        );
    }

    function testGetTokenAmountsForUsd() public localTest {
        uint256 amountEth = AggregatorV3Interface(
            $.deployConfig.wethPriceFeedAddress
        ).getTokensForValue(2 * WETH_USD_PRICE.convert());
        uint256 amountBtc = AggregatorV3Interface(
            $.deployConfig.wbtcPriceFeedAddress
        ).getTokensForValue(2 * WBTC_USD_PRICE.convert());
        uint256 expectedTokenAmount = 2;
        assertEq(amountEth, expectedTokenAmount.convert(0, PRECISION));
        assertEq(amountBtc, expectedTokenAmount.convert(0, PRECISION));
    }

    function testGetSFTokenAmountByCollateral() public localTest {
        uint256 ethAmount = 2 ether;
        uint256 collateralRatio = 2 * PRECISION_FACTOR;
        uint256 sfAmount = $.sfEngine.calculateSFTokensByCollateral($.deployConfig.wethTokenAddress, ethAmount, collateralRatio);
        uint256 ethInUsd = ethAmount * WETH_USD_PRICE.convert() / PRECISION_FACTOR;
        uint256 expectedSFAmount = ethInUsd * PRECISION_FACTOR / collateralRatio;
        assertEq(sfAmount, expectedSFAmount);
    }

    function test_RevertWhen_TokenAddressAndPriceFeedAddressLengthNotMatch() public localTest {
        ERC20Mock token = new ERC20Mock("TEST", "TEST", msg.sender, 10);
        // Token address length < price feed address length
        tokenAddresses = [address(0)];
        priceFeedAddresses = [address(0), address(1)];
        SFEngine engine = new SFEngine();
        vm.expectRevert(SFEngine.SFEngine__TokenAddressAndPriceFeedLengthNotMatch.selector);
        engine.initialize(address(token), address(0), 0, 0, 0, tokenAddresses, priceFeedAddresses);
        // Token address length > price feed address length
        tokenAddresses = [address(0), address(1)];
        priceFeedAddresses = [address(0)];
        engine = new SFEngine();
        vm.expectRevert(SFEngine.SFEngine__TokenAddressAndPriceFeedLengthNotMatch.selector);
        engine.initialize(address(token), address(0), 0, 0, 0, tokenAddresses, priceFeedAddresses);
    }

    function test_RevertWhen_DepositCollateralParamIsInvalid() public localTest {
        // Zero address
        vm.expectRevert(abi.encodeWithSelector(SFEngine.SFEngine__CollateralNotSupported.selector, address(0)));
        $.sfEngine.depositCollateralAndMintSFToken(address(0), 1 ether, 1 ether);
        // Zero amount of collateral
        vm.expectRevert(abi.encodeWithSelector(SFEngine.SFEngine__AmountCollateralToDepositCanNotBeZero.selector, 0));
        $.sfEngine.depositCollateralAndMintSFToken($.deployConfig.wethTokenAddress, 0 ether, 1 ether);
        // Unsupported token
        ERC20Mock token = new ERC20Mock("TEST", "TEST", msg.sender, 10);
        vm.expectRevert(abi.encodeWithSelector(SFEngine.SFEngine__CollateralNotSupported.selector, address(token)));
        $.sfEngine.depositCollateralAndMintSFToken(address(token), 1 ether, 1 ether);
    }

    function test_RevertWhen_CollateralRatioIsBroken() public ethSepoliaTest {
        // This assumes the collateral ratio is 1, eg. 100$ collateral => 100$ sf
        uint256 amountCollateral = 1 ether;
        uint256 amountToMint =  AggregatorV3Interface($.deployConfig.wethPriceFeedAddress).getTokenValue(amountCollateral);
        uint256 collateralRatio = 1 * PRECISION_FACTOR;
        ERC20Mock weth = ERC20Mock($.deployConfig.wethTokenAddress);
        vm.prank(Ownable(address(weth)).owner());
        weth.mint(user, amountCollateral);
        vm.startPrank(user);
        weth.approve(address($.sfEngine), amountCollateral);
        vm.expectRevert(
            abi.encodeWithSelector(SFEngine.SFEngine__CollateralRatioIsBroken.selector, user, collateralRatio)
        );
        $.sfEngine.depositCollateralAndMintSFToken(address(weth), amountCollateral, amountToMint);
    }

    function testDepositWithEnoughCollateral() public ethSepoliaTest {
        // Arrange data
        IERC20 weth = IERC20($.deployConfig.wethTokenAddress);
        uint256 amountCollateral = 2 ether;
        uint256 collateralValueInUsd = AggregatorV3Interface(
            address($.deployConfig.wethPriceFeedAddress)
        ).getTokenValue(amountCollateral);
        uint256 amountToMint = (collateralValueInUsd * PRECISION) / $.sfEngine.getMinimumCollateralRatio();
        vm.startPrank(user);
        weth.approve(address($.sfEngine), amountCollateral);
        // weth
        uint256 startingUserWethBalance = weth.balanceOf(user);
        uint256 startingUserAmountCollateral = $.sfEngine.getCollateralAmount(user, address(weth));
        uint256 startingEngineWethBalance = weth.balanceOf(address($.sfEngine));
        // sf
        uint256 startingUserSFBalance = $.sfToken.balanceOf(user);
        // Expected events
        vm.expectEmit(true, true, true, false);
        emit SFEngine__CollateralDeposited(user, address(weth), amountCollateral);
        vm.expectEmit(true, true, true, false);
        emit SFEngine__SFTokenMinted(user, amountToMint);
        // Act
        $.sfEngine.depositCollateralAndMintSFToken(address(weth), amountCollateral, amountToMint);
        // Assert
        // Check weth
        uint256 endingUserWethBalance = weth.balanceOf(user);
        uint256 endingUserAmountCollateral = $.sfEngine.getCollateralAmount(user, address(weth));
        uint256 endingEngineWethBalance = weth.balanceOf(address($.sfEngine));
        uint256 collateralInvested = amountCollateral * $.sfEngine.getInvestmentRatio() / PRECISION_FACTOR;
        (uint256 aTokenBalance, , , , , , , , ) = IPoolDataProvider(
            $.deployConfig.aaveDataProviderAddress
        ).getUserReserveData(address(weth), address($.sfEngine));
        assertEq(endingUserWethBalance, startingUserWethBalance - amountCollateral);
        assertEq(endingUserAmountCollateral, startingUserAmountCollateral + amountCollateral);
        assertEq(endingEngineWethBalance, startingEngineWethBalance + amountCollateral - collateralInvested);
        assertEq(aTokenBalance, collateralInvested);
        // Check sf
        uint256 endingUserSFBalance = $.sfToken.balanceOf(user);
        assertEq(endingUserSFBalance, startingUserSFBalance + amountToMint);
    }

    function test_RevertWhen_RedeemAmountExceedsDeposited() 
        public 
        ethSepoliaTest
        depositedCollateral($, $.deployConfig.wethTokenAddress, DEFAULT_COLLATERAL_RATIO) 
    {
        vm.startPrank(user);
        uint256 amountDeposited = $.sfEngine.getCollateralAmount(user, $.deployConfig.wethTokenAddress);
        uint256 amountToBurn = $.sfEngine.calculateSFTokensByCollateral(
            $.deployConfig.wethTokenAddress, 
            amountDeposited, 
            DEFAULT_COLLATERAL_RATIO
        );
        uint256 amountToRedeem = amountDeposited + 1 ether;
        $.sfToken.approve(address($.sfEngine), amountToBurn);
        vm.expectRevert(
            abi.encodeWithSelector(SFEngine.SFEngine__AmountToRedeemExceedsDeposited.selector, amountDeposited)
        );
        $.sfEngine.redeemCollateral(
            $.deployConfig.wethTokenAddress, amountToRedeem, amountToBurn
        );
    }

    function test_RevertWhen_AmountSFToBurnExceedsUserBalance()
        public
        ethSepoliaTest
        depositedCollateral($, $.deployConfig.wethTokenAddress, DEFAULT_COLLATERAL_RATIO)
    {
        // Burn all tokens from user
        vm.startPrank(address($.sfEngine));
        $.sfToken.burn(user, $.sfToken.balanceOf(user));
        vm.stopPrank();
        // Try to redeem, expect to revert
        vm.startPrank(user);
        vm.expectRevert(
            abi.encodeWithSelector(SFEngine.SFEngine__InsufficientBalance.selector, $.sfToken.balanceOf(user))
        );
        $.sfEngine.redeemCollateral($.deployConfig.wethTokenAddress, DEFAULT_AMOUNT_COLLATERAL, INITIAL_BALANCE);
    }

    function test_RevertWhen_RedeemBreaksCollateralRatio() 
        public 
        ethSepoliaTest
        depositedCollateral($, $.deployConfig.wethTokenAddress, DEFAULT_COLLATERAL_RATIO) 
    {
        uint256 amountCollateralToRedeem = DEFAULT_AMOUNT_COLLATERAL / 2;
        console2.log("amountCollateralToRedeem:", amountCollateralToRedeem);
        uint256 amountCollateralLeft =
            $.sfEngine.getCollateralAmount(user, $.deployConfig.wethTokenAddress) - amountCollateralToRedeem;
        console2.log("amountCollateralLeft:", amountCollateralLeft);
        // Maximum amount of sf the user can hold after collateral is redeemed
        uint256 maximumAmountSFToHold = $.sfEngine.calculateSFTokensByCollateral(
            $.deployConfig.wethTokenAddress, 
            amountCollateralLeft, 
            DEFAULT_COLLATERAL_RATIO
        );
        console2.log("maximumAmountSFToHold:", maximumAmountSFToHold);
        // The minimum amount of sf that it is supposed to burn to maintain the collateral ratio
        uint256 minimumAmountSFToBurn = $.sfEngine.getSFDebt(user) - maximumAmountSFToHold;
        console2.log("minimumAmountSFToBurn:", minimumAmountSFToBurn);
        // Burn half of the minimum amount of sf
        uint256 amountSFToBurn = minimumAmountSFToBurn / 2;
        console2.log("amountSFToBurn:", amountSFToBurn);
        // Calculate expected collateral ratio after redeem
        uint256 amountSFLeft = $.sfEngine.getSFDebt(user) - amountSFToBurn;
        console2.log("amountSFLeft:", amountSFLeft);
        uint256 amountCollateralLeftInUsd =
             AggregatorV3Interface($.deployConfig.wethPriceFeedAddress).getTokenValue(amountCollateralLeft);
        console2.log("amountCollateralLeftInUsd:", amountCollateralLeftInUsd);
        uint256 expectedCollateralRatioAfterRedeem = (amountCollateralLeftInUsd * PRECISION_FACTOR) / amountSFLeft;
        console2.log("expectedCollateralRatioAfterRedeem:", expectedCollateralRatioAfterRedeem);
        vm.startPrank(user);
        $.sfToken.approve(address($.sfEngine), amountSFToBurn);
        vm.expectRevert(
            abi.encodeWithSelector(
                SFEngine.SFEngine__CollateralRatioIsBroken.selector, user, expectedCollateralRatioAfterRedeem
            )
        );
        $.sfEngine.redeemCollateral($.deployConfig.wethTokenAddress, amountCollateralToRedeem, amountSFToBurn);
    }

    function testRedeemCollateral() 
        public 
        ethSepoliaTest 
        depositedCollateral($, $.deployConfig.wethTokenAddress, DEFAULT_COLLATERAL_RATIO) 
    {
        IERC20 weth = IERC20($.deployConfig.wethTokenAddress);
        // Starting balance
        uint256 startingUserWethBalance = weth.balanceOf(user);
        uint256 startingUserSFBalance = $.sfToken.balanceOf(user);
        uint256 startingEngineWethBalance = weth.balanceOf(address($.sfEngine));

        // Starting data
        uint256 startingAmountDeposited = $.sfEngine.getCollateralAmount(user, address(weth));
        uint256 startingAmountMinted = $.sfEngine.getSFDebt(user);
        (uint256 startingATokenBalance, , , , , , , , ) = IPoolDataProvider(
            $.deployConfig.aaveDataProviderAddress
        ).getUserReserveData(address(weth), address($.sfEngine));

        // Prepare redeem data
        uint256 amountCollateralToRedeem = DEFAULT_AMOUNT_COLLATERAL / 2;
        console2.log("amountCollateralToRedeem:", amountCollateralToRedeem);
        uint256 amountCollateralLeft =
            $.sfEngine.getCollateralAmount(user, $.deployConfig.wethTokenAddress) - amountCollateralToRedeem;
        console2.log("amountCollateralLeft:", amountCollateralLeft);
        // Maximum amount of sf the user can hold after collateral is redeemed
        uint256 maximumAmountSFToHold = $.sfEngine.calculateSFTokensByCollateral(
            $.deployConfig.wethTokenAddress, 
            amountCollateralLeft, 
            DEFAULT_COLLATERAL_RATIO
        );
        console2.log("maximumAmountSFToHold:", maximumAmountSFToHold);
        // The minimum amount of sf that it is supposed to burn to maintain the collateral ratio
        uint256 minimumAmountSFToBurn = $.sfEngine.getSFDebt(user) - maximumAmountSFToHold;
        console2.log("minimumAmountSFToBurn:", minimumAmountSFToBurn);
        // Calculate expected collateral ratio after redeem
        uint256 amountSFLeft = $.sfEngine.getSFDebt(user) - minimumAmountSFToBurn;
        console2.log("amountSFLeft:", amountSFLeft);
        uint256 amountCollateralLeftInUsd = AggregatorV3Interface(
            $.deployConfig.wethPriceFeedAddress
        ).getTokenValue(amountCollateralLeft);
        console2.log("amountCollateralLeftInUsd:", amountCollateralLeftInUsd);
        uint256 expectedCollateralRatioAfterRedeem = (amountCollateralLeftInUsd * PRECISION_FACTOR) / amountSFLeft;
        console2.log("expectedCollateralRatioAfterRedeem:", expectedCollateralRatioAfterRedeem);
        vm.startPrank(user);
        $.sfToken.approve(address($.sfEngine), minimumAmountSFToBurn);

        // Redeem
        $.sfEngine.redeemCollateral(
            $.deployConfig.wethTokenAddress, amountCollateralToRedeem, minimumAmountSFToBurn
        );

        // Ending balance
        uint256 endingUserWethBalance = weth.balanceOf(user);
        uint256 endingUserSFBalance = $.sfToken.balanceOf(user);
        (uint256 endingATokenBalance, , , , , , , , ) = IPoolDataProvider(
            $.deployConfig.aaveDataProviderAddress
        ).getUserReserveData(address(weth), address($.sfEngine));
        uint256 endingEngineWethBalance = weth.balanceOf(address($.sfEngine));
        // Ending data
        uint256 endingAmountDeposited = $.sfEngine.getCollateralAmount(user, address(weth));
        uint256 endingAmountMinted = $.sfEngine.getSFDebt(user);

        // Check balance
        assertEq(endingUserWethBalance, startingUserWethBalance + amountCollateralToRedeem);
        assertEq(endingUserSFBalance, startingUserSFBalance - minimumAmountSFToBurn);
        assertEq(endingEngineWethBalance, startingEngineWethBalance - amountCollateralToRedeem);

        // Check data
        assertEq(endingAmountDeposited, startingAmountDeposited - amountCollateralToRedeem);
        assertEq(endingAmountMinted, startingAmountMinted - minimumAmountSFToBurn);
        assertEq(startingATokenBalance, endingATokenBalance);
    }

    function testRedeemAllCollateral() 
        public 
        ethSepoliaTest 
        depositedCollateral($, $.deployConfig.wethTokenAddress, DEFAULT_COLLATERAL_RATIO) 
    {
        IERC20 weth = IERC20($.deployConfig.wethTokenAddress);
        // Starting balance
        uint256 startingUserWethBalance = weth.balanceOf(user);
        uint256 startingUserSFBalance = $.sfToken.balanceOf(user);
        uint256 startingEngineWethBalance = weth.balanceOf(address($.sfEngine));

        // Starting data
        uint256 startingAmountDeposited = $.sfEngine.getCollateralAmount(user, address(weth));
        uint256 startingAmountMinted = $.sfEngine.getSFDebt(user);
        (uint256 amountInvested, , , , , , , , ) = IPoolDataProvider(
            $.deployConfig.aaveDataProviderAddress
        ).getUserReserveData(address(weth), address($.sfEngine));

        // Prepare redeem data
        uint256 amountCollateralToRedeem = DEFAULT_AMOUNT_COLLATERAL;
        console2.log("amountCollateralToRedeem:", amountCollateralToRedeem);
        // The minimum amount of sf that it is supposed to burn to maintain the collateral ratio
        uint256 sfToBurn = $.sfEngine.getSFDebt(user);
        vm.startPrank(user);
        $.sfToken.approve(address($.sfEngine), sfToBurn);

        // Redeem
        $.sfEngine.redeemCollateral(
            $.deployConfig.wethTokenAddress, amountCollateralToRedeem, sfToBurn
        );

        // Ending balance
        uint256 endingUserWethBalance = weth.balanceOf(user);
        uint256 endingUserSFBalance = $.sfToken.balanceOf(user);
        (uint256 endingATokenBalance, , , , , , , , ) = IPoolDataProvider(
            $.deployConfig.aaveDataProviderAddress
        ).getUserReserveData(address(weth), address($.sfEngine));
        uint256 endingEngineWethBalance = weth.balanceOf(address($.sfEngine));
        // Ending data
        uint256 endingAmountDeposited = $.sfEngine.getCollateralAmount(user, address(weth));
        uint256 endingAmountMinted = $.sfEngine.getSFDebt(user);

        // Check balance
        assertEq(endingUserWethBalance, startingUserWethBalance + amountCollateralToRedeem);
        assertEq(endingUserSFBalance, startingUserSFBalance - sfToBurn);
        assertEq(endingEngineWethBalance, startingEngineWethBalance + amountInvested - amountCollateralToRedeem);

        // Check data
        assertEq(endingAmountDeposited, startingAmountDeposited - amountCollateralToRedeem);
        assertEq(endingAmountMinted, startingAmountMinted - sfToBurn);
        assertEq(endingATokenBalance, 0);
    }

    function test_RevertWhen_LiquidateWhenUserCollateralRatioIsNotBroken()
        public
        ethSepoliaTest
        depositedCollateral($, $.deployConfig.wethTokenAddress, DEFAULT_COLLATERAL_RATIO)
    {
        // Mint some token to liquidator
        address liquidator = makeAddr("liquidator");
        vm.prank(address($.sfEngine));
        $.sfToken.mint(liquidator, INITIAL_BALANCE);
        vm.startPrank(liquidator);
        $.sfToken.approve(address($.sfEngine), INITIAL_BALANCE);
        // Liquidate user's collateral, this will revert no matter how much debt we are going to cover
        vm.expectRevert(
            abi.encodeWithSelector(
                SFEngine.SFEngine__CollateralRatioIsNotBroken.selector, user, $.sfEngine.getCollateralRatio(user)
            )
        );
        $.sfEngine.liquidate(user, $.deployConfig.wethTokenAddress, 1000 ether);
    }

    function test_LiquidateWhen_DebtToCoverLessThanUserCollateral() 
        public 
        ethSepoliaTest
        depositedCollateral($, $.deployConfig.wethTokenAddress, DEFAULT_COLLATERAL_RATIO) 
    {
        ERC20Mock weth = ERC20Mock($.deployConfig.wethTokenAddress);
        address liquidator = makeAddr("liquidator");
        uint256 debtToCover = 300 ether;
        vm.prank(Ownable(address(weth)).owner());
        weth.mint(liquidator, LIQUIDATOR_DEPOSIT_AMOUNT);
        // Deposit enough eth to protocol to make sure liquidation won't break liquidator's collateral ratio
        vm.startPrank(liquidator);
        weth.approve(address($.sfEngine), LIQUIDATOR_DEPOSIT_AMOUNT);
        $.sfEngine.depositCollateralAndMintSFToken(
            $.deployConfig.wethTokenAddress, 
            LIQUIDATOR_DEPOSIT_AMOUNT, 
            $.sfEngine.getSFDebt(user)
        );

        // Starting balance
        uint256 startingLiquidatorWethBalance = weth.balanceOf(liquidator);
        uint256 startingLiquidatorSFBalance = $.sfToken.balanceOf(liquidator);
        uint256 startingEngineWethBalance = weth.balanceOf(address($.sfEngine));
        (uint256 startingATokenBalance, , , , , , , , ) = IPoolDataProvider(
            $.deployConfig.aaveDataProviderAddress
        ).getUserReserveData(address(weth), address($.sfEngine));

        // Starting data
        uint256 startingUserAmountMinted = $.sfEngine.getSFDebt(user);
        uint256 startingUserAmountDeposited = $.sfEngine.getCollateralAmount(user, address(weth));
        uint256 startingLiquidatorAmountDeposited = $.sfEngine.getCollateralAmount(liquidator, address(weth));

        $.sfToken.approve(address($.sfEngine), debtToCover);
        // Adjust weth / usd price to 1900$, this will break the collateral ratio, but liquidator can
        // only liquidate a small amount of collateral to make the collateral ratio back to normal
        MockV3Aggregator wethPriceFeed = MockV3Aggregator($.deployConfig.wethPriceFeedAddress);
        wethPriceFeed.updateAnswer(int256(1900 * (10 ** PRICE_FEED_DECIMALS)));

        // Liquidate
        $.sfEngine.liquidate(user, address(weth), debtToCover);
        vm.stopPrank();

        // Ending balance
        uint256 endingLiquidatorWethBalance = weth.balanceOf(liquidator);
        uint256 endingLiquidatorSFBalance = $.sfToken.balanceOf(liquidator);
        uint256 endingEngineWethBalance = weth.balanceOf(address($.sfEngine));
        (uint256 endingATokenBalance, , , , , , , , ) = IPoolDataProvider(
            $.deployConfig.aaveDataProviderAddress
        ).getUserReserveData(address(weth), address($.sfEngine));

        // Ending data
        uint256 endingUserAmountDeposited = $.sfEngine.getCollateralAmount(user, address(weth));
        uint256 endingLiquidatorAmountDeposited = $.sfEngine.getCollateralAmount(liquidator, address(weth));
        uint256 endingUserAmountMinted = $.sfEngine.getSFDebt(user);

        // Check balance
        uint256 amountCollateralToLiquidate = AggregatorV3Interface(
            $.deployConfig.wethPriceFeedAddress
        ).getTokensForValue(debtToCover);
        uint256 bonus = amountCollateralToLiquidate * (10 ** (PRECISION - 1)) / PRECISION_FACTOR;
        uint256 amountCollateralLiquidatorReceived = amountCollateralToLiquidate + bonus;
        assertEq(endingLiquidatorWethBalance, startingLiquidatorWethBalance + amountCollateralLiquidatorReceived);
        assertEq(endingLiquidatorSFBalance, startingLiquidatorSFBalance - debtToCover);
        assertEq(endingEngineWethBalance, startingEngineWethBalance - amountCollateralLiquidatorReceived);
        assertEq(endingATokenBalance, startingATokenBalance);

        // Check data
        assertEq(endingUserAmountDeposited, startingUserAmountDeposited - amountCollateralLiquidatorReceived);
        assertEq(endingLiquidatorAmountDeposited, startingLiquidatorAmountDeposited);
        assertEq(endingUserAmountMinted, startingUserAmountMinted - debtToCover);
    }

    function test_LiquidateWhen_DebtToCoverExceedsUserCollateral() 
        public 
        ethSepoliaTest
        depositedCollateral($, $.deployConfig.wethTokenAddress, DEFAULT_COLLATERAL_RATIO) 
    {
        ERC20Mock weth = ERC20Mock($.deployConfig.wethTokenAddress);
        address liquidator = makeAddr("liquidator");
        uint256 debtToCover = $.sfEngine.getSFDebt(user);
        vm.prank(Ownable(address(weth)).owner());
        weth.mint(liquidator, LIQUIDATOR_DEPOSIT_AMOUNT);
        // Deposit enough eth to protocol to make sure liquidation won't break liquidator's collateral ratio
        vm.startPrank(liquidator);
        weth.approve(address($.sfEngine), debtToCover);
        $.sfEngine.depositCollateralAndMintSFToken(
            $.deployConfig.wethTokenAddress, 
            LIQUIDATOR_DEPOSIT_AMOUNT, 
            $.sfEngine.getSFDebt(user)
        );

        // Starting balance
        uint256 startingLiquidatorWethBalance = weth.balanceOf(liquidator);
        uint256 startingLiquidatorSFBalance = $.sfToken.balanceOf(liquidator);
        uint256 startingEngineWethBalance = weth.balanceOf(address($.sfEngine));
        (uint256 startingATokenBalance, , , , , , , , ) = IPoolDataProvider(
            $.deployConfig.aaveDataProviderAddress
        ).getUserReserveData(address(weth), address($.sfEngine));


        // Starting data
        uint256 startingUserAmountDeposited = $.sfEngine.getCollateralAmount(user, address(weth));
        uint256 startingLiquidatorAmountDeposited = $.sfEngine.getCollateralAmount(liquidator, address(weth));

        $.sfToken.approve(address($.sfEngine), debtToCover);
        // Adjust weth / usd price to 1000$, this will break the collateral ratio, and collateral
        // cant't cover (debt + bonus), liquidator will get all the collaterals by burning
        // (debtToCover - bonus) amount of SF token
        MockV3Aggregator wethPriceFeed = MockV3Aggregator($.deployConfig.wethPriceFeedAddress);
        wethPriceFeed.updateAnswer(int256(1000 * (10 ** PRICE_FEED_DECIMALS)));

        // Liquidate
        $.sfEngine.liquidate(user, address(weth), debtToCover);
        vm.stopPrank();

        // Ending balance
        uint256 endingLiquidatorWethBalance = weth.balanceOf(liquidator);
        uint256 endingLiquidatorSFBalance = $.sfToken.balanceOf(liquidator);
        uint256 endingEngineWethBalance = weth.balanceOf(address($.sfEngine));
        (uint256 endingATokenBalance, , , , , , , , ) = IPoolDataProvider(
            $.deployConfig.aaveDataProviderAddress
        ).getUserReserveData(address(weth), address($.sfEngine));

        // Ending data
        uint256 endingUserAmountDeposited = $.sfEngine.getCollateralAmount(user, address(weth));
        uint256 endingLiquidatorAmountDeposited = $.sfEngine.getCollateralAmount(liquidator, address(weth));
        uint256 endingUserAmountMinted = $.sfEngine.getSFDebt(user);

        // Check balance
        uint256 amountCollateralToLiquidate = AggregatorV3Interface(
            $.deployConfig.wethPriceFeedAddress
        ).getTokensForValue(debtToCover);
        uint256 bonus = amountCollateralToLiquidate * (10 ** (PRECISION - 1)) / PRECISION_FACTOR;
        uint256 bonusInSFToken =  AggregatorV3Interface($.deployConfig.wethPriceFeedAddress).getTokenValue(bonus);
        assertEq(endingLiquidatorWethBalance, startingLiquidatorWethBalance + startingUserAmountDeposited);
        assertEq(endingLiquidatorSFBalance, startingLiquidatorSFBalance - debtToCover + bonusInSFToken);
        assertEq(endingEngineWethBalance, startingEngineWethBalance - startingUserAmountDeposited);
        assertEq(startingATokenBalance, endingATokenBalance);

        // Check data
        assertEq(endingUserAmountDeposited, 0);
        assertEq(endingLiquidatorAmountDeposited, startingLiquidatorAmountDeposited);
        assertEq(endingUserAmountMinted, 0);
    }

    function testHarvestSingleAsset() 
        public 
        ethSepoliaTest
        depositedCollateral($, $.deployConfig.wethTokenAddress, DEFAULT_COLLATERAL_RATIO) 
    {
        address asset = $.deployConfig.wethTokenAddress;
        uint256 amountInvested = $.sfEngine.getInvestmentRatio() * DEFAULT_AMOUNT_COLLATERAL / PRECISION_FACTOR;
        uint256 startingEngineCollateralBalance = IERC20(asset).balanceOf(address($.sfEngine));
        uint256 startingUserCollateralAmount = $.sfEngine.getCollateralAmount(user, asset);
        uint256 staringInvestmentGain = $.sfEngine.getInvestmentGain(asset);
        (uint256 startingATokenBalance, , , , , , , , ) = IPoolDataProvider(
            $.deployConfig.aaveDataProviderAddress
        ).getUserReserveData(asset, address($.sfEngine)); 

        vm.roll(block.number + 10000);
        vm.warp(block.timestamp + 365 days);
        vm.recordLogs();
        vm.prank($.sfEngine.owner());
        vm.expectEmit(true, false, false, false);
        emit SFEngine.SFEngine__Harvest(asset, 0, 0);
        $.sfEngine.harvest(asset, type(uint256).max);
        
        uint256 endingEngineCollateralBalance = IERC20(asset).balanceOf(address($.sfEngine));
        uint256 endingUserCollateralAmount = $.sfEngine.getCollateralAmount(user, asset);
        uint256 endingInvestmentGain = $.sfEngine.getInvestmentGain(asset);
        (uint256 endingATokenBalance, , , , , , , , ) = IPoolDataProvider(
            $.deployConfig.aaveDataProviderAddress
        ).getUserReserveData(asset, address($.sfEngine)); 
        uint256 amountWithdrawn;
        uint256 interest;
        Vm.Log[] memory logs = vm.getRecordedLogs();
        for (uint256 i = 0; i < logs.length; i++) {
            if (logs[i].topics[0] == keccak256("SFEngine__Harvest(address,uint256,uint256)")) {
                amountWithdrawn = uint256(logs[i].topics[2]);
                interest = uint256(logs[i].topics[3]);
            }
        }
        assertEq(amountWithdrawn - interest, amountInvested);
        assertEq(endingEngineCollateralBalance, startingEngineCollateralBalance + amountWithdrawn);
        assertEq(endingUserCollateralAmount, startingUserCollateralAmount);
        assertEq(endingInvestmentGain, staringInvestmentGain + interest);
        assertEq(endingATokenBalance, startingATokenBalance + interest - amountWithdrawn);
    }

    function testHarvestAll() 
        public 
        ethSepoliaTest
        depositedCollateral($, $.deployConfig.wethTokenAddress, DEFAULT_COLLATERAL_RATIO)
        depositedCollateral($, $.deployConfig.wbtcTokenAddress, DEFAULT_COLLATERAL_RATIO)
    {
        address weth = $.deployConfig.wethTokenAddress;
        address wbtc = $.deployConfig.wbtcTokenAddress;

        uint256 amountInvested = $.sfEngine.getInvestmentRatio() * DEFAULT_AMOUNT_COLLATERAL / PRECISION_FACTOR;
        uint256 startingEngineWethBalance = IERC20(weth).balanceOf(address($.sfEngine));
        uint256 startingUserWethAmount = $.sfEngine.getCollateralAmount(user, weth);
        uint256 staringWethInvestmentGain = $.sfEngine.getInvestmentGain(weth);
        (uint256 startingAWethBalance, , , , , , , , ) = IPoolDataProvider(
            $.deployConfig.aaveDataProviderAddress
        ).getUserReserveData(weth, address($.sfEngine));

        uint256 startingEngineBtcBalance = IERC20(wbtc).balanceOf(address($.sfEngine));
        uint256 startingUserBtcAmount = $.sfEngine.getCollateralAmount(user, wbtc);
        uint256 staringWbtcInvestmentGain = $.sfEngine.getInvestmentGain(wbtc);
        (uint256 startingAWbtcBalance, , , , , , , , ) = IPoolDataProvider(
            $.deployConfig.aaveDataProviderAddress
        ).getUserReserveData(wbtc, address($.sfEngine));

        vm.roll(block.number + 10000);
        vm.warp(block.timestamp + 365 days);

        // Update price to pass stale data check
        MockV3Aggregator($.deployConfig.wethPriceFeedAddress).updateAnswer(int256(WETH_USD_PRICE));
        MockV3Aggregator($.deployConfig.wbtcPriceFeedAddress).updateAnswer(int256(WBTC_USD_PRICE));

        vm.recordLogs();
        vm.prank($.sfEngine.owner());
        $.sfEngine.harvestAll();
        
        uint256 endingEngineWethBalance = IERC20(weth).balanceOf(address($.sfEngine));
        uint256 endingUserWethAmount = $.sfEngine.getCollateralAmount(user, weth);
        uint256 endingWethInvestmentGain = $.sfEngine.getInvestmentGain(weth);
        (uint256 endingAWethTokenBalance, , , , , , , , ) = IPoolDataProvider(
            $.deployConfig.aaveDataProviderAddress
        ).getUserReserveData(weth, address($.sfEngine)); 

        uint256 endingEngineWbtcBalance = IERC20(wbtc).balanceOf(address($.sfEngine));
        uint256 endingUserWbtcAmount = $.sfEngine.getCollateralAmount(user, wbtc);
        uint256 endingWbtcInvestmentGain = $.sfEngine.getInvestmentGain(wbtc);
        (uint256 endingAWbtcTokenBalance, , , , , , , , ) = IPoolDataProvider(
            $.deployConfig.aaveDataProviderAddress
        ).getUserReserveData(wbtc, address($.sfEngine));
        
        uint256 wethAmountWithdrawn;
        uint256 wethInterest;
        uint256 wbtcAmountWithdrawn;
        uint256 wbtcInterest;
        Vm.Log[] memory logs = vm.getRecordedLogs();
        for (uint256 i = 0; i < logs.length; i++) {
            if (logs[i].topics[0] == keccak256("SFEngine__Harvest(address,uint256,uint256)")) {
                address asset = address(uint160(uint256(logs[i].topics[1])));
                if (asset == weth) {
                    wethAmountWithdrawn = uint256(logs[i].topics[2]);
                    wethInterest = uint256(logs[i].topics[3]);
                } else if (asset == wbtc) {
                    wbtcAmountWithdrawn = uint256(logs[i].topics[2]);
                    wbtcInterest = uint256(logs[i].topics[3]);
                }
            }
        }

        uint256 wethInvestGainInUsd = AggregatorV3Interface($.deployConfig.wethPriceFeedAddress).getTokenValue(wethInterest);
        uint256 wbtcInvestGainInUsd = AggregatorV3Interface($.deployConfig.wbtcPriceFeedAddress).getTokenValue(wbtcInterest);

        assertEq(wethAmountWithdrawn - wethInterest, amountInvested);
        assertEq(wbtcAmountWithdrawn - wbtcInterest, amountInvested);
        assertEq(endingEngineWethBalance, startingEngineWethBalance + wethAmountWithdrawn);
        assertEq(endingEngineWbtcBalance, startingEngineBtcBalance + wbtcAmountWithdrawn);
        assertEq(endingUserWethAmount, startingUserWethAmount);
        assertEq(endingUserWbtcAmount, startingUserBtcAmount);
        assertEq(endingWethInvestmentGain, staringWethInvestmentGain + wethInterest);
        assertEq(endingWbtcInvestmentGain, staringWbtcInvestmentGain + wbtcInterest);
        assertEq(endingAWethTokenBalance, startingAWethBalance + wethInterest - wethAmountWithdrawn);
        assertEq(endingAWbtcTokenBalance, startingAWbtcBalance + wbtcInterest - wbtcAmountWithdrawn);
        assertEq($.sfEngine.getAllInvestmentGainInUsd(), wethInvestGainInUsd + wbtcInvestGainInUsd);
    }


    function testCalculateStorageLocation() public localTest {
        bytes memory name = "stableflow.storage.FreezePlugin";
        bytes32 b = keccak256(abi.encode(uint256(keccak256(name)) - 1)) & ~bytes32(uint256(0xff));
        console2.logBytes32(b);
    }

}

library Precisions {

    uint256 private constant PRICE_FEED_PRECISION = 8;
    uint256 private constant DEFAULT_PRECISION = 18;

    function convert(uint256 number) internal pure returns (uint256) {
        return convert(number, PRICE_FEED_PRECISION, DEFAULT_PRECISION);
    }

    function convert(uint256 number, uint256 currentPrecision) internal pure returns (uint256) {
        return convert(number, currentPrecision, DEFAULT_PRECISION);
    }

    function convert(
        uint256 number, 
        uint256 currentPrecision, 
        uint256 targetPrecision
    ) internal pure returns (uint256) {
        return number * 10 ** (targetPrecision - currentPrecision);
    }
}