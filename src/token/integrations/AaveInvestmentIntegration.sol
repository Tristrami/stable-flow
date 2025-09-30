// SPDX-License-Identifier: MIT
pragma solidity ^0.8.30;

import {ISFEngine} from "../../interfaces/ISFEngine.sol";
import {IPool} from "@aave/contracts/interfaces/IPool.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {EnumerableMap} from "@openzeppelin/contracts/utils/structs/EnumerableMap.sol";

/**
 * @title AaveInvestmentIntegration
 * @notice A secure library for integrating with Aave Protocol's lending pool
 * @dev Provides investment and withdrawal functions with built-in safety checks
 */
library AaveInvestmentIntegration {

    using EnumerableMap for EnumerableMap.AddressToUintMap;

    error AaveInvestmentIntegration__InvalidAsset();
    error AaveInvestmentIntegration__InvalidAssetAmount();
    error AaveInvestmentIntegration__InsufficientBalance(address asset, uint256 amountToInvest, uint256 amountRequired);
    error AaveInvestmentIntegration__AmountToWithdrawExceedsBalance(address asset, uint256 amountInvested, uint256 balance);

    event AaveInvestmentIntegration__Supply(address asset, uint256 amount);
    event AaveInvestmentIntegration__Withdraw(address asset, uint256 amount, uint256 interest);

    /**
     * @notice Tracks investment positions per SFEngine instance
     * @dev Uses EnumerableMap for efficient asset tracking
     */
    struct Investment {
        /// @dev Address of the parent SFEngine contract
        address sfEngineAddress;
        /// @dev Aave Pool contract address
        address poolAddress;
        /// @dev Mapping of asset addresses to invested amounts
        EnumerableMap.AddressToUintMap investedAssets;
    }

    /**
     * @notice Deposits assets into Aave protocol
     * @dev Performs safety checks before interacting with Aave
     * @param investment Storage reference to Investment struct
     * @param asset Address of the asset to invest
     * @param amount Amount to invest (in asset decimals)
     */
    function invest(Investment storage investment, address asset, uint256 amount) internal {
        _checkAsset(asset, amount);
        uint256 balance = IERC20(asset).balanceOf(investment.sfEngineAddress);
        if (balance < amount) {
            revert AaveInvestmentIntegration__InsufficientBalance(asset, balance, amount);
        }
        (, uint256 amountInvested) = investment.investedAssets.tryGet(asset);
        investment.investedAssets.set(asset, amountInvested + amount);
        IERC20(asset).approve(investment.poolAddress, amount);
        IPool(investment.poolAddress).supply(asset, amount, address(this), 0);
        emit AaveInvestmentIntegration__Supply(asset, amount);
    }

    /**
     * @notice Withdraws assets from Aave protocol
     * @dev Handles partial/full withdrawals and interest calculation
     * @param investment Storage reference to Investment struct
     * @param asset Address of the asset to withdraw
     * @param amount Amount to withdraw (type(uint256).max for full withdrawal)
     * @return amountWithdrawn Actual principal amount withdrawn
     * @return interest Accrued interest included in withdrawal
     */
    function withdraw(
        Investment storage investment, 
        address asset, 
        uint256 amount
    ) internal returns (
        uint256 amountWithdrawn,
        uint256 interest
    ) {
        _checkAsset(asset, amount);
        (, uint256 amountInvested) = investment.investedAssets.tryGet(asset);
        uint256 actualAmountToWithdraw = amount;
        if (actualAmountToWithdraw > amountInvested) {
            if (actualAmountToWithdraw == type(uint256).max) {
                actualAmountToWithdraw = amountInvested;
            } else {
                revert AaveInvestmentIntegration__AmountToWithdrawExceedsBalance(asset, amountInvested, amount);
            }
        }
        uint256 remainingAssets = amountInvested - actualAmountToWithdraw;
        if (remainingAssets == 0) {
            investment.investedAssets.remove(asset);
        } else {
            investment.investedAssets.set(asset, remainingAssets);
        }
        amountWithdrawn = IPool(investment.poolAddress).withdraw(asset, amount, address(this));
        interest = amountWithdrawn - actualAmountToWithdraw;
        emit AaveInvestmentIntegration__Withdraw(asset, amountWithdrawn, interest);
    }

    /**
     * @notice Internal validation for asset parameters
     * @dev Reverts if asset is address(0) or amount is zero
     * @param asset Asset address to validate
     * @param amount Amount to validate
     */
    function _checkAsset(address asset, uint256 amount) private pure {
        if (asset == address(0)) {
            revert AaveInvestmentIntegration__InvalidAsset();
        }
        if (amount == 0) {
            revert AaveInvestmentIntegration__InvalidAssetAmount();
        }
    }
}