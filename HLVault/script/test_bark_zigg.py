"""
Test rebalancing on BARK and ZIGG vaults.
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

w3 = Web3(Web3.HTTPProvider(RPC))
account = Account.from_key(PK)
core_abi = [{"inputs":[{"name":"data","type":"bytes"}],"name":"sendRawAction","outputs":[],"stateMutability":"nonpayable","type":"function"}]
core_contract = w3.eth.contract(address=Web3.to_checksum_address(CORE_WRITER), abi=core_abi)

abi_path = Path(__file__).parent.parent / "keeper" / "abi" / "RebalancingVault.json"
with open(abi_path) as f:
    vault_abi = json.load(f)

PHASE_NAMES = {0:"IDLE",1:"BRIDGING_IN",2:"AWAITING_BRIDGE_IN",3:"TRADING",4:"AWAITING_TRADES",5:"BRIDGING_OUT",6:"AWAITING_BRIDGE_OUT",7:"FINALIZING"}

VAULTS = {
    "BARK": {
        "address": "0x720021b106B42a625c1dC2322214A3248A09bb6a",
        "tokenIndex": 242,
        "spotMarket": 218,
        "szDec": 0,
        "weiDec": 5,
    },
    "ZIGG": {
        "address": "0x66e880e2bd93243569B985499aD00Df543a77554",
        "tokenIndex": 1048,
        "spotMarket": 980,
        "szDec": 2,
        "weiDec": 8,
    },
}


def send_tx(fn, value=0):
    nonce = w3.eth.get_transaction_count(account.address)
    try:
        gas = fn.estimate_gas({"from": account.address, "value": value})
        gas = int(gas * 1.5)
    except:
        gas = 2_000_000
    tx = fn.build_transaction({
        "from": account.address, "nonce": nonce,
        "gas": gas, "gasPrice": w3.eth.gas_price, "chainId": CHAIN_ID, "value": value,
    })
    signed = account.sign_transaction(tx)
    tx_hash = w3.eth.send_raw_transaction(signed.raw_transaction)
    receipt = w3.eth.wait_for_transaction_receipt(tx_hash, timeout=120)
    return receipt


def build_payload(action_id, params):
    data = bytearray(4 + len(params))
    data[0] = 0x01
    data[1] = (action_id >> 16) & 0xFF
    data[2] = (action_id >> 8) & 0xFF
    data[3] = action_id & 0xFF
    data[4:] = params
    return bytes(data)


def send_core_action(payload):
    nonce = w3.eth.get_transaction_count(account.address)
    tx = core_contract.functions.sendRawAction(payload).build_transaction({
        "from": account.address, "nonce": nonce,
        "gas": 500_000, "gasPrice": w3.eth.gas_price, "chainId": CHAIN_ID,
    })
    signed = account.sign_transaction(tx)
    tx_hash = w3.eth.send_raw_transaction(signed.raw_transaction)
    receipt = w3.eth.wait_for_transaction_receipt(tx_hash, timeout=120)
    return receipt


def check_core_exists(addr):
    precompile = "0x0000000000000000000000000000000000000810"
    padded = addr.lower().replace("0x", "").zfill(64)
    result = w3.eth.call({"to": precompile, "data": "0x" + padded})
    return int.from_bytes(result, "big") != 0


def get_core_bals(addr):
    resp = httpx.post(f"{HL_API}/info", json={"type": "spotClearinghouseState", "user": addr})
    return {b["coin"]: float(b["total"]) for b in resp.json()["balances"] if float(b["total"]) > 0}


def wait_l1(vault_contract, current, timeout=90):
    start = time.time()
    while time.time() - start < timeout:
        new = vault_contract.functions.getL1BlockNumber().call()
        if new > current:
            return new
        time.sleep(2)
    raise TimeoutError(f"L1 stuck at {current}")


def main():
    keeper_hype = w3.eth.get_balance(account.address) / 1e18
    print(f"Keeper EVM HYPE: {keeper_hype:.6f}")

    results = {}

    for name, config in VAULTS.items():
        addr = config["address"]
        vault = w3.eth.contract(address=Web3.to_checksum_address(addr), abi=vault_abi)

        print(f"\n{'='*60}")
        print(f"  {name} ({addr})")
        print(f"  szDec={config['szDec']}, weiDec={config['weiDec']}")
        print(f"{'='*60}")

        # Check/activate Core
        exists = check_core_exists(addr)
        if not exists:
            print("  Activating Core...")
            params = w3.codec.encode(
                ['address', 'uint64', 'uint64'],
                [Web3.to_checksum_address(addr), 0, 1_000_000]
            )
            payload = build_payload(6, params)
            r = send_core_action(payload)
            print(f"  status={r['status']}")
            time.sleep(5)
            if not check_core_exists(addr):
                print("  FAILED to activate!")
                results[name] = "ACTIVATION_FAILED"
                continue

        # Deposit HYPE
        vault_hype = w3.eth.get_balance(Web3.to_checksum_address(addr)) / 1e18
        print(f"  Current vault HYPE: {vault_hype:.6f}")
        if vault_hype < 0.14:
            deposit = int(0.15 * 1e18)
            print(f"  Depositing 0.15 HYPE...")
            try:
                r = send_tx(vault.functions.deposit(), value=deposit)
                print(f"  Deposit status={r['status']}")
            except Exception as e:
                print(f"  Deposit error: {str(e)[:200]}")
                results[name] = "DEPOSIT_FAILED"
                continue
            vault_hype = w3.eth.get_balance(Web3.to_checksum_address(addr)) / 1e18

        # Market info
        resp = httpx.post(f"{HL_API}/info", json={"type": "l2Book", "coin": f"@{config['spotMarket']}"})
        book = resp.json()
        if book and "levels" in book and book["levels"][0] and book["levels"][1]:
            bid = book["levels"][0][0]["px"]
            ask = book["levels"][1][0]["px"]
            print(f"  Market: bid={bid} ask={ask}")

        # State
        core_bals = get_core_bals(addr)
        gross = vault.functions.grossAssets().call()
        print(f"  grossAssets: ${gross/1e8:.4f}")
        print(f"  Core: {core_bals}")

        # Rebalance
        for call_num in range(1, 8):
            print(f"\n  --- advanceRebalance() call {call_num} ---")
            try:
                receipt = send_tx(vault.functions.advanceRebalance())
                print(f"    status={receipt['status']} gas={receipt['gasUsed']}")
            except Exception as e:
                err = str(e)
                if "revert" in err.lower():
                    print(f"    Reverted: {err[:200]}")
                    results[name] = "REVERT"
                    break
                print(f"    Error: {err[:200]}")
                results[name] = "ERROR"
                break

            phase = vault.functions.currentCycle().call()[1]
            l1 = vault.functions.getL1BlockNumber().call()
            print(f"    Phase: {PHASE_NAMES.get(phase, phase)}, L1: {l1}")

            time.sleep(2)
            core_bals = get_core_bals(addr)
            evm_hype = w3.eth.get_balance(Web3.to_checksum_address(addr)) / 1e18
            print(f"    Core: {core_bals}")
            print(f"    EVM HYPE: {evm_hype:.6f}")

            if phase == 0:
                if call_num == 1:
                    print("    -> Rebalance skipped")
                    results[name] = "SKIPPED"
                else:
                    print(f"    -> COMPLETE in {call_num} calls!")
                    results[name] = "SUCCESS"
                break

            print(f"    Waiting for L1 > {l1}...")
            try:
                new_l1 = wait_l1(vault, l1)
                print(f"    L1: {new_l1}")
            except TimeoutError:
                print("    TIMEOUT")
                results[name] = "TIMEOUT"
                break
        else:
            results[name] = "INCOMPLETE"

    # Summary
    print(f"\n{'='*60}")
    print("  RESULTS")
    print(f"{'='*60}")
    for name, result in results.items():
        addr = VAULTS[name]["address"]
        core_bals = get_core_bals(addr)
        evm_hype = w3.eth.get_balance(Web3.to_checksum_address(addr)) / 1e18
        token_on_core = name in core_bals
        print(f"  {name}: {result}")
        print(f"    Core: {core_bals}")
        print(f"    EVM HYPE: {evm_hype:.6f}")
        print(f"    {name} on Core: {'YES' if token_on_core else 'NO'}")


if __name__ == "__main__":
    main()
