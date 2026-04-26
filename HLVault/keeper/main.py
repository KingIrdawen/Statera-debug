import asyncio
import time
import structlog

from config import LOOP_INTERVAL_SECONDS, HEARTBEAT_INTERVAL_SECONDS
from vault_manager import VaultManager

log = structlog.get_logger()


class Keeper:
    def __init__(self):
        self.vm = VaultManager()
        self._last_heartbeat_time = {}

    async def run_loop(self):
        """Main keeper loop. Calls advance*() in a loop for each vault."""
        while True:
            try:
                vaults = self.vm.get_all_vault_addresses()
                any_action = False

                for vault_addr in vaults:
                    acted = await self._process_vault(vault_addr)
                    if acted:
                        any_action = True

                if not any_action:
                    self._ping_all_if_needed(vaults)

            except Exception as e:
                log.error("loop_error", error=str(e))

            await asyncio.sleep(LOOP_INTERVAL_SECONDS)

    async def _process_vault(self, vault_address: str) -> bool:
        """Process a single vault. Returns True if an action was taken."""
        log.info("processing_vault", vault=vault_address)

        # Emergency takes priority
        if self.vm.is_emergency(vault_address):
            return self._try_advance_emergency(vault_address)

        # Try batch settlement (no-ops if nothing to settle)
        settled = self._try_advance_batch_settlement(vault_address)
        if settled:
            return True

        # Try rebalance (no-ops if balanced)
        return self._try_advance_rebalance(vault_address)

    def _try_advance_rebalance(self, vault_address: str) -> bool:
        try:
            self.vm.advance_rebalance(vault_address)
            log.info("advance_rebalance_ok", vault=vault_address)
            return True
        except Exception as e:
            log.debug("advance_rebalance_skip", vault=vault_address, reason=str(e))
            return False

    def _try_advance_batch_settlement(self, vault_address: str) -> bool:
        try:
            self.vm.advance_batch_settlement(vault_address)
            log.info("advance_batch_settlement_ok", vault=vault_address)
            return True
        except Exception as e:
            log.debug("advance_batch_settlement_skip", vault=vault_address, reason=str(e))
            return False

    def _try_advance_emergency(self, vault_address: str) -> bool:
        if self.vm.get_recovery_complete(vault_address):
            log.info("recovery_already_complete", vault=vault_address)
            return False

        try:
            self.vm.advance_emergency(vault_address)
            log.info("advance_emergency_ok", vault=vault_address)
            return True
        except Exception as e:
            log.debug("advance_emergency_skip", vault=vault_address, reason=str(e))
            return False

    def _ping_all_if_needed(self, vaults: list):
        """Ping heartbeat if no keeper action happened recently."""
        now = time.time()
        for vault_address in vaults:
            last = self._last_heartbeat_time.get(vault_address, 0)
            if now - last >= HEARTBEAT_INTERVAL_SECONDS:
                try:
                    self.vm.keeper_ping(vault_address)
                    self._last_heartbeat_time[vault_address] = now
                    log.info("heartbeat_pinged", vault=vault_address)
                except Exception as e:
                    log.error("heartbeat_ping_failed", vault=vault_address, error=str(e))


def main():
    structlog.configure(
        processors=[
            structlog.processors.TimeStamper(fmt="iso"),
            structlog.processors.add_log_level,
            structlog.dev.ConsoleRenderer(),
        ]
    )

    keeper = Keeper()
    asyncio.run(keeper.run_loop())


if __name__ == "__main__":
    main()
