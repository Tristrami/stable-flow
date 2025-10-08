// SPDX-License-Identifier: MIT
pragma solidity ^0.8.30;

/**
 * AutomationRegistrar2_1
 */
interface AutomationRegistrarInterface {

    struct RegistrationParams {
        string name;
        bytes encryptedEmail;
        address upkeepContract;
        uint32 gasLimit;
        address adminAddress;
        uint8 triggerType;
        bytes checkData;
        bytes triggerConfig;
        bytes offchainConfig;
        uint96 amount;
    }

    enum TriggerType {
        CONDITIONAL_TRIGGERED,
        LOG_TRIGGERED
    }

    function registerUpkeep(
        RegistrationParams calldata requestParams
    ) external returns (uint256);
}