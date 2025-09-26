// SPDX-License-Identifier: MIT
pragma solidity ^0.8.30;

import {ISFAccount} from "../../interfaces/ISFAccount.sol";
import {BaseAccount} from "account-abstraction/contracts/core/BaseAccount.sol";
import {ERC165Checker} from "@openzeppelin/contracts/utils/introspection/ERC165Checker.sol";
import {OwnableUpgradeable} from "@openzeppelin/contracts-upgradeable/access/OwnableUpgradeable.sol";
import {AccessControlUpgradeable} from "@openzeppelin/contracts-upgradeable/access/AccessControlUpgradeable.sol";

abstract contract BaseSFAccountPlugin is ISFAccount, BaseAccount, OwnableUpgradeable, AccessControlUpgradeable {

    using ERC165Checker for address;

    error BaseSFAccountPlugin__NotSFAccount(address account);
    error BaseSFAccountPlugin__AccountIsNotFrozen();
    error BaseSFAccountPlugin__AccountIsFrozen();

    modifier onlyEntryPoint() {
        _requireFromEntryPoint();
        _;
    }

    modifier onlySFAccount(address account) {
        _requireSFAccount(account);
        _;
    }

    modifier requireFrozen() {
        _requireFrozen();
        _;
    }

    modifier requireNotFrozen() {
        _requireNotFrozen();
        _;
    }

    function _requireSFAccount(address account) internal view {
        if (!account.supportsInterface(type(ISFAccount).interfaceId)) {
            revert BaseSFAccountPlugin__NotSFAccount(account);
        }
    }

    function _requireFrozen() internal view {
        if (!this.isFrozen()) {
            revert BaseSFAccountPlugin__AccountIsNotFrozen();
        }
    }

    function _requireNotFrozen() internal view {
        if (this.isFrozen()) {
            revert BaseSFAccountPlugin__AccountIsFrozen();
        }
    }

}