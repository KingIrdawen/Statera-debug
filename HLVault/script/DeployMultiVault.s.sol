// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "forge-std/Script.sol";
import {RebalancingVault} from "../src/core/RebalancingVault.sol";
import {VaultFactory} from "../src/core/VaultFactory.sol";

contract DeployMultiVaultScript is Script {
    function run() external {
        uint256 deployerKey = vm.envUint("KEEPER_PRIVATE_KEY");
        address keeper = vm.addr(deployerKey);

        vm.startBroadcast(deployerKey);

        // ═══ 1. Deploy implementation + factory ═══
        RebalancingVault implementation = new RebalancingVault();
        VaultFactory factory = new VaultFactory(address(implementation), keeper);

        console.log("Implementation:", address(implementation));
        console.log("Factory:", address(factory));
        console.log("Keeper:", keeper);

        // ═══ 2. Create PURR vault ═══
        // tokenIndex=1, szDec=0, weiDec=5, spotMarket=0, evmDec=18
        address purrVault = factory.createVault(
            0xa9056c15938f9aff34CD497c722Ce33dB0C2fD57, // PURR EVM contract
            1,     // counterpartTokenIndex
            0,     // counterpartSpotMarketIndex
            1105,  // hypeTokenIndex (testnet)
            1035,  // hypeSpotMarketIndex (testnet)
            0,     // usdcTokenIndex
            0,     // counterpartSzDecimals
            5,     // counterpartWeiDecimals
            18,    // counterpartEvmDecimals
            10 ether, // maxSingleDeposit (10 HYPE)
            "HyperVault PURR",
            "hvPURR"
        );
        console.log("PURR Vault:", purrVault);

        // ═══ 3. Create DANK vault ═══
        // tokenIndex=1262, szDec=1, weiDec=6, spotMarket=1162, evmDec=18
        address dankVault = factory.createVault(
            0x728E20cde0F8B52d2B73D67e236611DBAE835a78, // DANK EVM contract
            1262,  // counterpartTokenIndex
            1162,  // counterpartSpotMarketIndex
            1105,  // hypeTokenIndex (testnet)
            1035,  // hypeSpotMarketIndex (testnet)
            0,     // usdcTokenIndex
            1,     // counterpartSzDecimals
            6,     // counterpartWeiDecimals
            18,    // counterpartEvmDecimals
            10 ether, // maxSingleDeposit (10 HYPE)
            "HyperVault DANK",
            "hvDANK"
        );
        console.log("DANK Vault:", dankVault);

        // ═══ 4. Create SOVY vault ═══
        // tokenIndex=1158, szDec=1, weiDec=8, spotMarket=1080, evmDec=18
        address sovyVault = factory.createVault(
            0x674d61f547AE1595f81369f7F37f7400C1210444, // SOVY EVM contract
            1158,  // counterpartTokenIndex
            1080,  // counterpartSpotMarketIndex
            1105,  // hypeTokenIndex (testnet)
            1035,  // hypeSpotMarketIndex (testnet)
            0,     // usdcTokenIndex
            1,     // counterpartSzDecimals
            8,     // counterpartWeiDecimals
            18,    // counterpartEvmDecimals
            10 ether, // maxSingleDeposit (10 HYPE)
            "HyperVault SOVY",
            "hvSOVY"
        );
        console.log("SOVY Vault:", sovyVault);

        vm.stopBroadcast();

        // Deposits must be done via cast send (precompiles don't exist in local simulation)
        console.log("");
        console.log("=== Next steps: deposit HYPE via cast send ===");
    }
}
