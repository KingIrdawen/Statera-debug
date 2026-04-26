import { formatEther, formatUnits } from "viem";

export function formatUsdc8(value: bigint): string {
  const num = Number(formatUnits(value, 8));
  return num.toLocaleString("en-US", {
    minimumFractionDigits: 2,
    maximumFractionDigits: 2,
  });
}

export function formatSharePrice(sharePriceUsdc8: bigint): string {
  // sharePriceUsdc8 = (grossAssets + 1e8) * 1e18 / (totalSupply + 1e18)
  // The raw value is in usdc8 scale (8 decimals) per 1e18 shares
  // To get USD per share: value / 1e8
  const num = Number(sharePriceUsdc8) / 1e8;
  return num.toLocaleString("en-US", {
    minimumFractionDigits: 4,
    maximumFractionDigits: 4,
  });
}

export function formatHype(value: bigint): string {
  const num = Number(formatEther(value));
  return num.toLocaleString("en-US", {
    minimumFractionDigits: 2,
    maximumFractionDigits: 4,
  });
}

export function formatShares(value: bigint): string {
  const num = Number(formatEther(value));
  return num.toLocaleString("en-US", {
    minimumFractionDigits: 2,
    maximumFractionDigits: 6,
  });
}

export function shortenAddress(address: string): string {
  return `${address.slice(0, 6)}...${address.slice(-4)}`;
}
