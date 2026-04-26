import { Badge } from "@/components/ui/Badge";

const PHASE_CONFIG: Record<
  number,
  { label: string; color: "green" | "blue" | "yellow" | "purple" | "red" | "gray" }
> = {
  0: { label: "Idle", color: "green" },
  1: { label: "Bridge Out", color: "blue" },
  2: { label: "Trading", color: "purple" },
  3: { label: "Bridge In", color: "blue" },
  4: { label: "Finalizing", color: "yellow" },
};

export function PhaseBadge({ phase }: { phase: number | undefined }) {
  if (phase === undefined) return <Badge color="gray">--</Badge>;
  const config = PHASE_CONFIG[phase] ?? { label: `Phase ${phase}`, color: "gray" as const };
  return <Badge color={config.color}>{config.label}</Badge>;
}
