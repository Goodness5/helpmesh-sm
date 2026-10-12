// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test} from "forge-std/Test.sol";
import {ERC2771Forwarder} from "@openzeppelin/contracts/metatx/ERC2771Forwarder.sol";
import {MessageHashUtils} from "@openzeppelin/contracts/utils/cryptography/MessageHashUtils.sol";
import {HelpAttestations} from "../src/HelpAttestations.sol";
import {HelpEscrow} from "../src/HelpEscrow.sol";
import {MockUSDC} from "../src/MockUSDC.sol";
import {SponsorPool} from "../src/SponsorPool.sol";
import {TipJar} from "../src/TipJar.sol";

contract Fixture is Test {
    uint256 internal constant REQUESTER_KEY = 0x111;
    uint256 internal constant HELPER_KEY = 0x222;
    uint256 internal constant SIGNER_KEY = 0xA11CE;
    uint128 internal constant MAX_AMOUNT = 10_000e6;
    uint128 internal constant REWARD = 10e6;

    bytes32 internal constant PERMIT_TYPEHASH =
        keccak256("Permit(address owner,address spender,uint256 value,uint256 nonce,uint256 deadline)");
    bytes32 internal constant FORWARD_TYPEHASH = keccak256(
        "ForwardRequest(address from,address to,uint256 value,uint256 gas,uint256 nonce,uint48 deadline,bytes data)"
    );
    bytes32 internal constant VOUCHER_TYPEHASH = keccak256(
        "PoolVoucher(uint64 poolId,bytes32 requestId,address requester,uint128 amount,uint64 openUntil,uint64 expiry)"
    );
    bytes32 internal constant CONFIRMATION_TYPEHASH =
        keccak256("Confirmation(bytes32 requestId,address helper,address requester,uint64 completedAt)");

    ERC2771Forwarder internal forwarder;
    MockUSDC internal token;
    HelpAttestations internal attestations;
    SponsorPool internal sponsorPool;
    HelpEscrow internal escrow;
    TipJar internal tipJar;

    address internal admin = makeAddr("admin");
    address internal operator = makeAddr("operator");
    address internal arbiter = makeAddr("arbiter");
    address internal pauser = makeAddr("pauser");
    address internal donor = makeAddr("donor");
    address internal relayer = makeAddr("relayer");
    address internal requester;
    address internal helper;
    address internal signer;

    uint256 internal nextId = 1;

    function setUp() public virtual {
        vm.warp(1_000_000);
        requester = vm.addr(REQUESTER_KEY);
        helper = vm.addr(HELPER_KEY);
        signer = vm.addr(SIGNER_KEY);

        forwarder = new ERC2771Forwarder("HelpMeshForwarder");
        token = new MockUSDC(address(forwarder));
        attestations = new HelpAttestations(admin, address(forwarder));
        sponsorPool = new SponsorPool(admin, address(forwarder));
        escrow = new HelpEscrow(admin, address(forwarder), attestations, sponsorPool, MAX_AMOUNT);
        tipJar = new TipJar(admin, address(forwarder));

        vm.startPrank(admin);
        sponsorPool.setEscrow(address(escrow));
        attestations.grantRole(attestations.ESCROW_ROLE(), address(escrow));
        escrow.grantRole(escrow.OPERATOR_ROLE(), operator);
        escrow.grantRole(escrow.ELIGIBILITY_SIGNER_ROLE(), signer);
        escrow.grantRole(escrow.ARBITER_ROLE(), arbiter);
        escrow.grantRole(escrow.PAUSER_ROLE(), pauser);
        escrow.setTokenAllowed(address(token), true);
        tipJar.setTokenAllowed(address(token), true);
        vm.stopPrank();

        deal(address(token), requester, 1_000_000e6);
        vm.prank(requester);
        token.approve(address(escrow), type(uint256).max);
        vm.prank(requester);
        token.approve(address(tipJar), type(uint256).max);

        vm.label(requester, "requester");
        vm.label(helper, "helper");
        vm.label(signer, "signer");
    }

    function _newId() internal returns (bytes32) {
        return keccak256(abi.encode("request", nextId++));
    }

    function _openUntil(uint256 extra) internal view returns (uint64) {
        return uint64(block.timestamp + extra);
    }

    function _fund(uint128 amount) internal returns (bytes32 requestId) {
        requestId = _newId();
        vm.prank(requester);
        escrow.fundFromRequester(requestId, address(token), amount, _openUntil(7 days));
    }

    function _toAssigned(uint128 amount) internal returns (bytes32 requestId) {
        requestId = _fund(amount);
        vm.prank(operator);
        escrow.assignHelper(requestId, helper);
    }

    function _toStarted(uint128 amount) internal returns (bytes32 requestId) {
        requestId = _toAssigned(amount);
        vm.prank(helper);
        escrow.start(requestId);
    }

    function _toCompleted(uint128 amount) internal returns (bytes32 requestId) {
        requestId = _toStarted(amount);
        vm.prank(helper);
        escrow.complete(requestId);
    }

    function _toDisputed(uint128 amount) internal returns (bytes32 requestId) {
        requestId = _toStarted(amount);
        vm.prank(requester);
        escrow.dispute(requestId);
    }

    function _state(bytes32 requestId) internal view returns (HelpEscrow.State state) {
        (,,,,,, state,,,) = escrow.escrows(requestId);
    }

    function _amountOf(bytes32 requestId) internal view returns (uint128 amount) {
        (,,, amount,,,,,,) = escrow.escrows(requestId);
    }

    function _fundedPool(uint128 maxPerRequest, uint128 depositAmount) internal returns (uint64 poolId) {
        vm.prank(donor);
        poolId = sponsorPool.createPool(address(token), keccak256("rules-v1"), maxPerRequest);
        deal(address(token), donor, uint256(depositAmount) + 1_000_000e6);
        vm.prank(donor);
        token.approve(address(sponsorPool), type(uint256).max);
        vm.prank(donor);
        sponsorPool.deposit(poolId, depositAmount);
    }

    function _voucher(uint64 poolId, bytes32 requestId, uint128 amount, uint64 openUntil, uint64 expiry)
        internal
        view
        returns (HelpEscrow.PoolVoucher memory voucher)
    {
        voucher = HelpEscrow.PoolVoucher({
            poolId: poolId,
            requestId: requestId,
            requester: requester,
            amount: amount,
            openUntil: openUntil,
            expiry: expiry
        });
    }

    function _signVoucher(HelpEscrow.PoolVoucher memory voucher) internal view returns (bytes memory) {
        return _sign(SIGNER_KEY, _voucherDigest(voucher));
    }

    function _voucherDigest(HelpEscrow.PoolVoucher memory voucher) internal view returns (bytes32) {
        bytes32 structHash = keccak256(
            abi.encode(
                VOUCHER_TYPEHASH,
                voucher.poolId,
                voucher.requestId,
                voucher.requester,
                voucher.amount,
                voucher.openUntil,
                voucher.expiry
            )
        );
        return MessageHashUtils.toTypedDataHash(_domainSeparator("HelpEscrow", address(escrow)), structHash);
    }

    function _confirmationDigest(HelpAttestations.Confirmation memory confirmation) internal view returns (bytes32) {
        bytes32 structHash = keccak256(
            abi.encode(
                CONFIRMATION_TYPEHASH,
                confirmation.requestId,
                confirmation.helper,
                confirmation.requester,
                confirmation.completedAt
            )
        );
        return MessageHashUtils.toTypedDataHash(_domainSeparator("HelpAttestations", address(attestations)), structHash);
    }

    function _signPermit(uint256 key, address owner, address spender, uint256 value, uint256 deadline)
        internal
        view
        returns (uint8 v, bytes32 r, bytes32 s)
    {
        bytes32 structHash =
            keccak256(abi.encode(PERMIT_TYPEHASH, owner, spender, value, token.nonces(owner), deadline));
        bytes32 digest = MessageHashUtils.toTypedDataHash(token.DOMAIN_SEPARATOR(), structHash);
        (v, r, s) = vm.sign(key, digest);
    }

    function _forward(uint256 key, address from, address to, bytes memory data) internal {
        uint256 nonce = forwarder.nonces(from);
        uint48 deadline = uint48(block.timestamp + 1 hours);
        uint256 gasLimit = 1_000_000;
        bytes32 structHash =
            keccak256(abi.encode(FORWARD_TYPEHASH, from, to, uint256(0), gasLimit, nonce, deadline, keccak256(data)));
        bytes32 digest =
            MessageHashUtils.toTypedDataHash(_domainSeparator("HelpMeshForwarder", address(forwarder)), structHash);
        forwarder.execute(
            ERC2771Forwarder.ForwardRequestData({
                from: from,
                to: to,
                value: 0,
                gas: gasLimit,
                deadline: deadline,
                data: data,
                signature: _sign(key, digest)
            })
        );
    }

    function _sign(uint256 key, bytes32 digest) internal view returns (bytes memory) {
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(key, digest);
        return abi.encodePacked(r, s, v);
    }

    function _domainSeparator(string memory name, address verifying) internal view returns (bytes32) {
        return keccak256(
            abi.encode(
                keccak256("EIP712Domain(string name,string version,uint256 chainId,address verifyingContract)"),
                keccak256(bytes(name)),
                keccak256(bytes("1")),
                block.chainid,
                verifying
            )
        );
    }
}
