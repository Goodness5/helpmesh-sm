// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {IAccessControl} from "@openzeppelin/contracts/access/IAccessControl.sol";
import {Pausable} from "@openzeppelin/contracts/utils/Pausable.sol";
import {Fixture} from "./Fixture.sol";
import {HelpEscrow} from "../src/HelpEscrow.sol";
import {HelpMeshContext} from "../src/HelpMeshContext.sol";
import {IHelpAttestations} from "../src/interfaces/IHelpAttestations.sol";
import {ISponsorPool} from "../src/interfaces/ISponsorPool.sol";

contract HelpEscrowTest is Fixture {
    function test_happyPath_confirmPaysAndRecords() public {
        uint256 helperBefore = token.balanceOf(helper);
        bytes32 requestId = _toCompleted(REWARD);
        vm.prank(requester);
        escrow.confirm(requestId);

        assertEq(uint8(_state(requestId)), uint8(HelpEscrow.State.Released));
        assertEq(token.balanceOf(helper) - helperBefore, REWARD);
        assertEq(token.balanceOf(address(escrow)), 0);
        assertTrue(attestations.confirmed(requestId));
        assertEq(attestations.completions(helper), 1);
    }

    function test_confirmFromStarted() public {
        bytes32 requestId = _toStarted(REWARD);
        vm.prank(requester);
        escrow.confirm(requestId);
        assertEq(uint8(_state(requestId)), uint8(HelpEscrow.State.Released));
        assertEq(token.balanceOf(helper), REWARD);
    }

    function test_fundWithPermit() public {
        vm.prank(requester);
        token.approve(address(escrow), 0);
        uint256 deadline = block.timestamp + 1 hours;
        (uint8 v, bytes32 r, bytes32 s) = _signPermit(REQUESTER_KEY, requester, address(escrow), REWARD, deadline);
        bytes32 requestId = _newId();
        uint256 beforeBal = token.balanceOf(requester);
        vm.prank(requester);
        escrow.fundFromRequesterWithPermit(requestId, address(token), REWARD, _openUntil(1 days), deadline, v, r, s);
        assertEq(uint8(_state(requestId)), uint8(HelpEscrow.State.Open));
        assertEq(token.balanceOf(address(escrow)), REWARD);
        assertEq(beforeBal - token.balanceOf(requester), REWARD);
    }

    function test_releaseAssignmentThenReassign() public {
        bytes32 requestId = _toAssigned(REWARD);
        vm.prank(helper);
        escrow.releaseAssignment(requestId);
        assertEq(uint8(_state(requestId)), uint8(HelpEscrow.State.Open));
        address other = makeAddr("other-helper");
        vm.prank(operator);
        escrow.assignHelper(requestId, other);
        (, address assigned,,,,,,,,) = escrow.escrows(requestId);
        assertEq(assigned, other);
        assertEq(uint8(_state(requestId)), uint8(HelpEscrow.State.Assigned));
    }

    function test_cancelOpenAndAssignedRefundRequester() public {
        uint256 beforeBal = token.balanceOf(requester);
        bytes32 openId = _fund(REWARD);
        vm.prank(requester);
        escrow.cancel(openId);
        assertEq(uint8(_state(openId)), uint8(HelpEscrow.State.Refunded));
        assertEq(token.balanceOf(requester), beforeBal);
        assertEq(token.balanceOf(address(escrow)), 0);

        bytes32 assignedId = _toAssigned(REWARD);
        vm.prank(requester);
        escrow.cancel(assignedId);
        assertEq(uint8(_state(assignedId)), uint8(HelpEscrow.State.Refunded));
        assertEq(token.balanceOf(helper), 0);
    }

    function test_cancelStartedOnlyAfterAbandonedSession() public {
        bytes32 requestId = _toStarted(REWARD);
        uint64 startedAt = uint64(block.timestamp);
        vm.prank(requester);
        vm.expectRevert(HelpEscrow.SessionActive.selector);
        escrow.cancel(requestId);

        vm.warp(uint256(startedAt) + escrow.maxSessionDuration());
        vm.prank(requester);
        vm.expectRevert(HelpEscrow.SessionActive.selector);
        escrow.cancel(requestId);

        vm.warp(block.timestamp + 1);
        vm.prank(requester);
        escrow.cancel(requestId);
        assertEq(uint8(_state(requestId)), uint8(HelpEscrow.State.Refunded));
        assertEq(token.balanceOf(helper), 0);
        assertEq(token.balanceOf(address(escrow)), 0);
    }

    function test_completeStillWorksAfterSessionAndCancelDoesNot() public {
        bytes32 requestId = _toStarted(REWARD);
        vm.warp(block.timestamp + escrow.maxSessionDuration() + 1);
        vm.prank(helper);
        escrow.complete(requestId);
        vm.prank(requester);
        vm.expectRevert(HelpEscrow.BadState.selector);
        escrow.cancel(requestId);
        assertEq(uint8(_state(requestId)), uint8(HelpEscrow.State.Completed));
    }

    function test_expireOpenBeforeAndAfter() public {
        uint64 until = _openUntil(1 hours);
        bytes32 early = _newId();
        bytes32 requestId = _newId();
        vm.prank(requester);
        escrow.fundFromRequester(early, address(token), REWARD, until);
        vm.prank(requester);
        escrow.fundFromRequester(requestId, address(token), REWARD, until);

        vm.expectRevert(HelpEscrow.TooEarly.selector);
        escrow.expireOpen(early);
        vm.warp(until);
        vm.expectRevert(HelpEscrow.TooEarly.selector);
        escrow.expireOpen(early);

        vm.warp(uint256(until) + 1);
        uint256 beforeBal = token.balanceOf(requester);
        escrow.expireOpen(requestId);
        assertEq(uint8(_state(requestId)), uint8(HelpEscrow.State.Refunded));
        assertEq(token.balanceOf(requester), beforeBal + REWARD);
        escrow.expireOpen(early);
        vm.expectRevert(HelpEscrow.BadState.selector);
        escrow.expireOpen(early);
    }

    function test_assignAtOpenUntilThenExpired() public {
        uint64 until = _openUntil(1 hours);
        bytes32 requestId = _newId();
        bytes32 late = _newId();
        vm.prank(requester);
        escrow.fundFromRequester(requestId, address(token), REWARD, until);
        vm.prank(requester);
        escrow.fundFromRequester(late, address(token), REWARD, until);
        vm.warp(until);
        vm.prank(operator);
        escrow.assignHelper(requestId, helper);
        assertEq(uint8(_state(requestId)), uint8(HelpEscrow.State.Assigned));

        vm.warp(uint256(until) + 1);
        vm.expectRevert(HelpEscrow.Expired.selector);
        vm.prank(operator);
        escrow.assignHelper(late, helper);
    }

    function test_autoReleaseWindow() public {
        bytes32 requestId = _toCompleted(REWARD);
        uint256 done = block.timestamp;
        vm.expectRevert(HelpEscrow.TooEarly.selector);
        escrow.autoRelease(requestId);
        vm.warp(done + escrow.autoReleaseWindow() - 1);
        vm.expectRevert(HelpEscrow.TooEarly.selector);
        escrow.autoRelease(requestId);
        vm.warp(done + escrow.autoReleaseWindow());
        escrow.autoRelease(requestId);
        assertEq(uint8(_state(requestId)), uint8(HelpEscrow.State.Released));
        assertEq(token.balanceOf(helper), REWARD);
        assertTrue(attestations.confirmed(requestId));
        assertEq(attestations.completions(helper), 1);
    }

    function test_disputeFreezesUntilResolve() public {
        bytes32 requestId = _toCompleted(REWARD);
        uint256 escrowBal = token.balanceOf(address(escrow));
        vm.prank(helper);
        escrow.dispute(requestId);
        assertEq(uint8(_state(requestId)), uint8(HelpEscrow.State.Disputed));
        assertEq(token.balanceOf(address(escrow)), escrowBal);
        assertEq(token.balanceOf(helper), 0);

        vm.expectRevert(HelpEscrow.BadState.selector);
        vm.prank(requester);
        escrow.confirm(requestId);
        vm.expectRevert(HelpEscrow.BadState.selector);
        escrow.autoRelease(requestId);
        vm.expectRevert(HelpEscrow.BadState.selector);
        vm.prank(requester);
        escrow.cancel(requestId);
    }

    function test_resolveBoundariesAndRemainder() public {
        _assertSplit(_toDisputed(REWARD), 0, 0, REWARD);
        _assertSplit(_toDisputed(REWARD), 5000, REWARD / 2, REWARD / 2);
        _assertSplit(_toDisputed(REWARD), 10_000, REWARD, 0);
        _assertSplit(_toDisputed(3), 5000, 1, 2);
    }

    function test_terminalStatesAreImmutable() public {
        bytes32 released = _toCompleted(REWARD);
        vm.prank(requester);
        escrow.confirm(released);
        _expectStuck(released);

        bytes32 refunded = _fund(REWARD);
        vm.prank(requester);
        escrow.cancel(refunded);
        _expectStuck(refunded);

        bytes32 resolved = _toDisputed(REWARD);
        vm.prank(arbiter);
        escrow.resolve(resolved, 1000);
        _expectStuck(resolved);
    }

    function test_doubleFundConfirmAndRefundRevert() public {
        bytes32 requestId = _fund(REWARD);
        vm.expectRevert(HelpEscrow.AlreadyExists.selector);
        vm.prank(requester);
        escrow.fundFromRequester(requestId, address(token), REWARD, _openUntil(1 days));

        vm.prank(requester);
        escrow.cancel(requestId);
        vm.expectRevert(HelpEscrow.BadState.selector);
        vm.prank(requester);
        escrow.cancel(requestId);

        bytes32 paid = _toCompleted(REWARD);
        vm.prank(requester);
        escrow.confirm(paid);
        vm.expectRevert(HelpEscrow.BadState.selector);
        vm.prank(requester);
        escrow.confirm(paid);
    }

    function test_accessControl() public {
        bytes32 completedId = _toCompleted(REWARD);
        bytes32 assignedId = _toAssigned(REWARD);
        bytes32 startedId = _toStarted(REWARD);
        bytes32 releaseId = _toAssigned(REWARD);
        bytes32 openForRequester = _fund(REWARD);
        bytes32 openForAdmin = _fund(REWARD);
        bytes32 disputeId = _toStarted(REWARD);
        bytes32 resolveId = _toDisputed(REWARD);
        bytes32 samePartyId = _fund(REWARD);
        bytes32 zeroHelperId = _fund(REWARD);

        vm.expectRevert(HelpEscrow.NotRequester.selector);
        vm.prank(helper);
        escrow.confirm(completedId);

        vm.expectRevert(HelpEscrow.NotHelper.selector);
        vm.prank(requester);
        escrow.start(assignedId);

        vm.expectRevert(HelpEscrow.NotHelper.selector);
        vm.prank(operator);
        escrow.complete(startedId);

        vm.expectRevert(HelpEscrow.NotHelper.selector);
        vm.prank(requester);
        escrow.releaseAssignment(releaseId);

        vm.expectRevert(
            abi.encodeWithSelector(
                IAccessControl.AccessControlUnauthorizedAccount.selector, requester, escrow.OPERATOR_ROLE()
            )
        );
        vm.prank(requester);
        escrow.assignHelper(openForRequester, helper);

        vm.expectRevert(
            abi.encodeWithSelector(
                IAccessControl.AccessControlUnauthorizedAccount.selector, admin, escrow.OPERATOR_ROLE()
            )
        );
        vm.prank(admin);
        escrow.assignHelper(openForAdmin, helper);

        vm.expectRevert(HelpEscrow.NotParty.selector);
        vm.prank(operator);
        escrow.dispute(disputeId);

        vm.expectRevert(
            abi.encodeWithSelector(
                IAccessControl.AccessControlUnauthorizedAccount.selector, requester, escrow.ARBITER_ROLE()
            )
        );
        vm.prank(requester);
        escrow.resolve(resolveId, 0);

        vm.expectRevert(HelpEscrow.SameParty.selector);
        vm.prank(operator);
        escrow.assignHelper(samePartyId, requester);

        vm.expectRevert(HelpMeshContext.ZeroAddress.selector);
        vm.prank(operator);
        escrow.assignHelper(zeroHelperId, address(0));
    }

    function testFuzz_onlyRequesterConfirms(address caller) public {
        vm.assume(caller != requester);
        bytes32 requestId = _toCompleted(REWARD);
        vm.expectRevert(HelpEscrow.NotRequester.selector);
        vm.prank(caller);
        escrow.confirm(requestId);
    }

    function testFuzz_onlyHelperStarts(address caller) public {
        vm.assume(caller != helper);
        bytes32 requestId = _toAssigned(REWARD);
        vm.expectRevert(HelpEscrow.NotHelper.selector);
        vm.prank(caller);
        escrow.start(requestId);
    }

    function testFuzz_onlyHelperCompletes(address caller) public {
        vm.assume(caller != helper);
        bytes32 requestId = _toStarted(REWARD);
        vm.expectRevert(HelpEscrow.NotHelper.selector);
        vm.prank(caller);
        escrow.complete(requestId);
    }

    function testFuzz_onlyOperatorAssigns(address caller) public {
        vm.assume(caller != operator);
        bytes32 requestId = _fund(REWARD);
        vm.expectRevert(
            abi.encodeWithSelector(
                IAccessControl.AccessControlUnauthorizedAccount.selector, caller, escrow.OPERATOR_ROLE()
            )
        );
        vm.prank(caller);
        escrow.assignHelper(requestId, helper);
    }

    function testFuzz_resolveSplits(uint128 amount, uint16 bps) public {
        amount = uint128(bound(amount, 1, MAX_AMOUNT));
        bps = uint16(bound(bps, 0, 10_000));
        bytes32 requestId = _toDisputed(amount);
        uint256 requesterBefore = token.balanceOf(requester);
        uint256 helperBefore = token.balanceOf(helper);
        vm.prank(arbiter);
        escrow.resolve(requestId, bps);
        uint256 helperAmount = uint256(amount) * bps / 10_000;
        uint256 refundAmount = amount - helperAmount;
        assertEq(token.balanceOf(helper) - helperBefore, helperAmount);
        assertEq(token.balanceOf(requester) - requesterBefore, refundAmount);
        assertEq(token.balanceOf(address(escrow)), 0);
        assertEq(helperAmount + refundAmount, amount);
        assertFalse(attestations.confirmed(requestId));
    }

    function testFuzz_invalidBps(uint256 bps) public {
        bps = bound(bps, 10_001, type(uint16).max);
        bytes32 requestId = _toDisputed(REWARD);
        vm.expectRevert(HelpEscrow.InvalidBps.selector);
        vm.prank(arbiter);
        escrow.resolve(requestId, bps);
    }

    function testFuzz_fundAndCancel(uint128 amount) public {
        amount = uint128(bound(amount, 1, MAX_AMOUNT));
        uint256 beforeBal = token.balanceOf(requester);
        bytes32 requestId = _fund(amount);
        assertEq(token.balanceOf(address(escrow)), amount);
        vm.prank(requester);
        escrow.cancel(requestId);
        assertEq(token.balanceOf(requester), beforeBal);
        assertEq(token.balanceOf(address(escrow)), 0);
    }

    function test_fundingGuards() public {
        vm.expectRevert(HelpEscrow.TokenNotAllowed.selector);
        vm.prank(requester);
        escrow.fundFromRequester(_newId(), makeAddr("other-token"), REWARD, _openUntil(1 days));

        vm.expectRevert(HelpEscrow.ZeroAmount.selector);
        vm.prank(requester);
        escrow.fundFromRequester(_newId(), address(token), 0, _openUntil(1 days));

        vm.expectRevert(HelpEscrow.AmountTooHigh.selector);
        vm.prank(requester);
        escrow.fundFromRequester(_newId(), address(token), MAX_AMOUNT + 1, _openUntil(1 days));

        vm.expectRevert(HelpEscrow.Expired.selector);
        vm.prank(requester);
        escrow.fundFromRequester(_newId(), address(token), REWARD, uint64(block.timestamp));
    }

    function test_pauseBlocksFundingButNotExits() public {
        bytes32 toConfirm = _toCompleted(REWARD);
        bytes32 toCancel = _fund(REWARD);
        bytes32 toExpire = _newId();
        vm.prank(requester);
        escrow.fundFromRequester(toExpire, address(token), REWARD, _openUntil(1 hours));
        bytes32 toRelease = _toCompleted(REWARD);
        bytes32 toResolve = _toDisputed(REWARD);

        vm.prank(pauser);
        escrow.pause();

        vm.expectRevert(Pausable.EnforcedPause.selector);
        vm.prank(requester);
        escrow.fundFromRequester(_newId(), address(token), REWARD, _openUntil(1 days));

        vm.prank(requester);
        escrow.confirm(toConfirm);
        vm.prank(requester);
        escrow.cancel(toCancel);
        vm.prank(arbiter);
        escrow.resolve(toResolve, 2500);
        vm.warp(block.timestamp + escrow.autoReleaseWindow());
        escrow.expireOpen(toExpire);
        escrow.autoRelease(toRelease);

        assertEq(uint8(_state(toConfirm)), uint8(HelpEscrow.State.Released));
        assertEq(uint8(_state(toCancel)), uint8(HelpEscrow.State.Refunded));
        assertEq(uint8(_state(toExpire)), uint8(HelpEscrow.State.Refunded));
        assertEq(uint8(_state(toRelease)), uint8(HelpEscrow.State.Released));
        assertEq(uint8(_state(toResolve)), uint8(HelpEscrow.State.Resolved));
        assertEq(token.balanceOf(address(escrow)), 0);
    }

    function test_pauseRoleAndUnpause() public {
        vm.expectRevert(
            abi.encodeWithSelector(
                IAccessControl.AccessControlUnauthorizedAccount.selector, admin, escrow.PAUSER_ROLE()
            )
        );
        vm.prank(admin);
        escrow.pause();

        vm.expectRevert(Pausable.ExpectedPause.selector);
        vm.prank(pauser);
        escrow.unpause();

        vm.prank(pauser);
        escrow.pause();
        vm.expectRevert(Pausable.EnforcedPause.selector);
        vm.prank(pauser);
        escrow.pause();
        vm.prank(pauser);
        escrow.unpause();

        vm.prank(requester);
        escrow.fundFromRequester(_newId(), address(token), REWARD, _openUntil(1 days));
    }

    function test_adminParamsStayInBoundsAndDoNotMoveFunds() public {
        bytes32 requestId = _fund(REWARD);
        uint256 escrowBal = token.balanceOf(address(escrow));
        uint256 adminBal = token.balanceOf(admin);

        vm.startPrank(admin);
        escrow.setAutoReleaseWindow(1 hours);
        escrow.setAutoReleaseWindow(30 days);
        escrow.setMaxSessionDuration(1 hours);
        escrow.setMaxSessionDuration(7 days);
        escrow.setMaxAmount(1);
        escrow.setMaxAmount(escrow.ABSOLUTE_MAX_AMOUNT());
        escrow.setTokenAllowed(address(token), true);
        vm.stopPrank();

        assertEq(escrow.autoReleaseWindow(), 30 days);
        assertEq(escrow.maxSessionDuration(), 7 days);
        assertEq(escrow.maxAmount(), escrow.ABSOLUTE_MAX_AMOUNT());
        assertEq(token.balanceOf(address(escrow)), escrowBal);
        assertEq(token.balanceOf(admin), adminBal);
        assertEq(uint8(_state(requestId)), uint8(HelpEscrow.State.Open));

        vm.expectRevert(HelpEscrow.ParamOutOfBounds.selector);
        vm.prank(admin);
        escrow.setAutoReleaseWindow(1 hours - 1);
        vm.expectRevert(HelpEscrow.ParamOutOfBounds.selector);
        vm.prank(admin);
        escrow.setMaxSessionDuration(7 days + 1);
        vm.expectRevert(HelpEscrow.ParamOutOfBounds.selector);
        vm.prank(admin);
        escrow.setMaxAmount(0);
        vm.expectRevert(HelpMeshContext.ZeroAddress.selector);
        vm.prank(admin);
        escrow.setTokenAllowed(address(0), true);
    }

    function test_constructorGuards() public {
        vm.expectRevert(HelpMeshContext.ZeroAddress.selector);
        new HelpEscrow(address(0), address(forwarder), attestations, sponsorPool, MAX_AMOUNT);
        vm.expectRevert(HelpMeshContext.ZeroAddress.selector);
        new HelpEscrow(admin, address(forwarder), IHelpAttestations(address(0)), sponsorPool, MAX_AMOUNT);
        vm.expectRevert(HelpMeshContext.ZeroAddress.selector);
        new HelpEscrow(admin, address(forwarder), attestations, ISponsorPool(address(0)), MAX_AMOUNT);
        vm.expectRevert(HelpEscrow.ParamOutOfBounds.selector);
        new HelpEscrow(admin, address(forwarder), attestations, sponsorPool, 0);
        uint128 overMax = escrow.ABSOLUTE_MAX_AMOUNT() + 1;
        vm.expectRevert(HelpEscrow.ParamOutOfBounds.selector);
        new HelpEscrow(admin, address(forwarder), attestations, sponsorPool, overMax);
    }

    function test_invalidTransitionsFromOpen() public {
        bytes32 requestId = _fund(REWARD);
        vm.expectRevert(HelpEscrow.BadState.selector);
        vm.prank(helper);
        escrow.start(requestId);
        vm.expectRevert(HelpEscrow.BadState.selector);
        vm.prank(helper);
        escrow.complete(requestId);
        vm.expectRevert(HelpEscrow.BadState.selector);
        vm.prank(requester);
        escrow.confirm(requestId);
        vm.expectRevert(HelpEscrow.BadState.selector);
        vm.prank(requester);
        escrow.dispute(requestId);
        vm.expectRevert(HelpEscrow.BadState.selector);
        escrow.autoRelease(requestId);
        vm.expectRevert(HelpEscrow.BadState.selector);
        vm.prank(helper);
        escrow.releaseAssignment(requestId);
    }

    function _assertSplit(bytes32 requestId, uint256 bps, uint256 helperAmount, uint256 refundAmount) internal {
        uint256 requesterBefore = token.balanceOf(requester);
        uint256 helperBefore = token.balanceOf(helper);
        vm.prank(arbiter);
        escrow.resolve(requestId, bps);
        assertEq(token.balanceOf(helper) - helperBefore, helperAmount);
        assertEq(token.balanceOf(requester) - requesterBefore, refundAmount);
        assertEq(uint8(_state(requestId)), uint8(HelpEscrow.State.Resolved));
        assertEq(token.balanceOf(address(escrow)), 0);
    }

    function _expectStuck(bytes32 requestId) internal {
        vm.expectRevert(HelpEscrow.BadState.selector);
        vm.prank(operator);
        escrow.assignHelper(requestId, helper);

        vm.expectRevert(HelpEscrow.BadState.selector);
        vm.prank(helper);
        escrow.start(requestId);

        vm.expectRevert(HelpEscrow.BadState.selector);
        vm.prank(helper);
        escrow.complete(requestId);

        vm.expectRevert(HelpEscrow.BadState.selector);
        vm.prank(requester);
        escrow.confirm(requestId);

        vm.expectRevert(HelpEscrow.BadState.selector);
        vm.prank(requester);
        escrow.cancel(requestId);

        vm.expectRevert(HelpEscrow.BadState.selector);
        escrow.expireOpen(requestId);

        vm.expectRevert(HelpEscrow.BadState.selector);
        vm.prank(requester);
        escrow.dispute(requestId);

        vm.expectRevert(HelpEscrow.BadState.selector);
        vm.prank(arbiter);
        escrow.resolve(requestId, 0);

        vm.expectRevert(HelpEscrow.BadState.selector);
        escrow.autoRelease(requestId);

        vm.expectRevert(HelpEscrow.AlreadyExists.selector);
        vm.prank(requester);
        escrow.fundFromRequester(requestId, address(token), REWARD, _openUntil(1 days));
    }
}
