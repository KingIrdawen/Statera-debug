// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "./VaultTestBase.sol";
import {RebalancingVault} from "../../src/core/RebalancingVault.sol";

contract AuditFixesTest is VaultTestBase {
    // ═══ keeperPing tests ═══

    function test_keeperPing_updatesHeartbeat() public {
        uint256 heartbeatBefore = vault.lastHeartbeat();

        vm.warp(block.timestamp + 1 hours);

        vm.prank(keeper);
        vault.keeperPing();

        assertGt(vault.lastHeartbeat(), heartbeatBefore);
        assertEq(vault.lastHeartbeat(), block.timestamp);
    }

    function test_keeperPing_preventsEmergency() public {
        vm.warp(block.timestamp + 23 hours);
        vm.prank(keeper);
        vault.keeperPing();
        vm.warp(block.timestamp + 23 hours);
        assertFalse(vault.isEmergency());
    }

    function test_keeperPing_onlyKeeper() public {
        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(RebalancingVault.NotKeeper.selector));
        vault.keeperPing();
    }

    function test_keeperPing_emergencyWithoutPing() public {
        vm.warp(block.timestamp + 25 hours);
        assertTrue(vault.isEmergency());
    }

    // ═══ reservedHypeForClaims excluded from grossAssets ═══

    function test_reservedHype_excluded_from_grossAssets() public {
        uint256 shares = _deposit(alice, 10 ether);

        vm.prank(alice);
        vault.requestRedeem(shares);

        // Settle via advanceBatchSettlement (no Core assets → settles with EVM HYPE)
        vm.prank(keeper);
        vault.advanceBatchSettlement();

        // reservedHypeForClaims should be set
        uint256 hypeRecovered = vault.reservedHypeForClaims();
        assertGt(hypeRecovered, 0);

        // grossAssets should NOT include the reserved HYPE
        uint256 gross = vault.grossAssets();

        // Add more HYPE to the vault
        vm.deal(address(vault), address(vault).balance + 5 ether);
        uint256 grossWithExtra = vault.grossAssets();

        assertGt(grossWithExtra, gross);
        // Only the extra 5 ether should count
        assertEq(grossWithExtra, 12500000000); // $125 in USDC 8-dec
    }

    function test_reservedHype_decreases_after_claim() public {
        uint256 shares = _deposit(alice, 10 ether);

        vm.prank(alice);
        vault.requestRedeem(shares);

        vm.prank(keeper);
        vault.advanceBatchSettlement();

        uint256 reservedBefore = vault.reservedHypeForClaims();

        vm.prank(alice);
        vault.claimBatch(0);

        assertLt(vault.reservedHypeForClaims(), reservedBefore);
    }

    // ═══ Multi-user batch with many redeemers ═══

    function test_multiUser_batch_10_redeemers() public {
        address[10] memory users;
        uint256[10] memory deposits;
        uint256[10] memory shareAmounts;

        for (uint256 i = 0; i < 10; i++) {
            users[i] = address(uint160(0x100 + i));
            deposits[i] = (1 + i) * 1 ether;
            vm.deal(users[i], deposits[i] + 1 ether);
        }

        uint256 totalShares;
        for (uint256 i = 0; i < 10; i++) {
            vm.prank(users[i]);
            shareAmounts[i] = vault.deposit{value: deposits[i]}();
            totalShares += shareAmounts[i];
        }

        for (uint256 i = 0; i < 10; i++) {
            vm.prank(users[i]);
            vault.requestRedeem(shareAmounts[i]);
        }

        assertEq(vault.escrowedShares(), totalShares);

        // Settle via advanceBatchSettlement
        vm.prank(keeper);
        vault.advanceBatchSettlement();

        uint256 totalHypeRecovered = vault.reservedHypeForClaims();

        // All claim
        uint256 totalClaimed;
        for (uint256 i = 0; i < 10; i++) {
            uint256 balBefore = users[i].balance;
            vm.prank(users[i]);
            vault.claimBatch(i);
            uint256 claimed = users[i].balance - balBefore;
            totalClaimed += claimed;

            uint256 expected = shareAmounts[i] * totalHypeRecovered / totalShares;
            assertEq(claimed, expected);
        }

        assertApproxEqAbs(totalClaimed, totalHypeRecovered, 10);
        assertEq(vault.escrowedShares(), 0);
        assertEq(vault.totalSupply(), 0);
    }

    // ═══ Settlement pro-rata distribution ═══

    function test_settlement_proRata_multipleDepositors() public {
        // Alice deposits 10 HYPE, Bob deposits 10 HYPE
        uint256 aliceShares = _deposit(alice, 10 ether);
        uint256 bobShares = _deposit(bob, 10 ether);

        // Only Alice redeems (50% of shares)
        vm.prank(alice);
        vault.requestRedeem(aliceShares);

        uint256 totalSupplyBefore = vault.totalSupply();
        assertEq(totalSupplyBefore, aliceShares + bobShares);

        // Settle — no Core assets, settles with EVM HYPE
        vm.prank(keeper);
        vault.advanceBatchSettlement();

        // Alice's batch should only get ~50% of free HYPE (pro-rata)
        (uint256 totalEscrowed,, uint256 totalHypeRecovered,,,,) = vault.batches(0);
        assertEq(totalEscrowed, aliceShares);

        // totalHypeRecovered should be ~50% of vault balance (not 100%)
        // Vault had 20 HYPE; Alice's batch should get ~10 HYPE
        uint256 expectedBatchHype = 20 ether * aliceShares / totalSupplyBefore;
        assertEq(totalHypeRecovered, expectedBatchHype);

        // Bob should still have his shares and the vault should have his HYPE
        assertEq(vault.balanceOf(bob), bobShares);

        // Alice claims
        uint256 aliceBefore = alice.balance;
        vm.prank(alice);
        vault.claimBatch(0);
        uint256 aliceClaimed = alice.balance - aliceBefore;

        // Alice should receive ~10 HYPE (her 50% share)
        assertApproxEqAbs(aliceClaimed, 10 ether, 1e15); // 0.001 HYPE tolerance
    }

    function test_settlement_proRata_singleDepositor() public {
        // Only Alice deposits and redeems — should get 100%
        uint256 aliceShares = _deposit(alice, 10 ether);

        vm.prank(alice);
        vault.requestRedeem(aliceShares);

        vm.prank(keeper);
        vault.advanceBatchSettlement();

        (,, uint256 totalHypeRecovered,,,,) = vault.batches(0);

        // Single depositor = 100% of free HYPE
        assertEq(totalHypeRecovered, 10 ether);

        uint256 aliceBefore = alice.balance;
        vm.prank(alice);
        vault.claimBatch(0);
        assertEq(alice.balance - aliceBefore, 10 ether);
    }

    function test_settlement_proRata_partialRedeem() public {
        // Alice deposits 10 HYPE, redeems only 30% of her shares
        uint256 aliceShares = _deposit(alice, 10 ether);
        uint256 redeemAmount = aliceShares * 30 / 100;

        vm.prank(alice);
        vault.requestRedeem(redeemAmount);

        uint256 totalSupplyBefore = vault.totalSupply();

        vm.prank(keeper);
        vault.advanceBatchSettlement();

        (uint256 totalEscrowed,, uint256 totalHypeRecovered,,,,) = vault.batches(0);
        assertEq(totalEscrowed, redeemAmount);

        // Batch should get 30% of free HYPE
        uint256 expectedBatchHype = 10 ether * redeemAmount / totalSupplyBefore;
        assertEq(totalHypeRecovered, expectedBatchHype);

        // Alice still has 70% of shares
        assertEq(vault.balanceOf(alice), aliceShares - redeemAmount);
    }

    // ═══ Sequential batches ═══

    function test_sequential_batches() public {
        // Batch 0: alice deposits and redeems
        uint256 shares1 = _deposit(alice, 10 ether);
        vm.prank(alice);
        vault.requestRedeem(shares1);
        vm.prank(keeper);
        vault.advanceBatchSettlement();

        vm.prank(alice);
        vault.claimBatch(0);

        // Batch 1: bob deposits and redeems
        uint256 shares2 = _deposit(bob, 5 ether);
        vm.prank(bob);
        vault.requestRedeem(shares2);
        vm.prank(keeper);
        vault.advanceBatchSettlement();

        vm.prank(bob);
        vault.claimBatch(1);

        assertEq(vault.escrowedShares(), 0);
        assertTrue(address(vault).balance >= vault.reservedHypeForClaims());
    }
}
