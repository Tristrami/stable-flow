// SPDX-License-Identifier: MIT
pragma solidity ^0.8.30;

interface ISFEngine {
    /**
     * @dev Deposit collateral token and mint sf token
     * @param collateralTokenAddress The address of collateral token contract
     * @param amountCollateral The amount of collateral token
     * @param amountSFToMint The amount of sf token to mint
     * @notice This will revert if the MINIMUM_COLLATERAL_RATIO is not met
     */
    function depositCollateralAndMintSFToken(
        address collateralTokenAddress,
        uint256 amountCollateral,
        uint256 amountSFToMint
    ) external;

    /**
     * @dev Redeem collateral and burn sf token
     * @param collateralTokenAddress The address of collateral token contract
     * @param amountCollateralToRedeem The amount of collateral token
     * @param amountSFToBurn The amount of sf token to burn
     */
    function redeemCollateral(
        address collateralTokenAddress,
        uint256 amountCollateralToRedeem,
        uint256 amountSFToBurn
    ) external;

    /**
     * @dev Liquidate user's collateral when collateral ratio is less than MINIMUM_COLLATERAL_RATIO
     * @param user The account address of user whose collateral ratio is less than MINIMUM_COLLATERAL_RATIO
     * @param collateralTokenAddress The address of collateral token contract
     * @param debtToCover The amount of debt (sf token) to cover
     */
    function liquidate(address user, address collateralTokenAddress, uint256 debtToCover) external;

    /**
     * @dev Get user's collateral ratio
     * @param user The account address of user
     */
    function getCollateralRatio(address user) external returns (uint256);
}
