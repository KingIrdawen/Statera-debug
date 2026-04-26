"""Final verification of all vault allocations."""
import json
import httpx
from web3 import Web3
from pathlib import Path

HL_API = "https://api.hyperliquid-testnet.xyz"
w3 = Web3(Web3.HTTPProvider("https://rpc.hyperliquid-testnet.xyz/evm"))

abi_path = Path(__file__).parent.parent / "keeper" / "abi" / "RebalancingVault.json"
with open(abi_path) as f:
    vault_abi = json.load(f)

VAULTS = {
    "SOVY": {"address": "0x22276e9562e38c309f8Dedf8f1fB405297560da7", "szDec": 1, "spotMarket": 1080},
    "BARK": {"address": "0x720021b106B42a625c1dC2322214A3248A09bb6a", "szDec": 0, "spotMarket": 218},
    "ZIGG": {"address": "0x66e880e2bd93243569B985499aD00Df543a77554", "szDec": 2, "spotMarket": 980},
}

mids = httpx.post(f"{HL_API}/info", json={"type": "allMids"}).json()

print("=" * 60)
print("  FINAL VERIFICATION")
print("=" * 60)

for name, cfg in VAULTS.items():
    addr = cfg["address"]
    vault = w3.eth.contract(address=Web3.to_checksum_address(addr), abi=vault_abi)

    resp = httpx.post(f"{HL_API}/info", json={"type": "spotClearinghouseState", "user": addr})
    core_bals = {b["coin"]: float(b["total"]) for b in resp.json()["balances"] if float(b["total"]) > 0}
    evm_hype = w3.eth.get_balance(Web3.to_checksum_address(addr)) / 1e18

    try:
        gross = vault.functions.grossAssets().call() / 1e8
        supply = vault.functions.totalSupply().call() / 1e18
    except:
        gross = supply = 0

    hype_mid = float(mids.get("@1035", "0"))
    token_mid = float(mids.get("@" + str(cfg["spotMarket"]), "0"))

    hype_value = evm_hype * hype_mid + core_bals.get("HYPE", 0) * hype_mid
    token_value = core_bals.get(name, 0) * token_mid
    usdc_value = core_bals.get("USDC", 0)
    total = hype_value + token_value + usdc_value

    print(f"\n  {name} (szDec={cfg['szDec']}):")
    print(f"    EVM HYPE: {evm_hype:.6f} (${evm_hype * hype_mid:.2f})")
    for coin, amt in core_bals.items():
        mid = hype_mid if coin == "HYPE" else (token_mid if coin == name else 1.0)
        print(f"    Core {coin}: {amt} (${amt * mid:.2f})")
    print(f"    grossAssets: ${gross:.4f}")
    print(f"    totalSupply: {supply:.4f}")

    if total > 1:
        h_pct = hype_value / total * 100
        t_pct = token_value / total * 100
        u_pct = usdc_value / total * 100
        print(f"    Allocation: HYPE={h_pct:.1f}% {name}={t_pct:.1f}% USDC={u_pct:.1f}%")
        print(f"    Target:     HYPE=48.0%  {name}=48.0%  USDC=4.0%")
        ok = abs(h_pct - 48) < 10 and abs(t_pct - 48) < 10
        status = "BALANCED" if ok else "DRIFT"
        print(f"    Status: {status}")
    else:
        print(f"    Total: ${total:.2f} (insufficient)")

# Fills summary
print(f"\n{'='*60}")
print("  TRADE FILLS")
print(f"{'='*60}")
for name, cfg in VAULTS.items():
    addr = cfg["address"]
    fills = httpx.post(f"{HL_API}/info", json={"type": "userFills", "user": addr}).json()
    print(f"\n  {name} ({len(fills)} fills):")
    for f in fills:
        print(f"    {f['coin']} {f['side']} {f['sz']}@{f['px']}")
