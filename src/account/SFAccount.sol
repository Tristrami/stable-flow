// SPDX-License-Identifier: MIT
pragma solidity ^0.8.30;

import {ISFAccount} from "../interfaces/ISFAccount.sol";
import {ISFEngine} from "../interfaces/ISFEngine.sol";
import {VaultPlugin} from "./plugins/VaultPlugin.sol";
import {SocialRecoveryPlugin} from "./plugins/SocialRecoveryPlugin.sol";
import {BaseAccount} from "account-abstraction/contracts/core/BaseAccount.sol";
import {SIG_VALIDATION_SUCCESS, SIG_VALIDATION_FAILED} from "account-abstraction/contracts/core/Helpers.sol";
import {IEntryPoint} from "account-abstraction/contracts/interfaces/IEntryPoint.sol";
import {PackedUserOperation} from "account-abstraction/contracts/interfaces/PackedUserOperation.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IERC165} from "@openzeppelin/contracts/utils/introspection/IERC165.sol";
import {ERC165} from "@openzeppelin/contracts/utils/introspection/ERC165.sol";
import {ECDSA} from "@openzeppelin/contracts/utils/cryptography/ECDSA.sol";
import {AccessControlUpgradeable} from "@openzeppelin/contracts-upgradeable/access/AccessControlUpgradeable.sol";

/**
 * @title SFAccount
 * @dev Core account contract implementing ERC-4337 account abstraction with plugin architecture
 * @notice Combines:
 * - Vault functionality (collateral management)
 * - Social recovery mechanisms
 * - ERC-4337 compliant account operations
 * @notice Key features:
 * - Modular plugin system (Vault/SocialRecovery plugins)
 * - Upgradeable via factory pattern
 * - Frozen state for security incidents
 * - ERC-4337 signature validation
 * @notice Inherits from:
 * - VaultPlugin (collateral management)
 * - SocialRecoveryPlugin (guardian recovery)
 * - BaseAccount (ERC-4337 core)
 * - ERC165 (interface detection)
 */
contract SFAccount is VaultPlugin, SocialRecoveryPlugin, ERC165 {

    /* -------------------------------------------------------------------------- */
    /*                                   Errors                                   */
    /* -------------------------------------------------------------------------- */

    error SFAccount__NotFromFactory();
    error SFAccount__OperationNotSupported();
    error SFAccount__InvalidAddress();
    error SFAccount__InvalidTokenAmount();
    error SFAccount__TransferFailed();
    error SFAccount__AccountIsFrozen();
    error SFAccount__AccountIsNotFrozen();

    /* -------------------------------------------------------------------------- */
    /*                                   Events                                   */
    /* -------------------------------------------------------------------------- */

    event SFAccount__AccountCreated(address indexed owner);
    event SFAccount__FreezeAccount(address indexed frozenBy);
    event SFAccount__UnfreezeAccount(address indexed unfrozenBy);

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
        bool isUnfozen;
    }

    /* -------------------------------------------------------------------------- */
    /*                               State Variables                              */
    /* -------------------------------------------------------------------------- */

    /// @dev Main protocol engine contract interface
    /// @notice Handles core protocol operations including collateral management and token minting/burning
    /// @notice Uses ISFEngine interface for type safety
    ISFEngine private sfEngine;

    /// @dev Address of the SF Token contract
    /// @notice Used for balance checks and token transfers
    /// @notice This is the native token of the protocol ecosystem
    address private sfTokenAddress;

    /// @dev Entry Point contract address for this chain
    /// @notice All privileged operations must originate from this address
    /// @notice Implements ERC-4337 Account Abstraction standards
    address private entryPointAddress;

    /// @dev Factory contract that created this account
    /// @notice Used for upgradeability and account management
    /// @notice May be used for factory-specific account verification
    address private accountFactoryAddress;

    /// @dev Account frozen status flag
    /// @notice When true, restricts most account operations
    /// @notice Only modifiable by privileged contracts (EntryPoint)
    bool private frozen;

    /// @dev Historical record of account freeze events
    /// @notice Contains timestamps and reasons for each freeze/unfreeze
    /// @notice Helps track account security history and compliance
    FreezeRecord[] private freezeRecords;

    /* -------------------------------------------------------------------------- */
    /*                                Initializers                                */
    /* -------------------------------------------------------------------------- */

    function initialize(
        address _accountOwner,
        address _entryPointAddress,
        address _sfEngineAddress,
        address _accountFactoryAddress,
        VaultConfig memory _vaultConfig,
        CustomVaultConfig memory _customVaultConfig,
        RecoveryConfig memory _recoveryConfig,
        CustomRecoveryConfig memory _customRecoveryConfig
    ) external initializer {
        // Upgradeable init
        __AccessControl_init();
        __Ownable_init(_accountOwner);
        __VaultPlugin_init(
            _vaultConfig,
            _customVaultConfig, 
            ISFEngine(_sfEngineAddress), 
            ISFEngine(_sfEngineAddress).getSFTokenAddress()
        );
        __SocialRecoveryPlugin_init(
            _recoveryConfig, 
            _customRecoveryConfig, 
            ISFEngine(_sfEngineAddress)
        );
        // State variable init
        entryPointAddress = _entryPointAddress;
        sfEngine = ISFEngine(_sfEngineAddress);
        sfTokenAddress = sfEngine.getSFTokenAddress();
        accountFactoryAddress = _accountFactoryAddress;
        frozen = false;
    }

    function reinitialize(
        VaultConfig memory vaultConfig,
        RecoveryConfig memory recoveryConfig,
        uint64 version
    ) external reinitializer(version) {
        _updateVaultConfig(vaultConfig);
        _updateSocialRecoveryConfig(recoveryConfig);
    }

    /* -------------------------------------------------------------------------- */
    /*                         External / Public Functions                        */
    /* -------------------------------------------------------------------------- */

    /// @inheritdoc ISFAccount
    function createAccount() external override {
        emit SFAccount__AccountCreated(owner());
    }

    /// @inheritdoc ISFAccount
    function getOwner() external view override returns (address) {
        return owner();
    }

    /// @inheritdoc ISFAccount
    function debt() external view override returns (uint256) {
        return _getSFDebt();
    }

    /// @inheritdoc ISFAccount
    function balance() external view override returns (uint256) {
        return _getSFTokenBalance();
    }

    /// @inheritdoc ISFAccount
    function transfer(address to, uint256 amount) 
        external 
        override 
        onlyEntryPoint 
        requireNotFrozen 
        onlySFAccount(to) 
    {
        if (to == address(0)) {
            revert SFAccount__InvalidAddress();
        }
        if (amount == 0) {
            revert SFAccount__InvalidTokenAmount();
        }
        bool success = IERC20(sfTokenAddress).transfer(to, amount);
        if (!success) {
            revert SFAccount__TransferFailed();
        }
    }

    /// @inheritdoc ISFAccount
    function freeze() external override onlyEntryPoint {
        _freezeAccount(owner());
    }

    /// @inheritdoc ISFAccount
    function unfreeze() external override onlyEntryPoint {
        _unfreezeAccount(owner());
    }

    /// @inheritdoc ISFAccount
    function isFrozen() external view override returns (bool) {
        return frozen;
    }

    /// @inheritdoc BaseAccount
    function entryPoint() public view override returns (IEntryPoint) {
        return IEntryPoint(entryPointAddress);
    }

    /// @inheritdoc BaseAccount
    function execute(address /* target */, uint256 /* value */, bytes calldata /* data */) external pure override {
        revert SFAccount__OperationNotSupported();
    }

    /// @inheritdoc BaseAccount
    function executeBatch(Call[] calldata /* calls */) external pure override {
        revert SFAccount__OperationNotSupported();
    }

    /// @inheritdoc ERC165
    function supportsInterface(bytes4 interfaceId) public view override(ERC165, IERC165, AccessControlUpgradeable) returns (bool) {
        return interfaceId == type(ISFAccount).interfaceId || super.supportsInterface(interfaceId);
    }

    /* -------------------------------------------------------------------------- */
    /*                        Internal / Private Functions                        */
    /* -------------------------------------------------------------------------- */

    /// @inheritdoc BaseAccount
    function _validateSignature(
        PackedUserOperation calldata userOp,
        bytes32 userOpHash
    ) internal view override returns (uint256 validationData) {
        address signer = ECDSA.recover(userOpHash, userOp.signature);
        return signer == owner() ? SIG_VALIDATION_SUCCESS : SIG_VALIDATION_FAILED;
    }

    function _freezeAccount(address frozenBy) private {
        _requireNotFrozen();
        frozen = true;
        FreezeRecord memory freezeRecord = FreezeRecord({
            frozenBy: frozenBy,
            unfrozenBy: address(0),
            isUnfozen: false
        });
        freezeRecords.push(freezeRecord);
        emit SFAccount__FreezeAccount(frozenBy);
    }

    function _unfreezeAccount(address unfrozenBy) private {
        _requireFrozen();
        FreezeRecord storage freezeRecord = freezeRecords[freezeRecords.length - 1];
        freezeRecord.isUnfozen = true;
        freezeRecord.unfrozenBy = unfrozenBy;
        emit SFAccount__UnfreezeAccount(unfrozenBy);
    }

    function _getSFTokenBalance() private view returns (uint256) {
        return IERC20(sfTokenAddress).balanceOf(address(this));
    }

    function _getSFDebt() private view returns (uint256) {
        return sfEngine.getSFDebt(address(this));
    }
}