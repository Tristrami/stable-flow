// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

interface ISocialRecoveryPlugin {
    
    /* -------------------------------------------------------------------------- */
    /*                                   Errors                                   */
    /* -------------------------------------------------------------------------- */

    /**
     * @dev Reverts when attempting to use social recovery on unsupported accounts
     */
    error ISocialRecoveryPlugin__SocialRecoveryNotSupported();

    /**
     * @dev Reverts when attempting to disable already disabled social recovery
     */
    error ISocialRecoveryPlugin__SocialRecoveryIsAlreadyDisabled();

    /**
     * @dev Reverts when attempting to enable already enabled social recovery
     */
    error ISocialRecoveryPlugin__SocialRecoveryIsAlreadyEnabled();

    /**
     * @dev Reverts when approvals exceed total guardian count
     * @param approvals Current number of approvals
     * @param numGuardians Total number of guardians
     */
    error ISocialRecoveryPlugin__ApprovalExceedsGuardianAmount(uint256 approvals, uint256 numGuardians);

    /**
     * @dev Reverts when operation requires non-recovering account but account is in recovery
     */
    error ISocialRecoveryPlugin__AccountIsInRecoveryProcess();

    /**
     * @dev Reverts when operation requires guardians but none are set
     */
    error ISocialRecoveryPlugin__NoGuardianSet();

    /**
     * @dev Reverts when attempting to set zero minimum guardian approvals
     */
    error ISocialRecoveryPlugin__MinGuardianApprovalsCanNotBeZero();

    /**
     * @dev Reverts when attempting to set zero maximum guardians
     */
    error ISocialRecoveryPlugin__MaxGuardiansCanNotBeZero();

    /**
     * @dev Reverts when caller is not a guardian
     */
    error ISocialRecoveryPlugin__OnlyGuardian();

    /**
     * @dev Reverts when guardian has already approved recovery
     */
    error ISocialRecoveryPlugin__AlreadyApproved();

    /**
     * @dev Reverts when attempting to exceed maximum guardian limit
     * @param maxGuardians Maximum allowed number of guardians
     */
    error ISocialRecoveryPlugin__TooManyGuardians(uint256 maxGuardians);

    /**
     * @dev Reverts when attempting to add existing guardian
     * @param guardian Address of duplicate guardian
     */
    error ISocialRecoveryPlugin__GuardianAlreadyExists(address guardian);

    /**
     * @dev Reverts when attempting to remove non-existent guardian
     * @param guardian Address of non-existent guardian
     */
    error ISocialRecoveryPlugin__GuardianNotExists(address guardian);

    /**
     * @dev Reverts when account is not an SF account
     * @param account Invalid account address
     */
    error ISocialRecoveryPlugin__NotSFAccount(address account);

    /**
     * @dev Reverts when operation requires recovery process but none exists
     */
    error ISocialRecoveryPlugin__NotInRecoveryProcess();

    /**
     * @dev Reverts when recovery approvals are insufficient
     * @param currentApprovals Number of approvals received
     * @param requiredApprovals Number of approvals needed
     */
    error ISocialRecoveryPlugin__InsufficientApprovals(
        uint256 currentApprovals, 
        uint256 requiredApprovals
    );

    /**
     * @dev Reverts when attempting to execute recovery before time lock expires
     * @param executableTime Timestamp when recovery becomes executable
     */
    error ISocialRecoveryPlugin__RecoveryNotExecutable(uint256 executableTime);

    /**
     * @dev Reverts when attempting to initiate duplicate recovery
     * @param newOwner Address already set as new owner in pending recovery
     */
    error ISocialRecoveryPlugin__RecoveryAlreadyInitiated(address newOwner);

    /* -------------------------------------------------------------------------- */
    /*                                   Events                                   */
    /* -------------------------------------------------------------------------- */

    /**
     * @dev Emitted when standard recovery configuration is updated
     * @param configData Encoded configuration parameters
     */
    event ISocialRecoveryPlugin__UpdateRecoveryConfig(bytes configData);

    /**
     * @dev Emitted when custom recovery configuration is updated
     * @param configData Encoded custom configuration parameters
     */
    event ISocialRecoveryPlugin__UpdateCustomRecoveryConfig(bytes configData);

    /**
     * @dev Emitted when guardian set is modified
     * @param numGuardians New number of guardians
     */
    event ISocialRecoveryPlugin__UpdateGuardians(uint256 numGuardians);

    /**
     * @dev Emitted when recovery process is initiated
     * @param newOwner Address designated as new owner
     */
    event ISocialRecoveryPlugin__RecoveryInitiated(
        address indexed initiator, 
        address indexed newOwner
    );

    /**
     * @dev Emitted when guardian approves recovery
     * @param guardian Address of approving guardian
     */
    event ISocialRecoveryPlugin__RecoveryApproved(address indexed guardian);

    /**
     * @dev Emitted when recovery process is cancelled
     * @param guardian Address that cancelled recovery
     * @param recordData Encoded cancellation details
     */
    event ISocialRecoveryPlugin__RecoveryCancelled(
        address indexed guardian, 
        bytes recordData
    );

    /**
     * @dev Emitted when recovery process is completed
     * @param previousOwner Original owner address
     * @param newOwner New owner address
     * @param recordData Encoded recovery details
     */
    event ISocialRecoveryPlugin__RecoveryCompleted(
        address indexed previousOwner, 
        address indexed newOwner, 
        bytes recordData
    );

    /* -------------------------------------------------------------------------- */
    /*                                    Types                                   */
    /* -------------------------------------------------------------------------- */

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
        /// @dev Array of addresses authorized as guardians for this account
        /// @notice Guardians can initiate and approve recovery processes
        address[] guardians;
        /// @dev Minimum number of guardian approvals required to execute recovery
        /// @notice Must be less than or equal to total number of guardians
        uint8 minGuardianApprovals;
        /// @dev Time delay (in seconds) required before recovery can be executed
        /// @notice Prevents immediate account takeover, providing a safety window
        uint256 recoveryTimeLock;
        /// @dev Flag indicating whether social recovery is enabled for this account
        bool socialRecoveryEnabled;
    }

    /**
     * @dev Recovery process record structure
     * @notice Tracks the state and progress of an ongoing recovery attempt
     */
    struct RecoveryRecord {
        /// @dev Address of the guardian who initiated the recovery
        address initiator;
        /// @dev Flag indicating if recovery was successfully completed
        bool isCompleted;
        /// @dev Flag indicating if recovery was cancelled
        bool isCancelled;
        /// @dev Address of the guardian who completed the recovery
        address completedBy;
        /// @dev Address of the guardian who cancelled the recovery
        address cancelledBy;
        /// @dev Original owner address before recovery initiation
        address previousOwner;
        /// @dev Proposed new owner address
        address newOwner;
        /// @dev Total number of guardians at time of recovery initiation
        uint256 totalGuardians;
        /// @dev Total required amount of approvals to execute recovery
        uint256 requiredApprovals; 
        /// @dev Array of guardians who have approved this recovery
        address[] approvedGuardians;
        /// @dev Timestamp when recovery can be executed (initiation time + time lock)
        uint256 executableTime;
    }

    /* -------------------------------------------------------------------------- */
    /*                                  Functions                                 */
    /* -------------------------------------------------------------------------- */

    /**
     * @dev Checks if social recovery feature is enabled for current account
     * @return bool True if social recovery is supported, false otherwise
     */
    function supportsSocialRecovery() external view returns (bool);

    /**
     * @dev Gets the base recovery configuration
     * @return RecoveryConfig The current RecoveryConfig settings
     */
    function getRecoveryConfig() external view returns (RecoveryConfig memory);

    /**
     * @dev Gets the custom recovery configuration
     * @return CustomRecoveryConfig The current CustomRecoveryConfig settings
     */
    function getCustomRecoveryConfig() external returns (CustomRecoveryConfig memory);

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
    function receiveInitiateRecovery(address newOwner) external;

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
     * @dev Retrieves the complete history of recovery attempts from storage
     * @return RecoveryRecord[] Array of recovery records
     */
    function getRecoveryRecords() external view returns (RecoveryRecord[] memory);

    /**
     * @dev Gets the current recovery progress status
     * @return isInRecoveryProgress True if recovery is in progress
     * @return receivedApprovals Number of approvals received
     * @return requiredApprovals Number of approvals required
     * @return executableTime When recovery can be executed
     * @notice Requirements:
     * - Account must supports social recovery (recoverable modifier)
     */
    function getRecoveryProgress() external view returns (
        bool isInRecoveryProgress, 
        uint256 receivedApprovals, 
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

    /**
     * @dev Checks if an account is currently in recovery process
     * @dev Returns true if there's an active (non-completed/non-cancelled) recovery record
     * @return bool True if account is in recovery, false otherwise
     */
    function isRecovering() external view returns (bool);
}