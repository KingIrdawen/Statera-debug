// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

library DecimalLib {
    function evmToCore(uint256 evmWei, uint8 evmDecimals, uint8 coreWeiDecimals)
        internal
        pure
        returns (uint64)
    {
        uint256 result;
        if (evmDecimals > coreWeiDecimals) {
            result = evmWei / (10 ** (evmDecimals - coreWeiDecimals));
        } else if (evmDecimals < coreWeiDecimals) {
            result = evmWei * (10 ** (coreWeiDecimals - evmDecimals));
        } else {
            result = evmWei;
        }
        require(result <= type(uint64).max, "evmToCore overflow");
        return uint64(result);
    }

    function coreToEvm(uint64 coreWei, uint8 coreWeiDecimals, uint8 evmDecimals)
        internal
        pure
        returns (uint256)
    {
        if (evmDecimals > coreWeiDecimals) {
            return uint256(coreWei) * (10 ** (evmDecimals - coreWeiDecimals));
        } else if (evmDecimals < coreWeiDecimals) {
            return uint256(coreWei) / (10 ** (coreWeiDecimals - evmDecimals));
        } else {
            return uint256(coreWei);
        }
    }
}
