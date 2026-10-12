// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test} from "forge-std/Test.sol";
import {HelpEscrow} from "../src/HelpEscrow.sol";
import {HelpMeshContext} from "../src/HelpMeshContext.sol";
import {IHelpAttestations} from "../src/interfaces/IHelpAttestations.sol";
import {ISponsorPool} from "../src/interfaces/ISponsorPool.sol";
import {MockUSDC} from "../src/MockUSDC.sol";

/// @dev Reaches the ERC-2771 `_msgData` overrides. Production calls use `_msgSender`.
contract MockUSDCHarness is MockUSDC {
    constructor(address forwarder) MockUSDC(forwarder) {}

    function exposedMsgData() external view returns (bytes memory) {
        return _msgData();
    }
}

contract EscrowHarness is HelpEscrow {
    constructor(address admin, address forwarder)
        HelpEscrow(admin, forwarder, IHelpAttestations(address(1)), ISponsorPool(address(2)), 1)
    {}

    function exposedMsgData() external view returns (bytes memory) {
        return _msgData();
    }
}

contract ContextHarness is HelpMeshContext {
    constructor(address admin, address forwarder) HelpMeshContext(admin, forwarder) {}

    function exposedMsgData() external view returns (bytes memory) {
        return _msgData();
    }
}

contract ContextOverridesTest is Test {
    function test_msgDataOverridesReturnCalldata() public {
        address admin = makeAddr("admin");
        MockUSDCHarness token = new MockUSDCHarness(address(1));
        EscrowHarness escrow = new EscrowHarness(admin, address(1));
        ContextHarness context = new ContextHarness(admin, address(1));

        bytes memory expected = abi.encodeWithSignature("exposedMsgData()");
        assertEq(token.exposedMsgData(), expected);
        assertEq(escrow.exposedMsgData(), expected);
        assertEq(context.exposedMsgData(), expected);
    }
}
