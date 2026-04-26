"use client";

import { Card } from "@/components/ui/Card";
import { Skeleton } from "@/components/ui/Skeleton";
import { useCoreBalances } from "@/hooks/useCoreBalances";

export function CoreBalancesCard() {
  const { data: balances, isLoading, error } = useCoreBalances();

  return (
    <Card>
      <h3 className="mb-4 text-sm font-semibold uppercase tracking-wider text-white/60">
        Core Balances (Vault)
      </h3>
      {isLoading ? (
        <div className="space-y-3">
          <Skeleton className="h-6 w-32" />
          <Skeleton className="h-6 w-32" />
          <Skeleton className="h-6 w-32" />
        </div>
      ) : error ? (
        <p className="text-xs text-red-400">Failed to load Core balances</p>
      ) : !balances || balances.length === 0 ? (
        <p className="text-xs text-white/30">No Core balances found</p>
      ) : (
        <div className="space-y-3">
          {balances.map((b) => (
            <div
              key={b.coin}
              className="flex items-center justify-between rounded-lg bg-white/[0.03] px-3 py-2"
            >
              <span className="text-sm text-white/50">{b.coin}</span>
              <div className="text-right">
                <span className="font-mono text-sm text-white">
                  {Number(b.total).toLocaleString("en-US", {
                    minimumFractionDigits: 2,
                    maximumFractionDigits: 6,
                  })}
                </span>
                {Number(b.hold) > 0 && (
                  <span className="ml-2 text-xs text-yellow-400">
                    (hold: {b.hold})
                  </span>
                )}
              </div>
            </div>
          ))}
        </div>
      )}
    </Card>
  );
}
