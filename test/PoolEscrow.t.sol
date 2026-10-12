// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {Pausable} from "@openzeppelin/contracts/utils/Pausable.sol";
import {Fixture} from "./Fixture.sol";
import {HelpEscrow} from "../src/HelpEscrow.sol";
import {HelpMeshContext} from "../src/HelpMeshContext.sol";

contract OtherToken is ERC20 {
    constructor() ERC20("Other", "OT") {}

    function mint(address to, uint256 amount) external {
        _mint(to, amount);
    }
}

contract PoolEscrowTest is Fixture {
    event RulesChanged(uint64 indexed poolId, bytes32 rulesHash);

    function test_sponsoredHappyPath() public {
        uint64 poolId = _fundedPool(MAX_AMOUNT, 1_000e6);
        bytes32 requestId = _newId();
        HelpEscrow.PoolVoucher memory voucher =
            _voucher(poolId, requestId, REWARD, _openUntil(2 days), _openUntil(3 days));
        assertEq(_voucherDigest(voucher), escrow.hashPoolVoucher(voucher));

        uint256 requesterBefore = token.balanceOf(requester);
        escrow.fundFromPool(voucher, _signVoucher(voucher));
        assertEq(uint8(_state(requestId)), uint8(HelpEscrow.State.Open));
        assertEq(token.balanceOf(requester), requesterBefore);
        assertEq(token.balanceOf(address(escrow)), REWARD);

        vm.prank(operator);
        escrow.assignHelper(requestId, helper);
        vm.prank(helper);
        escrow.start(requestId);
        vm.prank(helper);
        escrow.complete(requestId);
        vm.prank(requester);
        escrow.confirm(requestId);

        assertEq(token.balanceOf(helper), REWARD);
        assertEq(token.balanceOf(requester), requesterBefore);
        assertTrue(attestations.confirmed(requestId));
        assertEq(attestations.completions(helper), 1);
        (,,,, uint128 balance,, uint128 disbursed,) = sponsorPool.pools(poolId);
        assertEq(balance, 1_000e6 - REWARD);
        assertEq(disbursed, REWARD);
    }

    function test_poolRefundsReturnToPoolNotRequester() public {
        uint64 poolId = _fundedPool(MAX_AMOUNT, 1_000e6);
        uint256 requesterBefore = token.balanceOf(requester);
        bytes32 requestId = _fundPool(poolId, REWARD);

        vm.prank(requester);
        escrow.cancel(requestId);
        assertEq(token.balanceOf(requester), requesterBefore);
        assertEq(token.balanceOf(address(escrow)), 0);
        (,,,, uint128 balance,, uint128 disbursed,) = sponsorPool.pools(poolId);
        assertEq(balance, 1_000e6);
        assertEq(disbursed, 0);
        assertEq(token.balanceOf(address(sponsorPool)), 1_000e6);
    }

    function test_poolExpireAndAbandonedSessionReturnToPool() public {
        uint64 poolId = _fundedPool(MAX_AMOUNT, 1_000e6);
        uint256 requesterBefore = token.balanceOf(requester);

        bytes32 openId = _newId();
        uint64 until = _openUntil(1 hours);
        escrow.fundFromPool(
            _voucher(poolId, openId, REWARD, until, _openUntil(2 days)),
            _signVoucher(_voucher(poolId, openId, REWARD, until, _openUntil(2 days)))
        );
        vm.warp(uint256(until) + 1);
        escrow.expireOpen(openId);

        bytes32 startedId = _fundPool(poolId, REWARD);
        vm.prank(operator);
        escrow.assignHelper(startedId, helper);
        vm.prank(helper);
        escrow.start(startedId);
        vm.warp(block.timestamp + escrow.maxSessionDuration() + 1);
        vm.prank(requester);
        escrow.cancel(startedId);

        assertEq(token.balanceOf(requester), requesterBefore);
        (,,,, uint128 balance,, uint128 disbursed,) = sponsorPool.pools(poolId);
        assertEq(balance, 1_000e6);
        assertEq(disbursed, 0);
    }

    function test_poolDisputeSplitsBackToPool() public {
        uint64 poolId = _fundedPool(MAX_AMOUNT, 1_000e6);
        uint256 requesterBefore = token.balanceOf(requester);
        bytes32 requestId = _fundPool(poolId, 3);
        vm.prank(operator);
        escrow.assignHelper(requestId, helper);
        vm.prank(helper);
        escrow.start(requestId);
        vm.prank(helper);
        escrow.dispute(requestId);

        vm.prank(arbiter);
        escrow.resolve(requestId, 5000);
        assertEq(token.balanceOf(helper), 1);
        assertEq(token.balanceOf(requester), requesterBefore);
        (,,,, uint128 balance,, uint128 disbursed,) = sponsorPool.pools(poolId);
        assertEq(balance, 1_000e6 - 3 + 2);
        assertEq(disbursed, 1);
        assertEq(uint256(balance) + uint256(disbursed), 1_000e6);
        assertFalse(attestations.confirmed(requestId));
    }

    function test_poolResolvePaysHelperEverything() public {
        uint64 poolId = _fundedPool(MAX_AMOUNT, REWARD);
        bytes32 requestId = _fundPool(poolId, REWARD);
        vm.prank(operator);
        escrow.assignHelper(requestId, helper);
        vm.prank(helper);
        escrow.start(requestId);
        vm.prank(requester);
        escrow.dispute(requestId);
        vm.prank(arbiter);
        escrow.resolve(requestId, 10_000);
        assertEq(token.balanceOf(helper), REWARD);
        (,,,, uint128 balance,, uint128 disbursed,) = sponsorPool.pools(poolId);
        assertEq(balance, 0);
        assertEq(disbursed, REWARD);
    }

    function test_voucherReverts() public {
        uint64 poolId = _fundedPool(100e6, 50e6);
        bytes32 requestId = _newId();
        HelpEscrow.PoolVoucher memory voucher =
            _voucher(poolId, requestId, REWARD, _openUntil(1 days), _openUntil(2 days));

        vm.expectRevert(HelpEscrow.InvalidSignature.selector);
        escrow.fundFromPool(voucher, _sign(HELPER_KEY, _voucherDigest(voucher)));

        vm.expectRevert(HelpEscrow.InvalidSignature.selector);
        escrow.fundFromPool(voucher, hex"1234");

        bytes memory originalSig = _signVoucher(voucher);
        HelpEscrow.PoolVoucher memory tampered = _voucher(poolId, requestId, 1, voucher.openUntil, voucher.expiry);
        vm.expectRevert(HelpEscrow.InvalidSignature.selector);
        escrow.fundFromPool(tampered, originalSig);

        vm.warp(voucher.expiry + 1);
        vm.expectRevert(HelpEscrow.Expired.selector);
        escrow.fundFromPool(voucher, _signVoucher(voucher));
        vm.warp(1_000_000);

        HelpEscrow.PoolVoucher memory tooBig = _voucher(poolId, _newId(), 101e6, _openUntil(1 days), _openUntil(2 days));
        vm.expectRevert(HelpEscrow.AmountTooHigh.selector);
        escrow.fundFromPool(tooBig, _signVoucher(tooBig));

        HelpEscrow.PoolVoucher memory broke = _voucher(poolId, _newId(), 60e6, _openUntil(1 days), _openUntil(2 days));
        vm.expectRevert(HelpEscrow.InsufficientPool.selector);
        escrow.fundFromPool(broke, _signVoucher(broke));

        vm.prank(donor);
        sponsorPool.setPaused(poolId, true);
        vm.expectRevert(HelpEscrow.PoolIsPaused.selector);
        escrow.fundFromPool(voucher, _signVoucher(voucher));
        vm.prank(donor);
        sponsorPool.setPaused(poolId, false);

        bytes memory sig = _signVoucher(voucher);
        escrow.fundFromPool(voucher, sig);
        vm.expectRevert(HelpEscrow.AlreadyExists.selector);
        escrow.fundFromPool(voucher, sig);
    }

    function test_voucherUnknownPoolWrongTokenAndZero() public {
        HelpEscrow.PoolVoucher memory missing = _voucher(99, _newId(), REWARD, _openUntil(1 days), _openUntil(2 days));
        vm.expectRevert(HelpEscrow.UnknownPool.selector);
        escrow.fundFromPool(missing, _signVoucher(missing));

        OtherToken other = new OtherToken();
        vm.prank(donor);
        uint64 poolId = sponsorPool.createPool(address(other), keccak256("rules"), REWARD);
        other.mint(donor, REWARD);
        vm.prank(donor);
        other.approve(address(sponsorPool), REWARD);
        vm.prank(donor);
        sponsorPool.deposit(poolId, REWARD);
        HelpEscrow.PoolVoucher memory foreign =
            _voucher(poolId, _newId(), REWARD, _openUntil(1 days), _openUntil(2 days));
        vm.expectRevert(HelpEscrow.TokenNotAllowed.selector);
        escrow.fundFromPool(foreign, _signVoucher(foreign));

        uint64 real = _fundedPool(MAX_AMOUNT, REWARD);
        HelpEscrow.PoolVoucher memory zero = _voucher(real, _newId(), 0, _openUntil(1 days), _openUntil(2 days));
        vm.expectRevert(HelpEscrow.ZeroAmount.selector);
        escrow.fundFromPool(zero, _signVoucher(zero));

        HelpEscrow.PoolVoucher memory nobody = _voucher(real, _newId(), REWARD, _openUntil(1 days), _openUntil(2 days));
        nobody.requester = address(0);
        vm.expectRevert(HelpMeshContext.ZeroAddress.selector);
        escrow.fundFromPool(nobody, _signVoucher(nobody));
    }

    function test_pausedEscrowBlocksPoolFunding() public {
        uint64 poolId = _fundedPool(MAX_AMOUNT, REWARD);
        vm.prank(pauser);
        escrow.pause();
        HelpEscrow.PoolVoucher memory voucher =
            _voucher(poolId, _newId(), REWARD, _openUntil(1 days), _openUntil(2 days));
        vm.expectRevert(Pausable.EnforcedPause.selector);
        escrow.fundFromPool(voucher, _signVoucher(voucher));
    }

    function test_rulesChangeEmits() public {
        uint64 poolId = _fundedPool(MAX_AMOUNT, REWARD);
        bytes32 next = keccak256("rules-v2");
        vm.expectEmit(true, false, false, true, address(sponsorPool));
        emit RulesChanged(poolId, next);
        vm.prank(donor);
        sponsorPool.setRulesHash(poolId, next);
        (,, bytes32 stored,,,,,) = sponsorPool.pools(poolId);
        assertEq(stored, next);
    }

    function _fundPool(uint64 poolId, uint128 amount) internal returns (bytes32 requestId) {
        requestId = _newId();
        HelpEscrow.PoolVoucher memory voucher =
            _voucher(poolId, requestId, amount, _openUntil(2 days), _openUntil(3 days));
        escrow.fundFromPool(voucher, _signVoucher(voucher));
    }
}
