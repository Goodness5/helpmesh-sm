// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {IAccessControl} from "@openzeppelin/contracts/access/IAccessControl.sol";
import {Fixture} from "./Fixture.sol";
import {HelpMeshContext} from "../src/HelpMeshContext.sol";
import {TipJar} from "../src/TipJar.sol";

contract TipJarTest is Fixture {
    function test_tipAndSupportAreDirect() public {
        uint256 helperBefore = token.balanceOf(helper);
        uint256 senderBefore = token.balanceOf(requester);
        bytes32 requestId = bytes32("thanks");

        vm.prank(requester);
        tipJar.tip(helper, address(token), REWARD, requestId);
        vm.prank(requester);
        tipJar.support(helper, address(token), 1e6);

        assertEq(token.balanceOf(helper) - helperBefore, REWARD + 1e6);
        assertEq(senderBefore - token.balanceOf(requester), REWARD + 1e6);
        assertEq(token.balanceOf(address(tipJar)), 0);
        assertEq(attestations.completions(helper), 0);
        assertFalse(attestations.confirmed(requestId));
    }

    function test_tipGuards() public {
        vm.expectRevert(HelpMeshContext.ZeroAddress.selector);
        vm.prank(requester);
        tipJar.tip(address(0), address(token), 1, bytes32(0));
        vm.expectRevert(TipJar.ZeroAmount.selector);
        vm.prank(requester);
        tipJar.support(helper, address(token), 0);
        vm.expectRevert(TipJar.TokenNotAllowed.selector);
        vm.prank(requester);
        tipJar.tip(helper, makeAddr("nope"), 1, bytes32(0));

        vm.expectRevert(HelpMeshContext.ZeroAddress.selector);
        vm.prank(admin);
        tipJar.setTokenAllowed(address(0), true);
        vm.expectRevert(
            abi.encodeWithSelector(
                IAccessControl.AccessControlUnauthorizedAccount.selector, requester, tipJar.DEFAULT_ADMIN_ROLE()
            )
        );
        vm.prank(requester);
        tipJar.setTokenAllowed(address(token), false);
    }

    function test_gaslessTipUsesUser() public {
        vm.prank(requester);
        token.approve(address(tipJar), type(uint256).max);
        _forward(
            REQUESTER_KEY,
            requester,
            address(tipJar),
            abi.encodeCall(TipJar.tip, (helper, address(token), 2e6, bytes32("gasless")))
        );
        assertEq(token.balanceOf(helper), 2e6);
        assertEq(token.balanceOf(relayer), 0);
        assertEq(token.balanceOf(address(tipJar)), 0);
    }
}
