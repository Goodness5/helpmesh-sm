// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Vm} from "forge-std/Vm.sol";
import {IAccessControl} from "@openzeppelin/contracts/access/IAccessControl.sol";
import {Fixture} from "./Fixture.sol";
import {ERC1271Wallet} from "./mocks/ERC1271Wallet.sol";
import {HelpAttestations} from "../src/HelpAttestations.sol";
import {HelpMeshContext} from "../src/HelpMeshContext.sol";
import {IHelpAttestations} from "../src/interfaces/IHelpAttestations.sol";

contract HelpAttestationsTest is Fixture {
    event HelpConfirmed(
        bytes32 indexed requestId,
        address indexed helper,
        address indexed requester,
        IHelpAttestations.Kind kind,
        uint64 timestamp
    );

    function test_recordByEscrow() public {
        bytes32 requestId = _newId();
        vm.recordLogs();
        vm.prank(address(escrow));
        attestations.record(requestId, helper, requester, IHelpAttestations.Kind.Paid);

        assertTrue(attestations.confirmed(requestId));
        assertEq(attestations.completions(helper), 1);

        Vm.Log[] memory logs = vm.getRecordedLogs();
        assertEq(logs.length, 1);
        assertEq(logs[0].topics.length, 4);
        assertEq(logs[0].data.length, 64);
        assertEq(address(uint160(uint256(logs[0].topics[2]))), helper);
        assertEq(address(uint160(uint256(logs[0].topics[3]))), requester);
        (uint8 kind, uint64 timestamp) = abi.decode(logs[0].data, (uint8, uint64));
        assertEq(kind, uint8(IHelpAttestations.Kind.Paid));
        assertEq(timestamp, uint64(block.timestamp));
    }

    function test_recordSponsoredKind() public {
        bytes32 requestId = _newId();
        vm.prank(address(escrow));
        attestations.record(requestId, helper, requester, IHelpAttestations.Kind.Sponsored);
        assertEq(attestations.completions(helper), 1);
    }

    function test_recordAccessAndOnce() public {
        bytes32 requestId = _newId();
        vm.expectRevert(
            abi.encodeWithSelector(
                IAccessControl.AccessControlUnauthorizedAccount.selector, requester, attestations.ESCROW_ROLE()
            )
        );
        vm.prank(requester);
        attestations.record(requestId, helper, requester, IHelpAttestations.Kind.Paid);

        vm.prank(address(escrow));
        attestations.record(requestId, helper, requester, IHelpAttestations.Kind.Paid);
        vm.expectRevert(HelpAttestations.AlreadyConfirmed.selector);
        vm.prank(address(escrow));
        attestations.record(requestId, helper, requester, IHelpAttestations.Kind.Paid);
    }

    function test_recordRejectsSelfAndZero() public {
        vm.expectRevert(HelpAttestations.HelperIsRequester.selector);
        vm.prank(address(escrow));
        attestations.record(_newId(), requester, requester, IHelpAttestations.Kind.Paid);

        vm.expectRevert(HelpMeshContext.ZeroAddress.selector);
        vm.prank(address(escrow));
        attestations.record(_newId(), address(0), requester, IHelpAttestations.Kind.Paid);
    }

    function test_volunteerEoa() public {
        HelpAttestations.Confirmation memory confirmation = _confirmation(_newId(), helper, requester);
        attestations.attestVolunteer(confirmation, _sign(REQUESTER_KEY, _confirmationDigest(confirmation)));
        assertTrue(attestations.confirmed(confirmation.requestId));
        assertEq(attestations.completions(helper), 1);
    }

    function test_volunteerErc1271() public {
        uint256 ownerKey = 0x333;
        address owner = vm.addr(ownerKey);
        ERC1271Wallet wallet = new ERC1271Wallet(owner);
        HelpAttestations.Confirmation memory confirmation = _confirmation(_newId(), helper, address(wallet));
        bytes32 digest = _confirmationDigest(confirmation);
        attestations.attestVolunteer(confirmation, _sign(ownerKey, digest));
        assertTrue(attestations.confirmed(confirmation.requestId));
        assertEq(attestations.completions(helper), 1);

        HelpAttestations.Confirmation memory other = _confirmation(_newId(), helper, address(wallet));
        vm.expectRevert(HelpAttestations.InvalidSignature.selector);
        attestations.attestVolunteer(other, _sign(HELPER_KEY, _confirmationDigest(other)));
    }

    function test_volunteerRejectsBadSignatureReplaySelfAndFuture() public {
        HelpAttestations.Confirmation memory confirmation = _confirmation(_newId(), helper, requester);
        vm.expectRevert(HelpAttestations.InvalidSignature.selector);
        attestations.attestVolunteer(confirmation, _sign(HELPER_KEY, _confirmationDigest(confirmation)));

        bytes memory sig = _sign(REQUESTER_KEY, _confirmationDigest(confirmation));
        attestations.attestVolunteer(confirmation, sig);
        vm.expectRevert(HelpAttestations.AlreadyConfirmed.selector);
        attestations.attestVolunteer(confirmation, sig);

        HelpAttestations.Confirmation memory self = _confirmation(_newId(), requester, requester);
        vm.expectRevert(HelpAttestations.HelperIsRequester.selector);
        attestations.attestVolunteer(self, _sign(REQUESTER_KEY, _confirmationDigest(self)));

        HelpAttestations.Confirmation memory future = _confirmation(_newId(), helper, requester);
        future.completedAt = uint64(block.timestamp + 1);
        vm.expectRevert(HelpAttestations.FutureTimestamp.selector);
        attestations.attestVolunteer(future, _sign(REQUESTER_KEY, _confirmationDigest(future)));

        HelpAttestations.Confirmation memory zero = _confirmation(_newId(), helper, requester);
        zero.completedAt = 0;
        vm.expectRevert(HelpAttestations.FutureTimestamp.selector);
        attestations.attestVolunteer(zero, _sign(REQUESTER_KEY, _confirmationDigest(zero)));
    }

    function test_hashMatchesIndependentEncoding() public view {
        HelpAttestations.Confirmation memory confirmation = _confirmation(bytes32("id"), helper, requester);
        assertEq(_confirmationDigest(confirmation), attestations.hashConfirmation(confirmation));
    }

    function test_appendedSenderIsIgnoredUnlessForwarder() public {
        bytes32 requestId = _newId();
        bytes memory spoof = abi.encodePacked(
            abi.encodeCall(HelpAttestations.record, (requestId, helper, requester, IHelpAttestations.Kind.Volunteer)),
            address(escrow)
        );
        vm.prank(relayer);
        (bool ok,) = address(attestations).call(spoof);
        assertFalse(ok);
        assertFalse(attestations.confirmed(requestId));
    }

    function test_constructorRejectsZeroAdmin() public {
        vm.expectRevert(HelpMeshContext.ZeroAddress.selector);
        new HelpAttestations(address(0), address(forwarder));
    }

    function _confirmation(bytes32 requestId, address helper_, address requester_)
        internal
        view
        returns (HelpAttestations.Confirmation memory)
    {
        return HelpAttestations.Confirmation({
            requestId: requestId, helper: helper_, requester: requester_, completedAt: uint64(block.timestamp)
        });
    }
}
