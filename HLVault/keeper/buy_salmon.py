#!/usr/bin/env python3
"""
Run a rebalance cycle to buy SALMON with the USDC the vault now has.
"""

import json
import time
import httpx
from web3 import Web3
from eth_account import Account
from eth_abi import encode as abi_encode, decode as abi_decode

RPC_URL = "https://hyperliquid-testnet.core.chainstack.com/98107cd968ac1c4168c442fa6b1fe200/evm"
HL_API = "https://api.hyperliquid-testnet.xyz"
KEEPER_KEY = "0xe4ae2778178f38d157ed6894bc601da12742b93785a061bdd15889b33b750934"
VAULT_ADDR = "0x79BB593507d1C5b10a5001C866076115d818Ec0E"
SPOT_PRICE_PRECOMPILE = "0x0000000000000000000000000000000000000808"

SALMON_SZ_DECIMALS = 5
SALMON_SPOT_MARKET_INDEX = 1417
HYPE_SZ_DECIMALS = 2
HYPE_SPOT_MARKET_INDEX = 1035

w3 = Web3(Web3.HTTPProvider(RPC_URL))
account = Account.from_key(KEEPER_KEY)
KEEPER_ADDR = account.address

with open("/Users/morganmagalhaes/Documents/Codage/Statera/HLVault/keeper/abi/RebalancingVault.json") as f:
    vault_abi = json.load(f)["abi"]

vault = w3.eth.contract(address=Web3.to_checksum_address(VAULT_ADDR), abi=vault_abi)
nonce = w3.eth.get_transaction_count(KEEPER_ADDR)

def send_tx(tx, label="tx"):
    global nonce
    tx["nonce"] = nonce
    tx["gas"] = tx.get("gas", 500_000)
    tx.pop("maxFeePerGas", None)
    tx.pop("maxPriorityFeePerGas", None)
    tx.pop("type", None)
    tx["gasPrice"] = w3.to_wei(1, "gwei")
    tx["chainId"] = w3.eth.chain_id
    for attempt in range(3):
        try:
            signed = account.sign_transaction(tx)
            tx_hash = w3.eth.send_raw_transaction(signed.raw_transaction)
            print(f"  {label}: {tx_hash.hex()}")
            break
        except Exception as e:
            if "nonce too low" in str(e):
                nonce = w3.eth.get_transaction_count(KEEPER_ADDR)
                tx["nonce"] = nonce
                continue
            raise
    for attempt in range(5):
        try:
            receipt = w3.eth.wait_for_transaction_receipt(tx_hash, timeout=60)
            break
        except Exception as e:
            if attempt < 4:
                print(f"  Receipt retry: {e}")
                time.sleep(5)
            else:
                raise
    nonce += 1
    if receipt["status"] != 1:
        print(f"  !! {label} REVERTED gas={receipt['gasUsed']}")
        raise RuntimeError(f"{label} reverted")
    print(f"  {label}: OK block={receipt['blockNumber']} gas={receipt['gasUsed']}")
    return receipt

def get_l1_block():
    return vault.functions.getL1BlockNumber().call()

def wait_l1():
    start = get_l1_block()
    print(f"  Waiting L1 > {start}...")
    for _ in range(60):
        time.sleep(2)
        cur = get_l1_block()
        if cur > start:
            print(f"  L1: {start} -> {cur}")
            return
    raise TimeoutError("L1 timeout")

def format_tick_up(price_int, sz_dec):
    gran = 10 ** sz_dec
    price_int = ((price_int + gran - 1) // gran) * gran
    if price_int == 0: return 0
    s = str(price_int)
    if len(s) <= 5: return price_int
    factor = 10 ** (len(s) - 5)
    return ((price_int + factor - 1) // factor) * factor

# ── Check state ──
phase_val = vault.functions.currentCycle().call()[1]
print(f"Phase: {phase_val}")

if phase_val != 0:
    print("Aborting existing cycle...")
    tx = vault.functions.abortCycle().build_transaction({"from": KEEPER_ADDR, "gas": 200_000})
    send_tx(tx, "abortCycle")
    time.sleep(2)

# ── Check vault balances ──
vault_core = httpx.post(HL_API + "/info", json={"type": "spotClearinghouseState", "user": VAULT_ADDR}, timeout=10).json()
print("Current Core balances:")
for b in vault_core.get("balances", []):
    print(f"  {b.get('coin')}: {b.get('total')}")

# ── Start rebalance ──
print("\n--- startRebalance ---")
l1 = get_l1_block()
deadline = l1 + 500
tx = vault.functions.startRebalance(0, 0, 0, deadline).build_transaction({"from": KEEPER_ADDR, "gas": 300_000})
send_tx(tx, "startRebalance")

# ── Bridge in (nothing to bridge) ──
print("\n--- executeBridgeIn(0) ---")
tx = vault.functions.executeBridgeIn(0).build_transaction({"from": KEEPER_ADDR, "gas": 200_000})
send_tx(tx, "executeBridgeIn")

print("\n--- Wait + confirmBridgeIn ---")
wait_l1()
tx = vault.functions.confirmBridgeIn().build_transaction({"from": KEEPER_ADDR, "gas": 200_000})
send_tx(tx, "confirmBridgeIn")

# ── Build SALMON buy order ──
print("\n--- Build SALMON buy order ---")

# Get precompile price
salmon_px_data = w3.eth.call({"to": Web3.to_checksum_address(SPOT_PRICE_PRECOMPILE),
                               "data": abi_encode(["uint32"], [SALMON_SPOT_MARKET_INDEX])})
salmon_precompile_px = abi_decode(["uint64"], salmon_px_data)[0]
print(f"SALMON precompile: {salmon_precompile_px} (${salmon_precompile_px/1e3:.2f})")

# Get book
salmon_book = httpx.post(HL_API + "/info", json={"type": "l2Book", "coin": f"@{SALMON_SPOT_MARKET_INDEX}"}, timeout=10).json()
levels = salmon_book.get("levels", [[], []])
asks = levels[1] if len(levels) > 1 else []
best_ask = float(asks[0]["px"]) if asks else 0
best_ask_sz = float(asks[0]["sz"]) if asks else 0
print(f"SALMON best ask: ${best_ask} sz={best_ask_sz}")

# Get vault USDC
vault_usdc = 0
vault_core2 = httpx.post(HL_API + "/info", json={"type": "spotClearinghouseState", "user": VAULT_ADDR}, timeout=10).json()
for b in vault_core2.get("balances", []):
    if b.get("coin") == "USDC":
        vault_usdc = float(b["total"])
print(f"Vault USDC on Core: {vault_usdc}")

if vault_usdc > 10 and best_ask > 0:
    # Buy SALMON with available USDC
    salmon_to_buy = (vault_usdc / best_ask) * 0.95  # 95% of max to be safe
    salmon_sz_human = int(salmon_to_buy * 100000) / 100000.0
    salmon_sz_1e8 = (int(salmon_sz_human * 1e8) // 1000) * 1000

    # Price: precompile * 1.14 (within 15% slippage)
    salmon_buy_px = int(salmon_precompile_px * 1.14)
    salmon_buy_px = format_tick_up(salmon_buy_px, SALMON_SZ_DECIMALS)

    slippage_ceil = salmon_precompile_px * 11500 // 10000
    print(f"Buy: sz={salmon_sz_1e8/1e8} px={salmon_buy_px} (${salmon_buy_px/1e3:.2f}) ceil={slippage_ceil}")

    notional = salmon_sz_1e8 * salmon_buy_px
    print(f"Notional: {notional} (min 1e12={notional >= 1e12})")

    orders = [(10000 + SALMON_SPOT_MARKET_INDEX, True, salmon_buy_px, salmon_sz_1e8)]

    core_px = salmon_buy_px * (10 ** SALMON_SZ_DECIMALS)
    print(f"CoreWriter px: {core_px} = ${core_px/1e8:.2f}")
else:
    print(f"Not enough USDC ({vault_usdc}) or no ask")
    orders = []

print(f"Orders: {orders}")

# ── executeTrades ──
print("\n--- executeTrades ---")
tx = vault.functions.executeTrades(orders).build_transaction({"from": KEEPER_ADDR, "gas": 1_000_000})
send_tx(tx, "executeTrades")

# ── Confirm + finalize ──
print("\n--- Wait + confirmTrades ---")
wait_l1()
tx = vault.functions.confirmTrades().build_transaction({"from": KEEPER_ADDR, "gas": 200_000})
send_tx(tx, "confirmTrades")

print("\n--- skipBridgeOut ---")
tx = vault.functions.skipBridgeOut().build_transaction({"from": KEEPER_ADDR, "gas": 200_000})
send_tx(tx, "skipBridgeOut")

print("\n--- finalizeCycle ---")
tx = vault.functions.finalizeCycle().build_transaction({"from": KEEPER_ADDR, "gas": 200_000})
send_tx(tx, "finalizeCycle")

# ── Final verification ──
print("\n=== FINAL VERIFICATION ===")
time.sleep(3)

vault_core_final = httpx.post(HL_API + "/info", json={"type": "spotClearinghouseState", "user": VAULT_ADDR}, timeout=10).json()
print("Vault Core balances:")
for b in vault_core_final.get("balances", []):
    print(f"  {b.get('coin')}: total={b.get('total')}, hold={b.get('hold')}")

fills = httpx.post(HL_API + "/info", json={"type": "userFills", "user": VAULT_ADDR}, timeout=10).json()
print(f"\nAll fills ({len(fills)}):")
for f in fills[:20]:
    print(f"  {f.get('coin','?')} {f.get('side','?')} {f.get('sz','?')} @ {f.get('px','?')}")

try:
    price = vault.functions.sharePriceUsdc8().call()
    print(f"\nShare price: {price / 1e8:.6f} USDC")
    gross = vault.functions.grossAssets().call()
    print(f"Gross assets: {gross / 1e8:.2f} USDC")
    supply = vault.functions.totalSupply().call()
    print(f"Total supply: {supply / 1e18:.6f} shares")
except Exception as e:
    print(f"Error reading vault state: {e}")

print("\n=== DONE ===")
