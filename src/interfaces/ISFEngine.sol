// SPDX-License-Identifier: MIT
pragma solidity ^0.8.30;

interface ISFEngine {
    
    /**
     * @notice Deposits collateral and mints SF Tokens in a single transaction
     * @dev Combines collateral deposit, token minting, and automated yield farming
     * @param collateralAddress Address of the collateral token (must be whitelisted)
     * @param amountCollateral Amount of collateral to deposit (in token decimals)
     * @param amountSFToMint Amount of SF Tokens to mint (18 decimals)
     * @custom:requires Supported collateral (enforced by requireSupportedCollateral modifier)
     * @custom:effects 
     *   - Transfers collateral from user to protocol
     *   - Mints SF Tokens to user
     *   - Automatically invests portion to Aave (based on investmentRatio)
     * @custom:reverts 
     *   - With SFEngine__InvalidCollateralAddress if collateralAddress is zero
     *   - With SFEngine__AmountCollateralToDepositCanNotBeZero for zero deposits
     *   - With AaveInvestmentIntegration__InsufficientBalance if investment fails
     * @custom:security 
     *   - Reentrancy guarded
     *   - Collateral support verified
     *   - Investment ratio capped
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
     * @notice Updates the investment ratio (percentage of collateral assets allocated to investments)
     * @dev Restricted to authorized roles, modifies core protocol parameters
     * @param newInvestmentRatio New investment ratio in basis points (e.g., 5000 = 50%)
     * @custom:access Only addresses with CONFIGURATOR_ROLE
     * @custom:effect Updates `investmentRatio` state variable and may trigger rebalancing
     * @custom:security Reverts if ratio exceeds safety limits (MIN/MAX_INVESTMENT_RATIO)
     */
    function updateInvestmentRatio(uint256 newInvestmentRatio) external;

    /**
     * @notice Harvests investment gains from a specific asset
     * @dev Withdraws specified yield amount from external protocols (e.g., Aave)
     * @param asset Address of the yield-bearing asset (e.g., USDC, DAI)
     * @param amount Amount to harvest (in asset's native decimals)
     * @custom:access Only contract owner
     * @custom:effect Increases protocol treasury balance, updates `investmentGains` mapping
     * @custom:reverts If asset is unsupported or insufficient yield available
     */
    function harvest(address asset, uint256 amount) external;

    /**
     * @notice Harvests all available yields from all invested assets
     * @dev Iterates through all supported assets for batch processing
     * @custom:access Only contract owner
     * @custom:effect Updates all entries in `investmentGains` mapping
     * @custom:warning High gas consumption (scales with number of assets)
     * @custom:recommendation Execute during low network congestion
     */
    function harvestAll() external;

    /**
     * @notice Queries accumulated investment gains for a specific asset
     * @param asset Address of the asset to query
     * @return uint256 Total unclaimed yield (in asset's native decimals)
     * @dev Data sourced from internal `investmentGains` mapping
     * @custom:warning Returned value may fluctuate with market conditions
     */
    function getInvestmentGain(address asset) external view returns (uint256);

    /**
     * @notice Calculates total unrealized gains across all assets in USD value
     * @return uint256 Aggregate yield value (18 decimal precision)
     * @dev Uses Chainlink oracles for real-time price feeds
     * @custom:warning Extremely gas-intensive (multiple oracle calls + iteration)
     * @custom:reverts If any asset's oracle is unavailable
     * @custom:recommendation Use off-chain view function for frequent queries
     */
    function getAllInvestmentGainInUsd() external view returns (uint256);

    /**
     * @notice Returns the current investment ratio used by the protocol
     * @dev The investment ratio determines what percentage of deposited collateral is allocated to yield-generating protocols (e.g., Aave)
     * @dev Ratio is expressed in basis points (1e18 = 100%)
     * @return uint256 Current investment ratio with 18 decimal precision
     * @custom:examples
     * - 0.5e18 → 50% of collateral invested
     * - 0.3e18 → 30% of collateral invested
     * @custom:security This is a view function that does not modify state
     */
    function getInvestmentRatio() external view returns (uint256);

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
     * @dev Retrieves the collateral amount deposited by a specific user for a given collateral token
     * @param user Address of the user to query
     * @param collateralAddress Address of the collateral token contract
     * @return uint256 Amount of collateral deposited by the user (in token's native decimals)
     * @notice Returns 0 if:
     * - User has no deposited collateral
     * - Token is not supported as collateral
     */
    function getCollateralAmount(address user, address collateralAddress) external view returns (uint256);

    /**
     * @dev Gets the list of all supported collateral addresses
     * @return address[] memory Array of supported collateral contract addresses
     * @notice Returned array includes:
     * - Currently active collateral
     * - Tokens that may have zero total deposits
     * @notice The order of addresses in the array is not guaranteed
     */
    function getSupportedCollaterals() external view returns (address[] memory);

    /**
     * @dev Get system minimum collateral ratio
     * @return uint256 Minimum collateral ratio required by the system
     */
    function getMinimumCollateralRatio() external view returns (uint256);

    /**
     * @dev Get SF token contract address
     * @return address Address of the SF token contract
     */
    function getSFTokenAddress() external view returns (address);
}
