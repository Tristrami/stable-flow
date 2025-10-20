// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {FreezePlugin} from "./FreezePlugin.sol";
import {ISocialRecoveryPlugin} from "../../interfaces/ISocialRecoveryPlugin.sol";
import {ISFEngine} from "../../interfaces/ISFEngine.sol";
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
abstract contract SocialRecoveryPlugin is ISocialRecoveryPlugin, FreezePlugin {

    using ERC165Checker for address;
    using EnumerableSet for EnumerableSet.AddressSet;

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
        SocialRecoveryPluginStorage storage $ = _getSocialRecoveryPluginStorage();
        if (!hasRole(GUARDIAN_ROLE, _msgSender()) || !$.guardians.contains(_msgSender())) {
            revert ISocialRecoveryPlugin__OnlyGuardian();
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
    /*                                 Initializer                                */
    /* -------------------------------------------------------------------------- */

    function __SocialRecoveryPlugin_init(
        RecoveryConfig memory recoveryConfig,
        CustomRecoveryConfig memory customRecoveryConfig,
        ISFEngine sfEngine
    ) internal {
        SocialRecoveryPluginStorage storage $ = _getSocialRecoveryPluginStorage();
        $.sfEngine = sfEngine;
        _updateSocialRecoveryConfig(recoveryConfig);
        _updateCustomSocialRecoveryConfig(customRecoveryConfig);
    }

    /* -------------------------------------------------------------------------- */
    /*                         External / Public Functions                        */
    /* -------------------------------------------------------------------------- */

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
    function updateCustomRecoveryConfig(CustomRecoveryConfig memory customConfig) 
        external 
        override 
        onlyEntryPoint 
        notRecovering
        requireNotFrozen 
    {
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
        ISocialRecoveryPlugin(account).receiveInitiateRecovery(newOwner);
    }

    /// @inheritdoc ISocialRecoveryPlugin
    function receiveInitiateRecovery(address newOwner) 
        external 
        override 
        onlyGuardian  
        recoverable 
        notRecovering 
    {
        SocialRecoveryPluginStorage storage $ = _getSocialRecoveryPluginStorage();
        RecoveryRecord memory recoveryRecord = RecoveryRecord({
            initiator: msg.sender,
            isCompleted: false,
            isCancelled: false,
            completedBy: address(0),
            cancelledBy: address(0),
            previousOwner: this.owner(),
            newOwner: newOwner,
            totalGuardians: $.guardians.length(),
            requiredApprovals: $.customRecoveryConfig.minGuardianApprovals,
            approvedGuardians: new address[](0),
            executableTime: 0
        });
        $.recoveryRecords.push(recoveryRecord);
        if (!_isFrozen()) {
            _freezeAccount(msg.sender);
        }
        emit ISocialRecoveryPlugin__RecoveryInitiated(msg.sender, newOwner);
    }

    /// @inheritdoc ISocialRecoveryPlugin
    function approveRecovery(address account) 
        external 
        override 
        onlyEntryPoint 
        requireNotFrozen 
        recoverableAccount(account) 
    {
        ISocialRecoveryPlugin(account).receiveApproveRecovery();
    }

    /// @inheritdoc ISocialRecoveryPlugin
    function receiveApproveRecovery() external override onlyGuardian recoverable {
        SocialRecoveryPluginStorage storage $ = _getSocialRecoveryPluginStorage();
        RecoveryRecord storage recoveryRecord = _getPendingRecovery();
        address[] storage approvedGuardians = recoveryRecord.approvedGuardians;
        for (uint256 i = 0; i < approvedGuardians.length; i++) {
            if (approvedGuardians[i] == msg.sender) {
                revert ISocialRecoveryPlugin__AlreadyApproved();
            }
        }
        approvedGuardians.push(msg.sender);
        emit ISocialRecoveryPlugin__RecoveryApproved(msg.sender);
        bool approvalIsSufficient = recoveryRecord.approvedGuardians.length >= recoveryRecord.requiredApprovals;
        if (approvalIsSufficient) {
            recoveryRecord.executableTime = block.timestamp + $.customRecoveryConfig.recoveryTimeLock;
        }
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
        ISocialRecoveryPlugin(account).receiveCancelRecovery();
    }

    /// @inheritdoc ISocialRecoveryPlugin
    function receiveCancelRecovery() external override onlyGuardian recoverable {
        RecoveryRecord storage recoveryRecord = _getPendingRecovery();
        recoveryRecord.isCancelled = true;
        recoveryRecord.cancelledBy = msg.sender;
        _unfreezeAccount(msg.sender);
        emit ISocialRecoveryPlugin__RecoveryCancelled(msg.sender, abi.encode(recoveryRecord));
    }

    /// @inheritdoc ISocialRecoveryPlugin
    function completeRecovery(address account)
        external 
        override 
        onlyEntryPoint 
        requireNotFrozen 
        recoverableAccount(account) 
    {
        ISocialRecoveryPlugin(account).receiveCompleteRecovery();
    }

    /// @inheritdoc ISocialRecoveryPlugin
    function receiveCompleteRecovery() external override onlyGuardian recoverable {
        _completeRecovery(msg.sender);
    }

    /// @inheritdoc ISocialRecoveryPlugin
    function getRecoveryRecords() external view override returns (RecoveryRecord[] memory) {
        SocialRecoveryPluginStorage storage $ = _getSocialRecoveryPluginStorage();
        return $.recoveryRecords;
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

    /// @inheritdoc ISocialRecoveryPlugin
    function isRecovering() external view override returns (bool) {
        return _existsPendingRecovery();
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
        emit ISocialRecoveryPlugin__UpdateRecoveryConfig(abi.encode(recoveryConfig));
    }

    function _checkSocialRecoveryConfig(RecoveryConfig memory recoveryConfig) private pure {
        if (recoveryConfig.maxGuardians == 0) {
            revert ISocialRecoveryPlugin__MaxGuardiansCanNotBeZero();
        }
    }

    function _updateCustomSocialRecoveryConfig(CustomRecoveryConfig memory customConfig) internal {
        _checkCustomSocialRecoveryConfig(customConfig);
        SocialRecoveryPluginStorage storage $ = _getSocialRecoveryPluginStorage();
        _updateGuardians(customConfig.guardians);
        $.customRecoveryConfig = customConfig;
        emit ISocialRecoveryPlugin__UpdateCustomRecoveryConfig(abi.encode(customConfig));
    }

    function _checkCustomSocialRecoveryConfig(CustomRecoveryConfig memory customConfig) private view {
        if (!customConfig.socialRecoveryEnabled) {
            return;
        }
        SocialRecoveryPluginStorage storage $ = _getSocialRecoveryPluginStorage();
        if ($.customRecoveryConfig.socialRecoveryEnabled 
            && !customConfig.socialRecoveryEnabled) {
            // If disable social recovery, check whether account is in recovering process
            _requireNotRecovering();
        }
        if (customConfig.minGuardianApprovals == 0) {
            revert ISocialRecoveryPlugin__MinGuardianApprovalsCanNotBeZero();
        }
        if (customConfig.guardians.length == 0) {
            revert ISocialRecoveryPlugin__NoGuardianSet();
        }
        if (customConfig.minGuardianApprovals > customConfig.guardians.length) {
            revert ISocialRecoveryPlugin__ApprovalExceedsGuardianAmount(
                customConfig.minGuardianApprovals, 
                customConfig.guardians.length
            );
        }
    }

    function _updateGuardians(address[] memory guardians) private {
        if (guardians.length == 0) {
            return;
        }
        SocialRecoveryPluginStorage storage $ = _getSocialRecoveryPluginStorage();
        $.guardians.clear();
        for (uint256 i = 0; i < guardians.length; i++) {
            _grantRole(GUARDIAN_ROLE, guardians[i]);
            $.guardians.add(guardians[i]);
        }
        emit ISocialRecoveryPlugin__UpdateGuardians(guardians.length);
    }

    function _getPendingRecovery() private view returns (RecoveryRecord storage) {
        SocialRecoveryPluginStorage storage $ = _getSocialRecoveryPluginStorage();
        if ($.recoveryRecords.length == 0) {
            revert ISocialRecoveryPlugin__NotInRecoveryProcess();
        }
        RecoveryRecord storage latestRecord = $.recoveryRecords[$.recoveryRecords.length - 1];
        if (latestRecord.isCompleted || latestRecord.isCancelled) {
            revert ISocialRecoveryPlugin__NotInRecoveryProcess();
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
        RecoveryRecord storage recoveryRecord = _getPendingRecovery();
        uint256 currentApprovals = recoveryRecord.approvedGuardians.length;
        uint256 requiredApprovals = recoveryRecord.requiredApprovals;
        if (currentApprovals < requiredApprovals) {
            revert ISocialRecoveryPlugin__InsufficientApprovals(currentApprovals, requiredApprovals);
        }
        if (block.timestamp < recoveryRecord.executableTime) {
            revert ISocialRecoveryPlugin__RecoveryNotExecutable(recoveryRecord.executableTime);
        }
        recoveryRecord.isCompleted = true;
        recoveryRecord.completedBy = completedBy;
        _unfreezeAccount(completedBy);
        _transferOwnership(recoveryRecord.newOwner);
        emit ISocialRecoveryPlugin__RecoveryCompleted(
            recoveryRecord.previousOwner, 
            recoveryRecord.newOwner,
            abi.encode(recoveryRecord)
        );
    }

    function _supportsSocialRecovery() private view returns (bool) {
        SocialRecoveryPluginStorage storage $ = _getSocialRecoveryPluginStorage();
        return $.customRecoveryConfig.socialRecoveryEnabled;
    }

    function _requireNotRecovering() internal view {
        if (_existsPendingRecovery()) {
            revert ISocialRecoveryPlugin__AccountIsInRecoveryProcess();
        }
    }

    function _existsPendingRecovery() private view returns (bool) {
        SocialRecoveryPluginStorage storage $ = _getSocialRecoveryPluginStorage();
        if (!$.customRecoveryConfig.socialRecoveryEnabled) {
            return false;
        }
        if ($.recoveryRecords.length == 0) {
            return false;
        }
        RecoveryRecord memory latestRecord = $.recoveryRecords[$.recoveryRecords.length - 1];
        return !(latestRecord.isCompleted || latestRecord.isCancelled);
    }

    function _requireSupportsSocialRecovery() private view {
        if (!_supportsSocialRecovery()) {
            revert ISocialRecoveryPlugin__SocialRecoveryNotSupported();
        }
    }

    function _requireSupportsSocialRecovery(address account) private view {
        _requireSFAccount(account);
        if (!ISocialRecoveryPlugin(account).supportsSocialRecovery()) {
            revert ISocialRecoveryPlugin__SocialRecoveryNotSupported();
        }
    }
}