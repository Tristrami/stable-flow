// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {SFToken} from "./SFToken.sol";
import {TokenPool} from "@chainlink/contracts/src/v0.8/ccip/pools/TokenPool.sol";
import {Pool} from "@chainlink/contracts/src/v0.8/ccip/libraries/Pool.sol";
import {IERC20} from "@chainlink/contracts/src/v0.8/vendor/openzeppelin-solidity/v4.8.3/contracts/token/ERC20/IERC20.sol";

contract SFTokenPool is TokenPool {

    error SFTokenPool__TransferFailed();
    error SFTokenPool__ReleaseAmountExceedsLocked(uint256 amountToRelease, uint256 amountLocked);
    error SFTokenPool__InsufficientRN(uint256 balance, uint256 amountRequired);
    
    event SFTokenPool__Lock(address indexed user, uint256 indexed amount);
    event SFTokenPool__Release(address indexed user, uint256 indexed amount);

    uint256 private immutable i_mainChainId;
    SFToken private immutable i_sfToken;

    constructor(
        uint256 mainChainId,
        SFToken sfToken,
        address[] memory allowList,
        address rmnProxy,
        address router
    ) TokenPool (
        IERC20(address(sfToken)),
        allowList,
        rmnProxy,
        router
    ) {
        i_mainChainId = mainChainId;
        i_sfToken = sfToken;
    }

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

    function releaseOrMint(
        Pool.ReleaseOrMintInV1 calldata releaseOrMintIn
    ) external override returns (Pool.ReleaseOrMintOutV1 memory) {
        _validateReleaseOrMint(releaseOrMintIn);
        address receiver = releaseOrMintIn.receiver;
        uint256 amount = releaseOrMintIn.amount;
        if (block.chainid == i_mainChainId) {
            uint256 rnBalance = i_sfToken.balanceOf(address(this));
            if (rnBalance < amount) {
                revert SFTokenPool__InsufficientRN(rnBalance, amount);
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