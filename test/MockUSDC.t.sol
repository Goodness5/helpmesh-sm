// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test} from "forge-std/Test.sol";
import {ERC2771Forwarder} from "@openzeppelin/contracts/metatx/ERC2771Forwarder.sol";
import {MessageHashUtils} from "@openzeppelin/contracts/utils/cryptography/MessageHashUtils.sol";
import {MockUSDC} from "../src/MockUSDC.sol";

contract MockUSDCTest is Test {
    uint256 internal constant USER_KEY = 0xABC;
    bytes32 internal constant FORWARD_TYPEHASH = keccak256(
        "ForwardRequest(address from,address to,uint256 value,uint256 gas,uint256 nonce,uint48 deadline,bytes data)"
    );

    ERC2771Forwarder internal forwarder;
    MockUSDC internal token;
    address internal user;
    address internal relayer = makeAddr("relayer");

    function setUp() public {
        vm.warp(1_000_000);
        user = vm.addr(USER_KEY);
        forwarder = new ERC2771Forwarder("HelpMeshForwarder");
        token = new MockUSDC(address(forwarder));
    }

    function test_metadata() public view {
        assertEq(token.name(), "Mock USDC (test money)");
        assertEq(token.symbol(), "mUSDC");
        assertEq(token.decimals(), 6);
    }

    function test_faucetMintsOneHundredTokens() public {
        vm.prank(user);
        token.faucet();
        assertEq(token.balanceOf(user), 100e6);
        assertEq(token.totalSupply(), 100e6);
        assertEq(token.lastFaucetAt(user), block.timestamp);
    }

    function test_faucetCooldownAndBoundary() public {
        vm.startPrank(user);
        token.faucet();
        vm.expectRevert(abi.encodeWithSelector(MockUSDC.FaucetCooldown.selector, block.timestamp + 1 days));
        token.faucet();
        vm.warp(block.timestamp + 1 days - 1);
        vm.expectRevert();
        token.faucet();
        vm.warp(block.timestamp + 1);
        token.faucet();
        vm.stopPrank();
        assertEq(token.balanceOf(user), 200e6);
    }

    function test_faucetIsPerAccount() public {
        address other = makeAddr("other");
        vm.prank(user);
        token.faucet();
        vm.prank(other);
        token.faucet();
        assertEq(token.balanceOf(user), 100e6);
        assertEq(token.balanceOf(other), 100e6);
    }

    function test_gaslessFaucetCreditsUser() public {
        bytes memory data = abi.encodeCall(MockUSDC.faucet, ());
        _forward(USER_KEY, user, address(token), data);
        assertEq(token.balanceOf(user), 100e6);
        assertEq(token.balanceOf(relayer), 0);
        assertEq(token.lastFaucetAt(user), block.timestamp);
        assertEq(token.lastFaucetAt(relayer), 0);
    }

    function _forward(uint256 key, address from, address to, bytes memory data) internal {
        uint256 nonce = forwarder.nonces(from);
        uint48 deadline = uint48(block.timestamp + 1 hours);
        uint256 gasLimit = 200_000;
        bytes32 structHash =
            keccak256(abi.encode(FORWARD_TYPEHASH, from, to, uint256(0), gasLimit, nonce, deadline, keccak256(data)));
        bytes32 digest = MessageHashUtils.toTypedDataHash(
            keccak256(
                abi.encode(
                    keccak256("EIP712Domain(string name,string version,uint256 chainId,address verifyingContract)"),
                    keccak256(bytes("HelpMeshForwarder")),
                    keccak256(bytes("1")),
                    block.chainid,
                    address(forwarder)
                )
            ),
            structHash
        );
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(key, digest);
        vm.prank(relayer);
        forwarder.execute(
            ERC2771Forwarder.ForwardRequestData({
                from: from,
                to: to,
                value: 0,
                gas: gasLimit,
                deadline: deadline,
                data: data,
                signature: abi.encodePacked(r, s, v)
            })
        );
    }
}
