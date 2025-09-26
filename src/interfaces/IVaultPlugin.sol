// SPDX-License-Identifier: MIT
pragma solidity ^0.8.30;

interface IVaultPlugin {

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
        /// @dev The collateral ratio used for investment operations
        /// @notice Must be greater than or equal to the minimum collateral ratio supported by SFEngine
        uint256 collateralRatio;
        /// @dev Flag indicating whether automatic collateral top-up is enabled
        bool autoTopUpEnabled;
        /// @dev The collateral ratio threshold that triggers automatic top-up
        /// @notice When collateral ratio falls below this value and autoTopUpEnabled is true,
        /// the system will attempt to automatically add more collateral
        uint256 autoTopUpThreshold;
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
     * - Caller doesn't have enough collateral (VaultPlugin__InsufficientCollateral)
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
     * - Contract doesn't have enough SF tokens (VaultPlugin__InsufficientBalance)
     * - Contract is frozen (requireNotFrozen modifier)
     * - Collateral is not supported (requireSupportedCollateral modifier)
     * - Caller is not the entry point (onlyEntryPoint modifier)
     */
    function harvest(
        address collateralAddress,
        uint256 amountCollateralToRedeem
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
     * - Contract doesn't have enough SF tokens (VaultPlugin__InsufficientBalance)
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
     * @dev Update the vault configuration
     * @param vaultConfig The new vault configuration
     * @notice This will update the entire vault configuration
     * @notice Only callable by authorized addresses (internal _updateVaultConfig handles permissions)
     */
    function updateVaultConfig(VaultConfig memory vaultConfig) external;

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
     * - Amount is zero (VaultPlugin__InvalidTokenAmount)
     * - Transfer fails (VaultPlugin__TransferFailed)
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
     * - Collateral address is zero (VaultPlugin__InvalidTokenAddress)
     * - Amount is zero (VaultPlugin__InvalidTokenAmount)
     * - Insufficient collateral balance (VaultPlugin__InsufficientCollateral)
     * - Transfer fails (VaultPlugin__TransferFailed)
     * - Contract is frozen (requireNotFrozen modifier)
     * - Caller is not the entry point (onlyEntryPoint modifier)
     */
    function withdraw(address collateralAddress, uint256 amount) external;

    /**
     * @dev Get the balance of a specific collateral token in the vault
     * @param collateralAddress The address of collateral token to query
     * @return uint256 The current balance of the specified collateral
     */
    function getCollateralBalance(address collateralAddress) external view returns (uint256);

    /**
     * @dev Get the custom collateral ratio for this vault
     * @return uint256 The custom collateral ratio value
     * @notice Returns the vault-specific collateral ratio setting
     */
    function getCustomCollateralRatio() external view returns (uint256);

    /**
     * @dev Get the list of all deposited collateral tokens
     * @return address[] Array of collateral token addresses
     * @notice Returns all collateral types currently deposited in the vault
     */
    function getDepositedCollaterals() external view returns (address[] memory);
}