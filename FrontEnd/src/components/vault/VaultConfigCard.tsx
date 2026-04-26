"use client";

import { Card } from "@/components/ui/Card";
import { Skeleton } from "@/components/ui/Skeleton";
import { useVaultReads } from "@/hooks/useVaultReads";
import { formatEther } from "viem";

const REBALANCE_PHASES: Record<number, string> = {
  0: "Idle",
  1: "Bridging In",
  2: "Awaiting Bridge In",
  3: "Trading",
  4: "Awaiting Trades",
  5: "Bridging Out",
  6: "Awaiting Bridge Out",
  7: "Finalizing",
};

const SETTLEMENT_PHASES: Record<number, string> = {
  0: "None",
  1: "Selling Token",
  2: "Awaiting Sell",
  3: "Buying HYPE",
  4: "Awaiting Buy",
  5: "Bridging Out",
  6: "Awaiting Bridge",
  7: "Settling",
};

function Row({ label, value }: { label: string; value: React.ReactNode }) {
  return (
    <div className="flex items-center justify-between py-1">
      <span className="text-xs text-white/40">{label}</span>
      <span className="font-mono text-xs text-white">{value}</span>
    </div>
  );
}

export function VaultConfigCard() {
  const {
    targetHypeBps,
    targetTokenBps,
    targetUsdcBps,
    driftThresholdBps,
    slippageBps,
    lastHeartbeat,
    heartbeatTimeout,
    phase,
    cycleId,
    cycleDeadline,
    settlementPhase,
    settlementBatchId,
    l1BlockNumber,
    escrowedShares,
    reservedHypeForClaims,
    processingBatchCount,
    currentBatchId,
    isEmergency,
    isLoading,
  } = useVaultReads();

  const heartbeatAge =
    lastHeartbeat !== undefined
      ? Math.floor(Date.now() / 1000) - Number(lastHeartbeat)
      : undefined;

  const heartbeatOk =
    heartbeatAge !== undefined && heartbeatTimeout !== undefined
      ? heartbeatAge < Number(heartbeatTimeout)
      : undefined;

  if (isLoading) {
    return (
      <Card>
        <h3 className="mb-4 text-sm font-semibold uppercase tracking-wider text-white/60">
          Vault State
        </h3>
        <div className="space-y-2">
          {Array.from({ length: 8 }).map((_, i) => (
            <Skeleton key={i} className="h-5 w-full" />
          ))}
        </div>
      </Card>
    );
  }

  return (
    <Card>
      <h3 className="mb-3 text-sm font-semibold uppercase tracking-wider text-white/60">
        Vault State
      </h3>

      <div className="mb-3 border-b border-white/[0.06] pb-2">
        <p className="mb-1 text-[10px] font-semibold uppercase tracking-widest text-white/30">
          Target Allocation
        </p>
        <div className="flex gap-3">
          <span className="rounded bg-indigo-500/10 px-2 py-0.5 text-xs text-indigo-300">
            HYPE {targetHypeBps !== undefined ? (targetHypeBps / 100).toFixed(0) : "--"}%
          </span>
          <span className="rounded bg-emerald-500/10 px-2 py-0.5 text-xs text-emerald-300">
            TOKEN {targetTokenBps !== undefined ? (targetTokenBps / 100).toFixed(0) : "--"}%
          </span>
          <span className="rounded bg-amber-500/10 px-2 py-0.5 text-xs text-amber-300">
            USDC {targetUsdcBps !== undefined ? (targetUsdcBps / 100).toFixed(0) : "--"}%
          </span>
        </div>
      </div>

      <div className="mb-3 border-b border-white/[0.06] pb-2">
        <p className="mb-1 text-[10px] font-semibold uppercase tracking-widest text-white/30">
          Rebalance
        </p>
        <Row label="Phase" value={phase !== undefined ? REBALANCE_PHASES[phase] ?? `Unknown (${phase})` : "--"} />
        <Row label="Cycle" value={cycleId?.toString() ?? "--"} />
        <Row label="Deadline (L1)" value={cycleDeadline?.toString() ?? "--"} />
      </div>

      <div className="mb-3 border-b border-white/[0.06] pb-2">
        <p className="mb-1 text-[10px] font-semibold uppercase tracking-widest text-white/30">
          Settlement
        </p>
        <Row label="Phase" value={settlementPhase !== undefined ? SETTLEMENT_PHASES[settlementPhase] ?? `Unknown (${settlementPhase})` : "--"} />
        <Row label="Batch" value={settlementBatchId?.toString() ?? "--"} />
        <Row label="Processing" value={processingBatchCount?.toString() ?? "0"} />
        <Row label="Current Batch" value={currentBatchId?.toString() ?? "--"} />
      </div>

      <div className="mb-3 border-b border-white/[0.06] pb-2">
        <p className="mb-1 text-[10px] font-semibold uppercase tracking-widest text-white/30">
          Config
        </p>
        <Row label="Drift Threshold" value={driftThresholdBps !== undefined ? `${(driftThresholdBps / 100).toFixed(1)}%` : "--"} />
        <Row label="Slippage" value={slippageBps !== undefined ? `${(Number(slippageBps) / 100).toFixed(1)}%` : "--"} />
        <Row
          label="Escrowed Shares"
          value={escrowedShares !== undefined ? Number(formatEther(escrowedShares)).toLocaleString("en-US", { maximumFractionDigits: 4 }) : "--"}
        />
        <Row
          label="Reserved HYPE"
          value={reservedHypeForClaims !== undefined ? Number(formatEther(reservedHypeForClaims)).toLocaleString("en-US", { maximumFractionDigits: 4 }) : "--"}
        />
      </div>

      <div>
        <p className="mb-1 text-[10px] font-semibold uppercase tracking-widest text-white/30">
          Keeper
        </p>
        <Row
          label="Heartbeat"
          value={
            heartbeatAge !== undefined ? (
              <span className={heartbeatOk ? "text-green-400" : "text-red-400"}>
                {heartbeatAge < 60
                  ? `${heartbeatAge}s ago`
                  : heartbeatAge < 3600
                    ? `${Math.floor(heartbeatAge / 60)}m ago`
                    : `${Math.floor(heartbeatAge / 3600)}h ago`}
              </span>
            ) : (
              "--"
            )
          }
        />
        <Row
          label="Emergency"
          value={
            isEmergency !== undefined ? (
              <span className={isEmergency ? "text-red-400" : "text-green-400"}>
                {isEmergency ? "YES" : "No"}
              </span>
            ) : (
              "--"
            )
          }
        />
        <Row label="L1 Block" value={l1BlockNumber?.toString() ?? "--"} />
      </div>
    </Card>
  );
}
