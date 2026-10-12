// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {HelpMeshContext} from "./HelpMeshContext.sol";

/// @notice Direct thank-you tips and helper support. Tokens move from sender to helper in the same call.
/// @dev This contract never custodies tokens and never writes to HelpAttestations.
contract TipJar is HelpMeshContext, ReentrancyGuard {
    using SafeERC20 for IERC20;

    mapping(address token => bool) public tokenAllowed;

    error TokenNotAllowed();
    error ZeroAmount();

    event TokenAllowedSet(address indexed token, bool allowed);
    event Tipped(address indexed from, address indexed helper, bytes32 requestId, address token, uint128 amount);
    event Supported(address indexed from, address indexed helper, address token, uint128 amount);

    constructor(address admin, address trustedForwarder) HelpMeshContext(admin, trustedForwarder) {}

    function setTokenAllowed(address token, bool allowed) external onlyRole(DEFAULT_ADMIN_ROLE) {
        if (token == address(0)) revert ZeroAddress();
        tokenAllowed[token] = allowed;
        emit TokenAllowedSet(token, allowed);
    }

    function tip(address helper, address token, uint128 amount, bytes32 requestId) external nonReentrant {
        address from = _pay(helper, token, amount);
        emit Tipped(from, helper, requestId, token, amount);
    }

    function support(address helper, address token, uint128 amount) external nonReentrant {
        address from = _pay(helper, token, amount);
        emit Supported(from, helper, token, amount);
    }

    function _pay(address helper, address token, uint128 amount) internal returns (address from) {
        from = _msgSender();
        if (helper == address(0)) revert ZeroAddress();
        if (amount == 0) revert ZeroAmount();
        if (!tokenAllowed[token]) revert TokenNotAllowed();
        IERC20(token).safeTransferFrom(from, helper, amount);
    }
}
