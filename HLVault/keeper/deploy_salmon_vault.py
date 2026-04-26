#!/usr/bin/env python3
"""
Deploy a SALMON vault via the factory, activate its Core account,
deposit HYPE, and run a full rebalance cycle to buy SALMON.

Network: testnet
"""

import json
import time
import httpx
from web3 import Web3
from eth_account import Account
from eth_abi import encode as abi_encode, decode as abi_decode

# ── Config ──────────────────────────────────────────────────────────
RPC_URL = "https://hyperliquid-testnet.core.chainstack.com/98107cd968ac1c4168c442fa6b1fe200/evm"
HL_API = "https://api.hyperliquid-testnet.xyz"
KEEPER_KEY = "0xe4ae2778178f38d157ed6894bc601da12742b93785a061bdd15889b33b750934"
FACTORY_ADDR = "0x851489d96D561C1c149cC32e8bb5Bb149e2061D0"
CORE_WRITER = "0x3333333333333333333333333333333333333333"
CORE_USER_EXISTS = "0x0000000000000000000000000000000000000810"
L1_BLOCK_PRECOMPILE = "0x000000000000000000000000000000000000080B"

# SALMON token info (testnet)
SALMON_TOKEN_INDEX = 1544
SALMON_SZ_DECIMALS = 5
SALMON_WEI_DECIMALS = 10
SALMON_SPOT_MARKET_INDEX = 1417
SALMON_BRIDGE_ADDR = "0x2000000000000000000000000000000000000608"
# SALMON has no EVM ERC20 contract. We use a stub that returns 0 for balanceOf.
# The vault's grossAssets() calls IERC20(counterpartToken).balanceOf() which would
# revert on a non-contract address. The stub avoids this.
SALMON_STUB_ERC20 = "0x94500Af4DD8494CecC11F3678fEF16030DACD098"

# HYPE info (testnet)
HYPE_TOKEN_INDEX = 1105
HYPE_SZ_DECIMALS = 2
HYPE_WEI_DECIMALS = 8
HYPE_SPOT_MARKET_INDEX = 1035

USDC_TOKEN_INDEX = 0

# ── Web3 setup ──────────────────────────────────────────────────────
w3 = Web3(Web3.HTTPProvider(RPC_URL))
assert w3.is_connected(), "Cannot connect to RPC"
print(f"Connected to chain {w3.eth.chain_id}")

account = Account.from_key(KEEPER_KEY)
KEEPER_ADDR = account.address
print(f"Keeper address: {KEEPER_ADDR}")

# ── Load ABIs ───────────────────────────────────────────────────────
with open("/Users/morganmagalhaes/Documents/Codage/Statera/HLVault/keeper/abi/VaultFactory.json") as f:
    factory_abi = json.load(f)["abi"]
with open("/Users/morganmagalhaes/Documents/Codage/Statera/HLVault/keeper/abi/RebalancingVault.json") as f:
    vault_abi = json.load(f)["abi"]

factory = w3.eth.contract(address=Web3.to_checksum_address(FACTORY_ADDR), abi=factory_abi)

CORE_WRITER_ABI = [{"inputs":[{"name":"action","type":"bytes"}],"name":"sendRawAction","outputs":[],"stateMutability":"nonpayable","type":"function"}]
core_writer = w3.eth.contract(address=Web3.to_checksum_address(CORE_WRITER), abi=CORE_WRITER_ABI)

# ── Helpers ─────────────────────────────────────────────────────────
nonce = w3.eth.get_transaction_count(KEEPER_ADDR)

def send_tx(tx, label="tx"):
    global nonce
    tx["nonce"] = nonce
    tx["gas"] = tx.get("gas", 500_000)
    # Remove EIP-1559 fields if present and use legacy gasPrice
    tx.pop("maxFeePerGas", None)
    tx.pop("maxPriorityFeePerGas", None)
    tx.pop("type", None)
    tx["gasPrice"] = w3.to_wei(1, "gwei")
    tx["chainId"] = w3.eth.chain_id
    signed = account.sign_transaction(tx)
    tx_hash = w3.eth.send_raw_transaction(signed.raw_transaction)
    print(f"  {label}: {tx_hash.hex()}")
    # Retry receipt fetching in case of transient RPC errors
    receipt = None
    for attempt in range(5):
        try:
            receipt = w3.eth.wait_for_transaction_receipt(tx_hash, timeout=60)
            break
        except Exception as e:
            if attempt < 4:
                print(f"  Receipt fetch failed ({e}), retrying in 5s...")
                time.sleep(5)
            else:
                raise
    nonce += 1  # nonce consumed even if reverted
    if receipt["status"] != 1:
        print(f"  !! {label} REVERTED (status=0)")
        raise RuntimeError(f"{label} reverted")
    print(f"  {label}: confirmed block={receipt['blockNumber']} gas={receipt['gasUsed']}")
    return receipt

def get_l1_block():
    """Get L1 block number via the vault's getL1BlockNumber() function."""
    return vault.functions.getL1BlockNumber().call()

def wait_l1_advance(label="L1"):
    start = get_l1_block()
    print(f"  Waiting for L1 to advance past {start}...")
    for _ in range(60):
        time.sleep(2)
        cur = get_l1_block()
        if cur > start:
            print(f"  L1 advanced: {start} -> {cur}")
            return cur
    raise TimeoutError(f"L1 did not advance past {start} within 120s")

def format_tick_down(price_int, sz_dec):
    """Format tick price rounding DOWN (for sell orders)."""
    gran = 10 ** sz_dec
    price_int = (price_int // gran) * gran
    if price_int == 0:
        return 0
    s = str(price_int)
    if len(s) <= 5:
        return price_int
    factor = 10 ** (len(s) - 5)
    return (price_int // factor) * factor

def format_tick_up(price_int, sz_dec):
    """Format tick price rounding UP (for buy orders)."""
    gran = 10 ** sz_dec
    price_int = ((price_int + gran - 1) // gran) * gran
    if price_int == 0:
        return 0
    s = str(price_int)
    if len(s) <= 5:
        return price_int
    factor = 10 ** (len(s) - 5)
    return ((price_int + factor - 1) // factor) * factor

def get_all_mids():
    resp = httpx.post(HL_API + "/info", json={"type": "allMids"}, timeout=10)
    resp.raise_for_status()
    return resp.json()

def get_spot_clearinghouse(user_addr):
    resp = httpx.post(HL_API + "/info", json={"type": "spotClearinghouseState", "user": user_addr}, timeout=10)
    resp.raise_for_status()
    return resp.json()

# ── Step 1: Create SALMON vault ─────────────────────────────────────
print("\n=== STEP 1: Create SALMON vault ===")

salmon_stub = Web3.to_checksum_address(SALMON_STUB_ERC20)

# Check if vault already exists for the stub address
existing = factory.functions.vaults(salmon_stub).call()
if existing != "0x0000000000000000000000000000000000000000":
    print(f"Vault already exists at {existing}")
    vault_addr = existing
else:
    tx = factory.functions.createVault(
        salmon_stub,            # counterpartToken (stub ERC20 for balanceOf)
        SALMON_TOKEN_INDEX,     # counterpartTokenIndex
        SALMON_SPOT_MARKET_INDEX,  # counterpartSpotMarketIndex
        HYPE_TOKEN_INDEX,       # hypeTokenIndex
        HYPE_SPOT_MARKET_INDEX, # hypeSpotMarketIndex
        USDC_TOKEN_INDEX,       # usdcTokenIndex
        SALMON_SZ_DECIMALS,     # counterpartSzDecimals
        SALMON_WEI_DECIMALS,    # counterpartWeiDecimals
        SALMON_WEI_DECIMALS,    # counterpartEvmDecimals (use weiDecimals as fallback)
        100 * 10**18,           # maxSingleDeposit (100 HYPE)
        "Statera SALMON",       # name
        "stSALMON",             # symbol
    ).build_transaction({"from": KEEPER_ADDR, "gas": 5_000_000})
    receipt = send_tx(tx, "createVault")
    vault_addr = factory.functions.vaults(salmon_stub).call()
    print(f"Vault created at: {vault_addr}")

vault = w3.eth.contract(address=Web3.to_checksum_address(vault_addr), abi=vault_abi)
print(f"Vault address: {vault_addr}")

# ── Step 2: Configure vault ─────────────────────────────────────────
print("\n=== STEP 2: Configure vault ===")

current_slippage = vault.functions.slippageBps().call()
print(f"Current slippage: {current_slippage} bps")
if current_slippage != 1500:
    tx = vault.functions.setSlippage(1500).build_transaction({"from": KEEPER_ADDR})
    send_tx(tx, "setSlippage(1500)")
else:
    print("Slippage already 1500 bps")

current_max = vault.functions.maxSingleDepositHype18().call()
print(f"Current maxSingleDeposit: {current_max}")
if current_max != 100 * 10**18:
    tx = vault.functions.setMaxSingleDeposit(100 * 10**18).build_transaction({"from": KEEPER_ADDR})
    send_tx(tx, "setMaxSingleDeposit")
else:
    print("maxSingleDeposit already 100 HYPE")

# Enable deposits if not enabled
deposits_enabled = vault.functions.depositsEnabled().call()
print(f"Deposits enabled: {deposits_enabled}")
if not deposits_enabled:
    tx = vault.functions.setDepositsEnabled(True).build_transaction({"from": KEEPER_ADDR})
    send_tx(tx, "setDepositsEnabled(true)")

# ── Step 3: Activate Core account ────────────────────────────────────
print("\n=== STEP 3: Activate Core account ===")

# Check if already active
core_exists_result = w3.eth.call({
    "to": Web3.to_checksum_address(CORE_USER_EXISTS),
    "data": abi_encode(["address"], [vault_addr]).hex(),
})
core_exists = int.from_bytes(core_exists_result, "big")
print(f"Core user exists: {core_exists}")

if core_exists == 0:
    # Check keeper's Core USDC balance
    keeper_state = get_spot_clearinghouse(KEEPER_ADDR)
    print(f"Keeper Core state: {json.dumps(keeper_state, indent=2)[:500]}")

    keeper_usdc = 0
    if "balances" in keeper_state:
        for b in keeper_state["balances"]:
            if b.get("coin") == "USDC":
                keeper_usdc = float(b.get("total", "0"))
    print(f"Keeper Core USDC: {keeper_usdc}")

    if keeper_usdc >= 2.0:
        # Send 1 USDC to vault via spotSend (Action 6)
        send_amount = 100_000_000  # 1 USDC in 8 dec
        action_params = abi_encode(
            ["address", "uint32", "uint64"],
            [vault_addr, USDC_TOKEN_INDEX, send_amount]
        )
        action = bytes([0x01]) + (6).to_bytes(3, "big") + action_params
        tx = core_writer.functions.sendRawAction(action).build_transaction({"from": KEEPER_ADDR})
        send_tx(tx, "spotSend (activate Core)")
        time.sleep(5)
        core_exists_result = w3.eth.call({
            "to": Web3.to_checksum_address(CORE_USER_EXISTS),
            "data": abi_encode(["address"], [vault_addr]).hex(),
        })
        core_exists = int.from_bytes(core_exists_result, "big")
        print(f"Core user exists after activation: {core_exists}")
    else:
        print(f"!! Keeper has insufficient USDC ({keeper_usdc}) for activation (need >= 2 USDC).")
        print("   BRIDGED HYPE WILL BE IN evmEscrows (unusable) until account is activated.")
        print("   Proceeding with rebalance anyway -- trades will be silently rejected on Core.")
else:
    print("Core account already active")

# ── Step 4: Deposit HYPE ────────────────────────────────────────────
print("\n=== STEP 4: Deposit HYPE ===")

keeper_balance = w3.eth.get_balance(KEEPER_ADDR)
print(f"Keeper EVM HYPE balance: {keeper_balance / 1e18:.4f} HYPE")

vault_evm_balance_pre = w3.eth.get_balance(vault_addr)
print(f"Vault already has {vault_evm_balance_pre / 1e18:.6f} HYPE on EVM")

deposit_amount = 500_000_000_000_000_000  # 0.5 HYPE
gas_reserve = w3.to_wei(0.01, "ether")  # keep 0.01 HYPE for gas

if vault_evm_balance_pre > 0:
    print("Vault already funded, checking if additional deposit needed...")
    if keeper_balance > deposit_amount + gas_reserve:
        tx = vault.functions.deposit().build_transaction({"from": KEEPER_ADDR, "value": deposit_amount, "gas": 500_000})
        send_tx(tx, f"deposit({deposit_amount/1e18:.4f} HYPE)")
    elif keeper_balance > gas_reserve + w3.to_wei(0.01, "ether"):
        deposit_amount = keeper_balance - gas_reserve
        print(f"  Depositing remaining: {deposit_amount/1e18:.6f} HYPE")
        tx = vault.functions.deposit().build_transaction({"from": KEEPER_ADDR, "value": deposit_amount, "gas": 500_000})
        send_tx(tx, f"deposit({deposit_amount/1e18:.6f} HYPE)")
    else:
        print("  Not enough HYPE for additional deposit, proceeding with existing balance")
else:
    if keeper_balance < deposit_amount + gas_reserve:
        deposit_amount = keeper_balance - gas_reserve
        if deposit_amount <= 0:
            raise RuntimeError("Not enough HYPE to deposit")
        print(f"  Adjusted deposit to {deposit_amount/1e18:.6f} HYPE")
    tx = vault.functions.deposit().build_transaction({"from": KEEPER_ADDR, "value": deposit_amount, "gas": 500_000})
    send_tx(tx, f"deposit({deposit_amount/1e18:.6f} HYPE)")

vault_evm_balance = w3.eth.get_balance(vault_addr)
print(f"Vault EVM balance after deposit: {vault_evm_balance / 1e18:.6f} HYPE")

# ── Step 5: Full rebalance cycle ────────────────────────────────────
print("\n=== STEP 5: Full rebalance cycle ===")

# Check current phase first
current_phase = vault.functions.currentCycle().call()
phase_val = current_phase[1]
print(f"Current phase: {phase_val} (0=IDLE, 1=BRIDGING_IN, 2=AWAIT_BRIDGE_IN, 3=TRADING, ...)")

if phase_val != 0:
    print("Cycle in progress, aborting first...")
    tx = vault.functions.abortCycle().build_transaction({"from": KEEPER_ADDR})
    send_tx(tx, "abortCycle")
    time.sleep(3)  # wait for state to settle

# 5a. startRebalance
print("\n--- 5a: startRebalance ---")
l1_block = get_l1_block()
deadline = l1_block + 300
print(f"L1 block: {l1_block}, deadline: {deadline}")

tx = vault.functions.startRebalance(0, 0, 0, deadline).build_transaction({"from": KEEPER_ADDR, "gas": 300_000})
send_tx(tx, "startRebalance")

# 5b. executeBridgeIn
print("\n--- 5b: executeBridgeIn ---")
vault_evm_balance = w3.eth.get_balance(vault_addr)
# Round down to nearest 1e10 for clean EVM->Core conversion (18 dec -> 8 dec)
bridge_amount = (vault_evm_balance // 10**10) * 10**10
print(f"Vault EVM balance: {vault_evm_balance} wei")
print(f"Bridging {bridge_amount / 1e18:.8f} HYPE to Core (rounded)")

tx = vault.functions.executeBridgeIn(bridge_amount).build_transaction({"from": KEEPER_ADDR, "gas": 200_000})
send_tx(tx, "executeBridgeIn")

# 5c. Wait for L1 block to advance
print("\n--- 5c: Wait for L1 ---")
wait_l1_advance("bridge_in")

# 5d. confirmBridgeIn
print("\n--- 5d: confirmBridgeIn ---")
tx = vault.functions.confirmBridgeIn().build_transaction({"from": KEEPER_ADDR})
send_tx(tx, "confirmBridgeIn")

# 5e. Build trade orders
print("\n--- 5e: Build trade orders ---")

# Get prices
mids = get_all_mids()
hype_key = f"@{HYPE_SPOT_MARKET_INDEX}"
salmon_key = f"@{SALMON_SPOT_MARKET_INDEX}"
hype_mid = float(mids.get(hype_key, "0"))
salmon_mid = float(mids.get(salmon_key, "0"))
print(f"HYPE mid price: ${hype_mid}")
print(f"SALMON mid price: ${salmon_mid}")

if hype_mid == 0 or salmon_mid == 0:
    print("!! Could not get prices. Checking all keys with @...")
    for k, v in sorted(mids.items()):
        if k.startswith("@"):
            print(f"  {k}: {v}")
    # Try to proceed anyway or abort
    if hype_mid == 0:
        raise RuntimeError("Cannot get HYPE price")

# Get vault Core balances
vault_core = get_spot_clearinghouse(vault_addr)
print(f"Vault Core state: {json.dumps(vault_core, indent=2)[:800]}")

vault_hype_core = 0
if "balances" in vault_core:
    for b in vault_core["balances"]:
        if b.get("coin") == "HYPE":
            vault_hype_core = float(b.get("total", "0"))
print(f"Vault HYPE on Core: {vault_hype_core} HYPE")

if vault_hype_core <= 0:
    print("!! No HYPE on Core. Core account may not be activated or bridge pending.")
    print("   Sending empty executeTrades to advance state machine...")
    orders = []
else:
    # Sell ~48% of HYPE to buy SALMON (to meet min notional)
    hype_to_sell = vault_hype_core * 0.48

    # ─── HYPE sell order ───
    # Round down to szDecimals=2 (granularity 0.01)
    hype_sz_human = int(hype_to_sell * 100) / 100.0
    hype_sz_1e8 = int(hype_sz_human * 1e8)
    # Round down to granularity 1e6 (1e8 / 10^szDec = 1e8/1e2 = 1e6)
    hype_sz_1e8 = (hype_sz_1e8 // 1_000_000) * 1_000_000

    # Get precompile prices to compute slippage-safe limits
    from eth_abi import decode as abi_decode_local
    SPOT_PRICE_PRECOMPILE = "0x0000000000000000000000000000000000000808"
    hype_px_data = w3.eth.call({
        "to": Web3.to_checksum_address(SPOT_PRICE_PRECOMPILE),
        "data": abi_encode(["uint32"], [HYPE_SPOT_MARKET_INDEX]),
    })
    hype_precompile_px = abi_decode_local(["uint64"], hype_px_data)[0]
    print(f"HYPE precompile price: {hype_precompile_px} (${hype_precompile_px/1e6:.2f})")

    # Sell at the slippage floor (precompile * 0.85) to match the best bid
    hype_sell_px_precompile = int(hype_precompile_px * (10000 - 1500) // 10000)
    hype_sell_px_precompile = format_tick_down(hype_sell_px_precompile, HYPE_SZ_DECIMALS)

    print(f"HYPE sell: sz={hype_sz_1e8/1e8} @ precompile_px={hype_sell_px_precompile} (${hype_sell_px_precompile/1e6:.2f})")

    # ─── SALMON buy order ───
    usd_for_salmon = hype_sz_human * hype_mid
    salmon_to_buy = usd_for_salmon / salmon_mid
    # Round down to szDecimals=5 (granularity 0.00001)
    salmon_sz_human = int(salmon_to_buy * 100000) / 100000.0
    salmon_sz_1e8 = int(salmon_sz_human * 1e8)
    # Round down to granularity 1e3 (1e8 / 10^szDec = 1e8/1e5 = 1e3)
    salmon_sz_1e8 = (salmon_sz_1e8 // 1_000) * 1_000

    # Get SALMON precompile price
    salmon_px_data = w3.eth.call({
        "to": Web3.to_checksum_address(SPOT_PRICE_PRECOMPILE),
        "data": abi_encode(["uint32"], [SALMON_SPOT_MARKET_INDEX]),
    })
    salmon_precompile_px = abi_decode_local(["uint64"], salmon_px_data)[0]
    print(f"SALMON precompile price: {salmon_precompile_px} (${salmon_precompile_px/1e3:.2f})")

    # Buy price: precompile * 1.14 (just below the 15% ceiling)
    salmon_buy_px_precompile = int(salmon_precompile_px * 1.14)
    salmon_buy_px_precompile = format_tick_up(salmon_buy_px_precompile, SALMON_SZ_DECIMALS)

    print(f"SALMON buy: sz={salmon_sz_1e8/1e8} @ precompile_px={salmon_buy_px_precompile} (${salmon_buy_px_precompile/1e3:.2f})")

    # Min notional checks
    # HYPE: sz * limitPx >= 1e9 * 10^(8-2) = 1e9 * 1e6 = 1e15
    hype_notional = hype_sz_1e8 * hype_sell_px_precompile
    print(f"HYPE notional check: {hype_notional} >= {1e15} -> {'OK' if hype_notional >= 1e15 else 'FAIL'}")

    # SALMON: sz * limitPx >= 1e9 * 10^(8-5) = 1e9 * 1e3 = 1e12
    salmon_notional = salmon_sz_1e8 * salmon_buy_px_precompile
    print(f"SALMON notional check: {salmon_notional} >= {1e12} -> {'OK' if salmon_notional >= 1e12 else 'FAIL'}")

    orders = []

    # Only add orders that meet min notional
    if hype_notional >= 1e15 and hype_sz_1e8 > 0:
        orders.append((
            10000 + HYPE_SPOT_MARKET_INDEX,  # asset = 11035
            False,                            # isBuy = false (sell)
            hype_sell_px_precompile,          # limitPx (precompile format)
            hype_sz_1e8,                      # sz (1e8 format)
        ))
    else:
        print("!! HYPE sell order does not meet min notional, skipping")

    # NOTE: Submit SALMON buy in the same batch. Core processes orders sequentially,
    # so the HYPE sell proceeds (USDC) should be available for the SALMON buy.
    if salmon_notional >= 1e12 and salmon_sz_1e8 > 0 and salmon_mid > 0:
        orders.append((
            10000 + SALMON_SPOT_MARKET_INDEX,  # asset = 11417
            True,                               # isBuy = true (buy)
            salmon_buy_px_precompile,           # limitPx (precompile format)
            salmon_sz_1e8,                      # sz (1e8 format)
        ))
    else:
        print("!! SALMON buy order does not meet min notional, skipping")

    print(f"\nOrder details for verification:")
    for i, o in enumerate(orders):
        asset, is_buy, px, sz = o
        sz_dec = HYPE_SZ_DECIMALS if asset == 10000 + HYPE_SPOT_MARKET_INDEX else SALMON_SZ_DECIMALS
        core_px = px * (10 ** sz_dec)
        human_px = core_px / 1e8
        human_sz = sz / 1e8
        print(f"  Order {i}: asset={asset} {'BUY' if is_buy else 'SELL'} px_precompile={px} core_px={core_px} human_px=${human_px:.2f} sz={sz} human_sz={human_sz}")

print(f"Orders to submit: {orders}")

# 5f. executeTrades
print("\n--- 5f: executeTrades ---")
tx = vault.functions.executeTrades(orders).build_transaction({"from": KEEPER_ADDR, "gas": 1_000_000})
send_tx(tx, "executeTrades")

# 5g. Wait for L1 + confirmTrades
print("\n--- 5g: Wait for L1 + confirmTrades ---")
wait_l1_advance("trades")

tx = vault.functions.confirmTrades().build_transaction({"from": KEEPER_ADDR})
send_tx(tx, "confirmTrades")

# 5h. executeBridgeOut / skipBridgeOut
print("\n--- 5h: Bridge out ---")
current_phase = vault.functions.currentCycle().call()[1]
if current_phase == 5:  # BRIDGING_OUT
    try:
        tx = vault.functions.skipBridgeOut().build_transaction({"from": KEEPER_ADDR, "gas": 200_000})
        send_tx(tx, "skipBridgeOut")
    except Exception as e:
        print(f"  skipBridgeOut failed: {e}, trying executeBridgeOut(0)...")
        tx = vault.functions.executeBridgeOut(0).build_transaction({"from": KEEPER_ADDR, "gas": 200_000})
        send_tx(tx, "executeBridgeOut(0)")
        wait_l1_advance("bridge_out")
        tx = vault.functions.confirmBridgeOut().build_transaction({"from": KEEPER_ADDR, "gas": 200_000})
        send_tx(tx, "confirmBridgeOut")
elif current_phase == 7:  # FINALIZING
    print("Already in FINALIZING phase")
else:
    print(f"  Unexpected phase: {current_phase}")

# 5j. finalizeCycle
print("\n--- 5j: finalizeCycle ---")
current_phase = vault.functions.currentCycle().call()[1]
if current_phase == 7:  # FINALIZING
    tx = vault.functions.finalizeCycle().build_transaction({"from": KEEPER_ADDR, "gas": 200_000})
    send_tx(tx, "finalizeCycle")
elif current_phase == 0:
    print("Already IDLE")
else:
    print(f"  Unexpected phase: {current_phase}, cannot finalize")

# ── Step 6: Verify ──────────────────────────────────────────────────
print("\n=== STEP 6: Verify ===")
time.sleep(3)

vault_core_final = get_spot_clearinghouse(vault_addr)
print(f"Vault Core balances:")
if "balances" in vault_core_final:
    for b in vault_core_final["balances"]:
        print(f"  {b.get('coin', '?')}: total={b.get('total', '0')}, hold={b.get('hold', '0')}")
else:
    print(f"  Raw response: {json.dumps(vault_core_final, indent=2)[:500]}")

vault_evm_final = w3.eth.get_balance(vault_addr)
print(f"Vault EVM HYPE: {vault_evm_final / 1e18:.6f}")

share_price = vault.functions.sharePriceUsdc8().call()
print(f"Share price (USDC 8 dec): {share_price} ({share_price / 1e8:.6f} USDC)")

total_supply = vault.functions.totalSupply().call()
print(f"Total shares: {total_supply / 1e18:.6f}")

gross_assets = vault.functions.grossAssets().call()
print(f"Gross assets (USDC 8 dec): {gross_assets} ({gross_assets / 1e8:.2f} USDC)")

phase = vault.functions.currentCycle().call()
print(f"Current cycle: {phase}")

print("\n=== DONE ===")
