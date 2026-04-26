// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "forge-std/Script.sol";
import {RebalancingVault} from "../src/core/RebalancingVault.sol";
import {VaultFactory} from "../src/core/VaultFactory.sol";

contract DeployScript is Script {
    function run() external {
        address keeper = vm.envAddress("KEEPER_ADDRESS");

        vm.startBroadcast();

        RebalancingVault implementation = new RebalancingVault();
        VaultFactory factory = new VaultFactory(address(implementation), keeper);

        vm.stopBroadcast();

        console.log("Implementation:", address(implementation));
        console.log("Factory:", address(factory));
    }
}
