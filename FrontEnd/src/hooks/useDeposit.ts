"use client";

import { useWriteContract, useWaitForTransactionReceipt, useReadContract } from "wagmi";
import { parseEther } from "viem";
import { rebalancingVaultAbi } from "@/constants/contracts";
import { useVaultAddress } from "@/context/VaultContext";

export function useDeposit() {
  const vaultAddress = useVaultAddress();
  const {
    writeContract,
    data: hash,
    isPending,
    error,
    reset,
  } = useWriteContract();

  const { isLoading: isConfirming, isSuccess } = useWaitForTransactionReceipt({
    hash,
  });

  function deposit(amount: string) {
    writeContract({
      address: vaultAddress,
      abi: rebalancingVaultAbi,
      functionName: "deposit",
      value: parseEther(amount),
    });
  }

  return { deposit, isPending, isConfirming, isSuccess, error, hash, reset };
}

export function usePreviewDeposit(amount: string) {
  const vaultAddress = useVaultAddress();

  const parsed = (() => {
    try {
      return amount && Number(amount) > 0 ? parseEther(amount) : undefined;
    } catch {
      return undefined;
    }
  })();

  const { data, error } = useReadContract({
    address: vaultAddress,
    abi: rebalancingVaultAbi,
    functionName: "previewDeposit",
    args: parsed ? [parsed] : undefined,
    query: { enabled: !!parsed, refetchInterval: 12_000 },
  });

  return { previewShares: data, previewError: error };
}
