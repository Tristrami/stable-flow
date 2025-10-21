// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {SFToken} from "./SFToken.sol";
import {TokenPool} from "@chainlink/contracts/src/v0.8/ccip/pools/TokenPool.sol";
import {Pool} from "@chainlink/contracts/src/v0.8/ccip/libraries/Pool.sol";
import {IERC20} from "@chainlink/contracts/src/v0.8/vendor/openzeppelin-solidity/v4.8.3/contracts/token/ERC20/IERC20.sol";

/**
 * @title SFTokenPool
 * @dev Chainlink CCIP-compatible token pool for SFToken cross-chain transfers
 * @notice Handles locking/burning on source chain and minting/releasing on destination chain
 */
contract SFTokenPool is TokenPool {

    /**
     * @dev Error thrown when token transfer fails
     * @notice Used for failed ERC20 transfer operations
     */
    error SFTokenPool__TransferFailed();

    /**
     * @dev Error thrown when release amount exceeds locked balance
     * @param amountToRelease Requested release amount
     * @param amountLocked Currently locked token balance
     * @notice Prevents over-release of tokens
     */
    error SFTokenPool__ReleaseAmountExceedsLocked(uint256 amountToRelease, uint256 amountLocked);

    /**
     * @dev Error thrown when insufficient SFToken balance exists
     * @param balance Current token balance
     * @param amountRequired Requested token amount
     * @notice Ensures adequate liquidity for operations
     */
    error SFTokenPool__InsufficientSF(uint256 balance, uint256 amountRequired);

    /**
     * @dev Emitted when tokens are locked in the pool
     * @param user Address initiating the lock (indexed)
     * @param amount Token amount locked (indexed)
     */
    event SFTokenPool__Lock(address indexed user, uint256 indexed amount);

    /**
     * @dev Emitted when tokens are released from the pool
     * @param user Address receiving the release (indexed)
     * @param amount Token amount released (indexed)
     */
    event SFTokenPool__Release(address indexed user, uint256 indexed amount);

    /// @dev Immutable main chain identifier
    uint256 private immutable i_mainChainId;
    /// @dev Immutable SFToken contract reference
    SFToken private immutable i_sfToken;

    /**
     * @dev Initializes the token pool
     * @param mainChainId Chain ID of the main network
     * @param sfToken SFToken contract address
     * @param allowList Array of permitted caller addresses
     * @param rmnProxy RMN proxy contract address
     * @param router CCIP router address
     */
    constructor(
        uint256 mainChainId,
        SFToken sfToken,
        address[] memory allowList,
        address rmnProxy,
        address router
    ) TokenPool(
        IERC20(address(sfToken)),
        allowList,
        rmnProxy,
        router
    ) {
        i_mainChainId = mainChainId;
        i_sfToken = sfToken;
    }

    /**
     * @dev Locks or burns tokens based on chain context
     * @param lockOrBurnIn Input parameters for lock/burn operation
     * @return lockOrBurnOut Output parameters including destination token info
     * @notice On main chain: locks tokens, On other chains: burns tokens
     * Emits SFTokenPool__Lock event when locking on main chain
     */
    function lockOrBurn(
        Pool.LockOrBurnInV1 calldata lockOrBurnIn
    ) external override returns (Pool.LockOrBurnOutV1 memory lockOrBurnOut) {
        _validateLockOrBurn(lockOrBurnIn);
        address sender = lockOrBurnIn.originalSender;
        uint256 amount = lockOrBurnIn.amount;
        
        if (block.chainid == i_mainChainId) {
            emit SFTokenPool__Lock(sender, amount);
        } else {
            i_sfToken.burn(address(this), amount);
        }
        
        lockOrBurnOut = Pool.LockOrBurnOutV1({
            destTokenAddress: getRemoteToken(lockOrBurnIn.remoteChainSelector),
            destPoolData: ""
        });
        return lockOrBurnOut;
    }

    /**
     * @dev Releases or mints tokens based on chain context
     * @param releaseOrMintIn Input parameters for release/mint operation
     * @return ReleaseOrMintOutV1 Output parameters including destination amount
     * @notice On main chain: releases tokens, On other chains: mints tokens
     * Emits SFTokenPool__Release event when releasing on main chain
     * Reverts with SFTokenPool__InsufficientSF if balance is inadequate
     */
    function releaseOrMint(
        Pool.ReleaseOrMintInV1 calldata releaseOrMintIn
    ) external override returns (Pool.ReleaseOrMintOutV1 memory) {
        _validateReleaseOrMint(releaseOrMintIn);
        address receiver = releaseOrMintIn.receiver;
        uint256 amount = releaseOrMintIn.amount;
        
        if (block.chainid == i_mainChainId) {
            uint256 sfBalance = i_sfToken.balanceOf(address(this));
            if (sfBalance < amount) {
                revert SFTokenPool__InsufficientSF(sfBalance, amount);
            }
            emit SFTokenPool__Release(receiver, amount);
            i_sfToken.transfer(receiver, amount);
        } else {
            i_sfToken.mint(receiver, amount);
        }
        
        return Pool.ReleaseOrMintOutV1({
            destinationAmount: amount
        });
    }
}