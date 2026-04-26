import json
import time
import structlog
from pathlib import Path
from web3 import Web3
from eth_account import Account

from config import get_network_config, KEEPER_PRIVATE_KEY, FACTORY_ADDRESS, TX_RETRY_ATTEMPTS, TX_RETRY_DELAY_SECONDS

log = structlog.get_logger()

ABI_DIR = Path(__file__).parent / "abi"


def _load_abi(name):
    path = ABI_DIR / f"{name}.json"
    if not path.exists():
        raise FileNotFoundError(f"ABI file not found: {path}")
    with open(path) as f:
        data = json.load(f)
    if isinstance(data, dict) and "abi" in data:
        return data["abi"]
    return data


class VaultManager:
    """Minimal Web3 wrapper — only advance*() + keeperPing + reads."""

    def __init__(self):
        cfg = get_network_config()
        self.w3 = Web3(Web3.HTTPProvider(cfg["evm_rpc"]))
        self.account = Account.from_key(KEEPER_PRIVATE_KEY)
        self.chain_id = cfg["chain_id"]

        factory_abi = _load_abi("VaultFactory")
        self.factory = self.w3.eth.contract(
            address=Web3.to_checksum_address(FACTORY_ADDRESS),
            abi=factory_abi,
        )

        self.vault_abi = _load_abi("RebalancingVault")
        self._vaults = {}
        self._nonce = None

    def _get_nonce(self):
        if self._nonce is None:
            self._nonce = self.w3.eth.get_transaction_count(self.account.address)
        nonce = self._nonce
        self._nonce += 1
        return nonce

    def _reset_nonce(self):
        self._nonce = self.w3.eth.get_transaction_count(self.account.address)

    def get_vault(self, address):
        address = Web3.to_checksum_address(address)
        if address not in self._vaults:
            self._vaults[address] = self.w3.eth.contract(
                address=address, abi=self.vault_abi
            )
        return self._vaults[address]

    def get_all_vault_addresses(self):
        count = self.factory.functions.vaultCount().call()
        return [self.factory.functions.allVaults(i).call() for i in range(count)]

    # ═══ Read methods ═══

    def is_emergency(self, vault_address):
        return self.get_vault(vault_address).functions.isEmergency().call()

    def get_recovery_complete(self, vault_address):
        return self.get_vault(vault_address).functions.recoveryComplete().call()

    # ═══ Write methods (the 3 advance + ping) ═══

    def _send_tx(self, fn, value=0):
        last_error = None
        for attempt in range(TX_RETRY_ATTEMPTS):
            try:
                nonce = self._get_nonce()
                try:
                    gas_estimate = fn.estimate_gas({
                        "from": self.account.address,
                        "value": value,
                    })
                    gas = int(gas_estimate * 1.3)
                except Exception:
                    gas = 2_000_000

                tx = fn.build_transaction({
                    "from": self.account.address,
                    "nonce": nonce,
                    "gas": gas,
                    "gasPrice": self.w3.eth.gas_price,
                    "chainId": self.chain_id,
                    "value": value,
                })
                signed = self.account.sign_transaction(tx)
                tx_hash = self.w3.eth.send_raw_transaction(signed.raw_transaction)
                receipt = self.w3.eth.wait_for_transaction_receipt(tx_hash, timeout=120)
                log.info("tx_sent", tx_hash=tx_hash.hex(), status=receipt["status"])
                if receipt["status"] != 1:
                    raise RuntimeError(f"Transaction reverted: {tx_hash.hex()}")
                return receipt
            except Exception as e:
                last_error = e
                err_msg = str(e).lower()
                log.warn(
                    "tx_attempt_failed",
                    attempt=attempt + 1,
                    max_attempts=TX_RETRY_ATTEMPTS,
                    error=str(e),
                )
                if "nonce too low" not in err_msg and "already known" not in err_msg:
                    self._reset_nonce()
                if attempt < TX_RETRY_ATTEMPTS - 1:
                    time.sleep(TX_RETRY_DELAY_SECONDS)

        raise last_error

    def advance_rebalance(self, vault_address):
        vault = self.get_vault(vault_address)
        return self._send_tx(vault.functions.advanceRebalance())

    def advance_batch_settlement(self, vault_address):
        vault = self.get_vault(vault_address)
        return self._send_tx(vault.functions.advanceBatchSettlement())

    def advance_emergency(self, vault_address):
        vault = self.get_vault(vault_address)
        return self._send_tx(vault.functions.advanceEmergency())

    def keeper_ping(self, vault_address):
        vault = self.get_vault(vault_address)
        return self._send_tx(vault.functions.keeperPing())
