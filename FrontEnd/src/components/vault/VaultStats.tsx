"use client";

import { Card } from "@/components/ui/Card";
import { Skeleton } from "@/components/ui/Skeleton";
import { PhaseBadge } from "./PhaseBadge";
import { useVaultReads } from "@/hooks/useVaultReads";
import { formatUsdc8, formatSharePrice, formatShares } from "@/lib/format";

function StatItem({
  label,
  value,
  isLoading,
  mono = false,
}: {
  label: string;
  value: React.ReactNode;
  isLoading: boolean;
  mono?: boolean;
}) {
  return (
    <div className="space-y-1">
      <p className="text-xs text-white/40 uppercase tracking-wider">{label}</p>
      {isLoading ? (
        <Skeleton className="h-7 w-24" />
      ) : (
        <p className={`text-xl font-semibold text-white ${mono ? "font-mono" : ""}`}>
          {value}
        </p>
      )}
    </div>
  );
}

export function VaultStats() {
  const {
    grossAssets,
    sharePriceUsdc8,
    circulatingShares,
    phase,
    depositsEnabled,
    vaultName,
    isLoading,
  } = useVaultReads();

  return (
    <Card>
      <div className="mb-4 flex items-center justify-between">
        <div>
          <h2 className="text-lg font-semibold text-white">
            {isLoading ? <Skeleton className="h-6 w-40" /> : vaultName ?? "Vault"}
          </h2>
        </div>
        <div className="flex items-center gap-2">
          <PhaseBadge phase={phase} />
          {depositsEnabled === false && (
            <span className="rounded-full bg-yellow-500/15 border border-yellow-500/20 px-2.5 py-0.5 text-xs font-medium text-yellow-400">
              Deposits Off
            </span>
          )}
        </div>
      </div>
      <div className="grid grid-cols-2 gap-6 sm:grid-cols-3">
        <StatItem
          label="TVL"
          value={grossAssets !== undefined ? `$${formatUsdc8(grossAssets)}` : "--"}
          isLoading={isLoading}
          mono
        />
        <StatItem
          label="Share Price"
          value={
            sharePriceUsdc8 !== undefined
              ? `$${formatSharePrice(sharePriceUsdc8)}`
              : "--"
          }
          isLoading={isLoading}
          mono
        />
        <StatItem
          label="Circulating Shares"
          value={
            circulatingShares !== undefined
              ? formatShares(circulatingShares)
              : "--"
          }
          isLoading={isLoading}
          mono
        />
      </div>
    </Card>
  );
}
