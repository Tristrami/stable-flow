// SPDX-License-Identifier: MIT
pragma solidity ^0.8.30;

interface ISocialRecoveryPlugin {

    /**
     * @dev Basic recovery configuration structure
     * @notice Contains fundamental parameters for social recovery system
     */
    struct RecoveryConfig {
        /// @dev Maximum number of guardians that can be added to this account
        /// @notice This is a hard limit to prevent excessive guardian assignments
        uint8 maxGuardians;
    }

    /**
     * @dev Custom recovery configuration structure
     * @notice Contains account-specific recovery parameters that can be customized
     */
    struct CustomRecoveryConfig {
        /// @dev Flag indicating whether social recovery is enabled for this account
        bool socialRecoveryEnabled;
        /// @dev Minimum number of guardian approvals required to execute recovery
        /// @notice Must be less than or equal to total number of guardians
        uint8 minGuardianApprovals;
        /// @dev Time delay (in seconds) required before recovery can be executed
        /// @notice Prevents immediate account takeover, providing a safety window
        uint256 recoveryTimeLock;
        /// @dev Array of addresses authorized as guardians for this account
        /// @notice Guardians can initiate and approve recovery processes
        address[] guardians;
    }

    /**
     * @dev Recovery process record structure
     * @notice Tracks the state and progress of an ongoing recovery attempt
     */
    struct RecoveryRecord {
        /// @dev Flag indicating if recovery was successfully completed
        bool isCompleted;
        /// @dev Flag indicating if recovery was cancelled
        bool isCancelled;
        /// @dev Address of the guardian who cancelled the recovery
        address cancelledBy;
        /// @dev Original owner address before recovery initiation
        address previousOwner;
        /// @dev Proposed new owner address
        address newOwner;
        /// @dev Total number of guardians at time of recovery initiation
        uint256 totalGuardians;
        /// @dev Array of guardians who have approved this recovery
        address[] approvedGuardians;
        /// @dev Timestamp when recovery can be executed (initiation time + time lock)
        uint256 executableTime;
    }

    /**
     * @dev Checks if social recovery feature is enabled for current account
     * @return True if social recovery is supported, false otherwise
     */
    function supportsSocialRecovery() external view returns (bool);

    /**
     * @dev Gets the base recovery configuration
     * @return customConfig The current RecoveryConfig settings
     */
    function getRecoveryConfig() external view returns (RecoveryConfig memory customConfig);

    /**
     * @dev Updates the social recovery configuration
     * @param recoveryConfig New recovery configuration parameters
     * @notice Only callable by the entry point (onlyEntryPoint modifier)
     */
    function updateSocialRecoveryConfig(RecoveryConfig memory recoveryConfig) external;

    /**
     * @dev Gets the custom recovery configuration
     * @return customConfig The current CustomRecoveryConfig settings
     */
    function getCustomRecoveryConfig() external returns (CustomRecoveryConfig memory customConfig);

    /**
     * @dev Updates the custom recovery configuration
     * @param customConfig New custom recovery configuration parameters
     * @notice Only callable by the entry point (onlyEntryPoint modifier)
     */
    function updateCustomRecoveryConfig(CustomRecoveryConfig memory customConfig) external;

    /**
     * @dev Initiates a recovery process for an account
     * @param account The account to recover
     * @param newOwner The proposed new owner address
     * @notice Requirements:
     * - Caller must be entry point (onlyEntryPoint)
     * - Contract must not be frozen (requireNotFrozen)
     * - Account must supports social recovery (recoverableAccount)
     * @notice Triggers the recovery initiation process on the target account
     */
    function initiateRecovery(address account, address newOwner) external;

    /**
     * @dev Receives and processes a recovery initiation request
     * @param newOwner The proposed new owner address
     * @notice Requirements:
     * - Caller must be guardian (onlyGuardian)
     * - Contract must not be frozen (requireNotFrozen)
     * - Account must supports social recovery (recoverable)
     * - Not already in recovery (notRecovering)
     * @notice Creates a new recovery record and freezes the account
     */
    function receiveRecoveryInitiation(address newOwner) external;

    /**
     * @dev Approves a recovery process for an account
     * @param account The account being recovered
     * @notice Requirements:
     * - Caller must be entry point (onlyEntryPoint)
     * - Contract must not be frozen (requireNotFrozen)
     * - Account must supports social recovery (recoverableAccount)
     * @notice Forwards approval to the target account
     */
    function approveRecovery(address account) external;

    /**
     * @dev Receives and processes a recovery approval
     * @notice Requirements:
     * - Caller must be guardian (onlyGuardian)
     * - Contract must not be frozen (requireNotFrozen)
     * - Account must supports social recovery (recoverable)
     * @notice If sufficient approvals and time lock passed, completes recovery
     */
    function receiveApproveRecovery() external;

    /**
     * @dev Cancels an ongoing recovery process
     * @param account The account under recovery
     * @notice Requirements:
     * - Caller must be entry point (onlyEntryPoint)
     * - Contract must not be frozen (requireNotFrozen)
     * - Account must supports social recovery (recoverableAccount)
     * @notice Forwards cancellation to the target account
     */
    function cancelRecovery(address account) external;

    /**
     * @dev Receives and processes a recovery cancellation
     * @notice Requirements:
     * - Caller must be guardian (onlyGuardian)
     * - Contract must not be frozen (requireNotFrozen)
     * - Account must supports social recovery (recoverable)
     * @notice Marks recovery as cancelled and unfreezes account
     */
    function receiveCancelRecovery() external;

    /**
     * @dev Completes an ongoing recovery process
     * @param account The account under recovery
     * @notice Requirements:
     * - Caller must be entry point (onlyEntryPoint)
     * - Contract must not be frozen (requireNotFrozen)
     * - Account must supports social recovery (recoverableAccount)
     * @notice Forwards completion to the target account
     */
    function completeRecovery(address account) external;

    /**
     * @dev Receives and processes recovery completion
     * @notice Requirements:
     * - Caller must be guardian (onlyGuardian)
     * - Contract must not be frozen (requireNotFrozen)
     * - Account must supports social recovery (recoverable)
     * @notice Executes ownership transfer and unfreezes account
     */
    function receiveCompleteRecovery() external;

    /**
     * @dev Gets the current recovery progress status
     * @return isInRecoveryProgress True if recovery is in progress
     * @return currentApprovals Number of approvals received
     * @return requiredApprovals Number of approvals required
     * @return executableTime When recovery can be executed
     * @notice Requirements:
     * - Account must supports social recovery (recoverable modifier)
     */
    function getRecoveryProgress() external view returns (
        bool isInRecoveryProgress, 
        uint256 currentApprovals, 
        uint256 requiredApprovals, 
        uint256 executableTime
    );

    /**
     * @dev Gets the list of all guardians
     * @return address[] Array of guardian addresses
     * @notice Requirements:
     * - Account must supports social recovery (recoverable modifier)
     */
    function getGuardians() external view returns (address[] memory);

    /**
     * @dev Checks if an address is a guardian
     * @param account Address to check
     * @return bool True if address is a guardian, false otherwise
     * @notice Requirements:
     * - Account must supports social recovery (recoverable modifier)
     */
    function isGuardian(address account) external view returns (bool);
}