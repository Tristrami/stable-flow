// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

interface IFreezePlugin {

    /* -------------------------------------------------------------------------- */
    /*                                   Errors                                   */
    /* -------------------------------------------------------------------------- */

    /**
     * @dev Reverts when operation requires frozen account but account is active
     */
    error IFreezePlugin__AccountIsNotFrozen();

    /**
     * @dev Reverts when operation requires active account but account is frozen
     */
    error IFreezePlugin__AccountIsFrozen();

    /* -------------------------------------------------------------------------- */
    /*                                   Events                                   */
    /* -------------------------------------------------------------------------- */

    /**
     * @dev Emitted when an account is frozen
     * @param frozenBy Address that initiated the freeze
     */
    event IFreezePlugin__FreezeAccount(address indexed frozenBy);

    /**
     * @dev Emitted when an account is unfrozen
     * @param unfrozenBy Address that executed the unfreeze
     */
    event IFreezePlugin__UnfreezeAccount(address indexed unfrozenBy);

    /* -------------------------------------------------------------------------- */
    /*                                    Types                                   */
    /* -------------------------------------------------------------------------- */

    /**
     * @dev Record tracking account freeze/unfreeze events
     * @notice Used for security auditing and account state history tracking
     * @notice Maintains complete lifecycle of each freeze operation
     */
    struct FreezeRecord {
        /// @dev Address that initiated the freeze operation
        /// @notice Typically the EntryPoint or guardians
        address frozenBy;
        /// @dev Address that executed unfreeze operation
        /// @notice Zero address (0x0) indicates still frozen state
        address unfrozenBy;
        /// @dev Current state flag for this freeze record
        /// @notice true = unfrozen, false = currently frozen
        bool isUnfrozen;
    }

    /* -------------------------------------------------------------------------- */
    /*                                  Functions                                 */
    /* -------------------------------------------------------------------------- */

    /**
     * @dev Freeze this account
     * @notice Requirements:
     * - Caller must be entry point (onlyEntryPoint)
     * @notice Prevents most operations while account is frozen
     */
    function freeze() external;

    /**
     * @dev Unfreeze this account
     * @notice Requirements:
     * - Caller must be entry point (onlyEntryPoint)
     * @notice Restores normal account functionality
     */
    function unfreeze() external;

    /**
     * @dev Check if account is currently frozen
     * @return bool True if account is frozen, false otherwise
     */
    function isFrozen() external view returns (bool);

    /**
     * @dev Returns the complete history of account freeze/unfreeze events
     * @notice Provides transparent audit trail of all freeze operations
     * @return FreezeRecord[] Array of freeze records containing:
     */
    function getFreezeRecords() external view returns (FreezeRecord[] memory);
}