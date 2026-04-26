// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {CoreActionLib} from "./CoreActionLib.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {ICoreDepositWallet} from "../interfaces/ICoreDepositWallet.sol";

library BridgeLib {
    using SafeERC20 for IERC20;

    address constant HYPE_BRIDGE = 0x2222222222222222222222222222222222222222;

    /// @notice Bridge HYPE from EVM to Core
    function bridgeHypeEvmToCore(uint256 amount) internal {
        (bool ok,) = payable(HYPE_BRIDGE).call{value: amount}("");
        require(ok, "HYPE bridge failed");
    }

    /// @notice Bridge HYPE from Core to EVM via CoreWriter Action 6 (Spot Send)
    /// @param hypeTokenIndex HYPE token index on Core
    /// @param weiAmount Amount in HYPE weiDecimals (8)
    function bridgeHypeCoreToEvm(uint64 hypeTokenIndex, uint64 weiAmount) internal {
        CoreActionLib.spotSend(HYPE_BRIDGE, hypeTokenIndex, weiAmount);
    }

    /// @notice Bridge an ERC-20 token from EVM to Core
    /// @param token ERC-20 token address on EVM
    /// @param tokenIndex Token index on Core (used to compute system address)
    /// @param amount Amount in EVM decimals
    function bridgeTokenEvmToCore(address token, uint32 tokenIndex, uint256 amount) internal {
        address systemAddr = buildSystemAddress(tokenIndex);
        IERC20(token).safeTransfer(systemAddr, amount);
    }

    /// @notice Bridge USDC from EVM to Core via the CoreDepositWallet.
    /// @dev The deposit wallet address comes from Hyperliquid spotMeta for token index 0.
    function bridgeUsdcEvmToCore(address usdcToken, address coreDepositWallet, uint256 amount) internal {
        IERC20(usdcToken).forceApprove(coreDepositWallet, amount);
        ICoreDepositWallet(coreDepositWallet).deposit(amount);
    }

    /// @notice Bridge a token from Core to EVM via CoreWriter Action 6 (Spot Send)
    /// @param tokenIndex Token index on Core
    /// @param weiAmount Amount in weiDecimals
    function bridgeTokenCoreToEvm(uint64 tokenIndex, uint64 weiAmount) internal {
        address systemAddr = buildSystemAddress(uint32(tokenIndex));
        CoreActionLib.spotSend(systemAddr, tokenIndex, weiAmount);
    }

    /// @notice Build the system address for a token bridge
    /// @dev Format: 0x2000...{tokenIndex in big-endian hex, last 4 bytes}
    function buildSystemAddress(uint32 tokenIndex) internal pure returns (address) {
        // 0x2000000000000000000000000000000000000000 + tokenIndex
        return address(uint160(0x2000000000000000000000000000000000000000) + uint160(tokenIndex));
    }
}
