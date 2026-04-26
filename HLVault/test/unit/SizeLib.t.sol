// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "forge-std/Test.sol";
import {SizeLib} from "../../src/libraries/SizeLib.sol";

contract SizeLibTest is Test {
    // ═══ formatLotSize ═══

    function test_formatLotSize_HYPE() public pure {
        // 10 HYPE: rawSizeCore = 10 * 1e8 = 1000000000 (weiDecimals=8)
        // szDecimals = 2
        // sz = 1000000000 (already in 1e8)
        // granularity = 10^(8-2) = 1000000
        // 1000000000 / 1000000 * 1000000 = 1000000000
        uint64 result = SizeLib.formatLotSize(1000000000, 8, 2);
        assertEq(result, 1000000000); // 10.00 * 1e8
    }

    function test_formatLotSize_PURR() public pure {
        // 100 PURR: rawSizeCore = 100 * 1e5 = 10000000 (weiDecimals=5)
        // szDecimals = 0
        // sz = 10000000 * 1e8 / 1e5 = 10000000000
        // Wait: 10000000 * 10^(8-5) = 10000000 * 1000 = 10000000000
        // granularity = 10^(8-0) = 1e8
        // 10000000000 / 1e8 * 1e8 = 10000000000
        uint64 result = SizeLib.formatLotSize(10000000, 5, 0);
        assertEq(result, 10000000000); // 100 * 1e8
    }

    function test_formatLotSize_roundsDown() public pure {
        // 10.05 HYPE: rawSizeCore = 1005000000 (weiDecimals=8)
        // szDecimals = 2, granularity = 1e6
        // sz = 1005000000 (already in 1e8)
        // 1005000000 / 1000000 * 1000000 = 1005000000 -> already aligned
        uint64 result = SizeLib.formatLotSize(1005000000, 8, 2);
        assertEq(result, 1005000000); // 10.05 * 1e8

        // Now 10.051 HYPE -> 1005100000
        // 1005100000 / 1000000 * 1000000 = 1005000000
        result = SizeLib.formatLotSize(1005100000, 8, 2);
        assertEq(result, 1005000000); // truncated to 10.05
    }

    // ═══ isAboveMinNotional ═══

    function test_isAboveMinNotional_true_szDec0() public pure {
        // 1 token at $25 = $25 > $10 (szDec=0, px format = human * 1e8)
        bool result = SizeLib.isAboveMinNotional(100000000, 2500000000, 0);
        assertTrue(result);
    }

    function test_isAboveMinNotional_false_szDec0() public pure {
        // 0.01 token at $25 = $0.25 < $10 (szDec=0)
        bool result = SizeLib.isAboveMinNotional(1000000, 2500000000, 0);
        assertFalse(result);
    }

    function test_isAboveMinNotional_boundary_szDec0() public pure {
        // Exactly $10 with szDec=0: threshold = 1e9 * 10^8 = 1e17
        // sz=40000000 (0.4), px=2500000000 (25), notional = 40e6 * 25e8 = 1e17 ✓
        bool result = SizeLib.isAboveMinNotional(40000000, 2500000000, 0);
        assertTrue(result);
    }

    function test_isAboveMinNotional_true_szDec2() public pure {
        // 0.37 HYPE at $100.48 = $37.18 > $10 (szDec=2, px format = human * 1e6)
        // sz=37000000, px=100480000
        bool result = SizeLib.isAboveMinNotional(37000000, 100480000, 2);
        assertTrue(result);
    }

    function test_isAboveMinNotional_false_szDec2() public pure {
        // 0.01 HYPE at $100 = $1 < $10 (szDec=2)
        // sz=1000000, px=100000000
        bool result = SizeLib.isAboveMinNotional(1000000, 100000000, 2);
        assertFalse(result);
    }

    function test_isAboveMinNotional_boundary_szDec2() public pure {
        // Exactly $10 with szDec=2: threshold = 1e9 * 10^6 = 1e15
        // sz=10000000 (0.1 HYPE), px=100000000 ($100)
        // notional = 10e6 * 100e6 = 1e15 ✓
        bool result = SizeLib.isAboveMinNotional(10000000, 100000000, 2);
        assertTrue(result);
    }

    // ═══ Fuzz ═══

    function testFuzz_formatLotSize_neverExceedsInput(uint256 rawSize, uint8 weiDec, uint8 szDec) public pure {
        weiDec = uint8(bound(weiDec, 1, 18));
        szDec = uint8(bound(szDec, 0, 7));

        // Ensure the intermediate sz value fits in uint64
        // sz = rawSize * 10^max(0, 8-weiDec) / 10^max(0, weiDec-8)
        // To stay within uint64, limit rawSize based on weiDec
        if (weiDec < 8) {
            uint256 mult = 10 ** (8 - weiDec);
            rawSize = bound(rawSize, 1, type(uint64).max / mult);
        } else {
            rawSize = bound(rawSize, 1, type(uint64).max);
        }

        uint64 result = SizeLib.formatLotSize(rawSize, weiDec, szDec);
        // result should never exceed the unrounded value
        uint256 unrounded;
        if (weiDec >= 8) {
            unrounded = rawSize / (10 ** (weiDec - 8));
        } else {
            unrounded = rawSize * (10 ** (8 - weiDec));
        }
        assertLe(result, unrounded);
    }
}
