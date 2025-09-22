// SPDX-License-Identifier: MIT
pragma solidity ^0.8.30;

import {Test} from "forge-std/Test.sol";
import {SFEngine} from "../../../src/token/SFEngine.sol";
import {SFToken} from "../../../src/token/SFToken.sol";
import {ERC20Mock} from "../../../test/mocks/ERC20Mock.sol";

contract ContinueOnRevertHandler is Test {

    SFEngine private sfEngine;
    SFToken private sfToken;
    address[] private tokenAddresses;
    address[] private userDeposited;

    constructor(SFEngine _sfEngine, SFToken _sfToken) {
        sfEngine = _sfEngine;
        sfToken = _sfToken;
        tokenAddresses = sfEngine.getCollateralTokenAddresses();
    }

    function deposit(uint8 collateralTokenAddressSeed, uint96 amountCollateral, uint96 amountSFToMint) public {
        bound(amountCollateral, 1, type(uint96).max);
        bound(amountSFToMint, 1, type(uint96).max);
        address tokenAddress = pickRandomAddress(tokenAddresses, collateralTokenAddressSeed);
        ERC20Mock token = ERC20Mock(tokenAddress);
        token.mint(msg.sender, amountCollateral);
        // The sender will be this handler contract if without prank
        vm.startPrank(msg.sender);
        token.approve(address(sfEngine), amountCollateral);
        sfEngine.depositCollateralAndMintSFToken(tokenAddress, amountCollateral, amountSFToMint);
        userDeposited.push(msg.sender);
    }

    function redeem(
        uint8 collateralTokenAddressSeed,
        uint8 userSeed,
        uint96 amountCollateralToRedeem,
        uint96 amountSFToBurn
    ) public {
        address user = pickRandomAddress(userDeposited, userSeed);
        vm.assume(user != address(0));
        address tokenAddress = pickRandomAddress(tokenAddresses, collateralTokenAddressSeed);
        uint256 amountDeposited = sfEngine.getCollateralAmount(user, tokenAddress);
        vm.assume(amountDeposited > 0);
        uint256 sfBalance = sfToken.balanceOf(user);
        vm.assume(sfBalance > 0);
        uint256 collateralInUsd = sfEngine.getTokenValueInUsd(tokenAddress, amountCollateralToRedeem);
        bound(amountCollateralToRedeem, 1, amountDeposited);
        bound(amountSFToBurn, collateralInUsd, sfBalance);
        vm.prank(user);
        sfEngine.redeemCollateral(tokenAddress, amountCollateralToRedeem, amountSFToBurn);
    }

    function liquidate(uint8 userSeed, uint8 collateralTokenAddressSeed, uint256 debtToCover) public {
        address user = pickRandomAddress(userDeposited, userSeed);
        vm.assume(user != address(0));
        address tokenAddress = pickRandomAddress(tokenAddresses, collateralTokenAddressSeed);
        uint256 sfMinted = sfEngine.getSFTokenMinted(user);
        vm.assume(sfMinted > 0);
        bound(debtToCover, 1, sfMinted);
        sfEngine.liquidate(user, tokenAddress, debtToCover);
    }

    function pickRandomAddress(address[] memory addresses, uint8 seed) private pure returns (address) {
        return addresses.length == 0 ? address(0) : addresses[seed % addresses.length];
    }
}
