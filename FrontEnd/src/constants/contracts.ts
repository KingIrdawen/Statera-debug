import { rebalancingVaultAbi } from "./abis/RebalancingVault";
import { vaultFactoryAbi } from "./abis/VaultFactory";

export const VAULT_FACTORY_ADDRESS =
  (process.env.NEXT_PUBLIC_VAULT_FACTORY_ADDRESS as `0x${string}`) ??
  "0xaA10D8C30e6226356D61E0ca88c8d1B0e6df20AE";

export { rebalancingVaultAbi, vaultFactoryAbi };
