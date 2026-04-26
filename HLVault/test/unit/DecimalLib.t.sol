// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "forge-std/Test.sol";
import {DecimalLib} from "../../src/libraries/DecimalLib.sol";

contract DecimalLibTest is Test {
    using DecimalLib for uint256;
    using DecimalLib for uint64;

    // ═══ evmToCore ═══

    function test_evmToCore_HYPE_18to8() public pure {
        // 1 HYPE = 1e18 on EVM -> 1e8 on Core
        uint64 result = DecimalLib.evmToCore(1e18, 18, 8);
        assertEq(result, 1e8);
    }

    function test_evmToCore_HYPE_fractional() public pure {
        // 0.5 HYPE = 5e17 on EVM -> 5e7 on Core
        uint64 result = DecimalLib.evmToCore(5e17, 18, 8);
        assertEq(result, 5e7);
    }

    function test_evmToCore_USDC_6to8() public pure {
        // 1 USDC = 1e6 on EVM -> 1e8 on Core
        uint64 result = DecimalLib.evmToCore(1e6, 6, 8);
        assertEq(result, 1e8);
    }

    function test_evmToCore_sameDec() public pure {
        uint64 result = DecimalLib.evmToCore(12345, 8, 8);
        assertEq(result, 12345);
    }

    function test_evmToCore_overflow_reverts() public {
        // uint64 max is ~1.8e19. Try to convert a huge value
        // Library calls are inlined, so we use a wrapper
        DecimalLibWrapper wrapper = new DecimalLibWrapper();
        vm.expectRevert("evmToCore overflow");
        wrapper.evmToCore(type(uint256).max, 18, 18);
    }

    function test_evmToCore_truncatesDown() public pure {
        // 1 wei of HYPE (1 in 18 dec) -> should be 0 in 8 dec (truncated)
        uint64 result = DecimalLib.evmToCore(1, 18, 8);
        assertEq(result, 0);
    }

    function test_evmToCore_smallAmount() public pure {
        // 1e10 wei = 0.00000001 HYPE -> 1 in 8 dec
        uint64 result = DecimalLib.evmToCore(1e10, 18, 8);
        assertEq(result, 1);
    }

    // ═══ coreToEvm ═══

    function test_coreToEvm_HYPE_8to18() public pure {
        // 1e8 on Core -> 1e18 on EVM
        uint256 result = DecimalLib.coreToEvm(1e8, 8, 18);
        assertEq(result, 1e18);
    }

    function test_coreToEvm_USDC_8to6() public pure {
        // 1e8 on Core -> 1e6 on EVM
        uint256 result = DecimalLib.coreToEvm(1e8, 8, 6);
        assertEq(result, 1e6);
    }

    function test_coreToEvm_sameDec() public pure {
        uint256 result = DecimalLib.coreToEvm(12345, 8, 8);
        assertEq(result, 12345);
    }

    // ═══ Round-trip ═══

    function test_roundTrip_HYPE() public pure {
        uint256 original = 123e18; // 123 HYPE
        uint64 core = DecimalLib.evmToCore(original, 18, 8);
        uint256 backToEvm = DecimalLib.coreToEvm(core, 8, 18);
        assertEq(backToEvm, original);
    }

    function test_roundTrip_USDC() public pure {
        uint256 original = 1000e6; // 1000 USDC
        uint64 core = DecimalLib.evmToCore(original, 6, 8);
        uint256 backToEvm = DecimalLib.coreToEvm(core, 8, 6);
        assertEq(backToEvm, original);
    }

    // ═══ Fuzz ═══

    function testFuzz_evmToCore_coreToEvm_roundTrip(uint256 amount, uint8 evmDec, uint8 coreDec) public pure {
        evmDec = uint8(bound(evmDec, 0, 18));
        coreDec = uint8(bound(coreDec, 0, 18));
        // Limit amount to avoid overflow
        amount = bound(amount, 0, type(uint64).max);

        if (evmDec < coreDec) {
            // amount * 10^(coreDec-evmDec) must fit uint64
            uint256 multiplier = 10 ** (coreDec - evmDec);
            if (amount > type(uint64).max / multiplier) return;
        }

        uint64 core = DecimalLib.evmToCore(amount, evmDec, coreDec);
        uint256 back = DecimalLib.coreToEvm(core, coreDec, evmDec);

        if (evmDec >= coreDec) {
            // Lost precision going down
            uint256 granularity = 10 ** (evmDec - coreDec);
            assertEq(back, (amount / granularity) * granularity);
        } else {
            assertEq(back, amount);
        }
    }
}

contract DecimalLibWrapper {
    function evmToCore(uint256 evmWei, uint8 evmDec, uint8 coreDec) external pure returns (uint64) {
        return DecimalLib.evmToCore(evmWei, evmDec, coreDec);
    }
}
