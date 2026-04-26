// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {PriceLib} from "./PriceLib.sol";
import {SizeLib} from "./SizeLib.sol";

/// @title RebalanceLib — Pure computation for auto-rebalance logic
/// @notice Public functions are deployed separately (DELEGATECALL) to save vault bytecode
library RebalanceLib {
    struct PortfolioState {
        uint256 totalUsdc8;
        uint256 hypeUsdc8;
        uint256 tokenUsdc8;
        uint256 usdcUsdc8;
        uint64 hypePx; // precompile format: human * 10^(8-szDec)
        uint64 tokenPx;
        uint64 hypeCoreBalance; // weiDecimals (8)
        uint64 tokenCoreBalance;
        uint64 usdcCoreBalance;
        uint256 hypeEvmAvailable; // EVM wei (18 dec), after reservedHypeForClaims
    }

    struct SpotOrder {
        uint32 asset;
        bool isBuy;
        uint64 limitPx; // precompile format
        uint64 sz; // 1e8 * human_size
    }

    /// @notice Check if portfolio drift exceeds threshold for any asset
    function needsRebalance(
        PortfolioState memory s,
        uint16 targetHypeBps,
        uint16 targetTokenBps,
        uint16 targetUsdcBps,
        uint16 driftThresholdBps
    ) public pure returns (bool) {
        if (s.totalUsdc8 == 0) return false;

        uint256 hypeBps = s.hypeUsdc8 * 10000 / s.totalUsdc8;
        uint256 tokenBps = s.tokenUsdc8 * 10000 / s.totalUsdc8;
        uint256 usdcBps = s.usdcUsdc8 * 10000 / s.totalUsdc8;

        if (_absDiff(hypeBps, targetHypeBps) > driftThresholdBps) return true;
        if (_absDiff(tokenBps, targetTokenBps) > driftThresholdBps) return true;
        if (_absDiff(usdcBps, targetUsdcBps) > driftThresholdBps) return true;

        return false;
    }

    /// @notice Compute trade orders to rebalance the portfolio
    /// @return orders Array of up to 2 orders (HYPE + TOKEN)
    /// @return count Number of valid orders
    function computeOrders(
        PortfolioState memory s,
        uint16 targetHypeBps,
        uint16 targetTokenBps,
        uint32 hypeAsset,
        uint32 tokenAsset,
        uint8 hypeSzDec,
        uint8 tokenSzDec,
        uint256 slippageBps,
        uint256 minNotionalUsdc8
    ) public pure returns (SpotOrder[] memory orders, uint256 count) {
        orders = new SpotOrder[](2);
        count = 0;

        uint256 targetHypeUsdc8 = s.totalUsdc8 * targetHypeBps / 10000;
        uint256 targetTokenUsdc8 = s.totalUsdc8 * targetTokenBps / 10000;

        // HYPE order
        {
            int256 deltaHype = int256(targetHypeUsdc8) - int256(s.hypeUsdc8);
            if (deltaHype != 0) {
                uint256 absDelta = deltaHype > 0 ? uint256(deltaHype) : uint256(-deltaHype);
                if (absDelta >= minNotionalUsdc8) {
                    (bool valid, SpotOrder memory o) =
                        _buildOrder(hypeAsset, deltaHype > 0, absDelta, s.hypePx, hypeSzDec, slippageBps);
                    if (valid) {
                        orders[count++] = o;
                    }
                }
            }
        }

        // TOKEN order
        {
            int256 deltaToken = int256(targetTokenUsdc8) - int256(s.tokenUsdc8);
            if (deltaToken != 0) {
                uint256 absDelta = deltaToken > 0 ? uint256(deltaToken) : uint256(-deltaToken);
                if (absDelta >= minNotionalUsdc8) {
                    (bool valid, SpotOrder memory o) =
                        _buildOrder(tokenAsset, deltaToken > 0, absDelta, s.tokenPx, tokenSzDec, slippageBps);
                    if (valid) {
                        orders[count++] = o;
                    }
                }
            }
        }
    }

    /// @notice Compute how much HYPE (in EVM wei 18 dec) to bridge from EVM to Core
    /// @dev Only needed when selling HYPE (bridge EVM→Core for the sell order)
    function computeBridgeInAmount(
        PortfolioState memory s,
        SpotOrder[] memory orders,
        uint256 count,
        uint32 hypeAsset,
        uint8 hypeWeiDec
    ) public pure returns (uint256 hypeEvmWei) {
        // Find the HYPE sell order
        uint64 sellSz = 0;
        for (uint256 i = 0; i < count; i++) {
            if (orders[i].asset == hypeAsset && !orders[i].isBuy) {
                sellSz = orders[i].sz;
                break;
            }
        }
        if (sellSz == 0) return 0;

        // Convert sz (1e8 * human) to Core weiDecimals
        // human = sz / 1e8, core = human * 10^weiDec = sz * 10^weiDec / 1e8
        uint256 coreAmount;
        if (hypeWeiDec >= 8) {
            coreAmount = uint256(sellSz) * (10 ** (hypeWeiDec - 8));
        } else {
            coreAmount = uint256(sellSz) / (10 ** (8 - hypeWeiDec));
        }

        // Subtract what's already on Core
        if (coreAmount <= uint256(s.hypeCoreBalance)) return 0;
        coreAmount -= uint256(s.hypeCoreBalance);

        // Convert to EVM wei (18 dec) with 5% buffer
        hypeEvmWei = coreAmount * (10 ** (18 - hypeWeiDec));
        hypeEvmWei = hypeEvmWei * 105 / 100;

        // Cap at available
        if (hypeEvmWei > s.hypeEvmAvailable) {
            hypeEvmWei = s.hypeEvmAvailable;
        }
    }

    // ═══ Private helpers ═══

    function _buildOrder(
        uint32 asset,
        bool isBuy,
        uint256 deltaUsdc8,
        uint64 spotPx,
        uint8 szDec,
        uint256 slippageBps
    ) private pure returns (bool valid, SpotOrder memory order) {
        // sz_1e8 = deltaUsdc8 * 10^(8-szDec) / spotPx
        uint256 rawSz = deltaUsdc8 * (10 ** (8 - szDec)) / uint256(spotPx);

        // Round down to lot size
        uint256 granularity = 10 ** (8 - szDec);
        rawSz = (rawSz / granularity) * granularity;

        if (rawSz == 0 || rawSz > type(uint64).max) return (false, order);

        // Apply slippage and format to tick size
        uint64 limitPx;
        if (isBuy) {
            limitPx = PriceLib.formatTickPrice(
                uint256(PriceLib.applySlippageUp(spotPx, slippageBps)), szDec
            );
        } else {
            limitPx = PriceLib.formatTickPrice(
                uint256(PriceLib.applySlippageDown(spotPx, slippageBps)), szDec
            );
        }

        // Check min notional ($10)
        if (!SizeLib.isAboveMinNotional(uint64(rawSz), limitPx, szDec)) {
            return (false, order);
        }

        order = SpotOrder(asset, isBuy, limitPx, uint64(rawSz));
        valid = true;
    }

    function _absDiff(uint256 a, uint256 b) private pure returns (uint256) {
        return a >= b ? a - b : b - a;
    }
}
