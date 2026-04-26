// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "forge-std/Test.sol";
import {PriceLib} from "../../src/libraries/PriceLib.sol";

contract PriceLibTest is Test {
    // ═══ formatTickPrice ═══

    function test_formatTickPrice_basicPrice() public pure {
        // Price = 25.50 USDC for a token with szDecimals=2
        // rawPriceUsdc8 = 25.50 * 1e8 = 2550000000
        // max decimals = 8 - 2 = 6, min granularity = 100
        // 2550000000 / 100 * 100 = 2550000000 (already aligned)
        // 5 sig figs: 2550000000 -> 10 digits -> truncate to 5 -> 2550000000 (already 4 sig figs)
        uint64 result = PriceLib.formatTickPrice(2550000000, 2);
        assertEq(result, 2550000000);
    }

    function test_formatTickPrice_truncatesToSigFigs() public pure {
        // Price = 123456.789 USDC for a token with szDecimals=0
        // rawPriceUsdc8 = 12345678900000 (123456.789 * 1e8)
        // Truncated to 5 sig figs: 12345000000000
        uint64 result = PriceLib.formatTickPrice(12345678900000, 0);
        assertEq(result, 12345000000000);
    }

    function test_formatTickPrice_szDecimalsGranularity() public pure {
        // Price = 25.567 USDC for token with szDecimals=2
        // rawPriceUsdc8 = 2556700000
        // min granularity = 10^2 = 100
        // 2556700000 / 100 * 100 = 2556700000 (already aligned)
        // 5 sig figs: 10 digits -> truncate to 5 -> 2556700000
        uint64 result = PriceLib.formatTickPrice(2556700000, 2);
        assertEq(result, 2556700000);
    }

    function test_formatTickPrice_zeroReverts() public {
        PriceLibWrapper wrapper = new PriceLibWrapper();
        vm.expectRevert("zero price");
        wrapper.formatTickPrice(0, 2);
    }

    // ═══ Integer price exemption ═══

    function test_formatTickPrice_integerPrice_6SigFigs() public pure {
        // Price = $123456, szDec=2
        // rawPriceUsdc8 = 123456 * 10^(8-2) = 123456 * 1e6 = 123456000000
        // This is an integer price (6 sig figs) — should NOT be truncated
        uint64 result = PriceLib.formatTickPrice(123456000000, 2);
        assertEq(result, 123456000000);
    }

    function test_formatTickPrice_integerPrice_7SigFigs_szDec0() public pure {
        // Price = $1234567, szDec=0
        // rawPriceUsdc8 = 1234567 * 10^8 = 123456700000000
        // Integer price — should NOT be truncated
        uint64 result = PriceLib.formatTickPrice(123456700000000, 0);
        assertEq(result, 123456700000000);
    }

    function test_formatTickPrice_nonIntegerStillTruncated() public pure {
        // Price = $123456.78, szDec=2
        // rawPriceUsdc8 = 123456.78 * 1e6 = 123456780000
        // NOT integer (has fractional part), so truncate to 5 sig figs
        // After granularity rounding (100): 123456780000 (aligned)
        // _truncateToSigFigs: 12 digits → 123450000000
        uint64 result = PriceLib.formatTickPrice(123456780000, 2);
        assertEq(result, 123450000000);
    }

    function test_formatTickPrice_integerPrice_szDec5() public pure {
        // Price = $162000, szDec=5
        // rawPriceUsdc8 = 162000 * 1000 = 162000000
        // Granularity = 10^5 = 100000; 162000000 % 100000 = 0 ✓
        // integerUnit = 10^3 = 1000; 162000000 % 1000 = 0 → is integer (6 sig figs)
        // Integer price — should NOT be truncated to 5 sig figs
        uint64 result = PriceLib.formatTickPrice(162000000, 5);
        assertEq(result, 162000000);
    }

    function test_formatTickPrice_integerPrice_large_szDec5() public pure {
        // Price = $1623400, szDec=5
        // rawPriceUsdc8 = 1623400 * 1000 = 1623400000
        // Granularity = 100000; 1623400000 % 100000 = 0 ✓
        // integerUnit = 1000; 1623400000 % 1000 = 0 → is integer (7 effective digits)
        // Integer price — should NOT be truncated
        uint64 result = PriceLib.formatTickPrice(1623400000, 5);
        assertEq(result, 1623400000);
    }

    // ═══ applySlippageUp ═══

    function test_applySlippageUp_200bps() public pure {
        // 100 USDC * (1 + 2%) = 102 USDC
        uint64 result = PriceLib.applySlippageUp(10000000000, 200); // 100 * 1e8
        assertEq(result, 10200000000); // 102 * 1e8
    }

    function test_applySlippageUp_overflow_reverts() public {
        PriceLibWrapper wrapper = new PriceLibWrapper();
        // Use a price near uint64 max so slippage overflows
        vm.expectRevert("slippage overflow");
        wrapper.applySlippageUp(type(uint64).max, 500);
    }

    // ═══ applySlippageDown ═══

    function test_applySlippageDown_200bps() public pure {
        // 100 USDC * (1 - 2%) = 98 USDC
        uint64 result = PriceLib.applySlippageDown(10000000000, 200);
        assertEq(result, 9800000000); // 98 * 1e8
    }

    // ═══ Fuzz ═══

    function testFuzz_formatTickPrice_neverExceedsInput(uint256 rawPrice, uint8 szDec) public {
        szDec = uint8(bound(szDec, 0, 7));
        // Ensure rawPrice is large enough to survive truncation
        uint256 minGranularity = 10 ** szDec;
        rawPrice = bound(rawPrice, minGranularity, type(uint64).max);

        uint64 result = PriceLib.formatTickPrice(rawPrice, szDec);
        assertLe(result, rawPrice); // always rounds DOWN
    }

    function testFuzz_formatTickPrice_maxFiveSigFigs(uint256 rawPrice, uint8 szDec) public pure {
        szDec = uint8(bound(szDec, 0, 7));
        uint256 minGranularity = 10 ** szDec;
        rawPrice = bound(rawPrice, minGranularity, type(uint64).max);

        uint64 result = PriceLib.formatTickPrice(rawPrice, szDec);
        if (result == 0) return;

        // Integer prices are exempt from the 5 sig fig rule
        uint256 integerUnit = 10 ** (8 - szDec);
        if (uint256(result) % integerUnit == 0) return; // integer price, unlimited sig figs

        // Non-integer prices must have at most 5 significant figures
        uint256 sigFigs = _countSigFigs(uint256(result));
        assertLe(sigFigs, 5, "non-integer result exceeds 5 significant figures");
    }

    function testFuzz_formatTickPrice_respectsGranularity(uint256 rawPrice, uint8 szDec) public pure {
        szDec = uint8(bound(szDec, 0, 7));
        uint256 minGranularity = 10 ** szDec;
        rawPrice = bound(rawPrice, minGranularity, type(uint64).max);

        uint64 result = PriceLib.formatTickPrice(rawPrice, szDec);
        // Result must be divisible by minGranularity
        assertEq(uint256(result) % minGranularity, 0, "result violates granularity");
    }

    function testFuzz_applySlippageUp_monotonic(uint64 price, uint256 bps1, uint256 bps2) public {
        bps1 = bound(bps1, 0, 500);
        bps2 = bound(bps2, bps1, 500);
        price = uint64(bound(price, 1, type(uint64).max / 2)); // avoid overflow

        uint64 result1 = PriceLib.applySlippageUp(price, bps1);
        uint64 result2 = PriceLib.applySlippageUp(price, bps2);
        assertGe(result2, result1, "slippage up should be monotonic");
    }

    // ═══ Helper ═══

    function _countSigFigs(uint256 value) internal pure returns (uint256) {
        if (value == 0) return 0;

        // Remove trailing zeros
        while (value > 0 && value % 10 == 0) {
            value /= 10;
        }

        // Count remaining digits
        uint256 count = 0;
        while (value > 0) {
            count++;
            value /= 10;
        }
        return count;
    }
}

contract PriceLibWrapper {
    function formatTickPrice(uint256 rawPrice, uint8 szDec) external pure returns (uint64) {
        return PriceLib.formatTickPrice(rawPrice, szDec);
    }

    function applySlippageUp(uint64 price, uint256 bps) external pure returns (uint64) {
        return PriceLib.applySlippageUp(price, bps);
    }
}
