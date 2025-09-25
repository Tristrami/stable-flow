// SPDX-License-Identifier: MIT
pragma solidity ^0.8.30;

interface ISocialRecoveryPlugin {

    struct CustomRecoveryConfig {
        bool socialRecoveryEnabled; // Whether this account supports social recovery
        uint8 minGuardianApprovals; // Minimum amount of guardian approvals needed to recover the current account
        uint256 recoveryTimeLock; // Social recovery time lock, recovery can only be executed after a delay
        address[] guardians; // Guardian addresses for social recovery
    }

    struct RecoveryConfig {
        uint8 maxGuardians; // Max number of guardians that can be added
        CustomRecoveryConfig customConfig;
    }

    struct RecoveryRecord {
        bool isCompleted;
        bool isCancelled;
        address cancelledBy;
        address previousOwner;
        address newOwner;
        uint256 totalGuardians;
        address[] approvedGuardians;
        uint256 executableTime;
    }

    function supportsSocialRecovery() external view returns (bool);

    function updateCustomRecoveryConfig(CustomRecoveryConfig memory customConfig) external;

    function getCustomRecoveryConfig() external returns (CustomRecoveryConfig memory customConfig);

    function initiateRecovery(address account, address newOwner) external;

    function receiveRecoveryInitiation(address newOwner) external;

    function approveRecovery(address account) external;

    function receiveApproveRecovery() external;

    function cancelRecovery(address account) external;

    function receiveCancelRecovery() external;

    function completeRecovery(address account) external;

    function receiveCompleteRecovery() external;

    function getRecoveryProgress() external view returns (
        bool isInRecoveryProgress, 
        uint256 currentApprovals, 
        uint256 requiredApprovals, 
        uint256 executableTime
    );

    function getGuardians() external view returns (address[] memory);

    function isGuardian(address account) external view returns (bool);
}