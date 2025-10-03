// SPDX-License-Identifier: MIT
pragma solidity ^0.8.30;

import {SFAccount} from "./SFAccount.sol";
import {ISFAccount} from "../interfaces/ISFAccount.sol";
import {ISocialRecoveryPlugin} from "../interfaces/ISocialRecoveryPlugin.sol";
import {IVaultPlugin} from "../interfaces/IVaultPlugin.sol";
import {ERC165Checker} from "@openzeppelin/contracts/utils/introspection/ERC165Checker.sol";
import {BeaconProxy} from "@openzeppelin/contracts/proxy/beacon/BeaconProxy.sol";
import {OwnableUpgradeable} from "@openzeppelin/contracts-upgradeable/access/OwnableUpgradeable.sol";
import {UUPSUpgradeable} from "@openzeppelin/contracts-upgradeable/proxy/utils/UUPSUpgradeable.sol";

/**
 * @title SFAccountFactory
 * @dev Factory contract for deploying SFAccount proxy instances
 * @notice Implements UUPS upgrade pattern with BeaconProxy deployment
 */
contract SFAccountFactory is UUPSUpgradeable, OwnableUpgradeable {

    using ERC165Checker for address;

    error SFAccountFactory__OnlyOwner();
    error SFAccountFactory__IncompatibleImplementation();
    error SFAccountFactory__NotFromEntryPoint();

    event SFAccountFactory__CreateAccount(address indexed account, address indexed owner);

    address private entryPointAddress;
    address private sfEngineAddress;
    address private sfAccountImplementation;
    address private beaconAddress;
    IVaultPlugin.VaultConfig private vaultConfig;
    ISocialRecoveryPlugin.RecoveryConfig private recoveryConfig;

    function initialize(
        address _entryPointAddress,
        address _sfEngineAddress,
        address _beaconAddress,
        IVaultPlugin.VaultConfig memory _vaultConfig,
        ISocialRecoveryPlugin.RecoveryConfig memory _recoveryConfig
    ) external initializer {
        __UUPSUpgradeable_init();
        __Ownable_init(msg.sender);
        entryPointAddress = _entryPointAddress;
        sfEngineAddress = _sfEngineAddress;
        beaconAddress = _beaconAddress;
        vaultConfig = _vaultConfig;
        recoveryConfig = _recoveryConfig;
    }

    function createSFAccount(
        address _accountOwner,
        bytes32 _salt,
        IVaultPlugin.CustomVaultConfig memory _customVaultConfig,
        ISocialRecoveryPlugin.CustomRecoveryConfig memory _customRecoveryConfig
    ) external returns (address) {
        address accountProxyAddress = _deployBeaconProxy(_salt);
        SFAccount accountProxy = SFAccount(accountProxyAddress);
        accountProxy.initialize(
            _accountOwner,
            entryPointAddress,
            sfEngineAddress,
            address(this),
            vaultConfig,
            _customVaultConfig,
            recoveryConfig,
            _customRecoveryConfig
        );  
        emit SFAccountFactory__CreateAccount(accountProxyAddress, _accountOwner);
        return accountProxyAddress;
    }

    function _deployBeaconProxy(bytes32 salt) private returns (address) {
        return address(new BeaconProxy{salt: salt}(beaconAddress, ""));
    }

    function _authorizeUpgrade(address newImplementation) internal view override onlyOwner {
        if (!newImplementation.supportsInterface(type(ISFAccount).interfaceId)) {
            revert SFAccountFactory__IncompatibleImplementation();
        }
    }

    function _requireFromEntryPoint() private view {
        if (msg.sender != entryPointAddress) {
            revert SFAccountFactory__NotFromEntryPoint();
        }
    }
}