# JPY DeFi Day-1 Parameter Manifest

> Domain: Protocol
>
> Lifecycle: Launch
>
> Artifact Type: Manifest
>
> Schema Version: `3`
>
> Decision Authority: Protocol Governance
>
> Maintainer: DeltaForesight (Contributor)
>
> Status: Draft
>
> Manifest State: Candidate
>
> Environment: Ethereum mainnet
>
> Chain ID: `1`
>
> Release: Day1
>
> Normative Source: Self

## 1. Purpose and boundary

This document is the human-readable parameter manifest for the Ethereum mainnet Day-1 deployment. The machine-readable Owner Decision is [`config/day1-branch-manifest.json`](../../config/day1-branch-manifest.json); CI checks this document, code, and consumers against it.

- The Japanese [Parameter Catalog](../jp/protocol/product/parameters/Parameter-Catalog.md) defines parameter identifiers, units, bindings, mutability, and invariants.
- The Japanese [Collateral Parameter Policy](../jp/protocol/product/policies/Collateral-Parameter-Policy.md) governs future activation or post-launch changes. The Japanese [Day1 Parameter Decision](../jp/protocol/launch/decisions/Day1-Parameter-Decision.md) records Day-1 derivation and rationale.
- Deployment addresses, role holders, artifact hashes, and verification blocks belong in environment manifests and evidence.

The commit containing this file identifies its source revision. Environment-specific encoded amounts must be recorded in pre-broadcast freeze evidence referencing the same revision.

### 1.1 State transition

| State | Meaning | Update rule |
| --- | --- | --- |
| Candidate | Day-1 inputs under review | May change before approval |
| Approved | Protocol Governance approved a specific commit | Freeze this manifest; later changes use a new release artifact |
| Deployed / Verified | Block-tagged readback proves equality with Approved values | Do not overwrite this manifest with mutable on-chain state |

The manifest remains Candidate until the non-JPY oracle staleness inputs are frozen.

## 2. Day-1 branch scope

| Branch | dToken | Underlying | Day-1 state |
| ---: | --- | --- | --- |
| 0 | dwstETH | wstETH `0x7f39C581F595B53c5cb19bD0b3f8dA6c935E2Ca0` | active |
| 1 | dUSDC | USDC `0xA0b86991c6218b36c1d19D4a2e9Eb0cE3606eB48` | active |
| 2 | dETH | TBD | inert |
| 3 | dUSD-A | TBD | inert |
| 4 | dBTC | TBD | inert |
| 5 | dUSD-B | TBD | inert |
| 6 | dJPY | TBD | inert |
| 7 | dJGB | TBD | inert |

Only Branches 0 and 1 bind an Underlying, a real PriceFeed, and a CollateralYieldZapper and finalize Core risk parameters at deployment. Branches 2–7 have no bound Underlying, use `PriceFeedPlaceholder`, have cap 0, deploy neither a Strategy nor a CollateralYieldZapper, and remain `RESERVED`; their Core risk parameters are unfinalized, so they cannot be used on Day 1.

## 3. Day-1 parameter values

### 3.1 Core risk

The production protocol-wide `MIN_DEBT` (CORE-MOD-002 / CORE-LIB-FR-002) is `100_000e18` (100,000 JPYdf). It is common to every branch and is not part of branch-specific risk-parameter finalization.

The Branch 0–1 values are Core risk parameters finalized on Day 1. The displayed Branch 2–7 values are **bootstrap safety values** used to deploy valid but inactive Core contracts; they are neither approval values for future Underlyings nor reservation envelopes. After the exact Underlying is selected, derive all six risk values and the collateral compensation cap again under the [Core reserved-branch finalization requirements](protocol/product/spec/Liquity-v2-Core-Spec.md). The common Timelock finalizes them exactly once in the same activation ceremony that binds the Underlying and opens the cap. They cannot be changed, reverted, or unfrozen afterward.

When `riskParamsFinalized == false`, do not present the table's bootstrap values as public collateral terms. The contracts also reject Trove opening and Stability Pool deposits. The authoritative finalized values are the applicable activation parameter manifest, Timelock transaction, and block-tagged readback.

| Branch | dToken | Underlying | LLTV | MCR | CCR | SCR | BCR | SP penalty | Redistribution penalty |
| ---: | --- | --- | ---: | ---: | ---: | ---: | ---: | ---: | ---: |
| 0 | dwstETH | wstETH | 81.18% | 123.18% | 141.67% | 110% | 10% | 5% | 10% |
| 1 | dUSDC | USDC | 89.62% | 111.58% | 124.50% | 105% | 10% | 5% | 10% |
| 2 | dETH | TBD | 81.18% | 123.18% | 141.67% | 110% | 10% | 5% | 10% |
| 3 | dUSD-A | TBD | 83.33% | 120.00% | 137.65% | 105% | 10% | 5% | 10% |
| 4 | dBTC | TBD | 83.65% | 119.55% | 130.82% | 110% | 10% | 5% | 10% |
| 5 | dUSD-B | TBD | 83.33% | 120.00% | 137.65% | 105% | 10% | 5% | 10% |
| 6 | dJPY | TBD | 94.76% | 105.53% | 107.30% | 103.30% | 5% | 5% | 5% |
| 7 | dJGB | TBD | 94.76% | 105.53% | 107.30% | 103.30% | 5% | 5% | 5% |

| ID | Day-1 value |
| --- | ---: |
| `PRM-LIQ-KEEPER` | `min(0.5% × SP-offset collateral, branch cap)`; dwstETH: `2e18`, dUSDC: `1_000e18` |

### 3.2 dToken Layer

The Branch 0–1 cap and allocation amounts are freeze inputs. Branches 2–7 are not active token-denominated configurations: all remain at cap 0 and allocation 0.

| Branch | dToken | Underlying | mintCap | allocatorCooldown | allocateMaxMove | withdrawDelay | bufferTargetBps | bufferFloor |
| ---: | --- | --- | ---: | ---: | ---: | ---: | ---: | ---: |
| 0 | dwstETH | wstETH | JPY 35M | `1800s` | 0 | `259200s` | `333 bps` | 0 |
| 1 | dUSDC | USDC | JPY 100M | `1800s` | JPY 100M | `259200s` | `333 bps` | 0 |
| 2 | dETH | TBD | 0 | `1800s` | 0 | `259200s` | `333 bps` | 0 |
| 3 | dUSD-A | TBD | 0 | `1800s` | 0 | `259200s` | `333 bps` | 0 |
| 4 | dBTC | TBD | 0 | `1800s` | 0 | `259200s` | `333 bps` | 0 |
| 5 | dUSD-B | TBD | 0 | `1800s` | 0 | `259200s` | `333 bps` | 0 |
| 6 | dJPY | TBD | 0 | `1800s` | 0 | `259200s` | `333 bps` | 0 |
| 7 | dJGB | TBD | 0 | `1800s` | 0 | `259200s` | `333 bps` | 0 |

Convert nominal JPY caps and allocations into token amounts before handover. Record price, oracle round, block, formula, rounding, and encoded values in freeze evidence.

### 3.3 Oracle, governance, and bridge

| ID | Day-1 value |
| --- | ---: |
| `PRM-ORACLE-001` | `108000s` (30h) |
| `PRM-ORACLE-002` | `7200s` (2h; dwstETH redemption-only ETH/USD reference) |
| `PRM-ORACLE-006` | `86400s` (24h) |
| `PRM-ORACLE-007` | `90000s` (25h; dwstETH redemption-only stETH/ETH reference, 24h heartbeat + 1h grace) |
| `PRM-ORACLE-008` | `108000s` (30h; normal redemption and BorrowerOperations price-use gate based on shared JPY/USD round age) |
| `PRM-GOV-COMMON-TIMELOCK-DELAY` | `43200s` (12h) |
| `PRM-GOV-PRICE-FEED-SOURCE-DELAY` | `43200s` (12h) |
| `PRM-BRIDGE-MINTER-TIMELOCK` | `172800s` (48h) |

At shared JPY/USD age 30h, block new borrowing, debt increases, collateral withdrawals, normal redemption, and new permanent-shutdown decisions. Pure repayments and collateral additions require no oracle quote. Liquidations may continue until age 54h (30h validity plus 24h cached-rate grace), provided all other inputs remain valid. Cached FX can still cause missed or wrongful liquidations; pausing liquidation can instead increase collateral shortfalls. Product / Protocol Risk owns this residual trade-off. A fresh timestamp, including a same-value heartbeat, does not prove absence of market divergence.

The current candidate for `PRM-ORACLE-003` is `86400s`; `PRM-ORACLE-007` is
`90000s`. Because dwstETH redemption takes `max(direct, derived)`, it can select
a stale-high direct stETH/USD value or a stale-high derived value while the
ETH/USD (`PRM-ORACLE-002` = `7200s`) or stETH/ETH leg remains policy-valid.
The Product / Protocol Risk sign-off accepting possible redeemer underpayment is
not present in this Manifest and remains separate Ready / launch-blocker evidence.

## 4. Unfrozen launch inputs

| ID | Freeze gate |
| --- | --- |
| `PRM-ORACLE-003` | stETH/USD official metadata, fork block, and risk-owner sign-off |
| `PRM-ORACLE-004` | USDC/USD official metadata, fork block, and risk-owner sign-off |

Approved values for future branches, bridge routes, or other non-Day-1 surfaces are outside this manifest. Record them in a separately approved activation package. The Core values shown here for Branches 2–7 are bootstrap inputs only.
