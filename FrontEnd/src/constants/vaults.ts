export const TESTNET_VAULTS = [
  { address: "0x22276e9562e38c309f8Dedf8f1fB405297560da7" as const, label: "SOVY" },
  { address: "0x720021b106B42a625c1dC2322214A3248A09bb6a" as const, label: "BARK" },
  { address: "0x66e880e2bd93243569B985499aD00Df543a77554" as const, label: "ZIGG" },
] as const;

export const DEFAULT_VAULT = TESTNET_VAULTS[0];
