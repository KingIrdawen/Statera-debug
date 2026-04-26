"use client";

import { Header } from "@/components/layout/Header";
import { Footer } from "@/components/layout/Footer";
import { VaultStats } from "@/components/vault/VaultStats";
import { UserPositionCard } from "@/components/vault/UserPositionCard";
import { CoreBalancesCard } from "@/components/vault/CoreBalancesCard";
import { VaultConfigCard } from "@/components/vault/VaultConfigCard";
import { DepositCard } from "@/components/vault/DepositCard";
import { WithdrawCard } from "@/components/vault/WithdrawCard";
import { RedeemList } from "@/components/vault/RedeemList";
import { EmergencyBanner } from "@/components/vault/EmergencyBanner";
import { useVaultReads } from "@/hooks/useVaultReads";

export default function Home() {
  const { emergencyMode, paused } = useVaultReads();

  return (
    <div className="flex min-h-screen flex-col">
      <Header />
      <main className="mx-auto w-full max-w-5xl flex-1 px-4 py-8">
        <div className="space-y-6">
          <EmergencyBanner emergencyMode={emergencyMode} paused={paused} />
          <VaultStats />
          <UserPositionCard />
          <div className="grid gap-6 md:grid-cols-2">
            <CoreBalancesCard />
            <VaultConfigCard />
          </div>
          <div className="grid gap-6 md:grid-cols-2">
            <DepositCard />
            <WithdrawCard />
          </div>
          <RedeemList />
        </div>
      </main>
      <Footer />
    </div>
  );
}
