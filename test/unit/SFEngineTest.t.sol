// SPDX-License-Identifier: MIT
pragma solidity ^0.8.30;

import {Test, console2} from "forge-std/Test.sol";
import {SFEngine} from "../../src/token/SFEngine.sol";
import {SFToken} from "../../src/token/SFToken.sol";
import {Validator} from "../../src/token/Validator.sol";
import {DeploySFEngine} from "../../script/DeploySFEngine.s.sol";
import {Constants} from "../../script/util/Constants.sol";
import {DeployHelper} from "../../script/util/DeployHelper.sol";
import {ERC20Mock} from "../../test/mocks/ERC20Mock.sol";
import {MockV3Aggregator} from "../../test/mocks/MockV3Aggregator.sol";
import {IERC20} from "@openzeppelin/contracts/token/erc20/IERC20.sol";

contract SFEngineTest is Test, Constants {

    uint256 private constant INITIAL_USER_BALANCE = 100 ether;
    uint256 private constant LIQUIDATOR_DEPOSIT_AMOUNT = 1000 ether;
    uint256 private constant DEFAULT_AMOUNT_COLLATERAL = 2 ether;
    uint256 private constant DEFAULT_COLLATERAL_RATIO = 2 * PRECISION_FACTOR;

    DeploySFEngine private deployer;
    DeployHelper.DeployConfig private deployConfig;
    SFEngine private sfEngine;
    SFToken private sfToken;
    address private user = makeAddr("user");

    address[] private tokenAddresses;
    address[] private priceFeedAddresses;

    event SFEngine__CollateralDeposited(
        address indexed user, address indexed collateralTokenAddress, uint256 indexed amountCollateral
    );
    event SFEngine__CollateralRedeemed(
        address indexed user, address indexed collateralTokenAddress, uint256 indexed amountCollateral
    );
    event SFEngine__SFTokenMinted(address indexed user, uint256 indexed amountToken);

    modifier depositedCollateral(address tokenAddress, uint256 collateralRatio) {
        IERC20 collateralToken = IERC20(tokenAddress);
        vm.startPrank(user);
        collateralToken.approve(address(sfEngine), INITIAL_USER_BALANCE);
        uint256 amountToMint = getAmountSFToMint(tokenAddress, DEFAULT_AMOUNT_COLLATERAL, collateralRatio);
        sfToken.approve(address(sfEngine), amountToMint);
        sfEngine.depositCollateralAndMintSFToken(tokenAddress, DEFAULT_AMOUNT_COLLATERAL, amountToMint);
        vm.stopPrank();
        _;
    }

    function setUp() external {
        deployer = new DeploySFEngine();
        (sfEngine, deployConfig) = deployer.deploy();
        sfToken = SFToken(sfEngine.getSFTokenAddress());
        // Transfer some token to user
        IERC20 weth = IERC20(deployConfig.wethTokenAddress);
        vm.prank(address(deployer));
        weth.transfer(user, INITIAL_USER_BALANCE);
    }

    function testGetTokenUsdPrice() public view {
        assertEq(
            sfEngine.getTokenUsdPrice(deployConfig.wethTokenAddress),
            adjustNumberByPrecision(WETH_USD_PRICE, PRICE_FEED_DECIMALS, PRECISION)
        );
        assertEq(
            sfEngine.getTokenUsdPrice(deployConfig.wbtcTokenAddress),
            adjustNumberByPrecision(WBTC_USD_PRICE, PRICE_FEED_DECIMALS, PRECISION)
        );
    }

    function testGetTokenValueInUsd() public view {
        uint256 amountToken = 2 ether;
        assertEq(
            sfEngine.getTokenValueInUsd(deployConfig.wethTokenAddress, amountToken),
            (amountToken * adjustNumberByPrecision(WETH_USD_PRICE, PRICE_FEED_DECIMALS, PRECISION)) / PRECISION_FACTOR
        );
        assertEq(
            sfEngine.getTokenValueInUsd(deployConfig.wbtcTokenAddress, amountToken),
            (amountToken * adjustNumberByPrecision(WBTC_USD_PRICE, PRICE_FEED_DECIMALS, PRECISION)) / PRECISION_FACTOR
        );
    }

    function testGetTokenAmountFromUsd() public view {
        uint256 amountEth = sfEngine.getTokenAmountFromUsd(
            deployConfig.wethTokenAddress, 2 * adjustNumberByPrecision(WETH_USD_PRICE, PRICE_FEED_DECIMALS, PRECISION)
        );
        uint256 amountBtc = sfEngine.getTokenAmountFromUsd(
            deployConfig.wbtcTokenAddress, 2 * adjustNumberByPrecision(WBTC_USD_PRICE, PRICE_FEED_DECIMALS, PRECISION)
        );
        assertEq(amountEth, adjustNumberByPrecision(2, 0, PRECISION));
        assertEq(amountBtc, adjustNumberByPrecision(2, 0, PRECISION));
    }

    function testGetSFTokenAmountByCollateral() public view {
        uint256 ethAmount = 2 ether;
        uint256 collateralRatio = 2 * PRECISION_FACTOR;
        uint256 sfAmount = sfEngine.calculateSFTokensByCollateral(deployConfig.wethTokenAddress, ethAmount, collateralRatio);
        uint256 expectedEthInUsd = ethAmount * adjustNumberByPrecision(WETH_USD_PRICE, PRICE_FEED_DECIMALS, PRECISION) / PRECISION_FACTOR;
        uint256 expectedSFAmount = expectedEthInUsd * sfEngine.getMinimumCollateralRatio() / PRECISION_FACTOR;
        assertEq(sfAmount, expectedSFAmount);
    }

    function test_RevertWhen_TokenAddressAndPriceFeedAddressLengthNotMatch() public {
        ERC20Mock token = new ERC20Mock("TEST", "TEST", msg.sender, 10);
        // Token address length < price feed address length
        tokenAddresses = [address(0)];
        priceFeedAddresses = [address(0), address(1)];
        SFEngine engine = new SFEngine();
        vm.expectRevert(SFEngine.SFEngine__TokenAddressAndPriceFeedLengthNotMatch.selector);
        engine.initialize(address(token), tokenAddresses, priceFeedAddresses);
        // Token address length > price feed address length
        tokenAddresses = [address(0), address(1)];
        priceFeedAddresses = [address(0)];
        engine = new SFEngine();
        vm.expectRevert(SFEngine.SFEngine__TokenAddressAndPriceFeedLengthNotMatch.selector);
        engine.initialize(address(token), tokenAddresses, priceFeedAddresses);
    }

    function test_RevertWhen_DepositCollateralParamIsInvalid() public {
        // Zero address
        vm.expectRevert(abi.encodeWithSelector(Validator.Validator__InvalidAddress.selector, address(0)));
        sfEngine.depositCollateralAndMintSFToken(address(0), 1 ether, 1 ether);
        // Zero amount of collateral
        vm.expectRevert(abi.encodeWithSelector(Validator.Validator__ValueCanNotBeZero.selector, 0));
        sfEngine.depositCollateralAndMintSFToken(address(1), 0 ether, 1 ether);
        // Zero amount of sf to mint
        vm.expectRevert(abi.encodeWithSelector(Validator.Validator__ValueCanNotBeZero.selector, 0));
        sfEngine.depositCollateralAndMintSFToken(address(1), 1 ether, 0);
        // Unsupported token
        ERC20Mock token = new ERC20Mock("TEST", "TEST", msg.sender, 10);
        vm.expectRevert(abi.encodeWithSelector(SFEngine.SFEngine__TokenNotSupported.selector, address(token)));
        sfEngine.depositCollateralAndMintSFToken(address(token), 1 ether, 1 ether);
    }

    function test_RevertWhen_CollateralRatioIsBroken() public {
        // This assumes the collateral ratio is 1, eg. 100$ collateral => 100$ sf
        uint256 amountCollateral = 1 ether;
        uint256 amountToMint = sfEngine.getTokenValueInUsd(deployConfig.wethTokenAddress, amountCollateral);
        uint256 collateralRatio = 1 * PRECISION_FACTOR;
        IERC20 weth = IERC20(deployConfig.wethTokenAddress);
        vm.prank(address(deployer));
        weth.transfer(user, amountCollateral);
        vm.startPrank(user);
        weth.approve(address(sfEngine), amountCollateral);
        vm.expectRevert(
            abi.encodeWithSelector(SFEngine.SFEngine__CollateralRatioIsBroken.selector, user, collateralRatio)
        );
        sfEngine.depositCollateralAndMintSFToken(address(weth), amountCollateral, amountToMint);
    }

    function testDepositWithEnoughCollateral() public {
        // Arrange data
        IERC20 weth = IERC20(deployConfig.wethTokenAddress);
        uint256 amountCollateral = 2 ether;
        uint256 collateralValueInUsd = sfEngine.getTokenValueInUsd(address(weth), amountCollateral);
        uint256 amountToMint = (collateralValueInUsd * PRECISION) / sfEngine.getMinimumCollateralRatio();
        vm.startPrank(user);
        weth.approve(address(sfEngine), amountCollateral);
        // weth
        uint256 startingUserWethBalance = weth.balanceOf(user);
        uint256 startingEngineWethBalance = weth.balanceOf(address(sfEngine));
        uint256 startingUserAmountCollateral = sfEngine.getCollateralAmount(user, address(weth));
        // sf
        uint256 startingUserSFBalance = sfToken.balanceOf(user);
        // Expected events
        vm.expectEmit(true, true, true, false);
        emit SFEngine__CollateralDeposited(user, address(weth), amountCollateral);
        vm.expectEmit(true, true, true, false);
        emit SFEngine__SFTokenMinted(user, amountToMint);
        // Act
        sfEngine.depositCollateralAndMintSFToken(address(weth), amountCollateral, amountToMint);
        // Assert
        // Check weth
        uint256 endingUserWethBalance = weth.balanceOf(user);
        uint256 endingEngineWethBalance = weth.balanceOf(address(sfEngine));
        uint256 endingUserAmountCollateral = sfEngine.getCollateralAmount(user, address(weth));
        assertEq(endingUserWethBalance, startingUserWethBalance - amountCollateral);
        assertEq(endingEngineWethBalance, startingEngineWethBalance + amountCollateral);
        assertEq(endingUserAmountCollateral, startingUserAmountCollateral + amountCollateral);
        // Check sf
        uint256 endingUserSFBalance = sfToken.balanceOf(user);
        assertEq(endingUserSFBalance, startingUserSFBalance + amountToMint);
    }

    function test_RevertWhen_RedeemAmountExceedsDeposited() 
        public 
        depositedCollateral(deployConfig.wethTokenAddress, DEFAULT_COLLATERAL_RATIO) 
    {
        vm.startPrank(user);
        uint256 amountDeposited = sfEngine.getCollateralAmount(user, deployConfig.wethTokenAddress);
        uint256 amountToMint =
            getAmountSFToMint(deployConfig.wethTokenAddress, DEFAULT_AMOUNT_COLLATERAL, DEFAULT_COLLATERAL_RATIO);
        vm.expectRevert(
            abi.encodeWithSelector(SFEngine.SFEngine__AmountToRedeemExceedsDeposited.selector, amountDeposited)
        );
        sfEngine.redeemCollateral(
            deployConfig.wethTokenAddress, DEFAULT_AMOUNT_COLLATERAL + 1 ether, amountToMint
        );
    }

    function test_RevertWhen_AmountSFToBurnExceedsUserBalance()
        public
        depositedCollateral(deployConfig.wethTokenAddress, DEFAULT_COLLATERAL_RATIO)
    {
        // Burn all tokens from user
        vm.startPrank(address(sfEngine));
        sfToken.burn(user, sfToken.balanceOf(user));
        vm.stopPrank();
        // Try to redeem, expect to revert
        vm.startPrank(user);
        vm.expectRevert(
            abi.encodeWithSelector(SFEngine.SFEngine__InsufficientBalance.selector, sfToken.balanceOf(user))
        );
        sfEngine.redeemCollateral(deployConfig.wethTokenAddress, DEFAULT_AMOUNT_COLLATERAL, INITIAL_BALANCE);
    }

    function test_RevertWhen_RedeemBreaksCollateralRatio() 
        public 
        depositedCollateral(deployConfig.wethTokenAddress, DEFAULT_COLLATERAL_RATIO) 
    {
        uint256 amountCollateralToRedeem = DEFAULT_AMOUNT_COLLATERAL / 2;
        console2.log("amountCollateralToRedeem:", amountCollateralToRedeem);
        uint256 amountCollateralLeft =
            sfEngine.getCollateralAmount(user, deployConfig.wethTokenAddress) - amountCollateralToRedeem;
        console2.log("amountCollateralLeft:", amountCollateralLeft);
        // Maximum amount of sf the user can hold after collateral is redeemed
        uint256 maximumAmountSFToHold =
            getAmountSFToMint(deployConfig.wethTokenAddress, amountCollateralLeft, DEFAULT_COLLATERAL_RATIO);
        console2.log("maximumAmountSFToHold:", maximumAmountSFToHold);
        // The minimum amount of sf that it is supposed to burn to maintain the collateral ratio
        uint256 minimumAmountSFToBurn = sfEngine.getSFDebt(user) - maximumAmountSFToHold;
        console2.log("minimumAmountSFToBurn:", minimumAmountSFToBurn);
        // Burn half of the minimum amount of sf
        uint256 amountSFToBurn = minimumAmountSFToBurn / 2;
        console2.log("amountSFToBurn:", amountSFToBurn);
        // Calculate expected collateral ratio after redeem
        uint256 amountSFLeft = sfEngine.getSFDebt(user) - amountSFToBurn;
        console2.log("amountSFLeft:", amountSFLeft);
        uint256 amountCollateralLeftInUsd =
            sfEngine.getTokenValueInUsd(deployConfig.wethTokenAddress, amountCollateralLeft);
        console2.log("amountCollateralLeftInUsd:", amountCollateralLeftInUsd);
        uint256 expectedCollateralRatioAfterRedeem = (amountCollateralLeftInUsd * PRECISION_FACTOR) / amountSFLeft;
        console2.log("expectedCollateralRatioAfterRedeem:", expectedCollateralRatioAfterRedeem);
        vm.startPrank(user);
        sfToken.approve(address(sfEngine), amountSFToBurn);
        vm.expectRevert(
            abi.encodeWithSelector(
                SFEngine.SFEngine__CollateralRatioIsBroken.selector, user, expectedCollateralRatioAfterRedeem
            )
        );
        sfEngine.redeemCollateral(deployConfig.wethTokenAddress, amountCollateralToRedeem, amountSFToBurn);
    }

    function testRedeemCollateral() public depositedCollateral(deployConfig.wethTokenAddress, DEFAULT_COLLATERAL_RATIO) {
        IERC20 weth = IERC20(deployConfig.wethTokenAddress);
        // Starting balance
        uint256 startingUserWethBalance = weth.balanceOf(user);
        uint256 startingUserSFBalance = sfToken.balanceOf(user);
        uint256 startingEngineWethBalance = weth.balanceOf(address(sfEngine));

        // Starting data
        uint256 startingAmountDeposited = sfEngine.getCollateralAmount(user, address(weth));
        uint256 startingAmountMinted = sfEngine.getSFDebt(user);

        // Prepare redeem data
        uint256 amountCollateralToRedeem = DEFAULT_AMOUNT_COLLATERAL / 2;
        console2.log("amountCollateralToRedeem:", amountCollateralToRedeem);
        uint256 amountCollateralLeft =
            sfEngine.getCollateralAmount(user, deployConfig.wethTokenAddress) - amountCollateralToRedeem;
        console2.log("amountCollateralLeft:", amountCollateralLeft);
        // Maximum amount of sf the user can hold after collateral is redeemed
        uint256 maximumAmountSFToHold =
            getAmountSFToMint(deployConfig.wethTokenAddress, amountCollateralLeft, DEFAULT_COLLATERAL_RATIO);
        console2.log("maximumAmountSFToHold:", maximumAmountSFToHold);
        // The minimum amount of sf that it is supposed to burn to maintain the collateral ratio
        uint256 minimumAmountSFToBurn = sfEngine.getSFDebt(user) - maximumAmountSFToHold;
        console2.log("minimumAmountSFToBurn:", minimumAmountSFToBurn);
        // Calculate expected collateral ratio after redeem
        uint256 amountSFLeft = sfEngine.getSFDebt(user) - minimumAmountSFToBurn;
        console2.log("amountSFLeft:", amountSFLeft);
        uint256 amountCollateralLeftInUsd =
            sfEngine.getTokenValueInUsd(deployConfig.wethTokenAddress, amountCollateralLeft);
        console2.log("amountCollateralLeftInUsd:", amountCollateralLeftInUsd);
        uint256 expectedCollateralRatioAfterRedeem = (amountCollateralLeftInUsd * PRECISION_FACTOR) / amountSFLeft;
        console2.log("expectedCollateralRatioAfterRedeem:", expectedCollateralRatioAfterRedeem);
        vm.startPrank(user);
        sfToken.approve(address(sfEngine), minimumAmountSFToBurn);

        // Redeem
        sfEngine.redeemCollateral(
            deployConfig.wethTokenAddress, amountCollateralToRedeem, minimumAmountSFToBurn
        );

        // Ending balance
        uint256 endingUserWethBalance = weth.balanceOf(user);
        uint256 endingUserSFBalance = sfToken.balanceOf(user);
        uint256 endingEngineWethBalance = weth.balanceOf(address(sfEngine));

        // Ending data
        uint256 endingAmountDeposited = sfEngine.getCollateralAmount(user, address(weth));
        uint256 endingAmountMinted = sfEngine.getSFDebt(user);

        // Check balance
        assertEq(endingUserWethBalance, startingUserWethBalance + amountCollateralToRedeem);
        assertEq(endingUserSFBalance, startingUserSFBalance - minimumAmountSFToBurn);
        assertEq(endingEngineWethBalance, startingEngineWethBalance - amountCollateralToRedeem);

        // Check data
        assertEq(endingAmountDeposited, startingAmountDeposited - amountCollateralToRedeem);
        assertEq(endingAmountMinted, startingAmountMinted - minimumAmountSFToBurn);
    }

    function test_RevertWhen_LiquidateWhenUserCollateralRatioIsNotBroken()
        public
        depositedCollateral(deployConfig.wethTokenAddress, DEFAULT_COLLATERAL_RATIO)
    {
        // Mint some token to liquidator
        address liquidator = makeAddr("liquidator");
        vm.prank(address(sfEngine));
        sfToken.mint(liquidator, INITIAL_BALANCE);
        vm.startPrank(liquidator);
        sfToken.approve(address(sfEngine), INITIAL_BALANCE);
        // Liquidate user's collateral, this will revert no matter how much debt we are going to cover
        vm.expectRevert(
            abi.encodeWithSelector(
                SFEngine.SFEngine__CollateralRatioIsNotBroken.selector, user, sfEngine.getCollateralRatio(user)
            )
        );
        sfEngine.liquidate(user, deployConfig.wethTokenAddress, 1000 ether);
    }

    function test_LiquidateWhen_DebtToCoverLessThanUserCollateral() 
        public 
        depositedCollateral(deployConfig.wethTokenAddress, DEFAULT_COLLATERAL_RATIO) 
    {
        ERC20Mock weth = ERC20Mock(deployConfig.wethTokenAddress);
        address liquidator = makeAddr("liquidator");
        uint256 debtToCover = 300 ether;
        weth.mint(liquidator, LIQUIDATOR_DEPOSIT_AMOUNT);
        // Deposit enough eth to protocol to make sure liquidation won't break liquidator's collateral ratio
        vm.startPrank(liquidator);
        weth.approve(address(sfEngine), LIQUIDATOR_DEPOSIT_AMOUNT);
        sfEngine.depositCollateralAndMintSFToken(
            deployConfig.wethTokenAddress, 
            LIQUIDATOR_DEPOSIT_AMOUNT, 
            sfEngine.getSFDebt(user)
        );

        // Starting balance
        uint256 startingLiquidatorWethBalance = weth.balanceOf(liquidator);
        uint256 startingLiquidatorSFBalance = sfToken.balanceOf(liquidator);
        uint256 startingEngineWethBalance = weth.balanceOf(address(sfEngine));

        // Starting data
        uint256 startingUserAmountMinted = sfEngine.getSFDebt(user);
        uint256 startingUserAmountDeposited = sfEngine.getCollateralAmount(user, address(weth));
        uint256 startingLiquidatorAmountDeposited = sfEngine.getCollateralAmount(liquidator, address(weth));

        sfToken.approve(address(sfEngine), debtToCover);
        // Adjust weth / usd price to 1900$, this will break the collateral ratio, but liquidator can
        // only liquidate a small amount of collateral to make the collateral ratio back to normal
        MockV3Aggregator wethPriceFeed = MockV3Aggregator(deployConfig.wethPriceFeedAddress);
        wethPriceFeed.updateAnswer(int256(1900 * (10 ** PRICE_FEED_DECIMALS)));

        // Liquidate
        sfEngine.liquidate(user, address(weth), debtToCover);
        vm.stopPrank();

        // Ending balance
        uint256 endingLiquidatorWethBalance = weth.balanceOf(liquidator);
        uint256 endingLiquidatorSFBalance = sfToken.balanceOf(liquidator);
        uint256 endingEngineWethBalance = weth.balanceOf(address(sfEngine));

        // Ending data
        uint256 endingUserAmountDeposited = sfEngine.getCollateralAmount(user, address(weth));
        uint256 endingLiquidatorAmountDeposited = sfEngine.getCollateralAmount(liquidator, address(weth));
        uint256 endingUserAmountMinted = sfEngine.getSFDebt(user);

        // Check balance
        uint256 amountCollateralToLiquidate = sfEngine.getTokenAmountFromUsd(deployConfig.wethTokenAddress, debtToCover);
        uint256 bonus = amountCollateralToLiquidate * (10 ** (PRECISION - 1)) / PRECISION_FACTOR;
        uint256 amountCollateralLiquidatorReceived = amountCollateralToLiquidate + bonus;
        assertEq(endingLiquidatorWethBalance, startingLiquidatorWethBalance + amountCollateralLiquidatorReceived);
        assertEq(endingLiquidatorSFBalance, startingLiquidatorSFBalance - debtToCover);
        assertEq(endingEngineWethBalance, startingEngineWethBalance - amountCollateralLiquidatorReceived);

        // Check data
        assertEq(endingUserAmountDeposited, startingUserAmountDeposited - amountCollateralLiquidatorReceived);
        assertEq(endingLiquidatorAmountDeposited, startingLiquidatorAmountDeposited);
        assertEq(endingUserAmountMinted, startingUserAmountMinted - debtToCover);
    }

    function test_LiquidateWhen_DebtToCoverExceedsUserCollateral() 
        public 
        depositedCollateral(deployConfig.wethTokenAddress, DEFAULT_COLLATERAL_RATIO) 
    {
        ERC20Mock weth = ERC20Mock(deployConfig.wethTokenAddress);
        address liquidator = makeAddr("liquidator");
        uint256 debtToCover = sfEngine.getSFDebt(user);
        weth.mint(liquidator, LIQUIDATOR_DEPOSIT_AMOUNT);
        // Deposit enough eth to protocol to make sure liquidation won't break liquidator's collateral ratio
        vm.startPrank(liquidator);
        weth.approve(address(sfEngine), debtToCover);
        sfEngine.depositCollateralAndMintSFToken(
            deployConfig.wethTokenAddress, 
            LIQUIDATOR_DEPOSIT_AMOUNT, 
            sfEngine.getSFDebt(user)
        );

        // Starting balance
        uint256 startingLiquidatorWethBalance = weth.balanceOf(liquidator);
        uint256 startingLiquidatorSFBalance = sfToken.balanceOf(liquidator);
        uint256 startingEngineWethBalance = weth.balanceOf(address(sfEngine));

        // Starting data
        uint256 startingUserAmountDeposited = sfEngine.getCollateralAmount(user, address(weth));
        uint256 startingLiquidatorAmountDeposited = sfEngine.getCollateralAmount(liquidator, address(weth));

        sfToken.approve(address(sfEngine), debtToCover);
        // Adjust weth / usd price to 1000$, this will break the collateral ratio, and collateral
        // cant't cover (debt + bonus), liquidator will get all the collaterals by burning
        // (debtToCover - bonus) amount of SF token
        MockV3Aggregator wethPriceFeed = MockV3Aggregator(deployConfig.wethPriceFeedAddress);
        wethPriceFeed.updateAnswer(int256(1000 * (10 ** PRICE_FEED_DECIMALS)));

        // Liquidate
        sfEngine.liquidate(user, address(weth), debtToCover);
        vm.stopPrank();

        // Ending balance
        uint256 endingLiquidatorWethBalance = weth.balanceOf(liquidator);
        uint256 endingLiquidatorSFBalance = sfToken.balanceOf(liquidator);
        uint256 endingEngineWethBalance = weth.balanceOf(address(sfEngine));

        // Ending data
        uint256 endingUserAmountDeposited = sfEngine.getCollateralAmount(user, address(weth));
        uint256 endingLiquidatorAmountDeposited = sfEngine.getCollateralAmount(liquidator, address(weth));
        uint256 endingUserAmountMinted = sfEngine.getSFDebt(user);

        // Check balance
        uint256 amountCollateralToLiquidate = sfEngine.getTokenAmountFromUsd(deployConfig.wethTokenAddress, debtToCover);
        uint256 bonus = amountCollateralToLiquidate * (10 ** (PRECISION - 1)) / PRECISION_FACTOR;
        uint256 bonusInSFToken = sfEngine.getTokenValueInUsd(deployConfig.wethTokenAddress, bonus);
        assertEq(endingLiquidatorWethBalance, startingLiquidatorWethBalance + startingUserAmountDeposited);
        assertEq(endingLiquidatorSFBalance, startingLiquidatorSFBalance - debtToCover + bonusInSFToken);
        assertEq(endingEngineWethBalance, startingEngineWethBalance - startingUserAmountDeposited);

        // Check data
        assertEq(endingUserAmountDeposited, 0);
        assertEq(endingLiquidatorAmountDeposited, startingLiquidatorAmountDeposited);
        assertEq(endingUserAmountMinted, 0);
    }

    function getAmountSFToMint(address collateralTokenAddress, uint256 amountCollateral, uint256 collateralRatio)
        private
        view
        returns (uint256)
    {
        uint256 tokenValueInUsd = sfEngine.getTokenValueInUsd(collateralTokenAddress, amountCollateral);
        return (tokenValueInUsd * PRECISION_FACTOR) / collateralRatio;
    }

    function adjustNumberByPrecision(uint256 number, uint256 decimals, uint256 precision)
        private
        pure
        returns (uint256)
    {
        return number * 10 ** (precision - decimals);
    }

    function testS() public {
        bytes32 b = keccak256(abi.encode(uint256(keccak256("stableflow.storage.SocialRecoveryPlugin")) - 1)) & ~bytes32(uint256(0xff));
        console2.logBytes32(b);
    }
}
