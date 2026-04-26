"use client";

import { cn } from "@/lib/utils";
import { forwardRef } from "react";
import { motion, HTMLMotionProps } from "framer-motion";

const variants = {
  primary:
    "bg-indigo-600 hover:bg-indigo-700 text-white disabled:bg-indigo-600/40 shadow-lg shadow-indigo-900/20",
  secondary:
    "bg-white/[0.03] hover:bg-white/[0.08] text-white border border-white/[0.08] disabled:opacity-40 backdrop-blur-sm",
  danger:
    "bg-red-500/10 hover:bg-red-500/20 text-red-400 border border-red-500/20 disabled:opacity-40",
  ghost:
    "bg-transparent hover:bg-white/[0.05] text-white/70 hover:text-white disabled:opacity-40",
  outline:
    "bg-transparent border border-white/10 hover:bg-white/[0.03] text-white disabled:opacity-40",
} as const;

type ButtonProps = Omit<HTMLMotionProps<"button">, "onDrag"> & {
  variant?: keyof typeof variants;
  size?: "sm" | "md" | "lg" | "icon";
  isLoading?: boolean;
};

export const Button = forwardRef<HTMLButtonElement, ButtonProps>(
  (
    {
      variant = "primary",
      size = "md",
      isLoading = false,
      className = "",
      children,
      disabled,
      ...props
    },
    ref
  ) => {
    const sizeClasses = {
      sm: "px-3 py-1.5 text-xs",
      md: "px-4 py-2.5 text-sm",
      lg: "px-6 py-3 text-base",
      icon: "h-10 w-10 p-0 flex items-center justify-center",
    };

    return (
      <motion.button
        ref={ref}
        whileTap={{ scale: 0.98 }}
        whileHover={{ scale: disabled || isLoading ? 1 : 1.02 }}
        className={cn(
          "relative inline-flex items-center justify-center rounded-xl font-medium transition-all focus:outline-none focus:ring-2 focus:ring-indigo-500/50 disabled:cursor-not-allowed",
          variants[variant],
          sizeClasses[size],
          isLoading && "text-transparent",
          className
        )}
        disabled={disabled || isLoading}
        {...props}
      >
        {isLoading && (
          <div className="absolute inset-0 flex items-center justify-center">
            <svg
              className="h-4 w-4 animate-spin text-current"
              fill="none"
              viewBox="0 0 24 24"
            >
              <circle
                className="opacity-25"
                cx="12"
                cy="12"
                r="10"
                stroke="currentColor"
                strokeWidth="4"
              ></circle>
              <path
                className="opacity-75"
                fill="currentColor"
                d="M4 12a8 8 0 018-8V0C5.373 0 0 5.373 0 12h4zm2 5.291A7.962 7.962 0 014 12H0c0 3.042 1.135 5.824 3 7.938l3-2.647z"
              ></path>
            </svg>
          </div>
        )}
        <span className={isLoading ? "invisible" : ""}>{children as React.ReactNode}</span>
      </motion.button>
    );
  }
);

Button.displayName = "Button";
