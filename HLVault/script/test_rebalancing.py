"""
Test rebalancing on 3 vaults: SOVY (main test), BARK, ZIGG.
Calls advanceRebalance() repeatedly and verifies Core balances.
"""
import json
import time
import httpx
from web3 import Web3
from eth_account import Account
from pathlib import Path

RPC = "https://rpc.hyperliquid-testnet.xyz/evm"
HL_API = "https://api.hyperliquid-testnet.xyz"
PRIVATE_KEY = "0xe4ae2778178f38d157ed6894bc601da12742b93785a061bdd15889b33b750934"
CHAIN_ID = 998

VAULTS = {
    "SOVY": {
        "address": "0x660e143fDf7AF0004AD8BD555069E9A64EcF10e7",
        "tokenIndex": 1158,
        "spotMarket": 1080,
        "szDec": 1,
        "weiDec": 8,
    },
    "BARK": {
        "address": "0x09E3c1324F0c6a6E58E70c2F56A054BB92AB1824",
        "tokenIndex": 242,
        "spotMarket": 218,
        "szDec": 0,
        "weiDec": 5,
    },
    "ZIGG": {
        "address": "0xd1Bc57C42C05985921A707e7f4ad93BBF464c67a",
        "tokenIndex": 1048,
        "spotMarket": 980,
        "szDec": 2,
        "weiDec": 8,
    },
}

w3 = Web3(Web3.HTTPProvider(RPC))
account = Account.from_key(PRIVATE_KEY)

abi_path = Path(__file__).parent.parent / "keeper" / "abi" / "RebalancingVault.json"
with open(abi_path) as f:
    vault_abi = json.load(f)
if isinstance(vault_abi, dict) and "abi" in vault_abi:
    vault_abi = vault_abi["abi"]


def get_vault(address):
    return w3.eth.contract(address=Web3.to_checksum_address(address), abi=vault_abi)


def send_tx(fn):
    nonce = w3.eth.get_transaction_count(account.address)
    try:
        gas = fn.estimate_gas({"from": account.address})
        gas = int(gas * 1.5)
    except Exception:
        gas = 2_000_000
    tx = fn.build_transaction({
        "from": account.address, "nonce": nonce,
        "gas": gas, "gasPrice": w3.eth.gas_price, "chainId": CHAIN_ID,
    })
    signed = account.sign_transaction(tx)
    tx_hash = w3.eth.send_raw_transaction(signed.raw_transaction)
    receipt = w3.eth.wait_for_transaction_receipt(tx_hash, timeout=120)
    return receipt


def get_core_balances(address):
    resp = httpx.post(f"{HL_API}/info", json={
        "type": "spotClearinghouseState", "user": address
    })
    balances = {}
    for b in resp.json()["balances"]:
        if float(b["total"]) > 0:
            balances[b["coin"]] = float(b["total"])
    return balances


def get_phase(vault):
    return vault.functions.currentCycle().call()[1]


def get_l1_block(vault):
    return vault.functions.getL1BlockNumber().call()


def wait_l1(vault, current_l1, timeout=90):
    start = time.time()
    while time.time() - start < timeout:
        new_l1 = get_l1_block(vault)
        if new_l1 > current_l1:
            return new_l1
        time.sleep(2)
    raise TimeoutError(f"L1 stuck at {current_l1}")


PHASE_NAMES = {
    0: "IDLE", 1: "BRIDGING_IN", 2: "AWAITING_BRIDGE_IN",
    3: "TRADING", 4: "AWAITING_TRADES",
    5: "BRIDGING_OUT", 6: "AWAITING_BRIDGE_OUT", 7: "FINALIZING"
}


def test_vault(name, config):
    addr = config["address"]
    vault = get_vault(addr)

    print(f"\n{'='*60}")
    print(f"  {name} VAULT ({addr})")
    print(f"  tokenIndex={config['tokenIndex']}, szDec={config['szDec']}")
    print(f"{'='*60}")

    phase = get_phase(vault)
    evm_hype = w3.eth.get_balance(Web3.to_checksum_address(addr)) / 1e18
    core_bals = get_core_balances(addr)

    print(f"\nInitial: phase={PHASE_NAMES.get(phase, phase)}, EVM_HYPE={evm_hype:.6f}")
    print(f"  Core: {core_bals}")

    try:
        gross = vault.functions.grossAssets().call()
        print(f"  grossAssets: ${gross/1e8:.4f}")
    except Exception as e:
        print(f"  grossAssets error: {e}")

    if phase != 0:
        print("  Phase not IDLE, skipping")
        return "SKIP"

    # Call advanceRebalance up to 4 times
    for call_num in range(1, 5):
        print(f"\n--- advanceRebalance() call {call_num} ---")
        try:
            receipt = send_tx(vault.functions.advanceRebalance())
            gas_used = receipt["gasUsed"]
            print(f"  status={receipt['status']} gas={gas_used}")
        except Exception as e:
            err = str(e)
            if "revert" in err.lower():
                print(f"  Reverted: {err[:200]}")
                return "REVERT"
            print(f"  Error: {err[:200]}")
            return "ERROR"

        phase = get_phase(vault)
        l1 = get_l1_block(vault)
        print(f"  Phase: {PHASE_NAMES.get(phase, phase)}, L1: {l1}")

        # Check Core balances
        time.sleep(2)
        core_bals = get_core_balances(addr)
        print(f"  Core balances: {core_bals}")

        if phase == 0:
            if call_num == 1:
                print("  -> Rebalance skipped (below threshold or min notional)")
                return "SKIPPED"
            else:
                print(f"  -> Rebalance COMPLETE in {call_num} calls!")
                evm_hype = w3.eth.get_balance(Web3.to_checksum_address(addr)) / 1e18
                print(f"  Final EVM HYPE: {evm_hype:.6f}")
                try:
                    gross = vault.functions.grossAssets().call()
                    print(f"  Final grossAssets: ${gross/1e8:.4f}")
                except:
                    pass
                return "SUCCESS"

        # Wait for L1 to advance
        print(f"  Waiting for L1 > {l1}...")
        try:
            new_l1 = wait_l1(vault, l1)
            print(f"  L1 advanced to {new_l1}")
        except TimeoutError:
            print("  TIMEOUT waiting for L1")
            return "TIMEOUT"

    phase = get_phase(vault)
    print(f"\nFinal phase: {PHASE_NAMES.get(phase, phase)}")
    return "INCOMPLETE" if phase != 0 else "SUCCESS"


def main():
    print("=" * 60)
    print("  MULTI-TOKEN REBALANCING TEST")
    print("=" * 60)

    # Market info
    print("\n--- Markets ---")
    for name, c in VAULTS.items():
        resp = httpx.post(f"{HL_API}/info", json={"type": "l2Book", "coin": f"@{c['spotMarket']}"})
        book = resp.json()
        if book and "levels" in book:
            bids = book["levels"][0][:1]
            asks = book["levels"][1][:1]
            b = bids[0]["px"] if bids else "N/A"
            a = asks[0]["px"] if asks else "N/A"
            print(f"  {name} (@{c['spotMarket']}): bid={b} ask={a}")
        else:
            print(f"  {name}: NO BOOK DATA")

    resp = httpx.post(f"{HL_API}/info", json={"type": "l2Book", "coin": "@1035"})
    book = resp.json()
    b = book["levels"][0][0]["px"]
    a = book["levels"][1][0]["px"]
    print(f"  HYPE (@1035): bid={b} ask={a}")

    # Test each vault
    results = {}
    for name, config in VAULTS.items():
        results[name] = test_vault(name, config)

    # Summary
    print(f"\n{'='*60}")
    print("  RESULTS SUMMARY")
    print(f"{'='*60}")
    for name, result in results.items():
        print(f"  {name}: {result}")

    # Final Core balance verification
    print(f"\n--- Final State ---")
    for name, config in VAULTS.items():
        addr = config["address"]
        core_bals = get_core_balances(addr)
        evm_hype = w3.eth.get_balance(Web3.to_checksum_address(addr)) / 1e18
        print(f"\n  {name} ({addr}):")
        print(f"    EVM HYPE: {evm_hype:.6f}")
        if core_bals:
            for coin, amount in core_bals.items():
                print(f"    Core {coin}: {amount}")
        else:
            print(f"    Core: (empty)")
        vault = get_vault(addr)
        try:
            gross = vault.functions.grossAssets().call()
            supply = vault.functions.totalSupply().call()
            print(f"    grossAssets: ${gross/1e8:.4f}")
            print(f"    totalSupply: {supply/1e18:.4f} shares")
        except Exception as e:
            print(f"    view error: {e}")


if __name__ == "__main__":
    main()
