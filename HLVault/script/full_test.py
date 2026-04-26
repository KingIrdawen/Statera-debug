"""
Full rebalancing test on new vaults (GTC fix).
1. Create BARK + ZIGG vaults via factory
2. Activate all 3 vault Core accounts
3. Deposit HYPE into each
4. Run advanceRebalance() on each and verify Core balances
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
if isinstance(vault_abi, dict) and "abi" in vault_abi:
    vault_abi = vault_abi["abi"]

factory_abi_path = Path(__file__).parent.parent / "keeper" / "abi" / "VaultFactory.json"
with open(factory_abi_path) as f:
    factory_abi = json.load(f)
if isinstance(factory_abi, dict) and "abi" in factory_abi:
    factory_abi = factory_abi["abi"]

FACTORY = "0xaA10D8E5a5A6B89F12223f9F36ec2E66b4d9ACD1"  # wrong - let me fix
# Actually from deploy output:
FACTORY = "0xaA10D8C30e6226356D61E0ca88c8d1B0e6df20AE"
SOVY_VAULT = "0x22276e9562e38c309f8Dedf8f1fB405297560da7"

PHASE_NAMES = {0:"IDLE",1:"BRIDGING_IN",2:"AWAITING_BRIDGE_IN",3:"TRADING",4:"AWAITING_TRADES",5:"BRIDGING_OUT",6:"AWAITING_BRIDGE_OUT",7:"FINALIZING"}

# Token configs
TOKENS = {
    "SOVY": {
        "vault": SOVY_VAULT,
        "evmContract": "0x674d61f547AE1595f81369f7f37f7400c1210444",
        "tokenIndex": 1158,
        "spotMarket": 1080,
        "szDec": 1,
        "weiDec": 8,
        "evmDec": 18,
    },
    "BARK": {
        "evmContract": "0x66cafdad96b087187bd7875c7efe49a4bb1d388c",
        "tokenIndex": 242,
        "spotMarket": 218,
        "szDec": 0,
        "weiDec": 5,
        "evmDec": 18,
    },
    "ZIGG": {
        "evmContract": "0xe073a3e64423ce020716cd641dfd489c3b644620",
        "tokenIndex": 1048,
        "spotMarket": 980,
        "szDec": 2,
        "weiDec": 8,
        "evmDec": 18,
    },
}


def send_tx_raw(fn, value=0):
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


def create_vault(factory, config, name):
    """Create vault via factory if not already created."""
    print(f"\nCreating {name} vault...")
    r = send_tx_raw(factory.functions.createVault(
        Web3.to_checksum_address(config["evmContract"]),
        config["tokenIndex"],
        config["spotMarket"],
        1105,  # hypeTokenIndex testnet
        1035,  # hypeSpotMarketIndex testnet
        0,     # usdcTokenIndex
        config["szDec"],
        config["weiDec"],
        config["evmDec"],
        int(10e18),  # maxSingleDeposit
        f"HyperVault {name}",
        f"hv{name}",
    ))
    print(f"  status={r['status']}")
    # Get vault address from logs
    for log in r["logs"]:
        if len(log["topics"]) > 0:
            # VaultCreated event
            if len(log["data"]) >= 64:
                vault_addr = "0x" + log["data"].hex()[-40:]
                print(f"  Vault: {vault_addr}")
                return Web3.to_checksum_address(vault_addr)
    # Fallback: read from factory
    count = factory.functions.vaultCount().call()
    vault_addr = factory.functions.allVaults(count - 1).call()
    print(f"  Vault (from factory): {vault_addr}")
    return vault_addr


def test_rebalance(name, vault_addr):
    """Run advanceRebalance() and monitor Core balances."""
    vault = w3.eth.contract(address=Web3.to_checksum_address(vault_addr), abi=vault_abi)

    print(f"\n{'='*60}")
    print(f"  {name} REBALANCE TEST ({vault_addr[:16]}...)")
    print(f"{'='*60}")

    core_bals = get_core_bals(vault_addr)
    evm_hype = w3.eth.get_balance(Web3.to_checksum_address(vault_addr)) / 1e18
    phase = vault.functions.currentCycle().call()[1]

    print(f"  Phase: {PHASE_NAMES.get(phase, phase)}")
    print(f"  EVM HYPE: {evm_hype:.6f}")
    print(f"  Core: {core_bals}")

    try:
        gross = vault.functions.grossAssets().call()
        print(f"  grossAssets: ${gross/1e8:.4f}")
    except Exception as e:
        print(f"  grossAssets error: {e}")

    if phase != 0:
        print("  Not IDLE, skipping")
        return "SKIP"

    for call_num in range(1, 8):
        print(f"\n--- advanceRebalance() call {call_num} ---")
        try:
            receipt = send_tx_raw(vault.functions.advanceRebalance())
            print(f"  status={receipt['status']} gas={receipt['gasUsed']}")
        except Exception as e:
            err = str(e)
            if "revert" in err.lower():
                print(f"  Reverted: {err[:200]}")
                return "REVERT"
            print(f"  Error: {err[:200]}")
            return "ERROR"

        phase = vault.functions.currentCycle().call()[1]
        l1 = vault.functions.getL1BlockNumber().call()
        print(f"  Phase: {PHASE_NAMES.get(phase, phase)}, L1: {l1}")

        time.sleep(2)
        core_bals = get_core_bals(vault_addr)
        evm_hype = w3.eth.get_balance(Web3.to_checksum_address(vault_addr)) / 1e18
        print(f"  Core: {core_bals}")
        print(f"  EVM HYPE: {evm_hype:.6f}")

        if phase == 0:
            if call_num == 1:
                print("  -> Rebalance skipped")
                return "SKIPPED"
            else:
                print(f"  -> Rebalance COMPLETE in {call_num} calls!")
                return "SUCCESS"

        print(f"  Waiting for L1 > {l1}...")
        try:
            new_l1 = wait_l1(vault, l1)
            print(f"  L1: {new_l1}")
        except TimeoutError:
            print("  TIMEOUT")
            return "TIMEOUT"

    return "INCOMPLETE"


def main():
    print("=" * 60)
    print("  MULTI-TOKEN REBALANCE TEST (GTC orders)")
    print("=" * 60)

    keeper_hype = w3.eth.get_balance(account.address) / 1e18
    keeper_core = get_core_bals(account.address)
    print(f"\nKeeper EVM HYPE: {keeper_hype:.6f}")
    print(f"Keeper Core: {keeper_core}")

    factory = w3.eth.contract(address=Web3.to_checksum_address(FACTORY), abi=factory_abi)

    # Create BARK and ZIGG vaults if needed
    for name in ["BARK", "ZIGG"]:
        if "vault" not in TOKENS[name]:
            try:
                addr = create_vault(factory, TOKENS[name], name)
                TOKENS[name]["vault"] = addr
            except Exception as e:
                print(f"  Create {name} error: {str(e)[:200]}")
                continue

    # Activate Core accounts + deposit HYPE
    deposit_amounts = {"SOVY": 0.30, "BARK": 0.15, "ZIGG": 0.15}

    for name, config in TOKENS.items():
        if "vault" not in config:
            continue
        addr = config["vault"]
        print(f"\n--- Setting up {name} ({addr[:16]}...) ---")

        # Activate Core if needed
        exists = check_core_exists(addr)
        if not exists:
            print(f"  Activating Core account...")
            params = w3.codec.encode(
                ['address', 'uint64', 'uint64'],
                [Web3.to_checksum_address(addr), 0, 1_000_000]
            )
            payload = build_payload(6, params)
            r = send_core_action(payload)
            print(f"  Activation status={r['status']}")
            time.sleep(5)
            exists = check_core_exists(addr)
            print(f"  Active: {exists}")
            if not exists:
                print(f"  FAILED to activate!")
                continue

        # Deposit HYPE
        vault_hype = w3.eth.get_balance(Web3.to_checksum_address(addr)) / 1e18
        deposit_target = deposit_amounts.get(name, 0.15)
        if vault_hype < deposit_target * 0.9:
            deposit_wei = int(deposit_target * 1e18)
            print(f"  Depositing {deposit_target} HYPE...")
            vault = w3.eth.contract(address=Web3.to_checksum_address(addr), abi=vault_abi)
            try:
                r = send_tx_raw(vault.functions.deposit(), value=deposit_wei)
                print(f"  Deposit status={r['status']}")
            except Exception as e:
                print(f"  Deposit error: {str(e)[:200]}")
                continue
        else:
            print(f"  Already has {vault_hype:.6f} HYPE")

    # Market prices
    print(f"\n--- Market Prices ---")
    for name, config in TOKENS.items():
        if "vault" not in config:
            continue
        resp = httpx.post(f"{HL_API}/info", json={"type": "l2Book", "coin": f"@{config['spotMarket']}"})
        book = resp.json()
        if book and "levels" in book and book["levels"][0] and book["levels"][1]:
            bid = book["levels"][0][0]["px"]
            ask = book["levels"][1][0]["px"]
            print(f"  {name} (@{config['spotMarket']}): bid={bid} ask={ask}")
        else:
            print(f"  {name}: NO BOOK")

    # Test rebalancing
    results = {}
    for name, config in TOKENS.items():
        if "vault" not in config:
            results[name] = "NO VAULT"
            continue
        results[name] = test_rebalance(name, config["vault"])

    # Summary
    print(f"\n{'='*60}")
    print("  RESULTS SUMMARY")
    print(f"{'='*60}")
    for name, result in results.items():
        print(f"  {name}: {result}")

    # Final Core balance verification
    print(f"\n--- Final State ---")
    for name, config in TOKENS.items():
        if "vault" not in config:
            continue
        addr = config["vault"]
        core_bals = get_core_bals(addr)
        evm_hype = w3.eth.get_balance(Web3.to_checksum_address(addr)) / 1e18
        vault = w3.eth.contract(address=Web3.to_checksum_address(addr), abi=vault_abi)
        print(f"\n  {name} ({addr[:16]}...):")
        print(f"    EVM HYPE: {evm_hype:.6f}")
        if core_bals:
            for coin, amount in core_bals.items():
                print(f"    Core {coin}: {amount}")
        else:
            print(f"    Core: (empty)")
        try:
            gross = vault.functions.grossAssets().call()
            supply = vault.functions.totalSupply().call()
            print(f"    grossAssets: ${gross/1e8:.4f}")
            print(f"    totalSupply: {supply/1e18:.4f}")
        except Exception as e:
            print(f"    View error: {e}")

    # Verify token balances on Core
    print(f"\n--- Token Balance Verification ---")
    success_count = 0
    for name, config in TOKENS.items():
        if "vault" not in config:
            continue
        core_bals = get_core_bals(config["vault"])
        has_token = name in core_bals and core_bals[name] > 0
        has_usdc = "USDC" in core_bals and core_bals["USDC"] > 0
        print(f"  {name}: token_on_core={has_token}, usdc_on_core={has_usdc}")
        if has_token:
            success_count += 1

    if success_count > 0:
        print(f"\n  *** {success_count}/3 vaults have counterpart tokens on Core! ***")
    else:
        print(f"\n  *** No vaults have counterpart tokens on Core ***")


if __name__ == "__main__":
    main()
