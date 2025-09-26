// SPDX-License-Identifier: MIT
pragma solidity ^0.8.30;

import {ISocialRecoveryPlugin} from "./ISocialRecoveryPlugin.sol";
import {IVaultPlugin} from "./IVaultPlugin.sol";
import {IERC165} from "@openzeppelin/contracts/utils/introspection/IERC165.sol";

interface ISFAccount is ISocialRecoveryPlugin, IVaultPlugin, IERC165 {

    /**
     * @dev Initialize a new SFAccount
     * @notice Emits SFAccount__AccountCreated event with owner address
     * @notice Typically called when account is first created
     */
    function createAccount() external;

    /**
     * @dev Get the owner of this account
     * @return address Current owner of the account
     */
    function getOwner() external view returns (address);

    /**
     * @dev Get the current debt balance in SF tokens
     * @return uint256 Amount of SF token debt
     */
    function debt() external view returns (uint256);

    /**
     * @dev Get the SF token balance of this account
     * @return uint256 Current SF token balance
     */
    function balance() external view returns (uint256);

    /**
     * @dev Transfer SF tokens to another account
     * @param to Recipient address (must be SFAccount)
     * @param amount Amount of SF tokens to transfer
     * @notice Requirements:
     * - Caller must be entry point (onlyEntryPoint)
     * - Account must not be frozen (requireNotFrozen)
     * - Recipient must be SFAccount (onlySFAccount)
     * @notice Reverts if:
     * - Address is zero (SFAccount__InvalidAddress)
     * - Amount is zero (SFAccount__InvalidTokenAmount)
     * - Transfer fails (SFAccount__TransferFailed)
     */
    function transfer(address to, uint256 amount) external;

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