"use client";

import { useVaultContext } from "@/context/VaultContext";
import { TESTNET_VAULTS } from "@/constants/vaults";

export function VaultSelector() {
  const { vaultAddress, setVaultAddress } = useVaultContext();

  return (
    <select
      value={vaultAddress}
      onChange={(e) => setVaultAddress(e.target.value as `0x${string}`)}
      className="rounded-lg border border-white/10 bg-white/[0.05] px-3 py-1.5 text-sm text-white backdrop-blur-sm outline-none focus:border-indigo-500/50"
    >
      {TESTNET_VAULTS.map((v) => (
        <option key={v.address} value={v.address} className="bg-gray-900">
          {v.label} ({v.address.slice(0, 6)}...{v.address.slice(-4)})
        </option>
      ))}
    </select>
  );
}
