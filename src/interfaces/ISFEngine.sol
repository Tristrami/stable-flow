// SPDX-License-Identifier: MIT
pragma solidity ^0.8.30;

interface ISFEngine {
    
    /**
     * @dev Deposit collateral token and mint sf token
     * @param collateralAddress The address of collateral contract
     * @param amountCollateral The amount of collateral token
     * @param amountSFToMint The amount of sf token to mint
     * @notice This will revert if the MINIMUM_COLLATERAL_RATIO is not met
     */
    function depositCollateralAndMintSFToken(
        address collateralAddress,
        uint256 amountCollateral,
        uint256 amountSFToMint
    ) external;

    /**
     * @dev Redeem collateral and burn sf token
     * @param collateralAddress The address of collateral contract
     * @param amountCollateralToRedeem The amount of collateral token
     * @param amountSFToBurn The amount of sf token to burn
     */
    function redeemCollateral(
        address collateralAddress,
        uint256 amountCollateralToRedeem,
        uint256 amountSFToBurn
    ) external;

    /**
     * @dev Liquidate user's collateral when collateral ratio is less than MINIMUM_COLLATERAL_RATIO
     * @param user The account address of user whose collateral ratio is less than MINIMUM_COLLATERAL_RATIO
     * @param collateralAddress The address of collateral contract
     * @param debtToCover The amount of debt (sf token) to cover
     */
    function liquidate(address user, address collateralAddress, uint256 debtToCover) external;

    /**
     * @dev Get user's SFToken debt
     * @param user The account address of user
     * @return debt The remaining debt
     */
    function getSFDebt(address user) external view returns (uint256);

    /**
     * @dev Calculate the amount of SFToken based on the minimum collateral ratio
     * @param collateralAddress The address of collateral contract
     * @param amountCollateral The amount of collateral token
     * @return amountSFToken The amount of SFToken
     */
    function calculateSFTokensByCollateral(
        address collateralAddress,
        uint256 amountCollateral,
        uint256 collateralRatio
    ) external view returns (uint256);

    /**
     * @dev Get user's collateral ratio
     * @param user The account address of user
     * @return collateralRatio user's collateral ratio
     */
    function getCollateralRatio(address user) external view returns (uint256);

    /**
     * @dev Get user's total collateral value in usd
     * @param user The account address of user
     * @return totalCollateralValueInUsd total collateral value in usd
     */
    function getTotalCollateralValueInUsd(address user) external view returns (uint256);

    /**
     * @dev Get minimum collateral ratio
     */
    function getMinimumCollateralRatio() external view returns (uint256);

    /**
     * @dev Get the address of SFToken contract
     */
    function getSFTokenAddress() external returns (address);
}
