// SPDX-License-Identifier: MIT
pragma solidity ^0.8.30;

import {ISFEngine} from "./interfaces/ISFEngine.sol";
import {SFToken} from "./SFToken.sol";
import {Validator} from "./Validator.sol";
import {IERC20} from "@openzeppelin/contracts/token/erc20/IERC20.sol";
import {EnumerableSet} from "@openzeppelin/contracts/utils/structs/EnumerableSet.sol";
import {OracleLib, AggregatorV3Interface} from "./libraries/OracleLib.sol";
import {UUPSUpgradeable} from "@openzeppelin/contracts-upgradeable/proxy/utils/UUPSUpgradeable.sol";
import {OwnableUpgradeable} from "@openzeppelin/contracts-upgradeable/access/OwnableUpgradeable.sol";

contract SFEngine is ISFEngine, Validator, UUPSUpgradeable, OwnableUpgradeable {

    /* -------------------------------------------------------------------------- */
    /*                                  Constants                                 */
    /* -------------------------------------------------------------------------- */

    /// @dev The precision of number when calculating
    uint256 private constant PRECISION = 18;
    /// @dev THe precision factor used when calculating
    uint256 private constant PRECISION_FACTOR = 1e18;
    /// @dev 200% collateral ratio, eg. 10$ sf => 20$ collateral token
    uint256 private constant MINIMUM_COLLATERAL_RATIO = 2 * PRECISION_FACTOR;

    /* -------------------------------------------------------------------------- */
    /*                              State Variables                               */
    /* -------------------------------------------------------------------------- */

    SFToken private s_sfToken;
    EnumerableSet.AddressSet private s_supportedTokenAddressSet;
    mapping(address user => mapping(address tokenAddress => uint256 value)) private s_collaterals;
    mapping(address tokenAddress => address priceFeedAddress) private s_priceFeeds;
    mapping(address user => uint256 sfTokenMinted) private s_sfTokenMinted;

    /* -------------------------------------------------------------------------- */
    /*                                  Libraries                                 */
    /* -------------------------------------------------------------------------- */

    using EnumerableSet for EnumerableSet.AddressSet;
    using OracleLib for AggregatorV3Interface;

    /* -------------------------------------------------------------------------- */
    /*                                   Events                                   */
    /* -------------------------------------------------------------------------- */

    event SFEngine__CollateralDeposited(
        address indexed user, address indexed collateralTokenAddress, uint256 indexed amountCollateral
    );
    event SFEngine__CollateralRedeemed(
        address indexed user, address indexed collateralTokenAddress, uint256 indexed amountCollateral
    );
    event SFEngine__SFTokenMinted(address indexed user, uint256 indexed amountToken);

    /* -------------------------------------------------------------------------- */
    /*                                   Errors                                   */
    /* -------------------------------------------------------------------------- */

    error SFEngine__TokenAddressAndPriceFeedLengthNotMatch();
    error SFEngine__TokenNotSupported();
    error SFEngine__AmountToRedeemExceedsDeposited(uint256 amountDeposited);
    error SFEngine__DebtToCoverExceedsCollateralDeposited(uint256 amountDeposited);
    error SFEngine__TransferFailed();
    error SFEngine__InsufficientBalance(uint256 balance);
    error SFEngine__SFToBurnExceedsUserDebt(uint256 userDebt);
    error SFEngine__CollateralRatioIsBroken(address user, uint256 collateralRatio);
    error SFEngine__CollateralRatioIsNotBroken(address user, uint256 collateralRatio);

    /* -------------------------------------------------------------------------- */
    /*                                  Modifiers                                 */
    /* -------------------------------------------------------------------------- */

    modifier onlySupportedToken(address tokenAddress) {
        if (s_priceFeeds[tokenAddress] == address(0)) {
            revert SFEngine__TokenNotSupported();
        }
        _;
    }

    /* -------------------------------------------------------------------------- */
    /*                                 Initializer                                */
    /* -------------------------------------------------------------------------- */

    function initialize(
        address sfTokenAddress, 
        address[] memory tokenAddresses, 
        address[] memory priceFeedAddresses
    ) external initializer {
        s_sfToken = SFToken(sfTokenAddress);
        _initializePriceFeeds(tokenAddresses, priceFeedAddresses);
        __UUPSUpgradeable_init();
        __Ownable_init(msg.sender);
    }

    /* -------------------------------------------------------------------------- */
    /*                         External / Public Functions                        */
    /* -------------------------------------------------------------------------- */

    function depositCollateralAndMintSFToken(
        address collateralTokenAddress,
        uint256 amountCollateral,
        uint256 amountSFToMint
    )
        external
        notZeroAddress(collateralTokenAddress)
        notZeroValue(amountCollateral)
        notZeroValue(amountSFToMint)
        onlySupportedToken(collateralTokenAddress)
    {
        _depositCollateral(collateralTokenAddress, amountCollateral);
        _mintSFToken(amountSFToMint);
    }

    function redeemCollateral(
        address collateralTokenAddress,
        uint256 amountCollateralToRedeem,
        uint256 amountSFToBurn
    )
        public
        notZeroAddress(collateralTokenAddress)
        notZeroValue(amountCollateralToRedeem)
        onlySupportedToken(collateralTokenAddress)
    {
        _burnSFToken(msg.sender, msg.sender, amountSFToBurn, amountSFToBurn);
        _redeemCollateral(collateralTokenAddress, amountCollateralToRedeem, msg.sender, msg.sender);
        _revertIfCollateralRatioIsBroken(msg.sender);
    }

    function liquidate(address user, address collateralTokenAddress, uint256 debtToCover)
        external
        notZeroAddress(collateralTokenAddress)
        notZeroValue(debtToCover)
        onlySupportedToken(collateralTokenAddress)
    {
        _revertIfCollateralRatioIsNotBroken(user);
        uint256 liquidatorBalance = s_sfToken.balanceOf(msg.sender);
        if (debtToCover > liquidatorBalance) {
            debtToCover = liquidatorBalance;
        }
        uint256 amountCollateralToLiquidate = _getTokenAmountFromUsd(collateralTokenAddress, debtToCover);
        uint256 amountDeposited = s_collaterals[user][collateralTokenAddress];
        if (amountCollateralToLiquidate > amountDeposited) {
            amountCollateralToLiquidate = amountDeposited;
        }
        uint256 amountSFToBurn = debtToCover;
        // Give 10% bonus to liquidator
        uint256 bonus = amountCollateralToLiquidate * (10 ** (PRECISION - 1)) / PRECISION_FACTOR;
        uint256 maxAmountToLiquidate = amountCollateralToLiquidate + bonus;
        if (maxAmountToLiquidate > amountDeposited) {
            // If the collateral is not enough to cover the debt and bonus,
            // give all the collateral to liquidator, and subtract the bonus
            // on amount of sf token to burn
            amountCollateralToLiquidate = amountDeposited;
            uint256 bonusInSFToken = _getTokenValueInUsd(collateralTokenAddress, bonus);
            amountSFToBurn -= bonusInSFToken;
        } else {
            amountCollateralToLiquidate += bonus;
        }
        _burnSFToken(msg.sender, user, amountSFToBurn, debtToCover);
        _redeemCollateral(collateralTokenAddress, amountCollateralToLiquidate, user, msg.sender);
        _revertIfCollateralRatioIsBroken(user);
        _revertIfCollateralRatioIsBroken(msg.sender);
    }

    function getCollateralRatio(address user) public view returns (uint256) {
        uint256 sfMinted = s_sfTokenMinted[user];
        if (sfMinted == 0) {
            return type(uint256).max;
        }
        uint256 totalCollateralValueInUsd;
        for (uint256 i = 0; i < s_supportedTokenAddressSet.length(); i++) {
            address tokenAddress = s_supportedTokenAddressSet.at(i);
            uint256 amountCollateral = s_collaterals[user][tokenAddress];
            totalCollateralValueInUsd += _getTokenValueInUsd(tokenAddress, amountCollateral);
        }
        return totalCollateralValueInUsd * PRECISION_FACTOR / sfMinted;
    }

    /* -------------------------------------------------------------------------- */
    /*                              Private Functions                             */
    /* -------------------------------------------------------------------------- */

    function _initializePriceFeeds(address[] memory tokenAddresses, address[] memory priceFeedAddresses) private {
        if (tokenAddresses.length != priceFeedAddresses.length) {
            revert SFEngine__TokenAddressAndPriceFeedLengthNotMatch();
        }
        for (uint256 i = 0; i < tokenAddresses.length; i++) {
            s_supportedTokenAddressSet.add(tokenAddresses[i]);
            s_priceFeeds[tokenAddresses[i]] = priceFeedAddresses[i];
        }
    }

    /**
     * @dev Deposit collateral token
     * @param collateralTokenAddress The address of collateral token contract
     * @param amountCollateral The amount of collateral token
     */
    function _depositCollateral(address collateralTokenAddress, uint256 amountCollateral) private {
        s_collaterals[msg.sender][collateralTokenAddress] += amountCollateral;
        emit SFEngine__CollateralDeposited(msg.sender, collateralTokenAddress, amountCollateral);
        bool success = IERC20(collateralTokenAddress).transferFrom(msg.sender, address(this), amountCollateral);
        if (!success) {
            revert SFEngine__TransferFailed();
        }
    }

    /**
     * @dev Mint SF token
     * @param amount Amount of token you want to mint, 18 decimals
     */
    function _mintSFToken(uint256 amount) private {
        s_sfTokenMinted[msg.sender] += amount;
        _revertIfCollateralRatioIsBroken(msg.sender);
        emit SFEngine__SFTokenMinted(msg.sender, amount);
        s_sfToken.mint(msg.sender, amount);
    }

    /**
     * @dev Get token value in usd
     * @param tokenAddress The contract address of token
     * @param amountToken The amount of token, 18 decimals
     * @notice The returning usd value has 18 decimals
     */
    function _getTokenValueInUsd(address tokenAddress, uint256 amountToken)
        private
        view
        onlySupportedToken(tokenAddress)
        returns (uint256)
    {
        return amountToken * _getTokenUsdPrice(tokenAddress) / PRECISION_FACTOR;
    }

    /**
     * @dev Get the amount of token from usd
     * @param tokenAddress The contract address of token address
     * @param amountUsd The amount of usd，18 decimals，100$ => 100e18
     */
    function _getTokenAmountFromUsd(address tokenAddress, uint256 amountUsd)
        private
        view
        onlySupportedToken(tokenAddress)
        returns (uint256)
    {
        return (amountUsd * PRECISION_FACTOR) / _getTokenUsdPrice(tokenAddress);
    }

    /**
     * @dev Get the usd price of token
     * @param tokenAddress The contract address of token
     * @notice The returning usd price has 18 decimals
     */
    function _getTokenUsdPrice(address tokenAddress) private view onlySupportedToken(tokenAddress) returns (uint256) {
        AggregatorV3Interface priceFeed = AggregatorV3Interface(s_priceFeeds[tokenAddress]);
        // Normally 8 decimals
        (, int256 answer,,,) = priceFeed.getStaleCheckedLatestRoundData();
        // token / usd price，18 decimals
        return uint256(answer) * 10 ** (PRECISION - priceFeed.decimals());
    }

    /**
     * @dev Burn sf token
     * @param from The account where the sf token comes from
     * @param onBehalfOf The account of which you want to be on behalf of
     * @param amountToBurn Amount of token to burn
     * @param debtToCover Amount of debt to cover
     */
    function _burnSFToken(address from, address onBehalfOf, uint256 amountToBurn, uint256 debtToCover)
        private
        notZeroAddress(from)
        notZeroValue(amountToBurn)
        notZeroValue(debtToCover)
    {
        uint256 balance = s_sfToken.balanceOf(from);
        if (balance < amountToBurn) {
            revert SFEngine__InsufficientBalance(balance);
        }
        uint256 userSFMinted = s_sfTokenMinted[onBehalfOf];
        if (userSFMinted < debtToCover) {
            revert SFEngine__SFToBurnExceedsUserDebt(userSFMinted);
        }
        s_sfTokenMinted[onBehalfOf] -= debtToCover;
        bool success = s_sfToken.transferFrom(from, address(this), amountToBurn);
        if (!success) {
            revert SFEngine__TransferFailed();
        }
        s_sfToken.burn(address(this), amountToBurn);
    }

    /**
     * @dev Redeem collateral
     * @param collateralTokenAddress The address of collateral token contract
     * @param amountCollateralToRedeem The amount of collateral to redeem, 18 decimals
     * @param collateralFrom The account address where the collateral token comes from
     * @param collateralTo The account address where the collateral token will be transfer to
     */
    function _redeemCollateral(
        address collateralTokenAddress,
        uint256 amountCollateralToRedeem,
        address collateralFrom,
        address collateralTo
    ) private {
        uint256 collateralDeposited = s_collaterals[collateralFrom][collateralTokenAddress];
        if (collateralDeposited < amountCollateralToRedeem) {
            revert SFEngine__AmountToRedeemExceedsDeposited(collateralDeposited);
        }
        s_collaterals[collateralFrom][collateralTokenAddress] -= amountCollateralToRedeem;
        emit SFEngine__CollateralRedeemed(collateralFrom, collateralTokenAddress, amountCollateralToRedeem);
        bool success = IERC20(collateralTokenAddress).transfer(collateralTo, amountCollateralToRedeem);
        if (!success) {
            revert SFEngine__TransferFailed();
        }
    }

    /**
     * Revert if collateral ratio is less than MINIMUM_COLLATERAL_RATIO
     * @param user The account address
     */
    function _revertIfCollateralRatioIsBroken(address user) private view {
        (bool isBroken, uint256 collateralRatio) = _checkCollateralRatio(user);
        if (isBroken) {
            revert SFEngine__CollateralRatioIsBroken(user, collateralRatio);
        }
    }

    /**
     * Revert if collateral ratio is more than or equal to MINIMUM_COLLATERAL_RATIO
     * @param user The account address
     */
    function _revertIfCollateralRatioIsNotBroken(address user) private view {
        (bool isBroken, uint256 collateralRatio) = _checkCollateralRatio(user);
        if (!isBroken) {
            revert SFEngine__CollateralRatioIsNotBroken(user, collateralRatio);
        }
    }

    function _checkCollateralRatio(address user) public view returns (bool isBroken, uint256 collateralRatio) {
        collateralRatio = getCollateralRatio(user);
        isBroken = collateralRatio < MINIMUM_COLLATERAL_RATIO;
        return (isBroken, collateralRatio);
    }

    /* -------------------------------------------------------------------------- */
    /*                        Overridden Internal Functions                       */
    /* -------------------------------------------------------------------------- */
    
    function _authorizeUpgrade(address newImplementation) internal override onlyOwner {

    }

    /* -------------------------------------------------------------------------- */
    /*                           Getter / View Functions                          */
    /* -------------------------------------------------------------------------- */

    function getMinimumCollateralRatio() public pure returns (uint256) {
        return MINIMUM_COLLATERAL_RATIO;
    }

    function getCollateralAmount(address user, address collateralTokenAddress) public view returns (uint256) {
        return s_collaterals[user][collateralTokenAddress];
    }

    function getSFTokenMinted(address user) public view returns (uint256) {
        return s_sfTokenMinted[user];
    }

    function getSFTokenAddress() public view returns (address) {
        return address(s_sfToken);
    }

    function getCollateralTokenAddresses() public view returns (address[] memory) {
        return s_supportedTokenAddressSet.values();
    }

    function getTokenUsdPrice(address tokenAddress) external view returns (uint256) {
        return _getTokenUsdPrice(tokenAddress);
    }

    function getTokenValueInUsd(address tokenAddress, uint256 amountToken) external view returns (uint256) {
        return _getTokenValueInUsd(tokenAddress, amountToken);
    }

    function getTokenAmountFromUsd(address tokenAddress, uint256 amountUsd)
        external
        view
        returns (uint256 tokenValue)
    {
        return _getTokenAmountFromUsd(tokenAddress, amountUsd);
    }
}