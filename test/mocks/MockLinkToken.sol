// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

import {IERC677Receiver} from "@chainlink/contracts/src/v0.8/shared/interfaces/IERC677Receiver.sol";
import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";

contract MockLinkToken is ERC20 {
    
    uint256 private constant TOTAL_SUPPLY = 1_000_000_000 * 1e18;

    constructor() ERC20("LINK", "LINK") {
        _mint(msg.sender, TOTAL_SUPPLY);
    }

    function transferAndCall(
        address _to,
        uint256 _value,
        bytes calldata _data
    ) public returns (bool success) {
        transfer(_to, _value);
        if (isContract(_to)) {
            contractFallback(_to, _value, _data);
        }
        return true;
    }

    function isContract(address _addr) private view returns (bool hasCode) {
        uint256 length;
        assembly {
            length := extcodesize(_addr)
        }
        return length > 0;
    }

    function contractFallback(
        address _to,
        uint256 _value,
        bytes calldata _data
    ) private {
        IERC677Receiver receiver = IERC677Receiver(_to);
        receiver.onTokenTransfer(msg.sender, _value, _data);
    }
}
