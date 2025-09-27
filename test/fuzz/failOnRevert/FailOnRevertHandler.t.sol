// SPDX-License-Identifier: MIT
pragma solidity ^0.8.30;

import {SFEngine} from "../../../src/token/SFEngine.sol";
import {Test} from "forge-std/Test.sol";

/**
 * @dev Test all the getter functions, make sure they won't revert no matter what input parameters are given
 * @notice You should set ** fail_on_revert = true ** in foundry.toml before testing
 * @notice All functions to fuzz should be public, not be view or pure, and shouldn't return anything
 */
contract FailOnRevertHandler is Test {
    SFEngine private sfEngine;

    constructor(SFEngine _sfEngine) {
        sfEngine = _sfEngine;
    }

    function getMinimumCollateralRatio() public {
        sfEngine.getMinimumCollateralRatio();
    }

    function getCollateralAmount(address user, address collateralTokenAddress) public {
        sfEngine.getCollateralAmount(user, collateralTokenAddress);
    }

    function getSFDebt(address user) public {
        sfEngine.getSFDebt(user);
    }

    function getSFTokenAddress() public {
        sfEngine.getSFTokenAddress();
    }

    function getSupportedCollaterals() public {
        sfEngine.getSupportedCollaterals();
    }
}
