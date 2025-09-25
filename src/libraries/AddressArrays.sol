// SPDX-License-Identifier: MIT
pragma solidity ^0.8.30;

library AddressArrays {

    function contains(address[] memory array, address element) internal pure returns (bool) {
        for (uint256 i = 0; i < array.length; i++) {
            if (array[i] == element) {
                return true;
            }
        }
        return false;
    }
}