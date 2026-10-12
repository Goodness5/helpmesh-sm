// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Script, console2} from "forge-std/Script.sol";
import {ERC2771Forwarder} from "@openzeppelin/contracts/metatx/ERC2771Forwarder.sol";
import {HelpAttestations} from "../src/HelpAttestations.sol";
import {HelpEscrow} from "../src/HelpEscrow.sol";
import {MockUSDC} from "../src/MockUSDC.sol";
import {SponsorPool} from "../src/SponsorPool.sol";
import {TipJar} from "../src/TipJar.sol";

/// @notice Shared deployment. The forwarder is constructed first because its address is immutable.
contract ProtocolScript is Script {
    uint128 internal constant MAX_AMOUNT = 10_000e6;

    struct Deployment {
        uint256 chainId;
        address mockUsdc;
        address helpAttestations;
        address sponsorPool;
        address forwarder;
        address helpEscrow;
        address tipJar;
        address admin;
        address operator;
        address eligibilitySigner;
        address arbiter;
        address pauser;
        uint128 maxAmount;
        uint64 autoReleaseWindow;
        uint64 maxSessionDuration;
    }

    function _deploy(address admin, address operator, address eligibilitySigner, address arbiter, address pauser)
        internal
        returns (Deployment memory deployed)
    {
        ERC2771Forwarder forwarder = new ERC2771Forwarder("HelpMeshForwarder");
        MockUSDC usdc = new MockUSDC(address(forwarder));
        HelpAttestations attestations = new HelpAttestations(admin, address(forwarder));
        SponsorPool pool = new SponsorPool(admin, address(forwarder));
        HelpEscrow escrow = new HelpEscrow(admin, address(forwarder), attestations, pool, MAX_AMOUNT);
        TipJar tipJar = new TipJar(admin, address(forwarder));

        attestations.grantRole(attestations.ESCROW_ROLE(), address(escrow));
        pool.setEscrow(address(escrow));
        escrow.grantRole(escrow.OPERATOR_ROLE(), operator);
        escrow.grantRole(escrow.ELIGIBILITY_SIGNER_ROLE(), eligibilitySigner);
        escrow.grantRole(escrow.ARBITER_ROLE(), arbiter);
        escrow.grantRole(escrow.PAUSER_ROLE(), pauser);
        escrow.setTokenAllowed(address(usdc), true);
        tipJar.setTokenAllowed(address(usdc), true);

        deployed = Deployment({
            chainId: block.chainid,
            mockUsdc: address(usdc),
            helpAttestations: address(attestations),
            sponsorPool: address(pool),
            forwarder: address(forwarder),
            helpEscrow: address(escrow),
            tipJar: address(tipJar),
            admin: admin,
            operator: operator,
            eligibilitySigner: eligibilitySigner,
            arbiter: arbiter,
            pauser: pauser,
            maxAmount: MAX_AMOUNT,
            autoReleaseWindow: escrow.autoReleaseWindow(),
            maxSessionDuration: escrow.maxSessionDuration()
        });
    }

    function _save(Deployment memory deployed) internal {
        string memory obj = "deployment";
        vm.serializeUint(obj, "chainId", deployed.chainId);
        vm.serializeAddress(obj, "mockUsdc", deployed.mockUsdc);
        vm.serializeAddress(obj, "helpAttestations", deployed.helpAttestations);
        vm.serializeAddress(obj, "sponsorPool", deployed.sponsorPool);
        vm.serializeAddress(obj, "forwarder", deployed.forwarder);
        vm.serializeAddress(obj, "helpEscrow", deployed.helpEscrow);
        vm.serializeAddress(obj, "tipJar", deployed.tipJar);
        vm.serializeAddress(obj, "admin", deployed.admin);
        vm.serializeAddress(obj, "operator", deployed.operator);
        vm.serializeAddress(obj, "eligibilitySigner", deployed.eligibilitySigner);
        vm.serializeAddress(obj, "arbiter", deployed.arbiter);
        vm.serializeAddress(obj, "pauser", deployed.pauser);
        vm.serializeUint(obj, "maxAmount", deployed.maxAmount);
        vm.serializeUint(obj, "autoReleaseWindow", deployed.autoReleaseWindow);
        string memory json = vm.serializeUint(obj, "maxSessionDuration", deployed.maxSessionDuration);

        string memory dir = "contracts/deployments";
        vm.createDir(dir, true);
        string memory path = string.concat(dir, "/", vm.toString(deployed.chainId), ".json");
        vm.writeJson(json, path);
        console2.log("Wrote", path);
    }
}
