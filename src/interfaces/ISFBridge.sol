// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {IERC165} from "@openzeppelin/contracts/utils/introspection/IERC165.sol";

interface ISFBridge is IERC165 {

    /* -------------------------------------------------------------------------- */
    /*                                   Errors                                   */
    /* -------------------------------------------------------------------------- */

    /** 
     * @dev Thrown when new implementation contract is incompatible
     */
    error ISFBridge__IncompatibleImplementation();

    /** 
     * @dev Thrown when non-owner attempts privileged operation 
     */
    error ISFBridge__OnlyOwner();

    /** 
     * @dev Thrown when chain IDs and selectors count mismatch 
     */
    error ISFBridge__AmountOfChainIdsAndSelectorsNotMatch();

    /** 
     * @dev Thrown when supported chains list is empty 
     */
    error ISFBridge__SupportedChainIdsIsEmpty();

    /** 
     * @dev Thrown when target chain is not supported 
     */
    error ISFBridge__ChainNotSupported();

    /** 
     * @dev Thrown when receiver address is invalid 
     */
    error ISFBridge__InvalidReceiver();

    /** 
     * @dev Thrown when token amount is zero 
     */
    error ISFBridge__TokenAmountCanNotBeZero();

    /** 
     * @dev Thrown when destination chain matches current chain 
     */
    error ISFBridge__DestinationChainIdCanNotBeCurrentChainId();

    /** 
     * @dev Thrown when insufficient balance exists
     * @param balance Current available balance
     * @param amountRequired Amount that was requested 
     */
    error ISFBridge__InsufficientBalance(uint256 balance, uint256 amountRequired);

    /* -------------------------------------------------------------------------- */
    /*                                   Events                                   */
    /* -------------------------------------------------------------------------- */

    /** 
     * @dev Emitted when supported chains list is updated
     */
    event ISFBridge__UpdateSupportedChains();
    
    /** 
     * @dev Emitted when cross-chain token transfer occurs
     * @param destinationChainSelector Destination chain selector
     * @param receiver Recipient address
     * @param amount Token amount transferred
     */
    event ISFBridge__Bridge(
        uint64 indexed destinationChainSelector, 
        address indexed receiver,
        uint256 indexed amount
    );

    /* -------------------------------------------------------------------------- */
    /*                                  Functions                                 */
    /* -------------------------------------------------------------------------- */

    /**
     * @dev Initiates cross-chain token transfer
     * @param destinationChainId Target chain ID
     * @param receiver Recipient address on target chain
     * @param amount Token amount to transfer
     * @return messageId CCIP message identifier
     */
    function bridgeSFToken(
        uint256 destinationChainId,
        address receiver,
        uint256 amount
    ) external returns (bytes32 messageId);
}