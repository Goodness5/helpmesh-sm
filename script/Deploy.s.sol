// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {ProtocolScript} from "./Protocol.s.sol";

/// @notice Broadcasts the protocol from the deployer key.
/// @dev Uses `ADMIN_KEY` or `PRIVATE_KEY`. Role addresses default to that deployer.
///      Verify with `forge script script/Deploy.s.sol --rpc-url $RPC --broadcast --verify`.
contract DeployScript is ProtocolScript {
    function run() external {
        uint256 adminKey = vm.envExists("ADMIN_KEY") ? vm.envUint("ADMIN_KEY") : vm.envUint("PRIVATE_KEY");
        address deployer = vm.addr(adminKey);
        address operator = vm.envOr("OPERATOR", deployer);
        address eligibilitySigner = vm.envOr("ELIGIBILITY_SIGNER", deployer);
        address arbiter = vm.envOr("ARBITER", deployer);
        address pauser = vm.envOr("PAUSER", deployer);

        vm.startBroadcast(adminKey);
        Deployment memory deployed = _deploy(deployer, operator, eligibilitySigner, arbiter, pauser);
        vm.stopBroadcast();
        _save(deployed);
    }
}
