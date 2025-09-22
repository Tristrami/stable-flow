// SPDX-License-Identifier: MIT
pragma solidity ^0.8.30;

import {Validator} from "./Validator.sol";
import {ERC20Upgradeable} from "@openzeppelin/contracts-upgradeable/token/ERC20/ERC20Upgradeable.sol";
import {OwnableUpgradeable} from "@openzeppelin/contracts-upgradeable/access/OwnableUpgradeable.sol";

contract SFToken is Validator, ERC20Upgradeable, OwnableUpgradeable {

    event SFToken__TokenBurned(uint256 indexed amount);
    event SFToken__TokenMinted(uint256 indexed amount);

    error SFToken__InsufficientBalance(uint256 balance);

    function initialize() external initializer {
        __ERC20_init("SFToken", "SF");
        __Ownable_init(msg.sender);
    }

    function mint(address account, uint256 value) external onlyOwner notZeroAddress(account) notZeroValue(value) {
        _mint(account, value);
        emit SFToken__TokenMinted(value);
    }

    function burn(address account, uint256 value) external onlyOwner notZeroAddress(account) notZeroValue(value) {
        uint256 balance = balanceOf(account);
        if (balance < value) {
            revert SFToken__InsufficientBalance(balance);
        }
        _burn(account, value);
        emit SFToken__TokenBurned(value);
    }

}
