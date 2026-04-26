// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

library PriceLib {
    /// @notice Format a price to Hyperliquid tick size rules:
    ///         - Max 5 significant figures
    ///         - Max (8 - szDecimals) decimal places
    ///         - Returns limitPx = 1e8 * human_price (rounded DOWN)
    /// @param rawPriceUsdc8 Price in USDC 8-decimal format (1e8 * human_price)
    /// @param szDecimals The szDecimals of the base token
    function formatTickPrice(uint256 rawPriceUsdc8, uint8 szDecimals) internal pure returns (uint64) {
        require(rawPriceUsdc8 > 0, "zero price");
        require(rawPriceUsdc8 <= type(uint64).max, "price overflow");

        // Max decimal places in human price = 8 - szDecimals
        // In 1e8 format, this means minimum granularity = 10^szDecimals
        uint256 minGranularity = 10 ** szDecimals;

        // Round down to min granularity
        uint256 price = (rawPriceUsdc8 / minGranularity) * minGranularity;

        // Per Hyperliquid: "integer prices are always allowed, regardless of significant figures"
        // An integer human price means price % 10^(8-szDecimals) == 0
        // Only truncate non-integer prices to max 5 significant figures
        uint256 integerUnit = 10 ** (8 - szDecimals);
        if (price % integerUnit != 0) {
            price = _truncateToSigFigs(price, 5);
        }

        require(price > 0, "price rounds to zero");
        return uint64(price);
    }

    /// @notice Apply slippage UP (for buy orders — worst case higher price)
    function applySlippageUp(uint64 price, uint256 bps) internal pure returns (uint64) {
        uint256 result = uint256(price) * (10000 + bps) / 10000;
        require(result <= type(uint64).max, "slippage overflow");
        return uint64(result);
    }

    /// @notice Apply slippage DOWN (for sell orders — worst case lower price)
    function applySlippageDown(uint64 price, uint256 bps) internal pure returns (uint64) {
        return uint64(uint256(price) * (10000 - bps) / 10000);
    }

    /// @dev Truncate a number to at most `n` significant figures (round DOWN)
    function _truncateToSigFigs(uint256 value, uint8 n) internal pure returns (uint256) {
        if (value == 0) return 0;

        // Find the number of digits
        uint256 digits = 0;
        uint256 temp = value;
        while (temp > 0) {
            digits++;
            temp /= 10;
        }

        if (digits <= n) return value;

        // Truncate: zero out the least significant (digits - n) digits
        uint256 divisor = 10 ** (digits - n);
        return (value / divisor) * divisor;
    }
}
