// SPDX-License-Identifier: MIT
pragma solidity ^0.8.30;

interface IFreezePlugin {

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
}