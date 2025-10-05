// SPDX-License-Identifier: MIT
pragma solidity ^0.8.30;

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

    modifier requireFrozen() {
        _requireFrozen();
        _;
    }

    modifier requireNotFrozen() {
        _requireNotFrozen();
        _;
    }

    /* -------------------------------------------------------------------------- */
    /*                                 Initializer                                */
    /* -------------------------------------------------------------------------- */

    function __FreezePlugin_init() internal {
        FreezePluginStorage storage $ = _getFreezePluginStorage();
        $.frozen = false;
    }

    /* -------------------------------------------------------------------------- */
    /*                         External / Public Functions                        */
    /* -------------------------------------------------------------------------- */

    /// @inheritdoc IFreezePlugin
    function freeze() external override onlyEntryPoint {
        _freezeAccount(owner());
    }

    /// @inheritdoc IFreezePlugin
    function unfreeze() external override onlyEntryPoint {
        _unfreezeAccount(owner());
    }

    /// @inheritdoc IFreezePlugin
    function isFrozen() public view override returns (bool) {
        return _isFrozen();
    }

    /* -------------------------------------------------------------------------- */
    /*                        Internal / Private Functions                        */
    /* -------------------------------------------------------------------------- */

    function _getFreezePluginStorage() private pure returns (FreezePluginStorage storage $) {
        assembly {
            $.slot := FREEZE_PLUGIN_STORAGE_LOCATION
        }
    }

    function _freezeAccount(address frozenBy) internal {
        _requireNotFrozen();
        FreezePluginStorage storage $ = _getFreezePluginStorage();
        $.frozen = true;
        FreezeRecord memory freezeRecord = FreezeRecord({
            frozenBy: frozenBy,
            unfrozenBy: address(0),
            isUnfozen: false
        });
        $.freezeRecords.push(freezeRecord);
        emit IFreezePlugin__FreezeAccount(frozenBy);
    }

    function _unfreezeAccount(address unfrozenBy) internal {
        _requireFrozen();
        FreezePluginStorage storage $ = _getFreezePluginStorage();
        $.frozen = false;
        FreezeRecord storage freezeRecord = $.freezeRecords[$.freezeRecords.length - 1];
        freezeRecord.isUnfozen = true;
        freezeRecord.unfrozenBy = unfrozenBy;
        emit IFreezePlugin__UnfreezeAccount(unfrozenBy);
    }

    function _isFrozen() internal view returns (bool) {
        FreezePluginStorage storage $ = _getFreezePluginStorage();
        return $.frozen;
    }

    function _requireFrozen() internal view {
        if (!this.isFrozen()) {
            revert IFreezePlugin__AccountIsNotFrozen();
        }
    }

    function _requireNotFrozen() internal view {
        if (this.isFrozen()) {
            revert IFreezePlugin__AccountIsFrozen();
        }
    }
}