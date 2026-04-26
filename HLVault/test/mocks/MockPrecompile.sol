// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

/// @notice Mock for HyperCore precompiles. Deploy and etch to precompile addresses.
contract MockPrecompile {
    // Storage for spot balances: keccak256(user, tokenIndex) => (total, hold, entryNtl)
    mapping(bytes32 => uint64) public totalBalances;
    mapping(bytes32 => uint64) public holdBalances;

    // Storage for spot prices: spotMarketIndex => rawPrice
    mapping(uint32 => uint64) public spotPrices;

    // Storage for oracle prices: perpIndex => rawPrice
    mapping(uint32 => uint64) public oraclePrices;

    // L1 block number
    uint64 public l1BlockNumber;

    // Spot asset info: tokenIndex => (weiDecimals, evmContract)
    mapping(uint32 => uint8) public assetWeiDecimals;
    mapping(uint32 => address) public assetEvmContracts;

    // ═══ Setters (for test setup) ═══

    function setSpotBalance(address user, uint32 tokenIndex, uint64 total, uint64 hold) external {
        bytes32 key = keccak256(abi.encode(user, tokenIndex));
        totalBalances[key] = total;
        holdBalances[key] = hold;
    }

    function setSpotPrice(uint32 spotMarketIndex, uint64 rawPrice) external {
        spotPrices[spotMarketIndex] = rawPrice;
    }

    function setOraclePrice(uint32 perpIndex, uint64 rawPrice) external {
        oraclePrices[perpIndex] = rawPrice;
    }

    function setL1BlockNumber(uint64 blockNum) external {
        l1BlockNumber = blockNum;
    }

    function setSpotAssetInfo(uint32 tokenIndex, uint8 weiDec, address evmContract) external {
        assetWeiDecimals[tokenIndex] = weiDec;
        assetEvmContracts[tokenIndex] = evmContract;
    }

    // ═══ Fallback: routes staticcalls based on which address this is etched to ═══

    fallback(bytes calldata input) external returns (bytes memory) {
        // Determine which precompile we're mimicking based on the code address
        // The test will etch this contract to the appropriate address.
        // We use a dispatch approach: each precompile address has its own logic.

        // 0x801 — Spot Balance
        if (address(this) == address(0x0000000000000000000000000000000000000801)) {
            (address user, uint32 tokenIndex) = abi.decode(input, (address, uint32));
            bytes32 key = keccak256(abi.encode(user, tokenIndex));
            return abi.encode(totalBalances[key], holdBalances[key], uint64(0));
        }

        // 0x807 — Oracle Price
        if (address(this) == address(0x0000000000000000000000000000000000000807)) {
            uint32 perpIndex = abi.decode(input, (uint32));
            return abi.encode(oraclePrices[perpIndex]);
        }

        // 0x808 — Spot Price
        if (address(this) == address(0x0000000000000000000000000000000000000808)) {
            uint32 spotMarketIndex = abi.decode(input, (uint32));
            return abi.encode(spotPrices[spotMarketIndex]);
        }

        // 0x809 — L1 Block Number
        if (address(this) == address(0x0000000000000000000000000000000000000809)) {
            return abi.encode(l1BlockNumber);
        }

        // 0x80C — Token Info (weiDecimals, evmContract)
        if (address(this) == address(0x000000000000000000000000000000000000080C)) {
            uint32 tokenIndex = abi.decode(input, (uint32));
            return abi.encode(assetWeiDecimals[tokenIndex], assetEvmContracts[tokenIndex]);
        }

        revert("MockPrecompile: unknown precompile");
    }
}
