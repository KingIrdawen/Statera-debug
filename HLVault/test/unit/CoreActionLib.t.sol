// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "forge-std/Test.sol";
import {CoreActionLib} from "../../src/libraries/CoreActionLib.sol";
import {ICoreWriter, CORE_WRITER} from "../../src/interfaces/ICoreWriter.sol";
import {MockCoreWriter} from "../mocks/MockCoreWriter.sol";

/// @notice Wrapper to call internal CoreActionLib functions and capture payloads
contract CoreActionLibWrapper {
    function placeLimitOrder(
        uint32 asset,
        bool isBuy,
        uint64 limitPx,
        uint64 sz,
        bool reduceOnly,
        uint8 tif,
        uint128 cloid
    ) external {
        CoreActionLib.placeLimitOrder(asset, isBuy, limitPx, sz, reduceOnly, tif, cloid);
    }

    function spotSend(address dest, uint64 tokenIndex, uint64 weiAmount) external {
        CoreActionLib.spotSend(dest, tokenIndex, weiAmount);
    }

    function usdClassTransfer(uint64 ntl, bool toPerp) external {
        CoreActionLib.usdClassTransfer(ntl, toPerp);
    }

    function cancelOrder(uint32 asset, uint64 oid) external {
        CoreActionLib.cancelOrder(asset, oid);
    }
}

contract CoreActionLibTest is Test {
    CoreActionLibWrapper wrapper;
    MockCoreWriter mockWriter;

    function setUp() public {
        mockWriter = new MockCoreWriter();
        vm.etch(CORE_WRITER, address(mockWriter).code);
        wrapper = new CoreActionLibWrapper();
    }

    function _getLastPayload() internal view returns (bytes memory) {
        MockCoreWriter writer = MockCoreWriter(CORE_WRITER);
        uint256 count = writer.callCount();
        require(count > 0, "no calls");
        return writer.getCallData(count - 1);
    }

    // ═══ Payload header ═══

    function test_versionByte() public {
        wrapper.placeLimitOrder(10107, true, 2500000000, 100000000, false, 2, 0);
        bytes memory payload = _getLastPayload();
        assertEq(uint8(payload[0]), 0x01, "version byte must be 0x01");
    }

    function test_actionId_limitOrder() public {
        wrapper.placeLimitOrder(10107, true, 2500000000, 100000000, false, 2, 0);
        bytes memory payload = _getLastPayload();
        // Action ID 1 encoded as big-endian uint24: 0x000001
        assertEq(uint8(payload[1]), 0x00);
        assertEq(uint8(payload[2]), 0x00);
        assertEq(uint8(payload[3]), 0x01);
    }

    function test_actionId_spotSend() public {
        wrapper.spotSend(address(0x2222222222222222222222222222222222222222), 150, 1e8);
        bytes memory payload = _getLastPayload();
        // Action ID 6: 0x000006
        assertEq(uint8(payload[1]), 0x00);
        assertEq(uint8(payload[2]), 0x00);
        assertEq(uint8(payload[3]), 0x06);
    }

    function test_actionId_usdClassTransfer() public {
        wrapper.usdClassTransfer(1e8, true);
        bytes memory payload = _getLastPayload();
        // Action ID 7: 0x000007
        assertEq(uint8(payload[1]), 0x00);
        assertEq(uint8(payload[2]), 0x00);
        assertEq(uint8(payload[3]), 0x07);
    }

    function test_actionId_cancelOrder() public {
        wrapper.cancelOrder(10107, 42);
        bytes memory payload = _getLastPayload();
        // Action ID 10: 0x00000A
        assertEq(uint8(payload[1]), 0x00);
        assertEq(uint8(payload[2]), 0x00);
        assertEq(uint8(payload[3]), 0x0A);
    }

    // ═══ Payload length ═══

    function test_limitOrder_payloadLength() public {
        wrapper.placeLimitOrder(10107, true, 2500000000, 100000000, false, 2, 0);
        bytes memory payload = _getLastPayload();
        // 4 bytes header + abi.encode(uint32, bool, uint64, uint64, bool, uint8, uint128) = 4 + 7*32 = 228
        assertEq(payload.length, 4 + 7 * 32);
    }

    function test_spotSend_payloadLength() public {
        wrapper.spotSend(address(0x2222222222222222222222222222222222222222), 150, 1e8);
        bytes memory payload = _getLastPayload();
        // 4 bytes header + abi.encode(address, uint64, uint64) = 4 + 3*32 = 100
        assertEq(payload.length, 4 + 3 * 32);
    }

    function test_cancelOrder_payloadLength() public {
        wrapper.cancelOrder(10107, 42);
        bytes memory payload = _getLastPayload();
        // 4 + abi.encode(uint32, uint64) = 4 + 2*32 = 68
        assertEq(payload.length, 4 + 2 * 32);
    }

    // ═══ Params encoding ═══

    function test_limitOrder_paramsDecoding() public {
        uint32 asset = 10107;
        bool isBuy = true;
        uint64 limitPx = 2500000000;
        uint64 sz = 100000000;
        bool reduceOnly = false;
        uint8 tif = 3; // IOC
        uint128 cloid = 12345;

        wrapper.placeLimitOrder(asset, isBuy, limitPx, sz, reduceOnly, tif, cloid);
        bytes memory payload = _getLastPayload();

        // Skip 4-byte header, decode params
        bytes memory params = new bytes(payload.length - 4);
        for (uint256 i = 0; i < params.length; i++) {
            params[i] = payload[4 + i];
        }

        (
            uint32 dAsset,
            bool dIsBuy,
            uint64 dLimitPx,
            uint64 dSz,
            bool dReduceOnly,
            uint8 dTif,
            uint128 dCloid
        ) = abi.decode(params, (uint32, bool, uint64, uint64, bool, uint8, uint128));

        assertEq(dAsset, asset);
        assertTrue(dIsBuy);
        assertEq(dLimitPx, limitPx);
        assertEq(dSz, sz);
        assertFalse(dReduceOnly);
        assertEq(dTif, tif);
        assertEq(dCloid, cloid);
    }

    function test_spotSend_paramsDecoding() public {
        address dest = 0x2222222222222222222222222222222222222222;
        uint64 tokenIndex = 150;
        uint64 weiAmount = 5e8;

        wrapper.spotSend(dest, tokenIndex, weiAmount);
        bytes memory payload = _getLastPayload();

        bytes memory params = new bytes(payload.length - 4);
        for (uint256 i = 0; i < params.length; i++) {
            params[i] = payload[4 + i];
        }

        (address dDest, uint64 dIdx, uint64 dAmt) = abi.decode(params, (address, uint64, uint64));
        assertEq(dDest, dest);
        assertEq(dIdx, tokenIndex);
        assertEq(dAmt, weiAmount);
    }

    // ═══ Fuzz ═══

    function testFuzz_actionId_bigEndian(uint24 actionId) public pure {
        bytes memory data = new bytes(4);
        data[0] = bytes1(uint8(0x01));
        data[1] = bytes1(uint8(actionId >> 16));
        data[2] = bytes1(uint8(actionId >> 8));
        data[3] = bytes1(uint8(actionId));

        uint24 decoded = uint24(uint8(data[1])) << 16 | uint24(uint8(data[2])) << 8 | uint24(uint8(data[3]));
        assertEq(decoded, actionId);
    }
}
