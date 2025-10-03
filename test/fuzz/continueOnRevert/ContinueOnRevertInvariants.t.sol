// SPDX-License-Identifier: MIT
pragma solidity ^0.8.30;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {ContinueOnRevertHandler} from "./ContinueOnRevertHandler.t.sol";
import {BaseTest} from "../../BaseTest.t.sol";
import {OracleLib, AggregatorV3Interface} from "../../../src/libraries/OracleLib.sol";

contract ContinueOnRevertInvariants is BaseTest {

    using OracleLib for AggregatorV3Interface;

    function setUp() external {
        super._setUp();
        ContinueOnRevertHandler handler = new ContinueOnRevertHandler(sfEngine, sfToken);
        targetContract(address(handler));
    }

    function invariant_CollateralAlwaysExceedsMintedToken() public view {
        IERC20 weth = IERC20(deployConfig.wethTokenAddress);
        IERC20 wbtc = IERC20(deployConfig.wbtcTokenAddress);
        uint256 totalDepositedWethInUsd = AggregatorV3Interface(deployConfig.wethPriceFeedAddress)
            .getTokenValue(weth.balanceOf(address(sfEngine)));
        uint256 totalDepositedWbtcInUsd = AggregatorV3Interface(deployConfig.wbtcPriceFeedAddress)
            .getTokenValue(wbtc.balanceOf(address(sfEngine)));
        uint256 totalAmountSFMinted = sfToken.totalSupply();
        assert(totalDepositedWethInUsd + totalDepositedWbtcInUsd >= totalAmountSFMinted);
    }
}
