// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "./VaultTestBase.sol";
import {RebalancingVault} from "../../src/core/RebalancingVault.sol";

contract E2ESimulationTest is VaultTestBase {
    address public charlie = address(0xE);

    function setUp() public override {
        super.setUp();
        vm.deal(charlie, 100 ether);
    }

    function test_fullLifecycle() public {
        // ── 1. Multiple deposits ──
        uint256 aliceShares = _deposit(alice, 10 ether);
        uint256 bobShares = _deposit(bob, 5 ether);
        uint256 charlieShares = _deposit(charlie, 3 ether);

        assertEq(vault.totalSupply(), aliceShares + bobShares + charlieShares);

        // ── 2. Rebalance cycle via advanceRebalance ──
        vm.prank(keeper);
        vault.advanceRebalance();
        (, RebalancingVault.RebalancePhase phase1,,,,,,) = vault.currentCycle();
        assertEq(uint8(phase1), uint8(RebalancingVault.RebalancePhase.AWAITING_BRIDGE_IN));

        _setSpotBalance(address(vault), HYPE_TOKEN_INDEX, 500000000, 0);
        _setL1Block(101);

        vm.prank(keeper);
        vault.advanceRebalance(); // → AWAITING_TRADES

        _setSpotBalance(address(vault), HYPE_TOKEN_INDEX, 0, 0);
        _setSpotBalance(address(vault), PURR_TOKEN_INDEX, 12000000000, 0);
        _setL1Block(102);

        vm.prank(keeper);
        vault.advanceRebalance(); // → IDLE (no HYPE on Core)

        (, RebalancingVault.RebalancePhase phase2,,,,,,) = vault.currentCycle();
        assertEq(uint8(phase2), uint8(RebalancingVault.RebalancePhase.IDLE));

        // ── 3. Alice requests redeem ──
        vm.prank(alice);
        vault.requestRedeem(aliceShares);

        // ── 4. Settlement via advanceBatchSettlement (4 calls) ──
        // Call 1: close batch + sell TOKEN
        _setSpotBalance(address(vault), PURR_TOKEN_INDEX, 12000000000, 0);
        vm.prank(keeper);
        vault.advanceBatchSettlement();

        // Simulate sell completed → USDC received
        _setSpotBalance(address(vault), PURR_TOKEN_INDEX, 0, 0);
        _setSpotBalance(address(vault), USDC_TOKEN_INDEX, 1200000000, 0);
        _setL1Block(103);

        // Call 2: buy HYPE with USDC
        vm.prank(keeper);
        vault.advanceBatchSettlement();

        // Simulate buy completed → HYPE received
        _setSpotBalance(address(vault), USDC_TOKEN_INDEX, 0, 0);
        _setSpotBalance(address(vault), HYPE_TOKEN_INDEX, 48000000, 0);
        _setL1Block(104);

        // Call 3: bridge HYPE Core→EVM
        vm.prank(keeper);
        vault.advanceBatchSettlement();

        _setSpotBalance(address(vault), HYPE_TOKEN_INDEX, 0, 0);
        vm.deal(address(vault), address(vault).balance + 0.48 ether);
        _setL1Block(105);

        // Call 4: settle batch
        vm.prank(keeper);
        vault.advanceBatchSettlement();

        // ── 5. Alice claims ──
        uint256 aliceBefore = alice.balance;
        vm.prank(alice);
        vault.claimBatch(0);
        assertTrue(alice.balance > aliceBefore);

        // ── 6. Bob and Charlie are still holders ──
        assertEq(vault.balanceOf(bob), bobShares);
        assertEq(vault.balanceOf(charlie), charlieShares);

        // ── 7. Invariants hold ──
        assertGe(address(vault).balance, vault.reservedHypeForClaims());
        assertEq(vault.escrowedShares(), 0);
    }

    function test_depositAfterBatchSettlement() public {
        uint256 aliceShares = _deposit(alice, 10 ether);

        vm.prank(alice);
        vault.requestRedeem(aliceShares);

        // Settlement: no TOKEN/USDC on Core, settle with EVM HYPE
        vm.prank(keeper);
        vault.advanceBatchSettlement();

        (, RebalancingVault.SettlementPhase sPhase,,,) = vault.currentSettlement();
        assertEq(uint8(sPhase), uint8(RebalancingVault.SettlementPhase.NONE));

        // New deposit should work
        uint256 newShares = _deposit(bob, 5 ether);
        assertGt(newShares, 0);
    }
}
