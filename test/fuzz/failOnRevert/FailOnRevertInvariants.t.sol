// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {BaseTest} from "../../BaseTest.t.sol";
import {FailOnRevertHandler} from "./FailOnRevertHandler.t.sol";

contract FailOnRevertInvariants is BaseTest {
    function setUp() external {
        super._setUp();
        FailOnRevertHandler handler = new FailOnRevertHandler(sfEngine);
        targetContract(address(handler));
    }

    function invariant_GetterFunctionsCantRevert() public pure {
        // Do nothing, just make sure all the getter functions won't revert
        assert(true);
    }
}
