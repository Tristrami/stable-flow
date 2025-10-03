// SPDX-License-Identifier: MIT
pragma solidity ^0.8.30;

import {Script, console2} from "forge-std/Script.sol";
import {Vm} from "forge-std/Vm.sol";
import {Logs} from "./util/Logs.sol";
import {SFAccountFactory} from "../src/account/SFAccountFactory.sol";
import {ISFAccount} from "../src/interfaces/ISFAccount.sol";
import {IVaultPlugin} from "../src/interfaces/IVaultPlugin.sol";
import {ISocialRecoveryPlugin} from "../src/interfaces/ISocialRecoveryPlugin.sol";
import {DevOps} from "../script/util/DevOps.s.sol";
import {Constants} from "../script/util/Constants.sol";
import {BeaconProxy} from "@openzeppelin/contracts/proxy/beacon/BeaconProxy.sol";
import {PackedUserOperation} from "account-abstraction/contracts/interfaces/PackedUserOperation.sol";
import {IEntryPoint} from "account-abstraction/contracts/interfaces/IEntryPoint.sol";

contract Base is Script, Constants {

    DevOps internal devOps;

    constructor() {
        devOps = new DevOps();
    }

    function _createUserOp(
        address account,
        address entryPointAddress,
        address sender,
        bytes memory initCode,
        bytes memory callData
    ) internal view returns (PackedUserOperation memory userOp) {
        uint128 verificationGasLimit = 16777216;
        uint128 callGasLimit = verificationGasLimit;
        uint128 maxPriorityFeePerGas = 256;
        uint128 maxFeePerGas = maxPriorityFeePerGas;
        // bytes32(uint256(verificationGasLimit) << 128 | callGasLimit
        // This puts `verificationGasLimit` at high 128 bits, and put `callGasLimit` at low 128 bits
        userOp = PackedUserOperation({
            sender: sender,
            nonce: IEntryPoint(entryPointAddress).getNonce(sender, 0),
            initCode: initCode,
            callData: callData,
            accountGasLimits: bytes32(uint256(verificationGasLimit) << 128 | callGasLimit),
            preVerificationGas: verificationGasLimit,
            gasFees: bytes32(uint256(maxPriorityFeePerGas) << 128 | maxFeePerGas),
            paymasterAndData: "",
            signature: ""
        });
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(account, IEntryPoint(entryPointAddress).getUserOpHash(userOp));
        userOp.signature = abi.encodePacked(r, s, v);
        return userOp;
    }
}

contract CreateAccount is Base {

    function run() external {
        createAccount(
            msg.sender,
            devOps.getLatestDeployment("EntryPoint"),
            devOps.getLatestDeployment("SFAccountFactory"), 
            devOps.getLatestDeployment("SFAccountBeacon")
        );
    }

    function createAccount(
        address account,
        address entryPointAddress,
        address sfAccountFactoryAddress, 
        address beaconAddress
    ) public returns (address sfAccount) {
        bytes32 salt = getSalt(account);
        sfAccount = calculateAccountAddress(sfAccountFactoryAddress, beaconAddress, salt);
        console2.log("Calculated account address:", account);
        string memory accountConfigJson = vm.readFile("script/config/AccountConfig.json");
        bytes memory customVaultConfigBytes = vm.parseJson(accountConfigJson, ".customVaultConfig");
        bytes memory customRecoveryConfigBytes = vm.parseJson(accountConfigJson, ".customRecoveryConfig");
        IVaultPlugin.CustomVaultConfig memory customVaultConfig = abi.decode(
            customVaultConfigBytes,
            (IVaultPlugin.CustomVaultConfig)
        );
        ISocialRecoveryPlugin.CustomRecoveryConfig memory customRecoveryConfig = abi.decode(
            customRecoveryConfigBytes,
            (ISocialRecoveryPlugin.CustomRecoveryConfig)
        );
        bytes memory initCallData = abi.encodeCall(
            SFAccountFactory.createSFAccount, 
            (
                account,
                salt,
                customVaultConfig,
                customRecoveryConfig
            )
        );
        bytes memory initCode = abi.encodePacked(sfAccountFactoryAddress, initCallData);
        bytes memory callData = abi.encodeCall(ISFAccount.createAccount, ());
        PackedUserOperation[] memory userOps = new PackedUserOperation[](1);
        userOps[0] = _createUserOp(account, entryPointAddress, sfAccount, initCode, callData);
        vm.startBroadcast(account);
        IEntryPoint(entryPointAddress).handleOps(userOps, payable(account));
        vm.stopBroadcast();
    }

    function calculateAccountAddress(
        address sfAccountFactoryAddress, 
        address beaconAddress,
        bytes32 salt
    ) public pure returns (address) {
        bytes memory byteCode = abi.encodePacked(
            type(BeaconProxy).creationCode, 
            abi.encode(beaconAddress, "")
        );
        bytes32 hash = keccak256(abi.encodePacked(
            bytes1(0xff),
            sfAccountFactoryAddress,
            salt,
            keccak256(byteCode)
        ));
        return address(uint160(uint256(hash)));
    }

    function getSalt(address sfAccountOwner) public pure returns (bytes32) {
        return bytes32(uint256(uint160(sfAccountOwner)));
    }
}

contract Transfer is Base {
    function run() external {
        vm.startBroadcast();

        vm.stopBroadcast();
    }
}

contract Invest is Base {
    function run() external {
        vm.startBroadcast();

        vm.stopBroadcast();
    }
}

contract Harvest is Base {
    function run() external {
        vm.startBroadcast();

        vm.stopBroadcast();
    }
}

contract Liquidate is Base {
    function run() external {
        vm.startBroadcast();

        vm.stopBroadcast();
    }
}

contract TopUpCollateral is Base {
    function run() external {
        vm.startBroadcast();

        vm.stopBroadcast();
    }
}

contract Deposit is Base {
    function run() external {
        vm.startBroadcast();

        vm.stopBroadcast();
    }
}


contract Withdraw is Base {
    function run() external {
        vm.startBroadcast();

        vm.stopBroadcast();
    }
}

contract UpdateCustomRecoveryConfig is Base {
    function run() external {
        vm.startBroadcast();

        vm.stopBroadcast();
    }
}

contract InitiateRecovery is Base {
    function run() external {
        vm.startBroadcast();

        vm.stopBroadcast();
    }
}

contract ReceiveRecovery is Base {
    function run() external {
        vm.startBroadcast();

        vm.stopBroadcast();
    }
}

contract ApproveRecovery is Base {
    function run() external {
        vm.startBroadcast();

        vm.stopBroadcast();
    }
}

contract ReceiveApproveRecovery is Base {
    function run() external {
        vm.startBroadcast();

        vm.stopBroadcast();
    }
}

contract CancelRecovery is Base {
    function run() external {
        vm.startBroadcast();

        vm.stopBroadcast();
    }
}

contract ReceiveCancelRecovery is Base {
    function run() external {
        vm.startBroadcast();

        vm.stopBroadcast();
    }
}

contract CompleteRecovery is Base {
    function run() external {
        vm.startBroadcast();

        vm.stopBroadcast();
    }
}

contract ReceiveCompleteRecovery is Base {
    function run() external {
        vm.startBroadcast();

        vm.stopBroadcast();
    }
}