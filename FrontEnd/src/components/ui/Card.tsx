import { type ReactNode } from "react";

export function Card({
  children,
  className = "",
}: {
  children: ReactNode;
  className?: string;
}) {
  return (
    <div
      className={`rounded-xl border border-white/[0.08] bg-white/[0.02] p-6 backdrop-blur-sm ${className}`}
    >
      {children}
    </div>
  );
}
