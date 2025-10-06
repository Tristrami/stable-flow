// SPDX-License-Identifier: MIT
pragma solidity ^0.8.30;

import {IERC165} from "@openzeppelin/contracts/utils/introspection/IERC165.sol";
import {IFreezePlugin} from "./IFreezePlugin.sol";
import {IVaultPlugin} from "./IVaultPlugin.sol";
import {ISocialRecoveryPlugin} from "./ISocialRecoveryPlugin.sol";

interface ISFAccount is IFreezePlugin, IVaultPlugin, ISocialRecoveryPlugin, IERC165 {

   /* -------------------------------------------------------------------------- */
    /*                                   Errors                                   */
    /* -------------------------------------------------------------------------- */

    /**
     * @dev Reverts when operation is attempted by non-factory address
     * @notice Account operations must originate from the factory contract
     */
    error ISFAccount__NotFromFactory();

    /**
     * @dev Reverts when attempting an unsupported operation
     * @notice Certain account functions may be disabled
     */
    error ISFAccount__OperationNotSupported();

    /**
     * @dev Reverts when zero address is provided
     * @notice Prevents operations with zero addresses
     */
    error ISFAccount__AddressCanNotBeZero();

    /**
     * @dev Reverts when operation requires more balance than available
     * @param receiver The address of receiver account
     * @param balance Current available balance (18 decimals)
     * @param required Minimum required amount for the operation (18 decimals)
     * @notice This error occurs when attempting operations like Transfer or transfers 
     *         that exceed the account's current SF token balance
     */
    error ISFAccount__InsufficientBalance(address receiver, uint256 balance, uint256 required);

    /**
     * @dev Reverts when zero token amount is provided
     * @notice Ensures all token operations use non-zero amounts
     */
    error ISFAccount__TokenAmountCanNotBeZero();

    /**
     * @dev Reverts when token approval operation fails
     * @notice Indicates ERC20 approval call was unsuccessful
     */
    error ISFAccount__ApproveFailed();

    /**
     * @dev Reverts when token transfer operation fails
     * @notice Indicates ERC20 transfer call was unsuccessful
     */
    error ISFAccount__TransferFailed();

    /* -------------------------------------------------------------------------- */
    /*                                   Events                                   */
    /* -------------------------------------------------------------------------- */

    /**
     * @dev Emitted when new account instance is created
     * @param owner Address that owns the new account
     * @notice Logs all account creation events
     */
    event ISFAccount__AccountCreated(address indexed owner);

    /**
     * @dev Initialize a new SFAccount
     * @notice Emits ISFAccount__AccountCreated event with owner address
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
     * - Address is zero (ISFAccount__InvalidAddress)
     * - Amount is zero (ISFAccount__InvalidTokenAmount)
     * - Transfer fails (ISFAccount__TransferFailed)
     */
    function transfer(address to, uint256 amount) external;
}