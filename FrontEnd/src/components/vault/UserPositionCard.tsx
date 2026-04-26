"use client";

import { useAccount } from "wagmi";
import { Card } from "@/components/ui/Card";
import { Skeleton } from "@/components/ui/Skeleton";
import { useUserPosition } from "@/hooks/useUserPosition";
import { useVaultReads } from "@/hooks/useVaultReads";
import { formatShares, formatSharePrice } from "@/lib/format";

export function UserPositionCard() {
  const { isConnected } = useAccount();
  const { balance, isLoading } = useUserPosition();
  const { sharePriceUsdc8, vaultSymbol } = useVaultReads();

  if (!isConnected) return null;

  const usdValue =
    balance !== undefined && balance > 0n && sharePriceUsdc8 !== undefined
      ? (Number(balance) / 1e18) * (Number(sharePriceUsdc8) / 1e8)
      : undefined;

  return (
    <Card>
      <div className="flex items-center justify-between">
        <div>
          <p className="text-xs text-white/40 uppercase tracking-wider">
            Your {vaultSymbol ?? "Share"} Balance
          </p>
          {isLoading ? (
            <Skeleton className="mt-1 h-8 w-40" />
          ) : (
            <div className="mt-1 flex items-baseline gap-3">
              <span className="text-2xl font-bold font-mono text-white">
                {balance !== undefined && balance > 0n
                  ? formatShares(balance)
                  : "0.00"}
              </span>
              <span className="text-sm text-white/40">shares</span>
            </div>
          )}
        </div>
        <div className="text-right">
          <p className="text-xs text-white/40 uppercase tracking-wider">Value</p>
          <p className="mt-1 font-mono text-lg text-white/80">
            {usdValue !== undefined
              ? `$${usdValue.toLocaleString("en-US", { minimumFractionDigits: 2, maximumFractionDigits: 2 })}`
              : "--"}
          </p>
          {sharePriceUsdc8 !== undefined && (
            <p className="text-[10px] text-white/30">
              @ ${formatSharePrice(sharePriceUsdc8)}/share
            </p>
          )}
        </div>
      </div>
    </Card>
  );
}
