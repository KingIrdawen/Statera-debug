"use client";

import { type InputHTMLAttributes } from "react";

export function NumericInput({
  onMax,
  label,
  symbol,
  ...props
}: InputHTMLAttributes<HTMLInputElement> & {
  onMax?: () => void;
  label?: string;
  symbol?: string;
}) {
  return (
    <div className="space-y-1.5">
      {label && (
        <label className="text-xs text-white/50 uppercase tracking-wider">
          {label}
        </label>
      )}
      <div className="flex items-center gap-2 rounded-lg border border-white/[0.08] bg-white/[0.03] px-3 py-2.5">
        <input
          type="text"
          inputMode="decimal"
          autoComplete="off"
          className="flex-1 bg-transparent text-lg font-mono text-white outline-none placeholder:text-white/20"
          {...props}
        />
        {symbol && (
          <span className="text-sm text-white/40 font-mono">{symbol}</span>
        )}
        {onMax && (
          <button
            type="button"
            onClick={onMax}
            className="rounded bg-indigo-500/20 px-2 py-0.5 text-xs font-medium text-indigo-400 hover:bg-indigo-500/30 transition-colors"
          >
            MAX
          </button>
        )}
      </div>
    </div>
  );
}
