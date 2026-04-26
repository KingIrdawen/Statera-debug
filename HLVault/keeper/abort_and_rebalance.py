#!/usr/bin/env python3
"""
Abort stuck rebalance cycles on PURR and UETH vaults, then run fresh rebalances
to buy counterpart tokens.
"""
import json
import time
import math
import httpx
from pathlib import Path
from web3 import Web3
from eth_account import Account

# ──────────────── Config ────────────────
RPC = "https://hyperliquid-testnet.core.chainstack.com/98107cd968ac1c4168c442fa6b1fe200/evm"
HL_API = "https://api.hyperliquid-testnet.xyz"
CHAIN_ID = 998
KEEPER_KEY = "0xe4ae2778178f38d157ed6894bc601da12742b93785a061bdd15889b33b750934"

PURR_VAULT = "0x5e59963fFB340BA164d4E892Af09F8591D494452"
UETH_VAULT = "0x594441439B80116436c642585560aafd0d3b152e"

# Known testnet token info
HYPE_TOKEN_INDEX = 1105
HYPE_SZ_DEC = 2
HYPE_WEI_DEC = 8
HYPE_SPOT_MARKET_INDEX = 1035

UETH_TOKEN_INDEX = 1242
UETH_SZ_DEC = 4
UETH_WEI_DEC = 9
UETH_SPOT_MARKET_INDEX = 1137

L1_PRECOMPILE = "0x000000000000000000000000000000000000080B"

# ──────────────── Setup ────────────────
w3 = Web3(Web3.HTTPProvider(RPC))
account = Account.from_key(KEEPER_KEY)
print(f"Keeper address: {account.address}")
print(f"Connected: {w3.is_connected()}")

# Load ABI
abi_path = Path(__file__).parent / "abi" / "RebalancingVault.json"
with open(abi_path) as f:
    data = json.load(f)
abi = data["abi"] if isinstance(data, dict) and "abi" in data else data

nonce_counter = [None]  # mutable container

def get_nonce():
    if nonce_counter[0] is None:
        nonce_counter[0] = w3.eth.get_transaction_count(account.address)
    n = nonce_counter[0]
    nonce_counter[0] += 1
    return n

def reset_nonce():
    nonce_counter[0] = w3.eth.get_transaction_count(account.address)

def send_tx(fn, value=0, gas=2_000_000):
    """Send transaction with retry and gas price bumping."""
    for attempt in range(5):
        try:
            nonce = get_nonce()
            try:
                est = fn.estimate_gas({"from": account.address, "value": value})
                gas = int(est * 1.5)
            except Exception as e:
                print(f"  Gas estimation failed ({e}), using {gas}")

            base_gas_price = w3.eth.gas_price
            # Bump gas price on each attempt to handle replacement tx
            gas_price = int(base_gas_price * (1.5 ** attempt))
            if gas_price < 1_000_000_000:  # min 1 gwei
                gas_price = 1_000_000_000

            tx = fn.build_transaction({
                "from": account.address,
                "nonce": nonce,
                "gas": gas,
                "gasPrice": gas_price,
                "chainId": CHAIN_ID,
                "value": value,
            })
            signed = account.sign_transaction(tx)
            tx_hash = w3.eth.send_raw_transaction(signed.raw_transaction)
            receipt = w3.eth.wait_for_transaction_receipt(tx_hash, timeout=120)
            status = receipt["status"]
            print(f"  TX {tx_hash.hex()[:16]}... status={status}")
            if status != 1:
                raise RuntimeError(f"Transaction reverted: {tx_hash.hex()}")
            return receipt
        except Exception as e:
            print(f"  Attempt {attempt+1} failed: {e}")
            err = str(e).lower()
            if "replacement transaction underpriced" in err:
                # Same nonce, need higher gas - don't increment nonce
                nonce_counter[0] -= 1  # reuse same nonce
                time.sleep(2)
                continue
            if "nonce too low" in err or "already known" in err:
                # Transaction was already mined, reset nonce
                reset_nonce()
                time.sleep(2)
                continue
            reset_nonce()
            if attempt == 4:
                raise
            time.sleep(2)

def get_vault(addr):
    return w3.eth.contract(address=Web3.to_checksum_address(addr), abi=abi)

def get_l1_block(vault_addr=None):
    """Get L1 block number via a vault's getL1BlockNumber() function."""
    if vault_addr is None:
        vault_addr = UETH_VAULT  # fallback to any vault
    vault = get_vault(vault_addr)
    return vault.functions.getL1BlockNumber().call()

def wait_l1_advance(vault_addr=None, ref_block=None, max_wait=60):
    if ref_block is None:
        ref_block = get_l1_block(vault_addr)
    print(f"  Waiting for L1 block > {ref_block}...")
    start = time.time()
    while time.time() - start < max_wait:
        current = get_l1_block(vault_addr)
        if current > ref_block:
            print(f"  L1 advanced to {current}")
            return current
        time.sleep(2)
    raise TimeoutError(f"L1 block did not advance past {ref_block} within {max_wait}s")

def get_phase(vault_addr):
    vault = get_vault(vault_addr)
    cycle = vault.functions.currentCycle().call()
    # cycle is a tuple: (cycleId, phase, startedAtL1Block, lastActionL1Block, deadline, ...)
    phase_names = ["IDLE", "BRIDGING_IN", "AWAITING_BRIDGE_IN", "TRADING", "AWAITING_TRADES",
                   "BRIDGING_OUT", "AWAITING_BRIDGE_OUT", "FINALIZING"]
    phase_idx = cycle[1]
    return phase_idx, phase_names[phase_idx] if phase_idx < len(phase_names) else f"UNKNOWN({phase_idx})"

# ──────────────── Price utilities ────────────────

def format_tick_price(raw_price_precompile, sz_decimals, round_up=False):
    """
    Format price in precompile format (human * 10^(8-szDec)) to valid tick.
    Max 5 sig figs, granularity = 10^szDecimals (in 1e8 space, but price is in precompile space).

    Wait — the price is ALREADY in precompile format. The granularity in precompile format is 1
    (since precompile = 1e8 / 10^szDec, granularity in 1e8 is 10^szDec, so in precompile it's 1).

    Actually let me re-think. The contract checks:
      PriceLib.formatTickPrice(limitPx, szDecimals) == limitPx

    PriceLib.formatTickPrice operates on the raw value. It does:
      minGranularity = 10^szDecimals
      price = (rawPrice / minGranularity) * minGranularity
      price = _truncateToSigFigs(price, 5)

    But limitPx is in precompile format = human * 10^(8-szDec).
    For HYPE (szDec=2): limitPx = human * 1e6. minGranularity = 100.
    So granularity in human price terms = 100 / 1e6 = 0.0001 which is correct for 6 decimal places.

    Actually wait - formatTickPrice takes rawPriceUsdc8 which is 1e8 * human_price.
    But the contract passes limitPx which is human * 10^(8-szDec). These are NOT the same unless szDec=0.

    Let me re-read the contract code:
      _validateOrderFormat(o.limitPx, o.sz, szDecimals);

    And _validateOrderFormat calls:
      PriceLib.formatTickPrice(limitPx, szDecimals) == limitPx

    So formatTickPrice is called with the precompile-format price. Looking at PriceLib:
      minGranularity = 10^szDecimals
      price = (rawPriceUsdc8 / minGranularity) * minGranularity

    For HYPE szDec=2, limitPx = human * 1e6:
      minGranularity = 100
      So limitPx must be divisible by 100.
      human * 1e6 must be divisible by 100 → human must have at most 4 decimal places. ✓

    Then truncate to 5 sig figs on the raw value.
    """
    if raw_price_precompile <= 0:
        return 0

    granularity = 10 ** sz_decimals

    # Round to granularity
    if round_up:
        price = ((raw_price_precompile + granularity - 1) // granularity) * granularity
    else:
        price = (raw_price_precompile // granularity) * granularity

    # Truncate to 5 sig figs
    price = truncate_to_sig_figs(price, 5, round_up)

    # Ensure still on granularity after sig fig truncation
    if round_up:
        price = ((price + granularity - 1) // granularity) * granularity
        # Re-truncate (might add a digit)
        price = truncate_to_sig_figs(price, 5, round_up)
    else:
        price = (price // granularity) * granularity

    return price

def truncate_to_sig_figs(value, n_figs, round_up=False):
    if value <= 0:
        return 0
    digits = len(str(abs(value)))
    if digits <= n_figs:
        return value
    factor = 10 ** (digits - n_figs)
    if round_up:
        return ((value + factor - 1) // factor) * factor
    return (value // factor) * factor

def format_lot_size(sz_1e8, sz_decimals):
    """Round sz (in 1e8 * human format) down to szDecimals precision."""
    if sz_1e8 <= 0:
        return 0
    step = 10 ** (8 - sz_decimals)
    return (sz_1e8 // step) * step

# ──────────────── API calls ────────────────

def fetch_spot_meta():
    resp = httpx.post(f"{HL_API}/info", json={"type": "spotMeta"}, timeout=10)
    resp.raise_for_status()
    return resp.json()

def fetch_all_mids():
    resp = httpx.post(f"{HL_API}/info", json={"type": "allMids"}, timeout=10)
    resp.raise_for_status()
    return resp.json()

def fetch_spot_balances(address):
    resp = httpx.post(f"{HL_API}/info", json={"type": "spotClearinghouseState", "user": address}, timeout=10)
    resp.raise_for_status()
    return resp.json()

def print_balances(label, address):
    bals = fetch_spot_balances(address)
    print(f"\n  === {label} Core Balances ===")
    if "balances" in bals:
        for b in bals["balances"]:
            token = b.get("coin", "?")
            total = b.get("total", "0")
            hold = b.get("hold", "0")
            print(f"    {token}: total={total}, hold={hold}")
    else:
        print(f"    Raw: {bals}")

# ──────────────── MAIN ────────────────

def main():
    print("\n" + "="*60)
    print("Step 1: Resolve PURR token from spotMeta")
    print("="*60)

    meta = fetch_spot_meta()
    tokens = {t["name"]: t for t in meta.get("tokens", [])}
    universe = meta.get("universe", [])

    purr_token = tokens.get("PURR")
    if purr_token:
        purr_token_index = purr_token["index"]
        purr_sz_dec = purr_token.get("szDecimals", 0)
        purr_wei_dec = purr_token.get("weiDecimals", 5)
        print(f"  PURR: tokenIndex={purr_token_index}, szDecimals={purr_sz_dec}, weiDecimals={purr_wei_dec}")
    else:
        print("  PURR not found in tokens, searching...")
        for t in meta.get("tokens", []):
            print(f"    {t['name']}: index={t['index']}")
        # Try to find it
        purr_token_index = None

    # Find PURR spot market index from universe
    purr_spot_market_index = None
    for pair in universe:
        name = pair.get("name", "")
        tokens_list = pair.get("tokens", [])
        if "PURR" in name.upper():
            purr_spot_market_index = pair.get("index")
            print(f"  PURR pair: name={name}, index={purr_spot_market_index}, tokens={tokens_list}")
            break

    if purr_spot_market_index is None:
        print("  PURR pair not found in universe, listing all pairs...")
        for pair in universe[:20]:
            print(f"    {pair.get('name')}: index={pair.get('index')}")

    # Also confirm UETH
    ueth_token = tokens.get("UETH")
    if ueth_token:
        print(f"  UETH: tokenIndex={ueth_token['index']}, szDecimals={ueth_token.get('szDecimals')}, weiDecimals={ueth_token.get('weiDecimals')}")

    print("\n" + "="*60)
    print("Step 2: Check current vault states")
    print("="*60)

    for name, addr in [("PURR", PURR_VAULT), ("UETH", UETH_VAULT)]:
        phase_idx, phase_name = get_phase(addr)
        vault = get_vault(addr)
        cycle = vault.functions.currentCycle().call()
        evm_bal = w3.eth.get_balance(Web3.to_checksum_address(addr))
        print(f"  {name} vault ({addr}): phase={phase_name} (idx={phase_idx}), cycleId={cycle[0]}, EVM balance={evm_bal / 1e18:.6f} HYPE")
        print_balances(name, addr)

    print("\n" + "="*60)
    print("Step 3: Abort stuck cycles")
    print("="*60)

    for name, addr in [("PURR", PURR_VAULT), ("UETH", UETH_VAULT)]:
        phase_idx, phase_name = get_phase(addr)
        if phase_idx == 0:  # IDLE
            print(f"  {name}: Already IDLE, skip abort")
            continue
        print(f"  Aborting {name} cycle (phase={phase_name})...")
        vault = get_vault(addr)
        fn = vault.functions.abortCycle()
        send_tx(fn)
        phase_idx, phase_name = get_phase(addr)
        print(f"  {name} after abort: phase={phase_name}")

    print("\n" + "="*60)
    print("Step 4: Fetch spot prices from allMids")
    print("="*60)

    mids = fetch_all_mids()

    # Read vault configs to get the right market indices
    purr_vault_obj = get_vault(PURR_VAULT)
    ueth_vault_obj = get_vault(UETH_VAULT)

    purr_hype_mkt = purr_vault_obj.functions.hypeSpotMarketIndex().call()
    purr_cp_mkt = purr_vault_obj.functions.counterpartSpotMarketIndex().call()
    purr_cp_sz_dec = purr_vault_obj.functions.counterpartSzDecimals().call()

    ueth_hype_mkt = ueth_vault_obj.functions.hypeSpotMarketIndex().call()
    ueth_cp_mkt = ueth_vault_obj.functions.counterpartSpotMarketIndex().call()
    ueth_cp_sz_dec = ueth_vault_obj.functions.counterpartSzDecimals().call()

    print(f"  PURR vault: hypeSpotMkt={purr_hype_mkt}, counterpartSpotMkt={purr_cp_mkt}, counterpartSzDec={purr_cp_sz_dec}")
    print(f"  UETH vault: hypeSpotMkt={ueth_hype_mkt}, counterpartSpotMkt={ueth_cp_mkt}, counterpartSzDec={ueth_cp_sz_dec}")

    hype_mid_key = f"@{HYPE_SPOT_MARKET_INDEX}"
    hype_price_human = float(mids.get(hype_mid_key, 0))
    print(f"  HYPE spot mid ({hype_mid_key}): ${hype_price_human}")

    # For PURR — @0 may not exist in allMids, try alternatives
    purr_mid_key = f"@{purr_cp_mkt}"
    purr_price_human = float(mids.get(purr_mid_key, 0))
    if purr_price_human == 0:
        # Try PURR/USDC key
        purr_price_human = float(mids.get("PURR/USDC", 0))
        purr_mid_key = "PURR/USDC"
    if purr_price_human == 0:
        # Try L2 book
        try:
            book = httpx.post(f"{HL_API}/info", json={"type": "l2Book", "coin": "PURR/USDC"}, timeout=10).json()
            levels = book.get("levels", [[], []])
            if levels[0] and levels[1]:
                purr_price_human = (float(levels[0][0]["px"]) + float(levels[1][0]["px"])) / 2
                purr_mid_key = "PURR/USDC (L2 book)"
        except Exception:
            pass
    print(f"  PURR spot mid ({purr_mid_key}): ${purr_price_human}")

    # For UETH
    ueth_mid_key = f"@{ueth_cp_mkt}"
    ueth_price_human = float(mids.get(ueth_mid_key, 0))
    print(f"  UETH spot mid ({ueth_mid_key}): ${ueth_price_human}")

    # ──────────────── Rebalance each vault ────────────────

    vaults_config = [
        {
            "name": "PURR",
            "addr": PURR_VAULT,
            "hype_spot_mkt": purr_hype_mkt,
            "cp_spot_mkt": purr_cp_mkt,
            "cp_sz_dec": purr_cp_sz_dec,
            "hype_price": hype_price_human,
            "cp_price": purr_price_human,
            "cp_name": "PURR",
        },
        {
            "name": "UETH",
            "addr": UETH_VAULT,
            "hype_spot_mkt": ueth_hype_mkt,
            "cp_spot_mkt": ueth_cp_mkt,
            "cp_sz_dec": ueth_cp_sz_dec,
            "hype_price": hype_price_human,
            "cp_price": ueth_price_human,
            "cp_name": "UETH",
        },
    ]

    for vc in vaults_config:
        run_rebalance_cycle(vc)

    print("\n" + "="*60)
    print("FINAL: Check Core balances")
    print("="*60)

    for name, addr in [("PURR", PURR_VAULT), ("UETH", UETH_VAULT)]:
        print_balances(name, addr)


def run_rebalance_cycle(vc):
    name = vc["name"]
    addr = vc["addr"]
    vault = get_vault(addr)

    print(f"\n{'='*60}")
    print(f"REBALANCE: {name} vault ({addr})")
    print(f"{'='*60}")

    # ── Step A: startRebalance ──
    print(f"\n  [A] startRebalance(0, 0, 0, 200)")
    phase_idx, phase_name = get_phase(addr)
    if phase_idx != 0:
        print(f"  ERROR: vault not IDLE (phase={phase_name}), skipping")
        return

    fn = vault.functions.startRebalance(0, 0, 0, 200)
    send_tx(fn)
    phase_idx, phase_name = get_phase(addr)
    print(f"  After startRebalance: phase={phase_name}")

    # ── Step B: executeBridgeIn ──
    evm_balance = w3.eth.get_balance(Web3.to_checksum_address(addr))
    gas_reserve = int(0.001 * 1e18)  # 0.001 HYPE for gas
    bridge_amount = evm_balance - gas_reserve
    if bridge_amount <= 0:
        print(f"  No EVM balance to bridge (balance={evm_balance / 1e18:.6f}), bridging 0")
        bridge_amount = 0

    print(f"\n  [B] executeBridgeIn({bridge_amount}) [{bridge_amount / 1e18:.6f} HYPE]")
    fn = vault.functions.executeBridgeIn(bridge_amount)
    send_tx(fn)
    phase_idx, phase_name = get_phase(addr)
    print(f"  After executeBridgeIn: phase={phase_name}")

    # ── Step C: wait L1 and confirmBridgeIn ──
    print(f"\n  [C] Wait L1 + confirmBridgeIn")
    wait_l1_advance(addr)
    fn = vault.functions.confirmBridgeIn()
    send_tx(fn)
    phase_idx, phase_name = get_phase(addr)
    print(f"  After confirmBridgeIn: phase={phase_name}")

    # ── Step D: Build trade orders ──
    print(f"\n  [D] Build trade orders")

    hype_price = vc["hype_price"]
    cp_price = vc["cp_price"]
    cp_sz_dec = vc["cp_sz_dec"]
    hype_spot_mkt = vc["hype_spot_mkt"]
    cp_spot_mkt = vc["cp_spot_mkt"]

    # Read precompile spot prices (these are what the contract validates against)
    import eth_abi as eth_abi_mod
    precompile_addr = "0x0000000000000000000000000000000000000808"

    hype_precompile_px = int.from_bytes(
        w3.eth.call({"to": precompile_addr, "data": "0x" + eth_abi_mod.encode(["uint32"], [hype_spot_mkt]).hex()})[:32], "big"
    )
    cp_precompile_px = int.from_bytes(
        w3.eth.call({"to": precompile_addr, "data": "0x" + eth_abi_mod.encode(["uint32"], [cp_spot_mkt]).hex()})[:32], "big"
    )
    print(f"  Precompile prices: HYPE={hype_precompile_px} (${hype_precompile_px / 10**(8-HYPE_SZ_DEC):.2f}), {vc['cp_name']}={cp_precompile_px} (${cp_precompile_px / 10**(8-cp_sz_dec):.2f})")
    print(f"  allMids prices: HYPE=${hype_price:.4f}, {vc['cp_name']}=${cp_price:.4f}")

    orders = []

    hype_sell_amount_human = 0.30  # sell 0.30 HYPE

    if hype_precompile_px <= 0:
        print(f"  ERROR: HYPE precompile price is 0, cannot trade")
        print(f"\n  [E] executeTrades (empty)")
        fn = vault.functions.executeTrades([])
        send_tx(fn)
        finish_cycle(vault, addr, name)
        return

    # ── Order 1: Sell HYPE (on HYPE spot market) ──
    hype_asset = 10000 + hype_spot_mkt

    # Use precompile price as base, apply -14% slippage (stay within 15% cap)
    sell_price_precompile = int(hype_precompile_px * (10000 - 1400) / 10000)
    sell_price_tick = format_tick_price(sell_price_precompile, HYPE_SZ_DEC, round_up=False)

    hype_sz_1e8 = int(hype_sell_amount_human * 1e8)
    hype_sz_1e8 = format_lot_size(hype_sz_1e8, HYPE_SZ_DEC)

    min_notional = 10**9 * 10**(8 - HYPE_SZ_DEC)
    notional = hype_sz_1e8 * sell_price_tick
    print(f"  HYPE sell: sz={hype_sz_1e8} (human={hype_sz_1e8/1e8}), px={sell_price_tick} (precompile), notional={notional}, min={min_notional}")

    if notional >= min_notional and sell_price_tick > 0 and hype_sz_1e8 > 0:
        orders.append((hype_asset, False, sell_price_tick, hype_sz_1e8))
        print(f"  -> Added HYPE sell order")
    else:
        print(f"  -> HYPE sell order below min notional or invalid, skipping")

    # ── Order 2: Buy counterpart token ──
    if cp_precompile_px > 0 and cp_price > 0:
        cp_asset = 10000 + cp_spot_mkt

        # Use precompile price as base, apply +14% slippage (stay within 15% cap)
        buy_price_precompile = int(cp_precompile_px * (10000 + 1400) / 10000)
        buy_price_tick = format_tick_price(buy_price_precompile, cp_sz_dec, round_up=True)

        # How much counterpart to buy? Use the USDC value of HYPE we're selling
        hype_human_price = hype_precompile_px / (10 ** (8 - HYPE_SZ_DEC))
        cp_human_price = cp_precompile_px / (10 ** (8 - cp_sz_dec))
        usdc_value = hype_sell_amount_human * hype_human_price
        cp_amount_human = usdc_value / cp_human_price
        cp_sz_1e8 = int(cp_amount_human * 1e8)
        cp_sz_1e8 = format_lot_size(cp_sz_1e8, cp_sz_dec)

        cp_min_notional = 10**9 * 10**(8 - cp_sz_dec)
        cp_notional = cp_sz_1e8 * buy_price_tick
        print(f"  {vc['cp_name']} buy: sz={cp_sz_1e8} (human={cp_sz_1e8/1e8}), px={buy_price_tick} (precompile), notional={cp_notional}, min={cp_min_notional}")

        if cp_notional >= cp_min_notional and buy_price_tick > 0 and cp_sz_1e8 > 0:
            orders.append((cp_asset, True, buy_price_tick, cp_sz_1e8))
            print(f"  -> Added {vc['cp_name']} buy order")
        else:
            print(f"  -> {vc['cp_name']} buy order below min notional or invalid, skipping")
    else:
        print(f"  {vc['cp_name']} price is 0, skipping buy order")

    # ── Step E: executeTrades ──
    print(f"\n  [E] executeTrades with {len(orders)} orders")
    fn = vault.functions.executeTrades(orders)
    send_tx(fn)
    phase_idx, phase_name = get_phase(addr)
    print(f"  After executeTrades: phase={phase_name}")

    # ── Steps F-I: finish cycle ──
    finish_cycle(vault, addr, name)


def finish_cycle(vault, addr, name):
    # ── Step F: wait L1 + confirmTrades ──
    print(f"\n  [F] Wait L1 + confirmTrades")
    wait_l1_advance(addr)
    fn = vault.functions.confirmTrades()
    send_tx(fn)
    phase_idx, phase_name = get_phase(addr)
    print(f"  After confirmTrades: phase={phase_name}")

    # ── Step G: executeBridgeOut(0) — skip bridge out ──
    # Phase is BRIDGING_OUT. We can use skipBridgeOut() or executeBridgeOut(0).
    # executeBridgeOut(0) bridges 0 HYPE back, then needs confirmBridgeOut.
    # skipBridgeOut() goes directly to FINALIZING. Let's use that.
    print(f"\n  [G] skipBridgeOut")
    fn = vault.functions.skipBridgeOut()
    send_tx(fn)
    phase_idx, phase_name = get_phase(addr)
    print(f"  After skipBridgeOut: phase={phase_name}")

    # ── Step I: finalizeCycle ──
    print(f"\n  [I] finalizeCycle")
    fn = vault.functions.finalizeCycle()
    send_tx(fn)
    phase_idx, phase_name = get_phase(addr)
    print(f"  After finalizeCycle: phase={phase_name}")

    print(f"\n  {name} rebalance cycle COMPLETE!")
    print_balances(name, addr)


if __name__ == "__main__":
    main()
