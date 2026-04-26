"use client";

import { useWriteContract, useWaitForTransactionReceipt } from "wagmi";
import { parseEther } from "viem";
import { rebalancingVaultAbi } from "@/constants/contracts";
import { useVaultAddress } from "@/context/VaultContext";

export function useRequestRedeem() {
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

  function requestRedeem(shares: string) {
    writeContract({
      address: vaultAddress,
      abi: rebalancingVaultAbi,
      functionName: "requestRedeem",
      args: [parseEther(shares)],
    });
  }

  return { requestRedeem, isPending, isConfirming, isSuccess, error, hash, reset };
}
