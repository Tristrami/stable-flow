// SPDX-License-Identifier: MIT
pragma solidity ^0.8.30;

import {IERC20} from "@openzeppelin/contracts/token/erc20/IERC20.sol";
import {ContinueOnRevertHandler} from "./ContinueOnRevertHandler.t.sol";
import {BaseTest} from "../../BaseTest.t.sol";

contract ContinueOnRevertInvariants is BaseTest {
    function setUp() external {
        super._setUp();
        ContinueOnRevertHandler handler = new ContinueOnRevertHandler(sfEngine, sfToken);
        targetContract(address(handler));
    }

    function invariant_CollateralAlwaysExceedsMintedToken() public view {
        IERC20 weth = IERC20(deployConfig.wethTokenAddress);
        IERC20 wbtc = IERC20(deployConfig.wbtcTokenAddress);
        uint256 totalDepositedWethInUsd =
            sfEngine.getTokenValueInUsd(address(weth), weth.balanceOf(address(sfEngine)));
        uint256 totalDepositedWbtcInUsd =
            sfEngine.getTokenValueInUsd(address(wbtc), wbtc.balanceOf(address(sfEngine)));
        uint256 totalAmountSFMinted = sfToken.totalSupply();
        assert(totalDepositedWethInUsd + totalDepositedWbtcInUsd >= totalAmountSFMinted);
    }
}
