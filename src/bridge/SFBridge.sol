// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {ISFBridge} from "../interfaces/ISFBridge.sol";
import {SFToken} from "../token/SFToken.sol";
import {IRouterClient} from "@chainlink/contracts/src/v0.8/ccip/interfaces/IRouterClient.sol";
import {Client} from "@chainlink/contracts/src/v0.8/ccip/libraries/Client.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {EnumerableMap} from "@openzeppelin/contracts/utils/structs/EnumerableMap.sol";
import {OwnableUpgradeable} from "@openzeppelin/contracts-upgradeable/access/OwnableUpgradeable.sol";
import {UUPSUpgradeable} from "@openzeppelin/contracts-upgradeable/proxy/utils/UUPSUpgradeable.sol";
import {IERC165} from "@openzeppelin/contracts/utils/introspection/IERC165.sol";
import {ERC165} from "@openzeppelin/contracts/utils/introspection/ERC165.sol";
import {ERC165Checker} from "@openzeppelin/contracts/utils/introspection/ERC165Checker.sol";

/**
 * @title SFBridge
 * @dev Cross-chain bridge contract supporting token transfers via Chainlink CCIP
 * @notice Uses Ownable and UUPS upgrade pattern, requires initialization before use
 */
contract SFBridge is ISFBridge, OwnableUpgradeable, UUPSUpgradeable, ERC165 {

    using EnumerableMap for EnumerableMap.UintToUintMap;
    using ERC165Checker for address;
    
    /* -------------------------------------------------------------------------- */
    /*                               State Variables                              */
    /* -------------------------------------------------------------------------- */

    /// @dev Local SFToken contract instance
    SFToken private localSFToken;
    /// @dev LINK token address for fee payments
    address private linkTokenAddress;
    /// @dev Chainlink CCIP Router address
    address private routerAddress;
    /// @dev Mapping of supported chain IDs to their selectors
    EnumerableMap.UintToUintMap private supportedChains;

    /* -------------------------------------------------------------------------- */
    /*                                 Initializer                                */
    /* -------------------------------------------------------------------------- */

    /**
     * @dev Initializes the bridge contract
     * @param _localSFToken Local SFToken contract address
     * @param _linkTokenAddress LINK token address
     * @param _routerAddress CCIP Router address
     * @param _supportedChains Array of supported chain IDs
     * @param _chainSelectors Corresponding chain selectors
     */
    function initialize(
        SFToken _localSFToken,
        address _linkTokenAddress,
        address _routerAddress,
        uint256[] memory _supportedChains,
        uint64[] memory _chainSelectors
    ) external initializer {
        __UUPSUpgradeable_init();
        __Ownable_init(msg.sender);
        localSFToken = _localSFToken;
        linkTokenAddress = _linkTokenAddress;
        routerAddress = _routerAddress;
        _updateSupportedChains(_supportedChains, _chainSelectors);
    }

    /**
     * @dev Reinitializes contract with new parameters
     * @param _version Reinitialization version
     * @param _localSFToken Updated SFToken contract
     * @param _linkTokenAddress Updated LINK token address
     * @param _routerAddress Updated Router address
     * @param _supportedChains Updated supported chains
     * @param _chainSelectors Updated chain selectors
     */
    function reinitialize(
        uint64 _version,
        SFToken _localSFToken,
        address _linkTokenAddress,
        address _routerAddress,
        uint256[] memory _supportedChains,
        uint64[] memory _chainSelectors
    ) external reinitializer(_version) {
        localSFToken = _localSFToken;
        linkTokenAddress = _linkTokenAddress;
        routerAddress = _routerAddress;
        _updateSupportedChains(_supportedChains, _chainSelectors);
    }

    /* -------------------------------------------------------------------------- */
    /*                         Public / External Functions                        */
    /* -------------------------------------------------------------------------- */

    /// @inheritdoc ISFBridge
    function bridgeSFToken(
        uint256 destinationChainId,
        address receiver,
        uint256 amount
    ) external override returns (bytes32 messageId) {
        _requireSupportedChain(destinationChainId);
        if (destinationChainId == block.chainid) {
            revert ISFBridge__DestinationChainIdCanNotBeCurrentChainId();
        }
        if (receiver == address(0)) {
            revert ISFBridge__InvalidReceiver();
        }
        if (amount == 0) {
            revert ISFBridge__TokenAmountCanNotBeZero();
        }
        localSFToken.transferFrom(msg.sender, address(this), amount);
        uint64 destinationChainSelector = uint64(supportedChains.get(destinationChainId));
        Client.EVM2AnyMessage memory message = _createCCIPMessage(
            address(localSFToken),
            linkTokenAddress,
            receiver,
            amount
        );
        IRouterClient routerClient = IRouterClient(routerAddress);
        uint256 fee = routerClient.getFee(destinationChainSelector, message);
        IERC20(linkTokenAddress).transferFrom(msg.sender, address(this), fee);
        IERC20(linkTokenAddress).approve(routerAddress, fee);
        localSFToken.approve(routerAddress, amount);
        emit ISFBridge__Bridge(destinationChainSelector, receiver, amount);
        messageId = routerClient.ccipSend(destinationChainSelector, message);
    }

    /// @inheritdoc ERC165
    function supportsInterface(bytes4 interfaceId) public view override(ERC165, IERC165) returns (bool) {
        return interfaceId == type(ISFBridge).interfaceId || super.supportsInterface(interfaceId);
    }

    /* -------------------------------------------------------------------------- */
    /*                        Private / Internal Functions                        */
    /* -------------------------------------------------------------------------- */

    /// @inheritdoc UUPSUpgradeable
    function _authorizeUpgrade(address newImplementation) internal view override {
        if (msg.sender != owner()) {
            revert ISFBridge__OnlyOwner();
        }
        if (newImplementation == address(0)
            || newImplementation.code.length == 0
            || !newImplementation.supportsInterface(type(ISFBridge).interfaceId)) {
            revert ISFBridge__IncompatibleImplementation();
        }
    }

    /**
     * @dev Updates supported chains mapping
     * @param chainIds Array of chain IDs
     * @param chainSelectors Corresponding chain selectors
     */
    function _updateSupportedChains(
        uint256[] memory chainIds,
        uint64[] memory chainSelectors
    ) private {
        if (chainIds.length != chainSelectors.length) {
            revert ISFBridge__AmountOfChainIdsAndSelectorsNotMatch();
        }
        if (chainIds.length == 0) {
            revert ISFBridge__SupportedChainIdsIsEmpty();
        }
        
        for (uint256 i = 0; i < chainIds.length; i++) {
            supportedChains.set(chainIds[i], chainSelectors[i]);
        }
        emit ISFBridge__UpdateSupportedChains();
    }

    /**
     * @dev Creates CCIP message structure
     * @param localSFTokenAddress SFToken contract address
     * @param feeTokenAddress Fee token address
     * @param receiver Recipient address
     * @param amount Transfer amount
     * @return Client.EVM2AnyMessage CCIP message structure
     */
    function _createCCIPMessage(
        address localSFTokenAddress,
        address feeTokenAddress,
        address receiver,
        uint256 amount
    ) public pure returns (Client.EVM2AnyMessage memory) {
        Client.EVMTokenAmount[] memory tokenAmounts = new Client.EVMTokenAmount[](1);
        tokenAmounts[0] = Client.EVMTokenAmount({
            token: localSFTokenAddress,
            amount: amount
        });
        return Client.EVM2AnyMessage({
            receiver: abi.encode(receiver),
            data: "",
            feeToken: feeTokenAddress,
            tokenAmounts: tokenAmounts,
            extraArgs: Client._argsToBytes(Client.EVMExtraArgsV2({
                gasLimit: 0,
                allowOutOfOrderExecution: false
            }))
        });
    }

    /**
     * @dev Validates chain support
     * @param destinationChainId Chain ID to verify
     */
    function _requireSupportedChain(uint256 destinationChainId) private view {
        if (!supportedChains.contains(destinationChainId)) {
            revert ISFBridge__ChainNotSupported();
        }
    }
}