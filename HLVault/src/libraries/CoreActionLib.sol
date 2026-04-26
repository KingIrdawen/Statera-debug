// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {ICoreWriter, CORE_WRITER} from "../interfaces/ICoreWriter.sol";

library CoreActionLib {
    uint8 constant VERSION = 0x01;

    function _buildPayload(uint24 actionId, bytes memory params) internal pure returns (bytes memory) {
        bytes memory data = new bytes(4 + params.length);
        data[0] = bytes1(VERSION);
        data[1] = bytes1(uint8(actionId >> 16));
        data[2] = bytes1(uint8(actionId >> 8));
        data[3] = bytes1(uint8(actionId));
        for (uint256 i = 0; i < params.length; i++) {
            data[4 + i] = params[i];
        }
        return data;
    }

    /// @notice Place a limit order (Action ID 1)
    /// @param asset 10000 + spotMarketIndex for spot
    /// @param isBuy true = buy, false = sell
    /// @param limitPx 1e8 * human_price
    /// @param sz 1e8 * human_size
    /// @param reduceOnly Whether reduce-only
    /// @param tif Time-in-force: 1=ALO, 2=GTC, 3=IOC
    /// @param cloid Client order ID
    function placeLimitOrder(
        uint32 asset,
        bool isBuy,
        uint64 limitPx,
        uint64 sz,
        bool reduceOnly,
        uint8 tif,
        uint128 cloid
    ) internal {
        bytes memory params = abi.encode(asset, isBuy, limitPx, sz, reduceOnly, tif, cloid);
        bytes memory payload = _buildPayload(1, params);
        ICoreWriter(CORE_WRITER).sendRawAction(payload);
    }

    /// @notice Spot Send (Action ID 6) — transfer tokens on Core
    /// @param dest Destination address (system address for bridge)
    /// @param tokenIndex Token index on Core
    /// @param weiAmount Amount in weiDecimals
    function spotSend(address dest, uint64 tokenIndex, uint64 weiAmount) internal {
        bytes memory params = abi.encode(dest, tokenIndex, weiAmount);
        bytes memory payload = _buildPayload(6, params);
        ICoreWriter(CORE_WRITER).sendRawAction(payload);
    }

    /// @notice USD Class Transfer (Action ID 7)
    /// @param ntl Notional amount
    /// @param toPerp true = spot->perp, false = perp->spot
    function usdClassTransfer(uint64 ntl, bool toPerp) internal {
        bytes memory params = abi.encode(ntl, toPerp);
        bytes memory payload = _buildPayload(7, params);
        ICoreWriter(CORE_WRITER).sendRawAction(payload);
    }

    /// @notice Cancel Order (Action ID 10)
    /// @param asset Asset ID
    /// @param oid Order ID to cancel
    function cancelOrder(uint32 asset, uint64 oid) internal {
        bytes memory params = abi.encode(asset, oid);
        bytes memory payload = _buildPayload(10, params);
        ICoreWriter(CORE_WRITER).sendRawAction(payload);
    }
}
