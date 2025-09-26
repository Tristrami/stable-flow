// SPDX-License-Identifier: MIT
pragma solidity ^0.8.30;

import {ISocialRecoveryPlugin} from "./ISocialRecoveryPlugin.sol";
import {IVaultPlugin} from "./IVaultPlugin.sol";
import {IERC165} from "@openzeppelin/contracts/utils/introspection/IERC165.sol";

interface ISFAccount is ISocialRecoveryPlugin, IVaultPlugin, IERC165 {

    function getOwner() external view returns (address);

    function debt() external view returns (uint256);

    function balance() external view returns (uint256);

    function transfer(address to, uint256 amount) external;

    function freeze() external;

    function unfreeze() external;

    function isFrozen() external view returns (bool);
}