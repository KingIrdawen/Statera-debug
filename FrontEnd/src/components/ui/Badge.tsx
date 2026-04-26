import { type ReactNode } from "react";

const colors = {
  green: "bg-emerald-500/15 text-emerald-400 border-emerald-500/20",
  blue: "bg-blue-500/15 text-blue-400 border-blue-500/20",
  yellow: "bg-yellow-500/15 text-yellow-400 border-yellow-500/20",
  red: "bg-red-500/15 text-red-400 border-red-500/20",
  purple: "bg-purple-500/15 text-purple-400 border-purple-500/20",
  gray: "bg-white/[0.06] text-white/50 border-white/[0.08]",
} as const;

export function Badge({
  color = "gray",
  children,
}: {
  color?: keyof typeof colors;
  children: ReactNode;
}) {
  return (
    <span
      className={`inline-flex items-center rounded-full border px-2.5 py-0.5 text-xs font-medium ${colors[color]}`}
    >
      {children}
    </span>
  );
}
