// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

/// @notice Requester-confirmed completions. Storage and events carry no amount and no category.
interface IHelpAttestations {
    enum Kind {
        Paid,
        Sponsored,
        Volunteer
    }

    function record(bytes32 requestId, address helper, address requester, Kind kind) external;
}
