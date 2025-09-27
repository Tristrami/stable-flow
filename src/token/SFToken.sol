// SPDX-License-Identifier: MIT
pragma solidity ^0.8.30;

import {ERC20Upgradeable} from "@openzeppelin/contracts-upgradeable/token/ERC20/ERC20Upgradeable.sol";
import {OwnableUpgradeable} from "@openzeppelin/contracts-upgradeable/access/OwnableUpgradeable.sol";

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
contract SFToken is ERC20Upgradeable, OwnableUpgradeable {

    error SFToken__InsufficientBalance(uint256 balance);
    error SFToken__InvalidAccountAddress();
    error SFToken__TokenValueCanNotBeZero();

    event SFToken__TokenBurned(uint256 indexed amount);
    event SFToken__TokenMinted(uint256 indexed amount);


    function initialize() external initializer {
        __ERC20_init("SFToken", "SF");
        __Ownable_init(msg.sender);
    }

    function mint(address account, uint256 value) external onlyOwner {
        _requireAccountAddressNotZero(account);
        _requireTokenValueNotZero(value);
        _mint(account, value);
        emit SFToken__TokenMinted(value);
    }

    function burn(address account, uint256 value) external onlyOwner {
        _requireAccountAddressNotZero(account);
        _requireTokenValueNotZero(value);
        uint256 balance = balanceOf(account);
        if (balance < value) {
            revert SFToken__InsufficientBalance(balance);
        }
        _burn(account, value);
        emit SFToken__TokenBurned(value);
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
}
