// // SPDX-License-Identifier: MIT
// pragma solidity ^0.8.30;

// import {SFAccount} from "./SFAccount.sol";
// import {ISFAccount} from "../interfaces/ISFAccount.sol";
// import {ERC165Checker} from "@openzeppelin/contracts/utils/introspection/ERC165Checker.sol";
// import {BeaconProxy} from "@openzeppelin/contracts/proxy/beacon/BeaconProxy.sol";
// import {UpgradeableBeacon} from "@openzeppelin/contracts/proxy/beacon/UpgradeableBeacon.sol";
// import {OwnableUpgradeable} from "@openzeppelin/contracts-upgradeable/access/OwnableUpgradeable.sol";
// import {UUPSUpgradeable} from "@openzeppelin/contracts-upgradeable/proxy/utils/UUPSUpgradeable.sol";
// import {Create2} from "@openzeppelin/contracts/utils/Create2.sol";

// contract SFAccountFactory is UUPSUpgradeable, OwnableUpgradeable {

//     using ERC165Checker for address;

//     error SFAccountFactory__OnlyOwner();
//     error SFAccountFactory__IncompatibleImplementation();
//     error SFAccountFactory__NotFromEntryPoint();

//     event SFAccountFactory__AccountCreated(address indexed account, address indexed owner);

//     address[] private collaterals;
//     address[] private priceFeeds;
//     uint8 private maxGuardians; 
//     uint256 private recoveryTimeLock;
//     address private entryPointAddress;
//     address private sfEngineAddress;
//     address private sfAccountImplementation;
//     address private beaconAddress;

//     function initialize(
//         uint8 _maxGuardians, 
//         uint256 _recoveryTimeLock,
//         address _entryPointAddress,
//         address _sfEngineAddress,
//         address _beaconAddress
//     ) external initializer {
//         maxGuardians = _maxGuardians;
//         recoveryTimeLock = _recoveryTimeLock;
//         entryPointAddress = _entryPointAddress;
//         sfEngineAddress = _sfEngineAddress;
//         beaconAddress = _beaconAddress;
//     }

//     function createSFAccount(
//         address _accountOwner,
//         uint256 _customCollateralRatio,
//         bool _autoTopUpEnabled,
//         uint256 _autoTopUpThreshold,
//         bool _socialRecoveryEnabled,
//         uint8 _minGuardianApprovals,
//         address[] memory _guardians,
//         bytes32 salt
//     ) external returns (address) {
//         _requireFromEntryPoint();
//         address accountProxyAddress = _deployBeaconProxy(salt);
//         SFAccount accountProxy = SFAccount(accountProxyAddress);
//         accountProxy.initialize(
//             _accountOwner,
//             collaterals, 
//             priceFeeds, 
//             _customCollateralRatio, 
//             _autoTopUpEnabled,
//             _autoTopUpThreshold, 
//             _socialRecoveryEnabled, 
//             _minGuardianApprovals, 
//             _guardians, 
//             recoveryTimeLock,
//             maxGuardians, 
//             entryPointAddress,
//             sfEngineAddress, 
//             address(this)
//         );  
//         return accountProxyAddress;
//     }

//     function _deployBeaconProxy(bytes32 salt) private returns (address) {
//         bytes memory byteCode = abi.encodePacked(
//             type(BeaconProxy).creationCode,
//             beaconAddress,
//             hex""
//         );
//         return Create2.deploy(0, salt, byteCode);
//     }

//     function _authorizeUpgrade(address newImplementation) internal view override onlyOwner {
//         if (!newImplementation.supportsInterface(type(ISFAccount).interfaceId)) {
//             revert SFAccountFactory__IncompatibleImplementation();
//         }
//     }

//     function _requireFromEntryPoint() private view {
//         if (msg.sender != entryPointAddress) {
//             revert SFAccountFactory__NotFromEntryPoint();
//         }
//     }
// }