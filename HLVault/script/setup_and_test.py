"""
Setup and test rebalancing for SOVY vault (GTC fix).
1. Activate Core account
2. Deposit HYPE
3. Run advanceRebalance() and verify Core balances
"""
import json
import time
import httpx
from web3 import Web3
from eth_account import Account
from pathlib import Path

RPC = "https://rpc.hyperliquid-testnet.xyz/evm"
HL_API = "https://api.hyperliquid-testnet.xyz"
PK = "0xe4ae2778178f38d157ed6894bc601da12742b93785a061bdd15889b33b750934"
CORE_WRITER = "0x3333333333333333333333333333333333333333"
CHAIN_ID = 998

SOVY_VAULT = "0x22276e9562e38c309f8Dedf8f1fB405297560da7"

w3 = Web3(Web3.HTTPProvider(RPC))
account = Account.from_key(PK)
core_abi = [{"inputs":[{"name":"data","type":"bytes"}],"name":"sendRawAction","outputs":[],"stateMutability":"nonpayable","type":"function"}]
core_contract = w3.eth.contract(address=Web3.to_checksum_address(CORE_WRITER), abi=core_abi)

abi_path = Path(__file__).parent.parent / "keeper" / "abi" / "RebalancingVault.json"
with open(abi_path) as f:
    vault_abi = json.load(f)
if isinstance(vault_abi, dict) and "abi" in vault_abi:
    vault_abi = vault_abi["abi"]

vault = w3.eth.contract(address=Web3.to_checksum_address(SOVY_VAULT), abi=vault_abi)

PHASE_NAMES = {0:"IDLE",1:"BRIDGING_IN",2:"AWAITING_BRIDGE_IN",3:"TRADING",4:"AWAITING_TRADES",5:"BRIDGING_OUT",6:"AWAITING_BRIDGE_OUT",7:"FINALIZING"}


def build_payload(action_id, params):
    data = bytearray(4 + len(params))
    data[0] = 0x01
    data[1] = (action_id >> 16) & 0xFF
    data[2] = (action_id >> 8) & 0xFF
    data[3] = action_id & 0xFF
    data[4:] = params
    return bytes(data)


def send_core_action(payload, nonce=None):
    if nonce is None:
        nonce = w3.eth.get_transaction_count(account.address)
    tx = core_contract.functions.sendRawAction(payload).build_transaction({
        "from": account.address, "nonce": nonce,
        "gas": 500_000, "gasPrice": w3.eth.gas_price, "chainId": CHAIN_ID,
    })
    signed = account.sign_transaction(tx)
    tx_hash = w3.eth.send_raw_transaction(signed.raw_transaction)
    receipt = w3.eth.wait_for_transaction_receipt(tx_hash, timeout=120)
    return receipt


def send_tx(fn):
    nonce = w3.eth.get_transaction_count(account.address)
    try:
        gas = fn.estimate_gas({"from": account.address})
        gas = int(gas * 1.5)
    except:
        gas = 2_000_000
    tx = fn.build_transaction({
        "from": account.address, "nonce": nonce,
        "gas": gas, "gasPrice": w3.eth.gas_price, "chainId": CHAIN_ID,
    })
    signed = account.sign_transaction(tx)
    tx_hash = w3.eth.send_raw_transaction(signed.raw_transaction)
    receipt = w3.eth.wait_for_transaction_receipt(tx_hash, timeout=120)
    return receipt


def get_core_balances(addr):
    resp = httpx.post(f"{HL_API}/info", json={"type": "spotClearinghouseState", "user": addr})
    return {b["coin"]: float(b["total"]) for b in resp.json()["balances"] if float(b["total"]) > 0}


def check_core_exists(addr):
    precompile = "0x0000000000000000000000000000000000000810"
    padded = addr.lower().replace("0x", "").zfill(64)
    result = w3.eth.call({"to": precompile, "data": "0x" + padded})
    return int.from_bytes(result, "big") != 0


def wait_l1(current, timeout=90):
    start = time.time()
    while time.time() - start < timeout:
        new = vault.functions.getL1BlockNumber().call()
        if new > current:
            return new
        time.sleep(2)
    raise TimeoutError(f"L1 stuck at {current}")


def main():
    print(f"Keeper: {account.address}")
    print(f"SOVY Vault: {SOVY_VAULT}")

    # === Step 1: Activate Core account ===
    exists = check_core_exists(SOVY_VAULT)
    print(f"\nCore account active: {exists}")

    if not exists:
        keeper_bals = get_core_balances(account.address)
        print(f"Keeper Core USDC: {keeper_bals.get('USDC', 0):.4f}")

        print("Activating SOVY vault Core account via spotSend...")
        params = w3.codec.encode(
            ['address', 'uint64', 'uint64'],
            [Web3.to_checksum_address(SOVY_VAULT), 0, 1_000_000]  # 0.01 USDC
        )
        payload = build_payload(6, params)
        r = send_core_action(payload)
        print(f"  Activation tx status={r['status']}")
        time.sleep(5)
        exists = check_core_exists(SOVY_VAULT)
        print(f"  Core account active: {exists}")
        if not exists:
            print("FAILED to activate!")
            return

    # === Step 2: Deposit HYPE into vault ===
    evm_hype = w3.eth.get_balance(account.address) / 1e18
    print(f"\nKeeper EVM HYPE: {evm_hype:.6f}")
    vault_hype = w3.eth.get_balance(Web3.to_checksum_address(SOVY_VAULT)) / 1e18
    print(f"Vault EVM HYPE: {vault_hype:.6f}")

    # Need enough HYPE for rebalance. At $70, 0.30 HYPE = $21
    deposit_amount = int(0.015 * 1e18)  # Small deposit, we're low on HYPE
    if vault_hype < 0.01:
        print(f"Depositing {deposit_amount/1e18:.4f} HYPE...")
        nonce = w3.eth.get_transaction_count(account.address)
        tx = {
            "from": account.address,
            "to": Web3.to_checksum_address(SOVY_VAULT),
            "value": deposit_amount,
            "nonce": nonce,
            "gas": 500_000,
            "gasPrice": w3.eth.gas_price,
            "chainId": CHAIN_ID,
            "data": vault.encode_abi("deposit", [account.address]),
        }
        signed = account.sign_transaction(tx)
        tx_hash = w3.eth.send_raw_transaction(signed.raw_transaction)
        receipt = w3.eth.wait_for_transaction_receipt(tx_hash, timeout=120)
        print(f"  Deposit status={receipt['status']}")
        vault_hype = w3.eth.get_balance(Web3.to_checksum_address(SOVY_VAULT)) / 1e18
        print(f"  Vault EVM HYPE: {vault_hype:.6f}")

    # Check vault state
    try:
        gross = vault.functions.grossAssets().call()
        supply = vault.functions.totalSupply().call()
        print(f"\n  grossAssets: ${gross/1e8:.4f}")
        print(f"  totalSupply: {supply/1e18:.6f}")
    except Exception as e:
        print(f"  View error: {e}")

    # === Step 3: Run rebalance ===
    print(f"\n{'='*60}")
    print("  REBALANCE TEST (GTC orders)")
    print(f"{'='*60}")

    core_bals = get_core_balances(SOVY_VAULT)
    print(f"\nInitial Core balances: {core_bals}")
    print(f"Initial EVM HYPE: {vault_hype:.6f}")

    for call_num in range(1, 8):
        print(f"\n--- advanceRebalance() call {call_num} ---")
        try:
            receipt = send_tx(vault.functions.advanceRebalance())
            print(f"  status={receipt['status']} gas={receipt['gasUsed']}")
        except Exception as e:
            err = str(e)
            if "revert" in err.lower():
                print(f"  Reverted: {err[:300]}")
                break
            print(f"  Error: {err[:300]}")
            break

        phase_data = vault.functions.currentCycle().call()
        phase = phase_data[1]
        l1 = vault.functions.getL1BlockNumber().call()
        print(f"  Phase: {PHASE_NAMES.get(phase, phase)}, L1: {l1}")

        time.sleep(2)
        core_bals = get_core_balances(SOVY_VAULT)
        evm_hype = w3.eth.get_balance(Web3.to_checksum_address(SOVY_VAULT)) / 1e18
        print(f"  Core: {core_bals}")
        print(f"  EVM HYPE: {evm_hype:.6f}")

        if phase == 0:
            if call_num == 1:
                print("  -> Rebalance skipped (below threshold)")
            else:
                print(f"  -> Rebalance COMPLETE in {call_num} calls!")
            break

        print(f"  Waiting for L1 > {l1}...")
        try:
            new_l1 = wait_l1(l1)
            print(f"  L1 advanced to {new_l1}")
        except TimeoutError:
            print("  TIMEOUT")
            break

    # Final state
    print(f"\n{'='*60}")
    print("  FINAL STATE")
    print(f"{'='*60}")
    core_bals = get_core_balances(SOVY_VAULT)
    evm_hype = w3.eth.get_balance(Web3.to_checksum_address(SOVY_VAULT)) / 1e18
    print(f"Core: {core_bals}")
    print(f"EVM HYPE: {evm_hype:.6f}")
    try:
        gross = vault.functions.grossAssets().call()
        supply = vault.functions.totalSupply().call()
        print(f"grossAssets: ${gross/1e8:.4f}")
        print(f"totalSupply: {supply/1e18:.6f}")
    except Exception as e:
        print(f"View error: {e}")

    # Verify: check if SOVY appeared on Core
    if "SOVY" in core_bals:
        print(f"\n*** SUCCESS: SOVY on Core! {core_bals['SOVY']} ***")
    else:
        print(f"\n*** FAILED: No SOVY on Core ***")


if __name__ == "__main__":
    main()
