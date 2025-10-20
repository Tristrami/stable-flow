// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

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
    error SFAccountFactory__MaxAccountAmountCanNotBeZero();
    error SFAccountFactory__IncompatibleImplementation();
    error SFAccountFactory__NotFromEntryPoint();
    error SFAccountFactory__AccountLimitReached(uint256 limit);

    event SFAccountFactory__CreateAccount(address indexed account, address indexed owner);

    address private entryPointAddress;
    address private sfEngineAddress;
    address private sfAccountImplementation;
    address private beaconAddress;
    uint256 private maxAccountAmount;
    address private automationRegistrarAddress;
    address private linkTokenAddress;
    IVaultPlugin.VaultConfig private vaultConfig;
    ISocialRecoveryPlugin.RecoveryConfig private recoveryConfig;
    mapping(address user => address[] sfAccounts) private userAccounts;

    function initialize(
        address _entryPointAddress,
        address _sfEngineAddress,
        address _beaconAddress,
        uint256 _maxAccountAmount,
        address _automationRegistrarAddress,
        address _linkTokenAddress,
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
        if (_maxAccountAmount == 0) {
            revert SFAccountFactory__MaxAccountAmountCanNotBeZero();
        }
        maxAccountAmount = _maxAccountAmount;
        automationRegistrarAddress = _automationRegistrarAddress;
        linkTokenAddress = _linkTokenAddress;
    }

    function reinitialize(
        uint64 _version,
        uint256 _maxAccountAmount,
        IVaultPlugin.VaultConfig memory _vaultConfig,
        ISocialRecoveryPlugin.RecoveryConfig memory _recoveryConfig
    ) external reinitializer(_version) {
        vaultConfig = _vaultConfig;
        recoveryConfig = _recoveryConfig;
        if (_maxAccountAmount == 0) {
            revert SFAccountFactory__MaxAccountAmountCanNotBeZero();
        }
    }

    function createSFAccount(
        address accountOwner,
        bytes32 salt,
        IVaultPlugin.CustomVaultConfig memory customVaultConfig,
        ISocialRecoveryPlugin.CustomRecoveryConfig memory customRecoveryConfig
    ) external returns (address) {
        address[] memory sfAccounts = userAccounts[accountOwner];
        if (sfAccounts.length == maxAccountAmount) {
            revert SFAccountFactory__AccountLimitReached(maxAccountAmount);
        }
        address accountProxyAddress = _deployBeaconProxy(salt);
        userAccounts[accountOwner].push(accountProxyAddress);
        SFAccount accountProxy = SFAccount(accountProxyAddress);
        accountProxy.initialize(
            accountOwner,
            entryPointAddress,
            sfEngineAddress,
            address(this),
            automationRegistrarAddress,
            linkTokenAddress,
            vaultConfig,
            customVaultConfig,
            recoveryConfig,
            customRecoveryConfig
        );  
        emit SFAccountFactory__CreateAccount(accountProxyAddress, accountOwner);
        return accountProxyAddress;
    }

    function getUserAccounts(address user) external view returns (address[] memory) {
        return userAccounts[user];
    }

    function getVaultConfig() external view returns (IVaultPlugin.VaultConfig memory) {
        return vaultConfig;
    }

    function getRecoveryConfig() external view returns (ISocialRecoveryPlugin.RecoveryConfig memory) {
        return recoveryConfig;
    }

    function getInitCode(
        address accountOwner,
        bytes32 salt,
        IVaultPlugin.CustomVaultConfig memory customVaultConfig,
        ISocialRecoveryPlugin.CustomRecoveryConfig memory customRecoveryConfig
    ) external view returns (bytes memory) {
        bytes memory initCallData = abi.encodeCall(
            SFAccountFactory.createSFAccount, 
            (
                accountOwner,
                salt,
                customVaultConfig,
                customRecoveryConfig
            )
        );
        return abi.encodePacked(address(this), initCallData);
    }

    function getSFAccountSalt(address user) public view returns (bytes32) {
        return keccak256(abi.encode(user, getSFAccountAmount(user)));
    }

    function getSFAccountAmount(address user) public view returns (uint256) {
        return userAccounts[user].length;
    }

    function getMaxAccountAmount() public view returns (uint256) {
        return maxAccountAmount;
    }

    function calculateAccountAddress(address beacon, address deployer) public view returns (address) {
        return calculateAccountAddress(beacon, getSFAccountSalt(deployer));
    }

    function calculateAccountAddress(
        address beacon,
        bytes32 salt
    ) public view returns (address) {
        bytes memory byteCode = abi.encodePacked(
            type(BeaconProxy).creationCode, 
            abi.encode(beacon, "")
        );
        bytes32 hash = keccak256(abi.encodePacked(
            bytes1(0xff),
            address(this),
            salt,
            keccak256(byteCode)
        ));
        return address(uint160(uint256(hash)));
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