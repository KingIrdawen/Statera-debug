// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "./VaultTestBase.sol";
import {RebalancingVault} from "../../src/core/RebalancingVault.sol";
import {RebalanceLib} from "../../src/libraries/RebalanceLib.sol";

contract AdvanceRebalanceTest is VaultTestBase {
    uint32 constant HYPE_ASSET = 10000 + HYPE_SPOT_MARKET_INDEX;
    uint32 constant PURR_ASSET = 10000 + PURR_SPOT_MARKET_INDEX;

    function setUp() public override {
        super.setUp();
        assertEq(vault.targetHypeBps(), 4800);
        assertEq(vault.targetTokenBps(), 4800);
        assertEq(vault.targetUsdcBps(), 400);
        assertEq(vault.driftThresholdBps(), 300);
        assertEq(vault.minRebalanceNotionalUsdc8(), 5e8);
        assertEq(vault.cycleDeadlineBlocks(), 500);
    }

    // ═══ ADMIN SETTERS ═══

    function test_setTargetAllocations() public {
        vm.prank(owner);
        vault.setTargetAllocations(5000, 4500, 500);
        assertEq(vault.targetHypeBps(), 5000);
        assertEq(vault.targetTokenBps(), 4500);
        assertEq(vault.targetUsdcBps(), 500);
    }

    function test_setTargetAllocations_mustSum100() public {
        vm.prank(owner);
        vm.expectRevert(abi.encodeWithSelector(RebalancingVault.MustSumTo100.selector));
        vault.setTargetAllocations(5000, 4500, 600);
    }

    function test_setTargetAllocations_onlyOwner() public {
        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(RebalancingVault.NotOwner.selector));
        vault.setTargetAllocations(5000, 4500, 500);
    }

    function test_setDriftThreshold() public {
        vm.prank(owner);
        vault.setDriftThreshold(500);
        assertEq(vault.driftThresholdBps(), 500);
    }

    function test_setDriftThreshold_invalidReverts() public {
        vm.prank(owner);
        vm.expectRevert(abi.encodeWithSelector(RebalancingVault.InvalidThreshold.selector));
        vault.setDriftThreshold(0);

        vm.prank(owner);
        vm.expectRevert(abi.encodeWithSelector(RebalancingVault.InvalidThreshold.selector));
        vault.setDriftThreshold(5001);
    }

    function test_setMinRebalanceNotional() public {
        vm.prank(owner);
        vault.setMinRebalanceNotional(10e8);
        assertEq(vault.minRebalanceNotionalUsdc8(), 10e8);
    }

    function test_setCycleDeadlineBlocks() public {
        vm.prank(owner);
        vault.setCycleDeadlineBlocks(1000);
        assertEq(vault.cycleDeadlineBlocks(), 1000);
    }

    function test_setCycleDeadlineBlocks_zeroReverts() public {
        vm.prank(owner);
        vm.expectRevert(abi.encodeWithSelector(RebalancingVault.ZeroDeadline.selector));
        vault.setCycleDeadlineBlocks(0);
    }

    // ═══ ADVANCE: IDLE → NO-OP ═══

    function test_advanceIdle_belowThreshold() public {
        _deposit(alice, 10 ether);

        _setSpotBalance(address(vault), HYPE_TOKEN_INDEX, 480000000, 0);
        _setSpotBalance(address(vault), PURR_TOKEN_INDEX, 12000000000, 0);
        _setSpotBalance(address(vault), USDC_TOKEN_INDEX, 1000000000, 0);
        vm.deal(address(vault), 0);

        vm.prank(keeper);
        vm.expectEmit(true, true, true, true);
        emit RebalancingVault.AutoRebalanceSkipped(0);
        vault.advanceRebalance();

        (, RebalancingVault.RebalancePhase phase,,,,,,) = vault.currentCycle();
        assertEq(uint8(phase), uint8(RebalancingVault.RebalancePhase.IDLE));
    }

    // ═══ ADVANCE: IDLE → STARTS REBALANCE ═══

    function test_advanceIdle_startsRebalance() public {
        _deposit(alice, 10 ether);

        vm.prank(keeper);
        vault.advanceRebalance();

        (, RebalancingVault.RebalancePhase phase,,,,,,) = vault.currentCycle();
        assertEq(uint8(phase), uint8(RebalancingVault.RebalancePhase.AWAITING_BRIDGE_IN));
    }

    // ═══ ADVANCE: BATCH PROCESSING BLOCKS ═══

    function test_advanceIdle_batchProcessingReverts() public {
        _deposit(alice, 10 ether);

        uint256 shares = vault.balanceOf(alice);
        vm.prank(alice);
        vault.requestRedeem(shares);

        // Start settlement (creates PROCESSING batch)
        _setSpotBalance(address(vault), PURR_TOKEN_INDEX, 12000000000, 0);
        vm.prank(keeper);
        vault.advanceBatchSettlement();

        // Abort settlement but batch is still PROCESSING
        vm.prank(keeper);
        vault.abortSettlement();

        vm.prank(keeper);
        vm.expectRevert(abi.encodeWithSelector(RebalancingVault.BatchProcessing.selector));
        vault.advanceRebalance();
    }

    // ═══ ADVANCE: NOT KEEPER REVERTS ═══

    function test_advanceNotKeeper() public {
        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(RebalancingVault.NotKeeper.selector));
        vault.advanceRebalance();
    }

    // ═══ ADVANCE: L1 NOT ADVANCED REVERTS ═══

    function test_advanceAwaitingBridge_L1NotAdvanced() public {
        _deposit(alice, 10 ether);

        vm.prank(keeper);
        vault.advanceRebalance();

        vm.prank(keeper);
        vm.expectRevert(abi.encodeWithSelector(RebalancingVault.L1NotAdvanced.selector));
        vault.advanceRebalance();
    }

    // ═══ FULL CYCLE: 3 CALLS (NO BRIDGE OUT) ═══

    function test_fullCycleViaAdvance_noBridgeOut() public {
        _deposit(alice, 10 ether);

        vm.prank(keeper);
        vault.advanceRebalance();
        (, RebalancingVault.RebalancePhase phase1,,,,,,) = vault.currentCycle();
        assertEq(uint8(phase1), uint8(RebalancingVault.RebalancePhase.AWAITING_BRIDGE_IN));

        _setSpotBalance(address(vault), HYPE_TOKEN_INDEX, 500000000, 0);
        _setL1Block(101);

        vm.prank(keeper);
        vault.advanceRebalance();
        (, RebalancingVault.RebalancePhase phase2,,,,,,) = vault.currentCycle();
        assertEq(uint8(phase2), uint8(RebalancingVault.RebalancePhase.AWAITING_TRADES));

        _setSpotBalance(address(vault), HYPE_TOKEN_INDEX, 0, 0);
        _setSpotBalance(address(vault), PURR_TOKEN_INDEX, 12000000000, 0);
        _setL1Block(102);

        vm.prank(keeper);
        vault.advanceRebalance();
        (, RebalancingVault.RebalancePhase phase3,,,,,,) = vault.currentCycle();
        assertEq(uint8(phase3), uint8(RebalancingVault.RebalancePhase.IDLE));
    }

    // ═══ FULL CYCLE: 4 CALLS (WITH BRIDGE OUT) ═══

    function test_fullCycleViaAdvance_withBridgeOut() public {
        _deposit(alice, 10 ether);

        vm.prank(keeper);
        vault.advanceRebalance();

        _setSpotBalance(address(vault), HYPE_TOKEN_INDEX, 500000000, 0);
        _setL1Block(101);

        vm.prank(keeper);
        vault.advanceRebalance();

        _setSpotBalance(address(vault), HYPE_TOKEN_INDEX, 100000000, 0);
        _setL1Block(102);

        vm.prank(keeper);
        vault.advanceRebalance();
        (, RebalancingVault.RebalancePhase phase3,,,,,,) = vault.currentCycle();
        assertEq(uint8(phase3), uint8(RebalancingVault.RebalancePhase.AWAITING_BRIDGE_OUT));

        _setL1Block(103);

        vm.prank(keeper);
        vault.advanceRebalance();
        (, RebalancingVault.RebalancePhase phase4,,,,,,) = vault.currentCycle();
        assertEq(uint8(phase4), uint8(RebalancingVault.RebalancePhase.IDLE));
    }

    // ═══ NO BRIDGE IN NEEDED ═══

    function test_advanceIdle_noBridgeIn_buyHype() public {
        _deposit(alice, 1 ether);

        _setSpotBalance(address(vault), HYPE_TOKEN_INDEX, 0, 0);
        _setSpotBalance(address(vault), PURR_TOKEN_INDEX, 12000000000, 0);
        _setSpotBalance(address(vault), USDC_TOKEN_INDEX, 1000000000, 0);

        vm.prank(keeper);
        vault.advanceRebalance();

        (, RebalancingVault.RebalancePhase phase,,,,,,) = vault.currentCycle();
        assertEq(uint8(phase), uint8(RebalancingVault.RebalancePhase.AWAITING_TRADES));
    }

    // ═══ EMERGENCY BLOCKS ADVANCE ═══

    function test_advanceInEmergencyReverts() public {
        _deposit(alice, 10 ether);

        vm.warp(block.timestamp + 25 hours);
        vault.enterEmergency();

        vm.prank(keeper);
        vm.expectRevert(abi.encodeWithSelector(RebalancingVault.VaultPaused.selector));
        vault.advanceRebalance();
    }

    // ═══ SETTLEMENT BLOCKS ADVANCE ═══

    function test_advanceDuringSettlementReverts() public {
        _deposit(alice, 10 ether);

        uint256 shares = vault.balanceOf(alice);
        vm.prank(alice);
        vault.requestRedeem(shares / 2);

        _setSpotBalance(address(vault), PURR_TOKEN_INDEX, 12000000000, 0);
        vm.prank(keeper);
        vault.advanceBatchSettlement(); // AWAITING_SELL

        vm.prank(keeper);
        vm.expectRevert(abi.encodeWithSelector(RebalancingVault.SettlementInProgress.selector));
        vault.advanceRebalance();
    }
}
