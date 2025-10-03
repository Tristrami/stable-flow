// SPDX-License-Identifier: MIT
pragma solidity ^0.8.30;

import {Script, console2} from "forge-std/Script.sol";
import {SFAccountFactory} from "../src/account/SFAccountFactory.sol";
import {ISFAccount} from "../src/interfaces/ISFAccount.sol";
import {IVaultPlugin} from "../src/interfaces/IVaultPlugin.sol";
import {ISocialRecoveryPlugin} from "../src/interfaces/ISocialRecoveryPlugin.sol";
import {DevOps} from "../script/util/DevOps.s.sol";
import {Constants} from "../script/util/Constants.sol";
import {ERC165Checker} from "@openzeppelin/contracts/utils/introspection/ERC165Checker.sol";
import {BeaconProxy} from "@openzeppelin/contracts/proxy/beacon/BeaconProxy.sol";
import {PackedUserOperation} from "account-abstraction/contracts/interfaces/PackedUserOperation.sol";
import {IEntryPoint} from "account-abstraction/contracts/interfaces/IEntryPoint.sol";

contract BaseOperation is Script, Constants {

    using ERC165Checker for address;

    error BaseOperation__AccountNotExists();

    DevOps internal devOps;

    constructor() {
        devOps = new DevOps();
    }

    function createUserOp(
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

    function getSalt(address sfAccountOwner) public pure returns (bytes32) {
        return bytes32(uint256(uint160(sfAccountOwner)));
    }

    function getInitCode(address sfAccountFactoryAddress, address user) public view returns (bytes memory) {
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
        return SFAccountFactory(sfAccountFactoryAddress).getInitCode(
            user, 
            getSalt(user), 
            customVaultConfig, 
            customRecoveryConfig
        );
    }

    function _send(address entryPoint, address user, address sfAccount, bytes memory callData) internal {
        _send(entryPoint, user, sfAccount, callData, "");
    }

    function _send(address entryPoint, address user, address sfAccount, bytes memory callData, bytes memory initCode) internal {
        PackedUserOperation memory userOp = createUserOp(user, entryPoint, sfAccount, initCode, callData);
        PackedUserOperation[] memory userOps = _singleOp(userOp);
        vm.startBroadcast();
        IEntryPoint(entryPoint).handleOps(userOps, payable(user));
        vm.stopBroadcast();
    }

    function _requireOwnAccount(address sfAccountFactoryAddress, address user, address sfAccount) internal view {
        if (!_hasSFAccount(sfAccountFactoryAddress, user, sfAccount)) {
            revert BaseOperation__AccountNotExists();
        }
    }

    function _hasSFAccount(address sfAccountFactoryAddress, address user, address sfAccount) internal view returns (bool) {
        address[] memory sfAccounts = SFAccountFactory(sfAccountFactoryAddress).getUserAccounts(user);
        for (uint256 i = 0; i < sfAccounts.length; i++) {
            if (sfAccounts[i] == sfAccount) {
                return true;
            }
        }
        return false;
    }

    function _singleOp(PackedUserOperation memory userOp) internal pure returns (PackedUserOperation[] memory) {
        PackedUserOperation[] memory userOps = new PackedUserOperation[](1);
        userOps[0] = userOp;
        return userOps;
    }

    
}

contract UpdateCustomVaultConfig is BaseOperation {

    function run(
        address sfAccount,
        IVaultPlugin.CustomVaultConfig memory customConfig
    ) public {
        run(
            devOps.getLatestDeployment("SFAccountFactory"),
            devOps.getLatestDeployment("EntryPoint"),
            msg.sender, 
            sfAccount, 
            customConfig
        );
    }

    function run(
        address sfAccountFactoryAddress,
        address entryPointAddress,
        address user,
        address sfAccount,
        IVaultPlugin.CustomVaultConfig memory customConfig
    ) public {
        _requireOwnAccount(sfAccountFactoryAddress, user, sfAccount);
        bytes memory callData = abi.encodeCall(IVaultPlugin.updateCustomVaultConfig, (customConfig));
        _send(entryPointAddress, user, sfAccount, callData);
    }
}

contract CreateAccount is BaseOperation {

    function run() external returns (address sfAccount) {
        return run(
            msg.sender,
            devOps.getLatestDeployment("EntryPoint"),
            devOps.getLatestDeployment("SFAccountFactory"), 
            devOps.getLatestDeployment("SFAccountBeacon")
        );
    }

    function run(
        address user,
        address entryPointAddress,
        address sfAccountFactoryAddress, 
        address beaconAddress
    ) public returns (address sfAccount) {
        bytes32 salt = getSalt(user);
        sfAccount = calculateAccountAddress(sfAccountFactoryAddress, beaconAddress, salt);
        console2.log("Calculated sf account address:", sfAccount);
        bytes memory initCode = getInitCode(sfAccountFactoryAddress, user);
        bytes memory callData = abi.encodeCall(ISFAccount.createAccount, ());
        _send(entryPointAddress, user, sfAccount, callData, initCode);
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
}

contract Transfer is BaseOperation {

    function run(
        address from, 
        address to, 
        uint256 amount
    ) public {
        run(
            devOps.getLatestDeployment("SFAccountFactory"),
            devOps.getLatestDeployment("EntryPoint"),
            msg.sender, 
            from, 
            to, 
            amount
        );
    }

    function run(
        address sfAccountFactoryAddress,
        address entryPointAddress,
        address user,
        address from, 
        address to, 
        uint256 amount
    ) public {
        _requireOwnAccount(sfAccountFactoryAddress, user, from);
        bytes memory callData = abi.encodeCall(ISFAccount.transfer, (to, amount));
        _send(entryPointAddress, user, from, callData);
    }
}

contract Invest is BaseOperation {

    function run(
        address sfAccount,
        address collateralAddress,
        uint256 amountCollateral
    ) public {
        run(
            devOps.getLatestDeployment("SFAccountFactory"),
            devOps.getLatestDeployment("EntryPoint"),
            msg.sender, 
            sfAccount,
            collateralAddress,
            amountCollateral
        );
    }

    function run(
        address sfAccountFactoryAddress,
        address entryPointAddress,
        address user,
        address sfAccount,
        address collateralAddress,
        uint256 amountCollateral
    ) public {
        _requireOwnAccount(sfAccountFactoryAddress, user, sfAccount);
        bytes memory callData = abi.encodeCall(IVaultPlugin.invest, (collateralAddress, amountCollateral));
        _send(entryPointAddress, user, sfAccount, callData);
    }
}

contract Harvest is BaseOperation {

    function run(
        address sfAccount,
        address collateralAddress,
        uint256 amountCollateralToRedeem,
        uint256 debtToRepay
    ) public {
        run(
            devOps.getLatestDeployment("SFAccountFactory"),
            devOps.getLatestDeployment("EntryPoint"),
            msg.sender, 
            sfAccount,
            collateralAddress,
            amountCollateralToRedeem,
            debtToRepay
        );
    }

    function run(
        address sfAccountFactoryAddress,
        address entryPointAddress,
        address user,
        address sfAccount,
        address collateralAddress,
        uint256 amountCollateralToRedeem,
        uint256 debtToRepay
    ) public {
        _requireOwnAccount(sfAccountFactoryAddress, user, sfAccount);
        bytes memory callData = abi.encodeCall(
            IVaultPlugin.harvest, 
            (
                collateralAddress, 
                amountCollateralToRedeem, 
                debtToRepay
            )
        );
        _send(entryPointAddress, user, sfAccount, callData);
    }
}

contract Liquidate is BaseOperation {
    
    function run(
        address sfAccount,
        address accountToLiquidate, 
        address collateralAddress, 
        uint256 debtToCover
    ) public {
        run(
            devOps.getLatestDeployment("SFAccountFactory"),
            devOps.getLatestDeployment("EntryPoint"),
            msg.sender, 
            sfAccount,
            accountToLiquidate,
            collateralAddress,
            debtToCover
        );
    }

    function run(
        address sfAccountFactoryAddress,
        address entryPointAddress,
        address user,
        address sfAccount,
        address accountToLiquidate, 
        address collateralAddress, 
        uint256 debtToCover
    ) public {
        _requireOwnAccount(sfAccountFactoryAddress, user, sfAccount);
        bytes memory callData = abi.encodeCall(
            IVaultPlugin.liquidate, 
            (
                accountToLiquidate,
                collateralAddress,
                debtToCover
            )
        );
        _send(entryPointAddress, user, sfAccount, callData);
    }
}

contract TopUpCollateral is BaseOperation {
    
    function run(
        address sfAccount,
        address collateralAddress, 
        uint256 amount
    ) public {
        run(
            devOps.getLatestDeployment("SFAccountFactory"),
            devOps.getLatestDeployment("EntryPoint"),
            msg.sender, 
            sfAccount,
            collateralAddress, 
            amount
        );
    }

    function run(
        address sfAccountFactoryAddress,
        address entryPointAddress,
        address user,
        address sfAccount,
        address collateralAddress, 
        uint256 amount
    ) public {
        _requireOwnAccount(sfAccountFactoryAddress, user, sfAccount);
        bytes memory callData = abi.encodeCall(
            IVaultPlugin.topUpCollateral, 
            (
                collateralAddress, 
                amount
            )
        );
        _send(entryPointAddress, user, sfAccount, callData);
    }
}

contract Deposit is BaseOperation {
    
    function run(
        address sfAccount,
        address collateralAddress, 
        uint256 amount
    ) public {
        run(
            devOps.getLatestDeployment("SFAccountFactory"),
            devOps.getLatestDeployment("EntryPoint"),
            msg.sender, 
            sfAccount,
            collateralAddress, 
            amount
        );
    }

    function run(
        address sfAccountFactoryAddress,
        address entryPointAddress,
        address user,
        address sfAccount,
        address collateralAddress, 
        uint256 amount
    ) public {
        _requireOwnAccount(sfAccountFactoryAddress, user, sfAccount);
        bytes memory callData = abi.encodeCall(
            IVaultPlugin.deposit, 
            (
                collateralAddress, 
                amount
            )
        );
        _send(entryPointAddress, user, sfAccount, callData);
    }
}


contract Withdraw is BaseOperation {

    function run(
        address sfAccount,
        address collateralAddress, 
        uint256 amount
    ) public {
        run(
            devOps.getLatestDeployment("SFAccountFactory"),
            devOps.getLatestDeployment("EntryPoint"),
            msg.sender, 
            sfAccount,
            collateralAddress, 
            amount
        );
    }

    function run(
        address sfAccountFactoryAddress,
        address entryPointAddress,
        address user,
        address sfAccount,
        address collateralAddress, 
        uint256 amount
    ) public {
        _requireOwnAccount(sfAccountFactoryAddress, user, sfAccount);
        bytes memory callData = abi.encodeCall(
            IVaultPlugin.withdraw, 
            (
                collateralAddress, 
                amount
            )
        );
        _send(entryPointAddress, user, sfAccount, callData);
    }
}

contract UpdateCustomRecoveryConfig is BaseOperation {
    
    function run(
        address sfAccount,
        ISocialRecoveryPlugin.CustomRecoveryConfig memory customConfig
    ) public {
        run(
            devOps.getLatestDeployment("SFAccountFactory"),
            devOps.getLatestDeployment("EntryPoint"),
            msg.sender, 
            sfAccount, 
            customConfig
        );
    }

    function run(
        address sfAccountFactoryAddress,
        address entryPointAddress,
        address user,
        address sfAccount,
        ISocialRecoveryPlugin.CustomRecoveryConfig memory customConfig
    ) public {
        _requireOwnAccount(sfAccountFactoryAddress, user, sfAccount);
        bytes memory callData = abi.encodeCall(ISocialRecoveryPlugin.updateCustomRecoveryConfig, (customConfig));
        _send(entryPointAddress, user, sfAccount, callData);
    }
}

contract InitiateRecovery is BaseOperation {
    
    function run(
        address sfAccount,
        address accountToRecover, 
        address newOwner
    ) public {
        run(
            devOps.getLatestDeployment("SFAccountFactory"),
            devOps.getLatestDeployment("EntryPoint"),
            msg.sender, 
            sfAccount,
            accountToRecover, 
            newOwner
        );
    }

    function run(
        address sfAccountFactoryAddress,
        address entryPointAddress,
        address user,
        address sfAccount,
        address accountToRecover, 
        address newOwner
    ) public {
        _requireOwnAccount(sfAccountFactoryAddress, user, sfAccount);
        bytes memory callData = abi.encodeCall(
            ISocialRecoveryPlugin.initiateRecovery, 
            (
                accountToRecover, 
                newOwner
            )
        );
        _send(entryPointAddress, user, sfAccount, callData);
    }
}

contract ApproveRecovery is BaseOperation {
    
    function run(address sfAccount, address accountToRecover) public {
        run(
            devOps.getLatestDeployment("SFAccountFactory"),
            devOps.getLatestDeployment("EntryPoint"),
            msg.sender, 
            sfAccount,
            accountToRecover
        );
    }

    function run(
        address sfAccountFactoryAddress,
        address entryPointAddress,
        address user,
        address sfAccount,
        address accountToRecover
    ) public {
        _requireOwnAccount(sfAccountFactoryAddress, user, sfAccount);
        bytes memory callData = abi.encodeCall(
            ISocialRecoveryPlugin.approveRecovery, (accountToRecover)
        );
        _send(entryPointAddress, user, sfAccount, callData);
    }
}

contract CancelRecovery is BaseOperation {
    
    function run(address sfAccount, address accountToRecover) public {
        run(
            devOps.getLatestDeployment("SFAccountFactory"),
            devOps.getLatestDeployment("EntryPoint"),
            msg.sender, 
            sfAccount,
            accountToRecover
        );
    }

    function run(
        address sfAccountFactoryAddress,
        address entryPointAddress,
        address user,
        address sfAccount,
        address accountToRecover
    ) public {
        _requireOwnAccount(sfAccountFactoryAddress, user, sfAccount);
        bytes memory callData = abi.encodeCall(
            ISocialRecoveryPlugin.cancelRecovery, (accountToRecover)
        );
        _send(entryPointAddress, user, sfAccount, callData);
    }
}

contract CompleteRecovery is BaseOperation {
    
    function run(address sfAccount, address accountToRecover) public {
        run(
            devOps.getLatestDeployment("SFAccountFactory"),
            devOps.getLatestDeployment("EntryPoint"),
            msg.sender, 
            sfAccount,
            accountToRecover
        );
    }

    function run(
        address sfAccountFactoryAddress,
        address entryPointAddress,
        address user,
        address sfAccount,
        address accountToRecover
    ) public {
        _requireOwnAccount(sfAccountFactoryAddress, user, sfAccount);
        bytes memory callData = abi.encodeCall(
            ISocialRecoveryPlugin.completeRecovery, (accountToRecover)
        );
        _send(entryPointAddress, user, sfAccount, callData);
    }
}