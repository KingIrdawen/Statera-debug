// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "./VaultTestBase.sol";
import {RebalancingVault} from "../../src/core/RebalancingVault.sol";

contract BatchSettlementTest is VaultTestBase {
    uint256 aliceShares;
    uint256 bobShares;

    function setUp() public override {
        super.setUp();

        aliceShares = _deposit(alice, 10 ether);
        bobShares = _deposit(bob, 5 ether);

        vm.prank(alice);
        vault.requestRedeem(aliceShares);
        vm.prank(bob);
        vault.requestRedeem(bobShares);
    }

    function test_settlementCompleteFlow() public {
        // Call 1: close batch + settle directly (no TOKEN/USDC on Core)
        // All HYPE is on EVM, so settlement completes in one call
        vm.prank(keeper);
        vault.advanceBatchSettlement();

        // Settlement should be complete (settled with free EVM HYPE)
        (, RebalancingVault.SettlementPhase phase,,,) = vault.currentSettlement();
        assertEq(uint8(phase), uint8(RebalancingVault.SettlementPhase.NONE));

        // Batch should be settled
        (,,,,,,RebalancingVault.BatchStatus status) = vault.batches(0);
        assertEq(uint8(status), uint8(RebalancingVault.BatchStatus.SETTLED));

        // Users can claim
        uint256 aliceBefore = alice.balance;
        vm.prank(alice);
        vault.claimBatch(0);
        assertGt(alice.balance, aliceBefore);

        uint256 bobBefore = bob.balance;
        vm.prank(bob);
        vault.claimBatch(1);
        assertGt(bob.balance, bobBefore);
    }

    function test_settlementWithTokenSell() public {
        // Set TOKEN on Core — needs to be sold
        _setSpotBalance(address(vault), PURR_TOKEN_INDEX, 12000000000, 0);

        // Call 1: close batch + sell TOKEN
        vm.prank(keeper);
        vault.advanceBatchSettlement();

        (, RebalancingVault.SettlementPhase phase1,,,) = vault.currentSettlement();
        assertEq(uint8(phase1), uint8(RebalancingVault.SettlementPhase.AWAITING_SELL));

        // Simulate sell → USDC
        _setSpotBalance(address(vault), PURR_TOKEN_INDEX, 0, 0);
        _setSpotBalance(address(vault), USDC_TOKEN_INDEX, 1200000000, 0);
        _setL1Block(101);

        // Call 2: buy HYPE
        vm.prank(keeper);
        vault.advanceBatchSettlement();

        (, RebalancingVault.SettlementPhase phase2,,,) = vault.currentSettlement();
        assertEq(uint8(phase2), uint8(RebalancingVault.SettlementPhase.AWAITING_BUY));

        // Simulate buy → HYPE on Core
        _setSpotBalance(address(vault), USDC_TOKEN_INDEX, 0, 0);
        _setSpotBalance(address(vault), HYPE_TOKEN_INDEX, 48000000, 0);
        _setL1Block(102);

        // Call 3: bridge HYPE
        vm.prank(keeper);
        vault.advanceBatchSettlement();

        (, RebalancingVault.SettlementPhase phase3,,,) = vault.currentSettlement();
        assertEq(uint8(phase3), uint8(RebalancingVault.SettlementPhase.AWAITING_BRIDGE));

        // Simulate bridge completed
        _setSpotBalance(address(vault), HYPE_TOKEN_INDEX, 0, 0);
        vm.deal(address(vault), address(vault).balance + 0.48 ether);
        _setL1Block(103);

        // Call 4: settle
        vm.prank(keeper);
        vault.advanceBatchSettlement();

        (, RebalancingVault.SettlementPhase phase4,,,) = vault.currentSettlement();
        assertEq(uint8(phase4), uint8(RebalancingVault.SettlementPhase.NONE));
    }

    function test_settlement_noop_emptyBatch() public {
        // First, settle the current batch to clear it
        vm.prank(keeper);
        vault.advanceBatchSettlement();

        // Now batch 1 is OPEN with no shares — should be a no-op
        vm.prank(keeper);
        vault.advanceBatchSettlement();

        // No settlement started
        (, RebalancingVault.SettlementPhase phase,,,) = vault.currentSettlement();
        assertEq(uint8(phase), uint8(RebalancingVault.SettlementPhase.NONE));
    }

    function test_settlement_l1NotAdvanced_reverts() public {
        _setSpotBalance(address(vault), PURR_TOKEN_INDEX, 12000000000, 0);

        vm.prank(keeper);
        vault.advanceBatchSettlement(); // AWAITING_SELL

        // Try to advance without L1 progress
        vm.prank(keeper);
        vm.expectRevert(abi.encodeWithSelector(RebalancingVault.L1NotAdvanced.selector));
        vault.advanceBatchSettlement();
    }

    function test_settlement_blockedDuringRebalance() public {
        // Start rebalance first (need HYPE on EVM only = drift)
        vm.prank(keeper);
        vault.advanceRebalance();

        // Settlement should revert
        vm.prank(keeper);
        vm.expectRevert(abi.encodeWithSelector(RebalancingVault.CycleInProgress.selector));
        vault.advanceBatchSettlement();
    }

    function test_settlement_onlyKeeper() public {
        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(RebalancingVault.NotKeeper.selector));
        vault.advanceBatchSettlement();
    }

    function test_claimBatch_notOwnerReverts() public {
        vm.prank(keeper);
        vault.advanceBatchSettlement();

        vm.prank(bob);
        vm.expectRevert(abi.encodeWithSelector(RebalancingVault.NotReqOwner.selector));
        vault.claimBatch(0); // redeemId 0 belongs to alice
    }

    function test_claimBatch_doubleClaimReverts() public {
        vm.prank(keeper);
        vault.advanceBatchSettlement();

        vm.prank(alice);
        vault.claimBatch(0);

        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(RebalancingVault.AlreadyClaimed.selector));
        vault.claimBatch(0);
    }

    function test_processingBatchCount() public {
        // Start settlement (batch moves to PROCESSING)
        _setSpotBalance(address(vault), PURR_TOKEN_INDEX, 12000000000, 0);
        vm.prank(keeper);
        vault.advanceBatchSettlement();

        // Batch is PROCESSING during settlement
        assertGt(vault.processingBatchCount(), 0);

        // Complete settlement
        _setSpotBalance(address(vault), PURR_TOKEN_INDEX, 0, 0);
        _setSpotBalance(address(vault), USDC_TOKEN_INDEX, 0, 0);
        _setL1Block(101);
        vm.prank(keeper);
        vault.advanceBatchSettlement(); // try buy (no USDC) → try bridge

        _setL1Block(102);

        // Continue advancing until settlement completes
        vm.prank(keeper);
        vault.advanceBatchSettlement();

        assertEq(vault.processingBatchCount(), 0);
    }

    function test_abortSettlement() public {
        _setSpotBalance(address(vault), PURR_TOKEN_INDEX, 12000000000, 0);
        vm.prank(keeper);
        vault.advanceBatchSettlement(); // AWAITING_SELL

        // Keeper aborts
        vm.prank(keeper);
        vault.abortSettlement();

        (, RebalancingVault.SettlementPhase phase,,,) = vault.currentSettlement();
        assertEq(uint8(phase), uint8(RebalancingVault.SettlementPhase.NONE));
    }

    function test_abortSettlement_notAuthorizedReverts() public {
        _setSpotBalance(address(vault), PURR_TOKEN_INDEX, 12000000000, 0);
        vm.prank(keeper);
        vault.advanceBatchSettlement();

        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(RebalancingVault.NotKeeper.selector));
        vault.abortSettlement();
    }
}
