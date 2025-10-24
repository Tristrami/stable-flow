// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Vm} from "forge-std/Vm.sol";

/**
 * @title Logs
 * @dev Utility library for working with recorded transaction logs
 * @notice Provides functions to filter and find specific event logs from recorded transactions
 */
library Logs {
    /**
     * @dev Finds the first recorded log matching a specific event signature
     * @param vm Forge VM instance for log access
     * @param eventSignature The event signature to match (e.g. "Transfer(address,address,uint256)")
     * @return log The first matching Vm.Log struct containing:
     *   - topics: Array of topic hashes (indexed event parameters)
     *   - data: Non-indexed event data
     * @notice Returns empty log if no match found
     * @notice Uses exact signature matching (must include parameter types)
     * Example:
     * ```solidity
     * Vm.Log memory transferLog = Logs.findRecordedLog(vm, "Transfer(address,address,uint256)");
     * ```
     */
    function findRecordedLog(Vm vm, string memory eventSignature) 
        internal 
        returns (Vm.Log memory log) 
    {
        Vm.Log[] memory logs = vm.getRecordedLogs();
        bytes32 eventSigHash = keccak256(bytes(eventSignature));
        for (uint256 i = 0; i < logs.length; i++) {
            if (eventSigHash == logs[i].topics[0]) {
                return logs[i];
            }
        }
        return log; // returns empty log if not found
    }

    /**
     * @dev Finds all recorded logs matching a specific event signature
     * @param vm Forge VM instance for log access
     * @param eventSignature The event signature to match (e.g. "Transfer(address,address,uint256)")
     * @return logs Array of matching Vm.Log structs containing:
     *   - topics: Array of topic hashes (indexed event parameters)
     *   - data: Non-indexed event data
     * @notice Returns empty array if no matches found
     * @notice Uses exact signature matching (must include parameter types)
     * Example:
     * ```solidity
     * Vm.Log[] memory allTransfers = Logs.findRecordedLogs(vm, "Transfer(address,address,uint256)");
     * ```
     */
    function findRecordedLogs(Vm vm, string memory eventSignature) 
        internal  
        returns (Vm.Log[] memory logs) 
    {
        bytes32 eventSigHash = keccak256(bytes(eventSignature));
        Vm.Log[] memory recordedLogs = vm.getRecordedLogs();
        
        // First pass to count matches
        uint256 matchCount;
        for (uint256 i = 0; i < recordedLogs.length; i++) {
            if (eventSigHash == recordedLogs[i].topics[0]) {
                matchCount++;
            }
        }

        // Second pass to populate results
        logs = new Vm.Log[](matchCount);
        uint256 resultIndex;
        for (uint256 i = 0; i < recordedLogs.length; i++) {
            if (eventSigHash == recordedLogs[i].topics[0]) {
                logs[resultIndex] = recordedLogs[i];
                resultIndex++;
            }
        }
        return logs;
    }
}