// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Vm} from "forge-std/Vm.sol";
import {HelpAttestations} from "../../src/HelpAttestations.sol";
import {HelpEscrow} from "../../src/HelpEscrow.sol";
import {MockUSDC} from "../../src/MockUSDC.sol";
import {SponsorPool} from "../../src/SponsorPool.sol";

/// @notice Actor-driven calls for the escrow/pool invariants. Reverts are swallowed; broken properties are counters.
contract Handler {
    Vm internal constant vm = Vm(0x7109709ECfa91a80626fF3989D68f67F5b1DD12D);
    bytes4 internal constant ENFORCED_PAUSE = bytes4(keccak256("EnforcedPause()"));

    struct Snap {
        address helper;
        address requester;
        uint256 helperBal;
        uint256 requesterBal;
        uint256 escrowBal;
        uint256 poolBal;
    }

    HelpEscrow public immutable escrow;
    SponsorPool public immutable pool;
    MockUSDC public immutable token;
    HelpAttestations public immutable attestations;

    uint256 internal immutable signerKey;
    uint64 public immutable poolId;
    address public immutable operator;
    address public immutable arbiter;
    address public immutable pauser;
    address public immutable donor;

    address[3] public requesters;
    address[3] public helpers;
    uint256[3] internal requesterKeys;

    bytes32[] public ids;
    uint256 public nonce = 1;

    mapping(bytes32 id => uint256 amount) public paidToHelper;
    mapping(bytes32 id => uint8 code) public terminalState;
    mapping(address helper => uint32 count) public ghostCompletions;

    uint256 public enteredTerminal;
    uint256 public terminalMutations;
    uint256 public unexpectedHelperPay;
    uint256 public totalTrackedHelperPay;
    uint256 public poolRequesterGain;
    uint256 public leaked;
    uint256 public authBreaks;
    uint256 public pauseBlocks;

    constructor(
        HelpEscrow escrow_,
        SponsorPool pool_,
        MockUSDC token_,
        HelpAttestations attestations_,
        uint256 signerKey_,
        uint64 poolId_,
        address operator_,
        address arbiter_,
        address pauser_,
        address donor_
    ) {
        escrow = escrow_;
        pool = pool_;
        token = token_;
        attestations = attestations_;
        signerKey = signerKey_;
        poolId = poolId_;
        operator = operator_;
        arbiter = arbiter_;
        pauser = pauser_;
        donor = donor_;

        requesterKeys[0] = 0x1001;
        requesterKeys[1] = 0x1002;
        requesterKeys[2] = 0x1003;
        for (uint256 i; i < 3; ++i) {
            requesters[i] = vm.addr(requesterKeys[i]);
            helpers[i] = vm.addr(0x2001 + i);
        }
    }

    function idsLength() external view returns (uint256) {
        return ids.length;
    }

    function activeSum() external view returns (uint256 sum) {
        uint256 n = ids.length;
        for (uint256 i; i < n; ++i) {
            (,,, uint128 amount,,, HelpEscrow.State state,,,) = escrow.escrows(ids[i]);
            if (_active(state)) sum += amount;
        }
    }

    function terminalCount() external view returns (uint256 nTerminal) {
        uint256 n = ids.length;
        for (uint256 i; i < n; ++i) {
            (,,,,,, HelpEscrow.State state,,,) = escrow.escrows(ids[i]);
            if (_terminal(state)) nTerminal++;
        }
    }

    function fundRequester(uint256 amountSeed, uint256 requesterSeed) external {
        if (ids.length >= 16) return;
        address requester = requesters[requesterSeed % 3];
        uint128 amount = uint128(1 + (amountSeed % escrow.maxAmount()));
        bytes32 id = keccak256(abi.encode("req", nonce++));
        Snap memory snap = _snapOf(requester, address(0));
        (bool ok,) = _call(
            requester,
            abi.encodeCall(HelpEscrow.fundFromRequester, (id, address(token), amount, uint64(block.timestamp + 3 days)))
        );
        if (ok) {
            ids.push(id);
            _after(id, snap, false);
        }
    }

    function fundPool(uint256 amountSeed) external {
        if (ids.length >= 16) return;
        (,,, uint128 maxPer, uint128 balance,,,) = pool.pools(poolId);
        uint256 cap = maxPer;
        if (balance < cap) cap = balance;
        if (cap > escrow.maxAmount()) cap = escrow.maxAmount();
        if (cap == 0) return;
        uint128 amount = uint128(1 + (amountSeed % cap));
        bytes32 id = keccak256(abi.encode("pool", nonce++));
        address requester = requesters[amountSeed % 3];
        HelpEscrow.PoolVoucher memory voucher = HelpEscrow.PoolVoucher({
            poolId: poolId,
            requestId: id,
            requester: requester,
            amount: amount,
            openUntil: uint64(block.timestamp + 3 days),
            expiry: uint64(block.timestamp + 4 days)
        });
        Snap memory snap = _snapOf(requester, address(0));
        (bool ok,) = _call(address(this), abi.encodeCall(HelpEscrow.fundFromPool, (voucher, _signVoucher(voucher))));
        if (ok) {
            ids.push(id);
            _after(id, snap, false);
        }
    }

    function assign(uint256 idSeed, uint256 helperSeed, uint256 callerSeed) external {
        bytes32 id = _pick(idSeed);
        if (id == bytes32(0)) return;
        address helper = helpers[helperSeed % 3];
        address caller = callerSeed % 5 == 0 ? _actor(callerSeed) : operator;
        Snap memory snap = _snap(id);
        (bool ok,) = _call(caller, abi.encodeCall(HelpEscrow.assignHelper, (id, helper)));
        if (ok) {
            if (caller != operator) authBreaks++;
            _after(id, snap, false);
        }
    }

    function release(uint256 idSeed, uint256 callerSeed) external {
        bytes32 id = _pick(idSeed);
        if (id == bytes32(0)) return;
        Snap memory snap = _snap(id);
        address caller = callerSeed % 5 == 0 ? _actor(callerSeed) : snap.helper;
        (bool ok,) = _call(caller, abi.encodeCall(HelpEscrow.releaseAssignment, (id)));
        if (ok) {
            if (caller != snap.helper) authBreaks++;
            _after(id, snap, false);
        }
    }

    function start(uint256 idSeed, uint256 callerSeed) external {
        bytes32 id = _pick(idSeed);
        if (id == bytes32(0)) return;
        Snap memory snap = _snap(id);
        address caller = callerSeed % 5 == 0 ? _actor(callerSeed) : snap.helper;
        (bool ok,) = _call(caller, abi.encodeCall(HelpEscrow.start, (id)));
        if (ok) {
            if (caller != snap.helper) authBreaks++;
            _after(id, snap, false);
        }
    }

    function complete(uint256 idSeed, uint256 callerSeed) external {
        bytes32 id = _pick(idSeed);
        if (id == bytes32(0)) return;
        Snap memory snap = _snap(id);
        address caller = callerSeed % 5 == 0 ? _actor(callerSeed) : snap.helper;
        (bool ok,) = _call(caller, abi.encodeCall(HelpEscrow.complete, (id)));
        if (ok) {
            if (caller != snap.helper) authBreaks++;
            _after(id, snap, false);
        }
    }

    function confirm(uint256 idSeed, uint256 callerSeed) external {
        bytes32 id = _pick(idSeed);
        if (id == bytes32(0)) return;
        Snap memory snap = _snap(id);
        address caller = callerSeed % 5 == 0 ? _actor(callerSeed) : snap.requester;
        (bool ok, bytes memory ret) = _call(caller, abi.encodeCall(HelpEscrow.confirm, (id)));
        if (!ok) _notePause(ret);
        if (ok) {
            if (caller != snap.requester) authBreaks++;
            _after(id, snap, true);
            ghostCompletions[snap.helper] += 1;
        }
    }

    function cancel(uint256 idSeed, uint256 callerSeed) external {
        bytes32 id = _pick(idSeed);
        if (id == bytes32(0)) return;
        Snap memory snap = _snap(id);
        address caller = callerSeed % 5 == 0 ? _actor(callerSeed) : snap.requester;
        (bool ok, bytes memory ret) = _call(caller, abi.encodeCall(HelpEscrow.cancel, (id)));
        if (!ok) _notePause(ret);
        if (ok) {
            if (caller != snap.requester) authBreaks++;
            _after(id, snap, false);
        }
    }

    function expire(uint256 idSeed) external {
        bytes32 id = _pick(idSeed);
        if (id == bytes32(0)) return;
        Snap memory snap = _snap(id);
        (bool ok, bytes memory ret) = _call(_actor(idSeed), abi.encodeCall(HelpEscrow.expireOpen, (id)));
        if (!ok) _notePause(ret);
        if (ok) _after(id, snap, false);
    }

    function dispute(uint256 idSeed, uint256 callerSeed) external {
        bytes32 id = _pick(idSeed);
        if (id == bytes32(0)) return;
        Snap memory snap = _snap(id);
        address caller = callerSeed % 2 == 0 ? snap.requester : snap.helper;
        if (callerSeed % 7 == 0) caller = _actor(callerSeed);
        (bool ok,) = _call(caller, abi.encodeCall(HelpEscrow.dispute, (id)));
        if (ok) {
            if (caller != snap.requester && caller != snap.helper) authBreaks++;
            _after(id, snap, false);
        }
    }

    function resolve(uint256 idSeed, uint256 bpsSeed, uint256 callerSeed) external {
        bytes32 id = _pick(idSeed);
        if (id == bytes32(0)) return;
        Snap memory snap = _snap(id);
        uint256 bps = bpsSeed % 10_001;
        address caller = callerSeed % 5 == 0 ? _actor(callerSeed) : arbiter;
        (bool ok, bytes memory ret) = _call(caller, abi.encodeCall(HelpEscrow.resolve, (id, bps)));
        if (!ok) _notePause(ret);
        if (ok) {
            if (caller != arbiter) authBreaks++;
            _after(id, snap, true);
        }
    }

    function autoRelease(uint256 idSeed) external {
        bytes32 id = _pick(idSeed);
        if (id == bytes32(0)) return;
        Snap memory snap = _snap(id);
        (bool ok, bytes memory ret) = _call(_actor(idSeed), abi.encodeCall(HelpEscrow.autoRelease, (id)));
        if (!ok) _notePause(ret);
        if (ok) {
            _after(id, snap, true);
            ghostCompletions[snap.helper] += 1;
        }
    }

    function pauseFunding() external {
        vm.prank(pauser);
        (bool ok,) = address(escrow).call(abi.encodeCall(HelpEscrow.pause, ()));
        ok;
    }

    function unpauseFunding() external {
        vm.prank(pauser);
        (bool ok,) = address(escrow).call(abi.encodeCall(HelpEscrow.unpause, ()));
        ok;
    }

    function warpForward(uint256 seed) external {
        vm.warp(block.timestamp + 1 + (seed % 3 days));
    }

    function depositMore(uint256 seed) external {
        uint128 amount = uint128(1 + (seed % 1_000e6));
        vm.prank(donor);
        (bool ok,) = address(pool).call(abi.encodeCall(SponsorPool.deposit, (poolId, amount)));
        ok;
    }

    function pausePool(uint256 seed) external {
        vm.prank(donor);
        (bool ok,) = address(pool).call(abi.encodeCall(SponsorPool.setPaused, (poolId, seed % 2 == 0)));
        ok;
    }

    function attestVolunteer(uint256 seed) external {
        uint256 requesterIndex = seed % 3;
        uint256 helperIndex = (seed / 3) % 3;
        HelpAttestations.Confirmation memory confirmation = HelpAttestations.Confirmation({
            requestId: keccak256(abi.encode("vol", nonce++)),
            helper: helpers[helperIndex],
            requester: requesters[requesterIndex],
            completedAt: uint64(block.timestamp == 0 ? 1 : block.timestamp)
        });
        (uint8 v, bytes32 r, bytes32 s) =
            vm.sign(requesterKeys[requesterIndex], attestations.hashConfirmation(confirmation));
        (bool ok,) = address(attestations)
            .call(abi.encodeCall(HelpAttestations.attestVolunteer, (confirmation, abi.encodePacked(r, s, v))));
        if (ok) ghostCompletions[helpers[helperIndex]] += 1;
    }

    function _pick(uint256 seed) internal view returns (bytes32) {
        if (ids.length == 0) return bytes32(0);
        return ids[seed % ids.length];
    }

    function _actor(uint256 seed) internal view returns (address) {
        uint256 slot = seed % 10;
        if (slot == 0) return requesters[0];
        if (slot == 1) return requesters[1];
        if (slot == 2) return requesters[2];
        if (slot == 3) return helpers[0];
        if (slot == 4) return helpers[1];
        if (slot == 5) return helpers[2];
        if (slot == 6) return operator;
        if (slot == 7) return arbiter;
        if (slot == 8) return pauser;
        return donor;
    }

    function _call(address caller, bytes memory data) internal returns (bool ok, bytes memory ret) {
        vm.prank(caller);
        (ok, ret) = address(escrow).call(data);
    }

    function _snap(bytes32 id) internal view returns (Snap memory snap) {
        (snap.requester, snap.helper,,,,,,,,) = escrow.escrows(id);
        snap = _fill(snap);
    }

    function _snapOf(address requester, address helper) internal view returns (Snap memory snap) {
        snap.requester = requester;
        snap.helper = helper;
        snap = _fill(snap);
    }

    function _fill(Snap memory snap) internal view returns (Snap memory) {
        if (snap.helper != address(0)) snap.helperBal = token.balanceOf(snap.helper);
        if (snap.requester != address(0)) snap.requesterBal = token.balanceOf(snap.requester);
        snap.escrowBal = token.balanceOf(address(escrow));
        snap.poolBal = token.balanceOf(address(pool));
        return snap;
    }

    function _after(bytes32 id, Snap memory snap, bool expectPay) internal {
        uint256 helperAfter = snap.helper == address(0) ? 0 : token.balanceOf(snap.helper);
        uint256 requesterAfter = snap.requester == address(0) ? 0 : token.balanceOf(snap.requester);
        uint256 escrowAfter = token.balanceOf(address(escrow));
        uint256 poolAfter = token.balanceOf(address(pool));

        if (snap.helper != address(0) && helperAfter > snap.helperBal) {
            uint256 got = helperAfter - snap.helperBal;
            if (expectPay) {
                paidToHelper[id] += got;
                totalTrackedHelperPay += got;
            } else {
                unexpectedHelperPay += got;
            }
        }

        (,,,, HelpEscrow.Source source,,,,,) = escrow.escrows(id);
        if (source == HelpEscrow.Source.Pool && requesterAfter > snap.requesterBal) {
            poolRequesterGain += requesterAfter - snap.requesterBal;
        }

        int256 delta = int256(escrowAfter) - int256(snap.escrowBal) + int256(requesterAfter) - int256(snap.requesterBal)
            + int256(poolAfter) - int256(snap.poolBal);
        if (snap.helper != address(0)) delta += int256(helperAfter) - int256(snap.helperBal);
        if (delta != 0) leaked += _abs(delta);

        (,,,,,, HelpEscrow.State state,,,) = escrow.escrows(id);
        uint8 code = uint8(state);
        if (_terminal(state)) {
            if (terminalState[id] == 0) {
                terminalState[id] = code;
                enteredTerminal++;
            } else if (terminalState[id] != code) {
                terminalMutations++;
            }
        } else if (terminalState[id] != 0) {
            terminalMutations++;
        }
    }

    function _notePause(bytes memory ret) internal {
        if (ret.length >= 4 && bytes4(ret) == ENFORCED_PAUSE) pauseBlocks++;
    }

    function _signVoucher(HelpEscrow.PoolVoucher memory voucher) internal view returns (bytes memory) {
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(signerKey, escrow.hashPoolVoucher(voucher));
        return abi.encodePacked(r, s, v);
    }

    function _active(HelpEscrow.State state) internal pure returns (bool) {
        return state == HelpEscrow.State.Open || state == HelpEscrow.State.Assigned || state == HelpEscrow.State.Started
            || state == HelpEscrow.State.Completed || state == HelpEscrow.State.Disputed;
    }

    function _terminal(HelpEscrow.State state) internal pure returns (bool) {
        return
            state == HelpEscrow.State.Released || state == HelpEscrow.State.Refunded
                || state == HelpEscrow.State.Resolved;
    }

    function _abs(int256 value) internal pure returns (uint256) {
        return value < 0 ? uint256(-value) : uint256(value);
    }
}
