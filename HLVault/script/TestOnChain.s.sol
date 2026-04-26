// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {RebalancingVault} from "../src/core/RebalancingVault.sol";
import {VaultFactory} from "../src/core/VaultFactory.sol";

/// @title Phase 2 On-Chain Test Runner
/// @notice Uses EXISTING deployed Factory on testnet — split into individual test functions
/// @dev HyperEVM block gas limit is ~3M, so each test is a separate tx
///
/// Uses existing testnet contracts:
///   Factory: 0x851489d96D561C1c149cC32e8bb5Bb149e2061D0
contract OnChainTestRunner {
    // ═══ Existing testnet infrastructure ═══
    VaultFactory constant FACTORY = VaultFactory(0x851489d96D561C1c149cC32e8bb5Bb149e2061D0);

    // ═══ Testnet constants (PURR) ═══
    address constant PURR_TOKEN = 0xa9056c15938f9aff34CD497c722Ce33dB0C2fD57;

    // ═══ Precompile addresses ═══
    address constant SPOT_PRICE = address(0x808);

    // ═══ State ═══
    address public owner;
    uint256 public passed;
    uint256 public failed;

    // ═══ Events ═══
    event TestResult(string label, bool ok);
    event TestLog(string key, uint256 value);

    constructor() {
        owner = msg.sender;
    }

    modifier onlyOwner() {
        require(msg.sender == owner, "only owner");
        _;
    }

    /// @notice Test 1: Precompile reads (spot prices)
    function testPrecompiles() external onlyOwner {
        // HYPE spot price (market 1035)
        (bool ok2, bytes memory ret2) = SPOT_PRICE.staticcall(abi.encode(uint256(1035)));
        uint64 hypePx = ok2 && ret2.length >= 32 ? abi.decode(ret2, (uint64)) : 0;
        _check(hypePx > 0, "HYPE price > 0");
        _check(hypePx > 1_000_000, "HYPE > $1");
        emit TestLog("hypePx", hypePx);

        // PURR spot price (market 0)
        (bool ok3, bytes memory ret3) = SPOT_PRICE.staticcall(abi.encode(uint256(0)));
        uint64 purrPx = ok3 && ret3.length >= 32 ? abi.decode(ret3, (uint64)) : 0;
        emit TestLog("purrPx", purrPx);
    }

    /// @notice Test 2: Factory state
    function testFactory() external onlyOwner {
        _check(address(FACTORY).code.length > 0, "factory has code");
        _check(FACTORY.keeper() != address(0), "factory has keeper");
        _check(FACTORY.vaultCount() >= 1, "factory has vaults");
        emit TestLog("vaultCount", FACTORY.vaultCount());

        address purrVault = FACTORY.vaults(PURR_TOKEN);
        _check(purrVault != address(0), "PURR vault exists");
        emit TestLog("purrVault", uint256(uint160(purrVault)));
    }

    /// @notice Test 3: Vault view functions (grossAssets, sharePrice)
    function testVaultViews() external onlyOwner {
        address purrVaultAddr = FACTORY.vaults(PURR_TOKEN);
        require(purrVaultAddr != address(0), "no vault");

        RebalancingVault vault = RebalancingVault(payable(purrVaultAddr));

        uint256 ga = vault.grossAssets();
        _check(ga > 0 || vault.totalSupply() == 0, "grossAssets sane");
        emit TestLog("grossAssets", ga);

        uint256 sp = vault.sharePriceUsdc8();
        _check(sp > 0, "sharePrice > 0");
        emit TestLog("sharePriceUsdc8", sp);

        uint64 l1 = vault.getL1BlockNumber();
        _check(l1 > 0, "vault L1 block > 0");
        emit TestLog("l1Block", l1);
    }

    /// @notice Test 4: Vault state (phase, supply)
    function testVaultState() external onlyOwner {
        address purrVaultAddr = FACTORY.vaults(PURR_TOKEN);
        require(purrVaultAddr != address(0), "no vault");

        RebalancingVault vault = RebalancingVault(payable(purrVaultAddr));

        (, RebalancingVault.RebalancePhase phase,,,,,,) = vault.currentCycle();
        _check(uint8(phase) <= 7, "valid phase");
        emit TestLog("phase", uint8(phase));

        emit TestLog("totalSupply", vault.totalSupply());
        emit TestLog("circulatingShares", vault.circulatingShares());
        emit TestLog("escrowedShares", vault.escrowedShares());
        emit TestLog("vaultBalance", address(vault).balance);

        // targetHypeBps/targetTokenBps only exist on vaults with advanceRebalance
        // Use low-level call to avoid revert on older vaults
        (bool ok, bytes memory ret) = purrVaultAddr.staticcall(
            abi.encodeWithSignature("targetHypeBps()")
        );
        if (ok && ret.length >= 32) {
            uint16 hypeBps = abi.decode(ret, (uint16));
            _check(hypeBps > 0, "targetHypeBps set");
            emit TestLog("targetHypeBps", hypeBps);

            (, bytes memory ret2) = purrVaultAddr.staticcall(
                abi.encodeWithSignature("targetTokenBps()")
            );
            uint16 tokenBps = abi.decode(ret2, (uint16));
            _check(tokenBps > 0, "targetTokenBps set");
            emit TestLog("targetTokenBps", tokenBps);
        }
    }

    function _check(bool ok, string memory label) internal {
        emit TestResult(label, ok);
        if (ok) passed++;
        else failed++;
    }

    receive() external payable {}
}
