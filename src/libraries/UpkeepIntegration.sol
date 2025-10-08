// SPDX-License-Identifier: MIT
pragma solidity ^0.8.30;

import {AutomationRegistrarInterface} from "../interfaces/AutomationRegistrarInterface.sol";
import {IVaultPlugin} from "../interfaces/IVaultPlugin.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

library UpkeepIntegration {

    event UpkeepIntegration__Register(
        uint256 indexed upkeepId, 
        address indexed registrar, 
        address indexed vault, 
        uint8 linkAmount
    );

    uint8 internal constant CONDITIONAL_TRIGGER = 0;

    function register(
        AutomationRegistrarInterface registrar, 
        IVaultPlugin vault, 
        address admin, 
        address linkToken
    ) internal returns (uint256) {
        uint256 initialLinkAmount = IERC20(linkToken).balanceOf(address(vault));
        IERC20(linkToken).approve(address(registrar), initialLinkAmount);
        AutomationRegistrarInterface.RegistrationParams memory params = AutomationRegistrarInterface.RegistrationParams({
            name: "Vault Upkeep",
            encryptedEmail: "",
            upkeepContract: address(vault),
            gasLimit: 50000,
            adminAddress: admin,
            triggerType: CONDITIONAL_TRIGGER,
            checkData: "",
            triggerConfig: "",
            offchainConfig: "",
            amount: uint96(initialLinkAmount)
        });
        return registrar.registerUpkeep(params);
    }
}