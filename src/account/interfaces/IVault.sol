// SPDX-License-Identifier: MIT
pragma solidity ^0.8.30;

interface IVault {

    /**
     * @dev Deposit collateral token and mint sf token
     * @param collateralTokenAddress The address of collateral token contract
     * @param amountCollateral The amount of collateral token
     * @notice This will revert if the MINIMUM_COLLATERAL_RATIO is not met
     */
    function invest(
        address collateralTokenAddress,
        uint256 amountCollateral
    ) external;

    /**
     * @dev Redeem collateral and burn sf token
     * @param collateralTokenAddress The address of collateral token contract
     * @param amountCollateralToRedeem The amount of collateral token
     */
    function harvest(
        address collateralTokenAddress,
        uint256 amountCollateralToRedeem
    ) external;

    /**
     * @dev Liquidate user's collateral when collateral ratio is less than MINIMUM_COLLATERAL_RATIO
     * @param user The account address of user whose collateral ratio is less than MINIMUM_COLLATERAL_RATIO
     * @param collateralTokenAddress The address of collateral token contract
     * @param debtToCover The amount of debt (sf token) to cover
     */
    function liquidate(address user, address collateralTokenAddress, uint256 debtToCover) external;

    function deposit(address collateralAddress, uint256 amount) external;

    function withdraw(address collateralAddress, uint256 amount) external;

    function getCollateralBalance(address collateralAddress) external view returns (uint256);
}