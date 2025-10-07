// SPDX-License-Identifier: MIT
pragma solidity ^0.8.30;

import {ISFAccount} from "../../interfaces/ISFAccount.sol";
import {BaseAccount} from "account-abstraction/contracts/core/BaseAccount.sol";
import {ERC165Checker} from "@openzeppelin/contracts/utils/introspection/ERC165Checker.sol";
import {OwnableUpgradeable} from "@openzeppelin/contracts-upgradeable/access/OwnableUpgradeable.sol";
import {AccessControlUpgradeable} from "@openzeppelin/contracts-upgradeable/access/AccessControlUpgradeable.sol";

/**
 * @title BaseSFAccountPlugin
 * @dev Abstract base contract for all SFAccount plugins
 * @notice Provides core functionality required by all SFAccount plugins:
 * - EntryPoint access control (ERC-4337)
 * - Account frozen state management
 * - SFAccount interface verification
 * - Upgradeable ownership and role-based access
 * @notice Key features:
 * - Implements ERC-4337 BaseAccount standard
 * - Supports upgradeable plugin architecture
 * - Provides frozen state protection
 * - Enforces SFAccount interface compliance
 * @notice Inherits from:
 * - ISFAccount (interface)
 * - BaseAccount (ERC-4337)
 * - OwnableUpgradeable (upgradeable ownership)
 * - AccessControlUpgradeable (role-based access)
 */
abstract contract BaseSFAccountPlugin is ISFAccount, BaseAccount, OwnableUpgradeable, AccessControlUpgradeable {

    using ERC165Checker for address;

    error BaseSFAccountPlugin__NotSFAccount();

    modifier onlyEntryPoint() {
        _requireFromEntryPoint();
        _;
    }

    modifier onlySFAccount(address account) {
        _requireSFAccount(account);
        _;
    }

    function _requireSFAccount(address account) internal view {
        if (account == address(0) 
            || account.code.length == 0
            || !account.supportsInterface(type(ISFAccount).interfaceId)) {
            revert BaseSFAccountPlugin__NotSFAccount();
        }
    }

}