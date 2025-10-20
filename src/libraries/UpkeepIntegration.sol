// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {AutomationRegistrarInterface} from "../interfaces/AutomationRegistrarInterface.sol";
import {IVaultPlugin} from "../interfaces/IVaultPlugin.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

library UpkeepIntegration {

    error UpkeepIntegration__InsufficientLinkBalance(
        address account, 
        uint256 balance, 
        uint256 requiredAmount
    );

    event UpkeepIntegration__Register(
        uint256 indexed upkeepId, 
        address indexed registrar, 
        address indexed vault, 
        uint96 linkAmount,
        uint32 gasLimit
    );

    uint8 internal constant CONDITIONAL_TRIGGER = 0;

    function register(
        AutomationRegistrarInterface registrar, 
        IVaultPlugin vault, 
        address admin, 
        address linkToken,
        address linkPayer,
        uint96 linkAmount,
        uint32 gasLimit
    ) internal returns (uint256) {
        uint256 payerLinkBalance = IERC20(linkToken).balanceOf(linkPayer);
        if (payerLinkBalance < linkAmount) {
            revert UpkeepIntegration__InsufficientLinkBalance(linkPayer, payerLinkBalance, linkAmount);
        }
        IERC20(linkToken).transferFrom(linkPayer, address(this), linkAmount);
        IERC20(linkToken).approve(address(registrar), linkAmount);
        AutomationRegistrarInterface.RegistrationParams memory params = AutomationRegistrarInterface.RegistrationParams({
            name: "Vault Upkeep",
            encryptedEmail: "",
            upkeepContract: address(vault),
            gasLimit: gasLimit,
            adminAddress: admin,
            triggerType: CONDITIONAL_TRIGGER,
            checkData: "",
            triggerConfig: "",
            offchainConfig: "",
            amount: linkAmount
        });
        uint256 upkeepId =  registrar.registerUpkeep(params);
        emit UpkeepIntegration__Register(upkeepId, address(registrar), address(vault), linkAmount, gasLimit);
        return upkeepId;
    }
}