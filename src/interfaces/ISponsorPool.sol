// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

/// @notice Pool accounting used by escrow when drawing and returning sponsored funds.
interface ISponsorPool {
    function draw(uint64 poolId, uint128 amount, address to) external;

    function giveBack(uint64 poolId, uint128 amount) external;

    function pools(uint64 poolId)
        external
        view
        returns (
            address owner,
            address token,
            bytes32 rulesHash,
            uint128 maxPerRequest,
            uint128 balance,
            uint128 totalDeposited,
            uint128 totalDisbursed,
            bool paused
        );
}
