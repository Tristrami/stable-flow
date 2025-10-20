// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

/**
 * @title ISFEngine Interface
 * @dev Core interface for the SFEngine contract defining all external-facing functions
 */
interface ISFEngine {

    /* -------------------------------------------------------------------------- */
    /*                                   Errors                                   */
    /* -------------------------------------------------------------------------- */

    /**
     * @dev Reverts when zero address is provided as user address
     */
    error ISFEngine__UserAddressCanNotBeZero();

    /**
     * @dev Reverts when zero address is provided as collateral address
     */
    error ISFEngine__CollateralAddressCanNotBeZero();

    /**
     * @dev Reverts when attempting to deposit zero collateral amount
     * @notice Users must deposit a positive amount of collateral
     */
    error ISFEngine__AmountCollateralToDepositCanNotBeZero();

    /**
     * @dev Reverts when attempting to burn zero SF tokens
     */
    error ISFEngine__AmountSFToBurnCanNotBeZero();

    /**
     * @dev Reverts when attempting to cover zero debt amount
     */
    error ISFEngine__DebtToCoverCanNotBeZero();

    /**
     * @dev Reverts when token addresses and price feeds arrays have different lengths
     * @notice Configuration must provide matching data pairs
     */
    error ISFEngine__TokenAddressAndPriceFeedLengthNotMatch();

    /**
     * @dev Reverts when operation is attempted with unsupported collateral
     * @notice Only approved collateral assets can be used
     */
    error ISFEngine__CollateralNotSupported();

    /**
     * @dev Reverts when redemption amount exceeds deposited collateral
     * @param amountToRedeem The amount of collateral to redeem
     * @param amountDeposited The actual amount of collateral deposited
     * @notice Users cannot redeem more collateral than they've deposited
     */
    error ISFEngine__AmountToRedeemExceedsDeposited(uint256 amountToRedeem, uint256 amountDeposited);

    /**
     * @dev Reverts when debt to cover exceeds deposited collateral
     * @param amountDeposited The actual amount of collateral deposited
     */
    error ISFEngine__DebtToCoverExceedsCollateralDeposited(uint256 amountDeposited);

    /**
     * @dev Reverts when ERC20 transfer operation fails
     * @notice Indicates a problem with token transfer execution
     */
    error ISFEngine__TransferFailed();

    /**
     * @dev Reverts when operation requires more balance than available
     * @param balance The actual available balance
     */
    error ISFEngine__InsufficientBalance(uint256 balance);

    /**
     * @dev Reverts when debt to cover exceeds burnable SF tokens
     * @param userDebt The user's current debt amount
     * @param amountToBurn The requested burn amount
     */
    error ISFEngine__DebtToCoverExceedsSFToBurn(uint256 userDebt, uint256 amountToBurn);

    /**
     * @dev Reverts when debt to cover exceeds user's actual debt
     * @param debtToCover The requested coverage amount
     * @param userDebt The user's current debt amount
     */
    error ISFEngine__DebtToCoverExceedsUserDebt(uint256 debtToCover, uint256 userDebt);

    /**
     * @dev Reverts when collateral ratio falls below minimum threshold
     * @param user The address with undercollateralized position
     * @param collateralRatio The current collateral ratio
     * @notice Positions must maintain minimum collateralization
     */
    error ISFEngine__CollateralRatioIsBroken(address user, uint256 collateralRatio);

    /**
     * @dev Reverts when operation requires broken collateral ratio but position is healthy
     * @param user The address being checked
     * @param collateralRatio The current healthy collateral ratio
     */
    error ISFEngine__CollateralRatioIsNotBroken(address user, uint256 collateralRatio);

    /**
     * @dev Reverts when detecting incompatible contract implementation
     */
    error ISFEngine__IncompatibleImplementation();

    /* -------------------------------------------------------------------------- */
    /*                                   Events                                   */
    /* -------------------------------------------------------------------------- */

    /**
     * @dev Emitted when collateral is deposited
     * @param user The address that deposited collateral
     * @param collateralAddress The token address of deposited collateral
     * @param amountCollateral The amount deposited (in token decimals)
     * @notice Track all collateral deposits to the protocol
     */
    event ISFEngine__CollateralDeposited(
        address indexed user, 
        address indexed collateralAddress, 
        uint256 indexed amountCollateral
    );

    /**
     * @dev Emitted when collateral is redeemed
     * @param user The address that redeemed collateral
     * @param collateralAddress The token address of redeemed collateral
     * @param amountCollateral The amount redeemed (in token decimals)
     */
    event ISFEngine__CollateralRedeemed(
        address indexed user, 
        address indexed collateralAddress, 
        uint256 indexed amountCollateral
    );

    /**
     * @dev Emitted when new SF tokens are minted
     * @param user The address receiving minted tokens
     * @param amountToken The amount minted (18 decimals)
     * @notice Tracks all SF token creation
     */
    event ISFEngine__SFTokenMinted(
        address indexed user, 
        uint256 indexed amountToken
    );

    /**
     * @dev Emitted when investment ratio is updated
     * @param investmentRatio The new ratio in RAY units (1e27 = 100%)
     */
    event ISFEngine__UpdateInvestmentRatio(
        uint256 investmentRatio
    );

    /**
     * @dev Emitted when yield is harvested from external protocols
     * @param asset The address of the yield-bearing asset
     * @param amount The principal amount harvested
     * @param interest The yield earned (in asset decimals)
     * @notice Shows protocol earnings from yield strategies
     */
    event ISFEngine__Harvest(
        address indexed asset, 
        uint256 indexed amount, 
        uint256 indexed interest
    );
    
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
     *   - With ISFEngine__CollateralAddressCanNotBeZero if collateralAddress is zero
     *   - With ISFEngine__AmountCollateralToDepositCanNotBeZero for zero deposits
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
     * @dev Liquidates an undercollateralized position
     * @dev Allows liquidators to cover debt in exchange for collateral + bonus
     * @notice When the calculated bonus (amountCollateralToLiquidate + bonus) would exceed 
    *          the user's deposited collateral amount:
    *          1. Caps the liquidatable collateral at total deposited amount
    *          2. Calculates the remaining bonus that couldn't be paid in collateral
    *          3. Converts the unpaid bonus to equivalent SF token value
    *          4. Subtract actual amount to burn by bonus in SF token value
    *          
    *          This ensures:
    *          - Never attempts to transfer more collateral than exists
    *          - Liquidator still receives full promised value (in SF tokens if needed)
    *          - Protocol maintains accurate accounting
    *
     * @param user Address of the undercollateralized position
     * @param collateralAddress Collateral token to liquidate
     * @param debtToCover Amount of debt to cover (type(uint256).max for full debt)
     * @return actualAmountReceived Actual amount of collateral the liquidator receives
     * @custom:reverts ISFEngine__UserAddressCanNotBeZero If user address is zero
     * @custom:reverts ISFEngine__CollateralAddressCanNotBeZero If collateral address is zero
     * @custom:reverts ISFEngine__DebtToCoverCanNotBeZero If debtToCover is zero
     * @custom:reverts ISFEngine__InsufficientBalance If liquidator lacks sufficient SF tokens
     * @custom:reverts ISFEngine__CollateralRatioIsNotBroken If position is still healthy
     */
    function liquidate(address user, address collateralAddress, uint256 debtToCover) external returns (uint256);

    /**
     * @dev Returns the current bonus rate for liquidations
     * @dev The bonus rate determines the additional collateral percentage awarded to liquidators
     * @return uint256 The current bonus rate in RAY units (1e27 = 100%)
     */
    function getBonusRate() external view returns (uint256);

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
