// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {Fixture} from "./Fixture.sol";
import {HelpEscrow} from "../src/HelpEscrow.sol";
import {ReenteringToken} from "./mocks/ReenteringToken.sol";

contract ReentrancyTest is Fixture {
    ReenteringToken internal bad;

    function setUp() public override {
        super.setUp();
        bad = new ReenteringToken();
        vm.prank(admin);
        escrow.setTokenAllowed(address(bad), true);
        bad.mint(requester, 1_000e6);
        vm.prank(requester);
        bad.approve(address(escrow), type(uint256).max);
    }

    function test_transferFromReentrancyCannotRefundDuringFund() public {
        bytes32 requestId = _newId();
        bad.arm(address(escrow), abi.encodeCall(HelpEscrow.cancel, (requestId)));
        vm.prank(requester);
        escrow.fundFromRequester(requestId, address(bad), REWARD, _openUntil(1 days));

        assertFalse(bad.innerSucceeded());
        assertEq(bad.innerSelector(), ReentrancyGuard.ReentrancyGuardReentrantCall.selector);
        assertEq(uint8(_state(requestId)), uint8(HelpEscrow.State.Open));
        assertEq(bad.balanceOf(address(escrow)), REWARD);
        assertEq(bad.balanceOf(requester), 1_000e6 - REWARD);
    }

    function test_transferReentrancyCannotDoublePay() public {
        bytes32 requestId = _newId();
        vm.prank(requester);
        escrow.fundFromRequester(requestId, address(bad), REWARD, _openUntil(1 days));
        vm.prank(operator);
        escrow.assignHelper(requestId, helper);
        vm.prank(helper);
        escrow.start(requestId);

        bad.arm(address(escrow), abi.encodeCall(HelpEscrow.confirm, (requestId)));
        vm.prank(requester);
        escrow.confirm(requestId);

        assertFalse(bad.innerSucceeded());
        assertEq(bad.innerSelector(), ReentrancyGuard.ReentrancyGuardReentrantCall.selector);
        assertEq(uint8(_state(requestId)), uint8(HelpEscrow.State.Released));
        assertEq(bad.balanceOf(helper), REWARD);
        assertEq(bad.balanceOf(address(escrow)), 0);
        assertEq(bad.balanceOf(requester), 1_000e6 - REWARD);
        assertTrue(attestations.confirmed(requestId));
        assertEq(attestations.completions(helper), 1);
    }
}
