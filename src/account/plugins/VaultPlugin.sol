// SPDX-License-Identifier: MIT
pragma solidity ^0.8.30;

import {IVaultPlugin} from "../../interfaces/IVaultPlugin.sol";
import {ISFEngine} from "../../interfaces/ISFEngine.sol";
import {ISFAccount} from "../../interfaces/ISFAccount.sol";
import {OracleLib, AggregatorV3Interface} from "../../libraries/OracleLib.sol";
import {EnumerableSet} from "@openzeppelin/contracts/utils/structs/EnumerableSet.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {ERC165Checker} from "@openzeppelin/contracts/utils/introspection/ERC165Checker.sol";
import {Initializable} from "@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol";
import {AutomationCompatible} from "@chainlink/contracts/src/v0.8/automation/AutomationCompatible.sol";
import {AutomationCompatibleInterface} from "@chainlink/contracts/src/v0.8/automation/interfaces/AutomationCompatibleInterface.sol";

contract VaultPlugin is IVaultPlugin, AutomationCompatible, Initializable {

    using OracleLib for AggregatorV3Interface;
    using EnumerableSet for EnumerableSet.AddressSet;
    using ERC165Checker for address;

    /* -------------------------------------------------------------------------- */
    /*                                   Errors                                   */
    /* -------------------------------------------------------------------------- */

    error VaultPlugin__CollateralNotSupported(address collateral);
    error VaultPlugin__MismatchBetweenCollateralAndPriceFeeds(
        uint256 numCollaterals, 
        uint256 numPriceFeeds
    );
    error VaultPlugin__InsufficientCollateral(
        address receiver, 
        address collateralAddress, 
        uint256 balance, 
        uint256 required
    );
    error VaultPlugin__TopUpNotNeeded(
        uint256 currentCollateralInUsd, 
        uint256 requiredCollateralInUsd, 
        uint256 targetCollateralRatio
    );
    error VaultPlugin__TopUpThresholdTooSmall(uint256 topUpThreshold, uint256 liquidationThreshold);
    error VaultPlugin__NotSFAccount(address account);
    error VaultPlugin__InsufficientBalance(address receiver, uint256 balance, uint256 required);
    error VaultPlugin__InvalidTokenAmount(uint256 tokenAmount);
    error VaultPlugin__TransferFailed();
    error VaultPlugin__InvalidTokenAddress(address tokenAddress);
    error VaultPlugin__NotFromEntryPoint();
    error VaultPlugin__AccountIsFrozen();

    /* -------------------------------------------------------------------------- */
    /*                                   Events                                   */
    /* -------------------------------------------------------------------------- */

    event VaultPlugin__CollateralAndPriceFeedUpdated(uint256 indexed numCollateral);
    event VaultPlugin__Invest(
        address indexed collateralAddress, 
        uint256 indexed amountCollateral, 
        uint256 indexed sfToMint
    );
    event VaultPlugin__Harvest(
        address indexed collateralAddress, 
        uint256 indexed amountCollateral, 
        uint256 indexed sfToBurn
    );
    event VaultPlugin__Liquidate(
        address indexed account, 
        address indexed collateralAddress, 
        uint256 indexed debtToCover
    );
    event VaultPlugin__Danger(
        uint256 indexed currentCollateralRatio, 
        uint256 indexed liquidatingCollateralRatio
    );
    event VaultPlugin__TopUpCollateral(
        address indexed collateralAddress, 
        uint256 indexed amountCollateral
    );
    event VaultPlugin__CollateralRatioMaintained(
        uint256 indexed collateralTopedUpInUsd, 
        uint256 indexed targetCollateralRatio
    );
    event VaultPlugin__InsufficientCollateralForTopUp(
        uint256 indexed requiredCollateralInUsd, 
        uint256 indexed currentCollateralRatio, 
        uint256 indexed targetCollateralRatio
    );
    event VaultPlugin__Deposit(address indexed collateralAddress, uint256 indexed amount);
    event VaultPlugin__Withdraw(address indexed collateralAddress, uint256 indexed amount);
    event VaultPlugin__AddNewCollateral(address indexed collateralAddress);
    event VaultPlugin__RemoveCollateral(address indexed collateralAddress);
    event VaultPlugin__UpdateCustomAutoTopUpConfig(bool indexed enabled, bytes configData);

    /* -------------------------------------------------------------------------- */
    /*                                    Types                                   */
    /* -------------------------------------------------------------------------- */

    struct VaultPluginStorage {
        mapping(address collateral => address priceFeed) supportedCollaterals; // Supported collateral and its price feed
        ISFEngine sfEngine; // SFEngine
        ISFAccount sfAccount; // SFAccount
        address sfTokenAddress; // The SF Token contract address
        address entryPointAddress; // The address of entry point address
        uint256 customCollateralRatio; // The collateral ration used to invest, must be greater than or equal to the minimum collateral ratio supported by SFEngine
        EnumerableSet.AddressSet depositedCollaterals; // The address set of deposited token contract address
        AutoTopUpConfig autoTopUpConfig; // Auto top up config
    }

    /* -------------------------------------------------------------------------- */
    /*                                  Constants                                 */
    /* -------------------------------------------------------------------------- */

    /// @dev keccak256(abi.encode(uint256(keccak256("stableflow.storage.VaultPlugin")) - 1)) & ~bytes32(uint256(0xff))
    bytes32 private constant VAULT_PLUGIN_STORAGE_LOCATION = 0x2e0734a179e09ba5c0a4792616988f710c223d2ae2465d68704e987ae2447600;
    /// @dev Precision factor used to calculate
    uint256 private constant PRECISION_FACTOR = 1e18;

    /* -------------------------------------------------------------------------- */
    /*                                  Modifiers                                 */
    /* -------------------------------------------------------------------------- */

    modifier onlyEntryPoint() {
        _requireFromEntryPoint();
        _;
    }

    modifier notFrozen() {
        _requireNotFrozen();
        _;
    }

    modifier requireSupportedCollateral(address collateral) {
        _requireSupportedCollateral(collateral);
        _;
    }

    modifier onlySFAccount(address account) {
        _requireSFAccount(account);
        _;
    }

    /* -------------------------------------------------------------------------- */
    /*                         External / Public Functions                        */
    /* -------------------------------------------------------------------------- */

    function __VaultPlugin_init(
        address[] memory collaterals,
        address[] memory priceFeeds,
        ISFEngine sfEngine,
        ISFAccount sfAccount,
        address sfTokenAddress,
        address entryPointAddress,
        uint256 customCollateralRatio,
        AutoTopUpConfig memory autoTopUpConfig
    ) external onlyInitializing {
        _updateSupportedCollaterals(collaterals, priceFeeds);
        VaultPluginStorage storage $ = _getVaultPluginStorage();
        $.sfEngine = sfEngine;
        $.sfAccount = sfAccount;
        $.sfTokenAddress = sfTokenAddress;
        $.entryPointAddress = entryPointAddress;
        $.customCollateralRatio = customCollateralRatio;
        $.autoTopUpConfig = autoTopUpConfig;
        _checkCustomAutoTopUpConfig(autoTopUpConfig.customConfig);
    }

    /// @inheritdoc IVaultPlugin
    function invest(
        address collateralAddress,
        uint256 amountCollateral
    ) 
        external 
        override 
        onlyEntryPoint 
        notFrozen 
        requireSupportedCollateral(collateralAddress)
    {
        VaultPluginStorage storage $ = _getVaultPluginStorage();
        uint256 collateralBalance = _getCollateralBalance(collateralAddress);
        if (collateralBalance < amountCollateral) {
            revert VaultPlugin__InsufficientCollateral(
                address($.sfEngine), 
                collateralAddress, 
                collateralBalance, 
                amountCollateral
            );
        }
        uint256 amountSFToMint = $.sfEngine.calculateSFTokensByCollateral(
            collateralAddress, 
            amountCollateral,
            $.customCollateralRatio
        );
        emit VaultPlugin__Invest(collateralAddress, amountCollateral, amountSFToMint);
        IERC20(collateralAddress).approve(address($.sfEngine), amountCollateral);
        $.sfEngine.depositCollateralAndMintSFToken(collateralAddress, amountCollateral, amountSFToMint);
    }

    /// @inheritdoc IVaultPlugin
    function harvest(
        address collateralAddress,
        uint256 amountCollateralToRedeem
    ) 
        external 
        override 
        onlyEntryPoint 
        notFrozen 
        requireSupportedCollateral(collateralAddress)
    {
        VaultPluginStorage storage $ = _getVaultPluginStorage();
        uint256 amountSFToBurn = $.sfEngine.calculateSFTokensByCollateral(
            collateralAddress, 
            amountCollateralToRedeem,
            $.customCollateralRatio
        );
        uint256 sfBalance = $.sfAccount.balance();
        if (amountSFToBurn > sfBalance) {
            revert VaultPlugin__InsufficientBalance(address(0), sfBalance, amountSFToBurn);
        }
        emit VaultPlugin__Harvest(collateralAddress, amountCollateralToRedeem, amountSFToBurn);
        $.sfEngine.redeemCollateral(collateralAddress, amountCollateralToRedeem, amountSFToBurn);
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
        notFrozen 
        onlySFAccount(account) 
        requireSupportedCollateral(collateralAddress)
    {
        VaultPluginStorage storage $ = _getVaultPluginStorage();
        uint256 sfBalance = $.sfAccount.balance();
        if (debtToCover > sfBalance) {
            revert VaultPlugin__InsufficientBalance(address(0), sfBalance, debtToCover);
        }
        emit VaultPlugin__Liquidate(account, collateralAddress, debtToCover);
        IERC20($.sfTokenAddress).approve(address($.sfEngine), debtToCover);
        $.sfEngine.liquidate(account, collateralAddress, debtToCover);
    }

    /// @inheritdoc IVaultPlugin
    function updateCustomAutoTopUpConfig(CustomAutoTopUpConfig memory customConfig) external override onlyEntryPoint {
        _updateCustomAutoTopUpConfig(customConfig);
    }

    /// @inheritdoc IVaultPlugin
    function getCustomAutoTopUpConfig() external view override returns (CustomAutoTopUpConfig memory customConfig) {
        VaultPluginStorage storage $ = _getVaultPluginStorage();
        return $.autoTopUpConfig.customConfig;
    }

    /// @inheritdoc IVaultPlugin
    function checkCollateralSafety() external view override returns (
        bool danger, 
        uint256 collateralRatio, 
        uint256 liquidationThreshold
    ) {
        return _checkCollateralSafety();
    }

    /// @inheritdoc IVaultPlugin
    function topUpCollateral(address collateralAddress, uint256 amount)
        external 
        override 
        onlyEntryPoint 
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
        notFrozen 
        requireSupportedCollateral(collateralAddress)
    {
        if (amount == 0) {
            revert VaultPlugin__InvalidTokenAmount(amount);
        }
        VaultPluginStorage storage $ = _getVaultPluginStorage();
        bool added = $.depositedCollaterals.add(collateralAddress);
        if (added) {
            emit VaultPlugin__AddNewCollateral(collateralAddress);
        }
        emit VaultPlugin__Deposit(collateralAddress, amount);
        bool success = IERC20(collateralAddress).transferFrom($.sfAccount.getOwner(), address(this), amount);
        if (!success) {
            revert VaultPlugin__TransferFailed();
        }
    }

    /// @inheritdoc IVaultPlugin
    function withdraw(
        address collateralAddress, 
        uint256 amount
    ) external override onlyEntryPoint notFrozen {
        VaultPluginStorage storage $ = _getVaultPluginStorage();
        if (collateralAddress == address(0)) {
            revert VaultPlugin__InvalidTokenAddress(collateralAddress);
        }
        if (amount == 0) {
            revert VaultPlugin__InvalidTokenAmount(amount);
        }
        uint256 collateralBalance = getCollateralBalance(collateralAddress);
        if (amount > collateralBalance) {
            if (amount == type(uint256).max) {
                amount = getCollateralBalance(collateralAddress);
            } else {
                revert VaultPlugin__InsufficientCollateral($.sfAccount.getOwner(), collateralAddress, collateralBalance, amount);
            }
        }
        if (amount == collateralBalance) {
            bool removed = $.depositedCollaterals.remove(collateralAddress);
            if (removed) {
                emit VaultPlugin__RemoveCollateral(collateralAddress);
            }
        }
        emit VaultPlugin__Withdraw(collateralAddress, amount);
        bool success = IERC20(collateralAddress).transfer($.sfAccount.getOwner(), amount);
        if (!success) {
            revert VaultPlugin__TransferFailed();
        }
    }

    /// @inheritdoc IVaultPlugin
    function getCollateralBalance(address collateralAddress) public view override returns (uint256) {
        return _getCollateralBalance(collateralAddress);
    }

    /// @inheritdoc IVaultPlugin
    function getCustomCollateralRatio() external view override returns (uint256) {
        VaultPluginStorage storage $ = _getVaultPluginStorage();
        return $.customCollateralRatio;
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
        upkeepNeeded = _shouldTopUp();
        return (upkeepNeeded, performData);
    }

    /// @inheritdoc AutomationCompatibleInterface
    function performUpkeep(bytes calldata /* performData */) external override {
        VaultPluginStorage storage $ = _getVaultPluginStorage();
        if (_shouldTopUp()) {
            _topUpToMaintainCollateralRatio($.autoTopUpConfig.customConfig.autoTopUpThreshold);
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

    function _updateSupportedCollaterals(
        address[] memory collaterals, 
        address[] memory priceFeeds
    ) private {
        VaultPluginStorage storage $ = _getVaultPluginStorage();
        if (collaterals.length != priceFeeds.length) {
            revert VaultPlugin__MismatchBetweenCollateralAndPriceFeeds(
                collaterals.length, 
                priceFeeds.length
            );
        }
        for (uint256 i = 0; i < collaterals.length; i++) {
            $.supportedCollaterals[collaterals[i]] = priceFeeds[i];
        }
        emit VaultPlugin__CollateralAndPriceFeedUpdated(collaterals.length);
    }

    function _checkCollateralSafety() private view returns (
        bool danger,
        uint256 collateralRatio, 
        uint256 liquidationThreshold
    ) {
        VaultPluginStorage storage $ = _getVaultPluginStorage();
        liquidationThreshold = $.sfEngine.getMinimumCollateralRatio();
        collateralRatio = $.sfEngine.getCollateralRatio(address(this));
        uint256 autoTopUpThreshold = $.autoTopUpConfig.customConfig.autoTopUpThreshold;
        if (collateralRatio < autoTopUpThreshold) {
            danger = true;
        }
    }

    function _shouldTopUp() private returns (bool) {
        VaultPluginStorage storage $ = _getVaultPluginStorage();
        if ($.autoTopUpConfig.customConfig.autoTopUpEnabled) {
            (bool danger, uint256 collateralRatio, uint256 liquidationThreshold) = _checkCollateralSafety();
            if (danger) {
                emit VaultPlugin__Danger(collateralRatio, liquidationThreshold);
                return true;
            }
        }
        return false;
    }

    function _topUpCollateral(address collateralAddress, uint256 amount) private {
        VaultPluginStorage storage $ = _getVaultPluginStorage();
        uint256 collateralBalance = _getCollateralBalance(collateralAddress);
        if (collateralBalance < amount) {
            revert VaultPlugin__InsufficientCollateral(
                address($.sfEngine), 
                collateralAddress, 
                collateralBalance, 
                amount
            );
        }
        emit VaultPlugin__TopUpCollateral(collateralAddress, amount);
        IERC20(collateralAddress).approve(address($.sfEngine), amount);
        $.sfEngine.depositCollateralAndMintSFToken(collateralAddress, amount, 0);
    }

    function _topUpToMaintainCollateralRatio(uint256 targetCollateralRatio) private {
        VaultPluginStorage storage $ = _getVaultPluginStorage();
        uint256 sfDebt = _getSFDebt();
        uint256 currentCollateralInUsd = $.sfEngine.getTotalCollateralValueInUsd(address(this));
        uint256 requiredCollateralInUsd = sfDebt * targetCollateralRatio / PRECISION_FACTOR;
        if (currentCollateralInUsd >= requiredCollateralInUsd) {
            revert VaultPlugin__TopUpNotNeeded(currentCollateralInUsd, requiredCollateralInUsd, targetCollateralRatio);
        }
        uint256 collateralToTopUpInUsd = requiredCollateralInUsd - currentCollateralInUsd;
        address[] memory collaterals = $.depositedCollaterals.values();
        for (uint256 i = 0; i < collaterals.length && collateralToTopUpInUsd > 0; i++) {
            address priceFeed = $.supportedCollaterals[collaterals[i]];
            uint256 collateralBalance = _getCollateralBalance(collaterals[i]);
            if (priceFeed == address(0) || collateralBalance == 0) {
                continue;
            }
            uint256 collateralBalanceInUsd = AggregatorV3Interface(priceFeed).getTokenValue(collateralBalance);
            uint256 amountCollateralToTopUp;
            if (collateralBalanceInUsd >= collateralToTopUpInUsd) {
                amountCollateralToTopUp = AggregatorV3Interface(priceFeed).getTokensForValue(collateralToTopUpInUsd);
                collateralToTopUpInUsd = 0;
            } else {
                amountCollateralToTopUp = AggregatorV3Interface(priceFeed).getTokensForValue(collateralBalanceInUsd);
                collateralToTopUpInUsd -= collateralBalanceInUsd;
            }
            _topUpCollateral(collaterals[i], amountCollateralToTopUp);
        }
        if (collateralToTopUpInUsd > 0) {
            uint256 currentCollateralRatio = requiredCollateralInUsd * PRECISION_FACTOR / sfDebt;
            emit VaultPlugin__InsufficientCollateralForTopUp(
                collateralToTopUpInUsd,
                currentCollateralRatio,
                targetCollateralRatio
            );
        }
        emit VaultPlugin__CollateralRatioMaintained(collateralToTopUpInUsd, targetCollateralRatio);
    }

    function _getSFDebt() private view returns (uint256) {
        VaultPluginStorage storage $ = _getVaultPluginStorage();
        return $.sfEngine.getSFDebt(address(this));
    }

    function _getCollateralBalance(address collateralAddress) private view returns (uint256) {
        VaultPluginStorage storage $ = _getVaultPluginStorage();
        return IERC20(collateralAddress).balanceOf(address($.sfAccount));
    }

    function _updateCustomAutoTopUpConfig(CustomAutoTopUpConfig memory customConfig) private {
        VaultPluginStorage storage $ = _getVaultPluginStorage();
        _checkCustomAutoTopUpConfig(customConfig);
        $.autoTopUpConfig.customConfig = customConfig;
        bytes memory configBytes = abi.encode(customConfig);
        emit VaultPlugin__UpdateCustomAutoTopUpConfig(customConfig.autoTopUpEnabled, configBytes);
    }

    function _checkCustomAutoTopUpConfig(CustomAutoTopUpConfig memory customConfig) private view {
        VaultPluginStorage storage $ = _getVaultPluginStorage();
        uint256 liquidationThreshold = $.sfEngine.getMinimumCollateralRatio();
        if (customConfig.autoTopUpThreshold < liquidationThreshold) {
            revert VaultPlugin__TopUpThresholdTooSmall(customConfig.autoTopUpThreshold, liquidationThreshold);
        }
    }

    function _requireFromEntryPoint() private view {
        VaultPluginStorage storage $ = _getVaultPluginStorage();
        if (msg.sender != $.entryPointAddress) {
            revert VaultPlugin__NotFromEntryPoint();
        }
    }

    function _requireNotFrozen() private view {
        VaultPluginStorage storage $ = _getVaultPluginStorage();
        if ($.sfAccount.isFrozen()) {
            revert VaultPlugin__AccountIsFrozen();
        }
    }

    function _requireSupportedCollateral(address collateral) private view {
        VaultPluginStorage storage $ = _getVaultPluginStorage();
        if ($.supportedCollaterals[collateral] == address(0)) {
            revert VaultPlugin__CollateralNotSupported(collateral);
        }
    }

    function _requireSFAccount(address account) private view {
        if (!account.supportsInterface(type(ISFAccount).interfaceId)) {
            revert VaultPlugin__NotSFAccount(account);
        }
    }
}