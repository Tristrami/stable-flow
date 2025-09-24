// SPDX-License-Identifier: MIT
pragma solidity ^0.8.30;

import {IRecoverable} from "./IRecoverable.sol";
import {IVault} from "./IVault.sol";

interface ISFAccount is IRecoverable, IVault {

    function balance() external view returns (uint256);

    function transfer(address to, uint256 amount) external;

    function freeze() external;

    function unfreeze() external;

    function isFrozen() external view returns (bool);
}