// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {ERC20Upgradeable} from "@openzeppelin/contracts-upgradeable/token/ERC20/ERC20Upgradeable.sol";
import {OwnableUpgradeable} from "@openzeppelin/contracts-upgradeable/access/OwnableUpgradeable.sol";
import {UUPSUpgradeable} from "@openzeppelin/contracts-upgradeable/proxy/utils/UUPSUpgradeable.sol";
import {AccessControlUpgradeable} from "@openzeppelin/contracts-upgradeable/access/AccessControlUpgradeable.sol";

/**
 * @title SFToken
 * @dev Upgradeable ERC20 token contract for StableFlow protocol
 * @notice Core features:
 * - Mintable/Burnable by authorized minters
 * - UUPS upgrade pattern support
 * - Address and zero-value validation
 * - Role-based access control
 */
contract SFToken is ERC20Upgradeable, OwnableUpgradeable, AccessControlUpgradeable, UUPSUpgradeable {

    /* -------------------------------------------------------------------------- */
    /*                                   Errors                                   */
    /* -------------------------------------------------------------------------- */

    /**
     * @dev Error thrown when caller is not the contract owner
     * @notice Used in upgrade authorization and privileged functions
     */
    error SFToken__OnlyOwner();

    /**
     * @dev Error thrown when caller is not an authorized minter
     * @notice Used in mint/burn functions to enforce role-based access
     */
    error SFToken__OnlyMinter();

    /**
     * @dev Error thrown when account has insufficient token balance
     * @param balance Current token balance of the account
     * @notice Used in burn function to prevent overdrafts
     */
    error SFToken__InsufficientBalance(uint256 balance);

    /**
     * @dev Error thrown when account address is invalid (zero address)
     * @notice Used to validate recipient addresses in mint/transfer functions
     */
    error SFToken__InvalidAccountAddress();

    /**
     * @dev Error thrown when token amount is zero
     * @notice Used to prevent zero-value mint/burn/transfer operations
     */
    error SFToken__TokenValueCanNotBeZero();

    /* -------------------------------------------------------------------------- */
    /*                                   Events                                   */
    /* -------------------------------------------------------------------------- */

    /**
     * @dev Emitted when tokens are burned
     * @param amount Amount of tokens burned (indexed)
     */
    event SFToken__TokenBurned(uint256 indexed amount);

    /**
     * @dev Emitted when tokens are minted
     * @param amount Amount of tokens minted (indexed)
     */
    event SFToken__TokenMinted(uint256 indexed amount);

    /* -------------------------------------------------------------------------- */
    /*                                  Constants                                 */
    /* -------------------------------------------------------------------------- */

    /// @dev Role identifier for minters
    bytes32 private constant MINTER = keccak256("MINTER");
    /// @dev Role identifier for minter admins
    bytes32 private constant MINTER_ADMIN = keccak256("MINTER_ADMIN");

    /* -------------------------------------------------------------------------- */
    /*                                  Modifiers                                 */
    /* -------------------------------------------------------------------------- */

    /**
     * @dev Modifier to restrict access to authorized minters only
     */
    modifier onlyMinter() {
        _requireMinter();
        _;
    }

    /* -------------------------------------------------------------------------- */
    /*                         Public / External Functions                        */
    /* -------------------------------------------------------------------------- */

    /**
     * @dev Initializes the contract
     * @notice Sets up:
     * - Token name and symbol ("SFToken", "SF")
     * - Owner role
     * - Minter role hierarchy
     */
    function initialize() external initializer {
        __ERC20_init("SFToken", "SF");
        __Ownable_init(msg.sender);
        __AccessControl_init();
        _setRoleAdmin(MINTER, MINTER_ADMIN);
        _grantRole(MINTER_ADMIN, msg.sender);
    }

    /**
     * @dev Mints new tokens
     * @param account Address to receive minted tokens
     * @param value Amount of tokens to mint
     * Emits SFToken__TokenMinted event
     * Requirements:
     * - Caller must be authorized minter
     * - Account address must be valid
     * - Value must be non-zero
     */
    function mint(address account, uint256 value) external onlyMinter {
        _requireAccountAddressNotZero(account);
        _requireTokenValueNotZero(value);
        _mint(account, value);
        emit SFToken__TokenMinted(value);
    }

    /**
     * @dev Burns existing tokens
     * @param account Address whose tokens will be burned
     * @param value Amount of tokens to burn
     * Emits SFToken__TokenBurned event
     * Requirements:
     * - Caller must be authorized minter
     * - Account address must be valid
     * - Value must be non-zero
     * - Account must have sufficient balance
     */
    function burn(address account, uint256 value) external onlyMinter {
        _requireAccountAddressNotZero(account);
        _requireTokenValueNotZero(value);
        uint256 balance = balanceOf(account);
        if (balance < value) {
            revert SFToken__InsufficientBalance(balance);
        }
        _burn(account, value);
        emit SFToken__TokenBurned(value);
    }

    /**
     * @dev Grants minter role to address
     * @param minter Address to grant minter role
     * Requirements:
     * - Caller must have MINTER_ADMIN role
     */
    function addMinter(address minter) external {
        grantRole(MINTER, minter);
    }

    /**
     * @dev Revokes minter role from address
     * @param minter Address to revoke minter role from
     * Requirements:
     * - Caller must have MINTER_ADMIN role
     */
    function removeMinter(address minter) external {
        revokeRole(MINTER, minter);
    }

    /**
     * @dev Checks if address has minter role
     * @param account Address to check
     * @return bool True if address has minter role
     */
    function isMinter(address account) external view returns (bool) {
        return hasRole(MINTER, account);
    }

    /* -------------------------------------------------------------------------- */
    /*                        Private / Internal Functions                        */
    /* -------------------------------------------------------------------------- */

    /**
     * @dev Authorizes contract upgrades
     * Requirements:
     * - Caller must be owner
     */
    function _authorizeUpgrade(address /** newImplementation */) internal override view {
        if (msg.sender != owner()) {
            revert SFToken__OnlyOwner();
        }
    }

    /**
     * @dev Validates account address is not zero
     * @param account Address to validate
     */
    function _requireAccountAddressNotZero(address account) private pure {
        if (account == address(0)) {
            revert SFToken__InvalidAccountAddress();
        }
    }

    /**
     * @dev Validates token amount is not zero
     * @param value Amount to validate
     */
    function _requireTokenValueNotZero(uint256 value) private pure {
        if (value == 0) {
            revert SFToken__TokenValueCanNotBeZero();
        }
    }

    /**
     * @dev Validates caller has minter role
     */
    function _requireMinter() private view {
        if (!hasRole(MINTER, msg.sender)) {
            revert SFToken__OnlyMinter();
        }
    }
}