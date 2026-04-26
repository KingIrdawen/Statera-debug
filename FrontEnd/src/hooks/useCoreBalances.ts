"use client";

import { useQuery } from "@tanstack/react-query";
import { useVaultAddress } from "@/context/VaultContext";

export type CoreBalance = {
  coin: string;
  token: number;
  total: string;
  hold: string;
};

export function useCoreBalances() {
  const vaultAddress = useVaultAddress();

  return useQuery<CoreBalance[]>({
    queryKey: ["coreBalances", vaultAddress],
    queryFn: async () => {
      const res = await fetch("/api/core-balances", {
        method: "POST",
        headers: { "Content-Type": "application/json" },
        body: JSON.stringify({ vaultAddress }),
      });
      if (!res.ok) throw new Error("Failed to fetch core balances");
      return res.json();
    },
    refetchInterval: 15_000,
    enabled: !!vaultAddress,
  });
}
