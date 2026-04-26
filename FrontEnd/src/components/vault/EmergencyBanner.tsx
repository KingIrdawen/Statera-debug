export function EmergencyBanner({
  emergencyMode,
  paused,
}: {
  emergencyMode?: boolean;
  paused?: boolean;
}) {
  if (!emergencyMode && !paused) return null;

  return (
    <div className="rounded-xl border border-red-500/30 bg-red-500/10 px-4 py-3">
      <p className="text-sm font-medium text-red-400">
        {emergencyMode
          ? "Emergency mode is active. Deposits are disabled. Withdrawals via recovery may be available."
          : "The vault is currently paused. Operations are temporarily disabled."}
      </p>
    </div>
  );
}
