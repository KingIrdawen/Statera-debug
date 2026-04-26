// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {PriceLib} from "./PriceLib.sol";
import {SizeLib} from "./SizeLib.sol";

/// @title SettlementLib — Pure computation for batch settlement orders
/// @notice Computes sell TOKEN→USDC and buy HYPE←USDC orders for settlement
library SettlementLib {
    struct SpotOrder {
        uint32 asset;
        bool isBuy;
        uint64 limitPx; // precompile format: human * 10^(8-szDec)
        uint64 sz; // 1e8 * human_size
    }

    /// @notice Compute a sell order for all TOKEN on Core → USDC
    /// @param tokenCoreBalance Token balance on Core in weiDecimals
    /// @param tokenPx Token price in precompile format
    /// @param tokenAsset 10000 + spotMarketIndex
    /// @param tokenSzDec szDecimals for TOKEN
    /// @param tokenWeiDec weiDecimals for TOKEN
    /// @param slippageBps Slippage in basis points
    function computeSellTokenOrder(
        uint64 tokenCoreBalance,
        uint64 tokenPx,
        uint32 tokenAsset,
        uint8 tokenSzDec,
        uint8 tokenWeiDec,
        uint256 slippageBps
    ) public pure returns (bool valid, SpotOrder memory order) {
        if (tokenCoreBalance == 0 || tokenPx == 0) return (false, order);

        // Convert Core balance → sz format (1e8 * human)
        uint64 sz = SizeLib.formatLotSize(uint256(tokenCoreBalance), tokenWeiDec, tokenSzDec);
        if (sz == 0) return (false, order);

        // Apply slippage DOWN (worst case lower sell price)
        uint64 limitPx = PriceLib.formatTickPrice(
            uint256(PriceLib.applySlippageDown(tokenPx, slippageBps)), tokenSzDec
        );
        if (limitPx == 0) return (false, order);

        // Check min notional ($10)
        if (!SizeLib.isAboveMinNotional(sz, limitPx, tokenSzDec)) {
            return (false, order);
        }

        order = SpotOrder(tokenAsset, false, limitPx, sz);
        valid = true;
    }

    /// @notice Compute a buy order for HYPE using USDC on Core
    /// @param usdcCoreBalance USDC balance on Core in weiDecimals (8)
    /// @param hypePx HYPE price in precompile format
    /// @param hypeAsset 10000 + hypeSpotMarketIndex
    /// @param hypeSzDec szDecimals for HYPE (2)
    /// @param slippageBps Slippage in basis points
    function computeBuyHypeOrder(
        uint64 usdcCoreBalance,
        uint64 hypePx,
        uint32 hypeAsset,
        uint8 hypeSzDec,
        uint256 slippageBps
    ) public pure returns (bool valid, SpotOrder memory order) {
        if (usdcCoreBalance == 0 || hypePx == 0) return (false, order);

        // USDC is in 8 dec (= USDC value directly)
        // sz_1e8 = usdcValue * 10^(8-szDec) / spotPx
        uint256 rawSz = uint256(usdcCoreBalance) * (10 ** (8 - hypeSzDec)) / uint256(hypePx);

        // Round down to lot size
        uint256 granularity = 10 ** (8 - hypeSzDec);
        rawSz = (rawSz / granularity) * granularity;

        if (rawSz == 0 || rawSz > type(uint64).max) return (false, order);

        // Apply slippage UP (worst case higher buy price)
        uint64 limitPx = PriceLib.formatTickPrice(
            uint256(PriceLib.applySlippageUp(hypePx, slippageBps)), hypeSzDec
        );
        if (limitPx == 0) return (false, order);

        // Check min notional ($10)
        if (!SizeLib.isAboveMinNotional(uint64(rawSz), limitPx, hypeSzDec)) {
            return (false, order);
        }

        order = SpotOrder(hypeAsset, true, limitPx, uint64(rawSz));
        valid = true;
    }
}
