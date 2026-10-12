// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {EIP712} from "@openzeppelin/contracts/utils/cryptography/EIP712.sol";
import {SignatureChecker} from "@openzeppelin/contracts/utils/cryptography/SignatureChecker.sol";
import {HelpMeshContext} from "./HelpMeshContext.sol";
import {IHelpAttestations} from "./interfaces/IHelpAttestations.sol";

/// @notice Portable proof that a requester confirmed a helper completed a request.
/// @dev There is no amount, category, or free-text field. Money cannot be written into reputation here.
contract HelpAttestations is HelpMeshContext, EIP712, IHelpAttestations {
    bytes32 public constant ESCROW_ROLE = keccak256("ESCROW_ROLE");

    bytes32 public constant CONFIRMATION_TYPEHASH =
        keccak256("Confirmation(bytes32 requestId,address helper,address requester,uint64 completedAt)");

    struct Confirmation {
        bytes32 requestId;
        address helper;
        address requester;
        uint64 completedAt;
    }

    mapping(bytes32 requestId => bool) public confirmed;
    mapping(address helper => uint32) public completions;

    error AlreadyConfirmed();
    error HelperIsRequester();
    error InvalidSignature();
    error FutureTimestamp();

    event HelpConfirmed(
        bytes32 indexed requestId, address indexed helper, address indexed requester, Kind kind, uint64 timestamp
    );

    constructor(address admin, address trustedForwarder)
        HelpMeshContext(admin, trustedForwarder)
        EIP712("HelpAttestations", "1")
    {}

    /// @inheritdoc IHelpAttestations
    function record(bytes32 requestId, address helper, address requester, Kind kind) external onlyRole(ESCROW_ROLE) {
        _confirm(requestId, helper, requester, kind);
    }

    /// @notice Anyone may submit a requester-signed volunteer confirmation. The requester signs, the relayer pays gas.
    function attestVolunteer(Confirmation calldata confirmation, bytes calldata requesterSig) external {
        if (confirmation.completedAt == 0 || confirmation.completedAt > block.timestamp) revert FutureTimestamp();
        bytes32 digest = hashConfirmation(confirmation);
        if (!SignatureChecker.isValidSignatureNow(confirmation.requester, digest, requesterSig)) {
            revert InvalidSignature();
        }
        _confirm(confirmation.requestId, confirmation.helper, confirmation.requester, Kind.Volunteer);
    }

    function hashConfirmation(Confirmation calldata confirmation) public view returns (bytes32) {
        return _hashTypedDataV4(
            keccak256(
                abi.encode(
                    CONFIRMATION_TYPEHASH,
                    confirmation.requestId,
                    confirmation.helper,
                    confirmation.requester,
                    confirmation.completedAt
                )
            )
        );
    }

    function _confirm(bytes32 requestId, address helper, address requester, Kind kind) internal {
        if (helper == address(0) || requester == address(0)) revert ZeroAddress();
        if (helper == requester) revert HelperIsRequester();
        if (confirmed[requestId]) revert AlreadyConfirmed();

        confirmed[requestId] = true;
        completions[helper] += 1;
        emit HelpConfirmed(requestId, helper, requester, kind, uint64(block.timestamp));
    }
}
