# CLAUDE.md — HLVault (HyperVault)

## Projet

Systeme de **rebalancing vaults** sur HyperEVM (Hyperliquid L1).
Accepte HYPE natif, emet un share token ERC-20, maintient un ratio cible (48% HYPE / 48% TOKEN / 4% USDC) via rebalance multi-phase orchestree par un keeper Python off-chain.

Spec complete : `HYPERVAULT_FINAL_V3.md`

## Stack technique

### Smart Contracts (Solidity)
- **Framework** : Foundry (forge, cast, anvil)
- **Deps** : OpenZeppelin (ERC-20, ReentrancyGuard, Pausable), hyper-evm-lib
- **Solidity** : ^0.8.24
- **Cible** : HyperEVM (chainId 999 mainnet, 998 testnet)

### Keeper (Python)
- web3.py, eth-account
- python-dotenv, structlog
- Python 3.11+

## Arborescence cible

```
src/
  core/
    RebalancingVault.sol       # Vault principal (custom, PAS ERC-4626)
    VaultFactory.sol           # Factory + owner/keeper global
  libraries/
    CoreActionLib.sol          # Encoding actions CoreWriter (IDs 1,6,7,10)
    PrecompileLib.sol          # Lecture precompiles (0x801, 0x807, 0x808, 0x80B, 0x80D)
    BridgeLib.sol              # Bridge EVM <-> Core
    DecimalLib.sol             # Conversions evm<->core decimals
    PriceLib.sol               # Tick size formatting (5 sig figs)
    SizeLib.sol                # Lot size formatting (szDecimals)
    SettlementLib.sol          # Ordres de settlement (sell TOKEN, buy HYPE)
  interfaces/
    ICoreWriter.sol
    IRebalancingVault.sol
test/
  RebalancingVault.t.sol
  BatchWithdraw.t.sol
  BatchSettlement.t.sol
  EmergencyMode.t.sol
  DecimalLib.t.sol
  StateMachine.t.sol
  SharePricing.t.sol
  mocks/
    MockPrecompile.sol
    MockCoreWriter.sol
script/
  Deploy.s.sol
  CreateVault.s.sol
keeper/
  main.py                # Boucle minimale: advance*() en boucle
  config.py              # Env config (network, keys, timing)
  vault_manager.py       # Web3 wrapper: advance*() + keeperPing
  abi/
  requirements.txt
  Dockerfile
  .env.example
```

## Conventions et regles critiques

### Architecture
- **PAS d'ERC-4626** : HYPE natif + retraits async rendent ERC-4626 incompatible
- **Vault custom + share ERC-20** : le vault EST le token (herite ERC20)
- **Pas d'upgradeability** en V1
- **Factory pattern** : un vault par token de contrepartie
- **Le keeper est le cerveau** : le contrat est un coffre-fort, logique on-chain minimale

### Decimales et unites
- Shares : 18 decimales (ERC-20 standard)
- Valorisation : USDC 8 decimales (weiDecimals USDC sur Core)
- HYPE EVM : 18 decimales (natif, comme ETH)
- SCALING_FACTOR : 1e18
- VIRTUAL_SHARES : 1e18, VIRTUAL_ASSETS : 1e8 (prix initial 1 USDC/share)

### Adresses systeme (identiques testnet/mainnet)
- CoreWriter : `0x3333333333333333333333333333333333333333`
- HYPE bridge : `0x2222222222222222222222222222222222222222`
- Token bridge : `0x2000...{tokenIndex big-endian hex}`
- Precompile base : `0x0800`
- Spot Balance : `0x801`, Spot Price : `0x808`, L1 Block Number : `0x809`
- Spot Info : `0x80B`, Token Info : `0x80C`, Token Supply : `0x80D`
- BBO : `0x80E`, Core User Exists : `0x810`

### Activation compte Core (CRITIQUE)
Les smart contracts doivent avoir leur compte Core **active** avant de pouvoir trader ou utiliser des fonds bridges. Sans activation :
- Les HYPE bridges restent bloques en `evmEscrows` (inutilisables)
- Les ordres CoreWriter sont acceptes sur EVM mais **silencieusement rejetes** sur Core
- Les spotSend vers le contrat echouent silencieusement

**Procedure d'activation :**
1. Un compte externe (EOA) envoie un **quote token** (USDC, USDT0, ou USDH) au contrat via `spotSend` (CoreWriter Action 6)
2. Le Core deduit automatiquement **1 USDC de fee** du sender
3. Le compte du contrat est active et les `evmEscrows` deviennent des balances utilisables
4. Verifiable via precompile `coreUserExists` (0x810) : retourne 0 ou 1

**Le keeper doit activer le compte Core de chaque nouveau vault apres deploiement.** Le wallet keeper doit avoir >= 1 USDC sur Core pour payer le fee.

### CoreWriter encoding
```
Byte 0    : 0x01 (version)
Bytes 1-3 : Action ID (big-endian uint24)
Bytes 4+  : abi.encode(params...)
```
- Action 1 : Limit Order (asset, isBuy, limitPx, sz, reduceOnly, tif, cloid)
- Action 6 : Spot Send (dest, tokenIndex, weiAmount)
- Action 7 : USD Class Transfer (ntl, toPerp)
- Action 10 : Cancel Order (asset, oid)
- Format : `limitPx = 1e8 * human_price`, `sz = 1e8 * human_size`, `asset = 10000 + spotMarketIndex`
- **TIF encoding** : 1=ALO (Add Liquidity Only), 2=GTC (Good Till Cancel), 3=IOC (Immediate Or Cancel)
- **TOUJOURS utiliser GTC (tif=2) pour les ordres d'achat** — les ordres IOC (tif=3) d'achat sont **silencieusement rejetes** par HyperCore sur le testnet (la tx EVM reussit mais l'ordre n'apparait jamais dans les fills). Les ordres IOC de vente fonctionnent normalement. A verifier si ce comportement persiste sur mainnet.
- **Min notional** : $10 USDC sur Core (`sz * px >= 1e9 * 10^(8-szDecimals)` en format interne)

### Conversion prix precompile → CoreWriter (CRITIQUE)
Le contrat recoit les prix en **format precompile** : `human_price * 10^(8 - szDecimals)`.
CoreWriter attend les prix en **format 1e8** : `human_price * 1e8`.

**Le contrat doit convertir avant d'envoyer a CoreWriter** :
```solidity
uint64 corePx = uint64(uint256(o.limitPx) * (10 ** szDecimals));
```

Sans cette conversion, pour HYPE (szDec=2) le prix envoye est **100x trop petit** et Core **rejette silencieusement** l'ordre car trop loin du mark price.

### Tick price formatting (CRITIQUE)
Les prix doivent respecter les regles de tick size Hyperliquid :
- **Max 5 chiffres significatifs** (ex: 11935 OK, 119350 OK, 1193500 OK, mais 11934700 INTERDIT)
- **Granularite minimum** = `10^szDecimals` en format precompile
- Le contrat verifie on-chain : `PriceLib.formatTickPrice(limitPx, szDecimals) == limitPx` → revert "invalid tick" sinon
- Le keeper doit **pre-formater** tous les prix avant de les soumettre

### Non-atomicite CoreWriter (CRITIQUE)
Les actions CoreWriter qui echouent sur HyperCore **NE REVERT PAS** la tx EVM. Le keeper doit :
1. Toujours verifier l'etat au bloc L1 suivant via precompiles (0x801, 0x80B)
2. Comparer les balances avant/apres pour confirmer qu'un trade a ete rempli
3. Ne jamais supposer qu'un ordre IOC a ete execute — verifier le delta de balance

### Precompiles
Retournent l'etat du DEBUT du bloc EVM courant. Les actions CoreWriter du meme bloc ne sont PAS reflétées. Attendre progression de `l1BlockNumber()`.

### Bridge
- HYPE EVM->Core : `payable(0x2222...).call{value: amount}("")`
- HYPE Core->EVM : CoreWriter Action 6, dest = 0x2222...
- Token EVM->Core : `IERC20.transfer(systemAddress, amount)`
- USDC EVM->Core : `approve()` puis `deposit()` sur CoreDepositWallet (PAS transfer!)

## Modele comptable

### grossAssets()
Somme en USDC_8DEC de :
1. HYPE sur Core (precompile 0x801)
2. HYPE sur EVM : `address(this).balance - reservedHypeForClaims`
3. Token counterpart sur Core
4. Token counterpart sur EVM (temporaire)
5. USDC sur Core
- USDC sur EVM : NON inclus en V1

### Variables critiques
- `escrowedShares` : shares en escrow (batches OPEN + PROCESSING)
- `reservedHypeForClaims` : HYPE EVM isole pour batches SETTLED
- `circulatingShares = totalSupply() - escrowedShares` (derive, pas stocke)

### sharePriceUsdc8
```
(grossAssets() + VIRTUAL_ASSETS) * SCALING_FACTOR / (totalSupply() + VIRTUAL_SHARES)
```

### Arrondis
- Mint shares : DOWN (protege le vault)
- Claim withdraw : DOWN (division entiere)
- Taille d'ordre : DOWN (regle Hyperliquid)
- Prix d'achat : UP (slippage)
- Prix de vente : DOWN (slippage)

## Batch withdrawals

Flow : `requestRedeem()` -> `advanceBatchSettlement()` x N [keeper] -> `claimBatch()` [user]

Le keeper appelle `advanceBatchSettlement()` en boucle. Phases internes :
```
NONE -> close batch + sell TOKEN -> AWAITING_SELL
     -> buy HYPE with USDC -> AWAITING_BUY
     -> bridge HYPE Core→EVM -> AWAITING_BRIDGE
     -> settle batch -> NONE
```

Si pas de TOKEN/USDC sur Core, les phases de trading sont sautees.

Settlement formula : `hypeAmount = req.shares * batch.totalHypeRecovered / batch.totalEscrowedShares`
(shares et HYPE tous les deux en 18 dec, pas de scaling supplementaire)

## State machine rebalance

Le keeper appelle `advanceRebalance()` en boucle. Phases internes :
```
IDLE -> BRIDGING_IN -> AWAITING_BRIDGE_IN -> TRADING -> AWAITING_TRADES
  -> BRIDGING_OUT -> AWAITING_BRIDGE_OUT -> FINALIZING -> IDLE
```

Exclusion mutuelle : pas de rebalance si batch PROCESSING ou settlement en cours.

## Emergency mode

3 types d'utilisateurs :
- A. Holders : shares dans wallet -> claimRecovery()
- B. Redeem pending : shares en escrow -> reclaimEscrowedShares() puis claimRecovery()
- C. Settled unclaimed : claimBatch() normalement

Le keeper appelle `advanceEmergency()` en boucle. Phases internes :
```
NONE -> sell TOKEN -> AWAITING_LIQUIDATION
     -> buy HYPE with USDC -> AWAITING_BUY_HYPE
     -> bridge HYPE Core→EVM -> AWAITING_BRIDGE
     -> finalize recovery -> NONE
```

Sequence : enterEmergency -> reclaimEscrowedShares (users B) -> advanceEmergency x N (keeper) -> claimRecovery (users A+B)

## Deploiement d'un nouveau vault (checklist)

1. Deployer `RebalancingVault` implementation + `VaultFactory`
2. `createVault()` avec les **bons indices** (resoudre via `POST /info {"type": "spotMeta"}`, PAS hardcoder)
3. **Activer le compte Core du vault** : le keeper envoie >= 1 USDC au vault via `spotSend` (CoreWriter Action 6)
4. Verifier activation via precompile `coreUserExists` (0x810) — doit retourner 1
5. Premier deposit (assez de HYPE pour depasser le min notional ~$10)
6. Premier rebalance : appeler `advanceRebalance()` en boucle et verifier que les phases avancent

## Ordre de developpement

1. ~~**Phase 1 - Fondations**~~ ✅ : Foundry setup, DecimalLib, PriceLib, SizeLib, PrecompileLib, CoreActionLib, BridgeLib + tests
2. ~~**Phase 2 - Vault Core**~~ ✅ : RebalancingVault (share token, deposit, batch withdrawal, state machine, emergency) + tests
3. ~~**Phase 3 - Factory**~~ ✅ : VaultFactory, deploy scripts, tests E2E
4. ~~**Phase 4 - Keeper Python**~~ ✅ : persistence, core_reader, rebalancer, batch_processor, price_checker
5. ~~**Phase 5 - Tests & Security**~~ ✅ : fuzzing, invariants, simulation testnet (168 tests, E2E verifie)
6. **Phase 6 - Deploy** : testnet ✅ (verifie) → mainnet (a faire)
   - Avant mainnet : remettre SLIPPAGE_CAP_BPS a 500, MIN_REBALANCE_NOTIONAL_USD a 50

## Tests — Deux phases : Foundry (mocks) + On-chain (testnet)

### Phase 1 : Tests Foundry avec mocks (rapide, exhaustif)
Tests unitaires, integration, invariants avec MockPrecompile, MockCoreWriter, ERC20Mock.
Valident la logique, les edge cases, la state machine, les calculs de prix/taille.
```bash
forge test -vvv
```

### Phase 2 : Tests on-chain sur testnet (validation reelle)
Scripts Foundry deployes sur le vrai testnet HyperEVM via `forge script --broadcast`.
Valident que tout fonctionne avec les vrais precompiles, le vrai CoreWriter, les vrais tokens.
Les precompiles HyperEVM (0x801, 0x808, 0x80B) sont des system precompiles (pas de bytecode EVM),
elles ne fonctionnent PAS dans un fork Foundry — il faut executer directement sur le testnet.

```bash
forge script script/TestOnChain.s.sol --rpc-url https://rpc.hyperliquid-testnet.xyz/evm --broadcast -vvv
```

### Tokens testnet pour les tests multi-token
Resoudre via `POST /info {"type": "spotMeta"}` sur `https://api.hyperliquid-testnet.xyz`.

Tokens avec liquidite confirmee (2026-03-14) :

| Token | tokenIndex | szDecimals | weiDecimals | spotMarketIndex | prix approx | evmContract |
|---|---|---|---|---|---|---|
| PURR | 1 | 0 | 5 | 0 | N/A | 0xa9056c15938f9aff34cd497c722ce33db0c2fd57 |
| BARK | 242 | 0 | 5 | 218 | $0.063 | 0x66cafdad96b087187bd7875c7efe49a4bb1d388c |
| DANK | 1262 | 1 | 6 | 1162 | $3.17 | 0x728e20cde0f8b52d2b73d67e236611dbae835a78 |
| SOVY | 1158 | 1 | 8 | 1080 | $1.20 | 0x674d61f547ae1595f81369f7f37f7400c1210444 |
| ZIGG | 1048 | 2 | 8 | 980 | $0.11 | 0xe073a3e64423ce020716cd641dfd489c3b644620 |
| JNZ | 1031 | 2 | 8 | 1458 | $1.30 | 0x43ba7e2e99c05ac0829c16cb514e06eb82e88885 |
| UETH | 1242 | 4 | 9 | 1137 | $650 | 0x5a1a1339ad9e52b7a4df78452d5c18e8690746f3 |
| UNIT | 1129 | 5 | 10 | 1054 | $16249 | 0x09f83c5052784c63603184e016e1db7a24626503 |
| HYPE | 1105 | 2 | 8 | 1035 | $100 | natif |

## Commandes

```bash
# Build
forge build

# Phase 1 : Tests Foundry (mocks)
forge test -vvv

# Phase 1 : Tests specifiques
forge test --match-contract DecimalLibTest -vvv
forge test --match-contract MultiTokenRebalanceTest -vvv

# Phase 2 : Tests on-chain testnet
forge script script/TestOnChain.s.sol --rpc-url https://rpc.hyperliquid-testnet.xyz/evm --broadcast -vvv

# Deploy testnet
forge script script/Deploy.s.sol --rpc-url https://rpc.hyperliquid-testnet.xyz/evm --broadcast

# Keeper
cd keeper && python main.py
```

## Reseau

| | Mainnet | Testnet |
|---|---|---|
| Chain ID | 999 | 998 |
| EVM RPC | https://rpc.hyperliquid.xyz/evm | https://rpc.hyperliquid-testnet.xyz/evm |
| HL API | https://api.hyperliquid.xyz | https://api.hyperliquid-testnet.xyz |

Token indices resolus dynamiquement via `POST /info {"type": "spotMeta"}`.

## Tokens connus (mainnet)

| Token | tokenIndex | szDecimals | weiDecimals | EVM decimals | spot pair index |
|---|---|---|---|---|---|
| USDC | 0 | 8 | 8 | 6 | - |
| PURR | 1 | 0 | 5 | variable | 0 |
| HYPE | 150 | 2 | 8 | 18 (natif) | 107 |

## Tokens connus (testnet)

| Token | tokenIndex | szDecimals | weiDecimals | spot pair index |
|---|---|---|---|---|
| USDC | 0 | 8 | 8 | - |
| HYPE | 1105 | 2 | 8 | 1035 |
| UETH | 1242 | 4 | 9 | 1137 |

**ATTENTION** : les indices testnet/mainnet sont completement differents. Toujours resoudre via `POST /info {"type": "spotMeta"}`.

## Invariants a maintenir

- `totalSupply() == circulatingShares + escrowedShares`
- `address(this).balance >= reservedHypeForClaims`
- Pour chaque batch settled : `remainingHype <= totalHypeRecovered`
- Pour chaque batch settled : `claimedShares <= totalEscrowedShares`

## Pieges a eviter

- **Mettre a jour `DEPLOYMENTS.md`** a chaque deploiement (factory, vault, ou implementation) avec l'adresse, la date et la version. Ce fichier est la source de verite pour les adresses deployees.
- Tests en 2 phases : Phase 1 = Foundry avec mocks (logique), Phase 2 = on-chain testnet (validation reelle)
- Ne JAMAIS utiliser ERC-4626
- Ne PAS supposer qu'une action CoreWriter a reussi dans le meme bloc
- Ne PAS confondre L1 block et EVM block pour les verifications post-action
- Ne PAS bridge USDC via transfer() -> utiliser approve() + deposit() sur CoreDepositWallet
- Ne PAS utiliser de `totalShareSupply` separe -> utiliser `totalSupply()` d'ERC-20
- Ne PAS ajouter de scaling 1e18 dans la formule de settlement (shares et HYPE sont deja en 18 dec)
- `reservedHypeForClaims` doit TOUJOURS etre soustrait du balance EVM dans grossAssets
- Slippage cap : hard cap 15% testnet (SLIPPAGE_CAP_BPS = 1500), hard cap 5% mainnet (500), default 2% (200 bps)
- Max deposit par tx configurable (anti-manipulation NAV)
- **TOUJOURS activer le compte Core** d'un vault avant le premier rebalance (sinon les fonds bridges sont bloques en evmEscrows)
- Les indices token/spot **different entre testnet et mainnet** — toujours resoudre dynamiquement via `POST /info {"type": "spotMeta"}`
- Le prix precompile spot (0x808) peut etre **desynchro** du prix reel du marche — le keeper doit verifier les prix via l'API avant de trader
- **Prix spot ≠ prix perp** : sur testnet HYPE spot ~$116 vs perp ~$34 — le keeper doit utiliser le mid du marche spot (`@{spotMarketIndex}` dans allMids), PAS le prix perp
- **Tick price** : les prix doivent avoir max 5 chiffres significatifs — `38034700` est invalide, `38034000` ou `38035000` sont valides
- **Conversion prix** : le contrat recoit en format precompile (`human * 10^(8-szDec)`) et convertit en format CoreWriter (`human * 1e8`) avant envoi. Sans conversion, les ordres sont silencieusement rejetes par Core
- **API keeper simplifiee** : le keeper n'appelle que `advanceRebalance()`, `advanceBatchSettlement()`, `advanceEmergency()` et `keeperPing()` en boucle. Toute la logique de prix/ordres/bridging est on-chain
- **Min notional contrat** : `sz * limitPx >= 1e9 * 10^(8-szDecimals)` — pour HYPE (szDec=2) il faut ~$10 de notional minimum
- **Min assets vault pour rebalancing** : le vault doit avoir au moins ~$21 d'actifs totaux pour que l'allocation cible de 48% (~$10) depasse le min notional de $10 par ordre. En dessous, `advanceRebalance()` skip silencieusement (retour a IDLE sans trades)
- **Dependance intra-bloc sell/buy** : quand le vault vend HYPE et achete TOKEN dans le meme bloc L1, l'achat TOKEN peut echouer car le USDC issu de la vente HYPE n'est pas encore disponible sur Core. Non-deterministe (fonctionne parfois). Un 2eme cycle de rebalance corrige le probleme car le USDC est alors disponible. Amelioration future : separer sell/buy en phases distinctes (blocs L1 differents)
- **Divergence prix precompile vs API mid** : precompile 0x808 retourne le bid ($70 HYPE testnet) tandis que l'API mid retourne la moyenne bid/ask ($100). Le vault trade correctement aux prix precompile mais la verification externe par API montre des allocations apparemment desequilibrees

## Statut E2E testnet

### Phase 1 : Single-token (verifie 2026-03-12)
Cycle complet verifie dans les deux directions :
- **Achat** : 0.10 HYPE achete @ $119.08 (rempli sur Core)
- **Vente** : 0.10 HYPE vendu @ $113.19 (rempli sur Core)
- **8 phases** : startRebalance → executeBridgeIn → confirmBridgeIn → executeTrades → confirmTrades → executeBridgeOut → confirmBridgeOut → finalizeCycle

### Phase 2 : Multi-token (verifie 2026-03-15)
Test `advanceRebalance()` autonome sur 3 tokens avec differents szDecimals :

| Token | szDec | Resultat | Details |
|---|---|---|---|
| SOVY | 1 | **SUCCESS** (1 cycle, 4 appels) | 8.4 SOVY + 0.39 USDC sur Core |
| BARK | 0 | **SUCCESS** (2 cycles, 8 appels) | 170.88 BARK + 0.46 USDC sur Core — 1er cycle: vente HYPE OK mais achat BARK echoue (USDC pas encore dispo intra-bloc), 2eme cycle: achat reussi |
| ZIGG | 2 | **NON TESTE** | Fonds insuffisants ($7.25 < $21 minimum) |

**Decouverte critique** : les ordres IOC (tif=3) d'achat sont silencieusement rejetes par HyperCore. Fix applique : `uint8(3)` → `uint8(2)` (GTC) dans `_processAndSendOrder()`. Les ordres IOC de vente fonctionnent normalement.

### Audit 2026-04-03 — Bugs corriges
1. **PrecompileLib L1 Block** : adresse corrigee de `0x80B` (SPOT_INFO) a `0x809` (L1_BLOCK_NUMBER)
2. **PrecompileLib SPOT_ASSET_INFO** : adresse corrigee de `0x80D` (TOKEN_SUPPLY) a `0x80C` (TOKEN_INFO)
3. **Settlement pro-rata** : `_finalizeSettlement()` donnait TOUT le HYPE libre au batch au lieu du pro-rata. Fix : `batchHype = freeHype * batch.totalEscrowedShares / totalSupply()`
4. **PriceLib integer prices** : les prix entiers sont maintenant exemptes de la limite de 5 chiffres significatifs (regle Hyperliquid)

- **203 tests Foundry** passent (unit + integration + invariant)

### Contrats deployes (testnet, version GTC fix — 2026-03-15)
- Implementation : `0xc543833c778150823B69e147A18Ec42e3a4679A5`
- Factory (ancienne) : `0x851489d96D561C1c149cC32e8bb5Bb149e2061D0`
- Factory (GTC fix) : `0xaA10D8C30e6226356D61E0ca88c8d1B0e6df20AE`
- Vault SOVY : `0x22276e9562e38c309f8Dedf8f1fB405297560da7`
- Vault BARK : `0x720021b106B42a625c1dC2322214A3248A09bb6a`
- Vault ZIGG : `0x66e880e2bd93243569B985499aD00Df543a77554`
- RPC Chainstack : `https://hyperliquid-testnet.core.chainstack.com/98107cd968ac1c4168c442fa6b1fe200/evm`
