import os
from dotenv import load_dotenv

load_dotenv()

NETWORKS = {
    "mainnet": {
        "chain_id": 999,
        "evm_rpc": "https://rpc.hyperliquid.xyz/evm",
    },
    "testnet": {
        "chain_id": 998,
        "evm_rpc": os.getenv("EVM_RPC_URL", "https://rpc.hyperliquid-testnet.xyz/evm"),
    },
}

NETWORK = os.getenv("NETWORK", "testnet")
KEEPER_PRIVATE_KEY = os.getenv("KEEPER_PRIVATE_KEY", "")
FACTORY_ADDRESS = os.getenv("FACTORY_ADDRESS", "")

# Timing
LOOP_INTERVAL_SECONDS = 60
HEARTBEAT_INTERVAL_SECONDS = 300

# Transaction retry
TX_RETRY_ATTEMPTS = 3
TX_RETRY_DELAY_SECONDS = 2


def _validate_config():
    """Validate critical config values at import time."""
    if not KEEPER_PRIVATE_KEY:
        raise ValueError("KEEPER_PRIVATE_KEY must be set in .env")
    if not FACTORY_ADDRESS:
        raise ValueError("FACTORY_ADDRESS must be set in .env")
    if NETWORK not in NETWORKS:
        raise ValueError(f"NETWORK must be one of {list(NETWORKS.keys())}, got: {NETWORK}")


_validate_config()


def get_network_config():
    return NETWORKS[NETWORK]
