"use client";

import { useReadContracts } from "wagmi";
import { rebalancingVaultAbi } from "@/constants/contracts";
import { useVaultAddress } from "@/context/VaultContext";

export function useVaultReads() {
  const vaultAddress = useVaultAddress();

  const vaultContract = {
    address: vaultAddress,
    abi: rebalancingVaultAbi,
  } as const;

  const { data, isLoading, error, refetch } = useReadContracts({
    contracts: [
      { ...vaultContract, functionName: "grossAssets" },           // 0
      { ...vaultContract, functionName: "sharePriceUsdc8" },       // 1
      { ...vaultContract, functionName: "circulatingShares" },     // 2
      { ...vaultContract, functionName: "totalSupply" },           // 3
      { ...vaultContract, functionName: "currentCycle" },          // 4
      { ...vaultContract, functionName: "currentBatchId" },        // 5
      { ...vaultContract, functionName: "depositsEnabled" },       // 6
      { ...vaultContract, functionName: "emergencyMode" },         // 7
      { ...vaultContract, functionName: "maxSingleDepositHype18" },// 8
      { ...vaultContract, functionName: "name" },                  // 9
      { ...vaultContract, functionName: "symbol" },                // 10
      { ...vaultContract, functionName: "paused" },                // 11
      { ...vaultContract, functionName: "targetHypeBps" },         // 12
      { ...vaultContract, functionName: "targetTokenBps" },        // 13
      { ...vaultContract, functionName: "targetUsdcBps" },         // 14
      { ...vaultContract, functionName: "driftThresholdBps" },     // 15
      { ...vaultContract, functionName: "slippageBps" },           // 16
      { ...vaultContract, functionName: "counterpartToken" },      // 17
      { ...vaultContract, functionName: "lastHeartbeat" },         // 18
      { ...vaultContract, functionName: "heartbeatTimeout" },      // 19
      { ...vaultContract, functionName: "currentSettlement" },     // 20
      { ...vaultContract, functionName: "escrowedShares" },        // 21
      { ...vaultContract, functionName: "reservedHypeForClaims" }, // 22
      { ...vaultContract, functionName: "isEmergency" },           // 23
      { ...vaultContract, functionName: "getL1BlockNumber" },      // 24
      { ...vaultContract, functionName: "processingBatchCount" },  // 25
    ],
    query: {
      refetchInterval: 12_000,
    },
  });

  const r = data ?? [];

  const currentCycle = r[4]?.result as
    | readonly [bigint, number, bigint, bigint, bigint, bigint, bigint, bigint]
    | undefined;

  const currentSettlement = r[20]?.result as
    | readonly [bigint, number, bigint, bigint, bigint]
    | undefined;

  return {
    // Accounting
    grossAssets: r[0]?.result as bigint | undefined,
    sharePriceUsdc8: r[1]?.result as bigint | undefined,
    circulatingShares: r[2]?.result as bigint | undefined,
    totalSupply: r[3]?.result as bigint | undefined,
    escrowedShares: r[21]?.result as bigint | undefined,
    reservedHypeForClaims: r[22]?.result as bigint | undefined,

    // Rebalance cycle
    cycleId: currentCycle?.[0],
    phase: currentCycle?.[1],
    cycleStartedAt: currentCycle?.[2],
    cycleLastAction: currentCycle?.[3],
    cycleDeadline: currentCycle?.[4],

    // Settlement
    settlementBatchId: currentSettlement?.[0],
    settlementPhase: currentSettlement?.[1],
    settlementLastAction: currentSettlement?.[2],
    settlementDeadline: currentSettlement?.[3],
    settlementHypeEvmBefore: currentSettlement?.[4],

    // Batch
    currentBatchId: r[5]?.result as bigint | undefined,
    processingBatchCount: r[25]?.result as bigint | undefined,

    // Flags
    depositsEnabled: r[6]?.result as boolean | undefined,
    emergencyMode: r[7]?.result as boolean | undefined,
    paused: r[11]?.result as boolean | undefined,
    isEmergency: r[23]?.result as boolean | undefined,

    // Config
    maxSingleDepositHype18: r[8]?.result as bigint | undefined,
    targetHypeBps: r[12]?.result as number | undefined,
    targetTokenBps: r[13]?.result as number | undefined,
    targetUsdcBps: r[14]?.result as number | undefined,
    driftThresholdBps: r[15]?.result as number | undefined,
    slippageBps: r[16]?.result as bigint | undefined,
    counterpartToken: r[17]?.result as `0x${string}` | undefined,

    // Heartbeat
    lastHeartbeat: r[18]?.result as bigint | undefined,
    heartbeatTimeout: r[19]?.result as bigint | undefined,

    // L1 block
    l1BlockNumber: r[24]?.result as bigint | undefined,

    // Meta
    vaultName: r[9]?.result as string | undefined,
    vaultSymbol: r[10]?.result as string | undefined,

    isLoading,
    error,
    refetch,
  };
}
