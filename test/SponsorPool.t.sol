// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Fixture} from "./Fixture.sol";
import {HelpMeshContext} from "../src/HelpMeshContext.sol";
import {SponsorPool} from "../src/SponsorPool.sol";

contract SponsorPoolTest is Fixture {
    function test_depositTracksDonorAndIsIrrevocable() public {
        uint64 poolId = _fundedPool(500e6, 800e6);
        uint256 ownerAfterDeposit = token.balanceOf(donor);
        assertEq(sponsorPool.depositedBy(poolId, donor), 800e6);
        (
            address owner,,
            bytes32 rules,
            uint128 maxPer,
            uint128 balance,
            uint128 deposited,
            uint128 disbursed,
            bool paused
        ) = sponsorPool.pools(poolId);
        assertEq(owner, donor);
        assertEq(rules, keccak256("rules-v1"));
        assertEq(maxPer, 500e6);
        assertEq(balance, 800e6);
        assertEq(deposited, 800e6);
        assertEq(disbursed, 0);
        assertFalse(paused);

        vm.startPrank(donor);
        sponsorPool.setRulesHash(poolId, keccak256("rules-v2"));
        sponsorPool.setMaxPerRequest(poolId, 100e6);
        sponsorPool.setPaused(poolId, true);
        sponsorPool.setPaused(poolId, false);
        vm.stopPrank();
        assertEq(token.balanceOf(donor), ownerAfterDeposit);
        assertEq(token.balanceOf(address(sponsorPool)), 800e6);
    }

    function test_onlyEscrowDrawsAndReturns() public {
        uint64 poolId = _fundedPool(MAX_AMOUNT, 100e6);
        vm.expectRevert(SponsorPool.NotEscrow.selector);
        sponsorPool.draw(poolId, 1, address(escrow));

        vm.expectRevert(SponsorPool.BadRecipient.selector);
        vm.prank(address(escrow));
        sponsorPool.draw(poolId, 1, donor);

        vm.prank(address(escrow));
        sponsorPool.draw(poolId, 40e6, address(escrow));
        (,,,, uint128 balance,, uint128 disbursed,) = sponsorPool.pools(poolId);
        assertEq(balance, 60e6);
        assertEq(disbursed, 40e6);
        assertEq(token.balanceOf(address(escrow)), 40e6);

        vm.prank(donor);
        sponsorPool.setPaused(poolId, true);
        vm.expectRevert(SponsorPool.PoolIsPaused.selector);
        vm.prank(address(escrow));
        sponsorPool.draw(poolId, 1, address(escrow));

        vm.prank(address(escrow));
        token.approve(address(sponsorPool), 25e6);
        vm.prank(address(escrow));
        sponsorPool.giveBack(poolId, 25e6);
        (,,,, balance,, disbursed,) = sponsorPool.pools(poolId);
        assertEq(balance, 85e6);
        assertEq(disbursed, 15e6);
        assertTrue(_paused(poolId));
    }

    function test_drawAndGiveBackGuards() public {
        uint64 poolId = _fundedPool(10e6, 5e6);
        vm.expectRevert(SponsorPool.AmountTooHigh.selector);
        vm.prank(address(escrow));
        sponsorPool.draw(poolId, 11e6, address(escrow));

        vm.expectRevert(SponsorPool.InsufficientPool.selector);
        vm.prank(address(escrow));
        sponsorPool.draw(poolId, 6e6, address(escrow));

        vm.expectRevert(SponsorPool.ZeroAmount.selector);
        vm.prank(address(escrow));
        sponsorPool.draw(poolId, 0, address(escrow));

        vm.expectRevert(SponsorPool.UnknownPool.selector);
        vm.prank(address(escrow));
        sponsorPool.draw(99, 1, address(escrow));

        vm.prank(address(escrow));
        sponsorPool.draw(poolId, 1e6, address(escrow));
        vm.prank(address(escrow));
        token.approve(address(sponsorPool), 1e6);
        vm.expectRevert(SponsorPool.ZeroAmount.selector);
        vm.prank(address(escrow));
        sponsorPool.giveBack(poolId, 0);
        vm.expectRevert(SponsorPool.InsufficientPool.selector);
        vm.prank(address(escrow));
        sponsorPool.giveBack(poolId, 2e6);
        vm.expectRevert(SponsorPool.NotEscrow.selector);
        sponsorPool.giveBack(poolId, 1);
    }

    function test_ownerAndCreateGuards() public {
        vm.expectRevert(HelpMeshContext.ZeroAddress.selector);
        vm.prank(donor);
        sponsorPool.createPool(address(0), bytes32(0), 1);
        vm.expectRevert(SponsorPool.ZeroAmount.selector);
        vm.prank(donor);
        sponsorPool.createPool(address(token), bytes32(0), 0);

        vm.expectRevert(SponsorPool.UnknownPool.selector);
        vm.prank(donor);
        sponsorPool.deposit(42, 1);
        vm.expectRevert(SponsorPool.ZeroAmount.selector);
        vm.prank(donor);
        sponsorPool.deposit(1, 0);

        uint64 poolId = _fundedPool(10e6, 1e6);
        vm.expectRevert(SponsorPool.NotPoolOwner.selector);
        vm.prank(requester);
        sponsorPool.setRulesHash(poolId, bytes32("x"));
        vm.expectRevert(SponsorPool.NotPoolOwner.selector);
        vm.prank(requester);
        sponsorPool.setMaxPerRequest(poolId, 2);
        vm.expectRevert(SponsorPool.ZeroAmount.selector);
        vm.prank(donor);
        sponsorPool.setMaxPerRequest(poolId, 0);
        vm.expectRevert(SponsorPool.UnknownPool.selector);
        vm.prank(donor);
        sponsorPool.setPaused(99, true);

        SponsorPool fresh = new SponsorPool(admin, address(forwarder));
        vm.expectRevert(HelpMeshContext.ZeroAddress.selector);
        vm.prank(admin);
        fresh.setEscrow(address(0));
        vm.prank(admin);
        fresh.setEscrow(address(escrow));
        vm.expectRevert(SponsorPool.EscrowAlreadySet.selector);
        vm.prank(admin);
        fresh.setEscrow(address(escrow));
        vm.expectRevert(SponsorPool.EscrowAlreadySet.selector);
        vm.prank(admin);
        sponsorPool.setEscrow(address(escrow));
    }

    function test_forwarderCannotSpoofEscrow() public {
        uint64 poolId = _fundedPool(MAX_AMOUNT, REWARD);
        bytes memory spoof =
            abi.encodePacked(abi.encodeCall(SponsorPool.draw, (poolId, REWARD, address(escrow))), address(escrow));
        vm.prank(address(forwarder));
        (bool ok,) = address(sponsorPool).call(spoof);
        assertFalse(ok);
        (,,,, uint128 balance,,,) = sponsorPool.pools(poolId);
        assertEq(balance, REWARD);
    }

    function _paused(uint64 poolId) internal view returns (bool paused) {
        (,,,,,,, paused) = sponsorPool.pools(poolId);
    }
}
