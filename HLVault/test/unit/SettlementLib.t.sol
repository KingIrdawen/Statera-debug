// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "forge-std/Test.sol";
import {SettlementLib} from "../../src/libraries/SettlementLib.sol";
import {PriceLib} from "../../src/libraries/PriceLib.sol";
import {SizeLib} from "../../src/libraries/SizeLib.sol";

contract SettlementLibTest is Test {
    // ═══ computeSellTokenOrder ═══

    function test_sellToken_valid() public pure {
        // PURR: szDec=0, weiDec=5, price=$0.001 → rawPx=100000
        // 20000 PURR = 20000 * 1e5 = 2e9 in weiDec5 ($20 notional > $10 min)
        (bool valid, SettlementLib.SpotOrder memory order) = SettlementLib.computeSellTokenOrder(
            2e9, // tokenCoreBalance (weiDec5)
            100000, // tokenPx (precompile format)
            10000, // tokenAsset
            0, // tokenSzDec
            5, // tokenWeiDec
            200 // slippageBps (2%)
        );

        assertTrue(valid);
        assertEq(order.asset, 10000);
        assertFalse(order.isBuy);
        assertGt(order.sz, 0);
        assertGt(order.limitPx, 0);
    }

    function test_sellToken_zeroBalance() public pure {
        (bool valid,) = SettlementLib.computeSellTokenOrder(0, 100000, 10000, 0, 5, 200);
        assertFalse(valid);
    }

    function test_sellToken_zeroPrice() public pure {
        (bool valid,) = SettlementLib.computeSellTokenOrder(1e9, 0, 10000, 0, 5, 200);
        assertFalse(valid);
    }

    function test_sellToken_belowMinNotional() public pure {
        // Very small balance: 1 unit = 1e5 in weiDec5
        // At $0.001 = $0.001 notional, way below $10 min
        (bool valid,) = SettlementLib.computeSellTokenOrder(1e5, 100000, 10000, 0, 5, 200);
        assertFalse(valid);
    }

    function test_sellToken_hype() public pure {
        // HYPE: szDec=2, weiDec=8, price=$25 → rawPx=25000000
        // 1 HYPE = 1e8 in weiDec8
        (bool valid, SettlementLib.SpotOrder memory order) = SettlementLib.computeSellTokenOrder(
            1e8, // 1 HYPE
            25000000, // $25
            10107, // asset
            2, // szDec
            8, // weiDec
            200
        );

        assertTrue(valid);
        assertFalse(order.isBuy);
    }

    // ═══ computeBuyHypeOrder ═══

    function test_buyHype_valid() public pure {
        // 100 USDC on Core (100e8 in weiDec8)
        // HYPE $25 → rawPx=25000000 (szDec=2)
        (bool valid, SettlementLib.SpotOrder memory order) = SettlementLib.computeBuyHypeOrder(
            10000000000, // 100 USDC (weiDec8)
            25000000, // $25 HYPE
            10107, // hypeAsset
            2, // hypeSzDec
            200 // slippageBps
        );

        assertTrue(valid);
        assertTrue(order.isBuy);
        assertGt(order.sz, 0);
        assertGt(order.limitPx, 0);
    }

    function test_buyHype_zeroUsdc() public pure {
        (bool valid,) = SettlementLib.computeBuyHypeOrder(0, 25000000, 10107, 2, 200);
        assertFalse(valid);
    }

    function test_buyHype_zeroPrice() public pure {
        (bool valid,) = SettlementLib.computeBuyHypeOrder(10000000000, 0, 10107, 2, 200);
        assertFalse(valid);
    }

    function test_buyHype_belowMinNotional() public pure {
        // 1 USDC → $1 notional, below $10 min
        (bool valid,) = SettlementLib.computeBuyHypeOrder(100000000, 25000000, 10107, 2, 200);
        assertFalse(valid);
    }

    // ═══ Fuzz tests ═══

    function testFuzz_sellToken_priceFormat(uint64 tokenPx, uint8 szDec) public {
        szDec = uint8(bound(szDec, 0, 5));
        // Ensure price is large enough that slippage + tick formatting won't zero it
        uint256 minPx = 10 ** (szDec + 1); // must be > granularity after slippage
        vm.assume(tokenPx > minPx && tokenPx < type(uint64).max / 2);

        (bool valid, SettlementLib.SpotOrder memory order) = SettlementLib.computeSellTokenOrder(
            uint64(1e12), tokenPx, 10000, szDec, 8, 200
        );

        if (valid) {
            // Price should be valid tick
            assertEq(PriceLib.formatTickPrice(order.limitPx, szDec), order.limitPx);
            // Should be a sell
            assertFalse(order.isBuy);
        }
    }

    function testFuzz_buyHype_priceFormat(uint64 usdcBal, uint64 hypePx) public pure {
        vm.assume(usdcBal > 1e9 && usdcBal < 1e15);
        vm.assume(hypePx > 1e6 && hypePx < 1e12);

        (bool valid, SettlementLib.SpotOrder memory order) = SettlementLib.computeBuyHypeOrder(
            usdcBal, hypePx, 10107, 2, 200
        );

        if (valid) {
            assertEq(PriceLib.formatTickPrice(order.limitPx, 2), order.limitPx);
            assertTrue(order.isBuy);
        }
    }
}
