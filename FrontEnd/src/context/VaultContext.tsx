"use client";

import { createContext, useContext, useState, useEffect, type ReactNode } from "react";
import { DEFAULT_VAULT } from "@/constants/vaults";

type VaultContextType = {
  vaultAddress: `0x${string}`;
  setVaultAddress: (address: `0x${string}`) => void;
};

const VaultContext = createContext<VaultContextType | null>(null);

const STORAGE_KEY = "statera-vault-address";

export function VaultProvider({ children }: { children: ReactNode }) {
  const [vaultAddress, setVaultAddress] = useState<`0x${string}`>(DEFAULT_VAULT.address);

  useEffect(() => {
    const stored = localStorage.getItem(STORAGE_KEY);
    if (stored && stored.startsWith("0x")) {
      setVaultAddress(stored as `0x${string}`);
    }
  }, []);

  function handleSetVault(address: `0x${string}`) {
    setVaultAddress(address);
    localStorage.setItem(STORAGE_KEY, address);
  }

  return (
    <VaultContext.Provider value={{ vaultAddress, setVaultAddress: handleSetVault }}>
      {children}
    </VaultContext.Provider>
  );
}

export function useVaultAddress(): `0x${string}` {
  const ctx = useContext(VaultContext);
  if (!ctx) throw new Error("useVaultAddress must be used within VaultProvider");
  return ctx.vaultAddress;
}

export function useVaultContext() {
  const ctx = useContext(VaultContext);
  if (!ctx) throw new Error("useVaultContext must be used within VaultProvider");
  return ctx;
}
