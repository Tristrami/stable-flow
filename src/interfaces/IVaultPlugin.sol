// SPDX-License-Identifier: MIT
pragma solidity ^0.8.30;

interface IVaultPlugin {

    struct VaultConfig {
        address[] collaterals; // Supported collaterals
        address[] priceFeeds; // Collateral correlated price feeds
    }

    struct CustomVaultConfig {
        uint256 collateralRatio; // The collateral ration used to invest, must be greater than or equal to the minimum collateral ratio supported by SFEngine
        bool autoTopUpEnabled; // Whether this account supports collateral auto top up
        uint256 autoTopUpThreshold; // The collateral ratio threshold for auto top up
    }

    /**
     * @dev Deposit collateral token and mint sf token
     * @param collateralAddress The address of collateral token contract
     * @param amountCollateral The amount of collateral token
     * @notice This will revert if the MINIMUM_COLLATERAL_RATIO is not met
     */
    function invest(
        address collateralAddress,
        uint256 amountCollateral
    ) external;

    /**
     * @dev Redeem collateral and burn sf token
     * @param collateralAddress The address of collateral token contract
     * @param amountCollateralToRedeem The amount of collateral token
     */
    function harvest(
        address collateralAddress,
        uint256 amountCollateralToRedeem
    ) external;

    /**
     * @dev Liquidate user's collateral when collateral ratio is less than MINIMUM_COLLATERAL_RATIO
     * @param account The account address whose collateral ratio is less than MINIMUM_COLLATERAL_RATIO
     * @param collateralAddress The address of collateral token contract
     * @param debtToCover The amount of debt (sf token) to cover
     */
    function liquidate(address account, address collateralAddress, uint256 debtToCover) external;

    function getVaultConfig() external view returns (VaultConfig memory vaultConfig);

    function updateVaultConfig(VaultConfig memory vaultConfig) external;

    function getCustomVaultConfig() external view returns (CustomVaultConfig memory customConfig);

    function updateCustomVaultConfig(CustomVaultConfig memory customConfig) external;

    function checkCollateralSafety() external view returns (bool danger, uint256 collateralRatio, uint256 liquidationThreshold);

    function topUpCollateral(address collateralAddress, uint256 amount) external;

    function deposit(address collateralAddress, uint256 amount) external;

    function withdraw(address collateralAddress, uint256 amount) external;

    function getCollateralBalance(address collateralAddress) external view returns (uint256);

    function getCustomCollateralRatio() external view returns (uint256);

    function getDepositedCollaterals() external view returns (address[] memory);
}