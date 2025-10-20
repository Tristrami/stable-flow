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
 * - Mintable/Burnable by contract owner
 * - UUPS upgrade pattern support
 * - Address and zero-value validation
 * @notice Key characteristics:
 * - Token symbol: "SF"
 * - Used as stablecoin/debt token in protocol
 * - Owner-restricted supply control
 * @notice Inherits from:
 * - Validator (input validation)
 * - ERC20Upgradeable (standard token)
 * - OwnableUpgradeable (ownership control)
 */
contract SFToken is ERC20Upgradeable, OwnableUpgradeable, AccessControlUpgradeable, UUPSUpgradeable {

    error SFToken__OnlyOwner();
    error SFToken__OnlyMinter();
    error SFToken__InsufficientBalance(uint256 balance);
    error SFToken__InvalidAccountAddress();
    error SFToken__TokenValueCanNotBeZero();

    event SFToken__TokenBurned(uint256 indexed amount);
    event SFToken__TokenMinted(uint256 indexed amount);

    bytes32 private constant MINTER = keccak256("MINTER");
    bytes32 private constant MINTER_ADMIN = keccak256("MINTER_ADMIN");

    modifier onlyMinter() {
        _requireMinter();
        _;
    }

    function initialize() external initializer {
        __ERC20_init("SFToken", "SF");
        __Ownable_init(msg.sender);
        __AccessControl_init();
        _setRoleAdmin(MINTER, MINTER_ADMIN);
        _grantRole(MINTER_ADMIN, msg.sender);
    }

    function mint(address account, uint256 value) external onlyMinter {
        _requireAccountAddressNotZero(account);
        _requireTokenValueNotZero(value);
        _mint(account, value);
        emit SFToken__TokenMinted(value);
    }

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

    function addMinter(address minter) external {
        grantRole(MINTER, minter);
    }

    function removeMinter(address minter) external {
        revokeRole(MINTER, minter);
    }

    function isMinter(address account) external view returns (bool) {
        return hasRole(MINTER, account);
    }

    function _authorizeUpgrade(address /** newImplementation */) internal override view {
        if (msg.sender != owner()) {
            revert SFToken__OnlyOwner();
        }
    }

    function _requireAccountAddressNotZero(address account) private pure {
        if (account == address(0)) {
            revert SFToken__InvalidAccountAddress();
        }
    }

    function _requireTokenValueNotZero(uint256 value) private pure {
        if (value == 0) {
            revert SFToken__TokenValueCanNotBeZero();
        }
    }

    function _requireMinter() private view {
        if (!hasRole(MINTER, msg.sender)) {
            revert SFToken__OnlyMinter();
        }
    }
}
