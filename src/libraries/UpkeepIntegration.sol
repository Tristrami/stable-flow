// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {AutomationRegistrarInterface} from "../interfaces/AutomationRegistrarInterface.sol";
import {IVaultPlugin} from "../interfaces/IVaultPlugin.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

/**
 * @title UpkeepIntegration
 * @dev Library for managing Chainlink Automation upkeep registration
 * @notice Provides standardized functions for registering and funding Chainlink Automation upkeeps
 */
library UpkeepIntegration {

    /**
     * @dev Emitted when LINK balance is insufficient for upkeep registration
     * @param account Address with insufficient balance
     * @param balance Current LINK balance
     * @param requiredAmount Minimum LINK amount required
     */
    error UpkeepIntegration__InsufficientLinkBalance(
        address account, 
        uint256 balance, 
        uint256 requiredAmount
    );

    /**
     * @dev Emitted when a new upkeep is successfully registered
     * @param upkeepId The assigned upkeep ID (indexed)
     * @param registrar Chainlink registrar contract address (indexed)
     * @param contractAddress The contract being automated (indexed)
     * @param linkAmount LINK tokens funded
     * @param gasLimit Gas limit for upkeep executions
     */
    event UpkeepIntegration__Register(
        uint256 indexed upkeepId, 
        address indexed registrar, 
        address indexed contractAddress, 
        uint96 linkAmount,
        uint32 gasLimit
    );

    /**
     * @dev Constant for conditional trigger type
     * @notice Value 0 represents conditional triggers in Chainlink Automation
     */
    uint8 internal constant CONDITIONAL_TRIGGER = 0;

    /**
     * @dev Registers a new Chainlink Automation upkeep
     * @param registrar Chainlink Automation registrar interface
     * @param name Human-readable name for the upkeep
     * @param contractAddress Address of the contract to automate
     * @param admin Administrative address for the upkeep
     * @param linkToken LINK token contract address
     * @param linkPayer Address funding the upkeep
     * @param linkAmount LINK tokens to fund
     * @param gasLimit Maximum gas per upkeep execution
     * @return upkeepId The newly registered upkeep ID
     * @notice Emits UpkeepIntegration__Register event on success
     * Requirements:
     * - linkPayer must have sufficient LINK balance
     * - linkPayer must have approved this contract to spend LINK
     * - registrar must be valid Chainlink Automation registrar
     */
    function register(
        AutomationRegistrarInterface registrar, 
        string memory name,
        address contractAddress, 
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
            name: name,
            encryptedEmail: "",
            upkeepContract: contractAddress,
            gasLimit: gasLimit,
            adminAddress: admin,
            triggerType: CONDITIONAL_TRIGGER,
            checkData: "",
            triggerConfig: "",
            offchainConfig: "",
            amount: linkAmount
        });
        
        uint256 upkeepId = registrar.registerUpkeep(params);
        emit UpkeepIntegration__Register(upkeepId, address(registrar), contractAddress, linkAmount, gasLimit);
        return upkeepId;
    }
}