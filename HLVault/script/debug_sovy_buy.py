"""
Debug: try buying SOVY from keeper EOA via CoreWriter.
Tests GTC vs IOC, different sizes, and checks open orders.
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

print(f"Keeper: {account.address}")


def build_payload(action_id: int, params: bytes) -> bytes:
    data = bytearray(4 + len(params))
    data[0] = 0x01
    data[1] = (action_id >> 16) & 0xFF
    data[2] = (action_id >> 8) & 0xFF
    data[3] = action_id & 0xFF
    data[4:] = params
    return bytes(data)


def send_core_action(payload: bytes):
    nonce = w3.eth.get_transaction_count(account.address)
    tx = core_contract.functions.sendRawAction(payload).build_transaction({
        "from": account.address,
        "nonce": nonce,
        "gas": 500_000,
        "gasPrice": w3.eth.gas_price,
        "chainId": CHAIN_ID,
    })
    signed = account.sign_transaction(tx)
    tx_hash = w3.eth.send_raw_transaction(signed.raw_transaction)
    receipt = w3.eth.wait_for_transaction_receipt(tx_hash, timeout=120)
    print(f"  tx: {tx_hash.hex()} status={receipt['status']}")
    return receipt


def get_balances(user):
    resp = httpx.post(f"{HL_API}/info", json={"type": "spotClearinghouseState", "user": user})
    bals = {}
    for b in resp.json()["balances"]:
        if float(b["total"]) > 0:
            bals[b["coin"]] = float(b["total"])
    return bals


def get_open_orders(user):
    resp = httpx.post(f"{HL_API}/info", json={"type": "openOrders", "user": user})
    return resp.json()


def get_fills(user):
    resp = httpx.post(f"{HL_API}/info", json={"type": "userFills", "user": user})
    return resp.json()


def main():
    bals = get_balances(account.address)
    print(f"Keeper balances: {bals}")

    # SOVY market: spotMarketIndex=1080, szDec=1
    # Best ask: $1.2034 (133.6 available)
    # Buy 1.0 SOVY (small, well above min notional with price ~$1.2)
    # Wait — min notional is $10! 1.0 * 1.2 = $1.2 < $10
    # Need at least 8.4 SOVY to hit $10 notional

    # Try with 10.0 SOVY @ $1.2100 GTC (above ask)
    # Notional: 10.0 * 1.21 = $12.10 > $10 ✓
    asset = 11080  # 10000 + 1080
    is_buy = True
    limit_px = int(1.21 * 1e8)  # 121000000
    sz = int(10.0 * 1e8)  # 1000000000
    reduce_only = False
    tif = 2  # GTC
    cloid = 0

    print(f"\n=== Test 1: GTC buy 10.0 SOVY @ $1.21 ===")
    print(f"  asset={asset}, isBuy={is_buy}, limitPx={limit_px}, sz={sz}, tif={tif}")
    print(f"  Notional: ${10.0 * 1.21:.2f}")

    params = w3.codec.encode(
        ['uint32', 'bool', 'uint64', 'uint64', 'bool', 'uint8', 'uint128'],
        [asset, is_buy, limit_px, sz, reduce_only, tif, cloid]
    )
    payload = build_payload(1, params)
    print(f"  Payload hex: {payload.hex()}")

    send_core_action(payload)

    time.sleep(3)

    orders = get_open_orders(account.address)
    print(f"\nOpen orders: {json.dumps(orders, indent=2)}")

    fills_after = get_fills(account.address)
    sovy_fills = [f for f in fills_after if f.get("coin") == "@1080"]
    print(f"SOVY fills: {len(sovy_fills)}")
    if sovy_fills:
        for f in sovy_fills[-3:]:
            print(f"  {f['side']} {f['sz']}@{f['px']} t={f['time']}")

    bals_after = get_balances(account.address)
    print(f"\nBalances after: {bals_after}")


if __name__ == "__main__":
    main()
