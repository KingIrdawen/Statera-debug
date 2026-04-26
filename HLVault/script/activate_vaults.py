"""
Activate Core accounts for vault contracts.
1. Sell HYPE → USDC on Core via CoreWriter (IOC)
2. spotSend USDC to each vault (activates Core account, 1 USDC fee per send)
"""
import json
import time
import sys
import httpx
from web3 import Web3
from eth_account import Account

RPC = "https://rpc.hyperliquid-testnet.xyz/evm"
HL_API = "https://api.hyperliquid-testnet.xyz"
PRIVATE_KEY = "0xe4ae2778178f38d157ed6894bc601da12742b93785a061bdd15889b33b750934"
CORE_WRITER = "0x3333333333333333333333333333333333333333"
CHAIN_ID = 998

VAULTS = [
    "0x79B1304d9144a2660c3C2899eb522f8D9E100Cec",  # PURR
    "0x7C78C92cd22a74c74E06c9B5b9593826e70C7238",  # DANK
    "0x660e143fDf7AF0004AD8BD555069E9A64EcF10e7",  # SOVY
]

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


def send_core_action(payload: bytes, nonce: int):
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


def get_usdc_balance():
    resp = httpx.post(f"{HL_API}/info", json={
        "type": "spotClearinghouseState",
        "user": account.address
    })
    for b in resp.json()["balances"]:
        if b["coin"] == "USDC":
            return float(b["total"])
    return 0.0


def get_hype_balance():
    resp = httpx.post(f"{HL_API}/info", json={
        "type": "spotClearinghouseState",
        "user": account.address
    })
    for b in resp.json()["balances"]:
        if b["coin"] == "HYPE":
            return float(b["total"])
    return 0.0


def check_core_user_exists(address: str) -> bool:
    precompile = "0x0000000000000000000000000000000000000810"
    padded = address.lower().replace("0x", "").zfill(64)
    result = w3.eth.call({"to": precompile, "data": "0x" + padded})
    return int.from_bytes(result, "big") != 0


def main():
    usdc = get_usdc_balance()
    hype = get_hype_balance()
    print(f"USDC on Core: {usdc:.4f}")
    print(f"HYPE on Core: {hype:.6f}")

    # Step 1: Sell HYPE for USDC if needed
    if usdc < 4.0:
        # Get HYPE spot mid price
        resp = httpx.post(f"{HL_API}/info", json={"type": "allMids"})
        mids = resp.json()
        hype_mid = float(mids.get("@1035", "0"))
        print(f"\nHYPE spot mid: ${hype_mid:.2f}")

        if hype_mid == 0:
            print("ERROR: Cannot get HYPE price")
            sys.exit(1)

        # Sell all available HYPE with 5% slippage (IOC)
        # Round down to 0.01 (szDec=2)
        sell_human = int(hype * 100) / 100  # e.g. 0.10
        if sell_human < 0.01:
            print("Not enough HYPE to sell, bridging more...")
            sys.exit(1)

        # Limit price: 5% below mid, rounded to 5 sig figs
        limit_human = int(hype_mid * 0.95)
        limit_str = str(limit_human)
        if len(limit_str) > 5:
            sig = limit_str[:5]
            pad = len(limit_str) - 5
            limit_human = int(sig) * (10 ** pad)

        # CoreWriter format: limitPx = human * 1e8, sz = human * 1e8
        core_px = int(limit_human * 1e8)
        core_sz = int(sell_human * 1e8)

        print(f"Selling {sell_human} HYPE @ ${limit_human} (IOC)")
        print(f"  CoreWriter: px={core_px}, sz={core_sz}")
        print(f"  Notional: ${sell_human * limit_human:.2f}")

        params = w3.codec.encode(
            ['uint32', 'bool', 'uint64', 'uint64', 'bool', 'uint8', 'uint128'],
            [11035, False, core_px, core_sz, False, 3, 0]
        )
        payload = build_payload(1, params)

        nonce = w3.eth.get_transaction_count(account.address)
        send_core_action(payload, nonce)

        print("Waiting for Core to process sell...")
        for i in range(6):
            time.sleep(3)
            usdc = get_usdc_balance()
            print(f"  USDC: {usdc:.4f}")
            if usdc >= 4.0:
                break

    # Step 2: Activate each vault via spotSend
    print(f"\n=== Activating vaults (USDC: {usdc:.4f}) ===")
    nonce = w3.eth.get_transaction_count(account.address)

    for vault in VAULTS:
        exists = check_core_user_exists(vault)
        if exists:
            print(f"\n{vault} already active ✓")
            continue

        print(f"\nActivating {vault}...")
        # spotSend 0.01 USDC (1000000 in weiDec8)
        params = w3.codec.encode(
            ['address', 'uint64', 'uint64'],
            [Web3.to_checksum_address(vault), 0, 1_000_000]
        )
        payload = build_payload(6, params)
        send_core_action(payload, nonce)
        nonce += 1
        time.sleep(4)

        exists = check_core_user_exists(vault)
        print(f"  Active: {exists}")

    print("\n=== Final status ===")
    usdc = get_usdc_balance()
    print(f"USDC remaining: {usdc:.4f}")
    for vault in VAULTS:
        exists = check_core_user_exists(vault)
        print(f"{vault}: active={exists}")


if __name__ == "__main__":
    main()
