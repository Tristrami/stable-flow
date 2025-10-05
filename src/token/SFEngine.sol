// SPDX-License-Identifier: MIT
pragma solidity ^0.8.30;

import {ISFEngine} from "../interfaces/ISFEngine.sol";
import {SFToken} from "./SFToken.sol";
import {OracleLib, AggregatorV3Interface} from "../libraries/OracleLib.sol";
import {AaveInvestmentIntegration} from "./integrations/AaveInvestmentIntegration.sol";
import {ERC165} from "@openzeppelin/contracts/utils/introspection/ERC165.sol";
import {ERC165Checker} from "@openzeppelin/contracts/utils/introspection/ERC165Checker.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {EnumerableSet} from "@openzeppelin/contracts/utils/structs/EnumerableSet.sol";
import {EnumerableMap} from "@openzeppelin/contracts/utils/structs/EnumerableMap.sol";
import {UUPSUpgradeable} from "@openzeppelin/contracts-upgradeable/proxy/utils/UUPSUpgradeable.sol";
import {OwnableUpgradeable} from "@openzeppelin/contracts-upgradeable/access/OwnableUpgradeable.sol";
import {AutomationCompatibleInterface} from "@chainlink/contracts/src/v0.8/automation/interfaces/AutomationCompatibleInterface.sol";

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
contract SFEngine is ISFEngine, AutomationCompatibleInterface, UUPSUpgradeable, OwnableUpgradeable, ERC165 {

    using ERC165Checker for address;
    using EnumerableSet for EnumerableSet.AddressSet;
    using EnumerableMap for EnumerableMap.AddressToUintMap;
    using OracleLib for AggregatorV3Interface;
    using AaveInvestmentIntegration for AaveInvestmentIntegration.Investment;

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

    /**
     * @notice Current percentage of collateral allocated to Aave for yield generation
     * @dev Represented in basis points (1e18 = 100%)
     * @dev Example values:
     *   - 0.3e18 = 30% of collateral invested
     *   - 0.5e18 = 50% of collateral invested
     */
    uint256 private investmentRatio;

    /**
     * @notice Time interval between automatic yield harvests (in seconds)
     * @dev Used by Chainlink Automation to trigger harvestAll()
    */
    uint256 private autoHarvestDuration;

    /**
     * @notice Timestamp of last automated yield harvest
     * @dev Used with autoHarvestDuration to determine next harvest eligibility
     * @dev Reset to block.timestamp on:
     *   - Manual harvests
     *   - Successful auto-harvests
     *   - Investment ratio changes
     */
    uint256 private lastAutoHarvestTime;

    /**
     * @notice Liquidation bonus rate for incentivizing liquidators
     * @dev Determines the additional collateral percentage awarded to liquidators
     * @dev Calculation: `bonusAmount = collateralToLiquidate * bonusRate / PRECISION_FACTOR`
     */
    uint256 private bonusRate;

    /**
     * @notice Tracks harvested yields per asset
     * @dev Mapping format: assetAddress => accumulatedYieldAmount
     */
    EnumerableMap.AddressToUintMap private investmentGains;

    /**
     * @dev Instance of the SF token contract
     * @notice Handles all SF token minting/burning operations
     */
    SFToken private sfToken;

    /**
     * @dev Set of supported collateral token addresses
     * @notice Uses EnumerableSet for efficient iteration and membership checks
     */
    EnumerableSet.AddressSet private supportedCollaterals;

    /**
     * @dev Nested mapping tracking user collateral balances
     * @notice Format: user address => token address => amount
     */
    mapping(address user => mapping(address collateralAddress => uint256 value)) private collaterals;

    /**
     * @dev Mapping of collateral tokens to Chainlink price feeds
     * @notice Used for real-time price lookups and USD conversions
     */
    mapping(address collateralAddress => address priceFeedAddress) private priceFeeds;

    /**
     * @dev Tracks SF token debt per user
     * @notice Represents outstanding minted SF tokens that must be collateralized
     */
    mapping(address user => uint256 sfDebt) private sfDebts;

    /**
     * @notice Aave protocol integration state container
     * @dev Contains:
     *   - poolAddress: Current Aave Pool contract (upgradeable)
     *   - investedAssets: EnumerableMap of active investments (asset => amount)
     *   - sfEngineAddress: Parent contract reference for access control
     */
    AaveInvestmentIntegration.Investment private aaveInvestment;

    /* -------------------------------------------------------------------------- */
    /*                                  Modifiers                                 */
    /* -------------------------------------------------------------------------- */

    modifier requireSupportedCollateral(address collateral) {
        _requireSupportedCollateral(collateral);
        _;
    }

    /* -------------------------------------------------------------------------- */
    /*                                 Initializer                                */
    /* -------------------------------------------------------------------------- */

    function initialize(
        address _sfTokenAddress, 
        address _aavePoolAddress,
        uint256 _investmentRatio,
        uint256 _autoHarvestDuration,
        uint256 _bonusRate,
        address[] memory _tokenAddresses, 
        address[] memory _priceFeedAddresses
    ) external initializer {
        __UUPSUpgradeable_init();
        __Ownable_init(msg.sender);
        _updateSupportedCollaterals(_tokenAddresses, _priceFeedAddresses);
        sfToken = SFToken(_sfTokenAddress);
        investmentRatio = _investmentRatio;
        autoHarvestDuration = _autoHarvestDuration;
        bonusRate = _bonusRate;
        lastAutoHarvestTime = block.timestamp;
        aaveInvestment.poolAddress = _aavePoolAddress;
        aaveInvestment.sfEngineAddress = address(this);
    }

    function reinitialize(
        uint64 _version,
        uint256 _investmentRatio,
        uint256 _autoHarvestDuration,
        uint256 _bonusRate,
        address[] memory _tokenAddresses, 
        address[] memory _priceFeedAddresses
    ) external reinitializer(_version) {
        investmentRatio = _investmentRatio;
        autoHarvestDuration = _autoHarvestDuration;
        bonusRate = _bonusRate;
        _updateSupportedCollaterals(_tokenAddresses, _priceFeedAddresses);
    }

    /* -------------------------------------------------------------------------- */
    /*                         External / Public Functions                        */
    /* -------------------------------------------------------------------------- */

    /// @inheritdoc ISFEngine
    function depositCollateralAndMintSFToken(
        address collateralAddress,
        uint256 amountCollateral,
        uint256 amountSFToMint
    ) external override requireSupportedCollateral(collateralAddress) {
        if (collateralAddress == address(0)) {
            revert ISFEngine__InvalidCollateralAddress();
        }
        if (amountCollateral == 0) {
            revert ISFEngine__AmountCollateralToDepositCanNotBeZero();
        }
        _depositCollateral(collateralAddress, amountCollateral);
        _mintSFToken(amountSFToMint);
        uint256 amountToInvest = amountCollateral * investmentRatio / PRECISION_FACTOR;
        aaveInvestment.invest(collateralAddress, amountToInvest);
    }

    /// @inheritdoc ISFEngine
    function redeemCollateral(
        address collateralAddress,
        uint256 amountCollateralToRedeem,
        uint256 amountSFToBurn
    ) public override requireSupportedCollateral(collateralAddress) {
        if (collateralAddress == address(0)) {
            revert ISFEngine__InvalidCollateralAddress();
        }
        if (amountSFToBurn == 0) {
            revert ISFEngine__AmountSFToBurnCanNotBeZero();
        }
        if (amountSFToBurn == type(uint256).max) {
            amountSFToBurn = sfToken.balanceOf(msg.sender);
        }
        uint256 collateralDeposited = collaterals[msg.sender][collateralAddress];
        if (collateralDeposited < amountCollateralToRedeem && amountCollateralToRedeem < type(uint256).max) {
            revert ISFEngine__AmountToRedeemExceedsDeposited(amountCollateralToRedeem, collateralDeposited);
        }
        if (amountSFToBurn == sfToken.balanceOf(msg.sender)) {
            amountCollateralToRedeem = type(uint256).max;
        }
        _burnSFToken(msg.sender, msg.sender, amountSFToBurn, amountSFToBurn, 0);
        _redeemCollateral(collateralAddress, amountCollateralToRedeem, msg.sender, msg.sender);
        _requireCollateralRatioIsNotBroken(msg.sender);
    }

    /// @inheritdoc ISFEngine
    function liquidate(
        address user, 
        address collateralAddress, 
        uint256 debtToCover
    ) 
        external 
        override 
        requireSupportedCollateral(collateralAddress) 
        returns (uint256)
    {
        if (user == address(0)) {
            revert ISFEngine__InvalidUserAddress();
        }
        if (collateralAddress == address(0)) {
            revert ISFEngine__InvalidCollateralAddress();
        }
        if (debtToCover == 0) {
            revert ISFEngine__DebtToCoverCanNotBeZero();
        }
        _requireCollateralRatioIsBroken(user);
        uint256 userDebt = sfDebts[user];
        if (debtToCover == type(uint256).max) {
            debtToCover = userDebt;
        }
        uint256 liquidatorBalance = sfToken.balanceOf(msg.sender);
        if (debtToCover > liquidatorBalance) {
            revert ISFEngine__InsufficientBalance(liquidatorBalance);
        }
        uint256 amountCollateralToLiquidate = _getTokenAmountForUsd(collateralAddress, debtToCover);
        uint256 amountDeposited = collaterals[user][collateralAddress];
        if (amountCollateralToLiquidate > amountDeposited) {
            amountCollateralToLiquidate = amountDeposited;
        }
        uint256 amountSFToBurn = debtToCover;
        uint256 bonus = amountCollateralToLiquidate * bonusRate / PRECISION_FACTOR;
        uint256 amountCollateralGiveToLiquidator = amountCollateralToLiquidate + bonus;
        uint256 bonusInSFToken;
        if (amountCollateralGiveToLiquidator > amountDeposited) {
            amountCollateralToLiquidate = amountDeposited;
            bonus = amountCollateralGiveToLiquidator - amountCollateralToLiquidate;
            bonusInSFToken = _getTokenValueInUsd(collateralAddress, bonus);
        } else {
            amountCollateralToLiquidate += bonus;
        }
        _burnSFToken(msg.sender, user, amountSFToBurn, debtToCover, bonusInSFToken);
        uint256 actualAmountRedeemed = _redeemCollateral(
            collateralAddress, 
            amountCollateralToLiquidate, 
            user, 
            msg.sender
        );
        _requireCollateralRatioIsNotBroken(user);
        _requireCollateralRatioIsNotBroken(msg.sender);
        return actualAmountRedeemed;
    }

    /// @inheritdoc ISFEngine
    function getBonusRate() external view override returns (uint256) {
        return bonusRate;
    }

    /// @inheritdoc ISFEngine
    function updateInvestmentRatio(uint256 newInvestmentRatio) external override onlyOwner {
        _updateInvestmentRatio(newInvestmentRatio);
    }

    /// @inheritdoc ISFEngine
    function harvest(address asset, uint256 amount) external onlyOwner {
        _harvest(asset, amount);
    }

    /// @inheritdoc ISFEngine
    function harvestAll() external onlyOwner {
        _harvestAll();
    }

    /// @inheritdoc ISFEngine
    function getInvestmentGain(address asset) external view override returns (uint256) {
        (, uint256 amount) = investmentGains.tryGet(asset);
        return amount;
    }

    /// @inheritdoc ISFEngine
    function getAllInvestmentGainInUsd() external view override returns (uint256) {
        uint256 totalValueInUsd;
        for (uint256 i = 0; i < investmentGains.length(); i++) {
            (address asset, uint256 gain) = investmentGains.at(i);
            totalValueInUsd += AggregatorV3Interface(priceFeeds[asset]).getTokenValue(gain);
        }
        return totalValueInUsd;
    }

    /// @inheritdoc ISFEngine
    function getInvestmentRatio() external view override returns (uint256) {
        return investmentRatio;
    }

    /// @inheritdoc ISFEngine
    function getSFDebt(address user) external view override returns (uint256) {
        return sfDebts[user];
    }

    /// @inheritdoc ISFEngine
    function calculateSFTokensByCollateral(
        address collateralAddress,
        uint256 amountCollateral,
        uint256 collateralRatio
    ) external view override returns (uint256) {
        uint256 collateralInUsd = _getTokenValueInUsd(collateralAddress, amountCollateral);
        return collateralInUsd * PRECISION_FACTOR / collateralRatio;
    }

    /// @inheritdoc ISFEngine
    function getTotalCollateralValueInUsd(address user) public view override returns (uint256) {
        return _getTotalCollateralValueInUsd(user);
    }

    /// @inheritdoc ISFEngine
    function getCollateralRatio(address user) public view override returns (uint256) {
        return _getCollateralRatio(user);
    }

    /// @inheritdoc ISFEngine
    function getCollateralAmount(address user, address collateralAddress) external view override returns (uint256) {
        return collaterals[user][collateralAddress];
    }

    /// @inheritdoc ISFEngine
    function getSupportedCollaterals() external override view returns (address[] memory) {
        return supportedCollaterals.values();
    }

    /// @inheritdoc ISFEngine
    function getMinimumCollateralRatio() external pure override returns (uint256) {
        return MINIMUM_COLLATERAL_RATIO;
    }

    /// @inheritdoc ISFEngine
    function getSFTokenAddress() external view override returns (address) {
        return address(sfToken);
    }

    /// @inheritdoc AutomationCompatibleInterface
    function checkUpkeep(bytes calldata /* checkData */) external view override returns (
        bool upkeepNeeded, 
        bytes memory performData
    ) {
        upkeepNeeded = _shouldAutoHarvest();
        performData = "";
    }

    /// @inheritdoc AutomationCompatibleInterface
    function performUpkeep(bytes calldata /* performData */) external override {
        if (_shouldAutoHarvest()) {
            _harvestAll();
        }
    }

    /// @inheritdoc ERC165
    function supportsInterface(bytes4 interfaceId) public view override returns (bool) {
        return interfaceId == type(ISFEngine).interfaceId || super.supportsInterface(interfaceId);
    }

    /* -------------------------------------------------------------------------- */
    /*                              Private Functions                             */
    /* -------------------------------------------------------------------------- */

    /// @inheritdoc UUPSUpgradeable
    function _authorizeUpgrade(address newImplementation) internal view override onlyOwner {
        if (!newImplementation.supportsInterface(type(ISFEngine).interfaceId)) {
            revert ISFEngine__IncompatibleImplementation();
        }
    }

    /**
     * @dev Updates the list of supported collateral tokens and their price feeds
     * @dev Enforces 1:1 mapping between tokens and price feeds
     * @param tokenAddresses Array of ERC20 token addresses to support as collateral
     * @param priceFeedAddresses Array of Chainlink price feed addresses corresponding to tokens
     * @custom:reverts ISFEngine__TokenAddressAndPriceFeedLengthNotMatch if array lengths mismatch
     */
    function _updateSupportedCollaterals(
        address[] memory tokenAddresses, 
        address[] memory priceFeedAddresses
    ) private {
        if (tokenAddresses.length != priceFeedAddresses.length) {
            revert ISFEngine__TokenAddressAndPriceFeedLengthNotMatch();
        }
        for (uint256 i = 0; i < tokenAddresses.length; i++) {
            supportedCollaterals.add(tokenAddresses[i]);
            priceFeeds[tokenAddresses[i]] = priceFeedAddresses[i];
        }
    }

    /**
     * @dev Deposits collateral tokens into the protocol
     * @dev Updates user's collateral balance and transfers tokens from sender
     * @param collateralAddress Address of the collateral token being deposited
     * @param amountCollateral Amount of tokens to deposit (in token decimals)
     * @custom:emits ISFEngine__CollateralDeposited On successful deposit
     * @custom:reverts ISFEngine__TransferFailed If ERC20 transfer fails
     */
    function _depositCollateral(address collateralAddress, uint256 amountCollateral) private {
        collaterals[msg.sender][collateralAddress] += amountCollateral;
        emit ISFEngine__CollateralDeposited(msg.sender, collateralAddress, amountCollateral);
        bool success = IERC20(collateralAddress).transferFrom(msg.sender, address(this), amountCollateral);
        if (!success) {
            revert ISFEngine__TransferFailed();
        }
    }

    /**
     * @dev Mints new SF tokens to the sender's address
     * @dev Increases sender's debt position and validates collateral ratio
     * @param amount Amount of SF tokens to mint (18 decimals)
     * @custom:emits ISFEngine__SFTokenMinted On successful minting
     * @custom:security Validates collateral ratio remains safe after minting
     */
    function _mintSFToken(uint256 amount) private {
        if (amount == 0) {
            return;
        }
        sfDebts[msg.sender] += amount;
        _requireCollateralRatioIsNotBroken(msg.sender);
        emit ISFEngine__SFTokenMinted(msg.sender, amount);
        sfToken.mint(msg.sender, amount);
    }

    /**
     * @dev Converts token amount to USD value using price feed
     * @param collateralAddress Address of the collateral token
     * @param amountToken Amount of tokens to convert (in token decimals)
     * @return USD value equivalent (18 decimals)
     * @custom:reverts If collateral is not supported
     */
    function _getTokenValueInUsd(
        address collateralAddress, 
        uint256 amountToken
    ) private view requireSupportedCollateral(collateralAddress) returns (uint256) {
        return AggregatorV3Interface(priceFeeds[collateralAddress]).getTokenValue(amountToken);
    }

    /**
     * @dev Converts USD amount to token amount using price feed
     * @param collateralAddress Address of the collateral token
     * @param amountUsd USD amount to convert (18 decimals)
     * @return Token amount equivalent (in token decimals)
     * @custom:reverts If collateral is not supported
     */
    function _getTokenAmountForUsd(
        address collateralAddress, 
        uint256 amountUsd
    ) private view requireSupportedCollateral(collateralAddress) returns (uint256) {
        return AggregatorV3Interface(priceFeeds[collateralAddress]).getTokensForValue(amountUsd);
    }

    /**
     * @dev Gets current USD price of a collateral token
     * @param collateralAddress Address of the collateral token
     * @return Current price in USD (18 decimals)
     * @custom:reverts If collateral is not supported
     */
    function _getTokenUsdPrice(address collateralAddress) private view requireSupportedCollateral(collateralAddress) returns (uint256) {
        return AggregatorV3Interface(priceFeeds[collateralAddress]).getPrice();
    }

    /**
     * @notice Burns SFTokens to cover a specified debt amount with possible burn reduction
     * @dev Handles debt coverage logic with optional burn amount reduction via bonus
     * @param from Address providing the SFTokens to burn
     * @param onBehalfOf Address whose debt is being covered
     * @param amountToBurn Initial amount of SFTokens requested for burning.
     *                     Use type(uint256).max to burn ALL available tokens from 'from' address.
     * @param debtToCover Debt amount to be covered by the burn. 
     *                    Use type(uint256).max to cover ALL debt of 'onBehalfOf' address.
     * @param bonus Token amount reduction from the burn (cannot exceed amountToBurn)
     */
    function _burnSFToken(
        address from, 
        address onBehalfOf, 
        uint256 amountToBurn, 
        uint256 debtToCover,
        uint256 bonus
    ) private {
        uint256 balance = sfToken.balanceOf(from);
        if (amountToBurn == type(uint256).max) {
            amountToBurn = balance;
        }
        if (balance < amountToBurn - bonus) {
            revert ISFEngine__InsufficientBalance(balance);
        }
        uint256 userSFDebt = sfDebts[onBehalfOf];
        if (debtToCover == type(uint256).max) {
            debtToCover = userSFDebt;
        }
        if (userSFDebt < debtToCover) {
            revert ISFEngine__DebtToCoverExceedsUserDebt(debtToCover, userSFDebt);
        }
        if (amountToBurn < debtToCover) {
            revert ISFEngine__DebtToCoverExceedsSFToBurn(debtToCover, amountToBurn);
        }
        sfDebts[onBehalfOf] -= debtToCover;
        uint256 actualAmountToBurn = bonus > amountToBurn ? 0 : amountToBurn - bonus;
        bool success = sfToken.transferFrom(from, address(this), actualAmountToBurn);
        if (!success) {
            revert ISFEngine__TransferFailed();
        }
        sfToken.burn(address(this), actualAmountToBurn);
    }

    /**
     * @dev Redeems collateral tokens from the protocol
     * @notice Handles collateral redemption with automatic Aave withdrawal if needed
     * @param collateralAddress Address of the collateral token to redeem
     * @param amountCollateralToRedeem Amount of collateral to redeem. 
     *        Use type(uint256).max to redeem ALL deposited collateral.
     * @param collateralFrom Address that originally deposited the collateral
     * @param collateralTo Address that will receive the redeemed collateral
     * @return actualAmountRedeemed Actual amount of collateral redeemed
     */
    function _redeemCollateral(
        address collateralAddress,
        uint256 amountCollateralToRedeem,
        address collateralFrom,
        address collateralTo
    ) private returns (uint256) {
        if (amountCollateralToRedeem == 0) {
            return 0;
        }
        uint256 collateralDeposited = collaterals[collateralFrom][collateralAddress];
        if (amountCollateralToRedeem == type(uint256).max) {
            amountCollateralToRedeem = collateralDeposited;
        }
        if (collateralDeposited < amountCollateralToRedeem) {
            revert ISFEngine__AmountToRedeemExceedsDeposited(amountCollateralToRedeem, collateralDeposited);
        }
        uint256 collateralBalance = IERC20(collateralAddress).balanceOf(address(this));
        if (collateralBalance < amountCollateralToRedeem) {
            uint256 amountToWithdrawFromAave = amountCollateralToRedeem - collateralBalance;
            aaveInvestment.withdraw(collateralAddress, amountToWithdrawFromAave);
        }
        collaterals[collateralFrom][collateralAddress] -= amountCollateralToRedeem;
        emit ISFEngine__CollateralRedeemed(collateralFrom, collateralAddress, amountCollateralToRedeem);
        bool success = IERC20(collateralAddress).transfer(collateralTo, amountCollateralToRedeem);
        if (!success) {
            revert ISFEngine__TransferFailed();
        }
        return amountCollateralToRedeem;
    }

    /**
     * @dev Updates the investment ratio parameter
     * @dev This ratio determines what percentage of collateral is allocated to yield strategies
     * @param newInvestmentRatio New ratio (18 decimals, 1e18 = 100%)
     * @custom:emits ISFEngine__UpdateInvestmentRatio
     * @custom:security Only callable by authorized contracts
     */
    function _updateInvestmentRatio(uint256 newInvestmentRatio) private {
        investmentRatio = newInvestmentRatio;
        emit ISFEngine__UpdateInvestmentRatio(newInvestmentRatio);
    }

    /**
     * @dev Calculates the total USD value of a user's collateral
     * @dev Sums value across all supported collateral types
     * @param user Address to calculate collateral value for
     * @return totalCollateralValueInUsd Total value in USD (18 decimals, 1e18 = 1$)
     */
    function _getTotalCollateralValueInUsd(address user) private view returns (uint256) {
        uint256 totalCollateralValueInUsd;
        for (uint256 i = 0; i < supportedCollaterals.length(); i++) {
            address collateralAddress = supportedCollaterals.at(i);
            uint256 amountCollateral = collaterals[user][collateralAddress];
            totalCollateralValueInUsd += _getTokenValueInUsd(collateralAddress, amountCollateral);
        }
        return totalCollateralValueInUsd;
    }

    /**
     * @dev Checks if a user's collateral ratio is below minimum
     * @param user Address to check
     * @return isBroken True if ratio is below minimum threshold
     * @return collateralRatio Current ratio value (18 decimals, 1e18 = 100%)
     */
    function _checkCollateralRatio(address user) public view returns (bool isBroken, uint256 collateralRatio) {
        collateralRatio = _getCollateralRatio(user);
        isBroken = collateralRatio < MINIMUM_COLLATERAL_RATIO;
        return (isBroken, collateralRatio);
    }
    
    /**
     * @dev Calculates a user's collateralization ratio
     * @dev Returns max uint256 if user has no debt
     * @param user Address to calculate ratio for
     * @return collateralRatio Current ratio (totalCollateralUSD / totalDebt) (18 decimals, 1e18 = 100%)
     */
    function _getCollateralRatio(address user) private view returns (uint256) {
        uint256 sfDebt = sfDebts[user];
        if (sfDebt == 0) {
            return type(uint256).max;
        }
        uint256 totalCollateralValueInUsd;
        for (uint256 i = 0; i < supportedCollaterals.length(); i++) {
            address collateralAddress = supportedCollaterals.at(i);
            uint256 amountCollateral = collaterals[user][collateralAddress];
            totalCollateralValueInUsd += _getTokenValueInUsd(collateralAddress, amountCollateral);
        }
        return totalCollateralValueInUsd * PRECISION_FACTOR / sfDebt;
    }

    /**
     * @dev Determines if auto-harvest should execute
     * @dev Checks time elapsed since last harvest and investment existence
     * @return True if harvest conditions are met
     */
    function _shouldAutoHarvest() private view returns (bool) {
        bool hasInvestedAsset = aaveInvestment.investedAssets.length() > 0;
        return hasInvestedAsset && block.timestamp - lastAutoHarvestTime >= autoHarvestDuration;
    }

    /**
     * @dev Harvests yield from a specific asset
     * @dev Withdraws from Aave and records interest earned
     * @param asset Address of the yield-bearing asset
     * @param amount Amount to withdraw (type(uint256).max for full withdrawal)
     */
    function _harvest(address asset, uint256 amount) private {
        (uint256 amountWithdrawn, uint256 interest) = aaveInvestment.withdraw(asset, amount);
        (, uint256 investmentGain) = investmentGains.tryGet(asset);
        investmentGains.set(asset, investmentGain + interest);
        emit ISFEngine__Harvest(asset, amountWithdrawn, interest);
    }

    /**
     * @dev Harvests yield from all invested assets
     * @dev Performs full withdrawal from all yield positions
     * @custom:emits ISFEngine__Harvest For each asset harvested
     */
    function _harvestAll() private {
        address[] memory assets = aaveInvestment.investedAssets.keys();
        for (uint256 i = 0; i < assets.length; i++) {
            _harvest(assets[i], type(uint256).max);
        }
    }

    function _requireSupportedCollateral(address collateral) private view {
        if (priceFeeds[collateral] == address(0)) {
            revert ISFEngine__CollateralNotSupported();
        }
    }

    function _requireCollateralRatioIsNotBroken(address user) private view {
        (bool isBroken, uint256 collateralRatio) = _checkCollateralRatio(user);
        if (isBroken) {
            revert ISFEngine__CollateralRatioIsBroken(user, collateralRatio);
        }
    }

    function _requireCollateralRatioIsBroken(address user) private view {
        (bool isBroken, uint256 collateralRatio) = _checkCollateralRatio(user);
        if (!isBroken) {
            revert ISFEngine__CollateralRatioIsNotBroken(user, collateralRatio);
        }
    }
}