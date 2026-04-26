"use client";

import { useAccount } from "wagmi";
import { Card } from "@/components/ui/Card";
import { Button } from "@/components/ui/Button";
import { Badge } from "@/components/ui/Badge";
import { useUserPosition } from "@/hooks/useUserPosition";
import { useClaimBatch } from "@/hooks/useClaimBatch";
import { formatShares, formatHype } from "@/lib/format";

const BATCH_STATUS: Record<number, { label: string; color: "gray" | "yellow" | "green" }> = {
  0: { label: "Open", color: "gray" },
  1: { label: "Closed", color: "yellow" },
  2: { label: "Settled", color: "green" },
};

export function RedeemList() {
  const { isConnected } = useAccount();
  const { redeems, isLoading } = useUserPosition();
  const { claimBatch, isPending, isConfirming } = useClaimBatch();

  if (!isConnected) return null;
  if (!isLoading && redeems.length === 0) return null;

  return (
    <Card>
      <h3 className="mb-4 text-sm font-semibold uppercase tracking-wider text-white/60">
        Your Redemptions
      </h3>
      {isLoading ? (
        <p className="text-sm text-white/30">Loading...</p>
      ) : (
        <div className="overflow-x-auto">
          <table className="w-full text-sm">
            <thead>
              <tr className="border-b border-white/[0.06] text-left text-xs text-white/30 uppercase">
                <th className="pb-2 pr-4">ID</th>
                <th className="pb-2 pr-4">Shares</th>
                <th className="pb-2 pr-4">Batch</th>
                <th className="pb-2 pr-4">Status</th>
                <th className="pb-2 pr-4">Claimable</th>
                <th className="pb-2" />
              </tr>
            </thead>
            <tbody>
              {redeems.map((r) => {
                const batchStatus = r.batch
                  ? BATCH_STATUS[r.batch.status] ?? { label: "Unknown", color: "gray" as const }
                  : { label: "...", color: "gray" as const };

                const isSettled = r.batch?.status === 2;
                const canClaim = isSettled && !r.claimed;

                const claimableHype =
                  isSettled && r.batch && r.batch.totalEscrowedShares > 0n
                    ? (r.shares * r.batch.totalHypeRecovered) /
                      r.batch.totalEscrowedShares
                    : 0n;

                return (
                  <tr
                    key={r.id.toString()}
                    className="border-b border-white/[0.04] last:border-0"
                  >
                    <td className="py-3 pr-4 font-mono text-white/60">
                      #{r.id.toString()}
                    </td>
                    <td className="py-3 pr-4 font-mono text-white">
                      {formatShares(r.shares)}
                    </td>
                    <td className="py-3 pr-4 font-mono text-white/60">
                      #{r.batchId.toString()}
                    </td>
                    <td className="py-3 pr-4">
                      {r.claimed ? (
                        <Badge color="gray">Claimed</Badge>
                      ) : (
                        <Badge color={batchStatus.color}>{batchStatus.label}</Badge>
                      )}
                    </td>
                    <td className="py-3 pr-4 font-mono text-white">
                      {canClaim ? `${formatHype(claimableHype)} HYPE` : "--"}
                    </td>
                    <td className="py-3">
                      {canClaim && (
                        <Button
                          variant="primary"
                          onClick={() => claimBatch(r.id)}
                          disabled={isPending || isConfirming}
                          className="text-xs px-3 py-1.5"
                        >
                          {isPending || isConfirming ? "..." : "Claim"}
                        </Button>
                      )}
                    </td>
                  </tr>
                );
              })}
            </tbody>
          </table>
        </div>
      )}
    </Card>
  );
}
