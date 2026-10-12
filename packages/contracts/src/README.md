# Contract Source Map

This file indexes `contracts/src` for auditing and implementation work. It does
not replace the specs; use the linked `documents/jp` files for requirements.
For expected actors, production call paths, protocol-only handlers, and disabled
routes, start with
[`documents/jp/engineering/guides/Contract-Audit-Usage-Map.md`](../../documents/jp/engineering/guides/Contract-Audit-Usage-Map.md).

## Top-Level Core

| Contract | Role | Audit focus |
| --- | --- | --- |
| `CollateralRegistry.sol` | System entry for collateral branches and redemption routing. | Branch accounting, redemption routing weights, shutdown behavior, dependency wiring. |
| `BorrowerOperations.sol` | User and delegate entry point for opening, adjusting, and closing Troves. | Access/delegation, interest application, debt/collateral accounting, hint usage. |
| `TroveManager.sol` | Branch-local Trove state, liquidations, redemptions, and batch accounting. | ICR/TCR math, SP offset vs redistribution, zombie Troves, batch interest updates. |
| `StabilityPool.sol` / `DFStabilityPool.sol` | Branch-local JPYDF deposits used to offset liquidations. | Product-sum accounting, reward distribution, rounding, minimum JPYDF left in SP. |
| `ActivePool.sol`, `DefaultPool.sol`, `CollSurplusPool.sol`, `GasPool.sol` | Core asset and debt pools. | Conservation of debt/collateral, caller permissions, pull/push payment boundaries. |
| `SortedTroves.sol`, `HintHelpers.sol`, `DebtInFrontHelper.sol`, `MultiTroveGetter.sol` | Ordering and read helpers. | List integrity, cursor behavior, view/read-only assumptions, gas bounds. |
| `RedemptionHelper.sol` | Branch-level redemption implementation. | Fee math, debt/collateral movement, shutdown/urgent redemption behavior. |

## JPYdf-Specific Layers

| Path | Role | Source docs |
| --- | --- | --- |
| `JpydfToken.sol` | Protocol debt token inherited from the Liquity token surface and renamed for JPYdf. | `documents/jp/protocol/product/spec/JpydfToken.md`, core spec |
| `DToken.sol` | dToken wrapper for underlying collateral assets. | `documents/jp/protocol/product/spec/dToken.md` |
| `CollateralVault.sol` | Underlying custody, buffer, delayed redeem, strategy interaction, and backing ratio. | `documents/jp/protocol/product/spec/CollateralVault.md` |
| `Strategies/` | Yield strategy implementations and common push model. Audit inclusion does not by itself mean launch manifest activation. | `documents/jp/protocol/product/spec/strategies/`, `documents/jp/engineering/guides/Contract-Audit-Scope-And-nSLOC.md` |
| `PriceFeeds/` | Chainlink/composite/placeholder price feed adapters. | `documents/jp/protocol/product/spec/Oracle.md` |
| `Zappers/` | UX routers and route adapters for collateral-yield flows, Sky ingress, Uniswap v4 final-leg evidence, and leftovers handling. Removed leverage / flash-close / Balancer / v3 surfaces are not part of the launch ABI. | `documents/jp/protocol/product/spec/Zapper.md`, `documents/jp/protocol/product/policies/Liquidity-Route-Policy.md` |
| `InterestRouterForwarder.sol` | Permissionless route from received interest to configured recipient. | `documents/jp/protocol/product/spec/InterestRouter.md` |
| `PILAllocator.sol`, `Initiatives/` | Phase-A PIL allocation and Merkl/Uniswap v4 liquidity incentive initiatives. | `documents/jp/protocol/product/spec/PILAllocator.md` |
| `LiquidationCandidateGetter.sol` | Read helper used by keepers to scan liquidatable Troves, including last zombie. | core spec, `bots/liquidator/README.md` |

## Supporting Folders

| Folder | Contents | Notes |
| --- | --- | --- |
| `Interfaces/` | External interfaces and internal protocol interfaces. | Prefer updating interfaces alongside implementation changes. |
| `Dependencies/` | Shared math, constants, ownership, and small inherited helpers. | Changes here have broad blast radius. |
| `NFTMetadata/` | Trove NFT metadata and SVG helpers. | Check both metadata rendering and token URI tests. |
| `Types/` | Lightweight value-type wrappers and shared structs. | Keep wrappers simple; avoid hidden behavior. |

## Cross-Cutting Audit Questions

- **Accounting conservation**: for every state-changing path, identify which
  pool or vault balance changes and which debt variable changes.
- **Oracle dependency**: verify whether a path uses current price, last good
  price, or a shutdown/frozen value.
- **SP offset awareness**: liquidation behavior depends on branch-local SP
  deposits; do not reason globally across branches.
- **Vault safety**: strategy impairment and backing ratio changes affect dToken
  and operator safety, but must not silently alter Liquity core invariants.
- **External calls**: zappers, strategies, tokens, and price feeds are the main
  callback/failure surfaces.
- **Generated consumers**: ABI or event changes affect frontend packages,
  subgraph mappings, ops scripts, and the liquidator bot.

## Where To Add Comments

Prefer short comments at transition points rather than repeating code:

- before non-obvious accounting movements between pools/vault/strategy;
- before guard sequences where order matters for CEI or oracle safety;
- before adapter boundaries whose removal would change active external
  expectations;
- around deliberate fail-open or fail-closed choices.

Avoid large narrative comments inside Solidity when a spec ID or this index is a
better reference.
