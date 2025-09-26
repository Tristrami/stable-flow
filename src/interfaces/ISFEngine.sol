// SPDX-License-Identifier: MIT
pragma solidity ^0.8.30;

interface ISFEngine {
    
    /**
     * @dev Deposit collateral and mint SF tokens in a single transaction
     * @param collateralAddress Address of the collateral token to deposit
     * @param amountCollateral Amount of collateral to deposit
     * @param amountSFToMint Amount of SF tokens to mint
     * @notice Requirements:
     * - Collateral address must not be zero (notZeroAddress)
     * - Collateral amount must not be zero (notZeroValue)
     * - Token must be supported (onlySupportedToken)
     * @notice Calls internal _depositCollateral and _mintSFToken functions
     */
    function depositCollateralAndMintSFToken(
        address collateralAddress,
        uint256 amountCollateral,
        uint256 amountSFToMint
    ) external;

    /**
     * @dev Redeem collateral by burning SF tokens
     * @param collateralAddress Address of the collateral token to redeem
     * @param amountCollateralToRedeem Amount of collateral to withdraw
     * @param amountSFToBurn Amount of SF tokens to burn
     * @notice Requirements:
     * - Collateral address must not be zero (notZeroAddress)
     * - Collateral amount must not be zero (notZeroValue)
     * - Token must be supported (onlySupportedToken)
     * @notice Performs checks to ensure collateral ratio is maintained after redemption
     */
    function redeemCollateral(
        address collateralAddress,
        uint256 amountCollateralToRedeem,
        uint256 amountSFToBurn
    ) external;

    /**
     * @dev Liquidate an undercollateralized position
     * @param user Address of the undercollateralized account
     * @param collateralAddress Address of the collateral token to liquidate
     * @param debtToCover Amount of SF token debt to cover
     * @notice Requirements:
     * - Collateral address must not be zero (notZeroAddress)
     * - Debt amount must not be zero (notZeroValue)
     * - Token must be supported (onlySupportedToken)
     * - Position must be undercollateralized
     * @notice Liquidator receives 10% bonus in collateral
     * @notice Ensures both parties maintain proper collateral ratio after liquidation
     */
    function liquidate(address user, address collateralAddress, uint256 debtToCover) external;

    /**
     * @dev Get the SF token debt amount for a user
     * @param user Address to query
     * @return uint256 Current SF token debt balance
     */
    function getSFDebt(address user) external view returns (uint256);

    /**
     * @dev Calculate SF tokens that can be minted for given collateral
     * @param collateralAddress Address of collateral token
     * @param amountCollateral Amount of collateral
     * @param collateralRatio Collateral ratio to use for calculation
     * @return uint256 Amount of SF tokens that can be minted
     * @notice Uses current price feed to convert collateral to USD value
     */
    function calculateSFTokensByCollateral(
        address collateralAddress,
        uint256 amountCollateral,
        uint256 collateralRatio
    ) external view returns (uint256);

    /**
     * @dev Get total collateral value in USD for a user
     * @param user Address to query
     * @return uint256 Total collateral value in USD
     * @notice Sums value of all supported collateral tokens
     */
    function getTotalCollateralValueInUsd(address user) external view returns (uint256);

    /**
     * @dev Get current collateral ratio for a user
     * @param user Address to query
     * @return uint256 Current collateral ratio (precision adjusted)
     * @notice Returns max uint256 if user has no debt
     */
    function getCollateralRatio(address user) external view returns (uint256);

    /**
     * @dev Get system minimum collateral ratio
     * @return uint256 Minimum collateral ratio required by the system
     */
    function getMinimumCollateralRatio() external view returns (uint256);

    /**
     * @dev Get SF token contract address
     * @return address Address of the SF token contract
     */
    function getSFTokenAddress() external returns (address);
}
