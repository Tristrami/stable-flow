// SPDX-License-Identifier: MIT
pragma solidity ^0.8.30;

import {Vm} from "forge-std/Vm.sol";

library Logs {

    function findRecordedLog(Vm vm, string memory eventSignature) internal returns (Vm.Log memory log) {
        Vm.Log[] memory logs = vm.getRecordedLogs();
        for (uint256 i = 0; i < logs.length; i++) {
            if (keccak256(bytes(eventSignature)) == logs[i].topics[0]) {
                return logs[i];
            }
        }
    }
}