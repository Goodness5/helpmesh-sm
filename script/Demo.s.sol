// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {ERC2771Forwarder} from "@openzeppelin/contracts/metatx/ERC2771Forwarder.sol";
import {MessageHashUtils} from "@openzeppelin/contracts/utils/cryptography/MessageHashUtils.sol";
import {ProtocolScript} from "./Protocol.s.sol";
import {HelpEscrow} from "../src/HelpEscrow.sol";
import {MockUSDC} from "../src/MockUSDC.sol";
import {SponsorPool} from "../src/SponsorPool.sol";
import {HelpAttestations} from "../src/HelpAttestations.sol";

/// @notice Anvil demo: one requester-funded reward and one sponsored reward, with the relayer submitting user calls.
/// @dev Uses Anvil's public default keys. Do not point this script at a chain that holds real funds.
contract DemoScript is ProtocolScript {
    uint256 internal constant ADMIN_KEY = 0xac0974bec39a17e36ba4a6b4d238ff944bacb478cbed5efcae784d7bf4f2ff80;
    uint256 internal constant OPERATOR_KEY = 0x59c6995e998f97a5a0044966f0945389dc9e86dae88c7a8412f4603b6b78690d;
    uint256 internal constant SIGNER_KEY = 0x5de4111afa1a4b94908f83103eb1f1706367c2e68ca870fc3fb9a804cdab365a;
    uint256 internal constant REQUESTER_KEY = 0x7c852118294e51e653712a81e05800f419141751be58f605c371e15141b007a6;
    uint256 internal constant HELPER_KEY = 0x47e179ec197488593b187f80a00eb0da91f1b9d0b13f8733639f19c30a34926a;
    uint256 internal constant ARBITER_KEY = 0x8b3a350cf5c34c9194ca85829a2df0ec3153be0318b5e2d3348e872092edffba;
    uint256 internal constant PAUSER_KEY = 0x92db14e403b83dfe3df233f83dfa3a0d7096f21ca9b0d6d6b8d88b2b4ec1564e;
    uint256 internal constant RELAYER_KEY = 0x4bbbf85ce3377467afe5d46f804f221813b2bb87f24d81f60f1fcdbf7cbf4356;
    uint256 internal constant DONOR_KEY = 0xdbda1821b80551c9d65939329250298aa3472ba22feea921c0cf5d620ea67b97;

    uint128 internal constant REWARD = 10e6;
    bytes32 internal constant PERMIT_TYPEHASH =
        keccak256("Permit(address owner,address spender,uint256 value,uint256 nonce,uint256 deadline)");
    bytes32 internal constant FORWARD_TYPEHASH = keccak256(
        "ForwardRequest(address from,address to,uint256 value,uint256 gas,uint256 nonce,uint48 deadline,bytes data)"
    );

    function run() external {
        vm.startBroadcast(ADMIN_KEY);
        Deployment memory deployed = _deploy(
            vm.addr(ADMIN_KEY), vm.addr(OPERATOR_KEY), vm.addr(SIGNER_KEY), vm.addr(ARBITER_KEY), vm.addr(PAUSER_KEY)
        );
        vm.stopBroadcast();

        _reward(deployed);
        _sponsored(deployed);
        _save(deployed);
    }

    function _reward(Deployment memory deployed) internal {
        MockUSDC usdc = MockUSDC(deployed.mockUsdc);
        HelpEscrow escrow = HelpEscrow(deployed.helpEscrow);
        address requester = vm.addr(REQUESTER_KEY);
        address helper = vm.addr(HELPER_KEY);

        vm.startBroadcast(REQUESTER_KEY);
        usdc.faucet();
        vm.stopBroadcast();

        bytes32 rewardId = keccak256("demo-reward");
        uint256 deadline = block.timestamp + 1 hours;
        (uint8 v, bytes32 r, bytes32 s) = _signPermit(usdc, REQUESTER_KEY, requester, address(escrow), REWARD, deadline);
        _relay(
            ERC2771Forwarder(deployed.forwarder),
            REQUESTER_KEY,
            requester,
            address(escrow),
            abi.encodeCall(
                HelpEscrow.fundFromRequesterWithPermit,
                (rewardId, address(usdc), REWARD, uint64(block.timestamp + 3 days), deadline, v, r, s)
            )
        );

        vm.startBroadcast(OPERATOR_KEY);
        escrow.assignHelper(rewardId, helper);
        vm.stopBroadcast();
        _relay(
            ERC2771Forwarder(deployed.forwarder),
            HELPER_KEY,
            helper,
            address(escrow),
            abi.encodeCall(HelpEscrow.start, (rewardId))
        );
        _relay(
            ERC2771Forwarder(deployed.forwarder),
            HELPER_KEY,
            helper,
            address(escrow),
            abi.encodeCall(HelpEscrow.complete, (rewardId))
        );
        _relay(
            ERC2771Forwarder(deployed.forwarder),
            REQUESTER_KEY,
            requester,
            address(escrow),
            abi.encodeCall(HelpEscrow.confirm, (rewardId))
        );
        require(usdc.balanceOf(helper) == REWARD, "reward not paid");
        require(HelpAttestations(deployed.helpAttestations).confirmed(rewardId), "reward not attested");
    }

    function _sponsored(Deployment memory deployed) internal {
        MockUSDC usdc = MockUSDC(deployed.mockUsdc);
        HelpEscrow escrow = HelpEscrow(deployed.helpEscrow);
        SponsorPool pool = SponsorPool(deployed.sponsorPool);
        address requester = vm.addr(REQUESTER_KEY);
        address helper = vm.addr(HELPER_KEY);

        vm.startBroadcast(DONOR_KEY);
        usdc.faucet();
        uint64 poolId = pool.createPool(address(usdc), keccak256("demo-rules"), REWARD);
        usdc.approve(address(pool), 50e6);
        pool.deposit(poolId, 50e6);
        vm.stopBroadcast();

        bytes32 sponsoredId = keccak256("demo-sponsored");
        HelpEscrow.PoolVoucher memory voucher = HelpEscrow.PoolVoucher({
            poolId: poolId,
            requestId: sponsoredId,
            requester: requester,
            amount: REWARD,
            openUntil: uint64(block.timestamp + 3 days),
            expiry: uint64(block.timestamp + 4 days)
        });
        bytes memory voucherSig = _sign(SIGNER_KEY, escrow.hashPoolVoucher(voucher));
        uint256 requesterBefore = usdc.balanceOf(requester);
        vm.startBroadcast(RELAYER_KEY);
        escrow.fundFromPool(voucher, voucherSig);
        vm.stopBroadcast();

        vm.startBroadcast(OPERATOR_KEY);
        escrow.assignHelper(sponsoredId, helper);
        vm.stopBroadcast();
        ERC2771Forwarder forwarder = ERC2771Forwarder(deployed.forwarder);
        _relay(forwarder, HELPER_KEY, helper, address(escrow), abi.encodeCall(HelpEscrow.start, (sponsoredId)));
        _relay(forwarder, HELPER_KEY, helper, address(escrow), abi.encodeCall(HelpEscrow.complete, (sponsoredId)));
        _relay(forwarder, REQUESTER_KEY, requester, address(escrow), abi.encodeCall(HelpEscrow.confirm, (sponsoredId)));

        require(usdc.balanceOf(helper) == REWARD * 2, "sponsored reward not paid");
        require(usdc.balanceOf(requester) == requesterBefore, "pool funds leaked to requester");
        HelpAttestations attestations = HelpAttestations(deployed.helpAttestations);
        require(attestations.confirmed(sponsoredId), "sponsored help not attested");
        require(attestations.completions(helper) == 2, "completions");
    }

    function _relay(ERC2771Forwarder forwarder, uint256 key, address from, address to, bytes memory data) internal {
        uint256 nonce = forwarder.nonces(from);
        uint48 deadline = uint48(block.timestamp + 1 hours);
        uint256 gasLimit = 500_000;
        bytes32 structHash = keccak256(abi.encode(FORWARD_TYPEHASH, from, to, uint256(0), gasLimit, nonce, deadline, keccak256(data)));
        bytes32 digest = MessageHashUtils.toTypedDataHash(_domain("HelpMeshForwarder", address(forwarder)), structHash);
        vm.startBroadcast(RELAYER_KEY);
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
        vm.stopBroadcast();
    }

    function _signPermit(MockUSDC usdc, uint256 key, address owner, address spender, uint256 value, uint256 deadline)
        internal
        view
        returns (uint8 v, bytes32 r, bytes32 s)
    {
        bytes32 structHash = keccak256(abi.encode(PERMIT_TYPEHASH, owner, spender, value, usdc.nonces(owner), deadline));
        bytes32 digest = MessageHashUtils.toTypedDataHash(usdc.DOMAIN_SEPARATOR(), structHash);
        (v, r, s) = vm.sign(key, digest);
    }

    function _sign(uint256 key, bytes32 digest) internal pure returns (bytes memory) {
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(key, digest);
        return abi.encodePacked(r, s, v);
    }

    function _domain(string memory name, address verifying) internal view returns (bytes32) {
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
