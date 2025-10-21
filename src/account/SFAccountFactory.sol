// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {ISFAccountFactory} from "../interfaces/ISFAccountFactory.sol";
import {ISFAccount} from "../interfaces/ISFAccount.sol";
import {SFAccount} from "./SFAccount.sol";
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
 * @notice Manages account creation with configurable vault and recovery settings
 */
contract SFAccountFactory is ISFAccountFactory, UUPSUpgradeable, OwnableUpgradeable {

    using ERC165Checker for address;

    /* -------------------------------------------------------------------------- */
    /*                               State Variables                              */
    /* -------------------------------------------------------------------------- */

    /// @dev EntryPoint contract address
    address private entryPointAddress;
    /// @dev SFEngine contract address
    address private sfEngineAddress;
    /// @dev SFAccount implementation address
    address private sfAccountImplementation;
    /// @dev Beacon contract address
    address private beaconAddress;
    /// @dev Maximum accounts allowed per user
    uint256 private maxAccountAmount;
    /// @dev Chainlink Automation registrar address
    address private automationRegistrarAddress;
    /// @dev LINK token contract address
    address private linkTokenAddress;
    /// @dev Base vault configuration
    IVaultPlugin.VaultConfig private vaultConfig;
    /// @dev Base recovery configuration
    ISocialRecoveryPlugin.RecoveryConfig private recoveryConfig;
    /// @dev Mapping of user addresses to their created accounts
    mapping(address user => address[] sfAccounts) private userAccounts;

    /* -------------------------------------------------------------------------- */
    /*                                Initializers                                */
    /* -------------------------------------------------------------------------- */

    /**
     * @dev Initializes the factory contract
     * @param _entryPointAddress EntryPoint contract address
     * @param _sfEngineAddress SFEngine contract address
     * @param _beaconAddress Beacon contract address
     * @param _maxAccountAmount Maximum accounts per user
     * @param _automationRegistrarAddress Chainlink Automation registrar
     * @param _linkTokenAddress LINK token address
     * @param _vaultConfig Base vault configuration
     * @param _recoveryConfig Base recovery configuration
     * Requirements:
     * - _maxAccountAmount must be greater than zero
     */
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
            revert ISFAccountFactory__MaxAccountAmountCanNotBeZero();
        }
        maxAccountAmount = _maxAccountAmount;
        automationRegistrarAddress = _automationRegistrarAddress;
        linkTokenAddress = _linkTokenAddress;
    }

    /**
     * @dev Reinitializes contract with new configuration
     * @param _version Reinitialization version
     * @param _maxAccountAmount New maximum accounts per user
     * @param _vaultConfig New vault configuration
     * @param _recoveryConfig New recovery configuration
     * Requirements:
     * - _maxAccountAmount must be greater than zero
     */
    function reinitialize(
        uint64 _version,
        uint256 _maxAccountAmount,
        IVaultPlugin.VaultConfig memory _vaultConfig,
        ISocialRecoveryPlugin.RecoveryConfig memory _recoveryConfig
    ) external reinitializer(_version) {
        vaultConfig = _vaultConfig;
        recoveryConfig = _recoveryConfig;
        if (_maxAccountAmount == 0) {
            revert ISFAccountFactory__MaxAccountAmountCanNotBeZero();
        }
    }

    /* -------------------------------------------------------------------------- */
    /*                         Public / External Functions                        */
    /* -------------------------------------------------------------------------- */

    /// @inheritdoc ISFAccountFactory
    function createSFAccount(
        address accountOwner,
        bytes32 salt,
        IVaultPlugin.CustomVaultConfig memory customVaultConfig,
        ISocialRecoveryPlugin.CustomRecoveryConfig memory customRecoveryConfig
    ) external override returns (address) {
        address[] memory sfAccounts = userAccounts[accountOwner];
        if (sfAccounts.length == maxAccountAmount) {
            revert ISFAccountFactory__AccountLimitReached(maxAccountAmount);
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
        emit ISFAccountFactory__CreateAccount(accountProxyAddress, accountOwner);
        return accountProxyAddress;
    }

    /// @inheritdoc ISFAccountFactory
    function getUserAccounts(address user) external view returns (address[] memory) {
        return userAccounts[user];
    }

    /// @inheritdoc ISFAccountFactory
    function getVaultConfig() external view returns (IVaultPlugin.VaultConfig memory) {
        return vaultConfig;
    }

    /// @inheritdoc ISFAccountFactory
    function getRecoveryConfig() external view returns (ISocialRecoveryPlugin.RecoveryConfig memory) {
        return recoveryConfig;
    }

    /// @inheritdoc ISFAccountFactory
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

    /// @inheritdoc ISFAccountFactory
    function getSFAccountSalt(address user) public view returns (bytes32) {
        return keccak256(abi.encode(user, getSFAccountAmount(user)));
    }

    /// @inheritdoc ISFAccountFactory
    function getSFAccountAmount(address user) public view returns (uint256) {
        return userAccounts[user].length;
    }

    /// @inheritdoc ISFAccountFactory
    function getMaxAccountAmount() public view returns (uint256) {
        return maxAccountAmount;
    }

    /// @inheritdoc ISFAccountFactory
    function calculateAccountAddress(address beacon, address deployer) public view returns (address) {
        return calculateAccountAddress(beacon, getSFAccountSalt(deployer));
    }

    /// @inheritdoc ISFAccountFactory
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

    /* -------------------------------------------------------------------------- */
    /*                        Private / Internal Functions                        */
    /* -------------------------------------------------------------------------- */

    /**
     * @dev Deploys new BeaconProxy instance
     * @param salt Deployment salt
     * @return address Address of deployed proxy
     */
    function _deployBeaconProxy(bytes32 salt) private returns (address) {
        return address(new BeaconProxy{salt: salt}(beaconAddress, ""));
    }

    /**
     * @dev Authorizes contract upgrades
     * @param newImplementation Address of new implementation
     * Requirements:
     * - Caller must be owner
     * - New implementation must support ISFAccount interface
     */
    function _authorizeUpgrade(address newImplementation) internal view override onlyOwner {
        if (!newImplementation.supportsInterface(type(ISFAccount).interfaceId)) {
            revert ISFAccountFactory__IncompatibleImplementation();
        }
    }

    /**
     * @dev Validates caller is entry point
     * Requirements:
     * - msg.sender must be entryPointAddress
     */
    function _requireFromEntryPoint() private view {
        if (msg.sender != entryPointAddress) {
            revert ISFAccountFactory__NotFromEntryPoint();
        }
    }
}