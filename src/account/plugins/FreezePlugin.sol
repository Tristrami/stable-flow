// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {IFreezePlugin} from "../../interfaces/IFreezePlugin.sol";
import {BaseSFAccountPlugin} from "./BaseSFAccountPlugin.sol";

/**
 * @title FreezePlugin
 * @notice Provides account freezing/unfreezing functionality for StableFlow protocol
 * @dev Key features:
 * - Emergency account freezing via EntryPoint
 * - Complete freeze history tracking
 * - State-machine based freeze management
 * @dev Security features:
 * - Only EntryPoint can trigger freeze/unfreeze
 * - Immutable freeze records for auditing
 * - Storage isolation via diamond pattern
 */
abstract contract FreezePlugin is IFreezePlugin, BaseSFAccountPlugin {

    /* -------------------------------------------------------------------------- */
    /*                                    Types                                   */
    /* -------------------------------------------------------------------------- */

    /**
     * @dev Storage structure for FreezePlugin state management
     */
    struct FreezePluginStorage {
        /// @dev Account frozen status flag
        /// @notice When true, restricts most account operations
        /// @notice Only modifiable by privileged contracts (EntryPoint)
        bool frozen;
        /// @dev Historical record of account freeze events
        /// @notice Contains timestamps and reasons for each freeze/unfreeze
        /// @notice Helps track account security history and compliance
        FreezeRecord[] freezeRecords;
    }

    /* -------------------------------------------------------------------------- */
    /*                                  Constants                                 */
    /* -------------------------------------------------------------------------- */

    // keccak256(abi.encode(uint256(keccak256("stableflow.storage.FreezePlugin")) - 1)) & ~bytes32(uint256(0xff))
    bytes32 private constant FREEZE_PLUGIN_STORAGE_LOCATION = 0xc3a8e91e66054e79d0673b1e47c66424c1d29ab554156bd0078e8cd7db97e300;

    /* -------------------------------------------------------------------------- */
    /*                                  Modifiers                                 */
    /* -------------------------------------------------------------------------- */

    /**
     * @dev Modifier to enforce frozen account state
     * @notice Reverts with `IFreezePlugin__AccountIsNotFrozen` if account is not frozen
     * @notice Used to restrict actions that require frozen state
     * @dev Internally calls `_requireFrozen()` validation
     */
    modifier requireFrozen() {
        _requireFrozen();
        _;
    }

    /**
     * @dev Modifier to enforce non-frozen account state
     * @notice Reverts with `IFreezePlugin__AccountIsFrozen` if account is frozen
     * @notice Used to protect standard operations when account is frozen
     * @dev Internally calls `_requireNotFrozen()` validation
     */
    modifier requireNotFrozen() {
        _requireNotFrozen();
        _;
    }

    /* -------------------------------------------------------------------------- */
    /*                                 Initializer                                */
    /* -------------------------------------------------------------------------- */

    /**
     * @dev Initializes the FreezePlugin storage
     * @notice Sets initial state:
     * - `frozen` flag to false (unfrozen by default)
     * - Initializes empty freezeRecords array
     * @notice Called during contract initialization
     * Requirements:
     * - Must be called through proxy initialization
     * - Storage must not be previously initialized
     */
    function __FreezePlugin_init() internal {
        FreezePluginStorage storage $ = _getFreezePluginStorage();
        $.frozen = false;
    }

    /* -------------------------------------------------------------------------- */
    /*                         External / Public Functions                        */
    /* -------------------------------------------------------------------------- */

    /// @inheritdoc IFreezePlugin
    function freeze() external override onlyEntryPoint {
        _freezeAccount(address(this));
    }

    /// @inheritdoc IFreezePlugin
    function unfreeze() external override onlyEntryPoint {
        _unfreezeAccount(address(this));
    }

    /// @inheritdoc IFreezePlugin
    function isFrozen() public view override returns (bool) {
        return _isFrozen();
    }

    /// @inheritdoc IFreezePlugin
    function getFreezeRecords() external view override returns (FreezeRecord[] memory) {
        FreezePluginStorage storage $ = _getFreezePluginStorage();
        return $.freezeRecords;
    }

    /* -------------------------------------------------------------------------- */
    /*                        Internal / Private Functions                        */
    /* -------------------------------------------------------------------------- */

    /**
     * @dev Returns the storage pointer for FreezePluginStorage at predefined slot
     * @return $ The FreezePluginStorage struct at fixed storage location
     * @notice Uses assembly to access storage at constant slot location
     */
    function _getFreezePluginStorage() private pure returns (FreezePluginStorage storage $) {
        assembly {
            $.slot := FREEZE_PLUGIN_STORAGE_LOCATION
        }
    }

    /**
     * @dev Freezes the account and records freeze operation
     * @param frozenBy Address initiating the freeze
     * Emits IFreezePlugin__FreezeAccount event
     * Requirements:
     * - Account must not already be frozen
     */
    function _freezeAccount(address frozenBy) internal {
        _requireNotFrozen();
        FreezePluginStorage storage $ = _getFreezePluginStorage();
        $.frozen = true;
        FreezeRecord memory freezeRecord = FreezeRecord({
            frozenBy: frozenBy,
            unfrozenBy: address(0),
            isUnfrozen: false
        });
        $.freezeRecords.push(freezeRecord);
        emit IFreezePlugin__FreezeAccount(frozenBy);
    }

    /**
     * @dev Unfreezes the account and updates freeze record
     * @param unfrozenBy Address initiating the unfreeze
     * Emits IFreezePlugin__UnfreezeAccount event
     * Requirements:
     * - Account must be frozen
     * - Must pass _checkUnfreezeAccount validation
     */
    function _unfreezeAccount(address unfrozenBy) internal {
        _checkUnfreezeAccount(unfrozenBy);
        FreezePluginStorage storage $ = _getFreezePluginStorage();
        $.frozen = false;
        FreezeRecord storage freezeRecord = $.freezeRecords[$.freezeRecords.length - 1];
        freezeRecord.isUnfrozen = true;
        freezeRecord.unfrozenBy = unfrozenBy;
        emit IFreezePlugin__UnfreezeAccount(unfrozenBy);
    }

    /**
     * @dev Checks current freeze status
     * @return bool True if account is frozen, false otherwise
     */
    function _isFrozen() internal view returns (bool) {
        FreezePluginStorage storage $ = _getFreezePluginStorage();
        return $.frozen;
    }

    /**
     * @dev Requires account to be in frozen state
     * Reverts with IFreezePlugin__AccountIsNotFrozen if not frozen
     */
    function _requireFrozen() internal view {
        if (!this.isFrozen()) {
            revert IFreezePlugin__AccountIsNotFrozen();
        }
    }

    /**
     * @dev Requires account to be in unfrozen state
     * Reverts with IFreezePlugin__AccountIsFrozen if frozen
     */
    function _requireNotFrozen() internal view {
        if (this.isFrozen()) {
            revert IFreezePlugin__AccountIsFrozen();
        }
    }

    /**
     * @dev Virtual function for custom unfreeze validation logic
     * @param unfrozenBy Address attempting to unfreeze
     * @notice Must be implemented by inheriting contracts
     * @notice Provides extensibility for custom freeze policies
     */
    function _checkUnfreezeAccount(address unfrozenBy) internal view virtual;
}