#!/usr/bin/env python3
"""
E2E Rebalance Test Script
=========================
1. Query vault state & Core balances BEFORE rebalance
2. Execute a full rebalance cycle (if drift detected)
3. Query vault state & Core balances AFTER rebalance
4. Compare and report results
"""

import asyncio
import sys
import os
import time

# Ensure we can import from the keeper package
sys.path.insert(0, os.path.dirname(__file__))

import structlog

structlog.configure(
    processors=[
        structlog.processors.TimeStamper(fmt="iso"),
        structlog.processors.add_log_level,
        structlog.dev.ConsoleRenderer(),
    ]
)
log = structlog.get_logger()

from config import REBALANCE_CYCLE_DEADLINE_BLOCKS, DB_PATH
from persistence import KeeperState
from core_reader import CoreReader
from vault_manager import VaultManager
from rebalancer import Rebalancer, HYPE_WEI_DECIMALS
from price_checker import PriceChecker


def print_separator(title):
    print(f"\n{'='*60}")
    print(f"  {title}")
    print(f"{'='*60}\n")


def print_balances(label, balances, vault_config):
    """Pretty-print vault balances."""
    print(f"--- {label} ---")
    print(f"  HYPE on Core:  {balances['hype_core_human']:.6f}  (${balances['hype_usdc']:.2f})")
    print(f"  TOKEN on Core: {balances['token_core_human']:.6f}  (${balances['token_usdc']:.2f})")
    print(f"  USDC on Core:  {balances['usdc_core_human']:.6f}  (${balances['usdc_usdc']:.2f})")
    print(f"  TOTAL USD:     ${balances['total_usdc']:.2f}")
    print()
    total = balances['total_usdc']
    if total > 0:
        hype_pct = balances['hype_usdc'] / total * 100
        token_pct = balances['token_usdc'] / total * 100
        usdc_pct = balances['usdc_usdc'] / total * 100
        print(f"  Allocation: HYPE={hype_pct:.1f}% | TOKEN={token_pct:.1f}% | USDC={usdc_pct:.1f}%")
        print(f"  Target:     HYPE=48.0%   | TOKEN=48.0%   | USDC=4.0%")
        max_dev = max(abs(hype_pct - 48), abs(token_pct - 48), abs(usdc_pct - 4))
        print(f"  Max deviation: {max_dev:.1f}%")
    print()


async def fetch_balances(reader, vm, vault_address):
    """Fetch vault balances from Core + EVM (same logic as main.py)."""
    vault_config_addr = vault_address
    core_balances = await reader.get_spot_balances(vault_address)
    vault_config = vm.get_vault_config(vault_address, reader)

    hype_idx = vault_config["hype_token_index"]
    token_idx = vault_config["counterpart_token_index"]
    usdc_idx = vault_config["usdc_token_index"]
    hype_sz_dec = vault_config["hype_sz_decimals"]
    token_sz_dec = vault_config["counterpart_sz_decimals"]

    # Parse balances from API response
    token_balances = {}
    for balance in core_balances.get("balances", []):
        idx = balance.get("token")
        token_balances[idx] = float(balance.get("total", "0"))

    hype_core_human = token_balances.get(hype_idx, 0.0)
    token_core_human = token_balances.get(token_idx, 0.0)
    usdc_core_human = token_balances.get(usdc_idx, 0.0)

    # Include EVM HYPE balance (native balance minus reserved)
    evm_balance_wei = vm.w3.eth.get_balance(vault_config_addr)
    reserved_hype = vm.get_reserved_hype(vault_config_addr)
    evm_hype_available = max(0, evm_balance_wei - reserved_hype)
    evm_hype_human = evm_hype_available / 1e18
    total_hype_human = hype_core_human + evm_hype_human

    # Get spot prices from order book
    hype_pair = vault_config.get("hype_pair_name", "")
    hype_spot = await reader.get_mid_price(hype_pair) if hype_pair else 0.0
    pair_name = vault_config.get("pair_name", "")
    token_spot = await reader.get_mid_price(pair_name) if pair_name else 0.0

    # Get oracle prices — testnet uses @-prefixed pair names in allMids
    all_mids = await reader.get_all_mids()
    hype_oracle = float(all_mids.get(hype_pair, all_mids.get("HYPE", 0)))
    token_oracle = float(all_mids.get(pair_name, 0))
    if token_oracle == 0:
        token_base = pair_name.split("/")[0] if "/" in pair_name else pair_name
        token_oracle = float(all_mids.get(token_base, 0))

    # Use conservative prices
    checker = PriceChecker(reader)
    hype_price = checker.get_conservative_price(hype_spot, hype_oracle)
    token_price = checker.get_conservative_price(token_spot, token_oracle)

    # Use precompile spot prices for order building (contract validates against these)
    try:
        hype_px_raw = vm.get_precompile_spot_price(vault_config["hype_spot_market_index"])
        token_px_raw = vm.get_precompile_spot_price(vault_config["counterpart_spot_market_index"])
    except Exception:
        hype_px_raw = int(hype_price * 10 ** (8 - hype_sz_dec)) if hype_price > 0 else 0
        token_px_raw = int(token_price * 10 ** (8 - token_sz_dec)) if token_price > 0 else 0

    # Compute USD values (total HYPE includes EVM balance)
    hype_usdc = total_hype_human * hype_price
    token_usdc = token_core_human * token_price
    usdc_usdc = usdc_core_human
    total_usdc = hype_usdc + token_usdc + usdc_usdc

    return {
        "hype_usdc": hype_usdc,
        "token_usdc": token_usdc,
        "usdc_usdc": usdc_usdc,
        "total_usdc": total_usdc,
        "hype_price": hype_price,
        "token_price": token_price,
        "hype_price_raw": hype_px_raw,
        "token_price_raw": token_px_raw,
        "hype_core_human": total_hype_human,
        "token_core_human": token_core_human,
        "usdc_core_human": usdc_core_human,
        "evm_hype_human": evm_hype_human,
    }


async def run_e2e_test():
    print_separator("HLVault E2E Rebalance Test")

    # ─── Init ───
    state = KeeperState(DB_PATH)
    reader = CoreReader()
    vm = VaultManager()
    price = PriceChecker(reader)
    rebalancer = Rebalancer(vm, reader, price, state)

    await reader.refresh_spot_meta()

    # ─── Discover vaults ───
    vaults = vm.get_all_vault_addresses()
    print(f"Factory: {vm.factory.address}")
    print(f"Vaults discovered: {len(vaults)}")
    for i, v in enumerate(vaults):
        print(f"  [{i}] {v}")

    if not vaults:
        print("\nERROR: No vaults found. Exiting.")
        return

    vault_addr = vaults[0]
    vault_config = vm.get_vault_config(vault_addr, reader)

    print_separator("Vault Configuration")
    print(f"  Vault address:       {vault_addr}")
    print(f"  HYPE token index:    {vault_config['hype_token_index']}")
    print(f"  HYPE spot market:    {vault_config['hype_spot_market_index']}")
    print(f"  TOKEN index:         {vault_config['counterpart_token_index']}")
    print(f"  TOKEN spot market:   {vault_config['counterpart_spot_market_index']}")
    print(f"  TOKEN pair name:     {vault_config.get('pair_name', 'N/A')}")
    print(f"  TOKEN szDecimals:    {vault_config['counterpart_sz_decimals']}")
    print(f"  TOKEN weiDecimals:   {vault_config['counterpart_wei_decimals']}")
    print(f"  TOKEN evmDecimals:   {vault_config['counterpart_evm_decimals']}")
    print(f"  Slippage BPS:        {vault_config['slippage_bps']}")

    # ─── Vault on-chain state ───
    print_separator("Vault On-Chain State")
    phase = vm.get_phase(vault_addr)
    phase_names = ["IDLE", "BRIDGING_IN", "AWAITING_BRIDGE_IN", "TRADING",
                   "AWAITING_TRADES", "BRIDGING_OUT", "AWAITING_BRIDGE_OUT", "FINALIZING"]
    phase_name = phase_names[phase] if phase < len(phase_names) else f"UNKNOWN({phase})"
    print(f"  Phase:               {phase_name} ({phase})")

    is_emergency = vm.is_emergency(vault_addr)
    print(f"  Emergency mode:      {is_emergency}")

    gross_assets = vm.get_gross_assets(vault_addr)
    print(f"  Gross assets:        {gross_assets} (USDC 8dec) = ${gross_assets / 1e8:.2f}")

    share_price = vm.get_share_price(vault_addr)
    print(f"  Share price:         {share_price} (scaled 1e18) = ${share_price / 1e18:.6f}")

    l1_block = vm.get_l1_block(vault_addr)
    print(f"  L1 block number:     {l1_block}")

    escrowed = vm.get_escrowed_shares(vault_addr)
    print(f"  Escrowed shares:     {escrowed}")

    reserved_hype = vm.get_reserved_hype(vault_addr)
    print(f"  Reserved HYPE:       {reserved_hype}")

    processing = vm.get_processing_batch_count(vault_addr)
    print(f"  Processing batches:  {processing}")

    current_batch = vm.get_current_batch_id(vault_addr)
    print(f"  Current batch ID:    {current_batch}")

    # EVM balance
    evm_balance = vm.w3.eth.get_balance(vault_addr)
    print(f"  EVM HYPE balance:    {evm_balance} wei = {evm_balance / 1e18:.6f} HYPE")

    # ─── Check market conditions ───
    print_separator("Market Conditions")
    hype_pair = vault_config.get("hype_pair_name", "")
    if hype_pair:
        hype_market = await price.check_market_conditions(hype_pair, gross_assets / 1e8)
        print(f"  {hype_pair} spread:    {hype_market['spread']:.3f}%")
        print(f"  {hype_pair} depth bid: ${hype_market['depth_bid']:.0f}")
        print(f"  {hype_pair} depth ask: ${hype_market['depth_ask']:.0f}")
        print(f"  HYPE market safe:    {hype_market['safe']}")
    else:
        print("  HYPE pair: not resolved")

    pair_name = vault_config.get("pair_name")
    if pair_name:
        token_market = await price.check_market_conditions(pair_name, gross_assets / 1e8)
        print(f"  {pair_name} spread:    {token_market['spread']:.3f}%")
        print(f"  {pair_name} depth bid: ${token_market['depth_bid']:.0f}")
        print(f"  {pair_name} depth ask: ${token_market['depth_ask']:.0f}")
        print(f"  TOKEN market safe:   {token_market['safe']}")
    else:
        print("  TOKEN pair: not resolved")

    print("\n  NOTE: Market safety checks are informational only for this E2E test.")
    print("  On testnet, spreads are often very wide — we proceed regardless.")

    # ─── Core balances BEFORE ───
    print_separator("STEP 1: Balances BEFORE Rebalance")
    balances_before = await fetch_balances(reader, vm, vault_addr)
    if balances_before["total_usdc"] == 0:
        print("  WARNING: Total USD value is $0. Vault may be empty or prices unavailable.")
        print("  Prices: HYPE=${:.2f}, TOKEN=${:.2f}".format(
            balances_before["hype_price"], balances_before["token_price"]))
        print("\n  Cannot proceed with rebalance on empty vault.")
        return

    print(f"  Prices: HYPE=${balances_before['hype_price']:.4f}, TOKEN=${balances_before['token_price']:.6f}")
    print_balances("BEFORE", balances_before, vault_config)

    # ─── Check if rebalance needed ───
    should_rebalance = rebalancer.should_rebalance(vault_addr, balances_before)
    print(f"  Rebalance needed: {should_rebalance}")

    if phase != 0:
        print(f"\n  ERROR: Vault not IDLE (phase={phase_name}). Cannot start rebalance.")
        print("  You may need to abort the current cycle first.")
        return

    if is_emergency:
        print("\n  ERROR: Vault in emergency mode. Cannot rebalance.")
        return

    if processing > 0:
        print(f"\n  WARNING: {processing} batch(es) processing. Cannot rebalance.")
        return

    if not should_rebalance:
        print("\n  Vault is balanced within threshold (3%). No rebalance needed.")
        print("  Test PASSED: Vault is operational and properly balanced.")
        return

    # ─── Compute plan ───
    print_separator("STEP 2: Computing Rebalance Plan")
    token_wei_dec = vault_config["counterpart_wei_decimals"]
    plan = rebalancer.compute_plan(
        balances_before,
        balances_before["hype_price"],
        balances_before["token_price"],
        token_wei_dec,
    )

    if plan is None:
        print("  Rebalance plan returned None (delta below min notional $50).")
        print("  Test PASSED: Vault operational, rebalance too small.")
        return

    print(f"  HYPE delta:  {plan['hype_delta_wei']} core-wei  (${plan['hype_delta_usdc']:.2f})")
    print(f"  TOKEN delta: {plan['token_delta_wei']} core-wei  (${plan['token_delta_usdc']:.2f})")
    print(f"  USDC delta:  {plan['usdc_delta_wei']} core-wei")

    # ─── Build orders ───
    print_separator("STEP 3: Building Orders")
    hype_spot_idx = vault_config["hype_spot_market_index"]
    token_spot_idx = vault_config["counterpart_spot_market_index"]
    hype_px_raw = balances_before["hype_price_raw"]
    token_px_raw = balances_before["token_price_raw"]
    hype_sz_dec = vault_config["hype_sz_decimals"]
    token_sz_dec = vault_config["counterpart_sz_decimals"]
    slippage_bps = vault_config.get("slippage_bps")

    orders = rebalancer.build_orders(
        plan, hype_spot_idx, token_spot_idx,
        hype_px_raw, token_px_raw,
        hype_sz_dec, token_sz_dec,
        token_wei_dec,
        slippage_bps=slippage_bps,
    )

    if not orders:
        print("  No orders built (all below min notional $10).")
        print("  Test PASSED: Vault operational, orders too small.")
        return

    # Filter out orders for markets with extreme spreads (>20%)
    hype_spot_idx = vault_config["hype_spot_market_index"]
    token_spot_idx = vault_config["counterpart_spot_market_index"]
    filtered_orders = []
    for order in orders:
        asset, is_buy, px, sz = order
        market_idx = asset - 10000
        pair_for_order = vault_config.get("pair_name", "") if market_idx == token_spot_idx else (vault_config.get("hype_pair_name", ""))
        if pair_for_order:
            book = await reader.get_l2_book(pair_for_order)
            spread = reader.compute_spread(book)
            if spread > 20:
                side = "BUY" if is_buy else "SELL"
                print(f"  SKIPPING Order: asset={asset} {side} px={px} sz={sz}")
                print(f"    Reason: {pair_for_order} spread={spread:.1f}% (>20%, too wide for testnet)")
                continue
        filtered_orders.append(order)

    orders = filtered_orders

    if not orders:
        print("\n  All orders filtered out due to extreme testnet spreads.")
        print("  Test will proceed with empty orders to validate the cycle mechanism.")

    for i, (asset, is_buy, px, sz) in enumerate(orders):
        side = "BUY" if is_buy else "SELL"
        print(f"  Order [{i}]: asset={asset} {side} px={px} sz={sz}")

    # ─── Execute full cycle ───
    print_separator("STEP 4: Executing Full Rebalance Cycle")
    print("  Starting cycle...")
    l1_block = vm.get_l1_block(vault_addr)
    deadline = l1_block + REBALANCE_CYCLE_DEADLINE_BLOCKS

    start_time = time.time()
    try:
        await rebalancer.execute_cycle(vault_addr, plan, orders, deadline, vault_config)
        elapsed = time.time() - start_time
        print(f"\n  Cycle completed in {elapsed:.1f}s")
    except Exception as e:
        elapsed = time.time() - start_time
        print(f"\n  ERROR: Cycle failed after {elapsed:.1f}s: {e}")
        # Check phase after failure
        phase_after = vm.get_phase(vault_addr)
        phase_name_after = phase_names[phase_after] if phase_after < len(phase_names) else f"UNKNOWN({phase_after})"
        print(f"  Vault phase after failure: {phase_name_after}")
        return

    # ─── Verify post-rebalance state ───
    print_separator("STEP 5: Balances AFTER Rebalance")

    # Wait a moment for Core state to settle
    await asyncio.sleep(2)
    await reader.refresh_spot_meta()

    balances_after = await fetch_balances(reader, vm, vault_addr)
    print(f"  Prices: HYPE=${balances_after['hype_price']:.4f}, TOKEN=${balances_after['token_price']:.6f}")
    print_balances("AFTER", balances_after, vault_config)

    # ─── Post-rebalance on-chain state ───
    print_separator("STEP 6: Post-Rebalance On-Chain Verification")
    phase_after = vm.get_phase(vault_addr)
    phase_name_after = phase_names[phase_after] if phase_after < len(phase_names) else f"UNKNOWN({phase_after})"
    print(f"  Phase:               {phase_name_after} ({phase_after})")
    print(f"  Gross assets:        ${vm.get_gross_assets(vault_addr) / 1e8:.2f}")
    print(f"  Share price:         ${vm.get_share_price(vault_addr) / 1e18:.6f}")
    print(f"  L1 block number:     {vm.get_l1_block(vault_addr)}")
    evm_after = vm.w3.eth.get_balance(vault_addr)
    print(f"  EVM HYPE balance:    {evm_after / 1e18:.6f} HYPE")

    # ─── Comparison ───
    print_separator("STEP 7: Before/After Comparison")
    print(f"  {'Token':<10} {'Before USD':>12} {'After USD':>12} {'Delta':>12}")
    print(f"  {'-'*10} {'-'*12} {'-'*12} {'-'*12}")

    for token, key_usdc in [("HYPE", "hype_usdc"), ("TOKEN", "token_usdc"), ("USDC", "usdc_usdc")]:
        before_val = balances_before[key_usdc]
        after_val = balances_after[key_usdc]
        delta_val = after_val - before_val
        print(f"  {token:<10} ${before_val:>11.2f} ${after_val:>11.2f} ${delta_val:>+11.2f}")

    total_before = balances_before["total_usdc"]
    total_after = balances_after["total_usdc"]
    print(f"  {'TOTAL':<10} ${total_before:>11.2f} ${total_after:>11.2f} ${total_after - total_before:>+11.2f}")

    # ─── Allocation check ───
    print()
    if total_after > 0:
        hype_pct = balances_after['hype_usdc'] / total_after * 100
        token_pct = balances_after['token_usdc'] / total_after * 100
        usdc_pct = balances_after['usdc_usdc'] / total_after * 100
        max_dev = max(abs(hype_pct - 48), abs(token_pct - 48), abs(usdc_pct - 4))

        print(f"  Final allocation: HYPE={hype_pct:.1f}% | TOKEN={token_pct:.1f}% | USDC={usdc_pct:.1f}%")
        print(f"  Max deviation from target: {max_dev:.1f}%")

        if max_dev <= 3:
            print("\n  ✓ REBALANCE SUCCESSFUL — Vault is within 3% threshold")
        else:
            print(f"\n  ⚠ Vault still deviates by {max_dev:.1f}% (threshold=3%)")
            print("    This may be due to order book slippage or partial fills.")

    # Final phase check
    if phase_after == 0:
        print("  ✓ Vault returned to IDLE state")
    else:
        print(f"  ⚠ Vault NOT idle, phase={phase_name_after}")

    print_separator("Test Complete")


if __name__ == "__main__":
    asyncio.run(run_e2e_test())
