// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {ISocialRecoveryPlugin} from "./ISocialRecoveryPlugin.sol";
import {IVaultPlugin} from "./IVaultPlugin.sol";

interface ISFAccountFactory {

    /* -------------------------------------------------------------------------- */
    /*                                   Errors                                   */
    /* -------------------------------------------------------------------------- */

    /**
     * @dev Error thrown when caller is not the owner
     */
    error ISFAccountFactory__OnlyOwner();

    /**
     * @dev Error thrown when max account amount is set to zero
     */
    error ISFAccountFactory__MaxAccountAmountCanNotBeZero();

    /**
     * @dev Error thrown when incompatible implementation is provided
     */
    error ISFAccountFactory__IncompatibleImplementation();

    /**
     * @dev Error thrown when caller is not the entry point
     */
    error ISFAccountFactory__NotFromEntryPoint();

    /**
     * @dev Error thrown when user reaches account limit
     * @param limit Maximum allowed accounts per user
     */
    error ISFAccountFactory__AccountLimitReached(uint256 limit);

    /* -------------------------------------------------------------------------- */
    /*                                   Events                                   */
    /* -------------------------------------------------------------------------- */

    /**
     * @dev Emitted when new account is created
     * @param account Address of created account (indexed)
     * @param owner Address of account owner (indexed)
     */
    event ISFAccountFactory__CreateAccount(address indexed account, address indexed owner);

    /* -------------------------------------------------------------------------- */
    /*                                  Functions                                 */
    /* -------------------------------------------------------------------------- */

    /**
     * @dev Creates new SFAccount instance
     * @param accountOwner Address of account owner
     * @param salt Deployment salt
     * @param customVaultConfig Custom vault configuration
     * @param customRecoveryConfig Custom recovery configuration
     * @return address Address of created account
     * Emits ISFAccountFactory__CreateAccount event
     * Requirements:
     * - User must not exceed max account limit
     */
    function createSFAccount(
        address accountOwner,
        bytes32 salt,
        IVaultPlugin.CustomVaultConfig memory customVaultConfig,
        ISocialRecoveryPlugin.CustomRecoveryConfig memory customRecoveryConfig
    ) external returns (address);

    /**
     * @dev Gets all accounts created by a user
     * @param user Address of user
     * @return address[] Array of account addresses
     */
    function getUserAccounts(address user) external view returns (address[] memory);

    /**
     * @dev Gets base vault configuration
     * @return VaultConfig Current vault configuration
     */
    function getVaultConfig() external view returns (IVaultPlugin.VaultConfig memory);

    /**
     * @dev Gets base recovery configuration
     * @return RecoveryConfig Current recovery configuration
     */
    function getRecoveryConfig() external view returns (ISocialRecoveryPlugin.RecoveryConfig memory);

    /**
     * @dev Gets initialization code for account creation
     * @param accountOwner Address of account owner
     * @param salt Deployment salt
     * @param customVaultConfig Custom vault configuration
     * @param customRecoveryConfig Custom recovery configuration
     * @return bytes Encoded initialization data
     */
    function getInitCode(
        address accountOwner,
        bytes32 salt,
        IVaultPlugin.CustomVaultConfig memory customVaultConfig,
        ISocialRecoveryPlugin.CustomRecoveryConfig memory customRecoveryConfig
    ) external view returns (bytes memory);

    /**
     * @dev Calculates deployment salt for user's next account
     * @param user Address of user
     * @return bytes32 Calculated salt value
     */
    function getSFAccountSalt(address user) external view returns (bytes32);

    /**
     * @dev Gets number of accounts created by user
     * @param user Address of user
     * @return uint256 Number of accounts
     */
    function getSFAccountAmount(address user) external view returns (uint256);

    /**
     * @dev Gets maximum allowed accounts per user
     * @return uint256 Maximum account limit
     */
    function getMaxAccountAmount() external view returns (uint256);

    /**
     * @dev Calculates deterministic account address
     * @param beacon Beacon contract address
     * @param deployer Deployer address
     * @return address Predicted account address
     */
    function calculateAccountAddress(address beacon, address deployer) external view returns (address);

    /**
     * @dev Calculates deterministic account address
     * @param beacon Beacon contract address
     * @param salt Deployment salt
     * @return address Predicted account address
     */
    function calculateAccountAddress(
        address beacon,
        bytes32 salt
    ) external view returns (address);
}