"use client";

import { useReadContract, useReadContracts } from "wagmi";
import { useAccount } from "wagmi";
import { rebalancingVaultAbi } from "@/constants/contracts";
import { useVaultAddress } from "@/context/VaultContext";

export function useUserPosition() {
  const vaultAddress = useVaultAddress();
  const { address } = useAccount();

  const vaultContract = {
    address: vaultAddress,
    abi: rebalancingVaultAbi,
  } as const;

  const { data: balance, isLoading: balanceLoading } = useReadContract({
    ...vaultContract,
    functionName: "balanceOf",
    args: address ? [address] : undefined,
    query: { enabled: !!address, refetchInterval: 12_000 },
  });

  const { data: redeemIds, isLoading: redeemIdsLoading } = useReadContract({
    ...vaultContract,
    functionName: "getUserRedeemIds",
    args: address ? [address] : undefined,
    query: { enabled: !!address, refetchInterval: 12_000 },
  });

  const redeemContracts =
    redeemIds?.map((id) => ({
      ...vaultContract,
      functionName: "redeemRequests" as const,
      args: [id] as const,
    })) ?? [];

  const { data: redeemData, isLoading: redeemDataLoading } = useReadContracts({
    contracts: redeemContracts,
    query: { enabled: redeemContracts.length > 0, refetchInterval: 12_000 },
  });

  const batchIds = new Set<bigint>();
  redeemData?.forEach((r) => {
    if (r.result) {
      const result = r.result as readonly [string, bigint, bigint, boolean];
      batchIds.add(result[2]);
    }
  });

  const batchContracts = Array.from(batchIds).map((id) => ({
    ...vaultContract,
    functionName: "batches" as const,
    args: [id] as const,
  }));

  const { data: batchData } = useReadContracts({
    contracts: batchContracts,
    query: { enabled: batchContracts.length > 0, refetchInterval: 12_000 },
  });

  const batchMap = new Map<
    string,
    {
      totalEscrowedShares: bigint;
      totalHypeRecovered: bigint;
      status: number;
    }
  >();

  const batchIdArr = Array.from(batchIds);
  batchData?.forEach((b, i) => {
    if (b.result) {
      const result = b.result as readonly [
        bigint,
        bigint,
        bigint,
        bigint,
        bigint,
        bigint,
        number,
      ];
      batchMap.set(batchIdArr[i].toString(), {
        totalEscrowedShares: result[0],
        totalHypeRecovered: result[2],
        status: result[6],
      });
    }
  });

  const redeems =
    redeemIds?.map((id, i) => {
      const r = redeemData?.[i]?.result as
        | readonly [string, bigint, bigint, boolean]
        | undefined;
      if (!r) return null;
      const batch = batchMap.get(r[2].toString());
      return {
        id,
        user: r[0],
        shares: r[1],
        batchId: r[2],
        claimed: r[3],
        batch,
      };
    }) ?? [];

  return {
    balance,
    redeems: redeems.filter(Boolean) as NonNullable<(typeof redeems)[number]>[],
    isLoading: balanceLoading || redeemIdsLoading || redeemDataLoading,
  };
}
