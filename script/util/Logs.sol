// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

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

    function findRecordedLogs(Vm vm, string memory eventSignature) internal returns (Vm.Log[] memory logs) {
        uint256 matchedLogs;
        bytes32 eventSignatureHash = keccak256(bytes(eventSignature));
        Vm.Log[] memory recordedLogs = vm.getRecordedLogs();
        for (uint256 i = 0; i < recordedLogs.length; i++) {
            if (eventSignatureHash == recordedLogs[i].topics[0]) {
                matchedLogs++;
            }
        }
        logs = new Vm.Log[](matchedLogs);
        uint256 index;
        for (uint256 i = 0; i < recordedLogs.length; i++) {
            if (eventSignatureHash == recordedLogs[i].topics[0]) {
                logs[index] = recordedLogs[i];
                index++;
            }
        }
    }
}