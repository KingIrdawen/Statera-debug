"""
Direct test: IOC buy SOVY from keeper EOA.
Step 1: Bridge 0.2 HYPE EVM→Core
Step 2: Sell 0.15 HYPE IOC for USDC (on HYPE market)
Step 3: Wait for L1, check USDC
Step 4: Try IOC buy 8.5 SOVY
Step 5: If fails, try GTC buy 8.5 SOVY
"""
import json
import time
import httpx
from web3 import Web3
from eth_account import Account

RPC = "https://rpc.hyperliquid-testnet.xyz/evm"
HL_API = "https://api.hyperliquid-testnet.xyz"
PK = "0xe4ae2778178f38d157ed6894bc601da12742b93785a061bdd15889b33b750934"
CORE_WRITER = "0x3333333333333333333333333333333333333333"
HYPE_BRIDGE = "0x2222222222222222222222222222222222222222"
CHAIN_ID = 998

w3 = Web3(Web3.HTTPProvider(RPC))
account = Account.from_key(PK)
core_abi = [{"inputs":[{"name":"data","type":"bytes"}],"name":"sendRawAction","outputs":[],"stateMutability":"nonpayable","type":"function"}]
core_contract = w3.eth.contract(address=Web3.to_checksum_address(CORE_WRITER), abi=core_abi)


def build_payload(action_id, params):
    data = bytearray(4 + len(params))
    data[0] = 0x01
    data[1] = (action_id >> 16) & 0xFF
    data[2] = (action_id >> 8) & 0xFF
    data[3] = action_id & 0xFF
    data[4:] = params
    return bytes(data)


def send_tx(to, value=0, data=b""):
    nonce = w3.eth.get_transaction_count(account.address)
    tx = {
        "from": account.address, "to": to, "value": value, "data": data,
        "nonce": nonce, "gas": 500_000, "gasPrice": w3.eth.gas_price, "chainId": CHAIN_ID,
    }
    signed = account.sign_transaction(tx)
    tx_hash = w3.eth.send_raw_transaction(signed.raw_transaction)
    receipt = w3.eth.wait_for_transaction_receipt(tx_hash, timeout=120)
    return receipt


def send_core_action(payload):
    nonce = w3.eth.get_transaction_count(account.address)
    tx = core_contract.functions.sendRawAction(payload).build_transaction({
        "from": account.address, "nonce": nonce,
        "gas": 500_000, "gasPrice": w3.eth.gas_price, "chainId": CHAIN_ID,
    })
    signed = account.sign_transaction(tx)
    tx_hash = w3.eth.send_raw_transaction(signed.raw_transaction)
    receipt = w3.eth.wait_for_transaction_receipt(tx_hash, timeout=120)
    print(f"  status={receipt['status']}")
    return receipt


def get_balances(user):
    resp = httpx.post(f"{HL_API}/info", json={"type": "spotClearinghouseState", "user": user})
    return {b["coin"]: float(b["total"]) for b in resp.json()["balances"] if float(b["total"]) > 0}


def get_fills(user, coin=None):
    resp = httpx.post(f"{HL_API}/info", json={"type": "userFills", "user": user})
    fills = resp.json()
    if coin:
        fills = [f for f in fills if f["coin"] == coin]
    return fills


def main():
    print(f"Keeper: {account.address}")
    evm_hype = w3.eth.get_balance(account.address) / 1e18
    bals = get_balances(account.address)
    print(f"EVM HYPE: {evm_hype:.6f}")
    print(f"Core: {bals}")

    # Step 1: Bridge 0.2 HYPE EVM→Core
    bridge_amount = int(0.2 * 1e18)
    print(f"\n=== Step 1: Bridge 0.2 HYPE EVM→Core ===")
    r = send_tx(Web3.to_checksum_address(HYPE_BRIDGE), value=bridge_amount)
    print(f"  Bridge status={r['status']}")

    # Wait for L1
    print("  Waiting 8s for L1...")
    time.sleep(8)

    bals = get_balances(account.address)
    print(f"  Core after bridge: {bals}")

    # Step 2: Sell 0.15 HYPE IOC to get USDC
    print(f"\n=== Step 2: Sell 0.15 HYPE IOC @ $70 ===")
    # HYPE best bid = $70, szDec=2
    # asset=11035, sell, px=70*1e8=7000000000, sz=0.15*1e8=15000000
    params = w3.codec.encode(
        ['uint32', 'bool', 'uint64', 'uint64', 'bool', 'uint8', 'uint128'],
        [11035, False, 7000000000, 15000000, False, 3, 0]  # IOC sell
    )
    payload = build_payload(1, params)
    send_core_action(payload)

    print("  Waiting 5s...")
    time.sleep(5)
    bals = get_balances(account.address)
    print(f"  Core after sell: {bals}")

    usdc = bals.get("USDC", 0)
    if usdc < 10:
        print(f"  Only {usdc:.2f} USDC, not enough for $10 min notional")
        return

    # Step 3: Get SOVY order book
    resp = httpx.post(f"{HL_API}/info", json={"type": "l2Book", "coin": "@1080"})
    book = resp.json()
    best_ask = float(book["levels"][1][0]["px"])
    best_bid = float(book["levels"][0][0]["px"])
    print(f"\n  SOVY book: bid={best_bid} ask={best_ask}")

    # Step 4: IOC buy SOVY
    buy_px = round(best_ask * 1.02, 4)  # 2% above ask
    buy_sz = 8.5
    initial_fills = len(get_fills(account.address, "@1080"))

    print(f"\n=== Step 4: IOC buy {buy_sz} SOVY @ ${buy_px} ===")
    print(f"  Notional: ${buy_sz * buy_px:.2f}")
    params = w3.codec.encode(
        ['uint32', 'bool', 'uint64', 'uint64', 'bool', 'uint8', 'uint128'],
        [11080, True, int(buy_px * 1e8), int(buy_sz * 1e8), False, 3, 0]  # IOC
    )
    payload = build_payload(1, params)
    send_core_action(payload)

    time.sleep(5)
    bals = get_balances(account.address)
    new_fills = len(get_fills(account.address, "@1080"))
    print(f"  Balances after IOC: {bals}")
    print(f"  New fills: {new_fills - initial_fills}")

    if new_fills > initial_fills:
        print("  *** IOC BUY WORKED! ***")
        return

    print("  *** IOC BUY FAILED ***")

    # Step 5: Try GTC buy
    initial_fills = new_fills
    print(f"\n=== Step 5: GTC buy {buy_sz} SOVY @ ${buy_px} ===")
    params = w3.codec.encode(
        ['uint32', 'bool', 'uint64', 'uint64', 'bool', 'uint8', 'uint128'],
        [11080, True, int(buy_px * 1e8), int(buy_sz * 1e8), False, 2, 0]  # GTC
    )
    payload = build_payload(1, params)
    send_core_action(payload)

    time.sleep(5)
    bals_after = get_balances(account.address)
    new_fills_2 = len(get_fills(account.address, "@1080"))
    print(f"  Balances after GTC: {bals_after}")
    print(f"  New fills: {new_fills_2 - initial_fills}")

    if new_fills_2 > initial_fills:
        print("  *** GTC BUY WORKED! IOC is the problem. ***")
    else:
        print("  *** GTC ALSO FAILED ***")


if __name__ == "__main__":
    main()
