// SPDX-License-Identifier: MIT
pragma solidity ^0.8.30;

interface IVaultPlugin {

    /* -------------------------------------------------------------------------- */
    /*                                   Errors                                   */
    /* -------------------------------------------------------------------------- */

    /**
     * @dev Thrown when an unsupported collateral is used
     * @param collateral Address of the unsupported collateral token
     */
    error IVaultPlugin__CollateralNotSupported(address collateral);

    /**
     * @dev Thrown when collaterals and price feeds arrays are empty
     * @notice Both collaterals and price feeds must contain at least one element
     */
    error IVaultPlugin__CollateralsAndPriceFeedsCanNotBeEmpty();

    /**
     * @dev Thrown when the number of collaterals doesn't match the number of price feeds
     * @param numCollaterals Number of collateral tokens provided
     * @param numPriceFeeds Number of price feeds provided
     */
    error IVaultPlugin__MismatchBetweenCollateralsAndPriceFeeds(
        uint256 numCollaterals, 
        uint256 numPriceFeeds
    );

    /**
     * @dev Thrown when there's insufficient collateral balance
     * @param receiver Address attempting the operation
     * @param collateralAddress Address of the collateral token
     * @param balance Current balance of the collateral
     * @param required Minimum required balance
     */
    error IVaultPlugin__InsufficientCollateral(
        address receiver, 
        address collateralAddress, 
        uint256 balance, 
        uint256 required
    );

    /**
     * @dev Thrown when attempting to repay more debt than exists
     * @param debtToRepay Amount attempting to repay
     * @param totalDebt Current total debt
     */
    error IVaultPlugin__DebtToRepayExceedsTotalDebt(uint256 debtToRepay, uint256 totalDebt);

    /**
     * @dev Thrown when attempting to cover more debt than exists
     * @param debtToCover Amount attempting to cover
     * @param totalDebt Current total debt
     */
    error IVaultPlugin__DebtToCoverExceedsTotalDebt(uint256 debtToCover, uint256 totalDebt);

    /**
     * @dev Thrown when an operation requires investment but none exists
     * @notice Operation requires existing investment to proceed
     */
    error IVaultPlugin__NotInvested();

    /**
     * @dev Thrown when a top-up operation isn't needed
     * @param currentCollateralInUsd Current collateral value in USD
     * @param requiredCollateralInUsd Required collateral value in USD
     * @param targetCollateralRatio Target collateral ratio
     */
    error IVaultPlugin__TopUpNotNeeded(
        uint256 currentCollateralInUsd, 
        uint256 requiredCollateralInUsd, 
        uint256 targetCollateralRatio
    );

    /**
     * @dev Thrown when the top-up threshold is too small compared to liquidation threshold
     * @param topUpThreshold Proposed top-up threshold
     * @param liquidationThreshold Current liquidation threshold
     */
    error IVaultPlugin__TopUpThresholdTooSmall(uint256 topUpThreshold, uint256 liquidationThreshold);

    /**
     * @dev Thrown when the custom collateral ratio is below the minimum required
     * @param collateralRatio Proposed collateral ratio
     * @param minCollateralRatio Minimum allowed collateral ratio
     */
    error IVaultPlugin__CustomCollateralRatioTooSmall(uint256 collateralRatio, uint256 minCollateralRatio);

    /**
     * @dev Thrown when an account is not a valid SF account
     * @param account Address being checked
     */
    error IVaultPlugin__NotSFAccount(address account);

    /**
     * @dev Thrown when there's insufficient balance for an operation
     * @param receiver Address of receiver
     * @param balance Current balance available
     * @param required Minimum required balance
     */
    error IVaultPlugin__InsufficientBalance(address receiver, uint256 balance, uint256 required);

    /**
     * @dev Thrown when a zero token amount is provided
     * @notice Token amounts must be greater than zero
     */
    error IVaultPlugin__TokenAmountCanNotBeZero();

    /**
     * @dev Thrown when a token transfer fails
     * @notice Indicates a failed ERC20 transfer operation
     */
    error IVaultPlugin__TransferFailed();

    /**
     * @dev Thrown when a call is not made from the entry point
     * @notice Certain functions can only be called by the designated entry point
     */
    error IVaultPlugin__NotFromEntryPoint();

    /* -------------------------------------------------------------------------- */
    /*                                   Events                                   */
    /* -------------------------------------------------------------------------- */

    /**
     * @dev Emitted when collateral and price feed information is updated
     * @param numCollateral Number of collaterals updated (indexed)
     */
    event IVaultPlugin__UpdateCollateralAndPriceFeed(uint256 indexed numCollateral);

    /**
     * @dev Emitted when an investment is made
     * @param collateralAddress Address of the collateral token (indexed)
     * @param amountCollateral Amount of collateral invested (indexed)
     * @param sfToMint Amount of SF tokens to mint (indexed)
     */
    event IVaultPlugin__Invest(
        address indexed collateralAddress, 
        uint256 indexed amountCollateral, 
        uint256 indexed sfToMint
    );

    /**
     * @dev Emitted when funds are harvested/redeemed
     * @param collateralAddress Address of the collateral token (indexed)
     * @param amountCollateralToRedeem Amount of collateral being redeemed (indexed)
     * @param debtToRepay Amount of debt being repaid (indexed)
     */
    event IVaultPlugin__Harvest(
        address indexed collateralAddress, 
        uint256 indexed amountCollateralToRedeem, 
        uint256 indexed debtToRepay
    );

    /**
     * @dev Emitted when an account is liquidated
     * @param account Address of the account being liquidated (indexed)
     * @param collateralAddress Address of the collateral token (indexed)
     * @param debtToCover Amount of debt being covered (indexed)
     */
    event IVaultPlugin__Liquidate(
        address indexed account, 
        address indexed collateralAddress, 
        uint256 indexed debtToCover
    );

    /**
     * @dev Emitted when the collateral ratio reaches dangerous levels
     * @param currentCollateralRatio Current collateral ratio (indexed)
     * @param liquidatingCollateralRatio Liquidation threshold ratio (indexed)
     */
    event IVaultPlugin__Danger(
        uint256 indexed currentCollateralRatio, 
        uint256 indexed liquidatingCollateralRatio
    );

    /**
     * @dev Emitted when collateral is topped up
     * @param collateralAddress Address of the collateral token (indexed)
     * @param amountCollateral Amount of collateral added (indexed)
     */
    event IVaultPlugin__TopUpCollateral(
        address indexed collateralAddress, 
        uint256 indexed amountCollateral
    );

    /**
     * @dev Emitted when collateral ratio is successfully maintained
     * @param collateralTopedUpInUsd Amount of collateral topped up in USD (indexed)
     * @param targetCollateralRatio Target collateral ratio achieved (indexed)
     */
    event IVaultPlugin__CollateralRatioMaintained(
        uint256 indexed collateralTopedUpInUsd, 
        uint256 indexed targetCollateralRatio
    );

    /**
     * @dev Emitted when there's insufficient collateral for a top-up operation
     * @param requiredCollateralInUsd Required collateral amount in USD (indexed)
     * @param currentCollateralRatio Current collateral ratio (indexed)
     * @param targetCollateralRatio Target collateral ratio (indexed)
     */
    event IVaultPlugin__InsufficientCollateralForTopUp(
        uint256 indexed requiredCollateralInUsd, 
        uint256 indexed currentCollateralRatio, 
        uint256 indexed targetCollateralRatio
    );

    /**
     * @dev Emitted when collateral is deposited
     * @param collateralAddress Address of the collateral token (indexed)
     * @param amount Amount deposited (indexed)
     */
    event IVaultPlugin__Deposit(address indexed collateralAddress, uint256 indexed amount);

    /**
     * @dev Emitted when collateral is withdrawn
     * @param collateralAddress Address of the collateral token (indexed)
     * @param amount Amount withdrawn (indexed)
     */
    event IVaultPlugin__Withdraw(address indexed collateralAddress, uint256 indexed amount);

    /**
     * @dev Emitted when a new collateral is added
     * @param collateralAddress Address of the new collateral token (indexed)
     */
    event IVaultPlugin__AddNewCollateral(address indexed collateralAddress);

    /**
     * @dev Emitted when a collateral is removed
     * @param collateralAddress Address of the removed collateral token (indexed)
     */
    event IVaultPlugin__RemoveCollateral(address indexed collateralAddress);

    /**
     * @dev Emitted when the vault configuration is updated
     * @param configData New configuration data in bytes format
     */
    event IVaultPlugin__UpdateVaultConfig(bytes configData);

    /**
     * @dev Emitted when a custom vault configuration is updated
     * @param configData New custom configuration data in bytes format
     */
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
        /// @dev Gas limit for Chainlink Automation upkeep executions
        /// @notice Must be set according to the vault's expected operation complexity
        /// @notice Typical range: 200,000 - 500,000 gas depending on vault logic
        /// @notice Only used when creating account
        uint256 upkeepGasLimit;
        /// @dev Initial LINK amount required to register a Chainlink Automation upkeep
        /// @notice This amount will be locked when registering the vault's upkeep
        /// @notice Value should be in LINK token units (1e18 decimals)
        /// @notice Only used when creating account
        uint256 upkeepLinkAmount;
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