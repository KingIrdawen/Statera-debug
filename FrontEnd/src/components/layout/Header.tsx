"use client";

import { ConnectButton } from "@rainbow-me/rainbowkit";
import { VaultSelector } from "@/components/vault/VaultSelector";

export function Header() {
  return (
    <header className="border-b border-white/[0.06] bg-black/40 backdrop-blur-md">
      <div className="mx-auto flex max-w-5xl items-center justify-between px-4 py-4">
        <div className="flex items-center gap-3">
          <div className="flex h-8 w-8 items-center justify-center rounded-lg bg-indigo-500/20">
            <span className="text-sm font-bold text-indigo-400">S</span>
          </div>
          <span className="text-lg font-semibold tracking-tight text-white">
            Statera
          </span>
          <VaultSelector />
        </div>
        <ConnectButton
          showBalance={true}
          chainStatus="icon"
          accountStatus="address"
        />
      </div>
    </header>
  );
}
