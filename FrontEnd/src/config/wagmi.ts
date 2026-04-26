import { getDefaultConfig } from "@rainbow-me/rainbowkit";
import { hyperEvmTestnet, hyperEvmMainnet } from "./chains";

export const config = getDefaultConfig({
  appName: "HLVault",
  projectId: process.env.NEXT_PUBLIC_WALLETCONNECT_PROJECT_ID ?? "demo",
  chains: [hyperEvmTestnet, hyperEvmMainnet],
  ssr: true,
});
