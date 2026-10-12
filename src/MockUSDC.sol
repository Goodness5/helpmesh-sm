// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Context} from "@openzeppelin/contracts/utils/Context.sol";
import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {ERC20Permit} from "@openzeppelin/contracts/token/ERC20/extensions/ERC20Permit.sol";
import {ERC2771Context} from "@openzeppelin/contracts/metatx/ERC2771Context.sol";

/// @notice Test stablecoin. This is not a dollar and has no redeemability.
/// @dev 6 decimals, ERC-2612 permit, and a public faucet of 100 tokens per address per day.
contract MockUSDC is ERC20Permit, ERC2771Context {
    uint256 public constant FAUCET_DRIP = 100e6;
    uint256 public constant FAUCET_COOLDOWN = 1 days;

    mapping(address account => uint256 timestamp) public lastFaucetAt;

    error FaucetCooldown(uint256 nextAt);

    event FaucetDripped(address indexed to, uint256 amount);

    constructor(address trustedForwarder)
        ERC20("Mock USDC (test money)", "mUSDC")
        ERC20Permit("Mock USDC (test money)")
        ERC2771Context(trustedForwarder)
    {}

    function decimals() public pure override returns (uint8) {
        return 6;
    }

    /// @notice Mints {FAUCET_DRIP} test tokens to the caller, at most once per 24 hours.
    function faucet() external {
        address account = _msgSender();
        uint256 last = lastFaucetAt[account];
        if (last != 0 && block.timestamp < last + FAUCET_COOLDOWN) {
            revert FaucetCooldown(last + FAUCET_COOLDOWN);
        }
        lastFaucetAt[account] = block.timestamp;
        _mint(account, FAUCET_DRIP);
        emit FaucetDripped(account, FAUCET_DRIP);
    }

    function _msgSender() internal view override(Context, ERC2771Context) returns (address) {
        return ERC2771Context._msgSender();
    }

    function _msgData() internal view override(Context, ERC2771Context) returns (bytes calldata) {
        return ERC2771Context._msgData();
    }

    function _contextSuffixLength() internal view override(Context, ERC2771Context) returns (uint256) {
        return ERC2771Context._contextSuffixLength();
    }
}
