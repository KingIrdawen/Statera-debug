// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "forge-std/Test.sol";
import {PrecompileLib} from "../../src/libraries/PrecompileLib.sol";
import {MockPrecompile} from "../mocks/MockPrecompile.sol";

contract PrecompileLibTest is Test {
    function setUp() public {
        _etchPrecompiles();
    }

    function _etchPrecompiles() internal {
        MockPrecompile spotBalanceMock = new MockPrecompile();
        MockPrecompile oraclePriceMock = new MockPrecompile();
        MockPrecompile spotPriceMock = new MockPrecompile();
        MockPrecompile l1BlockMock = new MockPrecompile();
        MockPrecompile spotAssetInfoMock = new MockPrecompile();

        vm.etch(address(0x0000000000000000000000000000000000000801), address(spotBalanceMock).code);
        vm.etch(address(0x0000000000000000000000000000000000000807), address(oraclePriceMock).code);
        vm.etch(address(0x0000000000000000000000000000000000000808), address(spotPriceMock).code);
        vm.etch(address(0x0000000000000000000000000000000000000809), address(l1BlockMock).code);
        vm.etch(address(0x000000000000000000000000000000000000080C), address(spotAssetInfoMock).code);
    }

    // ═══ Precompile addresses ═══

    function test_constants() public pure {
        assertEq(PrecompileLib.SPOT_BALANCE, address(0x801));
        assertEq(PrecompileLib.ORACLE_PRICE, address(0x807));
        assertEq(PrecompileLib.SPOT_PRICE, address(0x808));
        assertEq(PrecompileLib.L1_BLOCK_NUMBER, address(0x809));
        assertEq(PrecompileLib.SPOT_ASSET_INFO, address(0x80C));
    }

    // ═══ getSpotBalance ═══

    function test_getSpotBalance_returnsZeroByDefault() public view {
        (uint64 total, uint64 hold) = PrecompileLib.getSpotBalance(address(0x1234), 150);
        assertEq(total, 0);
        assertEq(hold, 0);
    }

    function test_getSpotBalance_returnsSetValues() public {
        address user = address(0xBEEF);
        uint32 tokenIndex = 150;
        uint64 totalVal = 5e8;
        uint64 holdVal = 1e8;

        // Write to MockPrecompile storage at 0x801
        bytes32 key = keccak256(abi.encode(user, tokenIndex));
        bytes32 totalSlot = keccak256(abi.encode(key, uint256(0)));
        bytes32 holdSlot = keccak256(abi.encode(key, uint256(1)));
        vm.store(address(0x801), totalSlot, bytes32(uint256(totalVal)));
        vm.store(address(0x801), holdSlot, bytes32(uint256(holdVal)));

        (uint64 total, uint64 hold) = PrecompileLib.getSpotBalance(user, tokenIndex);
        assertEq(total, totalVal);
        assertEq(hold, holdVal);
    }

    // ═══ getSpotPrice ═══

    function test_getSpotPrice_returnsZeroByDefault() public view {
        uint64 price = PrecompileLib.getSpotPrice(107);
        assertEq(price, 0);
    }

    function test_getSpotPrice_returnsSetValue() public {
        uint32 spotIdx = 107;
        uint64 rawPrice = 25000000; // $25, szDec=2

        bytes32 slot = keccak256(abi.encode(uint256(spotIdx), uint256(2)));
        vm.store(address(0x808), slot, bytes32(uint256(rawPrice)));

        uint64 price = PrecompileLib.getSpotPrice(spotIdx);
        assertEq(price, rawPrice);
    }

    // ═══ getOraclePrice ═══

    function test_getOraclePrice_returnsSetValue() public {
        uint32 perpIdx = 3;
        uint64 rawPrice = 300000000;

        bytes32 slot = keccak256(abi.encode(uint256(perpIdx), uint256(3)));
        vm.store(address(0x807), slot, bytes32(uint256(rawPrice)));

        uint64 price = PrecompileLib.getOraclePrice(perpIdx);
        assertEq(price, rawPrice);
    }

    // ═══ getL1BlockNumber ═══

    function test_getL1BlockNumber_returnsSetValue() public {
        uint64 blockNum = 42;
        vm.store(address(0x809), bytes32(uint256(4)), bytes32(uint256(blockNum)));

        uint64 result = PrecompileLib.getL1BlockNumber();
        assertEq(result, blockNum);
    }

    function test_getL1BlockNumber_differentValues() public {
        vm.store(address(0x809), bytes32(uint256(4)), bytes32(uint256(999999)));
        assertEq(PrecompileLib.getL1BlockNumber(), 999999);

        vm.store(address(0x809), bytes32(uint256(4)), bytes32(uint256(0)));
        assertEq(PrecompileLib.getL1BlockNumber(), 0);
    }

    // ═══ getSpotAssetInfo ═══

    function test_getSpotAssetInfo_HYPE() public {
        uint32 tokenIdx = 150;

        // weiDecimals mapping at slot 5, evmContracts at slot 6
        bytes32 weiSlot = keccak256(abi.encode(uint256(tokenIdx), uint256(5)));
        bytes32 evmSlot = keccak256(abi.encode(uint256(tokenIdx), uint256(6)));
        vm.store(address(0x80C), weiSlot, bytes32(uint256(8)));
        vm.store(address(0x80C), evmSlot, bytes32(uint256(uint160(address(0)))));

        (uint8 weiDec, address evmContract) = PrecompileLib.getSpotAssetInfo(tokenIdx);
        assertEq(weiDec, 8);
        assertEq(evmContract, address(0));
    }

    // ═══ Fuzz ═══

    function testFuzz_getSpotPrice_roundTrip(uint32 spotIdx, uint64 rawPrice) public {
        bytes32 slot = keccak256(abi.encode(uint256(spotIdx), uint256(2)));
        vm.store(address(0x808), slot, bytes32(uint256(rawPrice)));

        uint64 result = PrecompileLib.getSpotPrice(spotIdx);
        assertEq(result, rawPrice);
    }
}
