#!/usr/bin/env python3
"""
Continue the SALMON vault rebalance cycle from current phase.
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

SALMON_TOKEN_INDEX = 1544
SALMON_SZ_DECIMALS = 5
SALMON_WEI_DECIMALS = 10
SALMON_SPOT_MARKET_INDEX = 1417
HYPE_TOKEN_INDEX = 1105
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
                print(f"  Receipt retry {attempt+1}: {e}")
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

def wait_l1_advance(label="L1"):
    start = get_l1_block()
    print(f"  Waiting L1 > {start}...")
    for _ in range(60):
        time.sleep(2)
        cur = get_l1_block()
        if cur > start:
            print(f"  L1: {start} -> {cur}")
            return cur
    raise TimeoutError("L1 timeout")

def format_tick_down(price_int, sz_dec):
    gran = 10 ** sz_dec
    price_int = (price_int // gran) * gran
    if price_int == 0: return 0
    s = str(price_int)
    if len(s) <= 5: return price_int
    factor = 10 ** (len(s) - 5)
    return (price_int // factor) * factor

def format_tick_up(price_int, sz_dec):
    gran = 10 ** sz_dec
    price_int = ((price_int + gran - 1) // gran) * gran
    if price_int == 0: return 0
    s = str(price_int)
    if len(s) <= 5: return price_int
    factor = 10 ** (len(s) - 5)
    return ((price_int + factor - 1) // factor) * factor

# ── Check current phase and continue ──
phase = vault.functions.currentCycle().call()
phase_val = phase[1]
PHASES = {0:"IDLE", 1:"BRIDGING_IN", 2:"AWAIT_BRIDGE_IN", 3:"TRADING",
          4:"AWAIT_TRADES", 5:"BRIDGING_OUT", 6:"AWAIT_BRIDGE_OUT", 7:"FINALIZING"}
print(f"Current phase: {phase_val} ({PHASES.get(phase_val, '?')})")
print(f"Cycle: {phase}")

# Phase 1: BRIDGING_IN -- execute bridge
if phase_val == 1:
    print("\n--- executeBridgeIn ---")
    vault_bal = w3.eth.get_balance(VAULT_ADDR)
    bridge_amt = (vault_bal // 10**10) * 10**10
    print(f"Vault EVM: {vault_bal} wei, bridging: {bridge_amt}")
    tx = vault.functions.executeBridgeIn(bridge_amt).build_transaction({"from": KEEPER_ADDR, "gas": 200_000})
    send_tx(tx, "executeBridgeIn")
    phase_val = 2

if phase_val == 2:
    print("\n--- Wait L1 + confirmBridgeIn ---")
    wait_l1_advance()
    tx = vault.functions.confirmBridgeIn().build_transaction({"from": KEEPER_ADDR, "gas": 200_000})
    send_tx(tx, "confirmBridgeIn")
    phase_val = 3

if phase_val == 3:
    print("\n--- executeTrades ---")
    # Get precompile prices
    hype_px_data = w3.eth.call({"to": Web3.to_checksum_address(SPOT_PRICE_PRECOMPILE),
                                 "data": abi_encode(["uint32"], [HYPE_SPOT_MARKET_INDEX])})
    hype_precompile_px = abi_decode(["uint64"], hype_px_data)[0]

    salmon_px_data = w3.eth.call({"to": Web3.to_checksum_address(SPOT_PRICE_PRECOMPILE),
                                   "data": abi_encode(["uint32"], [SALMON_SPOT_MARKET_INDEX])})
    salmon_precompile_px = abi_decode(["uint64"], salmon_px_data)[0]

    print(f"HYPE precompile: {hype_precompile_px} (${hype_precompile_px/1e6:.2f})")
    print(f"SALMON precompile: {salmon_precompile_px} (${salmon_precompile_px/1e3:.2f})")

    # Get market mids
    mids = httpx.post(HL_API + "/info", json={"type": "allMids"}, timeout=10).json()
    hype_mid = float(mids.get(f"@{HYPE_SPOT_MARKET_INDEX}", "0"))
    salmon_mid = float(mids.get(f"@{SALMON_SPOT_MARKET_INDEX}", "0"))
    print(f"HYPE mid: ${hype_mid}, SALMON mid: ${salmon_mid}")

    # Get vault Core HYPE balance
    vault_core = httpx.post(HL_API + "/info", json={"type": "spotClearinghouseState", "user": VAULT_ADDR}, timeout=10).json()
    vault_hype = 0
    for b in vault_core.get("balances", []):
        if b.get("coin") == "HYPE":
            vault_hype = float(b["total"])
    print(f"Vault HYPE on Core: {vault_hype}")

    # Get orderbook to determine actual fill prices
    hype_book = httpx.post(HL_API + "/info", json={"type": "l2Book", "coin": f"@{HYPE_SPOT_MARKET_INDEX}"}, timeout=10).json()
    salmon_book = httpx.post(HL_API + "/info", json={"type": "l2Book", "coin": f"@{SALMON_SPOT_MARKET_INDEX}"}, timeout=10).json()

    hype_bids = hype_book.get("levels", [[], []])[0]
    salmon_asks = hype_book.get("levels", [[], []])[1] if len(hype_book.get("levels", [])) > 1 else []
    salmon_book_asks = salmon_book.get("levels", [[], []])[1] if len(salmon_book.get("levels", [])) > 1 else []

    hype_best_bid = float(hype_bids[0]["px"]) if hype_bids else 0
    salmon_best_ask = float(salmon_book_asks[0]["px"]) if salmon_book_asks else 0
    print(f"HYPE best bid: ${hype_best_bid}")
    print(f"SALMON best ask: ${salmon_best_ask}")

    orders = []

    if vault_hype > 0:
        # Sell 48% of HYPE
        hype_to_sell = vault_hype * 0.48
        hype_sz_human = int(hype_to_sell * 100) / 100.0
        hype_sz_1e8 = (int(hype_sz_human * 1e8) // 1_000_000) * 1_000_000

        # Price: slippage floor (precompile * 0.85) -- this matches best bid on testnet
        hype_sell_px = int(hype_precompile_px * 8500 // 10000)
        hype_sell_px = format_tick_down(hype_sell_px, HYPE_SZ_DECIMALS)

        # Verify slippage check will pass
        slippage_floor = hype_precompile_px * 8500 // 10000
        print(f"HYPE sell: sz={hype_sz_1e8/1e8} px={hype_sell_px} (${hype_sell_px/1e6:.2f}) floor={slippage_floor}")

        hype_notional = hype_sz_1e8 * hype_sell_px
        print(f"HYPE notional: {hype_notional} (min 1e15={hype_notional >= 1e15})")

        if hype_notional >= 1e15 and hype_sz_1e8 > 0 and hype_sell_px >= slippage_floor:
            orders.append((10000 + HYPE_SPOT_MARKET_INDEX, False, hype_sell_px, hype_sz_1e8))

            # Expected USDC from sell
            expected_usdc = hype_sz_human * hype_best_bid if hype_best_bid else hype_sz_human * hype_sell_px / 1e6
            print(f"Expected USDC from sell: ~${expected_usdc:.2f}")

            # SALMON buy with expected USDC
            if salmon_best_ask > 0 and expected_usdc > 10:
                salmon_to_buy = expected_usdc / salmon_best_ask * 0.9  # 90% to be safe
                salmon_sz_human = int(salmon_to_buy * 100000) / 100000.0
                salmon_sz_1e8 = (int(salmon_sz_human * 1e8) // 1_000) * 1_000

                # Price: just above best ask, within slippage cap
                salmon_buy_px = int(salmon_precompile_px * 1.14)
                salmon_buy_px = format_tick_up(salmon_buy_px, SALMON_SZ_DECIMALS)

                # Verify slippage
                slippage_ceil = salmon_precompile_px * 11500 // 10000
                print(f"SALMON buy: sz={salmon_sz_1e8/1e8} px={salmon_buy_px} (${salmon_buy_px/1e3:.2f}) ceil={slippage_ceil}")

                salmon_notional = salmon_sz_1e8 * salmon_buy_px
                print(f"SALMON notional: {salmon_notional} (min 1e12={salmon_notional >= 1e12})")

                if salmon_notional >= 1e12 and salmon_sz_1e8 > 0 and salmon_buy_px <= slippage_ceil:
                    orders.append((10000 + SALMON_SPOT_MARKET_INDEX, True, salmon_buy_px, salmon_sz_1e8))
                else:
                    print("  SALMON order failed checks")
        else:
            print("  HYPE sell order failed checks")

    print(f"\nSubmitting {len(orders)} orders: {orders}")

    # Show Core order details
    for i, o in enumerate(orders):
        asset, is_buy, px, sz = o
        sz_dec = HYPE_SZ_DECIMALS if asset == 10000 + HYPE_SPOT_MARKET_INDEX else SALMON_SZ_DECIMALS
        core_px = px * (10 ** sz_dec)
        print(f"  Order {i}: asset={asset} {'BUY' if is_buy else 'SELL'} precompile_px={px} core_px={core_px} sz={sz}")

    tx = vault.functions.executeTrades(orders).build_transaction({"from": KEEPER_ADDR, "gas": 1_000_000})
    send_tx(tx, "executeTrades")
    phase_val = 4

if phase_val == 4:
    print("\n--- Wait L1 + confirmTrades ---")
    wait_l1_advance()
    tx = vault.functions.confirmTrades().build_transaction({"from": KEEPER_ADDR, "gas": 200_000})
    send_tx(tx, "confirmTrades")
    phase_val = 5

if phase_val == 5:
    print("\n--- skipBridgeOut ---")
    tx = vault.functions.skipBridgeOut().build_transaction({"from": KEEPER_ADDR, "gas": 200_000})
    send_tx(tx, "skipBridgeOut")
    phase_val = 7

if phase_val == 7:
    print("\n--- finalizeCycle ---")
    tx = vault.functions.finalizeCycle().build_transaction({"from": KEEPER_ADDR, "gas": 200_000})
    send_tx(tx, "finalizeCycle")
    phase_val = 0

# ── Verify ──
print("\n=== VERIFY ===")
time.sleep(3)

vault_core = httpx.post(HL_API + "/info", json={"type": "spotClearinghouseState", "user": VAULT_ADDR}, timeout=10).json()
print("Vault Core balances:")
for b in vault_core.get("balances", []):
    print(f"  {b.get('coin')}: total={b.get('total')}, hold={b.get('hold')}")

fills = httpx.post(HL_API + "/info", json={"type": "userFills", "user": VAULT_ADDR}, timeout=10).json()
print(f"\nFills ({len(fills)} total):")
for f in fills[:10]:
    print(f"  {f.get('coin','?')} {f.get('side','?')} {f.get('sz','?')} @ {f.get('px','?')} (time={f.get('time','')})")

vault_evm = w3.eth.get_balance(VAULT_ADDR)
print(f"\nVault EVM HYPE: {vault_evm / 1e18:.6f}")

try:
    price = vault.functions.sharePriceUsdc8().call()
    print(f"Share price: {price / 1e8:.6f} USDC")
except:
    print("Could not get share price")

print("\n=== DONE ===")
