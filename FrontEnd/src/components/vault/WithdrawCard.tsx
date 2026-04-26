"use client";

import { useState, useEffect } from "react";
import { useAccount } from "wagmi";
import { formatEther } from "viem";
import { Card } from "@/components/ui/Card";
import { Button } from "@/components/ui/Button";
import { NumericInput } from "@/components/ui/Input";
import { useRequestRedeem } from "@/hooks/useRequestRedeem";
import { useUserPosition } from "@/hooks/useUserPosition";
import { formatShares } from "@/lib/format";

export function WithdrawCard() {
  const [shares, setShares] = useState("");
  const { isConnected } = useAccount();
  const { balance } = useUserPosition();
  const { requestRedeem, isPending, isConfirming, isSuccess, error, reset } =
    useRequestRedeem();

  useEffect(() => {
    if (isSuccess) {
      setShares("");
      const timer = setTimeout(reset, 3000);
      return () => clearTimeout(timer);
    }
  }, [isSuccess, reset]);

  const parsedShares = (() => {
    try {
      return shares && Number(shares) > 0 ? BigInt(Math.floor(Number(shares) * 1e18)) : 0n;
    } catch {
      return 0n;
    }
  })();

  const exceedsBalance = balance !== undefined && parsedShares > 0n && parsedShares > balance;

  const canRedeem =
    isConnected &&
    parsedShares > 0n &&
    !exceedsBalance &&
    !isPending &&
    !isConfirming;

  return (
    <Card>
      <h3 className="mb-4 text-sm font-semibold uppercase tracking-wider text-white/60">
        Request Withdrawal
      </h3>
      <div className="space-y-4">
        <NumericInput
          value={shares}
          onChange={(e) => setShares(e.target.value)}
          placeholder="0.00"
          symbol="SHARES"
          label="Shares to redeem"
          onMax={() => {
            if (balance) setShares(formatEther(balance));
          }}
        />

        {balance !== undefined && balance > 0n && (
          <p className="text-xs text-white/30">
            Your balance: <span className="font-mono text-white/50">{formatShares(balance)}</span> shares
          </p>
        )}

        {exceedsBalance && (
          <p className="text-xs text-red-400">Exceeds your share balance</p>
        )}

        <Button
          onClick={() => requestRedeem(shares)}
          disabled={!canRedeem}
          variant="secondary"
          className="w-full"
        >
          {!isConnected
            ? "Connect Wallet"
            : isPending
              ? "Confirm in wallet..."
              : isConfirming
                ? "Confirming..."
                : isSuccess
                  ? "Requested!"
                  : "Request Redeem"}
        </Button>

        <p className="text-xs text-white/20">
          Withdrawals are processed in batches. After requesting, your shares are
          escrowed until the batch is settled, then you can claim your HYPE.
        </p>

        {error && (
          <p className="text-xs text-red-400 break-all">
            {(error as Error).message?.split("\n")[0]}
          </p>
        )}
      </div>
    </Card>
  );
}
