# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Projet

**Statera** est un système de rebalancing vaults sur HyperEVM (Hyperliquid L1). Le repo est un monorepo avec deux sous-projets indépendants (repos git séparés) :

- **HLVault/** — Smart contracts Solidity (Foundry) + keeper Python off-chain
- **FrontEnd/** — Interface web Next.js pour interagir avec les vaults

Le vault accepte du HYPE natif, émet un share token ERC-20, et maintient un ratio cible (48% HYPE / 48% TOKEN / 4% USDC) via rebalance multi-phase orchestrée par un keeper Python.

## Architecture

### HLVault (Smart Contracts + Keeper)

**Contracts Solidity** (`src/`) — Framework Foundry, Solidity ^0.8.24, cible HyperEVM :
- `src/core/RebalancingVault.sol` — Vault principal (custom, PAS ERC-4626). Le vault EST le token (hérite ERC20)
- `src/core/VaultFactory.sol` — Factory pattern, un vault par token de contrepartie
- `src/libraries/` — Libs pour encoding CoreWriter, precompiles, bridge, décimales, prix, tailles
- `src/interfaces/` — ICoreWriter, IRebalancingVault, ICoreDepositWallet

**Tests** (`test/`) — Deux phases : Foundry mocks (rapide) + on-chain testnet (validation réelle)

**Keeper Python** (`keeper/`) — Boucle minimale appelant `advanceRebalance()`, `advanceBatchSettlement()`, `advanceEmergency()`, `keeperPing()`. Le contrat contient toute la logique ; le keeper ne fait qu'avancer les phases.

**Scripts** (`script/`) — Deploy scripts Foundry + scripts Python de test on-chain

### FrontEnd (Next.js)

Next.js 16 App Router, React 19, TypeScript, Tailwind CSS 4 :
- `src/components/vault/` — Composants métier : DepositCard, WithdrawCard, VaultStats, RedeemList, EmergencyBanner
- `src/hooks/` — Hooks wagmi : useVaultReads, useDeposit, useRequestRedeem, useClaimBatch, useUserPosition
- `src/constants/abis/` — ABIs des contrats (RebalancingVault, VaultFactory)
- `src/config/` — Config wagmi + définition des chains HyperEVM (testnet 998, mainnet 999)
- Web3 stack : wagmi v3, viem, RainbowKit, TanStack Query

## Commandes

### HLVault (depuis `HLVault/`)
```bash
forge build                        # Build contracts
forge test -vvv                    # Tests Foundry (mocks) — ~191 tests
forge test --match-contract <Name> -vvv  # Test spécifique

# Tests on-chain testnet
forge script script/TestOnChain.s.sol --rpc-url https://rpc.hyperliquid-testnet.xyz/evm --broadcast -vvv

# Deploy testnet
forge script script/Deploy.s.sol --rpc-url https://rpc.hyperliquid-testnet.xyz/evm --broadcast

# Keeper
cd keeper && python main.py
```

### FrontEnd (depuis `FrontEnd/`)
```bash
npm run dev      # Dev server (localhost:3000)
npm run build    # Build production
npm run lint     # ESLint
```

## Réseaux HyperEVM

| | Mainnet | Testnet |
|---|---|---|
| Chain ID | 999 | 998 |
| EVM RPC | https://rpc.hyperliquid.xyz/evm | https://rpc.hyperliquid-testnet.xyz/evm |
| HL API | https://api.hyperliquid.xyz | https://api.hyperliquid-testnet.xyz |

Les indices token/spot **diffèrent entre testnet et mainnet** — toujours résoudre dynamiquement via `POST /info {"type": "spotMeta"}`.

## Règles critiques (HLVault)

Le fichier `HLVault/CLAUDE.md` contient la spec complète. Points essentiels :

- **PAS d'ERC-4626** — HYPE natif + retraits async rendent ERC-4626 incompatible
- **CoreWriter non-atomique** — Les actions qui échouent sur HyperCore NE REVERT PAS la tx EVM. Toujours vérifier l'état au bloc L1 suivant
- **Precompiles** retournent l'état du DÉBUT du bloc EVM courant (pas les actions du même bloc)
- **Activer le compte Core** d'un vault avant le premier rebalance (sinon fonds bloqués en evmEscrows)
- **TOUJOURS utiliser GTC (tif=2)** pour les ordres d'achat — les IOC (tif=3) sont silencieusement rejetés
- **Conversion prix obligatoire** : precompile format → CoreWriter format (`* 10^szDecimals`)
- **Tick price** : max 5 chiffres significatifs
- **Mettre à jour `HLVault/DEPLOYMENTS.md`** à chaque déploiement

## Fichiers sensibles

- `.env.local` contient les secrets (clés privées, tokens) — **ne jamais committer**
- `FrontEnd/.env.local` — `NEXT_PUBLIC_WALLETCONNECT_PROJECT_ID`, `NEXT_PUBLIC_VAULT_FACTORY_ADDRESS`, etc.

## Statut

- Smart contracts : testnet déployé et vérifié (Phase 6), mainnet à faire
- Keeper : fonctionnel, testé multi-token sur testnet
- FrontEnd : en développement
