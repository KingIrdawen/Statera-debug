import { NextRequest, NextResponse } from "next/server";

const HL_API =
  process.env.HYPERLIQUID_API_URL ?? "https://api.hyperliquid-testnet.xyz";

export async function POST(req: NextRequest) {
  const { vaultAddress } = (await req.json()) as { vaultAddress: string };

  if (!vaultAddress || !vaultAddress.startsWith("0x")) {
    return NextResponse.json({ error: "invalid address" }, { status: 400 });
  }

  const res = await fetch(`${HL_API}/info`, {
    method: "POST",
    headers: { "Content-Type": "application/json" },
    body: JSON.stringify({
      type: "spotClearinghouseState",
      user: vaultAddress,
    }),
  });

  if (!res.ok) {
    return NextResponse.json(
      { error: "upstream error", status: res.status },
      { status: 502 },
    );
  }

  const data = (await res.json()) as {
    balances: { coin: string; token: number; total: string; hold: string }[];
  };

  return NextResponse.json(data.balances ?? []);
}
