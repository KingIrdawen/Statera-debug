// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

library PrecompileLib {
    address constant SPOT_BALANCE = 0x0000000000000000000000000000000000000801;
    address constant ORACLE_PRICE = 0x0000000000000000000000000000000000000807;
    address constant SPOT_PRICE = 0x0000000000000000000000000000000000000808;
    address constant L1_BLOCK_NUMBER = 0x0000000000000000000000000000000000000809;
    address constant SPOT_ASSET_INFO = 0x000000000000000000000000000000000000080C;

    /// @notice Get spot balance for an address on HyperCore
    /// @return total Total balance in weiDecimals
    /// @return hold Amount held in open orders
    function getSpotBalance(address user, uint32 tokenIndex)
        internal
        view
        returns (uint64 total, uint64 hold)
    {
        (bool ok, bytes memory data) =
            SPOT_BALANCE.staticcall(abi.encode(user, tokenIndex));
        require(ok, "spotBalance precompile failed");
        (total, hold,) = abi.decode(data, (uint64, uint64, uint64));
    }

    /// @notice Get spot market price
    /// @param spotMarketIndex The spot market pair index
    /// @return rawPrice Raw price from precompile
    function getSpotPrice(uint32 spotMarketIndex) internal view returns (uint64 rawPrice) {
        (bool ok, bytes memory data) =
            SPOT_PRICE.staticcall(abi.encode(spotMarketIndex));
        require(ok, "spotPrice precompile failed");
        rawPrice = abi.decode(data, (uint64));
    }

    /// @notice Get oracle price (perps)
    function getOraclePrice(uint32 perpIndex) internal view returns (uint64 rawPrice) {
        (bool ok, bytes memory data) =
            ORACLE_PRICE.staticcall(abi.encode(perpIndex));
        require(ok, "oraclePrice precompile failed");
        rawPrice = abi.decode(data, (uint64));
    }

    /// @notice Get the current L1 block number
    /// @dev Falls back to block.number when precompile is unavailable (testnet)
    // TODO: remove fallback before mainnet deploy
    function getL1BlockNumber() internal view returns (uint64 l1Block) {
        (bool ok, bytes memory data) = L1_BLOCK_NUMBER.staticcall{gas: 10_000}("");
        if (ok && data.length >= 32) {
            l1Block = abi.decode(data, (uint64));
        } else {
            l1Block = uint64(block.number);
        }
    }

    /// @notice Get spot asset info
    function getSpotAssetInfo(uint32 tokenIndex)
        internal
        view
        returns (uint8 weiDecimals, address evmContract)
    {
        (bool ok, bytes memory data) =
            SPOT_ASSET_INFO.staticcall(abi.encode(tokenIndex));
        require(ok, "spotAssetInfo precompile failed");
        (weiDecimals, evmContract) = abi.decode(data, (uint8, address));
    }
}
