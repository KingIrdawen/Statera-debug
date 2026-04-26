// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "./VaultTestBase.sol";
import {VaultFactory} from "../../src/core/VaultFactory.sol";
import {RebalancingVault} from "../../src/core/RebalancingVault.sol";

contract RebalancingVaultFactoryTest is VaultTestBase {
    function test_factoryCreatesVault() public view {
        assertEq(factory.vaultCount(), 1);
        assertEq(factory.vaults(address(counterpartToken)), address(vault));
        assertEq(factory.allVaults(0), address(vault));
    }

    function test_factoryDuplicateReverts() public {
        vm.prank(owner);
        vm.expectRevert("vault exists");
        factory.createVault(
            address(counterpartToken),
            PURR_TOKEN_INDEX, PURR_SPOT_MARKET_INDEX,
            HYPE_TOKEN_INDEX, HYPE_SPOT_MARKET_INDEX, USDC_TOKEN_INDEX,
            PURR_SZ_DECIMALS, PURR_WEI_DECIMALS, PURR_EVM_DECIMALS,
            MAX_DEPOSIT, "dup", "DUP"
        );
    }

    function test_factorySetKeeper() public {
        address newKeeper = address(0xF);
        vm.prank(owner);
        factory.setKeeper(newKeeper);
        assertEq(factory.keeper(), newKeeper);
    }

    function test_factoryTransferOwnership() public {
        address newOwner = address(0xE);
        vm.prank(owner);
        factory.transferOwnership(newOwner);

        vm.prank(newOwner);
        factory.acceptOwnership();
        assertEq(factory.owner(), newOwner);
    }

    function test_globalPause() public {
        vm.prank(owner);
        factory.setGlobalPause(true);

        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(RebalancingVault.VaultPaused.selector));
        vault.deposit{value: 1 ether}();
    }

    function test_vaultAdmin_setSlippage() public {
        vm.prank(owner);
        vault.setSlippage(300);
        assertEq(vault.slippageBps(), 300);
    }

    function test_vaultAdmin_setSlippageExceedsCapReverts() public {
        vm.prank(owner);
        vm.expectRevert(abi.encodeWithSelector(RebalancingVault.ExceedsMax.selector));
        vault.setSlippage(1600);
    }

    function test_vaultAdmin_setMaxDeposit() public {
        vm.prank(owner);
        vault.setMaxSingleDeposit(500 ether);
        assertEq(vault.maxSingleDepositHype18(), 500 ether);
    }

    function test_vaultAdmin_rescueToken() public {
        ERC20Mock random = new ERC20Mock("RAND", "RAND", 18);
        random.mint(address(vault), 100e18);

        vm.prank(owner);
        vault.rescueToken(address(random), 100e18);
        assertEq(random.balanceOf(owner), 100e18);
    }

    function test_vaultAdmin_pauseUnpause() public {
        vm.prank(owner);
        vault.pause();
        assertTrue(vault.paused());

        vm.prank(owner);
        vault.unpause();
        assertFalse(vault.paused());
    }

    function test_initializeCannotBeCalledTwice() public {
        vm.expectRevert();
        vault.initialize(
            address(factory),
            address(counterpartToken),
            PURR_TOKEN_INDEX, PURR_SPOT_MARKET_INDEX,
            HYPE_TOKEN_INDEX, HYPE_SPOT_MARKET_INDEX, USDC_TOKEN_INDEX,
            PURR_SZ_DECIMALS, PURR_WEI_DECIMALS, PURR_EVM_DECIMALS,
            MAX_DEPOSIT, "dup", "DUP"
        );
    }
}
