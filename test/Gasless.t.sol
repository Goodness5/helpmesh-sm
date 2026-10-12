// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Fixture} from "./Fixture.sol";
import {HelpEscrow} from "../src/HelpEscrow.sol";

contract GaslessTest is Fixture {
    function test_rewardFlowThroughForwarder() public {
        vm.prank(requester);
        token.approve(address(escrow), 0);
        uint256 deadline = block.timestamp + 1 hours;
        (uint8 v, bytes32 r, bytes32 s) = _signPermit(REQUESTER_KEY, requester, address(escrow), REWARD, deadline);
        bytes32 requestId = _newId();

        _forward(
            REQUESTER_KEY,
            requester,
            address(escrow),
            abi.encodeCall(
                HelpEscrow.fundFromRequesterWithPermit,
                (requestId, address(token), REWARD, _openUntil(3 days), deadline, v, r, s)
            )
        );
        (address recorded,,,,,,,,,) = escrow.escrows(requestId);
        assertEq(recorded, requester);
        assertEq(uint8(_state(requestId)), uint8(HelpEscrow.State.Open));
        assertEq(token.balanceOf(address(escrow)), REWARD);

        vm.prank(operator);
        escrow.assignHelper(requestId, helper);
        _forward(HELPER_KEY, helper, address(escrow), abi.encodeCall(HelpEscrow.start, (requestId)));
        _forward(HELPER_KEY, helper, address(escrow), abi.encodeCall(HelpEscrow.complete, (requestId)));
        _forward(REQUESTER_KEY, requester, address(escrow), abi.encodeCall(HelpEscrow.confirm, (requestId)));

        assertEq(uint8(_state(requestId)), uint8(HelpEscrow.State.Released));
        assertEq(token.balanceOf(helper), REWARD);
        assertTrue(attestations.confirmed(requestId));
        assertEq(token.balanceOf(relayer), 0);
    }

    function test_sponsoredFlowThroughRelayer() public {
        uint64 poolId = _fundedPool(MAX_AMOUNT, 100e6);
        uint256 requesterBefore = token.balanceOf(requester);
        bytes32 requestId = _newId();
        HelpEscrow.PoolVoucher memory voucher =
            _voucher(poolId, requestId, REWARD, _openUntil(2 days), _openUntil(3 days));
        vm.prank(relayer);
        escrow.fundFromPool(voucher, _signVoucher(voucher));

        vm.prank(operator);
        escrow.assignHelper(requestId, helper);
        _forward(HELPER_KEY, helper, address(escrow), abi.encodeCall(HelpEscrow.start, (requestId)));
        _forward(HELPER_KEY, helper, address(escrow), abi.encodeCall(HelpEscrow.complete, (requestId)));
        _forward(REQUESTER_KEY, requester, address(escrow), abi.encodeCall(HelpEscrow.confirm, (requestId)));

        assertEq(token.balanceOf(helper), REWARD);
        assertEq(token.balanceOf(requester), requesterBefore);
        assertTrue(attestations.confirmed(requestId));
        (,,,, uint128 balance,, uint128 disbursed,) = sponsorPool.pools(poolId);
        assertEq(disbursed, REWARD);
        assertEq(balance, 100e6 - REWARD);
    }

    function test_nonForwarderCannotSpoofRequester() public {
        bytes32 requestId = _fund(REWARD);
        bytes memory spoof = abi.encodePacked(abi.encodeCall(HelpEscrow.cancel, (requestId)), requester);
        vm.prank(relayer);
        (bool ok,) = address(escrow).call(spoof);
        assertFalse(ok);
        assertEq(uint8(_state(requestId)), uint8(HelpEscrow.State.Open));
        assertEq(token.balanceOf(address(escrow)), REWARD);
    }
}
