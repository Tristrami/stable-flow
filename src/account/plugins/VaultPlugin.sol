// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {FreezePlugin} from "./FreezePlugin.sol";
import {IVaultPlugin} from "../../interfaces/IVaultPlugin.sol";
import {ISFEngine} from "../../interfaces/ISFEngine.sol";
import {OracleLib, AggregatorV3Interface} from "../../libraries/OracleLib.sol";
import {EnumerableSet} from "@openzeppelin/contracts/utils/structs/EnumerableSet.sol";
import {EnumerableMap} from "@openzeppelin/contracts/utils/structs/EnumerableMap.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {ERC165Checker} from "@openzeppelin/contracts/utils/introspection/ERC165Checker.sol";
import {AutomationCompatible} from "@chainlink/contracts/src/v0.8/automation/AutomationCompatible.sol";
import {AutomationCompatibleInterface} from "@chainlink/contracts/src/v0.8/automation/interfaces/AutomationCompatibleInterface.sol";
import {AutomationRegistrarInterface} from "../../interfaces/AutomationRegistrarInterface.sol";
import {UpkeepIntegration} from "../../libraries/UpkeepIntegration.sol";

/**
 * @title VaultPlugin
 * @dev Abstract contract implementing collateral vault functionality for SFAccounts
 * @notice Provides:
 * - Collateral deposit/withdrawal management
 * - Automated collateral ratio maintenance
 * - Liquidation protection mechanisms
 * - Chainlink Automation integration
 * @notice Key features:
 * - Multi-collateral support with price feeds
 * - Configurable collateral ratios
 * - Auto-topup for collateral maintenance
 * - Integrated with SFEngine protocol
 * @notice Inherits from:
 * - IVaultPlugin (interface)
 * - BaseSFAccountPlugin (base plugin functionality) 
 * - AutomationCompatible (Chainlink Automation)
 */
abstract contract VaultPlugin is IVaultPlugin, FreezePlugin, AutomationCompatible {

    using OracleLib for AggregatorV3Interface;
    using UpkeepIntegration for AutomationRegistrarInterface;
    using EnumerableSet for EnumerableSet.AddressSet;
    using EnumerableMap for EnumerableMap.AddressToAddressMap;
    using ERC165Checker for address;

    /* -------------------------------------------------------------------------- */
    /*                                    Types                                   */
    /* -------------------------------------------------------------------------- */

    /**
     * @dev Storage structure for VaultPlugin contract
     * @notice Maintains all state variables for vault operations including:
     * - Protocol engine interface
     * - Token configurations
     * - Collateral tracking
     */
    struct VaultPluginStorage {
        /// @dev Reference to SFEngine protocol contract
        /// @notice Handles core protocol operations including collateral management
        ISFEngine sfEngine;
        /// @dev Address of the SF Token contract
        /// @notice Used for balance checks and token transfers
        address sfTokenAddress;
        /// @dev System-wide vault configuration
        /// @notice Contains protocol-level parameters for all vaults
        VaultConfig vaultConfig;
        /// @dev Vault-specific custom configuration
        /// @notice Allows per-vault customization of collateral parameters
        CustomVaultConfig customVaultConfig;
        /// @dev Mapping of supported collateral tokens to their price feeds
        /// @notice Uses EnumerableMap for efficient iteration and lookup
        EnumerableMap.AddressToAddressMap supportedCollaterals;
        /// @dev Set of currently deposited collateral tokens
        /// @notice Tracks active collateral positions for the vault
        EnumerableSet.AddressSet depositedCollaterals;
        /// @dev Address of chainlink upkeep registrar contract
        address automationRegistrarAddress;
        /// @dev Address of the Link Token contract
        address linkTokenAddress;
        /// @dev Tracks Chainlink Automation upkeep IDs for each vault
        /// @notice Maps vault addresses to their corresponding Chainlink upkeep IDs
        mapping(address vault => uint256 upkeepId) upkeeps;
    }

    /* -------------------------------------------------------------------------- */
    /*                                  Constants                                 */
    /* -------------------------------------------------------------------------- */

    /// @dev keccak256(abi.encode(uint256(keccak256("stableflow.storage.VaultPlugin")) - 1)) & ~bytes32(uint256(0xff))
    bytes32 private constant VAULT_PLUGIN_STORAGE_LOCATION = 0x2e0734a179e09ba5c0a4792616988f710c223d2ae2465d68704e987ae2447600;
    /// @dev Base precision factor used for mathematical calculations throughout the contract
    uint256 private constant PRECISION_FACTOR = 1e18;

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

    function __VaultPlugin_init(
        VaultConfig memory vaultConfig,
        CustomVaultConfig memory customVaultConfig,
        ISFEngine sfEngine,
        address sfTokenAddress,
        address automationRegistrarAddress,
        address linkTokenAddress
    ) internal onlyInitializing {
        VaultPluginStorage storage $ = _getVaultPluginStorage();
        $.sfEngine = sfEngine;
        $.sfTokenAddress = sfTokenAddress;
        $.automationRegistrarAddress = automationRegistrarAddress;
        $.linkTokenAddress = linkTokenAddress;
        _updateVaultConfig(vaultConfig);
        _updateCustomVaultConfig(customVaultConfig);
    }

    /* -------------------------------------------------------------------------- */
    /*                         External / Public Functions                        */
    /* -------------------------------------------------------------------------- */

    /// @inheritdoc IVaultPlugin
    function invest(
        address collateralAddress,
        uint256 amountCollateral
    ) 
        external 
        override 
        onlyEntryPoint 
        requireNotFrozen 
        requireSupportedCollateral(collateralAddress)
    {
        if (amountCollateral == 0) {
            revert IVaultPlugin__TokenAmountCanNotBeZero();
        }
        VaultPluginStorage storage $ = _getVaultPluginStorage();
        uint256 collateralBalance = _getCollateralBalance(collateralAddress);
        if (amountCollateral == type(uint256).max) {
            amountCollateral = collateralBalance;
        }
        if (collateralBalance < amountCollateral) {
            revert IVaultPlugin__InsufficientCollateral(
                address($.sfEngine), 
                collateralAddress, 
                collateralBalance, 
                amountCollateral
            );
        }
        uint256 amountSFToMint = $.sfEngine.calculateSFTokensByCollateral(
            collateralAddress, 
            amountCollateral,
            $.customVaultConfig.collateralRatio
        );
        emit IVaultPlugin__Invest(collateralAddress, amountCollateral, amountSFToMint);
        IERC20(collateralAddress).approve(address($.sfEngine), amountCollateral);
        $.sfEngine.depositCollateralAndMintSFToken(collateralAddress, amountCollateral, amountSFToMint);
    }

    /// @inheritdoc IVaultPlugin
    function harvest(
        address collateralAddress,
        uint256 amountCollateralToRedeem,
        uint256 debtToRepay
    ) 
        external 
        override 
        onlyEntryPoint 
        requireNotFrozen 
        requireSupportedCollateral(collateralAddress)
    {
        if (amountCollateralToRedeem == 0) {
            revert IVaultPlugin__TokenAmountCanNotBeZero();
        }
        if (debtToRepay == 0) {
            revert IVaultPlugin__TokenAmountCanNotBeZero();
        }
        VaultPluginStorage storage $ = _getVaultPluginStorage();
        uint256 sfDebt = $.sfEngine.getSFDebt(address(this));
        if (debtToRepay == type(uint256).max) {
            debtToRepay = sfDebt;
        }
        if (debtToRepay > sfDebt) {
            revert IVaultPlugin__DebtToRepayExceedsTotalDebt(debtToRepay, sfDebt);
        }
        uint256 sfBalance = this.balance();
        if (debtToRepay > sfBalance) {
            revert IVaultPlugin__InsufficientBalance(address($.sfEngine), sfBalance, debtToRepay);
        }
        uint256 collateralInvested = $.sfEngine.getCollateralAmount(address(this), collateralAddress);
        if (collateralInvested < amountCollateralToRedeem && amountCollateralToRedeem < type(uint256).max) {
            revert IVaultPlugin__InsufficientCollateral(
                address($.sfEngine),
                collateralAddress,
                collateralInvested,
                amountCollateralToRedeem
            );
        }
        IERC20($.sfTokenAddress).approve(address($.sfEngine), debtToRepay);
        emit IVaultPlugin__Harvest(collateralAddress, amountCollateralToRedeem, debtToRepay);
        $.sfEngine.redeemCollateral(collateralAddress, amountCollateralToRedeem, debtToRepay);
    }

    /// @inheritdoc IVaultPlugin
    function liquidate(
        address account, 
        address collateralAddress, 
        uint256 debtToCover
    ) 
        external 
        override 
        onlyEntryPoint 
        requireNotFrozen 
        onlySFAccount(account) 
        requireSupportedCollateral(collateralAddress)
    {
        if (debtToCover == 0) {
            revert IVaultPlugin__TokenAmountCanNotBeZero();
        }
        VaultPluginStorage storage $ = _getVaultPluginStorage();
        uint256 maxDebtToCover = $.sfEngine.getSFDebt(account);
        if (debtToCover == type(uint256).max) {
            debtToCover = maxDebtToCover;
        }
        if (debtToCover > maxDebtToCover) {
            revert IVaultPlugin__DebtToCoverExceedsTotalDebt(debtToCover, maxDebtToCover);
        }
        uint256 liquidatorSFBalance = this.balance();
        if (liquidatorSFBalance < debtToCover) {
            revert IVaultPlugin__InsufficientBalance(address($.sfEngine), liquidatorSFBalance, debtToCover);
        }
        emit IVaultPlugin__Liquidate(account, collateralAddress, debtToCover);
        IERC20($.sfTokenAddress).approve(address($.sfEngine), debtToCover);
        $.sfEngine.liquidate(account, collateralAddress, debtToCover);
    }


    /// @inheritdoc IVaultPlugin
    function getVaultConfig() external view override returns (VaultConfig memory vaultConfig) {
        VaultPluginStorage storage $ = _getVaultPluginStorage();
        return $.vaultConfig;
    }

    /// @inheritdoc IVaultPlugin
    function getCustomVaultConfig() external view override returns (CustomVaultConfig memory customConfig) {
        VaultPluginStorage storage $ = _getVaultPluginStorage();
        return $.customVaultConfig;
    }

    /// @inheritdoc IVaultPlugin
    function updateCustomVaultConfig(CustomVaultConfig memory customConfig) external override onlyEntryPoint {
        _updateCustomVaultConfig(customConfig);
    }

    /// @inheritdoc IVaultPlugin
    function checkCollateralSafety() external view override returns (
        bool danger, 
        uint256 collateralRatio, 
        uint256 liquidationThreshold
    ) {
        (, danger, collateralRatio, liquidationThreshold) =  _checkCollateralSafety();
    }

    /// @inheritdoc IVaultPlugin
    function topUpCollateral(address collateralAddress, uint256 amount)
        external 
        override 
        onlyEntryPoint 
        requireNotFrozen
        requireSupportedCollateral(collateralAddress)
    {
        _topUpCollateral(collateralAddress, amount);
    }

    /// @inheritdoc IVaultPlugin
    function deposit(
        address collateralAddress, 
        uint256 amount
    ) 
        external 
        override 
        onlyEntryPoint 
        requireNotFrozen 
        requireSupportedCollateral(collateralAddress)
    {
        if (amount == 0) {
            revert IVaultPlugin__TokenAmountCanNotBeZero();
        }
        VaultPluginStorage storage $ = _getVaultPluginStorage();
        bool added = $.depositedCollaterals.add(collateralAddress);
        if (added) {
            emit IVaultPlugin__AddNewCollateral(collateralAddress);
        }
        emit IVaultPlugin__Deposit(collateralAddress, amount);
        bool success = IERC20(collateralAddress).transferFrom(
            this.owner(), 
            address(this), 
            amount
        );
        if (!success) {
            revert IVaultPlugin__TransferFailed();
        }
    }

    /// @inheritdoc IVaultPlugin
    function withdraw(
        address collateralAddress, 
        uint256 amount
    ) 
        external 
        override 
        onlyEntryPoint 
        requireNotFrozen 
        requireSupportedCollateral(collateralAddress)
    {
        VaultPluginStorage storage $ = _getVaultPluginStorage();
        if (amount == 0) {
            revert IVaultPlugin__TokenAmountCanNotBeZero();
        }
        uint256 collateralBalance = _getCollateralBalance(collateralAddress);
        if (amount == type(uint256).max) {
            amount = collateralBalance;
        }
        if (amount > collateralBalance) {
            revert IVaultPlugin__InsufficientCollateral(
                this.owner(), 
                collateralAddress, 
                collateralBalance, 
                amount
            );
        }
        if (amount == collateralBalance) {
            bool removed = $.depositedCollaterals.remove(collateralAddress);
            if (removed) {
                emit IVaultPlugin__RemoveCollateral(collateralAddress);
            }
        }
        emit IVaultPlugin__Withdraw(collateralAddress, amount);
        bool success = IERC20(collateralAddress).transfer(this.owner(), amount);
        if (!success) {
            revert IVaultPlugin__TransferFailed();
        }
    }

    /// @inheritdoc IVaultPlugin
    function getCollateralBalance(address collateralAddress) public view override returns (uint256) {
        return _getCollateralBalance(collateralAddress);
    }

    /// @inheritdoc IVaultPlugin
    function getCollateralInvested(address collateralAddress) external view override returns (uint256) {
        return _getCollateralInvested(collateralAddress);
    }

    /// @inheritdoc IVaultPlugin
    function getCustomCollateralRatio() external view override returns (uint256) {
        VaultPluginStorage storage $ = _getVaultPluginStorage();
        return $.customVaultConfig.collateralRatio;
    }

    /// @inheritdoc IVaultPlugin
    function getCurrentCollateralRatio() external view override returns (uint256) {
        VaultPluginStorage storage $ = _getVaultPluginStorage();
        return $.sfEngine.getCollateralRatio(address(this));
    }
    
    /// @inheritdoc IVaultPlugin
    function getDepositedCollaterals() external view override returns (address[] memory) {
        VaultPluginStorage storage $ = _getVaultPluginStorage();
        return $.depositedCollaterals.values();
    }

    /// @inheritdoc AutomationCompatibleInterface
    function checkUpkeep(bytes calldata /* checkData */) external override returns (
        bool upkeepNeeded, 
        bytes memory performData
    ) {
        (
            bool autoTopUpNeeded, 
            bool danger, 
            uint256 collateralRatio, 
            uint256 liquidationThreshold
        ) = _checkCollateralSafety();
        upkeepNeeded = autoTopUpNeeded;
        if (danger) {
            emit IVaultPlugin__Danger(collateralRatio, liquidationThreshold);
        }
        return (upkeepNeeded, performData);
    }

    /// @inheritdoc AutomationCompatibleInterface
    function performUpkeep(bytes calldata /* performData */) external override {
        (bool autoTopUpNeeded, , , ) = _checkCollateralSafety();
        if (autoTopUpNeeded) {
            VaultPluginStorage storage $ = _getVaultPluginStorage();
            _topUpToMaintainCollateralRatio($.customVaultConfig.autoTopUpThreshold);
        }
    }

    /* -------------------------------------------------------------------------- */
    /*                        Internal / Private Functions                        */
    /* -------------------------------------------------------------------------- */

    function _getVaultPluginStorage() private pure returns (VaultPluginStorage storage $) {
        assembly {
            $.slot := VAULT_PLUGIN_STORAGE_LOCATION
        }
    }

    function _checkCollateralSafety() private view returns (
        bool autoTopUpNeeded,
        bool danger,
        uint256 collateralRatio, 
        uint256 liquidationThreshold
    ) {
        VaultPluginStorage storage $ = _getVaultPluginStorage();
        liquidationThreshold = $.sfEngine.getMinimumCollateralRatio();
        collateralRatio = $.sfEngine.getCollateralRatio(address(this));
        uint256 autoTopUpThreshold = $.customVaultConfig.autoTopUpThreshold;
        if (collateralRatio < autoTopUpThreshold) {
            danger = true;
        }
        autoTopUpNeeded = $.customVaultConfig.autoTopUpEnabled && danger;
    }

    function _topUpCollateral(address collateralAddress, uint256 amountCollateral) private {
        if (collateralAddress == address(0)) {
            revert IVaultPlugin__CollateralNotSupported(collateralAddress);
        }
        if (amountCollateral == 0) {
            revert IVaultPlugin__TokenAmountCanNotBeZero();
        }
        uint256 collateralInvested = _getCollateralInvested(collateralAddress);
        if (collateralInvested == 0) {
            revert IVaultPlugin__NotInvested();
        }
        VaultPluginStorage storage $ = _getVaultPluginStorage();
        uint256 collateralBalance = _getCollateralBalance(collateralAddress);
        if (amountCollateral == type(uint256).max) {
            amountCollateral = collateralBalance;
        }
        if (collateralBalance == 0 || collateralBalance < amountCollateral) {
            revert IVaultPlugin__InsufficientCollateral(
                address($.sfEngine), 
                collateralAddress, 
                collateralBalance, 
                amountCollateral
            );
        }
        emit IVaultPlugin__TopUpCollateral(collateralAddress, amountCollateral);
        IERC20(collateralAddress).approve(address($.sfEngine), amountCollateral);
        $.sfEngine.depositCollateralAndMintSFToken(collateralAddress, amountCollateral, 0);
    }

    function _topUpToMaintainCollateralRatio(uint256 targetCollateralRatio) private {
        VaultPluginStorage storage $ = _getVaultPluginStorage();
        uint256 sfDebt = this.debt();
        uint256 currentCollateralInUsd = $.sfEngine.getTotalCollateralValueInUsd(address(this));
        uint256 requiredCollateralInUsd = sfDebt * targetCollateralRatio / PRECISION_FACTOR;
        if (currentCollateralInUsd >= requiredCollateralInUsd) {
            revert IVaultPlugin__TopUpNotNeeded(currentCollateralInUsd, requiredCollateralInUsd, targetCollateralRatio);
        }
        uint256 collateralToTopUpInUsd = requiredCollateralInUsd - currentCollateralInUsd;
        uint256 remainingTopUpAmountInUsd = collateralToTopUpInUsd;
        address[] memory collaterals = $.depositedCollaterals.values();
        for (uint256 i = 0; i < collaterals.length && remainingTopUpAmountInUsd > 0; i++) {
            (bool collateralSupported, address priceFeed) = $.supportedCollaterals.tryGet(collaterals[i]);
            uint256 collateralBalance = _getCollateralBalance(collaterals[i]);
            if (!collateralSupported || collateralBalance == 0) {
                continue;
            }
            uint256 collateralBalanceInUsd = AggregatorV3Interface(priceFeed).getTokenValue(collateralBalance);
            uint256 amountCollateralToTopUp;
            if (collateralBalanceInUsd >= remainingTopUpAmountInUsd) {
                amountCollateralToTopUp = AggregatorV3Interface(priceFeed).getTokensForValue(remainingTopUpAmountInUsd);
                remainingTopUpAmountInUsd = 0;
            } else {
                amountCollateralToTopUp = AggregatorV3Interface(priceFeed).getTokensForValue(collateralBalanceInUsd);
                remainingTopUpAmountInUsd -= collateralBalanceInUsd;
            }
            _topUpCollateral(collaterals[i], amountCollateralToTopUp);
        }
        if (remainingTopUpAmountInUsd > 0) {
            uint256 currentCollateralRatio = currentCollateralInUsd * PRECISION_FACTOR / sfDebt;
            emit IVaultPlugin__InsufficientCollateralForTopUp(
                remainingTopUpAmountInUsd,
                currentCollateralRatio,
                targetCollateralRatio
            );
        } else {
            emit IVaultPlugin__CollateralRatioMaintained(collateralToTopUpInUsd, targetCollateralRatio);
        }
    }

    function _getCollateralBalance(address collateralAddress) private view returns (uint256) {
        return IERC20(collateralAddress).balanceOf(address(this));
    }

    function _getCollateralInvested(address collateralAddress) private view returns (uint256) {
        VaultPluginStorage storage $ = _getVaultPluginStorage();
        return $.sfEngine.getCollateralAmount(address(this), collateralAddress);
    }

    function _updateVaultConfig(VaultConfig memory vaultConfig) internal {
        _checkVaultConfig(vaultConfig);
        _updateSupportedCollaterals(vaultConfig.collaterals, vaultConfig.priceFeeds);
        VaultPluginStorage storage $ = _getVaultPluginStorage();
        $.vaultConfig = vaultConfig;
        bytes memory configBytes = abi.encode(vaultConfig);
        emit IVaultPlugin__UpdateVaultConfig(configBytes);
    }

    function _checkVaultConfig(VaultConfig memory vaultConfig) private pure {
        if (vaultConfig.collaterals.length == 0 && vaultConfig.priceFeeds.length == 0) {
            revert IVaultPlugin__CollateralsAndPriceFeedsCanNotBeEmpty();
        }
        if (vaultConfig.collaterals.length != vaultConfig.priceFeeds.length) {
            revert IVaultPlugin__MismatchBetweenCollateralsAndPriceFeeds(
                vaultConfig.collaterals.length, 
                vaultConfig.priceFeeds.length
            );
        }
    }

    function _updateSupportedCollaterals(
        address[] memory collaterals, 
        address[] memory priceFeeds
    ) internal {
        if (collaterals.length == 0 && priceFeeds.length == 0) {
            revert IVaultPlugin__CollateralsAndPriceFeedsCanNotBeEmpty();
        }
        VaultPluginStorage storage $ = _getVaultPluginStorage();
        if (collaterals.length != priceFeeds.length) {
            revert IVaultPlugin__MismatchBetweenCollateralsAndPriceFeeds(
                collaterals.length, 
                priceFeeds.length
            );
        }
        $.supportedCollaterals.clear();
        for (uint256 i = 0; i < collaterals.length; i++) {
            $.supportedCollaterals.set(collaterals[i], priceFeeds[i]);
        }
        emit IVaultPlugin__UpdateCollateralAndPriceFeed(collaterals.length);
    }

    function _updateCustomVaultConfig(CustomVaultConfig memory customConfig) private {
        _checkCustomVaultConfig(customConfig);
        VaultPluginStorage storage $ = _getVaultPluginStorage();
        _registerUpkeepIfNecessary(customConfig);
        $.customVaultConfig = customConfig;
        bytes memory configBytes = abi.encode(customConfig);
        emit IVaultPlugin__UpdateCustomVaultConfig(configBytes);
    }

    function _registerUpkeepIfNecessary(CustomVaultConfig memory customConfig) private {
        VaultPluginStorage storage $ = _getVaultPluginStorage();
        bool topUpCurrentlyEnabled = $.customVaultConfig.autoTopUpEnabled;
        bool shouldEnableTopUp = customConfig.autoTopUpEnabled;
        if (!topUpCurrentlyEnabled && shouldEnableTopUp) {
            uint256 upkeepId = $.upkeeps[address(this)];
            if (upkeepId == 0) {
                address owner = this.getOwner();
                upkeepId = AutomationRegistrarInterface($.automationRegistrarAddress).register(
                    this, 
                    owner, 
                    $.linkTokenAddress,
                    owner,
                    uint96(customConfig.upkeepLinkAmount),
                    uint32(customConfig.upkeepGasLimit)
                );
                $.upkeeps[address(this)] = upkeepId;
            }
        }
    }

    function _checkCustomVaultConfig(CustomVaultConfig memory customConfig) private view {
        VaultPluginStorage storage $ = _getVaultPluginStorage();
        uint256 minCollateralRatio = $.sfEngine.getMinimumCollateralRatio();
        if (customConfig.autoTopUpEnabled && customConfig.autoTopUpThreshold < minCollateralRatio) {
            revert IVaultPlugin__TopUpThresholdTooSmall(customConfig.autoTopUpThreshold, minCollateralRatio);
        }
        if (customConfig.collateralRatio < minCollateralRatio) {
            revert IVaultPlugin__CustomCollateralRatioTooSmall(customConfig.collateralRatio, minCollateralRatio);
        }
    }

    function _requireSupportedCollateral(address collateral) private view {
        VaultPluginStorage storage $ = _getVaultPluginStorage();
        if (!$.supportedCollaterals.contains(collateral)) {
            revert IVaultPlugin__CollateralNotSupported(collateral);
        }
    }
}