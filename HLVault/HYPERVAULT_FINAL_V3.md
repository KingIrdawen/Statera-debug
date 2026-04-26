# HyperVault — Plan de Développement V3 (Final)
## Système de Rebalancing Vault sur Hyperliquid EVM

> **Objectif** : Ce document contient TOUTES les spécifications techniques nécessaires pour coder le projet. Il est destiné à être consommé par un agent de code (Claude Code) sans besoin de recherche supplémentaire.
>
> **V3** : Version finale après 3 itérations. Architecture solide (V1→V2), précision comptable corrigée (V2→V3). Vault custom ERC-20 shares, batch withdrawals, keeper Python orchestrateur, state machine explicite.

---
## 1. VISION DU PROJET

### 1.1 Concept
Un système de **vaults de rebalancing** déployé sur HyperEVM qui :
1. Accepte des dépôts en **HYPE** (token natif) sur HyperEVM
2. Émet un **token ERC-20 liquide** (share token) représentant la part de l'utilisateur
3. Maintient les assets principalement sur **HyperCore** pour le trading
4. Maintient un **ratio cible** via une fonction de rebalance multi-phase :
   - **48% HYPE**
   - **48% token de contrepartie** (ex: PURR, JEFF, etc.)
   - **4% USDC** (réserve de liquidité/gas)
5. Utilise un **Factory Pattern** : un vault par token de contrepartie

### 1.2 Décisions Architecturales Clés

| Décision | Choix | Justification |
|---|---|---|
| Standard vault | **Vault custom + share ERC-20** (PAS ERC-4626) | HYPE natif + retraits async rendent ERC-4626 incompatible |
| Retraits | **Batch withdrawal** | Évite optionalité gratuite, prix locké, et bugs de re-mint |
| Retrait en nature | **HYPE uniquement** | Simplifie la logique, le keeper vend TOKEN → USDC → HYPE |
| Frais | **Aucun (V1)** | Simplicité, adoption |
| Où vivent les assets | **Principalement sur HyperCore** | Pas de bridge retour routinier, seulement pour les withdrawals |
| Logique on-chain | **Minimale** : coffre-fort + règles + comptabilité | Le keeper est le cerveau (calculs, séquencement, retries) |
| Upgradeability | **Non (V1)** | Simplifie l'audit |
| Unité de valorisation | **USDC en 10^8** (weiDecimals USDC sur Core) | Tous les prix spot sont en USDC sur Hyperliquid |
| Premier dépôt | **Virtual shares/assets** pour éviter donation attack | `VIRTUAL_SHARES = 1e18`, `VIRTUAL_ASSETS = 1e8` → 1 USDC/share initial |

### 1.3 Architecture Globale

```
┌─────────────────────────────────────────────────────────┐
│                    HyperEVM Layer                         │
│                                                           │
│  ┌──────────────┐    ┌────────────────────────────────┐  │
│  │ VaultFactory │───>│ RebalancingVault (clone)        │  │
│  │              │    │  - Share token ERC-20            │  │
│  │ createVault()│    │  - deposit() payable            │  │
│  └──────────────┘    │  - requestRedeem(shares)        │  │
│                      │  - claimBatch(redeemId)         │  │
│                      │  - Accounting: grossAssets,     │  │
│                      │    reservedHypeForClaims        │  │
│                      │  - Rebalance state machine      │  │
│                      └─────────┬──────────────────────┘  │
│                                │                          │
│               Bridge: HYPE → 0x2222...2222               │
│               Bridge: Token → 0x2000...{idx}             │
└────────────────────────────────┼──────────────────────────┘
                                 │
┌────────────────────────────────┼──────────────────────────┐
│               HyperCore Layer (L1)                         │
│   Assets principaux restent ICI                            │
│                                                            │
│   ┌──────────────────┐  ┌──────────────────────────────┐  │
│   │  Spot Order Book │  │  CoreWriter (0x3333...3333)   │  │
│   │  HYPE/USDC       │  │  - Limit Order IOC (ID=1)    │  │
│   │  TOKEN/USDC      │  │  - Spot Send (ID=6)          │  │
│   └──────────────────┘  └──────────────────────────────┘  │
│                                                            │
│   ┌──────────────────────────────────────────────────┐    │
│   │  Read Precompiles                                 │    │
│   │  0x801: spotBalance  │ 0x808: spotPx              │    │
│   │  0x807: oraclePx     │ 0x80B: l1BlockNumber       │    │
│   └──────────────────────────────────────────────────┘    │
└────────────────────────────────────────────────────────────┘

┌────────────────────────────────────────────────────────────┐
│              Keeper Python (off-chain)                       │
│  = LE CERVEAU                                               │
│  - Calcule le plan de rebalance                             │
│  - Lit l'API HyperCore + precompiles + L2 book              │
│  - Orchestre les phases (bridge, trade, settle)             │
│  - Traite les batches de withdrawals                        │
│  - Persiste son état (SQLite)                               │
│  - Gère les retries et alertes                              │
└────────────────────────────────────────────────────────────┘
```

---

## 2. DOCUMENTATION TECHNIQUE HYPERLIQUID

### 2.1 Adresses Système (identiques testnet/mainnet)

| Élément | Adresse |
|---|---|
| **CoreWriter** | `0x3333333333333333333333333333333333333333` |
| **HYPE bridge (EVM→Core)** | `0x2222222222222222222222222222222222222222` |
| **Token bridge** | `0x2000...{tokenIndex big-endian hex}` |
| **Precompile base** | `0x0000000000000000000000000000000000000800` |

### 2.2 Read Precompiles (L1Read)

Les precompiles retournent l'état HyperCore au **début du bloc EVM courant**.

**Adresses et signatures Solidity exactes :**

```solidity
// 0x801 — Spot Balance
// Input:  abi.encode(address user, uint32 tokenIndex)
// Output: abi.decode -> (uint64 total, uint64 hold, uint64 entryNtl)
// Usage:
(bool ok, bytes memory data) = address(0x0000000000000000000000000000000000000801)
    .staticcall(abi.encode(user, tokenIndex));
require(ok, "precompile failed");
(uint64 total, uint64 hold, ) = abi.decode(data, (uint64, uint64, uint64));
// total est en weiDecimals du token (variable par token)
// hold est le montant en ordres ouverts

// 0x808 — Spot Price
// Input:  abi.encode(uint32 spotMarketIndex)
// Output: uint64 rawPrice
// Conversion: prix_humain = rawPrice / 10^(8 - baseSzDecimals)
// En USDC 10^8: prix_usdc_8dec = rawPrice * 10^baseSzDecimals
(bool ok, bytes memory data) = address(0x0000000000000000000000000000000000000808)
    .staticcall(abi.encode(spotMarketIndex));
uint64 rawPrice = abi.decode(data, (uint64));

// 0x807 — Oracle Price (perps)
// Input:  abi.encode(uint32 perpIndex)
// Output: uint64 rawPrice
// Conversion: prix_humain = rawPrice / 10^(6 - szDecimals)

// 0x80B — L1 Block Number
// Input:  (rien, bytes vides ou 0)
// Output: uint64 l1Block

// 0x80D — Spot Asset Info
// Input:  abi.encode(uint32 tokenIndex)
// Output: (uint8 weiDecimals, address evmContract)
```

**Gas des precompiles :** `2000 + 65 * (input_len + output_len)`

**⚠️ IMPORTANT :** Les precompiles renvoient l'état du **début du bloc**. Les actions CoreWriter envoyées dans le même bloc ne sont PAS reflétées. Il faut attendre une progression du `l1BlockNumber()`.

### 2.3 CoreWriter — Actions d'Écriture

Le CoreWriter (`0x3333...3333`) émet un event `RawAction` interprété par HyperCore.

**Interface CoreWriter :**
```solidity
interface ICoreWriter {
    function sendRawAction(bytes calldata data) external;
}
```

**Encoding :**
```
Byte 0    : Version = 0x01
Bytes 1-3 : Action ID (big-endian uint24)
Bytes 4+  : abi.encode(params...)
```

**⚠️ CRITIQUE — NON-ATOMICITÉ :**
Si l'action échoue sur HyperCore (pas de marge, prix invalide, taille trop petite), la transaction EVM **NE REVERT PAS**. Le contrat ne peut pas savoir si l'action a réussi dans le même bloc. Il faut vérifier l'état au bloc L1 suivant.

**Actions utilisées :**

| ID | Action | Params Solidity | Notes |
|---|---|---|---|
| 1 | Limit Order | `(uint32 asset, bool isBuy, uint64 limitPx, uint64 sz, bool reduceOnly, uint8 tif, uint128 cloid)` | asset = 10000+spotIdx pour spot. limitPx et sz = 10^8 * human. tif: 1=ALO, 2=GTC, 3=IOC |
| 6 | Spot Send | `(address dest, uint64 tokenIndex, uint64 weiAmount)` | Pour bridge Core→EVM: dest = system address. **Requiert HYPE sur Core pour gas.** |
| 7 | USD Class Transfer | `(uint64 ntl, bool toPerp)` | Transfert USDC spot ↔ perp |
| 10 | Cancel Order | `(uint32 asset, uint64 oid)` | Cancel par order ID |

**Pattern d'encoding :**
```solidity
function _sendCoreAction(uint24 actionId, bytes memory params) internal {
    bytes memory data = new bytes(4 + params.length);
    data[0] = 0x01;
    data[1] = uint8(actionId >> 16);
    data[2] = uint8(actionId >> 8);
    data[3] = uint8(actionId);
    for (uint256 i = 0; i < params.length; i++) {
        data[4 + i] = params[i];
    }
    ICoreWriter(0x3333333333333333333333333333333333333333).sendRawAction(data);
}
```

### 2.4 Bridge EVM ↔ Core

```solidity
// HYPE: EVM → Core
(bool ok,) = payable(0x2222222222222222222222222222222222222222).call{value: amount}("");

// HYPE: Core → EVM — via CoreWriter Action 6 (Spot Send)
// dest = 0x2222...2222, tokenIndex = hypeTokenIndex, wei = montant

// Token ERC-20: EVM → Core
IERC20(tokenAddr).transfer(systemAddress, amount);
// systemAddress = 0x2000...{tokenIndex big-endian hex}

// Token ERC-20: Core → EVM — via CoreWriter Action 6
// dest = system address du token. ⚠️ Requiert HYPE sur Core pour gas.

// USDC: EVM → Core — SPÉCIAL
// 1. Approve l'adresse CoreDepositWallet
// 2. Appeler deposit(uint256 amount) sur CoreDepositWallet
// NE PAS faire un simple transfer() !
// CoreDepositWallet address: récupérer via spotMeta API → evmContract.address pour USDC
```

**Ordre de traitement :** `L1 block → EVM block → EVM→Core transfers → CoreWriter actions`

### 2.5 Asset IDs, Tick & Lot Size

**Asset IDs :**
- Spot : `10000 + spotMeta.universe[].index`
- Exemple mainnet : HYPE/USDC → pair index 107 → `asset = 10107`

**Tokens connus mainnet (à résoudre dynamiquement sur testnet) :**
| Token | tokenIndex | szDecimals | weiDecimals | EVM decimals | spot pair index |
|---|---|---|---|---|---|
| USDC | 0 | 8 | 8 | 6 | — |
| PURR | 1 | 0 | 5 | variable | 0 |
| HYPE | 150 | 2 | 8 | 18 (natif) | 107 |

**Récupération dynamique :**
```
POST https://api.hyperliquid.xyz/info
Body: {"type": "spotMeta"}
→ tokens[]: {name, szDecimals, weiDecimals, index, tokenId, evmContract}
→ universe[]: {name, tokens: [baseIdx, quoteIdx], index}
```

**Tick Size (prix spot) :**
- Max 5 significant figures
- Max `8 - szDecimals` decimal places
- Entiers toujours valides
- **Format CoreWriter :** `limitPx = 10^8 * prix_humain_formaté`

**Lot Size (taille) :**
- Arrondi **DOWN** à `szDecimals` décimales
- **Format CoreWriter :** `sz = 10^8 * taille_humaine_formatée`
- **Minimum order :** notionnel ≈ $10 minimum

---

### 2.7 Bridge USDC — Clarification

> **⚠️ DISCLAIMER** : La séquence ci-dessous est basée sur la documentation publique et l'analyse
> du code hyper-evm-lib. Le champ exact `evmContract` dans la réponse `spotMeta` doit être
> vérifié en testnet avant déploiement mainnet. L'ABI de `deposit()` peut évoluer.

### 7.1 Adresses et Séquence

```
1. Récupérer l'adresse CoreDepositWallet :
   POST https://api.hyperliquid.xyz/info
   Body: {"type": "spotMeta"}
   → Chercher tokens[].name == "USDC"
   → Le champ tokens[].evmContract contient un objet avec :
     - address: adresse du CoreDepositWallet (PAS le token USDC natif)
   
   ⚠️ L'adresse USDC ERC-20 native sur HyperEVM est DIFFÉRENTE du CoreDepositWallet.
   Le USDC ERC-20 natif est celui utilisé dans les DEX EVM.
   Le CoreDepositWallet est le contrat spécial pour bridge vers Core.

2. Séquence pour bridge USDC EVM → Core :
   a. Obtenir l'adresse du USDC ERC-20 natif (ex: via un DEX ou config)
   b. IERC20(usdcNativeEvm).approve(coreDepositWalletAddress, amount)
   c. ICoreDepositWallet(coreDepositWalletAddress).deposit(amount)
   → Le USDC est crédité sur HyperCore au prochain bloc L1

3. Séquence pour bridge USDC Core → EVM :
   Via CoreWriter Action 6 (Spot Send) :
   - destination = system address USDC = 0x2000000000000000000000000000000000000000
     (token index 0 → big-endian = 0x00)
   - tokenIndex = 0
   - weiAmount = montant en USDC weiDecimals (8)
   
   ⚠️ Le vault doit détenir du HYPE sur Core pour payer le gas du spotSend.
```

### 7.2 ABI CoreDepositWallet

```solidity
// Interface minimale — la fonction exacte est deposit(uint256)
interface ICoreDepositWallet {
    function deposit(uint256 amount) external;
}
```

---

## 3. MODÈLE COMPTABLE (V3)

### 3.1 Conventions Fondamentales

```
SHARE_DECIMALS       = 18              (comme tout ERC-20 standard)
VALUATION_DECIMALS   = 8               (USDC sur HyperCore = 8 weiDecimals)
HYPE_EVM_DECIMALS    = 18              (natif, comme ETH)
SCALING_FACTOR       = 1e18            (pour divisions sans perte de précision)
```

**Unité de valorisation :** Toutes les NAV en `USDC_8DEC` (uint256, 8 décimales).
**Unité de shares :** `SHARE_WEI` (uint256, 18 décimales). `1 share = 1e18 share_wei`.

### 3.2 Variables Comptables

```solidity
// ═══ PAS de totalShareSupply séparé. On utilise les fonctions ERC-20. ═══

uint256 public escrowedShares;           // Shares en escrow (batches OPEN + PROCESSING)
uint256 public reservedHypeForClaims;    // HYPE 18dec sur EVM, réservé aux batches SETTLED

// Dérivés (pas stockés, calculés) :
// circulatingShares   = totalSupply() - escrowedShares
// availableHypeEvm    = address(this).balance - reservedHypeForClaims
// NOTE: grossAssets() exclut DÉJÀ reservedHypeForClaims du HYPE EVM compté.
//       Ne PAS soustraire reservedHypeForClaims une seconde fois.
```

### 3.3 Protection Premier Dépôt

```solidity
uint256 constant VIRTUAL_SHARES = 1e18;  // 1 share virtuel
uint256 constant VIRTUAL_ASSETS = 1e8;   // 1 USDC virtuel (8 dec)
// → Prix initial : 1 USDC / share. Clean.
```

### 3.4 Calcul de grossAssets (COMPLET)

```solidity
/// @notice Valeur totale de TOUS les assets détenus par le vault, en USDC_8DEC
/// @dev Inclut Core + EVM, tous les tokens
function grossAssets() public view returns (uint256 totalUsdc8) {
    uint64 hypePx  = _getSpotPrice(hypeSpotMarketIndex);
    uint64 tokenPx = _getSpotPrice(counterpartSpotMarketIndex);
    
    // HYPE sur Core (weiDecimals = 8, szDecimals = 2)
    (uint64 hypeCoreTotal, ) = _getSpotBalance(address(this), hypeTokenIndex);
    totalUsdc8 += _toUsdc8(hypeCoreTotal, hypeWeiDecimals, hypePx, hypeSzDecimals);
    
    // HYPE sur EVM (18 dec natif) — seulement la part NON réservée
    uint256 hypeEvmAvailable = address(this).balance - reservedHypeForClaims;
    uint64 hypeEvmCore = DecimalLib.evmToCore(hypeEvmAvailable, 18, hypeWeiDecimals);
    totalUsdc8 += _toUsdc8(hypeEvmCore, hypeWeiDecimals, hypePx, hypeSzDecimals);
    
    // Token counterpart sur Core
    (uint64 tokenCoreTotal, ) = _getSpotBalance(address(this), counterpartTokenIndex);
    totalUsdc8 += _toUsdc8(tokenCoreTotal, counterpartWeiDecimals, tokenPx, counterpartSzDecimals);
    
    // Token counterpart sur EVM (peut exister temporairement)
    uint256 tokenEvmBal = IERC20(counterpartToken).balanceOf(address(this));
    if (tokenEvmBal > 0) {
        uint64 tokenEvmCore = DecimalLib.evmToCore(tokenEvmBal, counterpartEvmDecimals, counterpartWeiDecimals);
        totalUsdc8 += _toUsdc8(tokenEvmCore, counterpartWeiDecimals, tokenPx, counterpartSzDecimals);
    }
    
    // USDC sur Core (weiDecimals = 8 = USDC_8DEC directement)
    (uint64 usdcCoreTotal, ) = _getSpotBalance(address(this), usdcTokenIndex);
    totalUsdc8 += uint256(usdcCoreTotal);
    
    // ⚠️ USDC sur EVM : NON INCLUS dans V1.
    // Le vault ne détient pas d'USDC ERC-20 sur EVM en fonctionnement normal.
    // Tout USDC EVM reçu accidentellement doit être rescue par owner via rescueToken().
}
```

### 3.5 Modèle Économique des Shares en Escrow

**Choix V3 : les shares en escrow restent économiquement actives jusqu'au settlement.**

Conséquences :
- `grossAssets()` inclut TOUS les assets, y compris ceux "en cours de liquidation" pour un batch
- La base pour mint/NAV est `totalSupply() + VIRTUAL_SHARES` (inclut escrow)
- Au `settleBatch()`, les shares sont burn → `totalSupply()` baisse, et `reservedHypeForClaims` augmente
- Pas besoin de `redeemLiabilities` dynamique complexe
- Pas besoin de `netAssets` ni de `activeAssets` — `grossAssets()` exclut déjà `reservedHypeForClaims` du HYPE EVM

```solidity
/// @notice Prix d'UNE share entière (1e18 share_wei) en USDC_8DEC
/// @return Valeur en USDC_8DEC. Ex: retourne 1e8 si 1 share = 1 USDC.
function sharePriceUsdc8() public view returns (uint256) {
    uint256 activeUsdc8 = grossAssets(); 
    // reservedHypeForClaims est déjà exclu de grossAssets() car on ne compte 
    // que address(this).balance - reservedHypeForClaims pour le HYPE EVM
    
    return (activeUsdc8 + VIRTUAL_ASSETS) * SCALING_FACTOR / (totalSupply() + VIRTUAL_SHARES);
}

/// @notice Nombre de shares pour un dépôt de HYPE
function previewDeposit(uint256 hypeEvmWei) public view returns (uint256 shares) {
    // Convertir HYPE en USDC_8DEC
    uint64 hypePx = _getSpotPrice(hypeSpotMarketIndex);
    uint64 hypeCore = DecimalLib.evmToCore(hypeEvmWei, 18, hypeWeiDecimals);
    uint256 depositUsdc8 = _toUsdc8(hypeCore, hypeWeiDecimals, hypePx, hypeSzDecimals);
    
    // shares = depositValue * SCALING / sharePrice  (arrondi DOWN)
    shares = depositUsdc8 * SCALING_FACTOR / sharePriceUsdc8();
    // shares est en 18 dec (share_wei)
}

/// @notice Dépose du HYPE natif et reçoit des share tokens
function deposit() external payable nonReentrant whenNotPaused returns (uint256 shares) {
    // ── Bloqué si vault occupé (NAV potentiellement stale) ──
    require(currentCycle.phase == RebalancePhase.IDLE, "rebalance in progress");
    require(!_hasBatchProcessing(), "batch processing");
    require(!emergencyMode, "emergency");
    require(depositsEnabled, "deposits disabled");
    require(msg.value > 0, "zero deposit");
    require(msg.value <= maxSingleDepositHype18, "exceeds max deposit");
    
    shares = previewDeposit(msg.value);
    require(shares > 0, "deposit too small");
    
    _mint(msg.sender, shares);
    emit Deposited(msg.sender, msg.value, shares);
}
```

### 3.6 Politique d'Arrondi (inchangée V2)

| Opération | Arrondi | Justification |
|---|---|---|
| Mint shares (deposit) | **DOWN** | Protège le vault |
| Claim (withdraw batch) | **DOWN** (division entière) | Protège le vault |
| Taille d'ordre | **DOWN** | Règle Hyperliquid |
| Prix d'achat | **UP** (slippage) | Pire cas pour le vault |
| Prix de vente | **DOWN** (slippage) | Pire cas pour le vault |

---

## 4. SYSTÈME DE RETRAIT PAR BATCH (V3)

### 4.1 Structures de Données

```solidity
struct WithdrawBatch {
    uint256 totalEscrowedShares;          // Total shares_wei (18 dec) dans ce batch
    uint256 claimedShares;                // Shares déjà claim (pour vérifier completion)
    uint256 totalHypeRecovered;           // HYPE_wei (18 dec) bridgé pour ce batch
    uint256 remainingHypeForClaims;       // HYPE_wei restant à claim (décrémenté)
    uint64  closedAtL1Block;              // L1 block quand le keeper a fermé le batch
    uint64  settledAtL1Block;             // L1 block quand le keeper a settled
    BatchStatus status;
}

struct RedeemRequest {
    address user;
    uint256 shares;     // en share_wei (18 dec)
    uint256 batchId;
    bool    claimed;
}

enum BatchStatus { OPEN, PROCESSING, SETTLED }

// Storage
uint256 public currentBatchId;
mapping(uint256 => WithdrawBatch) public batches;
mapping(uint256 => RedeemRequest) public redeemRequests;
uint256 public nextRedeemId;
mapping(address => uint256[]) public userRedeemIds;

uint256 public escrowedShares;
uint256 public reservedHypeForClaims;   // ← CRITIQUE: HYPE EVM isolé des assets actifs
```

### 4.2 Fonctions Solidity (CORRIGÉES)

```solidity
// ═══ RETRAITS ═══

function requestRedeem(uint256 shares) external nonReentrant whenNotPaused returns (uint256 redeemId) {
    require(shares > 0, "zero shares");
    require(balanceOf(msg.sender) >= shares, "insufficient");
    
    _transfer(msg.sender, address(this), shares);
    escrowedShares += shares;
    
    redeemId = nextRedeemId++;
    redeemRequests[redeemId] = RedeemRequest({
        user: msg.sender,
        shares: shares,
        batchId: currentBatchId,
        claimed: false
    });
    batches[currentBatchId].totalEscrowedShares += shares;
    userRedeemIds[msg.sender].push(redeemId);
    
    emit RedeemRequested(redeemId, msg.sender, shares, currentBatchId);
}

function closeBatch() external onlyKeeper {
    WithdrawBatch storage batch = batches[currentBatchId];
    require(batch.totalEscrowedShares > 0, "empty batch");
    // ── Exclusion mutuelle avec rebalance ──
    require(currentCycle.phase == RebalancePhase.IDLE, "rebalance in progress");
    
    batch.status = BatchStatus.PROCESSING;
    batch.closedAtL1Block = uint64(getL1BlockNumber());
    
    currentBatchId++;
    emit BatchClosed(currentBatchId - 1);
}

/// @param totalHypeRecovered HYPE_wei (18 dec) effectivement bridgé vers EVM pour ce batch
function settleBatch(uint256 batchId, uint256 totalHypeRecovered) external onlyKeeper nonReentrant {
    WithdrawBatch storage batch = batches[batchId];
    require(batch.status == BatchStatus.PROCESSING, "not processing");
    // Vérifier que le vault a assez de HYPE LIBRE (pas déjà réservé)
    require(
        address(this).balance >= reservedHypeForClaims + totalHypeRecovered,
        "insufficient free HYPE"
    );
    
    batch.totalHypeRecovered = totalHypeRecovered;
    batch.remainingHypeForClaims = totalHypeRecovered;
    batch.settledAtL1Block = uint64(getL1BlockNumber());
    batch.status = BatchStatus.SETTLED;
    
    // Réserver le HYPE pour les claims (exclu de grossAssets)
    reservedHypeForClaims += totalHypeRecovered;
    
    // Burn les shares en escrow
    _burn(address(this), batch.totalEscrowedShares);
    escrowedShares -= batch.totalEscrowedShares;
    
    emit BatchSettled(batchId, totalHypeRecovered, batch.totalEscrowedShares);
}

function claimBatch(uint256 redeemId) external nonReentrant {
    RedeemRequest storage req = redeemRequests[redeemId];
    require(req.user == msg.sender, "not owner");
    require(!req.claimed, "already claimed");
    
    WithdrawBatch storage batch = batches[req.batchId];
    require(batch.status == BatchStatus.SETTLED, "not settled");
    
    req.claimed = true;
    
    // ══ FORMULE CORRIGÉE avec scaling 1e18 ══
    // settlement: chaque share donne (totalHype / totalShares) de HYPE
    // Comme shares et HYPE sont tous les deux en 18 dec :
    // hypeAmount = req.shares * totalHypeRecovered / totalEscrowedShares
    // Division entière → arrondi DOWN → protège le vault
    uint256 hypeAmount = req.shares * batch.totalHypeRecovered / batch.totalEscrowedShares;
    
    batch.claimedShares += req.shares;
    batch.remainingHypeForClaims -= hypeAmount;
    reservedHypeForClaims -= hypeAmount;
    
    (bool ok,) = payable(msg.sender).call{value: hypeAmount}("");
    require(ok, "transfer failed");
    
    emit Claimed(redeemId, msg.sender, hypeAmount);
}

/// @notice Quand tous les claims d'un batch sont faits, la poussière retourne aux actifs
function sweepBatchDust(uint256 batchId) external onlyKeeper {
    WithdrawBatch storage batch = batches[batchId];
    require(batch.status == BatchStatus.SETTLED, "not settled");
    require(batch.remainingHypeForClaims > 0, "nothing to sweep");
    // Vérifier que TOUS les claims ont été faits
    require(batch.claimedShares == batch.totalEscrowedShares, "claims still pending");
    // La poussière de division est relâchée vers les actifs actifs
    reservedHypeForClaims -= batch.remainingHypeForClaims;
    batch.remainingHypeForClaims = 0;
}
```

### 4.3 Pourquoi la Formule Settlement est Correcte

Les shares et le HYPE sont **tous les deux en 18 décimales** :
- `req.shares` : share_wei (18 dec)
- `batch.totalHypeRecovered` : HYPE_wei (18 dec)
- `batch.totalEscrowedShares` : share_wei (18 dec)

Donc `shares * totalHype / totalShares` donne directement des HYPE_wei (18 dec).
Pas besoin d'un facteur `1e18` supplémentaire.

Le facteur `1e18` de la V2 (`settlementPriceHype18 = totalHype * 1e18 / totalShares`) était **faux** car il créait un double scaling.

---

## 5. REBALANCE — STATE MACHINE (V3)

### 5.1 Interface Typée pour les Ordres

```solidity
/// @notice Struct typée pour un ordre spot via CoreWriter
struct SpotOrder {
    uint32 asset;      // 10000 + spotMarketIndex
    bool   isBuy;
    uint64 limitPx;    // 10^8 * prix humain formaté
    uint64 sz;         // 10^8 * taille humaine formatée
}
// tif = IOC imposé par le contrat, reduceOnly = false, cloid = 0
```

### 5.2 Exclusion Mutuelle Rebalance / Batch

```solidity
function startRebalance(...) external onlyKeeper whenNotPaused {
    require(currentCycle.phase == RebalancePhase.IDLE, "cycle in progress");
    // ── Pas de rebalance si un batch est en PROCESSING ──
    require(!_hasBatchProcessing(), "batch processing");
    ...
}

function closeBatch() external onlyKeeper {
    // ── Pas de fermeture de batch si un rebalance est en cours ──
    require(currentCycle.phase == RebalancePhase.IDLE, "rebalance in progress");
    ...
}
```

### 5.3 Transition confirmBridgeOut Ajoutée

```solidity
// La state machine complète :
// IDLE → BRIDGING_IN → AWAITING_BRIDGE_IN → TRADING → AWAITING_TRADES
//   → BRIDGING_OUT → AWAITING_BRIDGE_OUT → FINALIZING → IDLE
//   (ou IDLE directement si pas de bridge out nécessaire)

function confirmBridgeOut() external onlyKeeper {
    require(currentCycle.phase == RebalancePhase.AWAITING_BRIDGE_OUT);
    uint64 currentL1 = uint64(getL1BlockNumber());
    require(currentL1 > currentCycle.lastActionL1Block, "L1 not advanced");
    currentCycle.phase = RebalancePhase.FINALIZING;
    _touchHeartbeat();
}
```

### 5.4 abortCycle — Permissionless Après Deadline

```solidity
function abortCycle() external {
    require(currentCycle.phase != RebalancePhase.IDLE, "no cycle");
    // Keeper ou Owner peuvent toujours abort
    // N'importe qui peut abort si la deadline L1 est dépassée
    bool isAuthorized = msg.sender == factory.keeper() || msg.sender == factory.owner();
    bool isExpired = uint64(getL1BlockNumber()) > currentCycle.deadline;
    require(isAuthorized || isExpired, "not authorized and not expired");
    
    currentCycle.phase = RebalancePhase.IDLE;
    if (isAuthorized) _touchHeartbeat();
    emit RebalanceCycleAborted(currentCycle.cycleId);
}
```

### 5.5 executeTrades avec Struct Typée

```solidity
function executeTrades(SpotOrder[] calldata orders) external onlyKeeper {
    require(currentCycle.phase == RebalancePhase.TRADING);
    
    for (uint i = 0; i < orders.length; i++) {
        SpotOrder calldata o = orders[i];
        // Validation: seulement les paires autorisées
        require(
            o.asset == 10000 + hypeSpotMarketIndex || 
            o.asset == 10000 + counterpartSpotMarketIndex,
            "unauthorized pair"
        );
        // Validation: slippage
        _validateTradePrice(
            o.asset == 10000 + hypeSpotMarketIndex ? hypeSpotMarketIndex : counterpartSpotMarketIndex,
            o.limitPx, o.isBuy
        );
        // Envoyer via CoreWriter: Action ID 1, tif = IOC (3)
        bytes memory params = abi.encode(o.asset, o.isBuy, o.limitPx, o.sz, false, uint8(3), uint128(0));
        _sendCoreAction(1, params);
    }
    
    currentCycle.lastActionL1Block = uint64(getL1BlockNumber());
    currentCycle.phase = RebalancePhase.AWAITING_TRADES;
    _touchHeartbeat();
}
```

### 5.6 Struct de Cycle Mise à Jour

```solidity
struct RebalanceCycle {
    uint256 cycleId;
    RebalancePhase phase;
    uint64 startedAtL1Block;
    uint64 lastActionL1Block;    // ← NOUVEAU : pour vérifier la progression L1
    uint64 deadline;
    int256 expectedHypeDeltaWei;
    int256 expectedTokenDeltaWei;
    int256 expectedUsdcDeltaWei;
}
```

---

## 6. CONVERSIONS DE DÉCIMALES (V3)

### 6.1 DecimalLib.sol — Avec Protection Overflow

```solidity
function evmToCore(uint256 evmWei, uint8 evmDecimals, uint8 coreWeiDecimals) 
    internal pure returns (uint64) 
{
    uint256 result;
    if (evmDecimals > coreWeiDecimals) {
        result = evmWei / (10 ** (evmDecimals - coreWeiDecimals));
    } else if (evmDecimals < coreWeiDecimals) {
        result = evmWei * (10 ** (coreWeiDecimals - evmDecimals));
    } else {
        result = evmWei;
    }
    require(result <= type(uint64).max, "evmToCore overflow");
    return uint64(result);
}

function coreToEvm(uint64 coreWei, uint8 coreWeiDecimals, uint8 evmDecimals)
    internal pure returns (uint256)
{
    if (evmDecimals > coreWeiDecimals) {
        return uint256(coreWei) * (10 ** (evmDecimals - coreWeiDecimals));
    } else if (evmDecimals < coreWeiDecimals) {
        return uint256(coreWei) / (10 ** (coreWeiDecimals - evmDecimals));
    } else {
        return uint256(coreWei);
    }
}
```

---

## 7. PROTECTIONS DE PRIX ET CIRCUIT BREAKER — CORRIGÉ

### 7.1 Validation de Prix (On-chain)

```solidity
/// @notice Le contrat valide le prix en comparant spot et oracle quand disponible
/// @dev Appelé lors des phases de trading pour borner le slippage
function _validateTradePrice(
    uint32 spotMarketIndex,
    uint64 proposedPx,
    bool isBuy
) internal view {
    uint64 spotPx = _getSpotPrice(spotMarketIndex);
    
    // Slippage check
    if (isBuy) {
        // Le prix d'achat ne doit pas dépasser spotPx * (1 + slippageBps/10000)
        require(proposedPx <= spotPx * (10000 + slippageBps) / 10000, "buy price too high");
    } else {
        // Le prix de vente ne doit pas être sous spotPx * (1 - slippageBps/10000)
        require(proposedPx >= spotPx * (10000 - slippageBps) / 10000, "sell price too low");
    }
}
```

### 7.2 Circuit Breaker — Corrigé

Le circuit breaker ne surveille **PAS** la NAV brute (qui bouge avec le marché), mais :

```solidity
uint256 public slippageBps = 200;                // Mutable, default 2%
uint256 public constant SLIPPAGE_CAP_BPS = 500;  // Hard cap 5%, immutable

// Le keeper peut ajuster dans les bornes
function setSlippage(uint256 newBps) external onlyOwner {
    require(newBps <= SLIPPAGE_CAP_BPS, "exceeds cap");
    slippageBps = newBps;
}
```

**Conditions de pause automatique (dans le contrat) :**
- Aucune. Le contrat ne pause pas automatiquement sur une baisse de NAV.

**Conditions de pause (dans le keeper) :**
Le keeper décide de pauser (appelle `pause()`) si :
- Slippage réalisé > seuil sur un trade
- Balance post-trade incompatible avec le plan
- Prix spot diverge de l'oracle de > 5%
- Partial fills répétés s'aggravant
- Erreur réseau ou exception inattendue

### 7.3 Protection Anti-Manipulation de NAV

Pour les tokens peu liquides, risque de manipulation du prix pour sur-minter des shares ou sortir à prix gonflé.

**Protections dans le contrat :**
```solidity
uint256 public maxSingleDepositHype18;   // Ex: 1000 HYPE max par dépôt
// Configurable par le keeper/owner pour chaque vault
// Les gros dépôts sont fragmentés naturellement

/// @notice Le keeper peut geler les dépôts si la liquidité est trop faible
function setDepositsEnabled(bool enabled) external onlyKeeper;
```

**Protections dans le keeper :**
- Vérifier la profondeur du L2 book avant de permettre les dépôts
- Si spread > 5% ou profondeur < 5x la taille du vault → désactiver les dépôts
- Utiliser le prix conservateur (min spot/oracle) pour la NAV

---

## 8. EMERGENCY MODE (V3)

### 8.1 Trois Types d'Utilisateurs à Gérer

En mode emergency, il existe 3 catégories de droits :

| Type | Situation | Droit |
|---|---|---|
| A. Holders | Shares dans leur wallet | Claim proportionnel des assets récupérés |
| B. Redeem pending | Shares en escrow (batches OPEN ou PROCESSING) | Même droit — les shares sont restituées puis traitées comme A |
| C. Settled unclaimed | Batch SETTLED mais pas encore claim | Leur HYPE est déjà dans `reservedHypeForClaims` — ils claim normalement |

### 8.1b Fonctions Autorisées en Emergency

| Fonction | Autorisée en emergency ? |
|---|---|
| `deposit()` | ❌ Non (paused + check explicite) |
| `requestRedeem()` | ❌ Non (paused) |
| `closeBatch()` | ❌ Non — ajouter `require(!emergencyMode)` |
| `settleBatch()` | ❌ Non — ajouter `require(!emergencyMode)` |
| `startRebalance()` | ❌ Non (paused + check) |
| Toutes transitions rebalance | ❌ Non |
| `claimBatch()` | ✅ Oui — pour batches SETTLED avant emergency |
| `reclaimEscrowedShares()` | ✅ Oui — users type B |
| `emergencyLiquidate()` | ✅ Oui — keeper/owner |
| `recoverHypeFromCore()` | ✅ Oui — keeper/owner |
| `finalizeRecovery()` | ✅ Oui — keeper/owner |
| `claimRecovery()` | ✅ Oui — tous holders |

### 8.2 Fonctions

```solidity
/// @notice Déclenche le mode emergency. PAS de boucle non bornée.
/// Pose seulement le flag — chaque user récupère ses shares individuellement.
function enterEmergency() external {
    require(isEmergency(), "conditions not met");
    emergencyMode = true;
    _pause(); // Bloque dépôts et nouveaux redeems
    // Abort le cycle de rebalance en cours s'il y en a un
    if (currentCycle.phase != RebalancePhase.IDLE) {
        currentCycle.phase = RebalancePhase.IDLE;
    }
    emit EmergencyEntered(block.timestamp);
}

/// @notice Users type B : récupèrent leurs shares en escrow (batches NON settled)
/// Chaque user appelle individuellement — pas de boucle on-chain.
function reclaimEscrowedShares(uint256 redeemId) external nonReentrant {
    require(emergencyMode, "not emergency");
    RedeemRequest storage req = redeemRequests[redeemId];
    require(req.user == msg.sender, "not owner");
    require(!req.claimed, "already processed");
    
    WithdrawBatch storage batch = batches[req.batchId];
    // Seulement pour les batches OPEN ou PROCESSING (pas SETTLED)
    require(batch.status != BatchStatus.SETTLED, "use claimBatch instead");
    
    req.claimed = true;
    escrowedShares -= req.shares;
    _transfer(address(this), msg.sender, req.shares);
    // Maintenant le user a ses shares dans son wallet et pourra faire claimRecovery()
    
    emit EscrowReclaimed(redeemId, msg.sender, req.shares);
}

/// @notice Le keeper/owner rapatrie les assets depuis Core vers EVM.
/// ⚠️ En emergency, le keeper doit D'ABORD convertir TOKEN et USDC vers HYPE sur Core
///    (via des ordres IOC), PUIS bridge le HYPE vers EVM.
///    claimRecovery() ne distribue QUE du HYPE natif EVM.
/// @param hypeWeiAmount Montant de HYPE en Core weiDecimals à bridge vers EVM
function recoverHypeFromCore(uint64 hypeWeiAmount) external {
    require(emergencyMode, "not emergency");
    require(msg.sender == factory.keeper() || msg.sender == factory.owner(), "not authorized");
    
    // HYPE utilise la system address spéciale 0x2222...2222
    bytes memory params = abi.encode(
        address(0x2222222222222222222222222222222222222222),
        hypeTokenIndex,
        hypeWeiAmount
    );
    _sendCoreAction(6, params);
}

/// @notice En emergency, le keeper peut aussi placer des ordres IOC pour
///         convertir TOKEN/USDC → HYPE sur Core avant de bridge.
function emergencyLiquidate(SpotOrder[] calldata orders) external {
    require(emergencyMode, "not emergency");
    require(msg.sender == factory.keeper() || msg.sender == factory.owner(), "not authorized");
    
    for (uint i = 0; i < orders.length; i++) {
        SpotOrder calldata o = orders[i];
        // ── Mêmes validations que executeTrades() ──
        require(
            o.asset == 10000 + hypeSpotMarketIndex || 
            o.asset == 10000 + counterpartSpotMarketIndex,
            "unauthorized pair"
        );
        _validateTradePrice(
            o.asset == 10000 + hypeSpotMarketIndex ? hypeSpotMarketIndex : counterpartSpotMarketIndex,
            o.limitPx, o.isBuy
        );
        bytes memory params = abi.encode(o.asset, o.isBuy, o.limitPx, o.sz, false, uint8(3), uint128(0));
        _sendCoreAction(1, params);
    }
}

/// @notice Le keeper marque la recovery comme terminée
function finalizeRecovery() external {
    require(emergencyMode, "not emergency");
    require(msg.sender == factory.keeper() || msg.sender == factory.owner());
    require(escrowedShares == 0, "escrow not reclaimed — users type B must reclaimEscrowedShares first");
    recoveryComplete = true;
}

/// @notice Claim proportionnel après recovery. Distribue UNIQUEMENT du HYPE natif EVM.
/// Séquence attendue :
///   1. Users type C (settled unclaimed) → claimBatch() normalement
///   2. Users type B → reclaimEscrowedShares() pour récupérer leurs shares
///   3. Keeper → emergencyLiquidate() pour convertir tout en HYPE sur Core
///   4. Keeper → recoverHypeFromCore() pour bridge HYPE vers EVM
///   5. Keeper → finalizeRecovery()
///   6. Users type A+B → claimRecovery()
function claimRecovery() external nonReentrant {
    require(emergencyMode && recoveryComplete, "not ready");
    uint256 userShares = balanceOf(msg.sender);
    require(userShares > 0, "no shares");
    
    // HYPE distributable = balance totale MOINS le HYPE réservé aux batches settled
    uint256 distributableHype = address(this).balance - reservedHypeForClaims;
    // totalSupply() ici = seulement les shares des holders (escrow déjà restituées)
    uint256 hypeOwed = distributableHype * userShares / totalSupply();
    
    _burn(msg.sender, userShares);
    (bool ok,) = payable(msg.sender).call{value: hypeOwed}("");
    require(ok);
    
    emit RecoveryClaimed(msg.sender, hypeOwed);
}
```

---

## 9. ARCHITECTURE DES SMART CONTRACTS

### 9.1 Arborescence

```
src/
├── core/
│   ├── RebalancingVault.sol        # Vault principal (custom, PAS ERC-4626)
│   ├── VaultFactory.sol            # Factory + owner/keeper global
│   └── VaultShareToken.sol         # ERC-20 share token (intégré au vault)
├── libraries/
│   ├── CoreActionLib.sol           # Encoding des actions CoreWriter
│   ├── PrecompileLib.sol           # Lecture precompiles (signatures exactes)
│   ├── BridgeLib.sol               # Bridge EVM ↔ Core
│   ├── DecimalLib.sol              # Conversions (CORRIGÉ: deux branches)
│   ├── PriceLib.sol                # Tick size formatting
│   └── SizeLib.sol                 # Lot size formatting
├── interfaces/
│   ├── ICoreWriter.sol
│   └── IRebalancingVault.sol
test/
├── RebalancingVault.t.sol
├── BatchWithdraw.t.sol
├── DecimalLib.t.sol                # Test USDC 6↔8, HYPE 18↔8
├── StateMachine.t.sol
├── mocks/
│   ├── MockPrecompile.sol
│   └── MockCoreWriter.sol
script/
├── Deploy.s.sol
├── CreateVault.s.sol
keeper/                              # Python off-chain
├── main.py
├── config.py
├── vault_manager.py                 # web3 interactions
├── core_reader.py                   # SDK + precompiles
├── rebalancer.py                    # Calcul + orchestration
├── batch_processor.py               # Traitement des batches de retraits
├── price_checker.py                 # Vérification liquidité L2 book
├── alerter.py
├── persistence.py                   # SQLite pour état du keeper
├── abi/
├── requirements.txt
├── Dockerfile
└── .env.example
```

### 9.2 Modèle d'Accès — Unifié via Factory

```solidity
// VaultFactory.sol
contract VaultFactory {
    address public owner;          // Multisig recommandé
    address public keeper;         // EOA dédié au keeper bot
    mapping(address => address) public vaults;  // counterpartToken → vault
    address[] public allVaults;
    bool public globalPaused;

    function setKeeper(address k) external onlyOwner;
    function setGlobalPause(bool p) external onlyOwner;
    function createVault(...) external onlyOwner returns (address);
}

// RebalancingVault.sol
contract RebalancingVault {
    VaultFactory public immutable factory;
    
    modifier onlyKeeper() {
        require(msg.sender == factory.keeper(), "not keeper");
        _;
    }
    modifier onlyOwner() {
        require(msg.sender == factory.owner(), "not owner");
        _;
    }
    modifier whenNotPaused() {
        require(!paused && !factory.globalPaused(), "paused");
        _;
    }
}
```

### 9.3 Paramètres d'Initialisation (Tous Configurables)

```solidity
function initialize(
    address _counterpartToken,       // ERC-20 sur EVM
    uint32 _counterpartTokenIndex,   // Token index HyperCore
    uint32 _counterpartSpotMarketIndex,
    uint32 _hypeTokenIndex,          // 150 mainnet, résolu dynamiquement
    uint32 _hypeSpotMarketIndex,     // 107 mainnet, résolu dynamiquement
    uint32 _usdcTokenIndex,          // 0
    uint8 _counterpartSzDecimals,
    uint8 _counterpartWeiDecimals,
    uint8 _counterpartEvmDecimals,
    uint256 _maxSingleDepositHype18  // Limit anti-manipulation
) external;
```

---

### 9.4 Compléments V3

### 9.1 Fonction Publique L1 Block

```solidity
/// @notice Expose le L1 block number pour le keeper
function getL1BlockNumber() public view returns (uint64) {
    (bool ok, bytes memory data) = address(0x000000000000000000000000000000000000080B)
        .staticcall("");
    require(ok, "L1 block precompile failed");
    return abi.decode(data, (uint64));
}
```

### 9.2 Arborescence Test Mise à Jour

```
test/
├── RebalancingVault.t.sol
├── BatchWithdraw.t.sol
├── BatchSettlement.t.sol       # ← NOUVEAU: scaling, dust, reservedHype
├── EmergencyMode.t.sol         # ← NOUVEAU: 3 types d'utilisateurs
├── DecimalLib.t.sol
├── StateMachine.t.sol
├── SharePricing.t.sol          # ← NOUVEAU: virtual shares, deposit/preview
├── mocks/
│   ├── MockPrecompile.sol
│   └── MockCoreWriter.sol
```

---

## 10. KEEPER PYTHON

### 10.1 Stack

```
hyperliquid-python-sdk    # API HyperCore
web3.py                   # HyperEVM transactions
eth-account               # Signing
python-dotenv             # Config
httpx                     # HTTP
APScheduler               # Loop
structlog                 # Logging
sqlite3                   # Persistance (stdlib, pas de dépendance externe)
```

### 10.2 Persistance (SQLite) — NOUVEAU

```python
# persistence.py
import sqlite3

class KeeperState:
    """Persiste l'état du keeper pour survivre aux restarts."""
    
    def __init__(self, db_path="keeper_state.db"):
        self.conn = sqlite3.connect(db_path)
        self._init_tables()
    
    def _init_tables(self):
        self.conn.executescript("""
            CREATE TABLE IF NOT EXISTS rebalance_cycles (
                cycle_id INTEGER PRIMARY KEY,
                vault_address TEXT,
                phase TEXT,
                started_at REAL,
                l1_ref_block INTEGER,
                planned_trades TEXT,  -- JSON
                tx_hashes TEXT,       -- JSON list of sent tx hashes
                retries INTEGER DEFAULT 0,
                status TEXT DEFAULT 'active'
            );
            CREATE TABLE IF NOT EXISTS withdraw_batches (
                batch_id INTEGER PRIMARY KEY,
                vault_address TEXT,
                total_shares TEXT,
                status TEXT,
                tx_hashes TEXT,
                settled_amount TEXT
            );
            CREATE TABLE IF NOT EXISTS keeper_meta (
                key TEXT PRIMARY KEY,
                value TEXT
            );
        """)
```

### 10.3 Attente sur L1 Block — CORRIGÉ

```python
async def wait_l1_block_progress(self, vault_contract, reference_l1_block=None):
    """Attend que le L1 block number avance depuis la référence.
    NE PAS juste attendre N blocs EVM — les precompiles reflètent l'état L1."""
    
    if reference_l1_block is None:
        reference_l1_block = vault_contract.functions.getL1BlockNumber().call()
    
    max_wait = 30  # secondes
    start = time.time()
    while time.time() - start < max_wait:
        current_l1 = vault_contract.functions.getL1BlockNumber().call()
        if current_l1 > reference_l1_block:
            return current_l1
        await asyncio.sleep(0.3)
    
    raise TimeoutError("L1 block did not advance")
```

### 10.4 Flow du Keeper (Simplifié)

```python
async def run_loop(self):
    while True:
        try:
            for vault in self.get_active_vaults():
                # 1. Heartbeat
                self.send_heartbeat(vault)
                
                # 2. Traiter les batches PROCESSING
                await self.process_pending_batches(vault)
                
                # 3. Si IDLE, évaluer le besoin de rebalance
                if self.should_rebalance(vault):
                    await self.execute_rebalance_cycle(vault)
        
        except Exception as e:
            await self.alerter.send(f"Error: {e}")
            self.state.log_error(str(e))
        
        await asyncio.sleep(60)
```

### 10.5 Configuration Réseau

```python
NETWORKS = {
    "mainnet": {
        "chain_id": 999,
        "evm_rpc": "https://rpc.hyperliquid.xyz/evm",
        "hl_api": "https://api.hyperliquid.xyz",
    },
    "testnet": {
        "chain_id": 998,
        "evm_rpc": "https://rpc.hyperliquid-testnet.xyz/evm",
        "hl_api": "https://api.hyperliquid-testnet.xyz",
    }
}
# Token indices résolus dynamiquement au démarrage via spotMeta API
```

---

## 11. SUPPORTED MARKETS POLICY (NOUVEAU)

Un vault ne peut être créé via la Factory que si le token :
1. A une paire spot active contre USDC sur HyperCore
2. A un contrat EVM lié (evmContract non null dans spotMeta)
3. Le keeper a vérifié une liquidité minimale (profondeur L2 book ≥ seuil configurable)

La Factory ne vérifie pas ça on-chain (impossible), c'est le owner qui valide avant d'appeler `createVault()`.

---

## 12. PLAN DE DÉVELOPPEMENT (PHASES)

### Phase 1 — Fondations (3-5 jours)
- [ ] Setup Foundry + hyper-evm-lib + OpenZeppelin
- [ ] `DecimalLib.sol` — AVEC les deux branches (evmDec > coreDec ET evmDec < coreDec)
- [ ] Tests DecimalLib : HYPE (18→8), USDC (6→8), PURR (variable→5)
- [ ] `PriceLib.sol` + `SizeLib.sol` — tick/lot size
- [ ] `PrecompileLib.sol` — wrapper avec signatures exactes
- [ ] `CoreActionLib.sol` — encoding des actions 1,6,7,10
- [ ] `BridgeLib.sol`
- [ ] Tests unitaires avec mocks

### Phase 2 — Vault Core (5-7 jours)
- [ ] `RebalancingVault.sol` — structure de base avec share token ERC-20
- [ ] Modèle comptable : grossAssets, escrowedShares, reservedHypeForClaims, virtual shares
- [ ] `deposit()` bloqué si : rebalance en cours, batch PROCESSING, emergencyMode, ou depositsEnabled=false
- [ ] Système de **batch withdrawal** complet :
  - [ ] `requestRedeem()` — escrow, pas burn
  - [ ] `closeBatch()` — keeper ferme
  - [ ] `settleBatch()` — keeper fixe le prix
  - [ ] `claimBatch()` — user réclame
- [ ] State machine de rebalance (8 phases)
- [ ] Emergency mode (enterEmergency, reclaimEscrowedShares, recoverHypeFromCore, emergencyLiquidate, claimRecovery)
- [ ] Tests d'intégration

### Phase 3 — Factory (2-3 jours)
- [ ] `VaultFactory.sol` — owner/keeper global, create via clone
- [ ] Deploy scripts
- [ ] Tests E2E

### Phase 4 — Keeper Python (5-7 jours)
- [ ] Setup Python + SDK + web3.py
- [ ] `persistence.py` — SQLite state
- [ ] `core_reader.py` — résolution dynamique des token indices
- [ ] `rebalancer.py` — calcul off-chain + orchestration multi-phase
- [ ] `batch_processor.py` — liquidation + settlement des batches
- [ ] `price_checker.py` — L2 book depth check
- [ ] Attente sur L1 block progression (pas EVM block)
- [ ] Heartbeat mechanism
- [ ] Tests + config testnet

### Phase 5 — Tests & Security (3-5 jours)
- [ ] Fuzzing DecimalLib (toutes combinaisons de décimales)
- [ ] Tests batch withdrawal E2E
- [ ] Tests state machine (toutes transitions, y compris abort)
- [ ] Tests emergency mode complet
- [ ] Tests anti-manipulation NAV
- [ ] Invariant: `totalSupply = circulatingShares + escrowedShares`
- [ ] Invariant: `address(this).balance >= reservedHypeForClaims`
- [ ] Invariant: pour chaque batch settled, `remainingHype <= totalHypeRecovered`
- [ ] Invariant: pour chaque batch settled, `claimedShares <= totalEscrowedShares`
- [ ] Simulation testnet complète

### Phase 6 — Déploiement (1-2 jours)
- [ ] Deploy sur testnet, cycle complet
- [ ] Deploy mainnet via big block (30M gas)
- [ ] Premier vault (ex: HYPE/PURR)
- [ ] Keeper en daemon (Docker)
- [ ] Monitoring

---

## 13. CHECKLIST DE SÉCURITÉ (V3)

- [ ] `SHARE_DECIMALS = 18` — explicite, cohérent avec ERC-20 standard
- [ ] `VIRTUAL_SHARES = 1e18`, `VIRTUAL_ASSETS = 1e8` → prix initial = 1 USDC/share
- [ ] Settlement: `hypeAmount = shares * totalHype / totalShares` — correct car les 3 sont en 18 dec
- [ ] `reservedHypeForClaims` : incrémenté au settlement, décrémenté au claim
- [ ] `grossAssets()` exclut `reservedHypeForClaims` du solde HYPE EVM
- [ ] `grossAssets()` inclut le counterpart token sur EVM (temporaire)
- [ ] `sharePriceUsdc8()` utilise `totalSupply() + VIRTUAL_SHARES` (pas de variable séparée)
- [ ] Shares en escrow = économiquement actives (dans `totalSupply()` jusqu'au burn)
- [ ] DecimalLib: `require(result <= type(uint64).max)` sur chaque cast
- [ ] `closeBatch()` interdit si rebalance en cours (exclusion mutuelle)
- [ ] `startRebalance()` interdit si batch en PROCESSING (exclusion mutuelle)
- [ ] State machine: `confirmBridgeOut()` entre `executeBridgeOut()` et `finalizeCycle()`
- [ ] `abortCycle()` permissionless si deadline L1 dépassée
- [ ] `executeTrades(SpotOrder[])` — struct typée, pas de `bytes calldata`
- [ ] `recoverHypeFromCore()` utilise `0x2222...` pour HYPE (PAS `_buildSystemAddress`)
- [ ] `emergencyLiquidate(SpotOrder[])` avec mêmes validations paire/slippage que `executeTrades()`
- [ ] `enterEmergency()` sans boucle non bornée — chaque user reclaim individuellement
- [ ] `finalizeRecovery()` requiert `escrowedShares == 0` (users B doivent reclaim d'abord)
- [ ] Emergency gère les 3 types d'users: holders, escrow pending, settled unclaimed
- [ ] `closeBatch()` et `settleBatch()` bloquées en emergencyMode
- [ ] Tableau 8.1b : liste exhaustive des fonctions autorisées/bloquées en emergency
- [ ] `reclaimEscrowedShares()` restitue les shares des batches non-settled en emergency
- [ ] `claimRecovery()` distribue `balance - reservedHypeForClaims` — HYPE uniquement
- [ ] `sweepBatchDust()` requiert `claimedShares == totalEscrowedShares` avant sweep
- [ ] `claimRecovery()` distribue `balance - reservedHypeForClaims` au pro-rata de `totalSupply()`
- [ ] `getL1BlockNumber()` exposée comme `public view` pour le keeper
- [ ] `sweepBatchDust()` relâche la poussière de division après tous les claims d'un batch
- [ ] `settleBatch()` vérifie `balance >= reservedHypeForClaims + totalHypeRecovered` (pas juste balance)
- [ ] USDC bridge: `approve()` puis `deposit()` sur CoreDepositWallet, PAS `transfer()`
- [ ] Pas de `totalShareSupply` séparé — utiliser `totalSupply()` et `escrowedShares`
- [ ] Keeper Python attend progression de `getL1BlockNumber()`, pas de blocs EVM

---

## 14. NOTES POUR LE DÉVELOPPEUR

1. **hyper-evm-lib** : Utiliser `CoreWriterLib`, `PrecompileLib`, `TokenRegistry` quand possible plutôt que recoder.

2. **L'ordre de traitement :** `L1 block → EVM block → EVM→Core transfers → CoreWriter actions`. Un ordre placé au bloc N n'est visible qu'au L1 block suivant.

3. **HYPE est natif** (comme ETH). Bridge EVM→Core = envoyer msg.value à `0x2222...`.

4. **USDC bridge est spécial** : `approve()` puis `deposit()` sur CoreDepositWallet. Pas `transfer()`.

5. **Les assets restent sur Core.** On ne bridge vers EVM que pour servir les withdrawals. Ça simplifie énormément le système.

6. **Le keeper est le cerveau.** Le contrat est un coffre-fort. Le keeper calcule, le contrat valide et exécute.

7. **Format CoreWriter :** `limitPx = 10^8 * human_price`, `sz = 10^8 * human_size`, `asset = 10000 + spotMarketIndex`.

8. **Pas de cancel de redeem en V1.** C'est un choix délibéré pour éviter l'optionalité gratuite. Les shares sont en escrow, pas perdues.

9. **Testnet vs Mainnet :** Chain IDs différents (998/999), RPC différents, token indices différents. Résoudre dynamiquement via `spotMeta` API au démarrage du keeper.

10. **L1 block ≠ EVM block.** Le keeper doit attendre la progression du L1 block number (via precompile 0x80B) pour vérifier les effets d'une action CoreWriter. Pas juste N blocs EVM.

### Notes Additionnelles V3 POUR LE DÉVELOPPEUR

En plus des notes V2 (toujours valides) :

11. **Shares = 18 décimales.** Comme tout ERC-20. Le settlement fonctionne directement car HYPE EVM est aussi en 18 dec. Pas de scaling supplémentaire entre shares et HYPE.

12. **`reservedHypeForClaims` est la variable la plus critique.** Elle isole le HYPE promis aux batches settled de tous les autres calculs. Si elle est incorrecte, soit les sortants sont volés, soit les entrants sont dilués.

13. **Exclusion mutuelle rebalance/batch.** En V3, on ne peut pas avoir un rebalance en cours ET un batch en PROCESSING simultanément. Le keeper doit finir l'un avant de commencer l'autre. Cela simplifie énormément le suivi des deltas d'assets.

14. **La poussière de settlement** reste dans `remainingHypeForClaims` du batch. Le keeper appelle `sweepBatchDust()` une fois tous les claims faits pour la relâcher vers les actifs actifs.

15. **En emergency**, la séquence est : `enterEmergency()` → users type B font `reclaimEscrowedShares()` → keeper fait `emergencyLiquidate()` pour convertir TOKEN/USDC → HYPE sur Core → keeper fait `recoverHypeFromCore()` pour bridge vers EVM → `finalizeRecovery()` → users type A+B font `claimRecovery()`. Les users type C (settled unclaimed) font `claimBatch()` normalement — leur HYPE est déjà réservé et isolé.