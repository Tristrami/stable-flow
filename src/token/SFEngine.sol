// SPDX-License-Identifier: MIT
pragma solidity ^0.8.30;

import {ISFEngine} from "../interfaces/ISFEngine.sol";
import {SFToken} from "./SFToken.sol";
import {Validator} from "./Validator.sol";
import {ERC165} from "@openzeppelin/contracts/utils/introspection/ERC165.sol";
import {ERC165Checker} from "@openzeppelin/contracts/utils/introspection/ERC165Checker.sol";
import {IERC20} from "@openzeppelin/contracts/token/erc20/IERC20.sol";
import {EnumerableSet} from "@openzeppelin/contracts/utils/structs/EnumerableSet.sol";
import {OracleLib, AggregatorV3Interface} from "../libraries/OracleLib.sol";
import {UUPSUpgradeable} from "@openzeppelin/contracts-upgradeable/proxy/utils/UUPSUpgradeable.sol";
import {OwnableUpgradeable} from "@openzeppelin/contracts-upgradeable/access/OwnableUpgradeable.sol";

/**
 * @title SFEngine
 * @dev Core engine contract for StableFlow protocol managing collateralization and SF token operations
 * @notice Implements:
 * - Collateral deposit/redeem mechanisms
 * - SF token minting/burning with collateral ratio enforcement
 * - Liquidation system for undercollateralized positions
 * - Chainlink oracle-integrated price feeds
 * @notice Key features:
 * - UUPS upgradeable pattern with ownership control
 * - 200% minimum collateral ratio enforcement
 * - Multi-collateral support with dynamic price feeds
 * - ERC-4337 account abstraction compatibility
 * @notice Security mechanisms:
 * - Input validation modifiers
 * - Collateral ratio checks
 * - Upgrade compatibility verification
 * - Owner-restricted critical functions
 */
contract SFEngine is ISFEngine, Validator, UUPSUpgradeable, OwnableUpgradeable, ERC165 {

    using ERC165Checker for address;
    using EnumerableSet for EnumerableSet.AddressSet;
    using OracleLib for AggregatorV3Interface;

    /* -------------------------------------------------------------------------- */
    /*                                  Constants                                 */
    /* -------------------------------------------------------------------------- */

    /**
     * @dev Standard decimal precision used for all mathematical calculations
     * @notice Fixed at 18 decimal places to match:
     * - Most ERC20 token implementations
     * - Chainlink price feed conventions
     * - Common DeFi protocol standards
     */
    uint256 private constant PRECISION = 18;

    /**
     * @dev Base unit for precision-adjusted calculations
     * @notice Equal to 10^PRECISION (10^18)
     * @notice Used for:
     * - Maintaining consistent decimal handling
     * - Collateral ratio computations
     * - Interest rate calculations
     */
    uint256 private constant PRECISION_FACTOR = 1e18;

    /**
     * @dev Minimum collateralization ratio enforced by the protocol
     * @notice Set to 200% (2.0) requiring:
     * - $20 collateral for every $10 SF token minted
     * - Provides 100% price fluctuation buffer
     * - Expressed in PRECISION_FACTOR units (2e18)
     */
    uint256 private constant MINIMUM_COLLATERAL_RATIO = 2 * PRECISION_FACTOR;

    /* -------------------------------------------------------------------------- */
    /*                              State Variables                               */
    /* -------------------------------------------------------------------------- */

    /// @dev Instance of the SF token contract
    /// @notice Handles all SF token minting/burning operations
    SFToken private sfToken;

    /// @dev Set of supported collateral token addresses
    /// @notice Uses EnumerableSet for efficient iteration and membership checks
    EnumerableSet.AddressSet private supportedTokenAddressSet;

    /// @dev Nested mapping tracking user collateral balances
    /// @notice Format: user address => token address => amount
    mapping(address user => mapping(address tokenAddress => uint256 value)) private collaterals;

    /// @dev Mapping of collateral tokens to Chainlink price feeds
    /// @notice Used for real-time price lookups and USD conversions
    mapping(address tokenAddress => address priceFeedAddress) private priceFeeds;

    /// @dev Tracks SF token debt per user
    /// @notice Represents outstanding minted SF tokens that must be collateralized
    mapping(address user => uint256 sfDebt) private sfDebts;

    /* -------------------------------------------------------------------------- */
    /*                                   Events                                   */
    /* -------------------------------------------------------------------------- */

    event SFEngine__CollateralDeposited(
        address indexed user, address indexed collateralAddress, uint256 indexed amountCollateral
    );
    event SFEngine__CollateralRedeemed(
        address indexed user, address indexed collateralAddress, uint256 indexed amountCollateral
    );
    event SFEngine__SFTokenMinted(address indexed user, uint256 indexed amountToken);

    /* -------------------------------------------------------------------------- */
    /*                                   Errors                                   */
    /* -------------------------------------------------------------------------- */

    error SFEngine__TokenAddressAndPriceFeedLengthNotMatch();
    error SFEngine__TokenNotSupported();
    error SFEngine__AmountToRedeemExceedsDeposited(uint256 amountDeposited);
    error SFEngine__DebtToCoverExceedsCollateralDeposited(uint256 amountDeposited);
    error SFEngine__TransferFailed();
    error SFEngine__InsufficientBalance(uint256 balance);
    error SFEngine__SFToBurnExceedsUserDebt(uint256 userDebt);
    error SFEngine__CollateralRatioIsBroken(address user, uint256 collateralRatio);
    error SFEngine__CollateralRatioIsNotBroken(address user, uint256 collateralRatio);
    error SFEngine__IncompatibleImplementation();

    /* -------------------------------------------------------------------------- */
    /*                                  Modifiers                                 */
    /* -------------------------------------------------------------------------- */

    modifier onlySupportedToken(address tokenAddress) {
        if (priceFeeds[tokenAddress] == address(0)) {
            revert SFEngine__TokenNotSupported();
        }
        _;
    }

    /* -------------------------------------------------------------------------- */
    /*                                 Initializer                                */
    /* -------------------------------------------------------------------------- */

    function initialize(
        address sfTokenAddress, 
        address[] memory tokenAddresses, 
        address[] memory priceFeedAddresses
    ) external initializer {
        __UUPSUpgradeable_init();
        __Ownable_init(msg.sender);
        _initializePriceFeeds(tokenAddresses, priceFeedAddresses);
        sfToken = SFToken(sfTokenAddress);
    }

    /* -------------------------------------------------------------------------- */
    /*                         External / Public Functions                        */
    /* -------------------------------------------------------------------------- */

    function depositCollateralAndMintSFToken(
        address collateralAddress,
        uint256 amountCollateral,
        uint256 amountSFToMint
    )
        external
        override
        notZeroAddress(collateralAddress)
        notZeroValue(amountCollateral)
        onlySupportedToken(collateralAddress)
    {
        _depositCollateral(collateralAddress, amountCollateral);
        _mintSFToken(amountSFToMint);
    }

    function redeemCollateral(
        address collateralAddress,
        uint256 amountCollateralToRedeem,
        uint256 amountSFToBurn
    )
        public
        override
        notZeroAddress(collateralAddress)
        notZeroValue(amountCollateralToRedeem)
        onlySupportedToken(collateralAddress)
    {
        _burnSFToken(msg.sender, msg.sender, amountSFToBurn, amountSFToBurn);
        _redeemCollateral(collateralAddress, amountCollateralToRedeem, msg.sender, msg.sender);
        _revertIfCollateralRatioIsBroken(msg.sender);
    }

    function liquidate(address user, address collateralAddress, uint256 debtToCover)
        external
        override
        notZeroAddress(collateralAddress)
        notZeroValue(debtToCover)
        onlySupportedToken(collateralAddress)
    {
        _revertIfCollateralRatioIsNotBroken(user);
        uint256 liquidatorBalance = sfToken.balanceOf(msg.sender);
        if (debtToCover > liquidatorBalance) {
            debtToCover = liquidatorBalance;
        }
        uint256 amountCollateralToLiquidate = _getTokenAmountFromUsd(collateralAddress, debtToCover);
        uint256 amountDeposited = collaterals[user][collateralAddress];
        if (amountCollateralToLiquidate > amountDeposited) {
            amountCollateralToLiquidate = amountDeposited;
        }
        uint256 amountSFToBurn = debtToCover;
        uint256 bonus = amountCollateralToLiquidate * (10 ** (PRECISION - 1)) / PRECISION_FACTOR;
        uint256 maxAmountToLiquidate = amountCollateralToLiquidate + bonus;
        if (maxAmountToLiquidate > amountDeposited) {
            amountCollateralToLiquidate = amountDeposited;
            uint256 bonusInSFToken = _getTokenValueInUsd(collateralAddress, bonus);
            amountSFToBurn -= bonusInSFToken;
        } else {
            amountCollateralToLiquidate += bonus;
        }
        _burnSFToken(msg.sender, user, amountSFToBurn, debtToCover);
        _redeemCollateral(collateralAddress, amountCollateralToLiquidate, user, msg.sender);
        _revertIfCollateralRatioIsBroken(user);
        _revertIfCollateralRatioIsBroken(msg.sender);
    }

    function getSFDebt(address user) external view override returns (uint256) {
        return sfDebts[user];
    }

    function calculateSFTokensByCollateral(
        address collateralAddress,
        uint256 amountCollateral,
        uint256 collateralRatio
    ) external view override returns (uint256) {
        uint256 collateralInUsd = _getTokenValueInUsd(collateralAddress, amountCollateral);
        return collateralInUsd * collateralRatio / PRECISION_FACTOR;
    }

    function getTotalCollateralValueInUsd(address user) public view override returns (uint256) {
        uint256 totalCollateralValueInUsd;
        for (uint256 i = 0; i < supportedTokenAddressSet.length(); i++) {
            address tokenAddress = supportedTokenAddressSet.at(i);
            uint256 amountCollateral = collaterals[user][tokenAddress];
            totalCollateralValueInUsd += _getTokenValueInUsd(tokenAddress, amountCollateral);
        }
        return totalCollateralValueInUsd;
    }

    function getCollateralRatio(address user) public view override returns (uint256) {
        uint256 sfDebt = sfDebts[user];
        if (sfDebt == 0) {
            return type(uint256).max;
        }
        uint256 totalCollateralValueInUsd;
        for (uint256 i = 0; i < supportedTokenAddressSet.length(); i++) {
            address tokenAddress = supportedTokenAddressSet.at(i);
            uint256 amountCollateral = collaterals[user][tokenAddress];
            totalCollateralValueInUsd += _getTokenValueInUsd(tokenAddress, amountCollateral);
        }
        return totalCollateralValueInUsd * PRECISION_FACTOR / sfDebt;
    }

    function getMinimumCollateralRatio() public pure override returns (uint256) {
        return MINIMUM_COLLATERAL_RATIO;
    }

    function getSFTokenAddress() public view override returns (address) {
        return address(sfToken);
    }

    /// @inheritdoc ERC165
    function supportsInterface(bytes4 interfaceId) public view override returns (bool) {
        return interfaceId == type(ISFEngine).interfaceId || super.supportsInterface(interfaceId);
    }

    /* -------------------------------------------------------------------------- */
    /*                              Private Functions                             */
    /* -------------------------------------------------------------------------- */

    function _initializePriceFeeds(address[] memory tokenAddresses, address[] memory priceFeedAddresses) private {
        if (tokenAddresses.length != priceFeedAddresses.length) {
            revert SFEngine__TokenAddressAndPriceFeedLengthNotMatch();
        }
        for (uint256 i = 0; i < tokenAddresses.length; i++) {
            supportedTokenAddressSet.add(tokenAddresses[i]);
            priceFeeds[tokenAddresses[i]] = priceFeedAddresses[i];
        }
    }

    function _depositCollateral(address collateralAddress, uint256 amountCollateral) private {
        collaterals[msg.sender][collateralAddress] += amountCollateral;
        emit SFEngine__CollateralDeposited(msg.sender, collateralAddress, amountCollateral);
        bool success = IERC20(collateralAddress).transferFrom(msg.sender, address(this), amountCollateral);
        if (!success) {
            revert SFEngine__TransferFailed();
        }
    }

    function _mintSFToken(uint256 amount) private {
        if (amount == 0) {
            return;
        }
        sfDebts[msg.sender] += amount;
        _revertIfCollateralRatioIsBroken(msg.sender);
        emit SFEngine__SFTokenMinted(msg.sender, amount);
        sfToken.mint(msg.sender, amount);
    }

    function _getTokenValueInUsd(address tokenAddress, uint256 amountToken)
        private
        view
        onlySupportedToken(tokenAddress)
        returns (uint256)
    {
        return amountToken * _getTokenUsdPrice(tokenAddress) / PRECISION_FACTOR;
    }

    function _getTokenAmountFromUsd(address tokenAddress, uint256 amountUsd)
        private
        view
        onlySupportedToken(tokenAddress)
        returns (uint256)
    {
        return (amountUsd * PRECISION_FACTOR) / _getTokenUsdPrice(tokenAddress);
    }

    function _getTokenUsdPrice(address tokenAddress) private view onlySupportedToken(tokenAddress) returns (uint256) {
        AggregatorV3Interface priceFeed = AggregatorV3Interface(priceFeeds[tokenAddress]);
        // Normally 8 decimals
        (, int256 answer,,,) = priceFeed.getStaleCheckedLatestRoundData();
        // token / usd price，18 decimals
        return uint256(answer) * 10 ** (PRECISION - priceFeed.decimals());
    }

    function _burnSFToken(address from, address onBehalfOf, uint256 amountToBurn, uint256 debtToCover)
        private
        notZeroAddress(from)
        notZeroValue(amountToBurn)
        notZeroValue(debtToCover)
    {
        uint256 balance = sfToken.balanceOf(from);
        if (balance < amountToBurn) {
            revert SFEngine__InsufficientBalance(balance);
        }
        uint256 userSFDebt = sfDebts[onBehalfOf];
        if (userSFDebt < debtToCover) {
            revert SFEngine__SFToBurnExceedsUserDebt(userSFDebt);
        }
        sfDebts[onBehalfOf] -= debtToCover;
        bool success = sfToken.transferFrom(from, address(this), amountToBurn);
        if (!success) {
            revert SFEngine__TransferFailed();
        }
        sfToken.burn(address(this), amountToBurn);
    }

    function _redeemCollateral(
        address collateralAddress,
        uint256 amountCollateralToRedeem,
        address collateralFrom,
        address collateralTo
    ) private {
        uint256 collateralDeposited = collaterals[collateralFrom][collateralAddress];
        if (collateralDeposited < amountCollateralToRedeem) {
            revert SFEngine__AmountToRedeemExceedsDeposited(collateralDeposited);
        }
        collaterals[collateralFrom][collateralAddress] -= amountCollateralToRedeem;
        emit SFEngine__CollateralRedeemed(collateralFrom, collateralAddress, amountCollateralToRedeem);
        bool success = IERC20(collateralAddress).transfer(collateralTo, amountCollateralToRedeem);
        if (!success) {
            revert SFEngine__TransferFailed();
        }
    }

    function _revertIfCollateralRatioIsBroken(address user) private view {
        (bool isBroken, uint256 collateralRatio) = _checkCollateralRatio(user);
        if (isBroken) {
            revert SFEngine__CollateralRatioIsBroken(user, collateralRatio);
        }
    }

    function _revertIfCollateralRatioIsNotBroken(address user) private view {
        (bool isBroken, uint256 collateralRatio) = _checkCollateralRatio(user);
        if (!isBroken) {
            revert SFEngine__CollateralRatioIsNotBroken(user, collateralRatio);
        }
    }

    function _checkCollateralRatio(address user) public view returns (bool isBroken, uint256 collateralRatio) {
        collateralRatio = getCollateralRatio(user);
        isBroken = collateralRatio < MINIMUM_COLLATERAL_RATIO;
        return (isBroken, collateralRatio);
    }

    /* -------------------------------------------------------------------------- */
    /*                        Overridden Internal Functions                       */
    /* -------------------------------------------------------------------------- */
    
    function _authorizeUpgrade(address newImplementation) internal view override onlyOwner {
        if (!newImplementation.supportsInterface(type(ISFEngine).interfaceId)) {
            revert SFEngine__IncompatibleImplementation();
        }
    }

    /* -------------------------------------------------------------------------- */
    /*                           Getter / View Functions                          */
    /* -------------------------------------------------------------------------- */

    function getCollateralAmount(address user, address collateralAddress) public view returns (uint256) {
        return collaterals[user][collateralAddress];
    }

    function getCollateralTokenAddresses() public view returns (address[] memory) {
        return supportedTokenAddressSet.values();
    }

    function getTokenUsdPrice(address tokenAddress) external view returns (uint256) {
        return _getTokenUsdPrice(tokenAddress);
    }

    function getTokenValueInUsd(address tokenAddress, uint256 amountToken) external view returns (uint256) {
        return _getTokenValueInUsd(tokenAddress, amountToken);
    }

    function getTokenAmountFromUsd(address tokenAddress, uint256 amountUsd)
        external
        view
        returns (uint256 tokenValue)
    {
        return _getTokenAmountFromUsd(tokenAddress, amountUsd);
    }
}