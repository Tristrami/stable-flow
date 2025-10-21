// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test, console2} from "forge-std/Test.sol";
import {DeployHelper} from "../../script/util/DeployHelper.sol";
import {ISFBridge} from "../../src/interfaces/ISFBridge.sol";
import {SFBridge} from "../../src/bridge/SFBridge.sol";
import {SFToken} from "../../src/token/SFToken.sol";
import {SFTokenPool} from "../../src/token/SFTokenPool.sol";
import {DeployOnMainChain} from "../../script/DeployOnMainChain.s.sol";
import {DeployOnOtherChain} from "../../script/DeployOnOtherChain.s.sol";
import {ConfigureTokenPool} from "../../script/ConfigureTokenPool.s.sol";
import {Constants} from "../../script/util/Constants.sol";
import {CCIPLocalSimulatorFork, Register} from "@chainlink/local/src/ccip/CCIPLocalSimulatorFork.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

contract SFBridgeTest is Test, Constants {

    struct TestData {
        SFToken sfToken;
        SFTokenPool sfTokenPool;
        SFBridge sfBridge;
        CCIPLocalSimulatorFork ccip;
        DeployHelper.DeployConfig deployConfig;
    }

    uint256 private constant SF_BALANCE = 100 * PRECISION_FACTOR;
    address private user = makeAddr("user");
    uint256 private ethSepoliaForkId;
    uint256 private avaFujiForkId;
    TestData private ethSepoliaData;
    TestData private avaFujiData;
    TestData private $;

    function setUp() external {
        _setUpEthSepolia();
        _setUpAvaFuji();
        _configureEthSepoliaTokenPool();
        _configureAvaFujiTokenPool();
        _mintSFTokenToUser();
    }

    function test_RevertWhen_BridgeTokenToNotSupportedChain() public {
        _selectEthSepoliaFork();
        vm.expectRevert(ISFBridge.ISFBridge__ChainNotSupported.selector);
        $.sfBridge.bridgeSFToken(1, user, 1 * PRECISION_FACTOR);
    }

    function test_RevertWhen_BridgeTokenToCurrentChain() public {
        _selectEthSepoliaFork();
        vm.expectRevert(ISFBridge.ISFBridge__DestinationChainIdCanNotBeCurrentChainId.selector);
        $.sfBridge.bridgeSFToken(block.chainid, user, 1 * PRECISION_FACTOR);
    }

    function test_RevertWhen_ReceiverIsZeroAddress() public {
        _selectEthSepoliaFork();
        vm.expectRevert(ISFBridge.ISFBridge__InvalidReceiver.selector);
        $.sfBridge.bridgeSFToken(AVA_FUJI_CHAIN_ID, address(0), 1 * PRECISION_FACTOR);
    }

    function test_RevertWhen_AmountIsZero() public {
        _selectEthSepoliaFork();
        vm.expectRevert(ISFBridge.ISFBridge__TokenAmountCanNotBeZero.selector);
        $.sfBridge.bridgeSFToken(AVA_FUJI_CHAIN_ID, user, 0);
    }

    function testBridgeTokenFromSepoliaToFuji() public {
        _selectEthSepoliaFork();
        uint256 amountToBridge = 1 * PRECISION_FACTOR;
        uint256 startingSepoliaUserBalance = $.sfToken.balanceOf(user);
        uint256 startingSepoliaPoolBalance = $.sfToken.balanceOf(address($.sfTokenPool));

        vm.startPrank(user);
        address linkToken = $.deployConfig.linkTokenAddress;
        uint256 feeInLink = $.sfBridge.getFee(AVA_FUJI_CHAIN_ID, user, amountToBridge);
        $.ccip.requestLinkFromFaucet(user, feeInLink);
        IERC20(linkToken).approve(address($.sfBridge), feeInLink);
        IERC20(address($.sfToken)).approve(address($.sfBridge), amountToBridge);
        $.sfBridge.bridgeSFToken(AVA_FUJI_CHAIN_ID, user, amountToBridge);
        vm.stopPrank();

        _selectAvaFujiFork();
        uint256 startingFujiUserBalance = $.sfToken.balanceOf(user);
        // Switch back to sepolia fork, or ccip.switchChainAndRouteMessage() won't work
        _selectEthSepoliaFork();
        $.ccip.switchChainAndRouteMessage(avaFujiForkId);
        // Call _selectAvaFujiFork() to change active test data
        _selectAvaFujiFork();
        assertEq($.sfToken.balanceOf(user), startingFujiUserBalance + amountToBridge);
        _selectEthSepoliaFork();
        assertEq($.sfToken.balanceOf(user), startingSepoliaUserBalance - amountToBridge);
        assertEq($.sfToken.balanceOf(address($.sfTokenPool)), startingSepoliaPoolBalance + amountToBridge);
    }

    function testBridgeTokenFromFujiToSepolia() public {
        uint256 amountToBridge = 1 * PRECISION_FACTOR;
        _bridgeFromSepoliaToFuji(user, amountToBridge);
        _selectAvaFujiFork();
        uint256 startingFujiUserBalance = $.sfToken.balanceOf(user);

        vm.startPrank(user);
        address linkToken = $.deployConfig.linkTokenAddress;
        uint256 feeInLink = $.sfBridge.getFee(ETH_SEPOLIA_CHAIN_ID, user, amountToBridge);
        $.ccip.requestLinkFromFaucet(user, feeInLink);
        IERC20(linkToken).approve(address($.sfBridge), feeInLink);
        IERC20(address($.sfToken)).approve(address($.sfBridge), amountToBridge);
        $.sfBridge.bridgeSFToken(ETH_SEPOLIA_CHAIN_ID, user, amountToBridge);
        vm.stopPrank();

        _selectEthSepoliaFork();
        uint256 startingSepoliaUserBalance = $.sfToken.balanceOf(user);
        uint256 startingSepoliaPoolBalance = $.sfToken.balanceOf(address($.sfTokenPool));
        // Switch back to fuji fork, or ccip.switchChainAndRouteMessage() won't work
        _selectAvaFujiFork();
        $.ccip.switchChainAndRouteMessage(ethSepoliaForkId);
        // Call _selectEthSepoliaFork() to change the active test data
        _selectEthSepoliaFork();
        assertEq($.sfToken.balanceOf(user), startingSepoliaUserBalance + amountToBridge);
        assertEq($.sfToken.balanceOf(address($.sfTokenPool)), startingSepoliaPoolBalance - amountToBridge);
        _selectAvaFujiFork();
        assertEq($.sfToken.balanceOf(user), startingFujiUserBalance - amountToBridge);
    }

    function _setUpEthSepolia() private {
        ethSepoliaForkId = vm.createSelectFork("ethSepolia");
        DeployOnMainChain deployer = new DeployOnMainChain();
        (
            address sfTokenAddress, ,
            address sfTokenPoolAddress,
            address sfBridgeAddress, , ,
            DeployHelper.DeployConfig memory deployConfig
        ) = deployer.deploy();
        ethSepoliaData.sfToken = SFToken(sfTokenAddress);
        ethSepoliaData.sfTokenPool = SFTokenPool(sfTokenPoolAddress);
        ethSepoliaData.sfBridge = SFBridge(sfBridgeAddress);
        ethSepoliaData.ccip = new CCIPLocalSimulatorFork();
        ethSepoliaData.deployConfig = deployConfig;
    }

    function _setUpAvaFuji() private {
        avaFujiForkId = vm.createSelectFork("avaFuji");
        DeployOnOtherChain deployer = new DeployOnOtherChain();
        (
            address sfTokenAddress,
            address sfTokenPoolAddress,
            address sfBridgeAddress,
            DeployHelper.DeployConfig memory deployConfig
        ) = deployer.deploy();
        avaFujiData.sfToken = SFToken(sfTokenAddress);
        avaFujiData.sfTokenPool = SFTokenPool(sfTokenPoolAddress);
        avaFujiData.sfBridge = SFBridge(sfBridgeAddress);
        avaFujiData.ccip = new CCIPLocalSimulatorFork();
        avaFujiData.deployConfig = deployConfig;
    }

    function _configureEthSepoliaTokenPool() private {
        vm.selectFork(ethSepoliaForkId);
        ConfigureTokenPool configurer = new ConfigureTokenPool();
        configurer.configure(
            address(ethSepoliaData.sfTokenPool),
            avaFujiData.deployConfig.chainSelector,
            address(avaFujiData.sfToken),
            true,
            address(avaFujiData.sfTokenPool)
        );
    }

    function _configureAvaFujiTokenPool() private {
        vm.selectFork(avaFujiForkId);
        ConfigureTokenPool configurer = new ConfigureTokenPool();
        configurer.configure(
            address(avaFujiData.sfTokenPool),
            ethSepoliaData.deployConfig.chainSelector,
            address(ethSepoliaData.sfToken),
            true,
            address(ethSepoliaData.sfTokenPool)
        );
    }

    function _mintSFTokenToUser() private {
        _selectEthSepoliaFork();
        vm.prank(address($.sfTokenPool));
        $.sfToken.mint(user, SF_BALANCE);
    }

    function _selectEthSepoliaFork() private {
        vm.selectFork(ethSepoliaForkId);
        $ = ethSepoliaData;
    }

    function _selectAvaFujiFork() private {
        vm.selectFork(avaFujiForkId);
        $ = avaFujiData;
    }

    function _bridgeFromSepoliaToFuji(address account, uint256 amount) private {
        _selectEthSepoliaFork();
        vm.startPrank(account);
        address linkToken = $.deployConfig.linkTokenAddress;
        uint256 feeInLink = $.sfBridge.getFee(AVA_FUJI_CHAIN_ID, account, amount);
        $.ccip.requestLinkFromFaucet(account, feeInLink);
        IERC20(linkToken).approve(address($.sfBridge), feeInLink);
        IERC20(address($.sfToken)).approve(address($.sfBridge), amount);
        $.sfBridge.bridgeSFToken(AVA_FUJI_CHAIN_ID, account, amount);
        vm.stopPrank();
        // Switch back to sepolia fork, or ccip.switchChainAndRouteMessage() won't work
        $.ccip.switchChainAndRouteMessage(avaFujiForkId);
    }

}