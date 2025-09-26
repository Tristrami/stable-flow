// SPDX-License-Identifier: MIT
pragma solidity ^0.8.30;

import {BaseSFAccountPlugin} from "./BaseSFAccountPlugin.sol";
import {ISocialRecoveryPlugin} from "../../interfaces/ISocialRecoveryPlugin.sol";
import {ISFEngine} from "../../interfaces/ISFEngine.sol";
import {ISFAccount} from "../../interfaces/ISFAccount.sol";
import {ERC165Checker} from "@openzeppelin/contracts/utils/introspection/ERC165Checker.sol";
import {EnumerableSet} from "@openzeppelin/contracts/utils/structs/EnumerableSet.sol";

/**
 * @title SocialRecoveryPlugin
 * @dev Abstract contract implementing social recovery functionality for SFAccounts
 * @notice Provides multi-signature guardian-based account recovery mechanism
 * @notice Key features:
 * - Guardian-managed account ownership recovery
 * - Configurable approval thresholds and time locks
 * - Recovery process tracking and verification
 * - Integration with SFAccount security model
 * @notice Inherits from:
 * - ISocialRecoveryPlugin (interface)
 * - BaseSFAccountPlugin (base plugin functionality)
 */
abstract contract SocialRecoveryPlugin is ISocialRecoveryPlugin, BaseSFAccountPlugin {

    using ERC165Checker for address;
    using EnumerableSet for EnumerableSet.AddressSet;

    /* -------------------------------------------------------------------------- */
    /*                                   Errors                                   */
    /* -------------------------------------------------------------------------- */

    error SocialRecoveryPlugin__SocialRecoveryNotSupported();
    error SocialRecoveryPlugin__SocialRecoveryIsAlreadyDisabled();
    error SocialRecoveryPlugin__SocialRecoveryIsAlreadyEnabled();
    error SocialRecoveryPlugin__ApprovalExceedsGuardianAmount(uint256 approvals, uint256 numGuardians);
    error SocialRecoveryPlugin__AccountIsInRecoveryProcess();
    error SocialRecoveryPlugin__NoGuardianSet();
    error SocialRecoveryPlugin__MinGuardianApprovalsCanNotBeZero();
    error SocialRecoveryPlugin__MaxGuardiansCanNotBeZero();
    error SocialRecoveryPlugin__OnlyGuardian();
    error SocialRecoveryPlugin__TooManyGuardians(uint256 maxGuardians);
    error SocialRecoveryPlugin__GuardianAlreadyExists(address guardian);
    error SocialRecoveryPlugin__GuardianNotExists(address guardian);
    error SocialRecoveryPlugin__NotSFAccount(address account);
    error SocialRecoveryPlugin__NoPendingRecovery();
    error SocialRecoveryPlugin__InsufficientApprovals(uint256 currentApprovals, uint256 requiredApprovals);
    error SocialRecoveryPlugin__RecoveryNotExecutable(uint256 executableTime);
    error SocialRecoveryPlugin__RecoveryAlreadyInitiated(address newOwner);
    error SocialRecoveryPlugin__AccountIsFrozen();
    error SocialRecoveryPlugin__NotFromEntryPoint();

    /* -------------------------------------------------------------------------- */
    /*                                   Events                                   */
    /* -------------------------------------------------------------------------- */

    event SocialRecoveryPlugin__UpdateRecoveryConfig(bytes configData);
    event SocialRecoveryPlugin__UpdateCustomRecoveryConfig(bytes configData);
    event SocialRecoveryPlugin__UpdateGuardians(uint256 numGuardians);
    event SocialRecoveryPlugin__RecoveryInitiated(address indexed newOwner);
    event SocialRecoveryPlugin__RecoveryApproved(address indexed guardian);
    event SocialRecoveryPlugin__RecoveryCancelled(address indexed guardian, bytes recordData);
    event SocialRecoveryPlugin__RecoveryCompleted(
        address indexed previousOwner, 
        address indexed newOwner, 
        bytes recordData
    );

    /* -------------------------------------------------------------------------- */
    /*                                    Types                                   */
    /* -------------------------------------------------------------------------- */

    /**
     * @dev Storage structure for social recovery plugin
     * @notice Maintains all state variables for account recovery operations including:
     * - Recovery configuration parameters
     * - Guardian management
     * - Recovery process tracking
     */
    struct SocialRecoveryPluginStorage {
        /// @dev Base recovery configuration parameters
        /// @notice Contains protocol-level settings for all accounts
        RecoveryConfig recoveryConfig;
        /// @dev Account-specific recovery customization
        /// @notice Allows per-account adjustment of recovery parameters
        CustomRecoveryConfig customRecoveryConfig;
        /// @dev Reference to the core SFEngine protocol contract
        /// @notice Used for cross-contract interactions and state verification
        ISFEngine sfEngine;
        /// @dev Historical record of recovery attempts
        /// @notice Tracks all recovery processes with timestamps and outcomes
        RecoveryRecord[] recoveryRecords;
        /// @dev Set of approved guardian addresses
        /// @notice Uses EnumerableSet for efficient management and iteration
        EnumerableSet.AddressSet guardians;
    }

    /* -------------------------------------------------------------------------- */
    /*                                  Constants                                 */
    /* -------------------------------------------------------------------------- */

    /// @dev The guardian role
    bytes32 private constant GUARDIAN_ROLE = keccak256("GUARDIAN_ROLE");
    /// @dev keccak256(abi.encode(uint256(keccak256("stableflow.storage.SocialRecoveryPlugin")) - 1)) & ~bytes32(uint256(0xff))
    bytes32 private constant SOCIAL_RECOVERY_PLUGIN_STORAGE_LOCATION = 0xdac11792be4a8e52852ea11c208b7f5648c73e01ec3fc746926f8cbb4459c300;

    /* -------------------------------------------------------------------------- */
    /*                                  Modifiers                                 */
    /* -------------------------------------------------------------------------- */

    modifier onlyGuardian() {
        if (!hasRole(GUARDIAN_ROLE, _msgSender())) {
            revert SocialRecoveryPlugin__OnlyGuardian();
        }
        _;
    }

    modifier notRecovering() {
        _requireNotRecovering();
        _;
    }

    modifier recoverable() {
        _requireSupportsSocialRecovery();
        _;
    }

    modifier recoverableAccount(address account) {
        _requireSupportsSocialRecovery(account);
        _;
    }

    /* -------------------------------------------------------------------------- */
    /*                         External / Public Functions                        */
    /* -------------------------------------------------------------------------- */

    function __SocialRecoveryPlugin_init(
        RecoveryConfig memory recoveryConfig,
        CustomRecoveryConfig memory customRecoveryConfig,
        ISFEngine sfEngine
    ) internal {
        _updateSocialRecoveryConfig(recoveryConfig);
        _updateCustomSocialRecoveryConfig(customRecoveryConfig);
        SocialRecoveryPluginStorage storage $ = _getSocialRecoveryPluginStorage();
        $.sfEngine = sfEngine;
    }

    /// @inheritdoc ISocialRecoveryPlugin
    function supportsSocialRecovery() public view override returns (bool) {
        return _supportsSocialRecovery();
    }

    /// @inheritdoc ISocialRecoveryPlugin
    function getRecoveryConfig() external view override returns (RecoveryConfig memory) {
        SocialRecoveryPluginStorage storage $ = _getSocialRecoveryPluginStorage();
        return $.recoveryConfig;
    }

    /// @inheritdoc ISocialRecoveryPlugin
    function getCustomRecoveryConfig() external view override returns (CustomRecoveryConfig memory) {
        SocialRecoveryPluginStorage storage $ = _getSocialRecoveryPluginStorage();
        return $.customRecoveryConfig;
    }

    /// @inheritdoc ISocialRecoveryPlugin
    function updateCustomRecoveryConfig(CustomRecoveryConfig memory customConfig) external override onlyEntryPoint {
        _updateCustomSocialRecoveryConfig(customConfig);
    }

    /// @inheritdoc ISocialRecoveryPlugin
    function initiateRecovery(address account, address newOwner) 
        external 
        override 
        onlyEntryPoint 
        requireNotFrozen 
        recoverableAccount(account) 
    {
        ISFAccount(account).receiveInitiateRecover(newOwner);
    }

    /// @inheritdoc ISocialRecoveryPlugin
    function receiveInitiateRecover(address newOwner) 
        external 
        override 
        onlyGuardian 
        requireNotFrozen 
        recoverable 
        notRecovering 
    {
        SocialRecoveryPluginStorage storage $ = _getSocialRecoveryPluginStorage();
        RecoveryRecord memory recoveryRecord = RecoveryRecord({
            isCompleted: false,
            isCancelled: false,
            completedBy: address(0),
            cancelledBy: address(0),
            previousOwner: this.owner(),
            newOwner: newOwner,
            totalGuardians: $.guardians.length(),
            approvedGuardians: new address[](0),
            executableTime: block.timestamp + $.customRecoveryConfig.recoveryTimeLock
        });
        $.recoveryRecords.push(recoveryRecord);
        this.freeze();
        emit SocialRecoveryPlugin__RecoveryInitiated(newOwner);
    }

    /// @inheritdoc ISocialRecoveryPlugin
    function approveRecovery(address account) 
        external 
        override 
        onlyEntryPoint 
        requireNotFrozen 
        recoverableAccount(account) 
    {
        ISFAccount(account).receiveApproveRecovery();
    }

    /// @inheritdoc ISocialRecoveryPlugin
    function receiveApproveRecovery() external override onlyGuardian recoverable {
        SocialRecoveryPluginStorage storage $ = _getSocialRecoveryPluginStorage();
        RecoveryRecord storage recoveryRecord = _getPendingRecovery();
        recoveryRecord.approvedGuardians.push(msg.sender);
        emit SocialRecoveryPlugin__RecoveryApproved(msg.sender);
        bool approvalIsSufficient = recoveryRecord.approvedGuardians.length >= $.customRecoveryConfig.minGuardianApprovals;
        bool executableTimeReached = block.timestamp >= recoveryRecord.executableTime;
        if (approvalIsSufficient && executableTimeReached) {
            _completeRecovery(msg.sender);
        }
    }

    /// @inheritdoc ISocialRecoveryPlugin
    function cancelRecovery(address account) 
        external 
        override 
        onlyEntryPoint 
        requireNotFrozen 
        recoverableAccount(account) 
    {
        ISFAccount(account).receiveCancelRecovery();
    }

    /// @inheritdoc ISocialRecoveryPlugin
    function receiveCancelRecovery() external override onlyGuardian recoverable {
        RecoveryRecord storage recoveryRecord = _getPendingRecovery();
        recoveryRecord.isCancelled = true;
        recoveryRecord.cancelledBy = msg.sender;
        this.unfreeze();
        emit SocialRecoveryPlugin__RecoveryCancelled(msg.sender, abi.encode(recoveryRecord));
    }

    /// @inheritdoc ISocialRecoveryPlugin
    function completeRecovery(address account)
        external 
        override 
        onlyEntryPoint 
        requireNotFrozen 
        recoverableAccount(account) 
    {
        ISFAccount(account).receiveCompleteRecovery();
    }

    /// @inheritdoc ISocialRecoveryPlugin
    function receiveCompleteRecovery() external override onlyGuardian recoverable {
        _completeRecovery(msg.sender);
    }

    /// @inheritdoc ISocialRecoveryPlugin
    function getRecoveryProgress() external view override recoverable returns (
        bool isInRecoveryProgress, 
        uint256 receivedApprovals, 
        uint256 requiredApprovals, 
        uint256 executableTime
    ) {
        SocialRecoveryPluginStorage storage $ = _getSocialRecoveryPluginStorage();
        RecoveryRecord memory recoveryRecord = _getPendingRecoveryUnchecked();
        if (recoveryRecord.previousOwner == address(0)) {
            isInRecoveryProgress = false;
            return (isInRecoveryProgress, receivedApprovals, requiredApprovals, executableTime);
        }
        isInRecoveryProgress = true;
        receivedApprovals = recoveryRecord.approvedGuardians.length;
        requiredApprovals = $.customRecoveryConfig.minGuardianApprovals;
        executableTime = recoveryRecord.executableTime;
    }

    /// @inheritdoc ISocialRecoveryPlugin
    function getGuardians() external view override recoverable returns (address[] memory) {
        SocialRecoveryPluginStorage storage $ = _getSocialRecoveryPluginStorage();
        return $.guardians.values();
    }

    /// @inheritdoc ISocialRecoveryPlugin
    function isGuardian(address account) external view recoverable override returns (bool) {
        SocialRecoveryPluginStorage storage $ = _getSocialRecoveryPluginStorage();
        return $.guardians.contains(account);
    }

    /* -------------------------------------------------------------------------- */
    /*                        Internal / Private Functions                        */
    /* -------------------------------------------------------------------------- */

    function _getSocialRecoveryPluginStorage() private pure returns (SocialRecoveryPluginStorage storage $) {
        assembly {
            $.slot := SOCIAL_RECOVERY_PLUGIN_STORAGE_LOCATION
        }
    }

    function _updateSocialRecoveryConfig(RecoveryConfig memory recoveryConfig) internal {
        _checkSocialRecoveryConfig(recoveryConfig);
        SocialRecoveryPluginStorage storage $ = _getSocialRecoveryPluginStorage();
        $.recoveryConfig = recoveryConfig;
        emit SocialRecoveryPlugin__UpdateRecoveryConfig(abi.encode(recoveryConfig));
    }

    function _checkSocialRecoveryConfig(RecoveryConfig memory recoveryConfig) private pure {
        if (recoveryConfig.maxGuardians == 0) {
            revert SocialRecoveryPlugin__MaxGuardiansCanNotBeZero();
        }
    }

    function _updateCustomSocialRecoveryConfig(CustomRecoveryConfig memory customConfig) internal {
        SocialRecoveryPluginStorage storage $ = _getSocialRecoveryPluginStorage();
        _updateGuardians(customConfig.guardians);
        $.customRecoveryConfig = customConfig;
        emit SocialRecoveryPlugin__UpdateCustomRecoveryConfig(abi.encode(customConfig));
    }

    function _checkCustomSocialRecoveryConfig(CustomRecoveryConfig memory customConfig) private view {
        SocialRecoveryPluginStorage storage $ = _getSocialRecoveryPluginStorage();
        if ($.customRecoveryConfig.socialRecoveryEnabled 
            && !customConfig.socialRecoveryEnabled) {
            // If disable social recovery, check whether account is in recovering process
            _requireNotRecovering();
        }
        if (customConfig.minGuardianApprovals == 0) {
            revert SocialRecoveryPlugin__MinGuardianApprovalsCanNotBeZero();
        }
        if (customConfig.guardians.length == 0) {
            revert SocialRecoveryPlugin__NoGuardianSet();
        }
        if (customConfig.minGuardianApprovals > customConfig.guardians.length) {
            revert SocialRecoveryPlugin__ApprovalExceedsGuardianAmount(
                customConfig.minGuardianApprovals, 
                customConfig.guardians.length
            );
        }
    }

    function _updateGuardians(address[] memory guardians) private {
        SocialRecoveryPluginStorage storage $ = _getSocialRecoveryPluginStorage();
        $.guardians.clear();
        for (uint256 i = 0; i < guardians.length; i++) {
            $.guardians.add(guardians[i]);
        }
        emit SocialRecoveryPlugin__UpdateGuardians(guardians.length);
    }

    function _getPendingRecovery() private view returns (RecoveryRecord storage) {
        SocialRecoveryPluginStorage storage $ = _getSocialRecoveryPluginStorage();
        if ($.recoveryRecords.length == 0) {
            revert SocialRecoveryPlugin__NoPendingRecovery();
        }
        RecoveryRecord storage latestRecord = $.recoveryRecords[$.recoveryRecords.length - 1];
        if (latestRecord.isCompleted || latestRecord.isCancelled) {
            revert SocialRecoveryPlugin__NoPendingRecovery();
        }
        return latestRecord;
    }

    function _getPendingRecoveryUnchecked() private view returns (RecoveryRecord memory recoveryRecord) {
        SocialRecoveryPluginStorage storage $ = _getSocialRecoveryPluginStorage();
        if ($.recoveryRecords.length == 0) {
            return recoveryRecord;
        }
        RecoveryRecord memory latestRecord = $.recoveryRecords[$.recoveryRecords.length - 1];
        return (latestRecord.isCompleted || latestRecord.isCancelled) 
            ? recoveryRecord 
            : latestRecord;
    }

    function _completeRecovery(address completedBy) private {
        SocialRecoveryPluginStorage storage $ = _getSocialRecoveryPluginStorage();
        RecoveryRecord storage recoveryRecord = _getPendingRecovery();
        uint256 currentApprovals = recoveryRecord.approvedGuardians.length;
        uint256 minApprovals = $.customRecoveryConfig.minGuardianApprovals;
        if (currentApprovals < minApprovals) {
            revert SocialRecoveryPlugin__InsufficientApprovals(currentApprovals, minApprovals);
        }
        if (block.timestamp < recoveryRecord.executableTime) {
            revert SocialRecoveryPlugin__RecoveryNotExecutable(recoveryRecord.executableTime);
        }
        recoveryRecord.isCompleted = true;
        recoveryRecord.completedBy = completedBy;
        this.transferOwnership(recoveryRecord.newOwner);
        emit SocialRecoveryPlugin__RecoveryCompleted(
            recoveryRecord.previousOwner, 
            recoveryRecord.newOwner,
            abi.encode(recoveryRecord)
        );
    }

    function _supportsSocialRecovery() private view returns (bool) {
        SocialRecoveryPluginStorage storage $ = _getSocialRecoveryPluginStorage();
        return $.customRecoveryConfig.socialRecoveryEnabled;
    }

    function _requireNotRecovering() private view {
        if (_existsPendingRecovery()) {
            revert SocialRecoveryPlugin__AccountIsInRecoveryProcess();
        }
    }

    function _existsPendingRecovery() private view returns (bool) {
        SocialRecoveryPluginStorage storage $ = _getSocialRecoveryPluginStorage();
        if ($.recoveryRecords.length == 0) {
            return false;
        }
        RecoveryRecord memory latestRecord = $.recoveryRecords[$.recoveryRecords.length - 1];
        return !(latestRecord.isCompleted || latestRecord.isCancelled);
    }

    function _requireSupportsSocialRecovery() private view {
        if (!_supportsSocialRecovery()) {
            revert SocialRecoveryPlugin__SocialRecoveryNotSupported();
        }
    }

    function _requireSupportsSocialRecovery(address account) private view {
        _requireSFAccount(account);
        if (!ISFAccount(account).supportsSocialRecovery()) {
            revert SocialRecoveryPlugin__SocialRecoveryNotSupported();
        }
    }
}