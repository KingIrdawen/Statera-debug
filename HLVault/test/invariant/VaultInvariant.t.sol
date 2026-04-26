// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "forge-std/Test.sol";
import "../integration/VaultTestBase.sol";
import {RebalancingVault} from "../../src/core/RebalancingVault.sol";

contract VaultHandler is Test {
    RebalancingVault public vault;
    address public keeper;
    address[] public actors;

    uint256 public totalDeposited;
    uint256 public totalSettledHype;

    uint64 constant L1_BLOCK_PRECOMPILE = 0x0809;

    constructor(RebalancingVault _vault, address _keeper, address[] memory _actors) {
        vault = _vault;
        keeper = _keeper;
        actors = _actors;
    }

    function deposit(uint256 actorSeed, uint256 amount) external {
        address actor = actors[actorSeed % actors.length];
        amount = bound(amount, 0.01 ether, 10 ether);

        (, RebalancingVault.RebalancePhase phase,,,,,, ) = vault.currentCycle();
        if (phase != RebalancingVault.RebalancePhase.IDLE) return;
        if (vault.emergencyMode()) return;
        if (vault.processingBatchCount() > 0) return;
        (, RebalancingVault.SettlementPhase sPhase,,,) = vault.currentSettlement();
        if (sPhase != RebalancingVault.SettlementPhase.NONE) return;

        vm.deal(actor, amount);
        vm.prank(actor);
        try vault.deposit{value: amount}() {
            totalDeposited += amount;
        } catch {}
    }

    function requestRedeem(uint256 actorSeed, uint256 sharesFraction) external {
        address actor = actors[actorSeed % actors.length];
        uint256 balance = vault.balanceOf(actor);
        if (balance == 0) return;

        uint256 shares = bound(sharesFraction, 1, balance);
        vm.prank(actor);
        try vault.requestRedeem(shares) {} catch {}
    }

    function keeperPing() external {
        vm.prank(keeper);
        try vault.keeperPing() {} catch {}
    }

    // ═══ Advance rebalance ═══

    function advanceRebalance() external {
        if (vault.emergencyMode()) return;

        _advanceL1Block();

        vm.prank(keeper);
        try vault.advanceRebalance() {} catch {}
    }

    function abortCycle() external {
        (, RebalancingVault.RebalancePhase phase,,,,,, ) = vault.currentCycle();
        if (phase == RebalancingVault.RebalancePhase.IDLE) return;

        vm.prank(keeper);
        try vault.abortCycle() {} catch {}
    }

    // ═══ Advance batch settlement ═══

    function advanceBatchSettlement() external {
        if (vault.emergencyMode()) return;

        _advanceL1Block();

        vm.prank(keeper);
        try vault.advanceBatchSettlement() {} catch {}
    }

    function abortSettlement() external {
        (, RebalancingVault.SettlementPhase sPhase,,,) = vault.currentSettlement();
        if (sPhase == RebalancingVault.SettlementPhase.NONE) return;

        vm.prank(keeper);
        try vault.abortSettlement() {} catch {}
    }

    function claimBatch(uint256 actorSeed, uint256 redeemId) external {
        address actor = actors[actorSeed % actors.length];
        redeemId = bound(redeemId, 0, vault.nextRedeemId());

        vm.prank(actor);
        try vault.claimBatch(redeemId) {} catch {}
    }

    // ═══ Emergency ═══

    function enterEmergency() external {
        if (vault.emergencyMode()) return;
        vm.warp(block.timestamp + 25 hours);
        try vault.enterEmergency() {} catch {}
    }

    function advanceEmergency() external {
        if (!vault.emergencyMode()) return;

        _advanceL1Block();

        vm.prank(keeper);
        try vault.advanceEmergency() {} catch {}
    }

    function _advanceL1Block() internal {
        uint64 current = vault.getL1BlockNumber();
        vm.store(
            address(0x0000000000000000000000000000000000000809),
            bytes32(uint256(4)),
            bytes32(uint256(current + 1))
        );
    }
}

contract VaultInvariantTest is VaultTestBase {
    VaultHandler public handler;

    function setUp() public override {
        super.setUp();

        address[] memory actors = new address[](3);
        actors[0] = alice;
        actors[1] = bob;
        actors[2] = address(0xE);
        vm.deal(actors[2], 100 ether);

        handler = new VaultHandler(vault, keeper, actors);

        targetContract(address(handler));
    }

    /// @dev balance >= reservedHypeForClaims
    function invariant_balanceCoversReserved() public view {
        assertGe(address(vault).balance, vault.reservedHypeForClaims());
    }

    /// @dev totalSupply == circulatingShares + escrowedShares
    function invariant_supplyConsistency() public view {
        assertEq(vault.totalSupply(), vault.circulatingShares() + vault.escrowedShares());
    }

    /// @dev reservedHypeForClaims should never exceed total vault balance
    function invariant_reservedNeverExceedsBalance() public view {
        assertGe(address(vault).balance, vault.reservedHypeForClaims());
    }

    /// @dev Emergency mode and active rebalance are mutually exclusive
    function invariant_emergencyExcludesRebalance() public view {
        if (vault.emergencyMode()) {
            (, RebalancingVault.RebalancePhase phase,,,,,, ) = vault.currentCycle();
            assertEq(uint8(phase), uint8(RebalancingVault.RebalancePhase.IDLE));
        }
    }

    /// @dev For each settled batch: remainingHype <= totalHypeRecovered
    function invariant_settledBatchHypeConsistency() public view {
        uint256 currentBatch = vault.currentBatchId();
        for (uint256 i = 0; i < currentBatch && i < 20; i++) {
            (
                uint256 totalEscrowedShares,
                ,
                uint256 totalHypeRecovered,
                uint256 remainingHypeForClaims,
                ,
                ,
                RebalancingVault.BatchStatus status
            ) = vault.batches(i);
            if (status == RebalancingVault.BatchStatus.SETTLED) {
                assertLe(remainingHypeForClaims, totalHypeRecovered);
                assertGt(totalEscrowedShares, 0);
            }
        }
    }

    /// @dev For each settled batch: claimedShares <= totalEscrowedShares
    function invariant_settledBatchSharesConsistency() public view {
        uint256 currentBatch = vault.currentBatchId();
        for (uint256 i = 0; i < currentBatch && i < 20; i++) {
            (
                uint256 totalEscrowedShares,
                uint256 claimedShares,
                ,
                ,
                ,
                ,
                RebalancingVault.BatchStatus status
            ) = vault.batches(i);
            if (status == RebalancingVault.BatchStatus.SETTLED) {
                assertLe(claimedShares, totalEscrowedShares);
            }
        }
    }

    /// @dev Share price should never be zero when there are circulating shares
    function invariant_sharePriceNonZeroWithShares() public view {
        if (vault.circulatingShares() > 0) {
            assertGt(vault.sharePriceUsdc8(), 0);
        }
    }

    /// @dev Phase transitions must follow the valid state machine order
    function invariant_validPhaseTransitions() public view {
        (, RebalancingVault.RebalancePhase phase,,,,,, ) = vault.currentCycle();
        assertTrue(uint8(phase) <= 7, "phase out of range");
    }

    /// @dev Settlement phase must be in valid range
    function invariant_validSettlementPhase() public view {
        (, RebalancingVault.SettlementPhase sPhase,,,) = vault.currentSettlement();
        assertTrue(uint8(sPhase) <= 7, "settlement phase out of range");
    }

    /// @dev Emergency phase must be in valid range
    function invariant_validEmergencyPhase() public view {
        assertTrue(vault.emergencyPhaseRaw() <= 7, "emergency phase out of range");
    }
}
