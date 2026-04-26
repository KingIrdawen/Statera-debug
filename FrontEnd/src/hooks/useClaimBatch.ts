"use client";

import { useWriteContract, useWaitForTransactionReceipt } from "wagmi";
import { rebalancingVaultAbi } from "@/constants/contracts";
import { useVaultAddress } from "@/context/VaultContext";

export function useClaimBatch() {
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

  function claimBatch(redeemId: bigint) {
    writeContract({
      address: vaultAddress,
      abi: rebalancingVaultAbi,
      functionName: "claimBatch",
      args: [redeemId],
    });
  }

  function claimRecovery() {
    writeContract({
      address: vaultAddress,
      abi: rebalancingVaultAbi,
      functionName: "claimRecovery",
    });
  }

  return { claimBatch, claimRecovery, isPending, isConfirming, isSuccess, error, hash, reset };
}
