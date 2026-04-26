"""
Debug: test IOC buy vs GTC buy for SOVY from keeper EOA.
Step 1: Sell 4.8 SOVY (IOC) to get USDC back
Step 2: Try IOC buy 8.3 SOVY
"""
import json
import time
import httpx
from web3 import Web3
from eth_account import Account

RPC = "https://rpc.hyperliquid-testnet.xyz/evm"
HL_API = "https://api.hyperliquid-testnet.xyz"
PRIVATE_KEY = "0xe4ae2778178f38d157ed6894bc601da12742b93785a061bdd15889b33b750934"
CORE_WRITER = "0x3333333333333333333333333333333333333333"
CHAIN_ID = 998

w3 = Web3(Web3.HTTPProvider(RPC))
account = Account.from_key(PRIVATE_KEY)
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


def send_core_action(payload):
    nonce = w3.eth.get_transaction_count(account.address)
    tx = core_contract.functions.sendRawAction(payload).build_transaction({
        "from": account.address, "nonce": nonce,
        "gas": 500_000, "gasPrice": w3.eth.gas_price, "chainId": CHAIN_ID,
    })
    signed = account.sign_transaction(tx)
    tx_hash = w3.eth.send_raw_transaction(signed.raw_transaction)
    receipt = w3.eth.wait_for_transaction_receipt(tx_hash, timeout=120)
    print(f"  tx: {tx_hash.hex()[:20]}... status={receipt['status']}")
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
    bals = get_balances(account.address)
    print(f"Keeper balances: {bals}")
    initial_fills = len(get_fills(account.address, "@1080"))
    print(f"SOVY fills count: {initial_fills}")

    # Step 1: Sell all SOVY (IOC) to recover USDC
    sovy_bal = bals.get("SOVY", 0)
    if sovy_bal >= 0.1:
        sell_sz = int(sovy_bal * 10) / 10  # Round to szDec=1
        print(f"\n=== Step 1: IOC sell {sell_sz} SOVY @ $1.19 ===")
        params = w3.codec.encode(
            ['uint32', 'bool', 'uint64', 'uint64', 'bool', 'uint8', 'uint128'],
            [11080, False, int(1.19 * 1e8), int(sell_sz * 1e8), False, 3, 0]
        )
        payload = build_payload(1, params)
        send_core_action(payload)
        time.sleep(3)
        bals = get_balances(account.address)
        print(f"  Balances after sell: {bals}")
        new_fills = len(get_fills(account.address, "@1080"))
        print(f"  SOVY fills: {new_fills - initial_fills} new")
        initial_fills = new_fills

    bals = get_balances(account.address)
    usdc = bals.get("USDC", 0)
    print(f"\nUSDC available: {usdc:.4f}")

    if usdc < 10:
        print("Not enough USDC for $10 min notional, aborting")
        return

    # Step 2: IOC buy SOVY
    buy_sz = 8.4  # ~$10.08 notional at $1.20
    buy_px = 1.2100  # Above best ask ($1.2034)
    print(f"\n=== Step 2: IOC buy {buy_sz} SOVY @ ${buy_px} ===")
    print(f"  Notional: ${buy_sz * buy_px:.2f}")
    params = w3.codec.encode(
        ['uint32', 'bool', 'uint64', 'uint64', 'bool', 'uint8', 'uint128'],
        [11080, True, int(buy_px * 1e8), int(buy_sz * 1e8), False, 3, 0]  # tif=3 IOC
    )
    payload = build_payload(1, params)
    print(f"  Payload: {payload.hex()[:40]}...")
    send_core_action(payload)
    time.sleep(3)

    bals = get_balances(account.address)
    print(f"  Balances after IOC buy: {bals}")
    new_fills = len(get_fills(account.address, "@1080"))
    print(f"  New SOVY fills: {new_fills - initial_fills}")

    if new_fills == initial_fills:
        print("\n  *** IOC BUY FAILED - no fills! ***")
        print("  Trying GTC buy as comparison...")
        params2 = w3.codec.encode(
            ['uint32', 'bool', 'uint64', 'uint64', 'bool', 'uint8', 'uint128'],
            [11080, True, int(buy_px * 1e8), int(buy_sz * 1e8), False, 2, 0]  # tif=2 GTC
        )
        payload2 = build_payload(1, params2)
        send_core_action(payload2)
        time.sleep(3)
        bals2 = get_balances(account.address)
        print(f"  Balances after GTC buy: {bals2}")
        new_fills2 = len(get_fills(account.address, "@1080"))
        print(f"  New SOVY fills (GTC): {new_fills2 - initial_fills}")


if __name__ == "__main__":
    main()
