// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Fixture} from "../Fixture.sol";
import {HelpEscrow} from "../../src/HelpEscrow.sol";
import {Handler} from "./Handler.sol";

/// forge-config: default.invariant.runs = 256
/// forge-config: default.invariant.depth = 50
/// forge-config: default.invariant.fail_on_revert = false
contract EscrowInvariants is Fixture {
    Handler internal handler;

    function setUp() public override {
        super.setUp();
        uint64 poolId = _fundedPool(MAX_AMOUNT, 5_000_000e6);
        handler =
            new Handler(escrow, sponsorPool, token, attestations, SIGNER_KEY, poolId, operator, arbiter, pauser, donor);

        for (uint256 i; i < 3; ++i) {
            address requester_ = handler.requesters(i);
            deal(address(token), requester_, 1_000_000e6);
            vm.prank(requester_);
            token.approve(address(escrow), type(uint256).max);
        }

        bytes4[] memory selectors = new bytes4[](18);
        selectors[0] = Handler.fundRequester.selector;
        selectors[1] = Handler.fundPool.selector;
        selectors[2] = Handler.assign.selector;
        selectors[3] = Handler.release.selector;
        selectors[4] = Handler.start.selector;
        selectors[5] = Handler.complete.selector;
        selectors[6] = Handler.confirm.selector;
        selectors[7] = Handler.cancel.selector;
        selectors[8] = Handler.expire.selector;
        selectors[9] = Handler.dispute.selector;
        selectors[10] = Handler.resolve.selector;
        selectors[11] = Handler.autoRelease.selector;
        selectors[12] = Handler.pauseFunding.selector;
        selectors[13] = Handler.unpauseFunding.selector;
        selectors[14] = Handler.warpForward.selector;
        selectors[15] = Handler.depositMore.selector;
        selectors[16] = Handler.pausePool.selector;
        selectors[17] = Handler.attestVolunteer.selector;

        targetContract(address(handler));
        targetSelector(FuzzSelector({addr: address(handler), selectors: selectors}));
        excludeContract(address(escrow));
        excludeContract(address(token));
        excludeContract(address(sponsorPool));
        excludeContract(address(attestations));
        excludeContract(address(tipJar));
        excludeContract(address(forwarder));
    }

    /// 1. Escrow token balance equals the sum of amounts still locked.
    function invariant_solvency() public view {
        assertEq(token.balanceOf(address(escrow)), handler.activeSum());
    }

    /// 2. Each escrow enters a terminal state once, and the helper is paid at most `amount`.
    function invariant_terminalOnceAndPayoutCap() public view {
        assertEq(handler.terminalMutations(), 0);
        assertEq(handler.enteredTerminal(), handler.terminalCount());
        uint256 n = handler.idsLength();
        for (uint256 i; i < n; ++i) {
            bytes32 id = handler.ids(i);
            (,,, uint128 amount,,,,,,) = escrow.escrows(id);
            assertLe(handler.paidToHelper(id), amount);
        }
    }

    /// 3 and 4. Helpers are paid only on release paths, and privileged calls keep their caller.
    function invariant_paymentsAndAuth() public view {
        assertEq(handler.unexpectedHelperPay(), 0);
        assertEq(handler.authBreaks(), 0);
        uint256 sum;
        for (uint256 i; i < 3; ++i) {
            sum += token.balanceOf(handler.helpers(i));
        }
        assertEq(sum, handler.totalTrackedHelperPay());
    }

    /// 5. Pool-sourced escrows never pay the requester.
    function invariant_poolNeverPaysRequester() public view {
        assertEq(handler.poolRequesterGain(), 0);
    }

    /// 6. Pool books balance. Donations, draws, and returns stay in balance.
    function invariant_poolAccounting() public view {
        uint64 n = sponsorPool.nextPoolId();
        uint256 tokenSum;
        for (uint64 i = 1; i <= n; ++i) {
            (, address poolToken,,, uint128 balance, uint128 deposited, uint128 disbursed,) = sponsorPool.pools(i);
            assertEq(uint256(balance) + uint256(disbursed), uint256(deposited));
            if (poolToken == address(token)) tokenSum += balance;
        }
        assertEq(token.balanceOf(address(sponsorPool)), tokenSum);
    }

    /// 7. Token movements on escrow calls stay inside helper, requester, pool, and escrow.
    function invariant_noThirdPartyLeak() public view {
        assertEq(handler.leaked(), 0);
    }

    /// 8. A request is confirmed only when escrow releases it, and completions match the handler.
    function invariant_attestationOnce() public view {
        uint256 n = handler.idsLength();
        for (uint256 i; i < n; ++i) {
            bytes32 id = handler.ids(i);
            (,,,,,, HelpEscrow.State state,,,) = escrow.escrows(id);
            if (state == HelpEscrow.State.Released) assertTrue(attestations.confirmed(id));
            else assertFalse(attestations.confirmed(id));
        }
        for (uint256 i; i < 3; ++i) {
            address helper = handler.helpers(i);
            assertEq(attestations.completions(helper), handler.ghostCompletions(helper));
        }
    }

    /// 9. Pause never blocks confirm, cancel, expire, auto-release, or resolve.
    function invariant_pauseDoesNotBlockExits() public view {
        assertEq(handler.pauseBlocks(), 0);
    }
}
