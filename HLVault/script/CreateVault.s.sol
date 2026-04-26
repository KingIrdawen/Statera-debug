// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "forge-std/Script.sol";
import {VaultFactory} from "../src/core/VaultFactory.sol";

contract CreateVaultScript is Script {
    function run() external {
        address factoryAddr = vm.envAddress("FACTORY_ADDRESS");
        address counterpartToken = vm.envAddress("COUNTERPART_TOKEN");
        uint32 counterpartTokenIndex = uint32(vm.envUint("COUNTERPART_TOKEN_INDEX"));
        uint32 counterpartSpotMarketIndex = uint32(vm.envUint("COUNTERPART_SPOT_MARKET_INDEX"));
        uint32 hypeTokenIndex = uint32(vm.envUint("HYPE_TOKEN_INDEX"));
        uint32 hypeSpotMarketIndex = uint32(vm.envUint("HYPE_SPOT_MARKET_INDEX"));
        uint32 usdcTokenIndex = uint32(vm.envUint("USDC_TOKEN_INDEX"));
        uint8 counterpartSzDecimals = uint8(vm.envUint("COUNTERPART_SZ_DECIMALS"));
        uint8 counterpartWeiDecimals = uint8(vm.envUint("COUNTERPART_WEI_DECIMALS"));
        uint8 counterpartEvmDecimals = uint8(vm.envUint("COUNTERPART_EVM_DECIMALS"));
        uint256 maxDeposit = vm.envUint("MAX_SINGLE_DEPOSIT");
        string memory vaultName = vm.envString("VAULT_NAME");
        string memory vaultSymbol = vm.envString("VAULT_SYMBOL");

        VaultFactory factory = VaultFactory(factoryAddr);

        vm.startBroadcast();

        address vault = factory.createVault(
            counterpartToken,
            counterpartTokenIndex,
            counterpartSpotMarketIndex,
            hypeTokenIndex,
            hypeSpotMarketIndex,
            usdcTokenIndex,
            counterpartSzDecimals,
            counterpartWeiDecimals,
            counterpartEvmDecimals,
            maxDeposit,
            vaultName,
            vaultSymbol
        );

        vm.stopBroadcast();

        console.log("Vault created:", vault);
    }
}
