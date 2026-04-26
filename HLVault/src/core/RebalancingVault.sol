// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {Pausable} from "@openzeppelin/contracts/utils/Pausable.sol";
import {Initializable} from "@openzeppelin/contracts/proxy/utils/Initializable.sol";

import {DecimalLib} from "../libraries/DecimalLib.sol";
import {PrecompileLib} from "../libraries/PrecompileLib.sol";
import {CoreActionLib} from "../libraries/CoreActionLib.sol";
import {BridgeLib} from "../libraries/BridgeLib.sol";
import {PriceLib} from "../libraries/PriceLib.sol";
import {SizeLib} from "../libraries/SizeLib.sol";
import {RebalanceLib} from "../libraries/RebalanceLib.sol";
import {SettlementLib} from "../libraries/SettlementLib.sol";
import {ICoreWriter, CORE_WRITER} from "../interfaces/ICoreWriter.sol";
import {IRebalancingVault} from "../interfaces/IRebalancingVault.sol";

interface IVaultFactory {
    function owner() external view returns (address);
    function keeper() external view returns (address);
    function globalPaused() external view returns (bool);
}

contract RebalancingVault is ERC20, ReentrancyGuard, Pausable, Initializable {
    using SafeERC20 for IERC20;
    using DecimalLib for uint256;
    using DecimalLib for uint64;

    // ═══ Constants ═══
    uint256 public constant SCALING_FACTOR = 1e18;
    uint256 public constant VIRTUAL_SHARES = 1e18;
    uint256 public constant VIRTUAL_ASSETS = 1e8;
    uint256 public constant SLIPPAGE_CAP_BPS = 1500; // 15% for testnet (wide spreads), 500 for mainnet
    uint8 public constant HYPE_EVM_DECIMALS = 18;
    uint8 public constant HYPE_WEI_DECIMALS = 8;
    uint8 public constant HYPE_SZ_DECIMALS = 2;
    uint8 public constant USDC_WEI_DECIMALS = 8;

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

    enum BatchStatus { OPEN, PROCESSING, SETTLED }

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
        uint256 hypeEvmBefore; // snapshot for computing recovered HYPE
    }

    // ═══ Immutables (set via initialize on clone) ═══
    IVaultFactory public factory;

    // ═══ Storage: Token config ═══
    string private _vaultName;
    string private _vaultSymbol;
    address public counterpartToken;
    uint32 public counterpartTokenIndex;
    uint32 public counterpartSpotMarketIndex;
    uint32 public hypeTokenIndex;
    uint32 public hypeSpotMarketIndex;
    uint32 public usdcTokenIndex;
    uint8 public counterpartSzDecimals;
    uint8 public counterpartWeiDecimals;
    uint8 public counterpartEvmDecimals;

    // ═══ Storage: Vault config ═══
    uint256 public maxSingleDepositHype18;
    uint256 public slippageBps;
    bool public depositsEnabled;

    // ═══ Storage: Accounting ═══
    uint256 public escrowedShares;
    uint256 public reservedHypeForClaims;

    // ═══ Storage: Batch withdrawals ═══
    uint256 public currentBatchId;
    mapping(uint256 => WithdrawBatch) public batches;
    mapping(uint256 => RedeemRequest) public redeemRequests;
    uint256 public nextRedeemId;
    mapping(address => uint256[]) internal _userRedeemIds;
    uint256 public processingBatchCount;

    // ═══ Storage: Rebalance ═══
    RebalanceCycle public currentCycle;
    uint256 public nextCycleId;

    // ═══ Storage: Emergency ═══
    bool public emergencyMode;
    bool public recoveryComplete;

    // ═══ Storage: Heartbeat ═══
    uint256 public lastHeartbeat;
    uint256 public heartbeatTimeout;

    // ═══ Storage: Auto-rebalance config ═══
    uint16 public targetHypeBps;
    uint16 public targetTokenBps;
    uint16 public targetUsdcBps;
    uint16 public driftThresholdBps;
    uint256 public minRebalanceNotionalUsdc8;
    uint64 public cycleDeadlineBlocks;

    // ═══ Storage: Settlement ═══
    SettlementCycle public currentSettlement;

    // ═══ Storage: Emergency advance ═══
    uint8 public emergencyPhaseRaw;
    uint64 public emergencyLastL1Block;

    // ═══ Events ═══
    event Deposited(address indexed user, uint256 hypeAmount, uint256 shares);
    event RedeemRequested(uint256 indexed redeemId, address indexed user, uint256 shares, uint256 batchId);
    event BatchClosed(uint256 indexed batchId);
    event BatchSettled(uint256 indexed batchId, uint256 totalHypeRecovered, uint256 totalShares);
    event Claimed(uint256 indexed redeemId, address indexed user, uint256 hypeAmount);
    event RebalanceCycleStarted(uint256 indexed cycleId);
    event RebalanceCycleCompleted(uint256 indexed cycleId);
    event RebalanceCycleAborted(uint256 indexed cycleId);
    event BridgeOutSkipped(uint256 indexed cycleId);
    event EmergencyEntered(uint256 timestamp);
    event BatchDustSwept(uint256 indexed batchId, uint256 dustAmount);
    event EscrowReclaimed(uint256 indexed redeemId, address indexed user, uint256 shares);
    event RecoveryClaimed(address indexed user, uint256 hypeAmount);
    event AutoRebalanceSkipped(uint8 reason); // 0=below threshold, 1=no valid orders
    event AutoRebalanceStarted(uint256 indexed cycleId, uint256 orderCount);
    event SettlementAdvanced(uint256 indexed batchId, SettlementPhase phase);
    event EmergencyAdvanced(EmergencyPhase phase);

    // ═══ Custom Errors ═══
    error NotKeeper();
    error NotOwner();
    error VaultPaused();
    error InEmergency();
    error NotInEmergency();
    error CycleInProgress();
    error SettlementInProgress();
    error BatchProcessing();
    error WrongPhase();
    error L1NotAdvanced();
    error UnauthorizedPair();
    error InvalidPhase();
    error MustSumTo100();
    error InvalidThreshold();
    error ZeroDeadline();
    error EmptyBatch();
    error NotProcessing();
    error InsufficientFreeHype();
    error NotReqOwner();
    error AlreadyClaimed();
    error NotSettled();
    error TransferFailed();
    error ConditionsNotMet();
    error NotReady();
    error NoShares();
    error ZeroDeposit();
    error ExceedsMax();
    error DepositsDisabled();
    error Insufficient();
    error EscrowNotReclaimed();
    error AlreadyProcessed();
    error UseClaimBatch();

    // ═══ Modifiers ═══
    modifier onlyKeeper() {
        if (msg.sender != factory.keeper()) revert NotKeeper();
        _;
    }

    modifier onlyOwner() {
        if (msg.sender != factory.owner()) revert NotOwner();
        _;
    }

    modifier onlyKeeperOrOwner() {
        if (msg.sender != factory.keeper() && msg.sender != factory.owner()) revert NotKeeper();
        _;
    }

    modifier whenNotGlobalPaused() {
        if (paused() || factory.globalPaused()) revert VaultPaused();
        _;
    }

    // ═══ Constructor (implementation — disables initializers) ═══
    constructor() ERC20("", "") {
        _disableInitializers();
    }

    // ═══ ERC20 overrides for clone pattern ═══
    function name() public view override returns (string memory) {
        return _vaultName;
    }

    function symbol() public view override returns (string memory) {
        return _vaultSymbol;
    }

    // ═══ Initializer ═══
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
    ) external initializer {
        factory = IVaultFactory(_factory);
        counterpartToken = _counterpartToken;
        counterpartTokenIndex = _counterpartTokenIndex;
        counterpartSpotMarketIndex = _counterpartSpotMarketIndex;
        hypeTokenIndex = _hypeTokenIndex;
        hypeSpotMarketIndex = _hypeSpotMarketIndex;
        usdcTokenIndex = _usdcTokenIndex;
        counterpartSzDecimals = _counterpartSzDecimals;
        counterpartWeiDecimals = _counterpartWeiDecimals;
        counterpartEvmDecimals = _counterpartEvmDecimals;
        maxSingleDepositHype18 = _maxSingleDepositHype18;
        _vaultName = _name;
        _vaultSymbol = _symbol;
        lastHeartbeat = block.timestamp;
        depositsEnabled = true;
        slippageBps = 200;
        heartbeatTimeout = 24 hours;
        targetHypeBps = 4800;
        targetTokenBps = 4800;
        targetUsdcBps = 400;
        driftThresholdBps = 300;
        minRebalanceNotionalUsdc8 = 5e8;
        cycleDeadlineBlocks = 500;
    }

    // ═══ Receive ═══
    receive() external payable {}

    // ═══════════════════════════════════════════════════════════
    //                     ACCOUNTING
    // ═══════════════════════════════════════════════════════════

    /// @notice Convert a Core balance + price to USDC 8-decimal value
    function _toUsdc8(uint64 balance, uint8 weiDec, uint64 rawPx, uint8 szDec)
        internal
        pure
        returns (uint256)
    {
        return uint256(balance) * uint256(rawPx) * (10 ** szDec) / (10 ** weiDec);
    }

    function grossAssets() public view returns (uint256) {
        return _grossAssetsWithHypeEvm(address(this).balance - reservedHypeForClaims);
    }

    function _grossAssetsWithHypeEvm(uint256 hypeEvmBalance) internal view returns (uint256 totalUsdc8) {
        uint64 hypePx = _getSpotPrice(hypeSpotMarketIndex);
        uint64 tokenPx = _getSpotPrice(counterpartSpotMarketIndex);

        (uint64 hypeCoreTotal,) = _getSpotBalance(address(this), hypeTokenIndex);
        totalUsdc8 += _toUsdc8(hypeCoreTotal, HYPE_WEI_DECIMALS, hypePx, HYPE_SZ_DECIMALS);

        uint64 hypeEvmCore = DecimalLib.evmToCore(hypeEvmBalance, HYPE_EVM_DECIMALS, HYPE_WEI_DECIMALS);
        totalUsdc8 += _toUsdc8(hypeEvmCore, HYPE_WEI_DECIMALS, hypePx, HYPE_SZ_DECIMALS);

        (uint64 tokenCoreTotal,) = _getSpotBalance(address(this), counterpartTokenIndex);
        totalUsdc8 += _toUsdc8(tokenCoreTotal, counterpartWeiDecimals, tokenPx, counterpartSzDecimals);

        uint256 tokenEvmBal = IERC20(counterpartToken).balanceOf(address(this));
        if (tokenEvmBal > 0) {
            uint64 tokenEvmCore =
                DecimalLib.evmToCore(tokenEvmBal, counterpartEvmDecimals, counterpartWeiDecimals);
            totalUsdc8 += _toUsdc8(tokenEvmCore, counterpartWeiDecimals, tokenPx, counterpartSzDecimals);
        }

        (uint64 usdcCoreTotal,) = _getSpotBalance(address(this), usdcTokenIndex);
        totalUsdc8 += uint256(usdcCoreTotal);
    }

    function sharePriceUsdc8() public view returns (uint256) {
        return (grossAssets() + VIRTUAL_ASSETS) * SCALING_FACTOR / (totalSupply() + VIRTUAL_SHARES);
    }

    function previewDeposit(uint256 hypeEvmWei) public view returns (uint256 shares) {
        uint64 hypePx = _getSpotPrice(hypeSpotMarketIndex);
        uint64 hypeCore = DecimalLib.evmToCore(hypeEvmWei, HYPE_EVM_DECIMALS, HYPE_WEI_DECIMALS);
        uint256 depositUsdc8 = _toUsdc8(hypeCore, HYPE_WEI_DECIMALS, hypePx, HYPE_SZ_DECIMALS);
        shares = _previewDepositFromUsdc8(depositUsdc8, grossAssets());
    }

    function _previewDepositFromUsdc8(uint256 depositUsdc8, uint256 grossAssetsBefore)
        internal
        view
        returns (uint256 shares)
    {
        uint256 sharePrice = (grossAssetsBefore + VIRTUAL_ASSETS) * SCALING_FACTOR
            / (totalSupply() + VIRTUAL_SHARES);
        shares = depositUsdc8 * SCALING_FACTOR / sharePrice;
    }

    function circulatingShares() public view returns (uint256) {
        return totalSupply() - escrowedShares;
    }

    // ═══════════════════════════════════════════════════════════
    //                        DEPOSIT
    // ═══════════════════════════════════════════════════════════

    function deposit() external payable nonReentrant whenNotGlobalPaused returns (uint256 shares) {
        if (currentCycle.phase != RebalancePhase.IDLE) revert CycleInProgress();
        if (currentSettlement.phase != SettlementPhase.NONE) revert SettlementInProgress();
        if (_hasBatchProcessing()) revert BatchProcessing();
        if (emergencyMode) revert InEmergency();
        if (!depositsEnabled) revert DepositsDisabled();
        if (msg.value == 0) revert ZeroDeposit();
        if (msg.value > maxSingleDepositHype18) revert ExceedsMax();

        uint64 hypePx = _getSpotPrice(hypeSpotMarketIndex);
        uint64 hypeCore = DecimalLib.evmToCore(msg.value, HYPE_EVM_DECIMALS, HYPE_WEI_DECIMALS);
        uint256 depositUsdc8 = _toUsdc8(hypeCore, HYPE_WEI_DECIMALS, hypePx, HYPE_SZ_DECIMALS);

        uint256 hypeEvmBeforeDeposit = address(this).balance - msg.value;
        uint256 grossAssetsBeforeDeposit = _grossAssetsWithHypeEvm(hypeEvmBeforeDeposit);

        shares = _previewDepositFromUsdc8(depositUsdc8, grossAssetsBeforeDeposit);
        if (shares == 0) revert ZeroDeposit();

        _mint(msg.sender, shares);
        emit Deposited(msg.sender, msg.value, shares);
    }

    // ═══════════════════════════════════════════════════════════
    //                   BATCH WITHDRAWALS
    // ═══════════════════════════════════════════════════════════

    function requestRedeem(uint256 shares) external nonReentrant whenNotGlobalPaused returns (uint256 redeemId) {
        if (shares == 0) revert NoShares();
        if (balanceOf(msg.sender) < shares) revert Insufficient();

        _transfer(msg.sender, address(this), shares);
        escrowedShares += shares;

        redeemId = nextRedeemId++;
        redeemRequests[redeemId] = RedeemRequest({
            user: msg.sender,
            shares: shares,
            batchId: currentBatchId,
            claimed: false
        });
        batches[currentBatchId].totalEscrowedShares += shares;
        _userRedeemIds[msg.sender].push(redeemId);

        emit RedeemRequested(redeemId, msg.sender, shares, currentBatchId);
    }

    function _closeBatchInternal() internal returns (uint256 batchId) {
        batchId = currentBatchId;
        WithdrawBatch storage batch = batches[batchId];
        if (batch.totalEscrowedShares == 0) revert EmptyBatch();

        batch.status = BatchStatus.PROCESSING;
        batch.closedAtL1Block = uint64(_getL1BlockNumber());
        processingBatchCount++;

        currentBatchId++;
        emit BatchClosed(batchId);
    }

    function _settleBatchInternal(uint256 batchId, uint256 totalHypeRecovered) internal {
        WithdrawBatch storage batch = batches[batchId];
        if (batch.status != BatchStatus.PROCESSING) revert NotProcessing();
        if (address(this).balance < reservedHypeForClaims + totalHypeRecovered) revert InsufficientFreeHype();

        batch.totalHypeRecovered = totalHypeRecovered;
        batch.remainingHypeForClaims = totalHypeRecovered;
        batch.settledAtL1Block = uint64(_getL1BlockNumber());
        batch.status = BatchStatus.SETTLED;

        reservedHypeForClaims += totalHypeRecovered;

        _burn(address(this), batch.totalEscrowedShares);
        escrowedShares -= batch.totalEscrowedShares;
        processingBatchCount--;

        emit BatchSettled(batchId, totalHypeRecovered, batch.totalEscrowedShares);
    }

    function claimBatch(uint256 redeemId) external nonReentrant {
        RedeemRequest storage req = redeemRequests[redeemId];
        if (req.user != msg.sender) revert NotReqOwner();
        if (req.claimed) revert AlreadyClaimed();

        WithdrawBatch storage batch = batches[req.batchId];
        if (batch.status != BatchStatus.SETTLED) revert NotSettled();

        req.claimed = true;

        uint256 hypeAmount = req.shares * batch.totalHypeRecovered / batch.totalEscrowedShares;

        batch.claimedShares += req.shares;
        batch.remainingHypeForClaims -= hypeAmount;
        reservedHypeForClaims -= hypeAmount;

        (bool ok,) = payable(msg.sender).call{value: hypeAmount}("");
        if (!ok) revert TransferFailed();

        emit Claimed(redeemId, msg.sender, hypeAmount);
    }

    function _sweepBatchDustInternal(uint256 batchId) internal {
        WithdrawBatch storage batch = batches[batchId];
        if (batch.status != BatchStatus.SETTLED) return;
        if (batch.remainingHypeForClaims == 0) return;
        if (batch.claimedShares < batch.totalEscrowedShares) return;

        uint256 dust = batch.remainingHypeForClaims;
        reservedHypeForClaims -= dust;
        batch.remainingHypeForClaims = 0;
        emit BatchDustSwept(batchId, dust);
    }

    function getUserRedeemIds(address user) external view returns (uint256[] memory) {
        return _userRedeemIds[user];
    }

    function _hasBatchProcessing() internal view returns (bool) {
        return processingBatchCount > 0;
    }

    // ═══════════════════════════════════════════════════════════
    //                     ADVANCE REBALANCE
    // ═══════════════════════════════════════════════════════════

    /// @notice Single-entry rebalance driver. Keeper calls this repeatedly.
    function advanceRebalance() external onlyKeeper whenNotGlobalPaused {
        if (emergencyMode) revert InEmergency();
        if (currentSettlement.phase != SettlementPhase.NONE) revert SettlementInProgress();

        RebalancePhase phase = currentCycle.phase;

        if (phase == RebalancePhase.IDLE) {
            _advanceFromIdle();
        } else if (phase == RebalancePhase.AWAITING_BRIDGE_IN) {
            _advanceFromAwaitingBridgeIn();
        } else if (phase == RebalancePhase.AWAITING_TRADES) {
            _advanceFromAwaitingTrades();
        } else if (phase == RebalancePhase.AWAITING_BRIDGE_OUT) {
            _advanceFromAwaitingBridgeOut();
        } else if (phase == RebalancePhase.FINALIZING) {
            _doFinalize();
        } else {
            revert InvalidPhase();
        }
    }

    function _advanceFromIdle() internal {
        if (_hasBatchProcessing()) revert BatchProcessing();

        RebalanceLib.PortfolioState memory s = _buildPortfolioState();

        if (!RebalanceLib.needsRebalance(s, targetHypeBps, targetTokenBps, targetUsdcBps, driftThresholdBps)) {
            emit AutoRebalanceSkipped(0);
            return;
        }

        (RebalanceLib.SpotOrder[] memory orders, uint256 count) = _computeOrders(s);

        if (count == 0) {
            emit AutoRebalanceSkipped(1);
            return;
        }

        uint256 bridgeInAmount = RebalanceLib.computeBridgeInAmount(
            s, orders, count, 10000 + hypeSpotMarketIndex, HYPE_WEI_DECIMALS
        );

        // Start cycle
        uint256 cycleId = nextCycleId++;
        uint64 currentL1 = uint64(_getL1BlockNumber());
        currentCycle = RebalanceCycle({
            cycleId: cycleId,
            phase: RebalancePhase.BRIDGING_IN,
            startedAtL1Block: currentL1,
            lastActionL1Block: currentL1,
            deadline: currentL1 + cycleDeadlineBlocks,
            expectedHypeDeltaWei: 0,
            expectedTokenDeltaWei: 0,
            expectedUsdcDeltaWei: 0
        });

        emit AutoRebalanceStarted(cycleId, count);

        if (bridgeInAmount > 0) {
            BridgeLib.bridgeHypeEvmToCore(bridgeInAmount);
            currentCycle.phase = RebalancePhase.AWAITING_BRIDGE_IN;
        } else {
            _sendComputedOrders(orders, count);
            currentCycle.phase = RebalancePhase.AWAITING_TRADES;
        }

        currentCycle.lastActionL1Block = uint64(_getL1BlockNumber());
        _touchHeartbeat();
        emit RebalanceCycleStarted(cycleId);
    }

    function _advanceFromAwaitingBridgeIn() internal {
        uint64 currentL1 = uint64(_getL1BlockNumber());
        if (currentL1 <= currentCycle.lastActionL1Block) revert L1NotAdvanced();

        RebalanceLib.PortfolioState memory s = _buildPortfolioState();
        (RebalanceLib.SpotOrder[] memory orders, uint256 count) = _computeOrders(s);
        _sendComputedOrders(orders, count);

        currentCycle.phase = RebalancePhase.AWAITING_TRADES;
        currentCycle.lastActionL1Block = currentL1;
        _touchHeartbeat();
    }

    function _advanceFromAwaitingTrades() internal {
        uint64 currentL1 = uint64(_getL1BlockNumber());
        if (currentL1 <= currentCycle.lastActionL1Block) revert L1NotAdvanced();

        (uint64 hypeCoreTotal,) = _getSpotBalance(address(this), hypeTokenIndex);

        if (hypeCoreTotal > 0) {
            BridgeLib.bridgeHypeCoreToEvm(uint64(hypeTokenIndex), hypeCoreTotal);
            currentCycle.phase = RebalancePhase.AWAITING_BRIDGE_OUT;
            currentCycle.lastActionL1Block = currentL1;
        } else {
            currentCycle.phase = RebalancePhase.IDLE;
            emit RebalanceCycleCompleted(currentCycle.cycleId);
        }

        _touchHeartbeat();
    }

    function _advanceFromAwaitingBridgeOut() internal {
        uint64 currentL1 = uint64(_getL1BlockNumber());
        if (currentL1 <= currentCycle.lastActionL1Block) revert L1NotAdvanced();

        currentCycle.phase = RebalancePhase.IDLE;
        _touchHeartbeat();
        emit RebalanceCycleCompleted(currentCycle.cycleId);
    }

    function _doFinalize() internal {
        currentCycle.phase = RebalancePhase.IDLE;
        _touchHeartbeat();
        emit RebalanceCycleCompleted(currentCycle.cycleId);
    }

    function abortCycle() external {
        if (currentCycle.phase == RebalancePhase.IDLE) revert InvalidPhase();
        bool isAuthorized = msg.sender == factory.keeper() || msg.sender == factory.owner();
        bool isExpired = uint64(_getL1BlockNumber()) > currentCycle.deadline;
        if (!isAuthorized && !isExpired) revert NotKeeper();

        currentCycle.phase = RebalancePhase.IDLE;
        if (isAuthorized) _touchHeartbeat();
        emit RebalanceCycleAborted(currentCycle.cycleId);
    }

    function _computeOrders(RebalanceLib.PortfolioState memory s)
        internal
        view
        returns (RebalanceLib.SpotOrder[] memory orders, uint256 count)
    {
        return RebalanceLib.computeOrders(
            s,
            targetHypeBps,
            targetTokenBps,
            10000 + hypeSpotMarketIndex,
            10000 + counterpartSpotMarketIndex,
            HYPE_SZ_DECIMALS,
            counterpartSzDecimals,
            slippageBps,
            minRebalanceNotionalUsdc8
        );
    }

    function _sendComputedOrders(RebalanceLib.SpotOrder[] memory orders, uint256 count) internal {
        for (uint256 i = 0; i < count; i++) {
            _processAndSendOrder(orders[i].asset, orders[i].isBuy, orders[i].limitPx, orders[i].sz);
        }
    }

    function _buildPortfolioState() internal view returns (RebalanceLib.PortfolioState memory s) {
        s.hypePx = _getSpotPrice(hypeSpotMarketIndex);
        s.tokenPx = _getSpotPrice(counterpartSpotMarketIndex);

        (s.hypeCoreBalance,) = _getSpotBalance(address(this), hypeTokenIndex);
        (s.tokenCoreBalance,) = _getSpotBalance(address(this), counterpartTokenIndex);
        (s.usdcCoreBalance,) = _getSpotBalance(address(this), usdcTokenIndex);

        s.hypeEvmAvailable =
            address(this).balance > reservedHypeForClaims ? address(this).balance - reservedHypeForClaims : 0;

        s.hypeUsdc8 = _toUsdc8(s.hypeCoreBalance, HYPE_WEI_DECIMALS, s.hypePx, HYPE_SZ_DECIMALS);
        if (s.hypeEvmAvailable > 0) {
            uint64 hypeEvmCore = DecimalLib.evmToCore(s.hypeEvmAvailable, HYPE_EVM_DECIMALS, HYPE_WEI_DECIMALS);
            s.hypeUsdc8 += _toUsdc8(hypeEvmCore, HYPE_WEI_DECIMALS, s.hypePx, HYPE_SZ_DECIMALS);
        }

        s.tokenUsdc8 = _toUsdc8(s.tokenCoreBalance, counterpartWeiDecimals, s.tokenPx, counterpartSzDecimals);
        uint256 tokenEvmBal = IERC20(counterpartToken).balanceOf(address(this));
        if (tokenEvmBal > 0) {
            uint64 tokenEvmCore =
                DecimalLib.evmToCore(tokenEvmBal, counterpartEvmDecimals, counterpartWeiDecimals);
            s.tokenUsdc8 += _toUsdc8(tokenEvmCore, counterpartWeiDecimals, s.tokenPx, counterpartSzDecimals);
        }

        s.usdcUsdc8 = uint256(s.usdcCoreBalance);
        s.totalUsdc8 = s.hypeUsdc8 + s.tokenUsdc8 + s.usdcUsdc8;
    }

    // ═══════════════════════════════════════════════════════════
    //                  ADVANCE BATCH SETTLEMENT
    // ═══════════════════════════════════════════════════════════

    /// @notice Single-entry settlement driver. Keeper calls this repeatedly.
    /// Phase transitions: NONE → AWAITING_SELL → AWAITING_BUY → AWAITING_BRIDGE → NONE
    function advanceBatchSettlement() external onlyKeeper whenNotGlobalPaused {
        if (emergencyMode) revert InEmergency();
        if (currentCycle.phase != RebalancePhase.IDLE) revert CycleInProgress();

        SettlementPhase phase = currentSettlement.phase;

        if (phase == SettlementPhase.NONE) {
            _settlementFromNone();
        } else if (phase == SettlementPhase.AWAITING_SELL) {
            _settlementFromAwaitingSell();
        } else if (phase == SettlementPhase.AWAITING_BUY) {
            _settlementFromAwaitingBuy();
        } else if (phase == SettlementPhase.AWAITING_BRIDGE) {
            _settlementFromAwaitingBridge();
        } else {
            revert InvalidPhase();
        }
    }

    /// @notice Call 1: Find OPEN batch, close it, sell TOKEN on Core
    function _settlementFromNone() internal {
        // Check if current batch has shares to close
        WithdrawBatch storage batch = batches[currentBatchId];
        if (batch.totalEscrowedShares == 0) {
            return; // No-op if no pending redeems
        }

        // Close the batch
        uint256 batchId = _closeBatchInternal();
        uint64 currentL1 = uint64(_getL1BlockNumber());

        currentSettlement = SettlementCycle({
            batchId: batchId,
            phase: SettlementPhase.NONE, // will be set below
            lastActionL1Block: currentL1,
            deadline: currentL1 + cycleDeadlineBlocks,
            hypeEvmBefore: 0
        });

        // Read TOKEN balance on Core
        (uint64 tokenCoreBalance,) = _getSpotBalance(address(this), counterpartTokenIndex);

        if (tokenCoreBalance > 0) {
            // Sell TOKEN → USDC
            uint64 tokenPx = _getSpotPrice(counterpartSpotMarketIndex);
            (bool valid, SettlementLib.SpotOrder memory order) = SettlementLib.computeSellTokenOrder(
                tokenCoreBalance, tokenPx,
                10000 + counterpartSpotMarketIndex,
                counterpartSzDecimals, counterpartWeiDecimals,
                slippageBps
            );
            if (valid) {
                _processAndSendOrder(order.asset, order.isBuy, order.limitPx, order.sz);
                currentSettlement.phase = SettlementPhase.AWAITING_SELL;
                currentSettlement.lastActionL1Block = uint64(_getL1BlockNumber());
            } else {
                // No valid sell order (dust amount) — skip to buying HYPE
                _tryBuyHypeForSettlement();
            }
        } else {
            // No TOKEN on Core — skip to buying HYPE
            _tryBuyHypeForSettlement();
        }

        _touchHeartbeat();
        emit SettlementAdvanced(batchId, currentSettlement.phase);
    }

    /// @notice Call 2: Wait L1, read USDC balance, buy HYPE
    function _settlementFromAwaitingSell() internal {
        uint64 currentL1 = uint64(_getL1BlockNumber());
        if (currentL1 <= currentSettlement.lastActionL1Block) revert L1NotAdvanced();

        _tryBuyHypeForSettlement();
        _touchHeartbeat();
        emit SettlementAdvanced(currentSettlement.batchId, currentSettlement.phase);
    }

    /// @dev Shared logic: try to buy HYPE with USDC, or bridge existing HYPE
    function _tryBuyHypeForSettlement() internal {
        (uint64 usdcCoreBalance,) = _getSpotBalance(address(this), usdcTokenIndex);

        if (usdcCoreBalance > 0) {
            uint64 hypePx = _getSpotPrice(hypeSpotMarketIndex);
            (bool valid, SettlementLib.SpotOrder memory order) = SettlementLib.computeBuyHypeOrder(
                usdcCoreBalance, hypePx,
                10000 + hypeSpotMarketIndex,
                HYPE_SZ_DECIMALS, slippageBps
            );
            if (valid) {
                _processAndSendOrder(order.asset, order.isBuy, order.limitPx, order.sz);
                currentSettlement.phase = SettlementPhase.AWAITING_BUY;
                currentSettlement.lastActionL1Block = uint64(_getL1BlockNumber());
                return;
            }
        }

        // No USDC or order too small — try bridging existing HYPE
        _tryBridgeHypeForSettlement();
    }

    /// @notice Call 3: Wait L1, read HYPE Core balance, bridge Core→EVM
    function _settlementFromAwaitingBuy() internal {
        uint64 currentL1 = uint64(_getL1BlockNumber());
        if (currentL1 <= currentSettlement.lastActionL1Block) revert L1NotAdvanced();

        _tryBridgeHypeForSettlement();
        _touchHeartbeat();
        emit SettlementAdvanced(currentSettlement.batchId, currentSettlement.phase);
    }

    /// @dev Bridge HYPE from Core→EVM, or settle with what's on EVM
    function _tryBridgeHypeForSettlement() internal {
        (uint64 hypeCoreBalance,) = _getSpotBalance(address(this), hypeTokenIndex);

        // Snapshot EVM HYPE before bridge
        currentSettlement.hypeEvmBefore = address(this).balance;

        if (hypeCoreBalance > 0) {
            BridgeLib.bridgeHypeCoreToEvm(uint64(hypeTokenIndex), hypeCoreBalance);
            currentSettlement.phase = SettlementPhase.AWAITING_BRIDGE;
            currentSettlement.lastActionL1Block = uint64(_getL1BlockNumber());
        } else {
            // No HYPE on Core — settle with whatever EVM HYPE is available
            _finalizeSettlement();
        }
    }

    /// @notice Call 4: Wait L1, compute recovered HYPE, settle batch
    function _settlementFromAwaitingBridge() internal {
        uint64 currentL1 = uint64(_getL1BlockNumber());
        if (currentL1 <= currentSettlement.lastActionL1Block) revert L1NotAdvanced();

        _finalizeSettlement();
        _touchHeartbeat();
        emit SettlementAdvanced(currentSettlement.batchId, currentSettlement.phase);
    }

    function _finalizeSettlement() internal {
        uint256 batchId = currentSettlement.batchId;

        // Compute how much free HYPE is available for settlement
        uint256 freeHype = address(this).balance > reservedHypeForClaims
            ? address(this).balance - reservedHypeForClaims
            : 0;

        // Pro-rata: batch only gets its share of free HYPE based on escrowed shares
        uint256 supply = totalSupply();
        uint256 batchHype = supply > 0
            ? freeHype * batches[batchId].totalEscrowedShares / supply
            : 0;

        // Settle the batch with its pro-rata share
        _settleBatchInternal(batchId, batchHype);

        // Auto-sweep dust from old settled batches (last 20)
        uint256 startBatch = batchId > 20 ? batchId - 20 : 0;
        for (uint256 i = startBatch; i < batchId; i++) {
            _sweepBatchDustInternal(i);
        }

        // Reset settlement state
        currentSettlement.phase = SettlementPhase.NONE;
    }

    /// @notice Abort a settlement cycle (safety valve)
    function abortSettlement() external {
        if (currentSettlement.phase == SettlementPhase.NONE) revert InvalidPhase();
        bool isAuthorized = msg.sender == factory.keeper() || msg.sender == factory.owner();
        bool isExpired = uint64(_getL1BlockNumber()) > currentSettlement.deadline;
        if (!isAuthorized && !isExpired) revert NotKeeper();

        currentSettlement.phase = SettlementPhase.NONE;
        if (isAuthorized) _touchHeartbeat();
    }

    // ═══════════════════════════════════════════════════════════
    //                     EMERGENCY MODE
    // ═══════════════════════════════════════════════════════════

    function isEmergency() public view returns (bool) {
        if (emergencyMode) return true;
        if (block.timestamp > lastHeartbeat + heartbeatTimeout) return true;
        return false;
    }

    function enterEmergency() external {
        if (!isEmergency()) revert ConditionsNotMet();
        emergencyMode = true;
        _pause();
        if (currentCycle.phase != RebalancePhase.IDLE) {
            currentCycle.phase = RebalancePhase.IDLE;
        }
        // Reset settlement if in progress
        if (currentSettlement.phase != SettlementPhase.NONE) {
            currentSettlement.phase = SettlementPhase.NONE;
        }
        emit EmergencyEntered(block.timestamp);
    }

    function reclaimEscrowedShares(uint256 redeemId) external nonReentrant {
        if (!emergencyMode) revert NotInEmergency();
        RedeemRequest storage req = redeemRequests[redeemId];
        if (req.user != msg.sender) revert NotReqOwner();
        if (req.claimed) revert AlreadyProcessed();

        WithdrawBatch storage batch = batches[req.batchId];
        if (batch.status == BatchStatus.SETTLED) revert UseClaimBatch();

        req.claimed = true;
        escrowedShares -= req.shares;
        batch.totalEscrowedShares -= req.shares;
        _transfer(address(this), msg.sender, req.shares);

        emit EscrowReclaimed(redeemId, msg.sender, req.shares);
    }

    /// @notice Single-entry emergency recovery driver. Keeper/owner calls this repeatedly.
    /// Phase transitions: NONE → AWAITING_LIQUIDATION → AWAITING_BUY_HYPE → AWAITING_BRIDGE → NONE
    function advanceEmergency() external onlyKeeperOrOwner {
        if (!emergencyMode) revert NotInEmergency();
        if (recoveryComplete) return; // Already done

        EmergencyPhase phase = EmergencyPhase(emergencyPhaseRaw);

        if (phase == EmergencyPhase.NONE) {
            _emergencyFromNone();
        } else if (phase == EmergencyPhase.AWAITING_LIQUIDATION) {
            _emergencyFromAwaitingLiquidation();
        } else if (phase == EmergencyPhase.AWAITING_BUY_HYPE) {
            _emergencyFromAwaitingBuyHype();
        } else if (phase == EmergencyPhase.AWAITING_BRIDGE) {
            _emergencyFromAwaitingBridge();
        } else {
            revert InvalidPhase();
        }
    }

    /// @notice Call 1: Sell all TOKEN on Core → USDC
    function _emergencyFromNone() internal {
        (uint64 tokenCoreBalance,) = _getSpotBalance(address(this), counterpartTokenIndex);

        if (tokenCoreBalance > 0) {
            uint64 tokenPx = _getSpotPrice(counterpartSpotMarketIndex);
            (bool valid, SettlementLib.SpotOrder memory order) = SettlementLib.computeSellTokenOrder(
                tokenCoreBalance, tokenPx,
                10000 + counterpartSpotMarketIndex,
                counterpartSzDecimals, counterpartWeiDecimals,
                slippageBps
            );
            if (valid) {
                _processAndSendOrder(order.asset, order.isBuy, order.limitPx, order.sz);
            }
            emergencyPhaseRaw = uint8(EmergencyPhase.AWAITING_LIQUIDATION);
        } else {
            // No TOKEN — skip to buying HYPE
            _emergencyTryBuyHype();
        }

        emergencyLastL1Block = uint64(_getL1BlockNumber());
        emit EmergencyAdvanced(EmergencyPhase(emergencyPhaseRaw));
    }

    /// @notice Call 2: Wait L1, buy HYPE with all USDC
    function _emergencyFromAwaitingLiquidation() internal {
        uint64 currentL1 = uint64(_getL1BlockNumber());
        if (currentL1 <= emergencyLastL1Block) revert L1NotAdvanced();

        _emergencyTryBuyHype();
        emit EmergencyAdvanced(EmergencyPhase(emergencyPhaseRaw));
    }

    function _emergencyTryBuyHype() internal {
        (uint64 usdcCoreBalance,) = _getSpotBalance(address(this), usdcTokenIndex);

        if (usdcCoreBalance > 0) {
            uint64 hypePx = _getSpotPrice(hypeSpotMarketIndex);
            (bool valid, SettlementLib.SpotOrder memory order) = SettlementLib.computeBuyHypeOrder(
                usdcCoreBalance, hypePx,
                10000 + hypeSpotMarketIndex,
                HYPE_SZ_DECIMALS, slippageBps
            );
            if (valid) {
                _processAndSendOrder(order.asset, order.isBuy, order.limitPx, order.sz);
            }
            emergencyPhaseRaw = uint8(EmergencyPhase.AWAITING_BUY_HYPE);
        } else {
            // No USDC — skip to bridging
            _emergencyTryBridge();
        }

        emergencyLastL1Block = uint64(_getL1BlockNumber());
    }

    /// @notice Call 3: Wait L1, bridge all HYPE Core→EVM
    function _emergencyFromAwaitingBuyHype() internal {
        uint64 currentL1 = uint64(_getL1BlockNumber());
        if (currentL1 <= emergencyLastL1Block) revert L1NotAdvanced();

        _emergencyTryBridge();
        emit EmergencyAdvanced(EmergencyPhase(emergencyPhaseRaw));
    }

    function _emergencyTryBridge() internal {
        (uint64 hypeCoreBalance,) = _getSpotBalance(address(this), hypeTokenIndex);

        if (hypeCoreBalance > 0) {
            BridgeLib.bridgeHypeCoreToEvm(uint64(hypeTokenIndex), hypeCoreBalance);
            emergencyPhaseRaw = uint8(EmergencyPhase.AWAITING_BRIDGE);
        } else {
            // No HYPE on Core — finalize directly
            _emergencyFinalize();
            return;
        }

        emergencyLastL1Block = uint64(_getL1BlockNumber());
    }

    /// @notice Call 4: Wait L1, finalize recovery
    function _emergencyFromAwaitingBridge() internal {
        uint64 currentL1 = uint64(_getL1BlockNumber());
        if (currentL1 <= emergencyLastL1Block) revert L1NotAdvanced();

        _emergencyFinalize();
        emit EmergencyAdvanced(EmergencyPhase(emergencyPhaseRaw));
    }

    function _emergencyFinalize() internal {
        if (escrowedShares != 0) revert EscrowNotReclaimed();
        recoveryComplete = true;
        emergencyPhaseRaw = uint8(EmergencyPhase.NONE);
    }

    function claimRecovery() external nonReentrant {
        if (!emergencyMode || !recoveryComplete) revert NotReady();
        uint256 userShares = balanceOf(msg.sender);
        if (userShares == 0) revert NoShares();

        uint256 distributableHype = address(this).balance - reservedHypeForClaims;
        uint256 hypeOwed = distributableHype * userShares / totalSupply();

        _burn(msg.sender, userShares);
        (bool ok,) = payable(msg.sender).call{value: hypeOwed}("");
        require(ok, "transfer failed");

        emit RecoveryClaimed(msg.sender, hypeOwed);
    }

    // ═══════════════════════════════════════════════════════════
    //                         ADMIN
    // ═══════════════════════════════════════════════════════════

    function keeperPing() external onlyKeeper {
        _touchHeartbeat();
    }

    function setSlippage(uint256 newBps) external onlyOwner {
        if (newBps > SLIPPAGE_CAP_BPS) revert ExceedsMax();
        slippageBps = newBps;
    }

    function setDepositsEnabled(bool enabled) external onlyKeeper {
        depositsEnabled = enabled;
    }

    function setMaxSingleDeposit(uint256 maxDeposit) external onlyOwner {
        maxSingleDepositHype18 = maxDeposit;
    }

    function setHeartbeatTimeout(uint256 timeout) external onlyOwner {
        heartbeatTimeout = timeout;
    }

    function rescueToken(address token, uint256 amount) external onlyOwner {
        if (token == address(0)) revert ZeroDeposit();
        if (token == counterpartToken && !emergencyMode) revert InEmergency();
        IERC20(token).safeTransfer(factory.owner(), amount);
    }

    function pause() external onlyOwner {
        _pause();
    }

    function unpause() external onlyOwner {
        if (emergencyMode) revert InEmergency();
        _unpause();
    }

    // ═══════════════════════════════════════════════════════════
    //                  AUTO-REBALANCE CONFIG
    // ═══════════════════════════════════════════════════════════

    function setTargetAllocations(uint16 hypeBps, uint16 tokenBps, uint16 usdcBps) external onlyOwner {
        if (hypeBps + tokenBps + usdcBps != 10000) revert MustSumTo100();
        targetHypeBps = hypeBps;
        targetTokenBps = tokenBps;
        targetUsdcBps = usdcBps;
    }

    function setDriftThreshold(uint16 bps) external onlyOwner {
        if (bps == 0 || bps > 5000) revert InvalidThreshold();
        driftThresholdBps = bps;
    }

    function setMinRebalanceNotional(uint256 usdc8) external onlyOwner {
        minRebalanceNotionalUsdc8 = usdc8;
    }

    function setCycleDeadlineBlocks(uint64 blocks) external onlyOwner {
        if (blocks == 0) revert ZeroDeadline();
        cycleDeadlineBlocks = blocks;
    }

    // ═══════════════════════════════════════════════════════════
    //                      INTERNAL HELPERS
    // ═══════════════════════════════════════════════════════════

    function _getSpotBalance(address user, uint32 tokenIndex)
        internal
        view
        returns (uint64 total, uint64 hold)
    {
        return PrecompileLib.getSpotBalance(user, tokenIndex);
    }

    function _getSpotPrice(uint32 spotMarketIndex) internal view returns (uint64) {
        return PrecompileLib.getSpotPrice(spotMarketIndex);
    }

    function _getL1BlockNumber() internal view returns (uint64) {
        return PrecompileLib.getL1BlockNumber();
    }

    function getL1BlockNumber() public view returns (uint64) {
        return _getL1BlockNumber();
    }

    function _validateTradePrice(uint32 spotMarketIndex, uint64 proposedPx, bool isBuy) internal view {
        uint64 spotPx = _getSpotPrice(spotMarketIndex);
        if (isBuy) {
            if (proposedPx > uint64(uint256(spotPx) * (10000 + slippageBps) / 10000)) revert ExceedsMax();
        } else {
            if (proposedPx < uint64(uint256(spotPx) * (10000 - slippageBps) / 10000)) revert ExceedsMax();
        }
    }

    function _validateOrderFormat(uint64 limitPx, uint64 sz, uint8 szDecimals) internal pure {
        if (limitPx == 0 || sz == 0) revert ZeroDeposit();
        if (PriceLib.formatTickPrice(limitPx, szDecimals) != limitPx) revert InvalidPhase();
        uint256 granularity = 10 ** (8 - szDecimals);
        if (uint256(sz) % granularity != 0) revert InvalidPhase();
        if (!SizeLib.isAboveMinNotional(sz, limitPx, szDecimals)) revert Insufficient();
    }

    function _touchHeartbeat() internal {
        lastHeartbeat = block.timestamp;
    }

    /// @dev Shared order validation, price conversion, and CoreWriter dispatch
    function _processAndSendOrder(uint32 asset, bool isBuy, uint64 limitPx, uint64 sz) internal {
        if (asset != 10000 + hypeSpotMarketIndex && asset != 10000 + counterpartSpotMarketIndex) {
            revert UnauthorizedPair();
        }
        uint8 szDecimals = asset == 10000 + hypeSpotMarketIndex ? HYPE_SZ_DECIMALS : counterpartSzDecimals;
        _validateOrderFormat(limitPx, sz, szDecimals);
        _validateTradePrice(
            asset == 10000 + hypeSpotMarketIndex ? hypeSpotMarketIndex : counterpartSpotMarketIndex,
            limitPx,
            isBuy
        );
        uint64 corePx = uint64(uint256(limitPx) * (10 ** szDecimals));
        bytes memory params = abi.encode(asset, isBuy, corePx, sz, false, uint8(2), uint128(0));
        _sendCoreAction(1, params);
    }

    function _sendCoreAction(uint24 actionId, bytes memory params) internal {
        bytes memory payload = CoreActionLib._buildPayload(actionId, params);
        ICoreWriter(CORE_WRITER).sendRawAction(payload);
    }
}
