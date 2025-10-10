// SPDX-License-Identifier: MIT
pragma solidity ^0.8.30;

import {AutomationRegistrarInterface} from "../../src/interfaces/AutomationRegistrarInterface.sol";

contract MockAutomationRegistrar is AutomationRegistrarInterface {

    error InvalidAdminAddress();

    event RegistrationRequested(
        bytes32 indexed hash,
        string name,
        bytes encryptedEmail,
        address indexed upkeepContract,
        uint32 gasLimit,
        address adminAddress,
        uint8 triggerType,
        bytes triggerConfig,
        bytes offchainConfig,
        bytes checkData,
        uint96 amount
    );

    function registerUpkeep(
        RegistrationParams memory requestParams
    ) external returns (uint256) {

        if (requestParams.adminAddress == address(0)) {
        revert InvalidAdminAddress();
        }

        bytes32 hash = keccak256(
            abi.encode(
                requestParams.upkeepContract,
                requestParams.gasLimit,
                requestParams.adminAddress,
                requestParams.triggerType,
                requestParams.checkData,
                requestParams.triggerConfig,
                requestParams.offchainConfig
            )
        );

        emit RegistrationRequested(
            hash,
            requestParams.name,
            requestParams.encryptedEmail,
            requestParams.upkeepContract,
            requestParams.gasLimit,
            requestParams.adminAddress,
            requestParams.triggerType,
            requestParams.triggerConfig,
            requestParams.offchainConfig,
            requestParams.checkData,
            requestParams.amount
        );
        return 0;
    }

}