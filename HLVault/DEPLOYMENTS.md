# Deployments

## Testnet (chainId 998)

| Contrat | Adresse |
|---|---|
| Implementation | `0x2d903a0b198681550b44b4a733d32eb4887ceb55` |
| Factory | `0xaA10D8C30e6226356D61E0ca88c8d1B0e6df20AE` |
| Vault SOVY | `0x22276e9562e38c309f8Dedf8f1fB405297560da7` |
| Vault BARK | `0x720021b106B42a625c1dC2322214A3248A09bb6a` |
| Vault ZIGG | `0x66e880e2bd93243569B985499aD00Df543a77554` |

**Deploye le** : 2026-03-15
**Version** : GTC fix (`_processAndSendOrder` tif=2)

> Note : L'adresse implementation `0xc543833c778150823B69e147A18Ec42e3a4679A5` mentionnee precedemment etait incorrecte.
> L'adresse reelle (verifiee on-chain) est `0x2d903a0b198681550b44b4a733d32eb4887ceb55`.
> Les clones (SOVY, BARK, ZIGG) pointent bien vers cette implementation.

## Etat au 2026-04-26

- **Precompiles** : fonctionnelles (0x801, 0x808, 0x809 repondent correctement)
- **Indices tokens/marches** : inchanges (SOVY=1158/1080, BARK=242/218, HYPE=1105/1035)
- **Vault SOVY** : grossAssets ~$22.79, sharePriceUsdc8 ~$1.09, depositsEnabled=true
- **ATTENTION** : `isEmergency()=true` car le keeper n'a pas tourne depuis le 2026-03-15 (heartbeat expire). `emergencyMode=false` (les depots fonctionnent encore). Relancer le keeper pour corriger.

## Mainnet (chainId 999)

*Pas encore deploye.*
