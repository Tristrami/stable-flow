// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

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

    /**
     * @dev Error thrown when an address is not a valid SFAccount contract
     * @notice Indicates either:
     * - Address is zero
     * - Address contains no code
     * - Address doesn't implement ISFAccount interface
     */
    error BaseSFAccountPlugin__NotSFAccount();

    /**
     * @dev Modifier to restrict access to EntryPoint contract only
     * @notice Reverts with custom error if caller is not the EntryPoint
     * @notice Used to protect functions that should only be called during user operations
     * @dev Internally calls `_requireFromEntryPoint()` validation
     */
    modifier onlyEntryPoint() {
        _requireFromEntryPoint();
        _;
    }

    /**
     * @dev Modifier to validate an address is a proper SFAccount
     * @param account Address to validate
     * @notice Reverts with BaseSFAccountPlugin__NotSFAccount if:
     * - Address is zero
     * - Address is not a contract
     * - Doesn't implement ISFAccount interface
     * @notice Used when interacting with external SFAccount contracts
     */
    modifier onlySFAccount(address account) {
        _requireSFAccount(account);
        _;
    }

    /**
     * @dev Internal validation for SFAccount contracts
     * @param account Address to validate
     * @notice Performs three checks:
     * 1. Non-zero address check
     * 2. Contract existence check (code size > 0)
     * 3. Interface support check (ISFAccount)
     * @notice Reverts with BaseSFAccountPlugin__NotSFAccount on failure
     */
    function _requireSFAccount(address account) internal view {
        if (account == address(0) 
            || account.code.length == 0
            || !account.supportsInterface(type(ISFAccount).interfaceId)) {
            revert BaseSFAccountPlugin__NotSFAccount();
        }
    }

}