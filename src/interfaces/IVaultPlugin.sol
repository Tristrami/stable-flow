// SPDX-License-Identifier: MIT
pragma solidity ^0.8.30;

interface IVaultPlugin {

    /* -------------------------------------------------------------------------- */
    /*                                   Errors                                   */
    /* -------------------------------------------------------------------------- */

    error IVaultPlugin__CollateralNotSupported(address collateral);
    error IVaultPlugin__CollateralsAndPriceFeedsCanNotBeEmpty();
    error IVaultPlugin__MismatchBetweenCollateralsAndPriceFeeds(
        uint256 numCollaterals, 
        uint256 numPriceFeeds
    );
    error IVaultPlugin__InsufficientCollateral(
        address receiver, 
        address collateralAddress, 
        uint256 balance, 
        uint256 required
    );
    error IVaultPlugin__DebtToRepayExceedsTotalDebt(uint256 debtToRepay, uint256 totalDebt);
    error IVaultPlugin__DebtToCoverExceedsTotalDebt(uint256 debtToCover, uint256 totalDebt);
    error IVaultPlugin__NotInvested();
    error IVaultPlugin__TopUpNotNeeded(
        uint256 currentCollateralInUsd, 
        uint256 requiredCollateralInUsd, 
        uint256 targetCollateralRatio
    );
    error IVaultPlugin__TopUpThresholdTooSmall(uint256 topUpThreshold, uint256 liquidationThreshold);
    error IVaultPlugin__CustomCollateralRatioTooSmall(uint256 collateralRatio, uint256 minCollateralRatio);
    error IVaultPlugin__NotSFAccount(address account);
    error IVaultPlugin__InsufficientBalance(address receiver, uint256 balance, uint256 required);
    error IVaultPlugin__TokenAmountCanNotBeZero();
    error IVaultPlugin__TransferFailed();
    error IVaultPlugin__NotFromEntryPoint();

    /* -------------------------------------------------------------------------- */
    /*                                   Events                                   */
    /* -------------------------------------------------------------------------- */

    event IVaultPlugin__UpdateCollateralAndPriceFeed(uint256 indexed numCollateral);
    event IVaultPlugin__Invest(
        address indexed collateralAddress, 
        uint256 indexed amountCollateral, 
        uint256 indexed sfToMint
    );
    event IVaultPlugin__Harvest(
        address indexed collateralAddress, 
        uint256 indexed amountCollateralToRedeem, 
        uint256 indexed debtToRepay
    );
    event IVaultPlugin__Liquidate(
        address indexed account, 
        address indexed collateralAddress, 
        uint256 indexed debtToCover
    );
    event IVaultPlugin__Danger(
        uint256 indexed currentCollateralRatio, 
        uint256 indexed liquidatingCollateralRatio
    );
    event IVaultPlugin__TopUpCollateral(
        address indexed collateralAddress, 
        uint256 indexed amountCollateral
    );
    event IVaultPlugin__CollateralRatioMaintained(
        uint256 indexed collateralTopedUpInUsd, 
        uint256 indexed targetCollateralRatio
    );
    event IVaultPlugin__InsufficientCollateralForTopUp(
        uint256 indexed requiredCollateralInUsd, 
        uint256 indexed currentCollateralRatio, 
        uint256 indexed targetCollateralRatio
    );
    event IVaultPlugin__Deposit(address indexed collateralAddress, uint256 indexed amount);
    event IVaultPlugin__Withdraw(address indexed collateralAddress, uint256 indexed amount);
    event IVaultPlugin__AddNewCollateral(address indexed collateralAddress);
    event IVaultPlugin__RemoveCollateral(address indexed collateralAddress);
    event IVaultPlugin__UpdateVaultConfig(bytes configData);
    event IVaultPlugin__UpdateCustomVaultConfig(bytes configData);

    /* -------------------------------------------------------------------------- */
    /*                                    Types                                   */
    /* -------------------------------------------------------------------------- */

    /**
     * @dev Vault configuration structure
     * @notice Contains the basic configuration parameters for a vault
     */
    struct VaultConfig {
        /// @dev Array of supported collateral token addresses
        address[] collaterals;
        /// @dev Array of price feed addresses corresponding to collaterals
        /// @notice Each price feed should match the collateral at the same index
        address[] priceFeeds;
    }

    /**
     * @dev Custom vault configuration structure
     * @notice Contains vault-specific configuration parameters that can be customized per vault
     */
    struct CustomVaultConfig {
        /// @dev Flag indicating whether automatic collateral top-up is enabled
        bool autoTopUpEnabled;
        /// @dev The collateral ratio threshold that triggers automatic top-up
        /// @notice When collateral ratio falls below this value and autoTopUpEnabled is true,
        /// the system will attempt to automatically add more collateral
        uint256 autoTopUpThreshold;
        /// @dev The collateral ratio used for investment operations
        /// @notice Must be greater than or equal to the minimum collateral ratio supported by SFEngine
        uint256 collateralRatio;
    }

    /**
     * @dev Deposit collateral token and mint sf token
     * @param collateralAddress The address of collateral token contract
     * @param amountCollateral The amount of collateral token to invest
     * @notice This function will:
     * - Check if the caller has sufficient collateral balance
     * - Calculate the amount of SF tokens to mint based on collateral ratio
     * - Approve the sfEngine to spend the collateral
     * - Deposit collateral and mint SF tokens through the sfEngine
     * @notice Reverts if:
     * - Caller doesn't have enough collateral (IVaultPlugin__InsufficientCollateral)
     * - Contract is frozen (requireNotFrozen modifier)
     * - Collateral is not supported (requireSupportedCollateral modifier)
     * - Caller is not the entry point (onlyEntryPoint modifier)
     */
    function invest(
        address collateralAddress,
        uint256 amountCollateral
    ) external;

    /**
     * @dev Redeem collateral by burning SF tokens
     * @param collateralAddress The address of collateral token to redeem
     * @param amountCollateralToRedeem The amount of collateral token to withdraw
     * @notice This function will:
     * - Calculate the amount of SF tokens needed to burn for the requested collateral
     * - Check if the contract has sufficient SF token balance
     * - Redeem collateral through the sfEngine
     * @notice Reverts if:
     * - Contract doesn't have enough SF tokens (IVaultPlugin__InsufficientBalance)
     * - Contract is frozen (requireNotFrozen modifier)
     * - Collateral is not supported (requireSupportedCollateral modifier)
     * - Caller is not the entry point (onlyEntryPoint modifier)
     */
    function harvest(
        address collateralAddress,
        uint256 amountCollateralToRedeem,
        uint256 debtToRepay
    ) external;

    /**
     * @dev Liquidate an undercollateralized account
     * @param account The address of account to liquidate
     * @param collateralAddress The address of collateral token to liquidate
     * @param debtToCover The amount of debt to cover in SF tokens
     * @notice This function will:
     * - Check if the contract has sufficient SF token balance
     * - Approve the sfEngine to spend SF tokens
     * - Execute liquidation through the sfEngine
     * @notice Reverts if:
     * - Contract doesn't have enough SF tokens (IVaultPlugin__InsufficientBalance)
     * - Contract is frozen (requireNotFrozen modifier)
     * - Collateral is not supported (requireSupportedCollateral modifier)
     * - Account is not an SFAccount (onlySFAccount modifier)
     * - Caller is not the entry point (onlyEntryPoint modifier)
     */
    function liquidate(address account, address collateralAddress, uint256 debtToCover) external;

    /**
     * @dev Get the current vault configuration
     * @return vaultConfig The current vault configuration struct
     * @notice Returns the complete VaultConfig struct stored in the contract
     */
    function getVaultConfig() external view returns (VaultConfig memory vaultConfig);

    /**
     * @dev Get the custom vault configuration
     * @return customConfig The current custom vault configuration
     * @notice Returns the custom configuration parameters for this specific vault
     */
    function getCustomVaultConfig() external view returns (CustomVaultConfig memory customConfig);

    /**
     * @dev Update the custom vault configuration
     * @param customConfig The new custom configuration
     * @notice Modifies vault-specific parameters like collateral ratio
     * @notice Only callable by the entry point (onlyEntryPoint modifier)
     */
    function updateCustomVaultConfig(CustomVaultConfig memory customConfig) external;

    /**
     * @dev Check if the vault's collateral position is safe
     * @return danger True if the position is in danger of liquidation
     * @return collateralRatio Current collateral ratio
     * @return liquidationThreshold The liquidation threshold ratio
     * @notice Provides information about the vault's collateral health status
     */
    function checkCollateralSafety() external view returns (bool danger, uint256 collateralRatio, uint256 liquidationThreshold);

    /**
     * @dev Add more collateral to the vault
     * @param collateralAddress The address of collateral token to add
     * @param amount The amount of collateral to add
     * @notice Only callable by the entry point (onlyEntryPoint modifier)
     * @notice Collateral must be supported (requireSupportedCollateral modifier)
     */
    function topUpCollateral(address collateralAddress, uint256 amount) external;

    /**
     * @dev Deposit collateral into the vault
     * @param collateralAddress The address of collateral token to deposit
     * @param amount The amount of collateral to deposit
     * @notice This function will:
     * - Track new collateral types added to the vault
     * - Transfer collateral from owner to vault
     * @notice Reverts if:
     * - Amount is zero (IVaultPlugin__InvalidTokenAmount)
     * - Transfer fails (IVaultPlugin__TransferFailed)
     * - Contract is frozen (requireNotFrozen modifier)
     * - Collateral is not supported (requireSupportedCollateral modifier)
     * - Caller is not the entry point (onlyEntryPoint modifier)
     */
    function deposit(address collateralAddress, uint256 amount) external;

    /**
     * @dev Withdraw collateral from the vault
     * @param collateralAddress The address of collateral token to withdraw
     * @param amount The amount of collateral to withdraw (type(uint256).max for full balance)
     * @notice This function will:
     * - Handle full balance withdrawal automatically when amount is max uint256
     * - Remove collateral from tracking if balance reaches zero
     * - Transfer collateral back to owner
     * @notice Reverts if:
     * - Collateral address is zero (IVaultPlugin__InvalidTokenAddress)
     * - Amount is zero (IVaultPlugin__InvalidTokenAmount)
     * - Insufficient collateral balance (IVaultPlugin__InsufficientCollateral)
     * - Transfer fails (IVaultPlugin__TransferFailed)
     * - Contract is frozen (requireNotFrozen modifier)
     * - Caller is not the entry point (onlyEntryPoint modifier)
     */
    function withdraw(address collateralAddress, uint256 amount) external;

    /**
     * @dev Get the balance of a specific collateral token in the vault
     * @param collateralAddress The address of collateral token to query
     * @return uint256 The current balance of the specified collateral (18 decimals)
     */
    function getCollateralBalance(address collateralAddress) external view returns (uint256);

    /**
     * @notice Gets the amount of collateral currently invested in yield strategies
     * @dev Returns the total invested amount for a specific collateral token
     * @param collateralAddress Address of the collateral token to query
     * @return uint256 Amount of collateral invested (18 decimals)
     */
    function getCollateralInvested(address collateralAddress) external view returns (uint256);

    /**
     * @dev Get the custom collateral ratio for this vault
     * @notice Returns the vault-specific collateral ratio setting
     * @return uint256 The custom collateral ratio value
     */
    function getCustomCollateralRatio() external view returns (uint256);

    /**
     * @dev Get current collateral ratio for this vault
     * @return uint256 The current collateral ratio value
     */
    function getCurrentCollateralRatio() external view returns (uint256);

    /**
     * @dev Get the list of all deposited collateral tokens
     * @return address[] Array of collateral token addresses
     * @notice Returns all collateral types currently deposited in the vault
     */
    function getDepositedCollaterals() external view returns (address[] memory);
}