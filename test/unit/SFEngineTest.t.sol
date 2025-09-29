// SPDX-License-Identifier: MIT
pragma solidity ^0.8.30;

import {Test, console2} from "forge-std/Test.sol";
import {SFEngine} from "../../src/token/SFEngine.sol";
import {SFToken} from "../../src/token/SFToken.sol";
import {Deploy} from "../../script/Deploy.s.sol";
import {Constants} from "../../script/util/Constants.sol";
import {DeployHelper} from "../../script/util/DeployHelper.sol";
import {ERC20Mock} from "../../test/mocks/ERC20Mock.sol";
import {MockV3Aggregator} from "../../test/mocks/MockV3Aggregator.sol";
import {OracleLib, AggregatorV3Interface} from "../../src/libraries/OracleLib.sol";
import {IERC20} from "@openzeppelin/contracts/token/erc20/IERC20.sol";
import {IPoolDataProvider} from "aave-address-book/src/AaveV3.sol";
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
    TestData private local;
    TestData private sepolia;

    address[] private tokenAddresses;
    address[] private priceFeedAddresses;

    event SFEngine__CollateralDeposited(
        address indexed user, address indexed collateralAddress, uint256 indexed amountCollateral
    );
    event SFEngine__CollateralRedeemed(
        address indexed user, address indexed collateralAddress, uint256 indexed amountCollateral
    );
    event SFEngine__SFTokenMinted(address indexed user, uint256 indexed amountToken);

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
        vm.selectFork(local.forkId);
        _;
    }

    modifier ethSepoliaTest() {
        vm.selectFork(sepolia.forkId);
        _;
    }

    function setUp() external {
        _setUpLocal();
        _setUpEthSepolia();
    }

    function _setUpLocal() private {
        local.forkId = vm.createSelectFork("local");
        Deploy deployer = new Deploy();
        (
            address sfTokenAddress, 
            address sfEngineAddress, , ,
            DeployHelper.DeployConfig memory deployConfig
        ) = deployer.deploy();
        local.sfEngine = SFEngine(sfEngineAddress);
        local.sfToken = SFToken(sfTokenAddress);
        local.deployConfig = deployConfig;
        IERC20 weth = IERC20(local.deployConfig.wethTokenAddress);
        vm.prank(address(deployer));
        weth.transfer(user, INITIAL_USER_BALANCE);
    }

    function _setUpEthSepolia() private {
        sepolia.forkId = vm.createSelectFork("ethSepolia");
        Deploy deployer = new Deploy();
        (
            address sfTokenAddress, 
            address sfEngineAddress, , ,
            DeployHelper.DeployConfig memory deployConfig
        ) = deployer.deploy();
        sepolia.sfEngine = SFEngine(sfEngineAddress);
        sepolia.sfToken = SFToken(sfTokenAddress);
        sepolia.deployConfig = deployConfig;
        ERC20Mock sepoliaWeth = ERC20Mock(sepolia.deployConfig.wethTokenAddress);
        vm.prank(Ownable(sepolia.deployConfig.wethTokenAddress).owner());
        sepoliaWeth.mint(user, INITIAL_USER_BALANCE);
    }

    function testGetTokenUsdPrice() public localTest {
        assertEq(
            AggregatorV3Interface(local.deployConfig.wethPriceFeedAddress).getPrice(),
            WETH_USD_PRICE.convert()
        );
        assertEq(
            AggregatorV3Interface(local.deployConfig.wbtcPriceFeedAddress).getPrice(),
            WBTC_USD_PRICE.convert()
        );
    }

    function testGetTokenValue() public localTest {
        uint256 amountToken = 2 ether;
        assertEq(
            AggregatorV3Interface(local.deployConfig.wethPriceFeedAddress).getTokenValue(amountToken),
            (amountToken * WETH_USD_PRICE.convert()) / PRECISION_FACTOR
        );
        assertEq(
            AggregatorV3Interface(local.deployConfig.wbtcPriceFeedAddress).getTokenValue(amountToken),
            (amountToken * WBTC_USD_PRICE.convert()) / PRECISION_FACTOR
        );
    }

    function testGetTokenAmountsForUsd() public localTest {
        uint256 amountEth = AggregatorV3Interface(
            local.deployConfig.wethPriceFeedAddress
        ).getTokensForValue(2 * WETH_USD_PRICE.convert());
        uint256 amountBtc = AggregatorV3Interface(
            local.deployConfig.wbtcPriceFeedAddress
        ).getTokensForValue(2 * WBTC_USD_PRICE.convert());
        uint256 expectedTokenAmount = 2;
        assertEq(amountEth, expectedTokenAmount.convert(0, PRECISION));
        assertEq(amountBtc, expectedTokenAmount.convert(0, PRECISION));
    }

    function testGetSFTokenAmountByCollateral() public localTest {
        uint256 ethAmount = 2 ether;
        uint256 collateralRatio = 2 * PRECISION_FACTOR;
        uint256 sfAmount = local.sfEngine.calculateSFTokensByCollateral(local.deployConfig.wethTokenAddress, ethAmount, collateralRatio);
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
        local.sfEngine.depositCollateralAndMintSFToken(address(0), 1 ether, 1 ether);
        // Zero amount of collateral
        vm.expectRevert(abi.encodeWithSelector(SFEngine.SFEngine__AmountCollateralToDepositCanNotBeZero.selector, 0));
        local.sfEngine.depositCollateralAndMintSFToken(local.deployConfig.wethTokenAddress, 0 ether, 1 ether);
        // Unsupported token
        ERC20Mock token = new ERC20Mock("TEST", "TEST", msg.sender, 10);
        vm.expectRevert(abi.encodeWithSelector(SFEngine.SFEngine__CollateralNotSupported.selector, address(token)));
        local.sfEngine.depositCollateralAndMintSFToken(address(token), 1 ether, 1 ether);
    }

    function test_RevertWhen_CollateralRatioIsBroken() public ethSepoliaTest {
        // This assumes the collateral ratio is 1, eg. 100$ collateral => 100$ sf
        uint256 amountCollateral = 1 ether;
        uint256 amountToMint =  AggregatorV3Interface(sepolia.deployConfig.wethPriceFeedAddress).getTokenValue(amountCollateral);
        uint256 collateralRatio = 1 * PRECISION_FACTOR;
        ERC20Mock weth = ERC20Mock(sepolia.deployConfig.wethTokenAddress);
        vm.prank(Ownable(address(weth)).owner());
        weth.mint(user, amountCollateral);
        vm.startPrank(user);
        weth.approve(address(sepolia.sfEngine), amountCollateral);
        vm.expectRevert(
            abi.encodeWithSelector(SFEngine.SFEngine__CollateralRatioIsBroken.selector, user, collateralRatio)
        );
        sepolia.sfEngine.depositCollateralAndMintSFToken(address(weth), amountCollateral, amountToMint);
    }

    function testDepositWithEnoughCollateral() public ethSepoliaTest {
        // Arrange data
        IERC20 weth = IERC20(sepolia.deployConfig.wethTokenAddress);
        uint256 amountCollateral = 2 ether;
        uint256 collateralValueInUsd = AggregatorV3Interface(
            address(sepolia.deployConfig.wethPriceFeedAddress)
        ).getTokenValue(amountCollateral);
        uint256 amountToMint = (collateralValueInUsd * PRECISION) / sepolia.sfEngine.getMinimumCollateralRatio();
        vm.startPrank(user);
        weth.approve(address(sepolia.sfEngine), amountCollateral);
        // weth
        uint256 startingUserWethBalance = weth.balanceOf(user);
        uint256 startingUserAmountCollateral = sepolia.sfEngine.getCollateralAmount(user, address(weth));
        uint256 startingEngineWethBalance = weth.balanceOf(address(sepolia.sfEngine));
        // sf
        uint256 startingUserSFBalance = sepolia.sfToken.balanceOf(user);
        // Expected events
        vm.expectEmit(true, true, true, false);
        emit SFEngine__CollateralDeposited(user, address(weth), amountCollateral);
        vm.expectEmit(true, true, true, false);
        emit SFEngine__SFTokenMinted(user, amountToMint);
        // Act
        sepolia.sfEngine.depositCollateralAndMintSFToken(address(weth), amountCollateral, amountToMint);
        // Assert
        // Check weth
        uint256 endingUserWethBalance = weth.balanceOf(user);
        uint256 endingUserAmountCollateral = sepolia.sfEngine.getCollateralAmount(user, address(weth));
        uint256 endingEngineWethBalance = weth.balanceOf(address(sepolia.sfEngine));
        uint256 collateralInvested = amountCollateral * sepolia.sfEngine.getInvestmentRatio() / PRECISION_FACTOR;
        (uint256 aTokenBalance, , , , , , , , ) = IPoolDataProvider(
            sepolia.deployConfig.aaveDataProviderAddress
        ).getUserReserveData(address(weth), address(sepolia.sfEngine));
        assertEq(endingUserWethBalance, startingUserWethBalance - amountCollateral);
        assertEq(endingUserAmountCollateral, startingUserAmountCollateral + amountCollateral);
        assertEq(endingEngineWethBalance, startingEngineWethBalance + amountCollateral - collateralInvested);
        assertEq(aTokenBalance, collateralInvested);
        // Check sf
        uint256 endingUserSFBalance = sepolia.sfToken.balanceOf(user);
        assertEq(endingUserSFBalance, startingUserSFBalance + amountToMint);
    }

    function test_RevertWhen_RedeemAmountExceedsDeposited() 
        public 
        ethSepoliaTest
        depositedCollateral(sepolia, sepolia.deployConfig.wethTokenAddress, DEFAULT_COLLATERAL_RATIO) 
    {
        vm.startPrank(user);
        uint256 amountDeposited = sepolia.sfEngine.getCollateralAmount(user, sepolia.deployConfig.wethTokenAddress);
        uint256 amountToBurn = sepolia.sfEngine.calculateSFTokensByCollateral(
            sepolia.deployConfig.wethTokenAddress, 
            amountDeposited, 
            DEFAULT_COLLATERAL_RATIO
        );
        uint256 amountToRedeem = amountDeposited + 1 ether;
        sepolia.sfToken.approve(address(sepolia.sfEngine), amountToBurn);
        vm.expectRevert(
            abi.encodeWithSelector(SFEngine.SFEngine__AmountToRedeemExceedsDeposited.selector, amountDeposited)
        );
        sepolia.sfEngine.redeemCollateral(
            sepolia.deployConfig.wethTokenAddress, amountToRedeem, amountToBurn
        );
    }

    function test_RevertWhen_AmountSFToBurnExceedsUserBalance()
        public
        ethSepoliaTest
        depositedCollateral(sepolia, sepolia.deployConfig.wethTokenAddress, DEFAULT_COLLATERAL_RATIO)
    {
        // Burn all tokens from user
        vm.startPrank(address(sepolia.sfEngine));
        sepolia.sfToken.burn(user, sepolia.sfToken.balanceOf(user));
        vm.stopPrank();
        // Try to redeem, expect to revert
        vm.startPrank(user);
        vm.expectRevert(
            abi.encodeWithSelector(SFEngine.SFEngine__InsufficientBalance.selector, sepolia.sfToken.balanceOf(user))
        );
        sepolia.sfEngine.redeemCollateral(sepolia.deployConfig.wethTokenAddress, DEFAULT_AMOUNT_COLLATERAL, INITIAL_BALANCE);
    }

    function test_RevertWhen_RedeemBreaksCollateralRatio() 
        public 
        ethSepoliaTest
        depositedCollateral(sepolia, sepolia.deployConfig.wethTokenAddress, DEFAULT_COLLATERAL_RATIO) 
    {
        uint256 amountCollateralToRedeem = DEFAULT_AMOUNT_COLLATERAL / 2;
        console2.log("amountCollateralToRedeem:", amountCollateralToRedeem);
        uint256 amountCollateralLeft =
            sepolia.sfEngine.getCollateralAmount(user, sepolia.deployConfig.wethTokenAddress) - amountCollateralToRedeem;
        console2.log("amountCollateralLeft:", amountCollateralLeft);
        // Maximum amount of sf the user can hold after collateral is redeemed
        uint256 maximumAmountSFToHold = sepolia.sfEngine.calculateSFTokensByCollateral(
            sepolia.deployConfig.wethTokenAddress, 
            amountCollateralLeft, 
            DEFAULT_COLLATERAL_RATIO
        );
        console2.log("maximumAmountSFToHold:", maximumAmountSFToHold);
        // The minimum amount of sf that it is supposed to burn to maintain the collateral ratio
        uint256 minimumAmountSFToBurn = sepolia.sfEngine.getSFDebt(user) - maximumAmountSFToHold;
        console2.log("minimumAmountSFToBurn:", minimumAmountSFToBurn);
        // Burn half of the minimum amount of sf
        uint256 amountSFToBurn = minimumAmountSFToBurn / 2;
        console2.log("amountSFToBurn:", amountSFToBurn);
        // Calculate expected collateral ratio after redeem
        uint256 amountSFLeft = sepolia.sfEngine.getSFDebt(user) - amountSFToBurn;
        console2.log("amountSFLeft:", amountSFLeft);
        uint256 amountCollateralLeftInUsd =
             AggregatorV3Interface(sepolia.deployConfig.wethPriceFeedAddress).getTokenValue(amountCollateralLeft);
        console2.log("amountCollateralLeftInUsd:", amountCollateralLeftInUsd);
        uint256 expectedCollateralRatioAfterRedeem = (amountCollateralLeftInUsd * PRECISION_FACTOR) / amountSFLeft;
        console2.log("expectedCollateralRatioAfterRedeem:", expectedCollateralRatioAfterRedeem);
        vm.startPrank(user);
        sepolia.sfToken.approve(address(sepolia.sfEngine), amountSFToBurn);
        vm.expectRevert(
            abi.encodeWithSelector(
                SFEngine.SFEngine__CollateralRatioIsBroken.selector, user, expectedCollateralRatioAfterRedeem
            )
        );
        sepolia.sfEngine.redeemCollateral(sepolia.deployConfig.wethTokenAddress, amountCollateralToRedeem, amountSFToBurn);
    }

    function testRedeemCollateral() 
        public 
        ethSepoliaTest 
        depositedCollateral(sepolia, sepolia.deployConfig.wethTokenAddress, DEFAULT_COLLATERAL_RATIO) 
    {
        IERC20 weth = IERC20(sepolia.deployConfig.wethTokenAddress);
        // Starting balance
        uint256 startingUserWethBalance = weth.balanceOf(user);
        uint256 startingUserSFBalance = sepolia.sfToken.balanceOf(user);
        uint256 startingEngineWethBalance = weth.balanceOf(address(sepolia.sfEngine));

        // Starting data
        uint256 startingAmountDeposited = sepolia.sfEngine.getCollateralAmount(user, address(weth));
        uint256 startingAmountMinted = sepolia.sfEngine.getSFDebt(user);
        (uint256 startingATokenBalance, , , , , , , , ) = IPoolDataProvider(
            sepolia.deployConfig.aaveDataProviderAddress
        ).getUserReserveData(address(weth), address(sepolia.sfEngine));

        // Prepare redeem data
        uint256 amountCollateralToRedeem = DEFAULT_AMOUNT_COLLATERAL / 2;
        console2.log("amountCollateralToRedeem:", amountCollateralToRedeem);
        uint256 amountCollateralLeft =
            sepolia.sfEngine.getCollateralAmount(user, sepolia.deployConfig.wethTokenAddress) - amountCollateralToRedeem;
        console2.log("amountCollateralLeft:", amountCollateralLeft);
        // Maximum amount of sf the user can hold after collateral is redeemed
        uint256 maximumAmountSFToHold = sepolia.sfEngine.calculateSFTokensByCollateral(
            sepolia.deployConfig.wethTokenAddress, 
            amountCollateralLeft, 
            DEFAULT_COLLATERAL_RATIO
        );
        console2.log("maximumAmountSFToHold:", maximumAmountSFToHold);
        // The minimum amount of sf that it is supposed to burn to maintain the collateral ratio
        uint256 minimumAmountSFToBurn = sepolia.sfEngine.getSFDebt(user) - maximumAmountSFToHold;
        console2.log("minimumAmountSFToBurn:", minimumAmountSFToBurn);
        // Calculate expected collateral ratio after redeem
        uint256 amountSFLeft = sepolia.sfEngine.getSFDebt(user) - minimumAmountSFToBurn;
        console2.log("amountSFLeft:", amountSFLeft);
        uint256 amountCollateralLeftInUsd = AggregatorV3Interface(
            sepolia.deployConfig.wethPriceFeedAddress
        ).getTokenValue(amountCollateralLeft);
        console2.log("amountCollateralLeftInUsd:", amountCollateralLeftInUsd);
        uint256 expectedCollateralRatioAfterRedeem = (amountCollateralLeftInUsd * PRECISION_FACTOR) / amountSFLeft;
        console2.log("expectedCollateralRatioAfterRedeem:", expectedCollateralRatioAfterRedeem);
        vm.startPrank(user);
        sepolia.sfToken.approve(address(sepolia.sfEngine), minimumAmountSFToBurn);

        // Redeem
        sepolia.sfEngine.redeemCollateral(
            sepolia.deployConfig.wethTokenAddress, amountCollateralToRedeem, minimumAmountSFToBurn
        );

        // Ending balance
        uint256 endingUserWethBalance = weth.balanceOf(user);
        uint256 endingUserSFBalance = sepolia.sfToken.balanceOf(user);
        (uint256 endingATokenBalance, , , , , , , , ) = IPoolDataProvider(
            sepolia.deployConfig.aaveDataProviderAddress
        ).getUserReserveData(address(weth), address(sepolia.sfEngine));
        uint256 endingEngineWethBalance = weth.balanceOf(address(sepolia.sfEngine));
        // Ending data
        uint256 endingAmountDeposited = sepolia.sfEngine.getCollateralAmount(user, address(weth));
        uint256 endingAmountMinted = sepolia.sfEngine.getSFDebt(user);

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
        depositedCollateral(sepolia, sepolia.deployConfig.wethTokenAddress, DEFAULT_COLLATERAL_RATIO) 
    {
        IERC20 weth = IERC20(sepolia.deployConfig.wethTokenAddress);
        // Starting balance
        uint256 startingUserWethBalance = weth.balanceOf(user);
        uint256 startingUserSFBalance = sepolia.sfToken.balanceOf(user);
        uint256 startingEngineWethBalance = weth.balanceOf(address(sepolia.sfEngine));

        // Starting data
        uint256 startingAmountDeposited = sepolia.sfEngine.getCollateralAmount(user, address(weth));
        uint256 startingAmountMinted = sepolia.sfEngine.getSFDebt(user);
        (uint256 amountInvested, , , , , , , , ) = IPoolDataProvider(
            sepolia.deployConfig.aaveDataProviderAddress
        ).getUserReserveData(address(weth), address(sepolia.sfEngine));

        // Prepare redeem data
        uint256 amountCollateralToRedeem = DEFAULT_AMOUNT_COLLATERAL;
        console2.log("amountCollateralToRedeem:", amountCollateralToRedeem);
        // The minimum amount of sf that it is supposed to burn to maintain the collateral ratio
        uint256 sfToBurn = sepolia.sfEngine.getSFDebt(user);
        vm.startPrank(user);
        sepolia.sfToken.approve(address(sepolia.sfEngine), sfToBurn);

        // Redeem
        sepolia.sfEngine.redeemCollateral(
            sepolia.deployConfig.wethTokenAddress, amountCollateralToRedeem, sfToBurn
        );

        // Ending balance
        uint256 endingUserWethBalance = weth.balanceOf(user);
        uint256 endingUserSFBalance = sepolia.sfToken.balanceOf(user);
        (uint256 endingATokenBalance, , , , , , , , ) = IPoolDataProvider(
            sepolia.deployConfig.aaveDataProviderAddress
        ).getUserReserveData(address(weth), address(sepolia.sfEngine));
        uint256 endingEngineWethBalance = weth.balanceOf(address(sepolia.sfEngine));
        // Ending data
        uint256 endingAmountDeposited = sepolia.sfEngine.getCollateralAmount(user, address(weth));
        uint256 endingAmountMinted = sepolia.sfEngine.getSFDebt(user);

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
        depositedCollateral(sepolia, sepolia.deployConfig.wethTokenAddress, DEFAULT_COLLATERAL_RATIO)
    {
        // Mint some token to liquidator
        address liquidator = makeAddr("liquidator");
        vm.prank(address(sepolia.sfEngine));
        sepolia.sfToken.mint(liquidator, INITIAL_BALANCE);
        vm.startPrank(liquidator);
        sepolia.sfToken.approve(address(sepolia.sfEngine), INITIAL_BALANCE);
        // Liquidate user's collateral, this will revert no matter how much debt we are going to cover
        vm.expectRevert(
            abi.encodeWithSelector(
                SFEngine.SFEngine__CollateralRatioIsNotBroken.selector, user, sepolia.sfEngine.getCollateralRatio(user)
            )
        );
        sepolia.sfEngine.liquidate(user, sepolia.deployConfig.wethTokenAddress, 1000 ether);
    }

    function test_LiquidateWhen_DebtToCoverLessThanUserCollateral() 
        public 
        ethSepoliaTest
        depositedCollateral(sepolia, sepolia.deployConfig.wethTokenAddress, DEFAULT_COLLATERAL_RATIO) 
    {
        ERC20Mock weth = ERC20Mock(sepolia.deployConfig.wethTokenAddress);
        address liquidator = makeAddr("liquidator");
        uint256 debtToCover = 300 ether;
        vm.prank(Ownable(address(weth)).owner());
        weth.mint(liquidator, LIQUIDATOR_DEPOSIT_AMOUNT);
        // Deposit enough eth to protocol to make sure liquidation won't break liquidator's collateral ratio
        vm.startPrank(liquidator);
        weth.approve(address(sepolia.sfEngine), LIQUIDATOR_DEPOSIT_AMOUNT);
        sepolia.sfEngine.depositCollateralAndMintSFToken(
            sepolia.deployConfig.wethTokenAddress, 
            LIQUIDATOR_DEPOSIT_AMOUNT, 
            sepolia.sfEngine.getSFDebt(user)
        );

        // Starting balance
        uint256 startingLiquidatorWethBalance = weth.balanceOf(liquidator);
        uint256 startingLiquidatorSFBalance = sepolia.sfToken.balanceOf(liquidator);
        uint256 startingEngineWethBalance = weth.balanceOf(address(sepolia.sfEngine));
        (uint256 startingATokenBalance, , , , , , , , ) = IPoolDataProvider(
            sepolia.deployConfig.aaveDataProviderAddress
        ).getUserReserveData(address(weth), address(sepolia.sfEngine));

        // Starting data
        uint256 startingUserAmountMinted = sepolia.sfEngine.getSFDebt(user);
        uint256 startingUserAmountDeposited = sepolia.sfEngine.getCollateralAmount(user, address(weth));
        uint256 startingLiquidatorAmountDeposited = sepolia.sfEngine.getCollateralAmount(liquidator, address(weth));

        sepolia.sfToken.approve(address(sepolia.sfEngine), debtToCover);
        // Adjust weth / usd price to 1900$, this will break the collateral ratio, but liquidator can
        // only liquidate a small amount of collateral to make the collateral ratio back to normal
        MockV3Aggregator wethPriceFeed = MockV3Aggregator(sepolia.deployConfig.wethPriceFeedAddress);
        wethPriceFeed.updateAnswer(int256(1900 * (10 ** PRICE_FEED_DECIMALS)));

        // Liquidate
        sepolia.sfEngine.liquidate(user, address(weth), debtToCover);
        vm.stopPrank();

        // Ending balance
        uint256 endingLiquidatorWethBalance = weth.balanceOf(liquidator);
        uint256 endingLiquidatorSFBalance = sepolia.sfToken.balanceOf(liquidator);
        uint256 endingEngineWethBalance = weth.balanceOf(address(sepolia.sfEngine));
        (uint256 endingATokenBalance, , , , , , , , ) = IPoolDataProvider(
            sepolia.deployConfig.aaveDataProviderAddress
        ).getUserReserveData(address(weth), address(sepolia.sfEngine));

        // Ending data
        uint256 endingUserAmountDeposited = sepolia.sfEngine.getCollateralAmount(user, address(weth));
        uint256 endingLiquidatorAmountDeposited = sepolia.sfEngine.getCollateralAmount(liquidator, address(weth));
        uint256 endingUserAmountMinted = sepolia.sfEngine.getSFDebt(user);

        // Check balance
        uint256 amountCollateralToLiquidate = AggregatorV3Interface(
            sepolia.deployConfig.wethPriceFeedAddress
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
        depositedCollateral(sepolia, sepolia.deployConfig.wethTokenAddress, DEFAULT_COLLATERAL_RATIO) 
    {
        ERC20Mock weth = ERC20Mock(sepolia.deployConfig.wethTokenAddress);
        address liquidator = makeAddr("liquidator");
        uint256 debtToCover = sepolia.sfEngine.getSFDebt(user);
        vm.prank(Ownable(address(weth)).owner());
        weth.mint(liquidator, LIQUIDATOR_DEPOSIT_AMOUNT);
        // Deposit enough eth to protocol to make sure liquidation won't break liquidator's collateral ratio
        vm.startPrank(liquidator);
        weth.approve(address(sepolia.sfEngine), debtToCover);
        sepolia.sfEngine.depositCollateralAndMintSFToken(
            sepolia.deployConfig.wethTokenAddress, 
            LIQUIDATOR_DEPOSIT_AMOUNT, 
            sepolia.sfEngine.getSFDebt(user)
        );

        // Starting balance
        uint256 startingLiquidatorWethBalance = weth.balanceOf(liquidator);
        uint256 startingLiquidatorSFBalance = sepolia.sfToken.balanceOf(liquidator);
        uint256 startingEngineWethBalance = weth.balanceOf(address(sepolia.sfEngine));
        (uint256 startingATokenBalance, , , , , , , , ) = IPoolDataProvider(
            sepolia.deployConfig.aaveDataProviderAddress
        ).getUserReserveData(address(weth), address(sepolia.sfEngine));


        // Starting data
        uint256 startingUserAmountDeposited = sepolia.sfEngine.getCollateralAmount(user, address(weth));
        uint256 startingLiquidatorAmountDeposited = sepolia.sfEngine.getCollateralAmount(liquidator, address(weth));

        sepolia.sfToken.approve(address(sepolia.sfEngine), debtToCover);
        // Adjust weth / usd price to 1000$, this will break the collateral ratio, and collateral
        // cant't cover (debt + bonus), liquidator will get all the collaterals by burning
        // (debtToCover - bonus) amount of SF token
        MockV3Aggregator wethPriceFeed = MockV3Aggregator(sepolia.deployConfig.wethPriceFeedAddress);
        wethPriceFeed.updateAnswer(int256(1000 * (10 ** PRICE_FEED_DECIMALS)));

        // Liquidate
        sepolia.sfEngine.liquidate(user, address(weth), debtToCover);
        vm.stopPrank();

        // Ending balance
        uint256 endingLiquidatorWethBalance = weth.balanceOf(liquidator);
        uint256 endingLiquidatorSFBalance = sepolia.sfToken.balanceOf(liquidator);
        uint256 endingEngineWethBalance = weth.balanceOf(address(sepolia.sfEngine));
        (uint256 endingATokenBalance, , , , , , , , ) = IPoolDataProvider(
            sepolia.deployConfig.aaveDataProviderAddress
        ).getUserReserveData(address(weth), address(sepolia.sfEngine));

        // Ending data
        uint256 endingUserAmountDeposited = sepolia.sfEngine.getCollateralAmount(user, address(weth));
        uint256 endingLiquidatorAmountDeposited = sepolia.sfEngine.getCollateralAmount(liquidator, address(weth));
        uint256 endingUserAmountMinted = sepolia.sfEngine.getSFDebt(user);

        // Check balance
        uint256 amountCollateralToLiquidate = AggregatorV3Interface(
            sepolia.deployConfig.wethPriceFeedAddress
        ).getTokensForValue(debtToCover);
        uint256 bonus = amountCollateralToLiquidate * (10 ** (PRECISION - 1)) / PRECISION_FACTOR;
        uint256 bonusInSFToken =  AggregatorV3Interface(sepolia.deployConfig.wethPriceFeedAddress).getTokenValue(bonus);
        assertEq(endingLiquidatorWethBalance, startingLiquidatorWethBalance + startingUserAmountDeposited);
        assertEq(endingLiquidatorSFBalance, startingLiquidatorSFBalance - debtToCover + bonusInSFToken);
        assertEq(endingEngineWethBalance, startingEngineWethBalance - startingUserAmountDeposited);
        assertEq(startingATokenBalance, endingATokenBalance);

        // Check data
        assertEq(endingUserAmountDeposited, 0);
        assertEq(endingLiquidatorAmountDeposited, startingLiquidatorAmountDeposited);
        assertEq(endingUserAmountMinted, 0);
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