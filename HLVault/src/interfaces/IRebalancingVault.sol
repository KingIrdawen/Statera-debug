// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

interface IRebalancingVault {
    // ═══ Enums ═══

    enum RebalancePhase {
        IDLE,
        BRIDGING_IN,
        AWAITING_BRIDGE_IN,
        TRADING,
        AWAITING_TRADES,
        BRIDGING_OUT,
        AWAITING_BRIDGE_OUT,
        FINALIZING
    }

    enum BatchStatus {
        OPEN,
        PROCESSING,
        SETTLED
    }

    enum SettlementPhase {
        NONE,
        SELLING_TOKEN,
        AWAITING_SELL,
        BUYING_HYPE,
        AWAITING_BUY,
        BRIDGING_OUT,
        AWAITING_BRIDGE,
        SETTLING
    }

    enum EmergencyPhase {
        NONE,
        LIQUIDATING,
        AWAITING_LIQUIDATION,
        BUYING_HYPE,
        AWAITING_BUY_HYPE,
        BRIDGING_OUT,
        AWAITING_BRIDGE,
        READY
    }

    // ═══ Structs ═══

    struct WithdrawBatch {
        uint256 totalEscrowedShares;
        uint256 claimedShares;
        uint256 totalHypeRecovered;
        uint256 remainingHypeForClaims;
        uint64 closedAtL1Block;
        uint64 settledAtL1Block;
        BatchStatus status;
    }

    struct RedeemRequest {
        address user;
        uint256 shares;
        uint256 batchId;
        bool claimed;
    }

    struct RebalanceCycle {
        uint256 cycleId;
        RebalancePhase phase;
        uint64 startedAtL1Block;
        uint64 lastActionL1Block;
        uint64 deadline;
        int256 expectedHypeDeltaWei;
        int256 expectedTokenDeltaWei;
        int256 expectedUsdcDeltaWei;
    }

    struct SpotOrder {
        uint32 asset;
        bool isBuy;
        uint64 limitPx;
        uint64 sz;
    }

    struct SettlementCycle {
        uint256 batchId;
        SettlementPhase phase;
        uint64 lastActionL1Block;
        uint64 deadline;
        uint256 hypeEvmBefore;
    }

    // ═══ Events ═══

    event Deposited(address indexed user, uint256 hypeAmount, uint256 shares);
    event RedeemRequested(uint256 indexed redeemId, address indexed user, uint256 shares, uint256 batchId);
    event BatchClosed(uint256 indexed batchId);
    event BatchSettled(uint256 indexed batchId, uint256 totalHypeRecovered, uint256 totalShares);
    event Claimed(uint256 indexed redeemId, address indexed user, uint256 hypeAmount);
    event RebalanceCycleStarted(uint256 indexed cycleId);
    event RebalanceCycleCompleted(uint256 indexed cycleId);
    event RebalanceCycleAborted(uint256 indexed cycleId);
    event EmergencyEntered(uint256 timestamp);
    event EscrowReclaimed(uint256 indexed redeemId, address indexed user, uint256 shares);
    event RecoveryClaimed(address indexed user, uint256 hypeAmount);
    event AutoRebalanceSkipped(uint8 reason);
    event AutoRebalanceStarted(uint256 indexed cycleId, uint256 orderCount);
    event SettlementAdvanced(uint256 indexed batchId, SettlementPhase phase);
    event EmergencyAdvanced(EmergencyPhase phase);

    // ═══ External functions ═══

    function initialize(
        address _factory,
        address _counterpartToken,
        uint32 _counterpartTokenIndex,
        uint32 _counterpartSpotMarketIndex,
        uint32 _hypeTokenIndex,
        uint32 _hypeSpotMarketIndex,
        uint32 _usdcTokenIndex,
        uint8 _counterpartSzDecimals,
        uint8 _counterpartWeiDecimals,
        uint8 _counterpartEvmDecimals,
        uint256 _maxSingleDepositHype18,
        string calldata _name,
        string calldata _symbol
    ) external;

    function keeperPing() external;
    function advanceRebalance() external;
    function advanceBatchSettlement() external;
    function advanceEmergency() external;
    function abortCycle() external;
    function abortSettlement() external;
    function enterEmergency() external;
    function reclaimEscrowedShares(uint256 redeemId) external;
    function setTargetAllocations(uint16 hypeBps, uint16 tokenBps, uint16 usdcBps) external;
    function setDriftThreshold(uint16 bps) external;
    function setMinRebalanceNotional(uint256 usdc8) external;
    function setCycleDeadlineBlocks(uint64 blocks) external;
    function deposit() external payable returns (uint256 shares);
    function requestRedeem(uint256 shares) external returns (uint256 redeemId);
    function claimBatch(uint256 redeemId) external;
    function claimRecovery() external;
    function grossAssets() external view returns (uint256);
    function sharePriceUsdc8() external view returns (uint256);
    function previewDeposit(uint256 hypeEvmWei) external view returns (uint256);
}
