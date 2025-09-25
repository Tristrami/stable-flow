// SPDX-License-Identifier: MIT
pragma solidity ^0.8.30;

import {ISocialRecoveryPlugin} from "./ISocialRecoveryPlugin.sol";
import {IVaultPlugin} from "./IVaultPlugin.sol";

interface ISFAccount is ISocialRecoveryPlugin, IVaultPlugin {

    function getOwner() external view returns (address);

    function debt() external view returns (uint256);

    function balance() external view returns (uint256);

    function transfer(address to, uint256 amount) external;

    function freeze() external;

    function unfreeze() external;

    function isFrozen() external view returns (bool);
}