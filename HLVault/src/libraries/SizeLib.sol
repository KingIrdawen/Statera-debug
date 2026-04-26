// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

library SizeLib {
    /// @notice Format a size to Hyperliquid lot size rules:
    ///         - Round DOWN to szDecimals decimal places
    ///         - Returns sz = 1e8 * human_size
    /// @param rawSizeCore Size in core weiDecimals format
    /// @param weiDecimals The weiDecimals of the token on Core
    /// @param szDecimals The szDecimals of the token
    function formatLotSize(uint256 rawSizeCore, uint8 weiDecimals, uint8 szDecimals)
        internal
        pure
        returns (uint64)
    {
        // rawSizeCore is in 10^weiDecimals
        // human_size = rawSizeCore / 10^weiDecimals
        // sz = 1e8 * human_size = rawSizeCore * 1e8 / 10^weiDecimals
        // Then round down to szDecimals decimal places in human terms
        // In 1e8 format, the granularity is 10^(8 - szDecimals)

        uint256 sz;
        if (weiDecimals >= 8) {
            sz = rawSizeCore / (10 ** (weiDecimals - 8));
        } else {
            sz = rawSizeCore * (10 ** (8 - weiDecimals));
        }

        // Round down to szDecimals decimal places (in 1e8 format)
        uint256 granularity = 10 ** (8 - szDecimals);
        sz = (sz / granularity) * granularity;

        require(sz <= type(uint64).max, "size overflow");
        return uint64(sz);
    }

    /// @notice Check if an order meets the minimum notional (~$10)
    /// @param sz Size in 1e8 * human_size format
    /// @param px Price in human_price * 10^(8-szDecimals) format (precompile/Core format)
    /// @param szDecimals The szDecimals of the token
    function isAboveMinNotional(uint64 sz, uint64 px, uint8 szDecimals) internal pure returns (bool) {
        // human_notional = (sz / 1e8) * (px / 10^(8-szDecimals))
        // = sz * px / (1e8 * 10^(8-szDecimals))
        // We need human_notional >= 10, so:
        // sz * px >= 10 * 1e8 * 10^(8-szDecimals) = 1e9 * 10^(8-szDecimals)
        uint256 notional = uint256(sz) * uint256(px);
        uint256 threshold = 1e9 * (10 ** (8 - szDecimals));
        return notional >= threshold;
    }
}
