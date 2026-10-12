// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";

/// @notice Test token that calls back into a target during transfer and transferFrom.
contract ReenteringToken is ERC20 {
    address public target;
    bytes public payload;
    bool public armed;
    bool public innerSucceeded;
    bytes4 public innerSelector;

    constructor() ERC20("Reentering Token", "REENT") {}

    function mint(address to, uint256 amount) external {
        _mint(to, amount);
    }

    function arm(address target_, bytes calldata payload_) external {
        target = target_;
        payload = payload_;
        armed = true;
        innerSucceeded = false;
        innerSelector = bytes4(0);
    }

    function transfer(address to, uint256 value) public override returns (bool) {
        _reenter();
        return super.transfer(to, value);
    }

    function transferFrom(address from, address to, uint256 value) public override returns (bool) {
        _reenter();
        return super.transferFrom(from, to, value);
    }

    function _reenter() internal {
        if (!armed) return;
        armed = false;
        (bool ok, bytes memory ret) = target.call(payload);
        innerSucceeded = ok;
        if (ret.length >= 4) {
            innerSelector = bytes4(ret);
        }
    }
}
