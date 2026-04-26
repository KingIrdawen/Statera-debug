// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "./VaultTestBase.sol";
import {RebalancingVault} from "../../src/core/RebalancingVault.sol";
import {MockCoreWriter} from "../mocks/MockCoreWriter.sol";

contract EmergencyModeTest is VaultTestBase {
    function test_isEmergency_heartbeatExpired() public {
        _deposit(alice, 10 ether);
        vm.warp(block.timestamp + 25 hours);
        assertTrue(vault.isEmergency());
    }

    function test_isEmergency_notExpired() public view {
        assertFalse(vault.isEmergency());
    }

    function test_enterEmergency() public {
        _deposit(alice, 10 ether);
        vm.warp(block.timestamp + 25 hours);

        vault.enterEmergency();
        assertTrue(vault.emergencyMode());
        assertTrue(vault.paused());
    }

    function test_enterEmergency_conditionsNotMetReverts() public {
        vm.expectRevert(abi.encodeWithSelector(RebalancingVault.ConditionsNotMet.selector));
        vault.enterEmergency();
    }

    function test_enterEmergency_abortsActiveCycle() public {
        _deposit(alice, 10 ether);

        // Start rebalance via advanceRebalance
        vm.prank(keeper);
        vault.advanceRebalance();

        vm.warp(block.timestamp + 25 hours);
        vault.enterEmergency();

        (, RebalancingVault.RebalancePhase phase,,,,,, ) = vault.currentCycle();
        assertEq(uint8(phase), uint8(RebalancingVault.RebalancePhase.IDLE));
    }

    function test_reclaimEscrowedShares() public {
        uint256 shares = _deposit(alice, 10 ether);

        vm.prank(alice);
        vault.requestRedeem(shares);

        vm.warp(block.timestamp + 25 hours);
        vault.enterEmergency();

        vm.prank(alice);
        vault.reclaimEscrowedShares(0);

        assertEq(vault.balanceOf(alice), shares);
        assertEq(vault.escrowedShares(), 0);
    }

    function test_fullEmergencyFlow_viaAdvanceEmergency() public {
        // Type A: alice holds shares in wallet
        uint256 aliceShares = _deposit(alice, 10 ether);
        // Type B: bob has shares in escrow
        uint256 bobShares = _deposit(bob, 5 ether);
        vm.prank(bob);
        vault.requestRedeem(bobShares);

        // Enter emergency
        vm.warp(block.timestamp + 25 hours);
        vault.enterEmergency();

        // Bob reclaims escrowed shares (type B -> becomes type A)
        vm.prank(bob);
        vault.reclaimEscrowedShares(0);
        assertEq(vault.balanceOf(bob), bobShares);

        // Set TOKEN on Core for liquidation
        _setSpotBalance(address(vault), PURR_TOKEN_INDEX, 12000000000, 0);

        // Call 1: sell TOKEN → USDC
        vm.prank(keeper);
        vault.advanceEmergency();
        assertEq(vault.emergencyPhaseRaw(), uint8(RebalancingVault.EmergencyPhase.AWAITING_LIQUIDATION));

        // Simulate sell completed
        _setSpotBalance(address(vault), PURR_TOKEN_INDEX, 0, 0);
        _setSpotBalance(address(vault), USDC_TOKEN_INDEX, 1200000000, 0);
        _setL1Block(101);

        // Call 2: buy HYPE with USDC
        vm.prank(keeper);
        vault.advanceEmergency();
        assertEq(vault.emergencyPhaseRaw(), uint8(RebalancingVault.EmergencyPhase.AWAITING_BUY_HYPE));

        // Simulate buy completed
        _setSpotBalance(address(vault), USDC_TOKEN_INDEX, 0, 0);
        _setSpotBalance(address(vault), HYPE_TOKEN_INDEX, 48000000, 0);
        _setL1Block(102);

        // Call 3: bridge HYPE Core→EVM
        vm.prank(keeper);
        vault.advanceEmergency();
        assertEq(vault.emergencyPhaseRaw(), uint8(RebalancingVault.EmergencyPhase.AWAITING_BRIDGE));

        // Simulate bridge completed
        _setSpotBalance(address(vault), HYPE_TOKEN_INDEX, 0, 0);
        vm.deal(address(vault), address(vault).balance + 0.48 ether);
        _setL1Block(103);

        // Call 4: finalize recovery
        vm.prank(keeper);
        vault.advanceEmergency();
        assertTrue(vault.recoveryComplete());

        // Both claim recovery
        uint256 aliceBefore = alice.balance;
        vm.prank(alice);
        vault.claimRecovery();
        uint256 aliceReceived = alice.balance - aliceBefore;

        uint256 bobBefore = bob.balance;
        vm.prank(bob);
        vault.claimRecovery();
        uint256 bobReceived = bob.balance - bobBefore;

        assertGt(aliceReceived, bobReceived);
    }

    function test_advanceEmergency_notInEmergencyReverts() public {
        _deposit(alice, 10 ether);
        vm.prank(keeper);
        vm.expectRevert(abi.encodeWithSelector(RebalancingVault.NotInEmergency.selector));
        vault.advanceEmergency();
    }

    function test_advanceEmergency_ownerCanCall() public {
        _deposit(alice, 10 ether);
        vm.warp(block.timestamp + 25 hours);
        vault.enterEmergency();

        // Owner can call advanceEmergency (not just keeper)
        vm.prank(owner);
        vault.advanceEmergency(); // Should not revert
    }

    function test_advanceEmergency_noTokenSkipsToHype() public {
        _deposit(alice, 10 ether);
        vm.warp(block.timestamp + 25 hours);
        vault.enterEmergency();

        // No TOKEN on Core, some USDC
        _setSpotBalance(address(vault), USDC_TOKEN_INDEX, 1000000000, 0);

        // Call 1: skips selling (no TOKEN), buys HYPE with USDC
        vm.prank(keeper);
        vault.advanceEmergency();
        assertEq(vault.emergencyPhaseRaw(), uint8(RebalancingVault.EmergencyPhase.AWAITING_BUY_HYPE));
    }

    function test_advanceEmergency_nothingOnCore() public {
        _deposit(alice, 10 ether);
        vm.warp(block.timestamp + 25 hours);
        vault.enterEmergency();

        // Nothing on Core → finalize directly
        vm.prank(keeper);
        vault.advanceEmergency();
        assertTrue(vault.recoveryComplete());
    }

    function test_claimRecovery_notReadyReverts() public {
        _deposit(alice, 10 ether);
        vm.warp(block.timestamp + 25 hours);
        vault.enterEmergency();

        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(RebalancingVault.NotReady.selector));
        vault.claimRecovery();
    }
}
