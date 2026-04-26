// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "forge-std/Test.sol";
import {RebalancingVault} from "../../src/core/RebalancingVault.sol";
import {VaultFactory} from "../../src/core/VaultFactory.sol";
import {RebalanceLib} from "../../src/libraries/RebalanceLib.sol";
import {MockPrecompile} from "../mocks/MockPrecompile.sol";
import {MockCoreWriter} from "../mocks/MockCoreWriter.sol";
import {ERC20Mock} from "./ERC20Mock.sol";

/// @title Multi-token advanceRebalance tests
/// @notice Tests rebalancing with 3 counterpart tokens of very different characteristics:
///
///   PURR  — $0.001, szDec=0, weiDec=5,  evmDec=18  (micro-cap, huge quantities)
///   JEFF  — $1.50,  szDec=1, weiDec=9,  evmDec=8   (mid-range, non-standard evmDec)
///   SOLH  — $180,   szDec=2, weiDec=8,  evmDec=18  (high-value, small lots)
///
contract MultiTokenRebalanceTest is Test {
    // ═══ Infrastructure ═══
    VaultFactory public factory;
    MockCoreWriter public coreWriter;

    // ═══ Vaults ═══
    RebalancingVault public vPurr;
    RebalancingVault public vJeff;
    RebalancingVault public vSolh;

    // ═══ ERC20 mocks ═══
    ERC20Mock public purr;
    ERC20Mock public jeff;
    ERC20Mock public solh;

    // ═══ Addresses ═══
    address owner = address(0xA);
    address keeper = address(0xB);
    address alice = address(0xC);

    // ═══ HYPE (shared across all vaults) ═══
    uint32 constant HYPE_TI = 150; // tokenIndex
    uint32 constant HYPE_MI = 107; // spotMarketIndex
    uint32 constant USDC_TI = 0;
    uint64 constant HYPE_PX = 25_000_000; // $25 * 10^(8-2) = 25e6
    uint8 constant HYPE_SZ = 2;

    // ═══ PURR config ═══
    uint32 constant PURR_TI = 1;
    uint32 constant PURR_MI = 0;
    uint8 constant PURR_SZ = 0;
    uint8 constant PURR_WD = 5;
    uint8 constant PURR_ED = 18;
    uint64 constant PURR_PX = 100_000; // $0.001 * 10^8

    // ═══ JEFF config ═══
    uint32 constant JEFF_TI = 10;
    uint32 constant JEFF_MI = 5;
    uint8 constant JEFF_SZ = 1;
    uint8 constant JEFF_WD = 9;
    uint8 constant JEFF_ED = 8;
    uint64 constant JEFF_PX = 15_000_000; // $1.50 * 10^7

    // ═══ SOLH config ═══
    uint32 constant SOLH_TI = 20;
    uint32 constant SOLH_MI = 10;
    uint8 constant SOLH_SZ = 2;
    uint8 constant SOLH_WD = 8;
    uint8 constant SOLH_ED = 18;
    uint64 constant SOLH_PX = 180_000_000; // $180 * 10^6

    address constant CW = 0x3333333333333333333333333333333333333333;

    // ═══════════════════════════════════════════════════════════
    //                          SETUP
    // ═══════════════════════════════════════════════════════════

    function setUp() public {
        // Precompiles
        _etchPrecompiles();
        MockCoreWriter writerMock = new MockCoreWriter();
        vm.etch(CW, address(writerMock).code);
        coreWriter = MockCoreWriter(CW);

        // ERC20 mocks
        purr = new ERC20Mock("PURR", "PURR", PURR_ED);
        jeff = new ERC20Mock("JEFF", "JEFF", JEFF_ED);
        solh = new ERC20Mock("SOLH", "SOLH", SOLH_ED);

        // Prices
        _setSpotPrice(HYPE_MI, HYPE_PX);
        _setSpotPrice(PURR_MI, PURR_PX);
        _setSpotPrice(JEFF_MI, JEFF_PX);
        _setSpotPrice(SOLH_MI, SOLH_PX);
        _setL1Block(100);

        // Factory + vaults
        vm.startPrank(owner);
        RebalancingVault impl = new RebalancingVault();
        factory = new VaultFactory(address(impl), keeper);

        vPurr = _createVault(address(purr), PURR_TI, PURR_MI, PURR_SZ, PURR_WD, PURR_ED, "hlPURR");
        vJeff = _createVault(address(jeff), JEFF_TI, JEFF_MI, JEFF_SZ, JEFF_WD, JEFF_ED, "hlJEFF");
        vSolh = _createVault(address(solh), SOLH_TI, SOLH_MI, SOLH_SZ, SOLH_WD, SOLH_ED, "hlSOLH");
        vm.stopPrank();

        vm.deal(alice, 1000 ether);
    }

    function _createVault(
        address token,
        uint32 ti,
        uint32 mi,
        uint8 szd,
        uint8 wd,
        uint8 ed,
        string memory sym
    ) internal returns (RebalancingVault) {
        return RebalancingVault(
            payable(
                factory.createVault(
                    token, ti, mi, HYPE_TI, HYPE_MI, USDC_TI, szd, wd, ed, 1000 ether, string.concat("HLVault ", sym), sym
                )
            )
        );
    }

    // ═══════════════════════════════════════════════════════════
    //              PURR — $0.001, szDec=0, weiDec=5
    //              Micro-cap: huge quantities, whole units
    // ═══════════════════════════════════════════════════════════

    function test_purr_fullCycle_sellHype() public {
        // 10 HYPE deposit = $250.  100% HYPE → massive drift
        vm.prank(alice);
        vPurr.deposit{value: 10 ether}();

        // ── Call 1: IDLE → AWAITING_BRIDGE_IN (bridge HYPE for sell) ──
        vm.prank(keeper);
        vPurr.advanceRebalance();
        _assertPhase(vPurr, RebalancingVault.RebalancePhase.AWAITING_BRIDGE_IN);
        assertLt(address(vPurr).balance, 10 ether, "HYPE should be bridged");

        // Simulate bridge completion
        uint64 bridgedCore = uint64((10 ether - address(vPurr).balance) / 1e10);
        _setSpotBalance(address(vPurr), HYPE_TI, bridgedCore, 0);
        _setL1Block(101);

        // ── Call 2: AWAITING_BRIDGE_IN → AWAITING_TRADES (orders sent) ──
        uint256 cwBefore = coreWriter.callCount();
        vm.prank(keeper);
        vPurr.advanceRebalance();
        _assertPhase(vPurr, RebalancingVault.RebalancePhase.AWAITING_TRADES);

        // Verify orders
        uint256 orderCount = coreWriter.callCount() - cwBefore;
        assertGe(orderCount, 1, "at least 1 order");

        // Find HYPE sell + PURR buy
        (bool hypeSell, bool purrBuy) = (false, false);
        for (uint256 i = cwBefore; i < cwBefore + orderCount; i++) {
            (uint32 asset, bool isBuy, uint64 corePx, uint64 sz) = _decodeOrder(i);
            if (asset == 10000 + HYPE_MI) {
                assertFalse(isBuy, "HYPE should be SELL");
                assertGt(sz, 0);
                // corePx = precompilePx * 10^2 ≈ 24500000 * 100 = 2450000000
                assertApproxEqRel(corePx, 2_450_000_000, 0.02e18);
                hypeSell = true;
            }
            if (asset == 10000 + PURR_MI) {
                assertTrue(isBuy, "PURR should be BUY");
                // Huge quantity: ~120000 PURR → sz ≈ 1.2e13
                assertGt(sz, 1e12, "PURR qty should be large");
                // corePx = precompilePx * 10^0 ≈ 102000
                assertEq(corePx, 102000, "PURR corePx = px * 10^0");
                purrBuy = true;
            }
        }
        assertTrue(hypeSell, "must sell HYPE");
        assertTrue(purrBuy, "must buy PURR");

        // ── Call 3: finalize ──
        _setSpotBalance(address(vPurr), HYPE_TI, 0, 0);
        _setL1Block(102);
        vm.prank(keeper);
        vPurr.advanceRebalance();
        _assertPhase(vPurr, RebalancingVault.RebalancePhase.IDLE);
    }

    function test_purr_balanced_noRebalance() public {
        vm.prank(alice);
        vPurr.deposit{value: 10 ether}();

        // Set balanced portfolio on Core, zero EVM
        // HYPE: 48% = $120 → 4.8 HYPE → 480000000 weiDec8
        // PURR: 48% = $120 → 120000 PURR → 12e9 weiDec5
        // USDC: 4% = $10 → 1e9 weiDec8
        _setSpotBalance(address(vPurr), HYPE_TI, 480_000_000, 0);
        _setSpotBalance(address(vPurr), PURR_TI, 12_000_000_000, 0);
        _setSpotBalance(address(vPurr), USDC_TI, 1_000_000_000, 0);
        vm.deal(address(vPurr), 0);

        vm.prank(keeper);
        vm.expectEmit(true, true, true, true);
        emit RebalancingVault.AutoRebalanceSkipped(0);
        vPurr.advanceRebalance();
        _assertPhase(vPurr, RebalancingVault.RebalancePhase.IDLE);
    }

    function test_purr_largeDeposit_noOverflow() public {
        // 100 HYPE = $2500 → PURR qty ≈ 1,200,000 units. sz_1e8 ≈ 1.2e14
        vm.prank(alice);
        vPurr.deposit{value: 100 ether}();

        vm.prank(keeper);
        vPurr.advanceRebalance(); // should not overflow
        _assertPhase(vPurr, RebalancingVault.RebalancePhase.AWAITING_BRIDGE_IN);
    }

    // ═══════════════════════════════════════════════════════════
    //              JEFF — $1.50, szDec=1, weiDec=9
    //              Mid-range, 8-dec EVM token, fine lot precision
    // ═══════════════════════════════════════════════════════════

    function test_jeff_fullCycle_sellHype() public {
        vm.prank(alice);
        vJeff.deposit{value: 10 ether}();

        // ── Call 1 ──
        vm.prank(keeper);
        vJeff.advanceRebalance();
        _assertPhase(vJeff, RebalancingVault.RebalancePhase.AWAITING_BRIDGE_IN);

        uint64 bridgedCore = uint64((10 ether - address(vJeff).balance) / 1e10);
        _setSpotBalance(address(vJeff), HYPE_TI, bridgedCore, 0);
        _setL1Block(101);

        // ── Call 2 ──
        uint256 cwBefore = coreWriter.callCount();
        vm.prank(keeper);
        vJeff.advanceRebalance();
        _assertPhase(vJeff, RebalancingVault.RebalancePhase.AWAITING_TRADES);

        uint256 orderCount = coreWriter.callCount() - cwBefore;
        (bool hypeSell, bool jeffBuy) = (false, false);
        for (uint256 i = cwBefore; i < cwBefore + orderCount; i++) {
            (uint32 asset, bool isBuy, uint64 corePx, uint64 sz) = _decodeOrder(i);
            if (asset == 10000 + HYPE_MI) {
                assertFalse(isBuy, "HYPE SELL");
                assertGt(sz, 0);
                // corePx ≈ 24500000 * 10^2 = 2450000000
                assertApproxEqRel(corePx, 2_450_000_000, 0.02e18);
                hypeSell = true;
            }
            if (asset == 10000 + JEFF_MI) {
                assertTrue(isBuy, "JEFF BUY");
                // ~80 JEFF → sz ≈ 8e9 in 1e8 format
                assertGt(sz, 1e9, "JEFF sz should be significant");
                // corePx = precompilePx * 10^1 ≈ 15300000 * 10 = 153000000
                assertApproxEqRel(corePx, 153_000_000, 0.02e18);
                // Verify lot granularity: 10^(8-1) = 10^7
                assertEq(sz % 10_000_000, 0, "JEFF lot granularity 10^7");
                jeffBuy = true;
            }
        }
        assertTrue(hypeSell, "must sell HYPE");
        assertTrue(jeffBuy, "must buy JEFF");

        // ── Finalize ──
        _setSpotBalance(address(vJeff), HYPE_TI, 0, 0);
        _setL1Block(102);
        vm.prank(keeper);
        vJeff.advanceRebalance();
        _assertPhase(vJeff, RebalancingVault.RebalancePhase.IDLE);
    }

    function test_jeff_reverseDirection_tokenOverweight() public {
        // Small HYPE deposit + lots of JEFF on Core → TOKEN overweight → BUY HYPE, SELL JEFF
        vm.prank(alice);
        vJeff.deposit{value: 1 ether}(); // $25 HYPE on EVM

        // Set Core: big JEFF position, small HYPE
        // 200 JEFF * $1.50 = $300 → 200 * 1e9 = 2e11 weiDec9
        _setSpotBalance(address(vJeff), HYPE_TI, 0, 0);
        _setSpotBalance(address(vJeff), JEFF_TI, 200_000_000_000, 0); // 200 JEFF
        _setSpotBalance(address(vJeff), USDC_TI, 500_000_000, 0); // $5 USDC

        // Total value ≈ $25 + $300 + $5 = $330
        // HYPE: $25/$330 = 7.6% (target 48%) → need BUY HYPE
        // JEFF: $300/$330 = 90.9% (target 48%) → need SELL JEFF
        // No bridge in needed (buying HYPE, not selling)

        vm.prank(keeper);
        vJeff.advanceRebalance();
        // Should skip bridge and go straight to AWAITING_TRADES
        _assertPhase(vJeff, RebalancingVault.RebalancePhase.AWAITING_TRADES);
    }

    function test_jeff_balanced_noRebalance() public {
        vm.prank(alice);
        vJeff.deposit{value: 10 ether}();

        // Balanced: 48% HYPE ($120), 48% JEFF ($120), 4% USDC ($10)
        // HYPE: 480000000 weiDec8
        // JEFF: $120 / $1.50 = 80 JEFF → 80 * 1e9 = 8e10 weiDec9
        // USDC: 1e9 weiDec8
        _setSpotBalance(address(vJeff), HYPE_TI, 480_000_000, 0);
        _setSpotBalance(address(vJeff), JEFF_TI, 80_000_000_000, 0);
        _setSpotBalance(address(vJeff), USDC_TI, 1_000_000_000, 0);
        vm.deal(address(vJeff), 0);

        vm.prank(keeper);
        vm.expectEmit(true, true, true, true);
        emit RebalancingVault.AutoRebalanceSkipped(0);
        vJeff.advanceRebalance();
    }

    // ═══════════════════════════════════════════════════════════
    //              SOLH — $180, szDec=2, weiDec=8
    //              High-value: small quantities, min notional edge
    // ═══════════════════════════════════════════════════════════

    function test_solh_fullCycle_sellHype() public {
        vm.prank(alice);
        vSolh.deposit{value: 10 ether}();

        // ── Call 1 ──
        vm.prank(keeper);
        vSolh.advanceRebalance();
        _assertPhase(vSolh, RebalancingVault.RebalancePhase.AWAITING_BRIDGE_IN);

        uint64 bridgedCore = uint64((10 ether - address(vSolh).balance) / 1e10);
        _setSpotBalance(address(vSolh), HYPE_TI, bridgedCore, 0);
        _setL1Block(101);

        // ── Call 2 ──
        uint256 cwBefore = coreWriter.callCount();
        vm.prank(keeper);
        vSolh.advanceRebalance();
        _assertPhase(vSolh, RebalancingVault.RebalancePhase.AWAITING_TRADES);

        uint256 orderCount = coreWriter.callCount() - cwBefore;
        (bool hypeSell, bool solhBuy) = (false, false);
        for (uint256 i = cwBefore; i < cwBefore + orderCount; i++) {
            (uint32 asset, bool isBuy, uint64 corePx, uint64 sz) = _decodeOrder(i);
            if (asset == 10000 + HYPE_MI) {
                assertFalse(isBuy, "HYPE SELL");
                hypeSell = true;
            }
            if (asset == 10000 + SOLH_MI) {
                assertTrue(isBuy, "SOLH BUY");
                // ~0.66 SOLH → sz ≈ 66000000 in 1e8 format (small!)
                assertLt(sz, 100_000_000, "SOLH sz should be < 1 unit");
                assertGt(sz, 5_000_000, "SOLH sz should be > 0.05");
                // Verify lot granularity: 10^(8-2) = 10^6
                assertEq(sz % 1_000_000, 0, "SOLH lot granularity 10^6");
                // corePx = precompilePx * 10^2 ≈ 183600000 * 100 = 18360000000
                assertApproxEqRel(corePx, 18_360_000_000, 0.02e18);
                solhBuy = true;
            }
        }
        assertTrue(hypeSell, "must sell HYPE");
        assertTrue(solhBuy, "must buy SOLH");

        // ── Finalize ──
        _setSpotBalance(address(vSolh), HYPE_TI, 0, 0);
        _setL1Block(102);
        vm.prank(keeper);
        vSolh.advanceRebalance();
        _assertPhase(vSolh, RebalancingVault.RebalancePhase.IDLE);
    }

    function test_solh_tinyDeposit_belowMinNotional() public {
        // 0.5 HYPE = $12.50 total. Target SOLH = 48% = $6 → below $10 min notional
        vm.prank(alice);
        vSolh.deposit{value: 0.5 ether}();

        // Both orders (sell $6.50 HYPE, buy $6 SOLH) fail min notional → skip
        vm.prank(keeper);
        vm.expectEmit(true, true, true, true);
        emit RebalancingVault.AutoRebalanceSkipped(1); // reason=1: no valid orders
        vSolh.advanceRebalance();
        _assertPhase(vSolh, RebalancingVault.RebalancePhase.IDLE);
    }

    function test_solh_fullCycle_withBridgeOut() public {
        vm.prank(alice);
        vSolh.deposit{value: 10 ether}();

        // ── Call 1: bridge in ──
        vm.prank(keeper);
        vSolh.advanceRebalance();

        uint64 bridgedCore = uint64((10 ether - address(vSolh).balance) / 1e10);
        _setSpotBalance(address(vSolh), HYPE_TI, bridgedCore, 0);
        _setL1Block(101);

        // ── Call 2: trades ──
        vm.prank(keeper);
        vSolh.advanceRebalance();

        // After trade simulation: 1 HYPE remains on Core (partial fill)
        _setSpotBalance(address(vSolh), HYPE_TI, 100_000_000, 0); // 1 HYPE on Core
        _setL1Block(102);

        // ── Call 3: bridge out ──
        vm.prank(keeper);
        vSolh.advanceRebalance();
        _assertPhase(vSolh, RebalancingVault.RebalancePhase.AWAITING_BRIDGE_OUT);

        _setL1Block(103);

        // ── Call 4: finalize ──
        vm.prank(keeper);
        vSolh.advanceRebalance();
        _assertPhase(vSolh, RebalancingVault.RebalancePhase.IDLE);
    }

    function test_solh_balanced_noRebalance() public {
        vm.prank(alice);
        vSolh.deposit{value: 10 ether}();

        // Balanced: HYPE $120, SOLH $120, USDC $10
        // SOLH: $120 / $180 = 0.6667 SOLH → 66666666 weiDec8
        _setSpotBalance(address(vSolh), HYPE_TI, 480_000_000, 0);
        _setSpotBalance(address(vSolh), SOLH_TI, 66_666_666, 0);
        _setSpotBalance(address(vSolh), USDC_TI, 1_000_000_000, 0);
        vm.deal(address(vSolh), 0);

        vm.prank(keeper);
        vm.expectEmit(true, true, true, true);
        emit RebalancingVault.AutoRebalanceSkipped(0);
        vSolh.advanceRebalance();
    }

    // ═══════════════════════════════════════════════════════════
    //                 CROSS-TOKEN COMPARISONS
    // ═══════════════════════════════════════════════════════════

    function test_allVaults_sameDeposit_differentOrderSizes() public {
        // Same 10 HYPE deposit into all 3 vaults.
        // Verify that order sizes scale inversely with token price.
        vm.startPrank(alice);
        vPurr.deposit{value: 10 ether}();
        vJeff.deposit{value: 10 ether}();
        vSolh.deposit{value: 10 ether}();
        vm.stopPrank();

        // Start rebalance for all 3
        vm.startPrank(keeper);
        vPurr.advanceRebalance();
        vJeff.advanceRebalance();
        vSolh.advanceRebalance();
        vm.stopPrank();

        // All should be AWAITING_BRIDGE_IN (selling HYPE from 100% allocation)
        _assertPhase(vPurr, RebalancingVault.RebalancePhase.AWAITING_BRIDGE_IN);
        _assertPhase(vJeff, RebalancingVault.RebalancePhase.AWAITING_BRIDGE_IN);
        _assertPhase(vSolh, RebalancingVault.RebalancePhase.AWAITING_BRIDGE_IN);

        // Set Core balances + advance L1
        _setSpotBalance(address(vPurr), HYPE_TI, uint64((10 ether - address(vPurr).balance) / 1e10), 0);
        _setSpotBalance(address(vJeff), HYPE_TI, uint64((10 ether - address(vJeff).balance) / 1e10), 0);
        _setSpotBalance(address(vSolh), HYPE_TI, uint64((10 ether - address(vSolh).balance) / 1e10), 0);
        _setL1Block(101);

        // Execute trades for all 3
        uint256 cw0 = coreWriter.callCount();
        vm.prank(keeper);
        vPurr.advanceRebalance();
        uint256 cw1 = coreWriter.callCount();
        vm.prank(keeper);
        vJeff.advanceRebalance();
        uint256 cw2 = coreWriter.callCount();
        vm.prank(keeper);
        vSolh.advanceRebalance();
        uint256 cw3 = coreWriter.callCount();

        // Extract TOKEN buy sizes
        uint64 purrSz = _findTokenBuySz(cw0, cw1, PURR_MI);
        uint64 jeffSz = _findTokenBuySz(cw1, cw2, JEFF_MI);
        uint64 solhSz = _findTokenBuySz(cw2, cw3, SOLH_MI);

        // PURR is cheapest → largest quantity (sz in 1e8 format)
        // SOLH is most expensive → smallest quantity
        assertGt(purrSz, jeffSz, "PURR qty > JEFF qty");
        assertGt(jeffSz, solhSz, "JEFF qty > SOLH qty");

        // Approximate USDC notional of each buy should be ~$120 (48% of $250)
        // notional_usdc8 = sz * px / 10^(8-szDec) since both are in precompile format
        uint256 purrNotional = uint256(purrSz) * uint256(PURR_PX) / (10 ** (8 - PURR_SZ));
        uint256 jeffNotional = uint256(jeffSz) * uint256(JEFF_PX) / (10 ** (8 - JEFF_SZ));
        uint256 solhNotional = uint256(solhSz) * uint256(SOLH_PX) / (10 ** (8 - SOLH_SZ));

        // All should target roughly the same USDC value (within 5%)
        assertApproxEqRel(purrNotional, jeffNotional, 0.05e18, "PURR ~ JEFF notional");
        assertApproxEqRel(jeffNotional, solhNotional, 0.05e18, "JEFF ~ SOLH notional");
    }

    // ═══════════════════════════════════════════════════════════
    //      CORE BALANCE VERIFICATION AFTER SIMULATED FILLS
    // ═══════════════════════════════════════════════════════════

    /// @dev Full cycle with simulated fills: verify final Core balances match 48/48/4
    function test_purr_postFill_coreBalancesMatch48_48_4() public {
        _verifyPostFillBalances(
            vPurr, PURR_TI, PURR_MI, PURR_PX, PURR_SZ, PURR_WD,
            12_000_000_000, // expected ~120,000 PURR in weiDec5
            "PURR"
        );
    }

    function test_jeff_postFill_coreBalancesMatch48_48_4() public {
        _verifyPostFillBalances(
            vJeff, JEFF_TI, JEFF_MI, JEFF_PX, JEFF_SZ, JEFF_WD,
            80_000_000_000, // expected ~80 JEFF in weiDec9
            "JEFF"
        );
    }

    function test_solh_postFill_coreBalancesMatch48_48_4() public {
        _verifyPostFillBalances(
            vSolh, SOLH_TI, SOLH_MI, SOLH_PX, SOLH_SZ, SOLH_WD,
            66_000_000, // expected ~0.66 SOLH in weiDec8 (rounded to lot)
            "SOLH"
        );
    }

    /// @dev Run full cycle, simulate order fills, verify resulting allocations
    function _verifyPostFillBalances(
        RebalancingVault v,
        uint32 tokenTI,
        uint32 tokenMI,
        uint64 tokenPx,
        uint8 tokenSzDec,
        uint8 tokenWeiDec,
        uint256 expectedTokenCore,
        string memory label
    ) internal {
        // Deposit 10 HYPE ($250)
        vm.prank(alice);
        v.deposit{value: 10 ether}();

        // ── Call 1: IDLE → AWAITING_BRIDGE_IN ──
        vm.prank(keeper);
        v.advanceRebalance();

        // Simulate bridge: EVM HYPE moved to Core
        uint64 bridgedHype = uint64((10 ether - address(v).balance) / 1e10);
        _setSpotBalance(address(v), HYPE_TI, bridgedHype, 0);
        _setL1Block(101);

        // ── Call 2: AWAITING_BRIDGE_IN → AWAITING_TRADES ──
        // Capture orders
        uint256 cwBefore = coreWriter.callCount();
        vm.prank(keeper);
        v.advanceRebalance();
        uint256 cwAfter = coreWriter.callCount();

        // Decode orders to compute expected fills
        uint64 hypeSellSz = 0;
        uint64 tokenBuySz = 0;
        for (uint256 i = cwBefore; i < cwAfter; i++) {
            (uint32 asset, bool isBuy,, uint64 sz) = _decodeOrder(i);
            if (asset == 10000 + HYPE_MI && !isBuy) hypeSellSz = sz;
            if (asset == 10000 + tokenMI && isBuy) tokenBuySz = sz;
        }

        // Compute expected Core balances after fills:
        //
        // HYPE Core after sell: bridgedHype - sold amount (in weiDec8)
        // sold_weiDec8 = hypeSellSz * 10^(weiDec-8) but weiDec for HYPE = 8, so sold = hypeSellSz
        uint64 hypeCoreFinal = bridgedHype - hypeSellSz;

        // TOKEN Core after buy: tokenBuySz converted to weiDecimals
        // buySz is in 1e8 format. human = buySz / 1e8.
        // weiDec amount = human * 10^weiDec = buySz * 10^weiDec / 1e8
        uint256 tokenCoreFinal;
        if (tokenWeiDec >= 8) {
            tokenCoreFinal = uint256(tokenBuySz) * (10 ** (tokenWeiDec - 8));
        } else {
            tokenCoreFinal = uint256(tokenBuySz) / (10 ** (8 - tokenWeiDec));
        }

        // USDC Core after trades: sell proceeds - buy cost (both in USDC8)
        // Sell HYPE proceeds = hypeSellSz * hypePx / 10^(8-HYPE_SZ)
        uint256 sellProceeds = uint256(hypeSellSz) * uint256(HYPE_PX) / (10 ** (8 - HYPE_SZ));
        // Buy TOKEN cost = tokenBuySz * tokenPx / 10^(8-tokenSzDec)
        uint256 buyCost = uint256(tokenBuySz) * uint256(tokenPx) / (10 ** (8 - tokenSzDec));
        uint256 usdcCoreFinal = sellProceeds - buyCost;

        // Now simulate these filled balances and verify they are near the targets
        _setSpotBalance(address(v), HYPE_TI, hypeCoreFinal, 0);
        _setSpotBalance(address(v), tokenTI, uint64(tokenCoreFinal), 0);
        _setSpotBalance(address(v), USDC_TI, uint64(usdcCoreFinal), 0);
        _setL1Block(102);

        // ── Call 3: finalize ──
        vm.prank(keeper);
        v.advanceRebalance();

        // After bridge-out of remaining HYPE, the Core HYPE goes to EVM
        // Final Core should have: TOKEN + USDC + maybe small HYPE residual

        // ── Verify allocations ──
        // Total value in USDC8
        uint256 totalUsdc8 = 25_000_000_000; // $250

        // TOKEN value should be ~48% of total
        // buyCost IS the USDC8 value of the token position (sz * spotPx at fill)
        uint256 tokenUsdc8 = buyCost;
        uint256 tokenBps = tokenUsdc8 * 10000 / totalUsdc8;

        // HYPE: remaining EVM HYPE value
        uint256 hypeEvmWei = address(v).balance;
        uint256 hypeCoreUsdc8 = uint256(hypeCoreFinal) * uint256(HYPE_PX) / (10 ** (8 - HYPE_SZ));
        uint256 hypeEvmUsdc8 = (hypeEvmWei / 1e10) * uint256(HYPE_PX) / (10 ** (8 - HYPE_SZ));
        uint256 totalHypeUsdc8 = hypeCoreUsdc8 + hypeEvmUsdc8;
        uint256 hypeBps = totalHypeUsdc8 * 10000 / totalUsdc8;

        uint256 usdcBps = usdcCoreFinal * 10000 / totalUsdc8;

        // All allocations should be within 3% of target (300 bps = drift threshold)
        assertApproxEqAbs(tokenBps, 4800, 300, string.concat(label, " TOKEN bps ~48%"));
        assertApproxEqAbs(usdcBps, 400, 200, string.concat(label, " USDC bps ~4%"));
        // HYPE is the residual, should also be ~48%
        assertApproxEqAbs(hypeBps, 4800, 300, string.concat(label, " HYPE bps ~48%"));

        // Sum should be ~100%
        uint256 totalBps = hypeBps + tokenBps + usdcBps;
        assertApproxEqAbs(totalBps, 10000, 100, string.concat(label, " total ~100%"));

        // TOKEN Core balance should match expected (within lot rounding)
        assertApproxEqRel(
            tokenCoreFinal, expectedTokenCore, 0.05e18,
            string.concat(label, " Core balance ~= expected")
        );
    }

    // ═══════════════════════════════════════════════════════════
    //          ORDER NOTIONAL MATCHES TARGET ALLOCATION
    // ═══════════════════════════════════════════════════════════

    /// @dev For each token: deposit 10 HYPE ($250), verify order notionals match 48% targets
    function test_purr_orderNotional_matchesTarget() public {
        _verifyOrderNotionals(vPurr, PURR_MI, PURR_PX, PURR_SZ);
    }

    function test_jeff_orderNotional_matchesTarget() public {
        _verifyOrderNotionals(vJeff, JEFF_MI, JEFF_PX, JEFF_SZ);
    }

    function test_solh_orderNotional_matchesTarget() public {
        _verifyOrderNotionals(vSolh, SOLH_MI, SOLH_PX, SOLH_SZ);
    }

    function _verifyOrderNotionals(
        RebalancingVault v,
        uint32 tokenMI,
        uint64 tokenPx,
        uint8 tokenSzDec
    ) internal {
        // 10 HYPE = $250 total. Starting allocation: 100% HYPE, 0 TOKEN, 0 USDC
        // Target: 48% HYPE ($120), 48% TOKEN ($120), 4% USDC ($10)
        // Expected deltas: sell ~$130 HYPE, buy ~$120 TOKEN
        vm.prank(alice);
        v.deposit{value: 10 ether}();

        // Call 1: IDLE → AWAITING_BRIDGE_IN
        vm.prank(keeper);
        v.advanceRebalance();

        // Simulate bridge
        uint64 bridgedCore = uint64((10 ether - address(v).balance) / 1e10);
        _setSpotBalance(address(v), HYPE_TI, bridgedCore, 0);
        _setL1Block(101);

        // Call 2: trades sent
        uint256 cwBefore = coreWriter.callCount();
        vm.prank(keeper);
        v.advanceRebalance();
        uint256 cwAfter = coreWriter.callCount();

        // Decode all orders, compute notionals
        uint256 hypeSellNotional = 0;
        uint256 tokenBuyNotional = 0;

        for (uint256 i = cwBefore; i < cwAfter; i++) {
            (uint32 asset, bool isBuy,, uint64 sz) = _decodeOrder(i);

            if (asset == 10000 + HYPE_MI) {
                assertFalse(isBuy, "HYPE should be SELL");
                // notional = sz * spotPx / 10^(8-szDec) — use spot price, not limit price
                hypeSellNotional = uint256(sz) * uint256(HYPE_PX) / (10 ** (8 - HYPE_SZ));
            }
            if (asset == 10000 + tokenMI) {
                assertTrue(isBuy, "TOKEN should be BUY");
                tokenBuyNotional = uint256(sz) * uint256(tokenPx) / (10 ** (8 - tokenSzDec));
            }
        }

        // Total value in USDC8: 10 HYPE * $25 = $250 = 25_000_000_000
        uint256 totalUsdc8 = 25_000_000_000;

        // Target HYPE: 48% = $120 = 12_000_000_000 USDC8
        // Current HYPE: $250. Delta = $130 sell
        uint256 expectedHypeSellUsdc8 = totalUsdc8 - (totalUsdc8 * 4800 / 10000);
        // Target TOKEN: 48% = $120 buy
        uint256 expectedTokenBuyUsdc8 = totalUsdc8 * 4800 / 10000;

        // HYPE sell notional should be ~$130 (within 10% for rounding/lot size)
        assertApproxEqRel(
            hypeSellNotional, expectedHypeSellUsdc8, 0.10e18,
            "HYPE sell notional ~= target delta"
        );

        // TOKEN buy notional should be ~$120 (within 10% for rounding/lot size)
        assertApproxEqRel(
            tokenBuyNotional, expectedTokenBuyUsdc8, 0.10e18,
            "TOKEN buy notional ~= target delta"
        );

        // The two sides should roughly balance (sell proceeds fund the buy)
        // TOKEN buy <= HYPE sell (can't buy more than you sell)
        assertLe(tokenBuyNotional, hypeSellNotional, "buy <= sell proceeds");
    }

    /// @dev Verify reverse direction: TOKEN overweight → sell TOKEN, buy HYPE
    function test_jeff_reverseDirection_orderNotionals() public {
        // 1 HYPE on EVM ($25) + 200 JEFF on Core ($300) + $5 USDC = $330 total
        vm.prank(alice);
        vJeff.deposit{value: 1 ether}();

        _setSpotBalance(address(vJeff), HYPE_TI, 0, 0);
        _setSpotBalance(address(vJeff), JEFF_TI, 200_000_000_000, 0); // 200 JEFF weiDec9
        _setSpotBalance(address(vJeff), USDC_TI, 500_000_000, 0);    // $5

        uint256 cwBefore = coreWriter.callCount();
        vm.prank(keeper);
        vJeff.advanceRebalance();
        uint256 cwAfter = coreWriter.callCount();

        // Should be AWAITING_TRADES (no bridge needed — buying HYPE)
        _assertPhase(vJeff, RebalancingVault.RebalancePhase.AWAITING_TRADES);

        uint256 hypeBuyNotional = 0;
        uint256 jeffSellNotional = 0;

        for (uint256 i = cwBefore; i < cwAfter; i++) {
            (uint32 asset, bool isBuy,, uint64 sz) = _decodeOrder(i);
            if (asset == 10000 + HYPE_MI) {
                assertTrue(isBuy, "HYPE should be BUY");
                hypeBuyNotional = uint256(sz) * uint256(HYPE_PX) / (10 ** (8 - HYPE_SZ));
            }
            if (asset == 10000 + JEFF_MI) {
                assertFalse(isBuy, "JEFF should be SELL");
                jeffSellNotional = uint256(sz) * uint256(JEFF_PX) / (10 ** (8 - JEFF_SZ));
            }
        }

        // Total ~$330. Target HYPE: 48% = ~$158. Current HYPE: $25. Delta buy ~$133
        // Target JEFF: 48% = ~$158. Current JEFF: $300. Delta sell ~$142
        uint256 totalApprox = 33_000_000_000; // $330 in USDC8
        uint256 targetHypeUsdc8 = totalApprox * 4800 / 10000; // ~$158.4
        uint256 currentHypeUsdc8 = 2_500_000_000; // $25
        uint256 expectedHypeBuy = targetHypeUsdc8 - currentHypeUsdc8; // ~$133

        uint256 targetJeffUsdc8 = totalApprox * 4800 / 10000;
        uint256 currentJeffUsdc8 = 30_000_000_000; // $300
        uint256 expectedJeffSell = currentJeffUsdc8 - targetJeffUsdc8; // ~$142

        assertApproxEqRel(
            hypeBuyNotional, expectedHypeBuy, 0.10e18,
            "HYPE buy notional ~= target"
        );
        assertApproxEqRel(
            jeffSellNotional, expectedJeffSell, 0.10e18,
            "JEFF sell notional ~= target"
        );

        // Buy HYPE <= Sell JEFF proceeds
        assertLe(hypeBuyNotional, jeffSellNotional, "buy <= sell");
    }

    // ═══════════════════════════════════════════════════════════
    //                     INTERNAL HELPERS
    // ═══════════════════════════════════════════════════════════

    function _assertPhase(RebalancingVault v, RebalancingVault.RebalancePhase expected) internal view {
        (, RebalancingVault.RebalancePhase phase,,,,,,) = v.currentCycle();
        assertEq(uint8(phase), uint8(expected));
    }

    /// @dev Decode a CoreWriter limit-order payload at call index `idx`
    function _decodeOrder(uint256 idx) internal view returns (uint32 asset, bool isBuy, uint64 corePx, uint64 sz) {
        bytes memory data = coreWriter.getCallData(idx);
        assertEq(uint8(data[0]), 0x01, "version");
        assertEq(uint8(data[3]), 0x01, "action=limit order");

        bytes memory params = new bytes(data.length - 4);
        for (uint256 i = 0; i < params.length; i++) {
            params[i] = data[4 + i];
        }
        (asset, isBuy, corePx, sz,,,) = abi.decode(params, (uint32, bool, uint64, uint64, bool, uint8, uint128));
    }

    /// @dev Find the TOKEN buy order sz in a range of CoreWriter calls
    function _findTokenBuySz(uint256 from, uint256 to, uint32 tokenMI)
        internal
        view
        returns (uint64 sz)
    {
        for (uint256 i = from; i < to; i++) {
            (uint32 asset, bool isBuy,, uint64 orderSz) = _decodeOrder(i);
            if (asset == 10000 + tokenMI && isBuy) return orderSz;
        }
        revert("token buy order not found");
    }

    // ═══════════════════════════════════════════════════════════
    //     UETH-LIKE — $650, szDec=4, weiDec=9  (high szDec)
    // ═══════════════════════════════════════════════════════════

    uint32 constant UETH_TI = 30;
    uint32 constant UETH_MI = 15;
    uint8 constant UETH_SZ = 4;
    uint8 constant UETH_WD = 9;
    uint8 constant UETH_ED = 18;
    uint64 constant UETH_PX = 6500000; // $650 * 10^(8-4) = 650 * 10000

    function test_ueth_fullCycle_sellHype() public {
        // Create UETH vault
        ERC20Mock ueth = new ERC20Mock("UETH", "UETH", UETH_ED);
        _setSpotPrice(UETH_MI, UETH_PX);
        vm.prank(owner);
        RebalancingVault vUeth = _createVault(address(ueth), UETH_TI, UETH_MI, UETH_SZ, UETH_WD, UETH_ED, "hlUETH");

        // 10 HYPE = $250
        vm.prank(alice);
        vUeth.deposit{value: 10 ether}();

        // Call 1: IDLE → AWAITING_BRIDGE_IN
        vm.prank(keeper);
        vUeth.advanceRebalance();
        _assertPhase(vUeth, RebalancingVault.RebalancePhase.AWAITING_BRIDGE_IN);

        // Simulate bridge
        uint64 bridgedCore = uint64((10 ether - address(vUeth).balance) / 1e10);
        _setSpotBalance(address(vUeth), HYPE_TI, bridgedCore, 0);
        _setL1Block(101);

        // Call 2: orders sent
        uint256 cwBefore = coreWriter.callCount();
        vm.prank(keeper);
        vUeth.advanceRebalance();
        _assertPhase(vUeth, RebalancingVault.RebalancePhase.AWAITING_TRADES);

        uint256 orderCount = coreWriter.callCount() - cwBefore;
        assertGe(orderCount, 1, "at least 1 order");

        // Verify UETH buy order
        bool uethBuy = false;
        for (uint256 i = cwBefore; i < cwBefore + orderCount; i++) {
            (uint32 asset, bool isBuy, uint64 corePx, uint64 sz) = _decodeOrder(i);
            if (asset == 10000 + UETH_MI && isBuy) {
                // corePx = precompilePx * 10^4 = ~6630000 * 10000 = ~66300000000
                assertGt(corePx, 0, "UETH corePx must be positive");
                // sz should be small (~0.18 UETH): sz = 0.18 * 1e8 = 18000000
                // Lot granularity for szDec=4 = 10^(8-4) = 10000
                assertEq(sz % 10000, 0, "UETH sz must respect lot granularity");
                assertGt(sz, 0, "UETH sz must be positive");
                uethBuy = true;
            }
        }
        assertTrue(uethBuy, "must buy UETH");
    }

    // ═══════════════════════════════════════════════════════════
    //     UNIT-LIKE — $16000, szDec=5, weiDec=10 (highest szDec)
    // ═══════════════════════════════════════════════════════════

    uint32 constant UNIT_TI = 40;
    uint32 constant UNIT_MI = 20;
    uint8 constant UNIT_SZ = 5;
    uint8 constant UNIT_WD = 10;
    uint8 constant UNIT_ED = 18;
    uint64 constant UNIT_PX = 16000000; // $16000 * 10^(8-5) = 16000 * 1000

    function test_unit_fullCycle_sellHype() public {
        ERC20Mock unit_ = new ERC20Mock("UNIT", "UNIT", UNIT_ED);
        _setSpotPrice(UNIT_MI, UNIT_PX);
        vm.prank(owner);
        RebalancingVault vUnit = _createVault(address(unit_), UNIT_TI, UNIT_MI, UNIT_SZ, UNIT_WD, UNIT_ED, "hlUNIT");

        // 10 HYPE = $250
        vm.prank(alice);
        vUnit.deposit{value: 10 ether}();

        vm.prank(keeper);
        vUnit.advanceRebalance();
        _assertPhase(vUnit, RebalancingVault.RebalancePhase.AWAITING_BRIDGE_IN);

        uint64 bridgedCore = uint64((10 ether - address(vUnit).balance) / 1e10);
        _setSpotBalance(address(vUnit), HYPE_TI, bridgedCore, 0);
        _setL1Block(101);

        uint256 cwBefore = coreWriter.callCount();
        vm.prank(keeper);
        vUnit.advanceRebalance();
        _assertPhase(vUnit, RebalancingVault.RebalancePhase.AWAITING_TRADES);

        uint256 orderCount = coreWriter.callCount() - cwBefore;
        assertGe(orderCount, 1, "at least 1 order");

        // Verify UNIT buy order
        bool unitBuy = false;
        for (uint256 i = cwBefore; i < cwBefore + orderCount; i++) {
            (uint32 asset, bool isBuy, uint64 corePx, uint64 sz) = _decodeOrder(i);
            if (asset == 10000 + UNIT_MI && isBuy) {
                // corePx = precompilePx * 10^5
                assertGt(corePx, 0, "UNIT corePx must be positive");
                // Lot granularity for szDec=5 = 10^3 = 1000
                assertEq(sz % 1000, 0, "UNIT sz must respect lot granularity");
                assertGt(sz, 0, "UNIT sz must be positive");
                unitBuy = true;
            }
        }
        assertTrue(unitBuy, "must buy UNIT");
    }

    // ═══════════════════════════════════════════════════════════
    //     FULL LIFECYCLE: deposit → rebalance → withdraw → claim
    // ═══════════════════════════════════════════════════════════

    function test_fullLifecycle_deposit_rebalance_withdraw_claim() public {
        // Alice and Bob both deposit into SOLH vault
        address bob = address(0xD);
        vm.deal(bob, 100 ether);

        vm.prank(alice);
        uint256 aliceShares = vSolh.deposit{value: 10 ether}();
        vm.prank(bob);
        uint256 bobShares = vSolh.deposit{value: 10 ether}();

        assertEq(vSolh.totalSupply(), aliceShares + bobShares);

        // ── Rebalance: sell HYPE, buy SOLH ──
        vm.prank(keeper);
        vSolh.advanceRebalance();
        _assertPhase(vSolh, RebalancingVault.RebalancePhase.AWAITING_BRIDGE_IN);

        // Simulate bridge + trades
        uint64 bridgedCore = uint64((20 ether - address(vSolh).balance) / 1e10);
        _setSpotBalance(address(vSolh), HYPE_TI, bridgedCore, 0);
        _setL1Block(101);

        vm.prank(keeper);
        vSolh.advanceRebalance(); // sends orders
        _assertPhase(vSolh, RebalancingVault.RebalancePhase.AWAITING_TRADES);

        // Simulate fills: 48% HYPE left on Core, 48% SOLH, 4% USDC
        uint256 totalUsdc8 = 500_00000000; // $500 total
        uint64 hypeOnCore = uint64(totalUsdc8 * 48 / 100 / 25); // ~9.6 HYPE in weiDec=8
        uint64 solhOnCore = uint64(totalUsdc8 * 48 / 100 * 1e8 / uint256(SOLH_PX) / (10 ** (SOLH_WD - SOLH_SZ)));
        uint64 usdcOnCore = uint64(totalUsdc8 * 4 / 100); // $20 = 2000000000
        _setSpotBalance(address(vSolh), HYPE_TI, hypeOnCore, 0);
        _setSpotBalance(address(vSolh), SOLH_TI, solhOnCore, 0);
        _setSpotBalance(address(vSolh), USDC_TI, usdcOnCore, 0);
        _setL1Block(102);

        vm.prank(keeper);
        vSolh.advanceRebalance(); // bridge out remaining HYPE

        if (hypeOnCore > 0) {
            _assertPhase(vSolh, RebalancingVault.RebalancePhase.AWAITING_BRIDGE_OUT);
            _setSpotBalance(address(vSolh), HYPE_TI, 0, 0);
            vm.deal(address(vSolh), address(vSolh).balance + uint256(hypeOnCore) * 1e10);
            _setL1Block(103);
            vm.prank(keeper);
            vSolh.advanceRebalance(); // finalize
        }
        _assertPhase(vSolh, RebalancingVault.RebalancePhase.IDLE);

        // ── Alice requests withdraw ──
        vm.prank(alice);
        vSolh.requestRedeem(aliceShares);

        // ── Settlement: sell SOLH → USDC → buy HYPE → bridge → settle ──
        vm.prank(keeper);
        vSolh.advanceBatchSettlement(); // close batch + sell SOLH

        // Simulate sell SOLH → USDC
        _setSpotBalance(address(vSolh), SOLH_TI, 0, 0);
        _setSpotBalance(address(vSolh), USDC_TI, usdcOnCore + uint64(uint256(solhOnCore) * SOLH_PX * (10 ** SOLH_SZ) / (10 ** SOLH_WD)), 0);
        _setL1Block(104);

        vm.prank(keeper);
        vSolh.advanceBatchSettlement(); // buy HYPE

        // Simulate buy HYPE
        (uint64 usdcAfterSell,) = vSolh.factory().keeper() == keeper
            ? (uint64(0), uint64(0))
            : (uint64(0), uint64(0));
        // Simplified: just put HYPE on Core
        _setSpotBalance(address(vSolh), USDC_TI, 0, 0);
        uint64 hypeFromBuy = uint64(4_00000000 / 25); // ~$400 / $25 = 16 HYPE in weiDec=8
        _setSpotBalance(address(vSolh), HYPE_TI, hypeFromBuy, 0);
        _setL1Block(105);

        vm.prank(keeper);
        vSolh.advanceBatchSettlement(); // bridge HYPE

        _setSpotBalance(address(vSolh), HYPE_TI, 0, 0);
        vm.deal(address(vSolh), address(vSolh).balance + uint256(hypeFromBuy) * 1e10);
        _setL1Block(106);

        vm.prank(keeper);
        vSolh.advanceBatchSettlement(); // settle

        // Verify batch is settled
        (,,,,,,RebalancingVault.BatchStatus status) = vSolh.batches(0);
        assertEq(uint8(status), uint8(RebalancingVault.BatchStatus.SETTLED));

        // ── Alice claims ──
        uint256 aliceBefore = alice.balance;
        vm.prank(alice);
        vSolh.claimBatch(0);
        uint256 aliceClaimed = alice.balance - aliceBefore;
        assertGt(aliceClaimed, 0, "Alice must receive HYPE");

        // ── Bob still has shares and can continue ──
        assertEq(vSolh.balanceOf(bob), bobShares);
        assertGt(vSolh.grossAssets(), 0, "vault still has assets for Bob");

        // ── Invariants ──
        assertGe(address(vSolh).balance, vSolh.reservedHypeForClaims(), "balance >= reserved");
        assertEq(vSolh.totalSupply(), bobShares, "only Bob's shares remain");
        assertEq(vSolh.escrowedShares(), 0, "no escrowed shares");
    }

    // ═══════════════════════════════════════════════════════════
    //     LOW LIQUIDITY: vault too small for rebalance
    // ═══════════════════════════════════════════════════════════

    function test_lowLiquidity_belowMinNotional_skipsRebalance() public {
        // Deposit only 0.1 HYPE = $2.50, way below $21 minimum for rebalance
        vm.prank(alice);
        vSolh.deposit{value: 0.1 ether}();

        vm.prank(keeper);
        vSolh.advanceRebalance();

        // Should still be IDLE (rebalance skipped — orders below min notional)
        _assertPhase(vSolh, RebalancingVault.RebalancePhase.IDLE);
    }

    // ═══ Precompile helpers (same as VaultTestBase) ═══

    function _etchPrecompiles() internal {
        MockPrecompile m;
        m = new MockPrecompile(); vm.etch(address(0x801), address(m).code);
        m = new MockPrecompile(); vm.etch(address(0x807), address(m).code);
        m = new MockPrecompile(); vm.etch(address(0x808), address(m).code);
        m = new MockPrecompile(); vm.etch(address(0x809), address(m).code);
        m = new MockPrecompile(); vm.etch(address(0x80C), address(m).code);
    }

    function _setSpotPrice(uint32 mi, uint64 px) internal {
        bytes32 slot = keccak256(abi.encode(uint256(mi), uint256(2)));
        vm.store(address(0x808), slot, bytes32(uint256(px)));
    }

    function _setSpotBalance(address user, uint32 ti, uint64 total, uint64 hold) internal {
        bytes32 key = keccak256(abi.encode(user, ti));
        vm.store(address(0x801), keccak256(abi.encode(key, uint256(0))), bytes32(uint256(total)));
        vm.store(address(0x801), keccak256(abi.encode(key, uint256(1))), bytes32(uint256(hold)));
    }

    function _setL1Block(uint64 bn) internal {
        vm.store(address(0x809), bytes32(uint256(4)), bytes32(uint256(bn)));
    }
}
