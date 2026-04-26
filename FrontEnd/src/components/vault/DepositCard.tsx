"use client";

import { useState, useEffect } from "react";
import { useAccount, useBalance } from "wagmi";
import { formatEther, parseEther } from "viem";
import { Card } from "@/components/ui/Card";
import { Button } from "@/components/ui/Button";
import { NumericInput } from "@/components/ui/Input";
import { useDeposit, usePreviewDeposit } from "@/hooks/useDeposit";
import { useVaultReads } from "@/hooks/useVaultReads";
import { formatShares } from "@/lib/format";

export function DepositCard() {
  const [amount, setAmount] = useState("");
  const { address, isConnected } = useAccount();
  const { data: ethBalance } = useBalance({ address });
  const { depositsEnabled, maxSingleDepositHype18, phase, emergencyMode, paused } =
    useVaultReads();
  const { previewShares, previewError } = usePreviewDeposit(amount);
  const { deposit, isPending, isConfirming, isSuccess, error, reset } = useDeposit();

  useEffect(() => {
    if (isSuccess) {
      setAmount("");
      const timer = setTimeout(reset, 3000);
      return () => clearTimeout(timer);
    }
  }, [isSuccess, reset]);

  const parsedAmount = (() => {
    try {
      return amount && Number(amount) > 0 ? parseEther(amount) : 0n;
    } catch {
      return 0n;
    }
  })();

  const exceedsMax =
    maxSingleDepositHype18 !== undefined &&
    parsedAmount > 0n &&
    parsedAmount > maxSingleDepositHype18;

  const canDeposit =
    isConnected &&
    parsedAmount > 0n &&
    depositsEnabled !== false &&
    phase === 0 &&
    !emergencyMode &&
    !paused &&
    !exceedsMax &&
    !isPending &&
    !isConfirming;

  return (
    <Card>
      <h3 className="mb-4 text-sm font-semibold uppercase tracking-wider text-white/60">
        Deposit HYPE
      </h3>
      <div className="space-y-4">
        <NumericInput
          value={amount}
          onChange={(e) => setAmount(e.target.value)}
          placeholder="0.00"
          symbol="HYPE"
          label="Amount"
          onMax={() => {
            if (ethBalance) {
              const max = ethBalance.value > parseEther("0.01")
                ? ethBalance.value - parseEther("0.01")
                : 0n;
              setAmount(formatEther(max));
            }
          }}
        />

        {previewShares !== undefined && parsedAmount > 0n && (
          <div className="rounded-lg bg-white/[0.03] px-3 py-2 text-sm">
            <span className="text-white/40">You will receive: </span>
            <span className="font-mono text-white">
              {formatShares(previewShares)} shares
            </span>
          </div>
        )}

        {previewError && parsedAmount > 0n && (
          <p className="text-xs text-yellow-400">
            Preview unavailable (rebalance may be in progress)
          </p>
        )}

        {exceedsMax && maxSingleDepositHype18 && (
          <p className="text-xs text-red-400">
            Max single deposit: {formatEther(maxSingleDepositHype18)} HYPE
          </p>
        )}

        <Button
          onClick={() => deposit(amount)}
          disabled={!canDeposit}
          className="w-full"
        >
          {!isConnected
            ? "Connect Wallet"
            : isPending
              ? "Confirm in wallet..."
              : isConfirming
                ? "Confirming..."
                : isSuccess
                  ? "Deposited!"
                  : "Deposit"}
        </Button>

        {error && (
          <p className="text-xs text-red-400 break-all">
            {(error as Error).message?.split("\n")[0]}
          </p>
        )}
      </div>
    </Card>
  );
}
