# 🟢 Oracle Requirements Specification

## 0. Metadata

| Item | Value |
| --- | --- |
| Status | Draft (implementation exists; requirements are being canonicalized) |
| Owner | DeltaForesight |
| Target contracts | `contracts/src/PriceFeeds/PriceFeedProxy.sol` (outer fixed-reference layer, `Ownable2Step`) / `contracts/src/PriceFeeds/DFPriceFeedBase.sol` (DF JPY conversion base, `is MainnetPriceFeedBase`) / shared JPY layer: `contracts/src/PriceFeeds/JpyUsdRateProvider.sol` (deployment-wide JPY/USD cache / freeze state machine) / `contracts/src/PriceFeeds/JpyFreezeLib.sol` (shared JPY conversion / freeze / backing library) / Active collateral-specific PriceFeeds: `contracts/src/PriceFeeds/DFUSDCPriceFeed.sol` / `contracts/src/PriceFeeds/DFWstETHPriceFeed.sol` (stETH/USD × canonical rate composite, inherits `CompositePriceFeed`) / `contracts/src/PriceFeeds/PriceFeedPlaceholder.sol` (initial source for placeholder branches). Archived candidate feeds: `contracts/src/PriceFeeds/archive/DFUSDTPriceFeed.sol` / `contracts/src/PriceFeeds/archive/DFXAUTPriceFeed.sol` / `contracts/src/PriceFeeds/archive/DFWBTCPriceFeed.sol` / `contracts/src/PriceFeeds/archive/sUSDSPriceFeed.sol` (Composite rate, inherits `CompositePriceFeed`). 🔵 upstream-derived bases = `contracts/src/PriceFeeds/MainnetPriceFeedBase.sol` (with Chainlink response-validation hardening) / `contracts/src/PriceFeeds/CompositePriceFeed.sol` (upstream-derived base pruned for sUSDS to primary -> `lastGoodPrice`; WSTETH/RETH LST secondary fallback removed). Wiring = `contracts/script/DeployLiquity2.s.sol` |
| Related documents | [Product-Overview](../Product-Overview.md) (architecture and responsibility separation) / [Liquity-v2-Core-Spec](Liquity-v2-Core-Spec.md) (🔵 core collateral, liquidation, Redemption, and PriceFeed bases) / [CollateralVault](CollateralVault.md) (deferred Underlying binding and placeholder coordination) / [dToken](dToken.md) (placeholder branches, cap, setTokenInfo) / [Parameters](../../../Parameters.md) (branch↔collateral allocation, staleness, MCR/LLTV, etc.) |

> This document follows the [requirements specification standard](../../../README.md#requirements-spec-standard). Requirements, invariants, and security requirements are assigned persistent IDs (`ORCL-...`), and cross-references use those IDs.

---

## 1. Purpose, Scope, and Non-Responsibilities

The oracle layer is a DeltaForesight-specific layer that keeps the **oracle reference address used by the Liquity v2 core fixed**, while making the real PriceFeed behind it (the source) **replaceable**, and supplies all collateral prices **denominated in JPY**. Each collateral branch inserts one fixed-reference `PriceFeedProxy`, and JPY/USD conversion is added in the DF layer rather than baked into the upstream-derived PriceFeed base. The `MainnetPriceFeedBase` diff is limited to the Chainlink response-validation hardening described below.

- **Specified by this document**: `PriceFeedProxy` (fixed reference, 12h-timelocked source replacement, recoverable failure pause, validated resume, self-defense caches, `Ownable2Step`) / `DFPriceFeedBase` / collateral-specific oracle patterns / downward dToken-backing multiplication / placeholder binding / both consumer paths / wstETH redemption-lag protection / failure handling and monitoring.
- **Not specified by this document (non-responsibilities and other documents)**:
  - 🔵 internal behavior of upstream-derived price acquisition bases (`MainnetPriceFeedBase` / `CompositePriceFeed`), `PriceSource` state machine, Chainlink reads, 18-decimal normalization, and shutdown body -> [Liquity-v2-Core-Spec](Liquity-v2-Core-Spec.md) (this document specifies the DF-added layer, the `MainnetPriceFeedBase` Chainlink response-validation hardening, and the sUSDS-only pruning in `CompositePriceFeed`)
  - dToken placeholder launch, `setTokenInfo`, cap, and conversion -> [dToken](dToken.md)
  - Underlying custody, `setUnderlying`, mint/redeem, and buffer accounting -> [CollateralVault](CollateralVault.md)
  - Branch number ↔ collateral (Underlying) allocation, finalized/unfinalized status, finalized staleness values, MCR/LLTV/CCR, and depeg haircuts -> [Parameters](../../../Parameters.md)
- **Responsibility boundary (intentionally unaware)**: the oracle layer does not assume "which branch is which number"; it defines only oracle patterns for each collateral-asset type. Concrete branch↔collateral allocation and finalized status are read from [Parameters](../../../Parameters.md) as the canonical source.

---

## 2. Background and Design Policy

In Liquity v2, the protocol (BorrowerOperations / TroveManager) **directly references Chainlink Price Feed contracts**, and those reference addresses **cannot be changed** after deployment.

```javascript
Protocol (BorrowerOperations, TroveManager)
            ↓
Chainlink Price Feed (ETH/USD, BTC/USD...)
```

With this design unchanged, there is no way to replace a reference if Chainlink deprecates a specific feed, a feed fails, or the collateral asset composition is changed in the future. The DeltaForesight oracle layer solves this with the following policy.

- **Fixed reference + replaceable source**: Keep the "oracle reference address" seen by the Liquity v2 core fixed, while **inserting `PriceFeedProxy` and making the real PriceFeed (source) behind it replaceable**, enabling effective oracle replacement without modifying the core ([ORCL-FR-001](#orcl-fr-001) / [ORCL-FR-002](#orcl-fr-002)).
- **Isolate failures by leg**: collateral, peg-monitor, canonical-rate, and backing legs use the recoverable oracle-failure pause. The shared JPY/USD leg first uses the bounded soft-freeze in `ORCL-SEC-005`.
- **Localize DF-specific behavior**: upstream-base changes are limited to Chainlink response-validation hardening. JPY conversion and backing-ratio application stay in the DF layer (`ORCL-SEC-001`).
- **Register all 8 branches + placeholder**: With the dToken approach, all 8 branches are registered on Day 1. Branches whose Underlying is not finalized are deployed with `PriceFeedPlaceholder` as their initial source and activated on Day 2 ([ORCL-FR-008](#orcl-fr-008) / [ORCL-FR-009](#orcl-fr-009)).

The normative design decisions are `ORCL-SEC-001`, `ORCL-SEC-003`, and `ORCL-SEC-005`. The quantitative basis for JPY/USD staleness is the [design memo](../../launch/decisions/jpyusd-staleness-threshold-determination.md), and the overall no-core-modification policy is canonical in [Product Overview](../Product-Overview.md).

---

## 3. Terms, External Dependencies, and Assumptions

### 3.1 Overall Architecture

```plain text
┌─────────────────────────────────────────────────────────────────┐
│ Protocol (BorrowerOperations, TroveManager, StabilityPool)       │
└───────────────────────────────┬─────────────────────────────────┘
                                │ fetchPrice() / fetchRedemptionPrice()
                                ▼
┌─────────────────────────────────────────────────────────────────┐
│ PriceFeedProxy (Ownable2Step, non-upgradeable)                   │
│  - source (replaceable, 12h timelock)                            │
│  - _lastGoodPrice / _lastGoodRedemptionPrice (self-defense cache)│
│  - ownership (2-step transfer / renounce disabled)               │
└───────────────────────────────┬─────────────────────────────────┘
                                │ delegates to source
                                ▼
┌─────────────────────────────────────────────────────────────────┐
│ DF PriceFeed implementations (e.g. wstETH / USDC / sUSDS)        │
│   inheritance = upstream-derived price base + DF JPY base         │
│                                                                   │
│  ┌──────────────────────────────┐   ┌──────────────────────────┐ │
│  │ 🔵 upstream-derived           │   │ 🟢 DF: DFPriceFeedBase    │ │
│  │  MainnetPriceFeedBase /       │ + │   (is MainnetPriceFeedBase)│ │
│  │  CompositePriceFeed (sUSDS)   │   │  ├ jpyUsdOracle (JPY/USD) │ │
│  │  ├ Collateral/USD Chainlink   │   │  └ _convertUsdPriceToJpyWithFreeze │ │
│  │  ├ canonical rate (composite) │   └──────────────────────────┘ │
│  │  └ PriceSource / lastGoodPrice│                                │
│  └──────────────────────────────┘   collateral/USD failure -> shutdown │
│                                      JPY/USD failure -> soft-freeze      │
└─────────────────────────────────────────────────────────────────┘
```

Relationship between fixed reference and replaceable source (address seen by Protocol is fixed; source behind it is replaceable):

```javascript
Protocol (BorrowerOperations, TroveManager)
            ↓  ★Address referenced by Protocol is fixed (same as Liquity v2)
PriceFeedProxy
            ↓  ★source referenced by PriceFeedProxy (= actual PriceFeed implementation) is replaceable
Various PriceFeeds (DFWstETHPriceFeed, DFUSDCPriceFeed, etc.)
            ↓  ★Internally references Chainlink feeds
Chainlink Aggregator (+ Chainlink JPY/USD for JPY conversion)
```

Assignment of finalized/unfinalized branches and PriceFeedProxy:

```javascript
Protocol
 ├─ finalized branch   -> PriceFeedProxy#n -> real PriceFeed (per collateral: Standard / Composite rate / Composite peg, §6)
 └─ unfinalized branch -> PriceFeedProxy#n -> PriceFeedPlaceholder (replaced with real feed on Day 2)
                              ↑
                        One PriceFeedProxy per branch
                        (passed to core logic as the fixed reference. Branch number↔collateral is canonical in Parameters.md)
```

### 3.2 Deriving collateral/JPY price

```javascript
Collateral/JPY       = (Collateral/USD) ÷ (JPY/USD)          // market price (per-collateral _fetchPricePrimary)
dToken/JPY collateral value = (Collateral/JPY) × backingRatio / 1e18 // shared final layer (ORCL-FR-014)
```

The Chainlink JPY/USD feed (`0xBcE206caE7f0ec07b545EddE332A47C2F75bbeb3`) returns **USD per JPY** (≈ 0.006667), so the division above converts to JPY. One deployment-wide `JpyUsdRateProvider` reads Chainlink and owns the cache/freeze state; every active feed asks that provider for the conversion rate. `DFPriceFeedBase` and `sUSDSPriceFeed` perform only the final division.

**JPY update policy**: Historical observations show updates near the 24h heartbeat during weekends and holidays; nearly 72h of silence is not normal weekend behavior. Use `PRM-ORACLE-001 = 30h` plus `006 = 24h` cached-rate grace for liquidation, while normal redemption and BorrowerOperations price use stop at `008 = 30h`. See [Parameters](../../../Parameters.md) and ORCL-SEC-005.

**Consistency with EUR CDPs**: Angle Borrowing Module for EURA/agEUR also handles prices such as USDC/EUR by composing Chainlink feeds such as `USDC/USD` and `EUR/USD`. Its implementation reverts with `InvalidChainlinkRate` when `latestRoundData()` `updatedAt` exceeds `stalePeriod`, and it does not carry weekday/holiday calendars on-chain (references: [Angle Borrowing Module Architecture](https://developers.angle.money/borrowing-module-contracts/architecture-overview), [Angle `BaseOracleChainlinkMulti`](https://github.com/AngleProtocol/borrow-contracts/blob/main/contracts/oracle/BaseOracleChainlinkMulti.sol), [Angle `OracleUSDCEURChainlink`](https://github.com/AngleProtocol/borrow-contracts/blob/main/contracts/oracle/implementations/mainnet/EUR/OracleUSDCEURChainlink.sol)). JPYdf adopts the same operational philosophy: FX feeds are handled with "sufficiently long staleness threshold + `updatedAt`", not calendar logic.

In the final step, multiply by **dToken backing ratio (`A / L_effective`, `<= 1e18`)** so Strategy impairment and dToken depeg are reflected in collateral value ([ORCL-FR-014](#orcl-fr-014)). In healthy state, `backingRatio == 1e18` and price equals market price.

### 3.3 Terms

| Term | Meaning |
| --- | --- |
| source | Actual PriceFeed implementation delegated to by `PriceFeedProxy`. Replaceable (12h timelock) |
| collateral/USD oracle | Chainlink aggregator for the collateral asset denominated in USD. Upstream storage name is `ethUsdOracle` (same name even for non-ETH collateral; this document uses `collUsdOracle` in pseudocode for readability) |
| `jpyUsdOracle` | Chainlink aggregator for JPY/USD (**returns USD per JPY**). Held once by `JpyUsdRateProvider` |
| `jpyUsdRateProvider` | Single deployed JPY rate/cache/freeze state machine injected into every active feed. Its address must be identical across branches |
| canonical rate | Underlying conversion rate for yield-bearing tokens (USDS per sUSDS for sUSDS). Retrieved from a rate-provider contract, not Chainlink |
| `PriceSource` | Price source state (`primary` / `ETHUSDxCanonical` / `lastGoodPrice`). Upstream `MainnetPriceFeedBase` definition is retained, but current production feeds use only `primary` / `lastGoodPrice` |
| `lastGoodPrice` | Last healthy price returned during failures. Two layers: upstream base (per feed) and Proxy (normal path `_lastGoodPrice` / redemption path `_lastGoodRedemptionPrice`) |
| oracle failure pause | Recoverable branch pause via `borrowerOperations.shutdownFromOracleFailure()`, distinct from irreversible economic shutdown when `TCR < SCR` |
| placeholder branch | Collateral slot deployed before Underlying is finalized and activated on Day 2. Initial source is `PriceFeedPlaceholder` |
| Peg Monitor | Monitoring feed for wrapper vs underlying peg divergence (WBTC/BTC, XAUT/XAU) |
| GOV / multisig | Owner of `PriceFeedProxy` (governance multisig) |

### 3.4 External Dependencies (trusted external components)

- **Chainlink Data Feeds** — price sources for collateral/USD, JPY/USD, and peg monitoring (WBTC/BTC, etc.). The upstream-derived base validates `roundId != 0`, `answeredInRound >= roundId`, `updatedAt != 0`, `updatedAt <= block.timestamp`, staleness, and `answer > 0`. A successful `latestRoundData()` does not guarantee the round reflects the current market, and **using a price with a stale `updatedAt` for collateral valuation, liquidation, or redemption would lead to over-borrowing at an old high, over-liquidation at an old low, and JPY-denominated valuation drift from delayed FX conversion**; therefore any response that fails these checks is treated as invalid and fail-closed. JPY/USD uses an explicit 30h cutoff and bounded liquidation grace (§3.2 / [ORCL-SEC-005](#orcl-sec-005)).
- **sUSDS contract** (`0xa3931d71877C0E7a3148CB7Eb4463524FEc27fbD`, rate provider) — reads ERC-4626 `convertToAssets(1e18)` directly as canonical rate (not Chainlink).
- **wstETH contract** (`0x7f39C581F595B53c5cb19bD0b3f8dA6c935E2Ca0`, rate provider) — reads `stEthPerToken()` directly as the canonical stETH-per-wstETH rate. This non-Chainlink rate has no staleness concept (`ORCL-FR-015`).
- **🔵 upstream-derived price acquisition bases** (`MainnetPriceFeedBase` / `CompositePriceFeed`) — handle Chainlink acquisition, 18-decimal normalization, gas griefing protection, `PriceSource`, and shutdown body. `MainnetPriceFeedBase` has the Chainlink response-validation hardening diff; `CompositePriceFeed` is used as an upstream-derived base pruned for the sUSDS primary -> `lastGoodPrice` path (WSTETH/RETH LST secondary fallback removed from production `src`, [Liquity-v2-Core-Spec](Liquity-v2-Core-Spec.md)).
- **OpenZeppelin `Ownable2Step`** — 2-step ownership transfer for `PriceFeedProxy`.

### 3.5 Assumptions

- The Liquity v2 core fixes oracle reference addresses at deployment and cannot change them from the core side.
- Chainlink collateral/USD and JPY/USD feeds both use 8 decimals at deployment. On every read, the shared `JpyUsdRateProvider` also compares live `decimals()` with its constructor-pinned value. A mismatch or ordinary metadata-read failure invalidates the response without scaling or caching it; insufficient-gas failure re-reverts through the existing gas guard. Oracle values are normalized to 18 decimals only after this validation.
- JPY/USD feed returns **USD per JPY** (≈ 0.006667). JPY-denominated price is obtained by division `collUsd × 1e18 / jpyUsdRate`.
- JPY/USD staleness includes weekends. No weekday/holiday calendar is kept on-chain; if the threshold is exceeded, `lastGoodJpyRate` soft-freeze is used. Collateral/USD, peg-monitoring, or canonical-rate failures enter the recoverable oracle-failure pause.
- Branch number ↔ collateral (Underlying) assignment and finalized/unfinalized status are canonical in [Parameters](../../../Parameters.md) (this document does not assign numbers).

---

## 4. Actors, Roles, and Trust Boundaries

| Actor | Operations | Trust boundary |
| --- | --- | --- |
| **Owner (GOV / multisig)** | `proposeSource` / `confirmSource` / `cancelSourceProposal` / `transferOwnership` / `acceptOwnership` / `renounceOwnership` | Strong authority (source replacement, ownership transfer). Production owner is governance / multisig. Initial deploy owner is deployer EOA. `renounceOwnership` is disabled |
| **Protocol (BorrowerOperations / TroveManager / StabilityPool)** | `fetchPrice` / `fetchRedemptionPrice` | Canonical core consumer. Calls `PriceFeedProxy` as fixed reference. Trust relation requires `shutdownFromOracleFailure()` caller to be `address(priceFeed)` (= Proxy) ([ORCL-FR-004](#orcl-fr-004)) |
| **source (actual PriceFeed)** | Returns price when delegated by Proxy | Replaceable. Proxy treats source revert / invalid price / brick defensively (not fully trusted) |
| **CollateralVault (backing source)** | source reads `backingRatioForPricing()` | Read-only source for dToken backing ratio (`A / L_effective`) and valuation availability. A normal read failure or `available == false` enters oracle-failure pause ([ORCL-FR-014](#orcl-fr-014)). Accounting remains on Vault side |
| **Anyone (permissionless)** | `fetchPrice` / `fetchRedemptionPrice` (view-like read) / observing source proposals | No trust required |

- **Authority separation**: source replacement and ownership transfer are Owner-only. Price acquisition paths (`fetchPrice` / `fetchRedemptionPrice`) have no authorization and anyone reads the same price.
- **Operations policy (ownership transfer)**: initially owned by deployer EOA, and during production transition transferred to **governance / multisig** through `transferOwnership()` -> `acceptOwnership()` by the new owner. In production the Owner is held directly by the GOV multisig and is **not** placed under the common TimelockController (source replacement is already protected by PriceFeedProxy's built-in 12h timelock; routing it through the common Timelock would add a 12h+12h double delay and lose cancel immediacy) ([ORCL-GOV-001](#orcl-gov-001) / [ORCL-GOV-002](#orcl-gov-002)).

---

## 5. Interface Specification

Major functions of `PriceFeedProxy` (outer fixed-reference layer) and DF PriceFeed implementations (inner source). Behavior is defined in §6 Functional Requirements; only visibility is summarized below (non-normative).

Each DF PriceFeed inherits its upstream-derived price acquisition base, obtains the deployment-wide JPY rate from `JpyUsdRateProvider`, and applies its branch-local dToken backing ratio. The JPY-conversion / freeze / backing logic itself is the shared `JpyFreezeLib`; `DFPriceFeedBase` (standard and peg feeds) and the composite feeds (`sUSDSPriceFeed` / `DFWstETHPriceFeed`, which preserve the pruned `CompositePriceFeed` inheritance) only hold the library's state and wire it in. JPY cache/freeze state is never duplicated. `MainnetPriceFeedBase` only carries the explicit Chainlink response-validation hardening.

**PriceFeedProxy (`Ownable2Step`, non-upgradeable)**

| Function | Visibility | Summary | Requirement |
| --- | --- | --- | --- |
| `proposeSource(address newSource)` | external (onlyOwner) | Propose new source (starts 12h timelock) | ORCL-FR-001 |
| `confirmSource()` | external (onlyOwner) | Confirm source replacement after timelock (price-difference guard in normal cases) | ORCL-FR-002 |
| `confirmSourceEmergency()` | external (onlyOwner) | Confirm source replacement after timelock (explicitly bypasses the old-source read and price-difference guard) | ORCL-FR-002 |
| `cancelSourceProposal()` | external (onlyOwner) | Cancel pending source proposal | ORCL-FR-003 |
| `fetchPrice() -> (uint256, bool)` | external | Delegate to source, pass through failures, delegate shutdown | ORCL-FR-004 |
| `fetchRedemptionPrice() -> (uint256, bool)` | external | Delegate redemption price with same structure | ORCL-FR-005 |
| `transferOwnership(address)` / `acceptOwnership()` | external (onlyOwner / pendingOwner) | 2-step ownership transfer | ORCL-FR-006 |
| `renounceOwnership()` | external (onlyOwner) | Always reverts with `RenounceOwnershipDisabled` | ORCL-FR-007 |
| `_bubbleIfGasError(bytes)` | internal | Pass through gas-guard reverts | ORCL-FR-004 |
| `TIMELOCK_DELAY` | constant | `12 hours` | ORCL-FR-001 |

**DF PriceFeed implementations (inner source)**

| Function | Visibility | Summary | Requirement |
| --- | --- | --- | --- |
| `_fetchPricePrimary()` | internal | collateral/USD -> JPY conversion -> record `lastGoodPrice` | ORCL-FR-010-013 |
| `JpyUsdRateProvider.fetchJpyUsdRate()` | external, permissionless | Read JPY/USD and return the one shared live/frozen rate and expiry decision. The provider alone stores `lastGoodJpyRate`, its `updatedAt`, and `jpyFrozenSince`; 24h expiry is latched across all consumers | ORCL-FR-010 / ORCL-SEC-005 |
| `_convertUsdPriceToJpyWithFreeze(uint256 usdPrice)` | internal (implemented by shared `JpyFreezeLib`) | Fetch the shared provider result and convert USD->JPY. An expired shared freeze enters oracle-failure pause | ORCL-FR-010 / ORCL-SEC-005 |
| `_getCanonicalRate()` | internal (composite) | Canonical rate: sUSDS `convertToAssets(1e18)`, wstETH `stEthPerToken()` | ORCL-FR-012 / ORCL-FR-015 |
| `_applyBackingRatio(uint256 collJpy)` | internal (implemented by the shared `JpyFreezeLib`; state held per feed) | Multiply by `collateralVault.backingRatioForPricing()` and return actual dToken collateral value. A normal read failure or unavailable valuation is an oracle failure; a gas guard revert is re-reverted | ORCL-FR-014 |
| `fetchPrice()` / `fetchRedemptionPrice()` / `lastGoodPrice()` | external | IPriceFeed standard from upstream base | [Liquity-v2-Core-Spec](Liquity-v2-Core-Spec.md) |

**PriceFeedPlaceholder (initial source for placeholder branches)**

| Function | Visibility | Summary | Requirement |
| --- | --- | --- | --- |
| `fetchPrice()` / `fetchRedemptionPrice()` | external view | Stub that always returns `(1e18, false)` | ORCL-FR-008 |

---

## 6. Functional Requirements (FR)

> §6.A = PriceFeedProxy (outer fixed-reference layer). §6.B = DF PriceFeed implementation (inner source / collateral-specific oracle patterns). §6.C = placeholder branches and post-launch binding.

### 6.A PriceFeedProxy (outer fixed-reference layer)

`PriceFeedProxy` is a normal contract inheriting OpenZeppelin **`Ownable2Step`**; it has no proxy/upgrade mechanism such as UUPS (non-upgradeable). The name "Proxy" means it acts as the **fixed reference** from the Protocol perspective and replaces the `source` (actual PriceFeed) behind it. It does not update its own contract logic with `upgradeTo`. To change logic, deploy a new PriceFeed and replace the source with `proposeSource()` (= feed-level replacement).

#### <a id="orcl-fr-001"></a>ORCL-FR-001: Propose source replacement (`proposeSource`)

- **Type**: Functional | **Source**: Product-Overview "Oracle Layer" / DF design rationale (feed replacement and MEV mitigation)
- **Signature**: `proposeSource(address newSource)`
- **Purpose**: Register a proposal to replace the actual PriceFeed (source) behind the Proxy and start a 12h timelock. Immediate replacement is not allowed; the planned switch time and new source are published 12h in advance (enabling pre-audit and cancellation).
- **Authorization**: Owner (GOV / multisig) only (`onlyOwner`).
- **Preconditions (Checks)**: `caller == Owner`. `newSource` is a valid address (as in constructor, `address(0)` / EOA and a direct source returning the `IPriceFeedProxy.source()` marker are not allowed = `InvalidSource`) and must differ from the current `source` (`SameSource` otherwise). The marker is a one-level type screen based only on a 32-byte getter response; it does not prove that forwarding wrappers or the wider dependency graph are acyclic.
- **Behavior (Effects)**:
  1. Record pending source proposal (`newSource` and confirmable time = `block.timestamp + TIMELOCK_DELAY`)
  2. Emit `SourceProposed` (indexes new source and confirmable time)
- **Revert / early return**: non-Owner -> revert; `newSource == address(0)` / EOA -> `InvalidSource`; `newSource == source` -> `SameSource`.
- **Emitted event**: `SourceProposed` ([ORCL-EVT-001](#11-events-and-monitoring-requirements-evt)).
- **Design notes**: `TIMELOCK_DELAY = 12 hours` (constant). It is shorter than the shared JPY soft-freeze bound (`PRM-ORACLE-006` = 24h), preserving time to recover the source after incident detection. Timelock alone does not eliminate **price-jump MEV** in the `confirmSource` block (e.g. redemption/liquidation immediately after switch at new price), so it is combined with a confirmation-time price-difference guard and private sending operations ([ORCL-SEC-003](#orcl-sec-003)).
- **Verification**: unit (Owner-only, reject `address(0)` / EOA / self / direct marker, proposal recorded), manual (ORCL-GOV-004 dependency evidence).

#### <a id="orcl-fr-002"></a>ORCL-FR-002: Confirm source replacement (`confirmSource`)

- **Type**: Functional | **Source**: Product-Overview "Oracle Layer" / DF design rationale
- **Signature**: `confirmSource()` / `confirmSourceEmergency()`
- **Purpose**: After the 12h timelock elapses, confirm the pending source proposal and replace `source` with the new PriceFeed.
- **Authorization**: Owner (GOV / multisig) only.
- **Preconditions (Checks)**: `caller == Owner`; pending proposal exists; current time is at or after confirmable time (`proposedAt + TIMELOCK_DELAY`).
- **Behavior (Effects)**:
  1. `confirmSource()` best-effort reads the old source and treats it as healthy only when its price paths return valid prices with `failure=false`. `confirmSourceEmergency()` never calls the old source and uses the Proxy caches as its reference, preserving recovery even if the old source consumes all forwarded gas; the event reports `oldSourceHealthy=false`
  2. Reject a new source returning the `IPriceFeedProxy.source()` marker as a direct type screen, then smoke-test all three new-source price paths; reject on revert / wrong ABI / invalid price / `failure=true`. Neither the marker nor smoke tests prove semantic forwarding or dependency-graph acyclicity. Also validate `jpyUsdRateProvider()` and the provider's `lastGoodJpyUpdatedAt()` through 30,000-gas, fixed 32-byte return buffers; missing, malformed, or oversized-return getters, non-contract providers, and zero/future timestamps are `InvalidSource`. An `AGED` source may still be confirmed, but its redemption quote is not cached
  3. Use live old-source normal and urgent prices while all three old-source paths are healthy. Use the live old-source normal-redemption price only when its JPY provenance is fresh; otherwise use `_lastGoodRedemptionPrice`. If the old source is unhealthy, use `_lastGoodPrice` for normal and `_lastGoodRedemptionPrice` for normal-redemption and urgent continuity
  4. `confirmSource()` requires all three new-source prices to be within `MAX_SOURCE_SWITCH_DEVIATION_BPS` (1%) of those references regardless of old-source health. Only `confirmSourceEmergency()` explicitly bypasses the price-difference guard
  5. Re-initialize `_lastGoodPrice`. Update `_lastGoodRedemptionPrice` only while JPY/USD age is below `PRM-ORACLE-008`; never cache an age-gated quote
  6. Set `source = proposedSource` (replacement complete), clear pending proposal
  7. Emit `SourceUpdated` / `SourceSwitchValidated`
- **Revert / early return**: non-Owner -> revert; no proposal -> `NoProposalPending`; timelock not elapsed -> `TimelockNotElapsed`; invalid new source -> `InvalidSource`; `proposedSource == source` -> `SameSource`; normal confirm with a price difference > 1% from the live/cached reference -> `SourcePriceDeviationTooLarge`.
- **Emitted event**: `SourceUpdated(oldSource, newSource)` ([ORCL-EVT-002](#11-events-and-monitoring-requirements-evt)), `SourceSwitchValidated` ([ORCL-EVT-006](#11-events-and-monitoring-requirements-evt)).
- **Design notes**: Normal replacement suppresses sandwich opportunity with the price-difference guard. An old-source failure does not silently turn the normal path into an emergency path; continuity is checked against validated caches. Placeholder activation or incidents requiring more than a 1% correction from cached prices use `confirmSourceEmergency()` sent privately (Flashbots Protect, etc.) and combined with cap stops / keeper bundles as needed ([ORCL-SEC-003](#orcl-sec-003)). The emergency path retains the new source's three-path smoke test; it bypasses only the old-source read and price-difference guard. The on-chain smoke test cannot distinguish a legacy source's terminal `lastGoodPrice` state from a live response or prove its callback dependency structure. Operations therefore propose only a fresh deployment of the current source implementation and verify both `priceSource() == primary` and unchanged ORCL-GOV-004 dependency evidence at proposal and immediately before confirmation.
- **Verification**: unit (succeeds only after timelock, reverts before, replacement reflected, live/cached price-difference guard, no implicit bypass on old-source failure, emergency bypass, emergency replacement of an old source that consumes all gas), manual (private-send operations).

#### <a id="orcl-fr-003"></a>ORCL-FR-003: Cancel source proposal (`cancelSourceProposal`)

- **Type**: Functional | **Source**: DF design rationale (ability to interrupt replacement)
- **Signature**: `cancelSourceProposal()`
- **Purpose**: Allow Owner to cancel a pending source proposal during timelock and return to clean state.
- **Authorization**: Owner (GOV / multisig) only.
- **Preconditions (Checks)**: `caller == Owner`; pending proposal exists.
- **Behavior (Effects)**:
  1. Clear pending proposal (source unchanged)
  2. Emit `SourceProposalCancelled`
- **Revert / early return**: non-Owner -> revert; no proposal -> `NoProposalPending`.
- **Emitted event**: `SourceProposalCancelled` ([ORCL-EVT-003](#11-events-and-monitoring-requirements-evt)).
- **Design notes**: Because Owner renounce is disabled, unnecessary pending proposals are explicitly cancelled with `cancelSourceProposal()` ([ORCL-FR-007](#orcl-fr-007)).
- **Verification**: unit (Owner-only, proposal cleared).

#### <a id="orcl-fr-004"></a>ORCL-FR-004: `fetchPrice` (failure pass-through and pause delegation)

- **Type**: Functional | **Source**: Liquity-v2-Core-Spec (shutdown mechanism) / DF design rationale (Proxy protection layer)
- **Signature**: `fetchPrice() -> (uint256 price, bool oracleFailure)` (IPriceFeed-compatible) / `resumeFromOracleFailure()`
- **Purpose**: Delegate to source `fetchPrice()` while the Proxy acts as a protection layer. If the underlying feed directly calls `borrowerOperations.shutdownFromOracleFailure()` on oracle failure, `msg.sender` is the underlying feed, violating BorrowerOperations' requirement `msg.sender == address(priceFeed)` (= Proxy) and causing revert. To avoid this, Proxy catches source revert / invalid price with `try/catch` and calls `shutdownFromOracleFailure()` **itself**.
- **Authorization**: none (permissionless; Protocol/anyone can read).
- **Preconditions (Checks)**: none (defense handled in catch path).
- **Behavior (Effects)**:
  1. `try IPriceFeed(source).fetchPrice()`
  2. On source success, update `_lastGoodPrice`. For the BorrowerOperations caller only, invalid JPY provenance or age >=30h returns `(price, true)` without latching pause. This gates borrowing, withdrawals, close, and new TCR/SCR shutdown decisions. Liquidation keeps source-policy-valid pricing. Pure repayments and additions do not call this path.
  3. If revert is gas guard (`InsufficientGasForExternalCall`, exactly 4 bytes) -> `_bubbleIfGasError` **re-reverts as is** (no shutdown; entire call reverts)
  4. For any other revert, invalid price, or source `oracleFailure == true` -> `try borrowerOperations.shutdownFromOracleFailure()` to latch the recoverable pause. The normal path then tries `IPriceFeed(source).lastGoodPrice()` and updates `_lastGoodPrice` if it is readable and valid. The redemption path does **not** read `source.lastGoodPrice()` because that view is not redemption-specific; it returns the Proxy's own `_lastGoodRedemptionPrice`. If the normal source cache is bricked, the Proxy returns its own `_lastGoodPrice` (prevents permanent DoS).
  5. `resumeFromOracleFailure()` is Owner-only. It requires an active BO pause and validates all three current-source price reads as non-sentinel with `failure == false` in one transaction. It always refreshes the normal cache, refreshes the normal-redemption cache only with fresh JPY provenance, and then clears the BO pause. Aged/invalid provenance therefore does not prevent pause clearance when all three prices are healthy, but the FR-005 normal-redemption gate remains. Source recovery or replacement alone does not auto-resume.
- **Revert / early return**: gas guard revert (`InsufficientGasForExternalCall`, strict 4 bytes) -> re-revert unchanged.
- **Emitted event**: the failure path emits `SourceFailureHandled`; validated resume emits `OracleFailureShutdownResumed` ([ORCL-EVT-004/011](#11-events-and-monitoring-requirements-evt)).
- **Design notes**:
  - **Invalid price determination**: `price == 0` or `price == type(uint256).max`.
  - **Passing through gas griefing protection**: `MainnetPriceFeedBase` intentionally reverts with `InsufficientGasForExternalCall()` when Chainlink call failure appears to be due to insufficient gas (`gasleft() <= gasBefore / 64`), so OOG is not mistaken for oracle failure (§5). If Proxy try/catch indiscriminately sends this protective revert to shutdown, the protection is effectively disabled across Proxy. Therefore catch re-reverts raw only when revert data matches the `InsufficientGasForExternalCall` selector **and is exactly 4 bytes** (`_bubbleIfGasError`). All other failures follow the usual shutdown path.
  - **Distinguishing real oracle failures**: Real failures can also reach Proxy as 4-byte errors such as `CallerNotPriceFeed()`. Length alone cannot distinguish them, so selector equality is used and length is strictly `== 4` (selector prefix with appended data does not re-revert). This lets only the gas guard pass through while real failures still shutdown ([ORCL-SEC-002](#orcl-sec-002)).
  - **Compile-time coupling to upstream**: the selector compared is `MainnetPriceFeedBase.InsufficientGasForExternalCall.selector`, directly referencing upstream at compile time (no local mirror). If upstream renames/removes the error, this file fails to compile and the protection cannot silently disappear ([ORCL-SEC-002](#orcl-sec-002)).
- **Verification**: unit (valid price passthrough, invalid-price pause, path-specific Proxy cache returned when source fetches are bricked, both paths validated, Owner-only resume, recovery/replacement alone does not clear the BO flag or reopen normal redemption, oracle-independent risk-reducing BO carve-out), fork (real feed failure scenario), integration (gas guard re-revert vs real failure distinction).

#### <a id="orcl-fr-005"></a>ORCL-FR-005: `fetchRedemptionPrice` (redemption consumer path)

- **Type**: Functional | **Source**: Liquity-v2-Core-Spec (Redemption) / DF design rationale
- **Signature**: `fetchRedemptionPrice() -> (uint256 price, bool isShutdown)`
- **Purpose**: Delegate redemption price acquisition to source `fetchRedemptionPrice()` with the same try/catch structure as `fetchPrice`, while stopping **normal redemption** when shared JPY/USD round age reaches `PRM-ORACLE-008` (30h).
- **Authorization**: none (permissionless).
- **Preconditions (Checks)**: none.
- **Behavior (Effects)**:
  1. Call source `fetchRedemptionPrice()` first, so the first call observing a fresh round updates provenance and automatically clears the age gate
  2. Preserve `_handleFailedFetch(true)`, BO oracle pause, and `SourceFailureHandled` for source revert, invalid price, or source `failure=true`
  3. After source success, read the current source's `jpyUsdRateProvider()` and its `lastGoodJpyUpdatedAt()` with bounded 30,000-gas staticcalls. Invalid provenance or `block.timestamp - updatedAt >= PRM-ORACLE-008` returns `(price, true)` without `_handleFailedFetch` or a cache write
  4. Update `_lastGoodRedemptionPrice` only with fresh provenance. The existing BO latch still forces `failure=true` until Owner resume
- **Revert / early return**: strict four-byte gas-guard revert -> re-revert. Age/provenance gate -> return a valid price and `true`, without BO pause or failure event.
- **Emitted event**: real source failures emit the same events as [ORCL-FR-004](#orcl-fr-004); the age/provenance gate itself emits none.
- **Design notes**: Real source-failure defenses remain symmetric. FR-004 also applies the 30h gate to BorrowerOperations, while liquidation and FR-016 urgent redemption retain the source cached-rate policy. Resume and source confirmation never cache an age-gated redemption quote.
- **Verification**: unit (30h−1s / 30h boundary, first-call recovery, cache isolation, real-failure priority, malformed/gas-grief provenance, source switch and resume), integration (TroveManager pre-mutation zero and Helper simulation/refund).

#### <a id="orcl-fr-006"></a>ORCL-FR-006: 2-step ownership transfer (`transferOwnership` / `acceptOwnership`)

- **Type**: Functional | **Source**: OpenZeppelin `Ownable2Step`
- **Signature**: `transferOwnership(address newOwner)` / `acceptOwnership()`
- **Purpose**: Prevent erroneous transfer caused by typos, etc. Ownership is finalized only after `transferOwnership(newOwner)` is followed by `acceptOwnership()` by the new owner. Used to transfer from deployer EOA to governance / multisig during production transition.
- **Authorization**: `transferOwnership` = Owner only / `acceptOwnership` = pending owner only.
- **Preconditions (Checks)**: `transferOwnership`: `caller == Owner`. `acceptOwnership`: `caller == pendingOwner`.
- **Behavior (Effects)**:
  1. `transferOwnership`: `pendingOwner = newOwner` (ownership not yet transferred)
  2. `acceptOwnership`: `owner = pendingOwner`, clear `pendingOwner`
  3. Emit OZ `OwnershipTransferStarted` / `OwnershipTransferred`
- **Revert / early return**: non-Owner `transferOwnership` -> revert; non-pendingOwner `acceptOwnership` -> revert.
- **Emitted event**: OZ `OwnershipTransferStarted(previousOwner, newOwner)` / `OwnershipTransferred(previousOwner, newOwner)` ([ORCL-EVT-005](#11-events-and-monitoring-requirements-evt)).
- **Design notes**: 2-step policy aligns with dToken ([DTKN-GOV-002](dToken.md)) and Vault GOV operations ([ORCL-GOV-002](#orcl-gov-002)).
- **Verification**: unit (2-step finalization, mistaken transfer prevention), manual (production transition configuration review).

#### <a id="orcl-fr-007"></a>ORCL-FR-007: `renounceOwnership` (disabled)

- **Type**: Functional | **Source**: JPY/USD shared dependency and source-replacement recovery path preservation
- **Signature**: `renounceOwnership()`
- **Purpose**: Prevent permanently losing source replacement authority through Owner renounce. Owner is not burned; it is transferred to governance / multisig so recovery paths remain for JPY/USD shared dependency incidents, Chainlink deprecation, and placeholder branch activation.
- **Authorization**: Owner (GOV / multisig) only.
- **Preconditions (Checks)**: `caller == Owner`.
- **Behavior (Effects)**:
  1. Always revert with `RenounceOwnershipDisabled`
  2. Do not change `owner` / `pendingOwner` / `proposedSource` / `sourceProposedAt`
- **Revert / early return**: non-Owner -> revert.
- **Emitted event**: none.
- **Design notes**: Pending proposals are cancelled through `cancelSourceProposal()`, and pending ownership transfers through `transferOwnership(address(0))`. To decentralize authority, use `transferOwnership()` -> `acceptOwnership()` to DAO / timelock / multisig.
- **Verification**: unit (always revert, owner/source proposal/pendingOwner unchanged), manual (production transfer configuration review).

### 6.B DF PriceFeed Implementation (inner source / collateral-specific oracle patterns)

Each DF PriceFeed uses the two-layer composition in §5. The current branch map and deployment values are canonical in [Parameters](../../../Parameters.md). Day 1 has real feeds only for Branch 0 dwstETH (`ORCL-FR-015`) and Branch 1 dUSDC (`ORCL-FR-010`); Branches 2–7 use `PriceFeedPlaceholder`. The BTC, sUSDS, and XAUT patterns below are archived candidate research, not active deployment requirements.

Each DF PriceFeed applies the **shared final layer that multiplies dToken backing ratio ([ORCL-FR-014](#orcl-fr-014))** to the market price (JPY-denominated) calculated by collateral-specific `_fetchPricePrimary()`, and returns actual dToken collateral value (market price × backing ratio).

The constructor of every active DF PriceFeed requires `priceSource == primary && lastGoodPrice != 0` after its initial primary fetch and reverts the entire deployment with `InvalidInitialPrice` otherwise. This also rejects a zero-price deployment when the shared JPY provider is in an unhealthy expired episode and the not-yet-registered feed's shutdown call is caught. The same constructor becomes deployable again after a fresh JPY round clears the provider episode ([ORCL-INV-012](#8-invariants-inv)).

Oracle patterns and PriceFeed implementations specified in this document:

| Underlying (collateral asset) | Oracle pattern | PriceFeed implementation | Requirement |
| --- | --- | --- | --- |
| USDC (and candidates with a direct collateral/USD feed, e.g. WETH) | Standard | `DFUSDCPriceFeed` / asset-specific feed | ORCL-FR-010 |
| WBTC (archived candidate example) | **Peg-monitored** | archived `DFWBTCPriceFeed` | ORCL-FR-011 |
| sUSDS (archived candidate example) | **Composite rate** | archived `sUSDSPriceFeed` | ORCL-FR-012 |
| XAUT (future candidate) | **Composite peg** or equivalent direct XAUT/USD market feed; not bound to the current branch map | candidate implementation | ORCL-FR-013 |
| wstETH (dwstETH) | **Market / canonical composite** | `DFWstETHPriceFeed` | ORCL-FR-015 |
| Underlying unfinalized (post-launch finalization) | TBD | `PriceFeedPlaceholder` | ORCL-FR-008 |

> ⚠️ The canonical source for collateral↔branch assignment and finalized status is [Parameters](../../../Parameters.md). See each FR table for finalized collateral-specific Chainlink addresses (unfinalized entries remain to be confirmed).

#### <a id="orcl-fr-010"></a>ORCL-FR-010: Standard pattern (USDC)

- **Type**: Functional | **Source**: adopted reconstruction plan / direct Chainlink Coll/USD feeds
- **Signature**: `_fetchPricePrimary()` (`DFUSDCPriceFeed`; archived candidates are outside the active source tree)
- **Purpose**: For collateral with direct collateral/USD feeds, derive JPY price with `_getOracleAnswer(collUsdOracle)` -> `_convertUsdPriceToJpyWithFreeze()`. Collateral-leg failure enters recoverable oracle pause; the shared JPY leg first uses a bounded 24h soft-freeze ([ORCL-SEC-005](#orcl-sec-005)).
- **Authorization**: none (internal, read through Proxy).
- **Preconditions (Checks)**: `collUsdOracle` is within staleness and `answer > 0` (collateral leg). `jpyUsdOracle` is used and updated if healthy; if failed, use `lastGoodJpyRate`.
- **Behavior (Effects)**:
  1. `(collUsd, down1) = _getOracleAnswer(collUsdOracle)` (collateral/USD, normalized to 18 decimals). If `down1`, call `_shutDownAndReturnLastGoodPrice(collUsdOracle)` and keep `primary` retryable
  2. `collJpy = _convertUsdPriceToJpyWithFreeze(collUsd)`: healthy JPY uses the live rate; failure uses `lastGoodJpyRate`, and expiry enters recoverable oracle pause. Recovery clears provider episode state but not the BO pause
  3. `lastGoodPrice = _applyBackingRatio(collJpy)`, return `(price, false)`
- **Revert / early return**: collateral-leg failure transitions to shutdown, not revert. JPY-leg failure does not early-return; it continues with fallback (only gas-griefing OOG raw-reverts with `InsufficientGasForExternalCall`).
- **Emitted event**: `JpyRateFrozen` / `JpyRateUnfrozen` (start/end of JPY soft-freeze). Collateral-leg shutdown is upstream mechanism.
- **Design notes**: `_fetchPricePrimary()` pseudocode:
  ```javascript
  _fetchPricePrimary() {
      (collUsd, down1) = _getOracleAnswer(collUsdOracle);   // collateral/USD (Chainlink, per branch)
      if (down1) return _shutDownAndSwitchToLastGoodPrice(collUsdOracle);

      collJpy = _convertUsdPriceToJpyWithFreeze(collUsd);   // JPY/USD (Chainlink, shared)
      // JPY failure -> lastGoodJpyRate fallback, no shutdown (soft-freeze)

      lastGoodPrice = _applyBackingRatio(collJpy);
      return (lastGoodPrice, false);
  }
  ```
  Chainlink feeds (mainnet; staleness is [ORCL-TBD-001](#orcl-tbd-001), final values in [Parameters](../../../Parameters.md)):

  | Collateral | Chainlink feed (`collUsdOracle`) |
  | --- | --- |
  | USDC | USDC/USD `0x8fFfFfd4AfB6115b954Bd326cbe7B4BA576818f6` |
  | Shared across all branches | JPY/USD `0xBcE206caE7f0ec07b545EddE332A47C2F75bbeb3` (`jpyUsdOracle`) |
- **Verification**: unit (collateral-leg shutdown branch, JPY-leg soft-freeze, fallback/recovery/events), fork (18-decimal normalization and JPY conversion with real Chainlink), integration.

#### <a id="orcl-fr-011"></a>ORCL-FR-011: Archived peg-monitored candidate pattern (WBTC [BTC type])

- **Type**: Functional | **Source**: reconstruction plan / Aave v3 WBTC/BTC × BTC/USD adapter (industry standard)
- **Signature**: `_fetchPricePrimary()` / `fetchRedemptionPrice()` (`DFWBTCPriceFeed`, inheriting `DFPriceFeedBase`)
- **Purpose**: For BTC-type collateral (representative example WBTC; in [Parameters](../../../Parameters.md), corresponds to future dBTC branch = **enabled at Day-2 activation**), derive price with a three-stage structure that inserts `DFWBTCPriceFeed`-specific storage `wbtcBtcOracle` (Chainlink WBTC/BTC) before Collateral/USD. WBTC/BTC and BTC/USD legs shutdown on failure; JPY/USD leg is a shared dependency and therefore soft-freezes ([ORCL-SEC-005](#orcl-sec-005)).
- **Authorization**: none (internal).
- **Preconditions (Checks)**: `wbtcBtcOracle` / `collUsdOracle` (= BTC/USD) are within staleness and `answer > 0`. `jpyUsdOracle` is used and updated if healthy; if failed, use `lastGoodJpyRate` (soft-freeze, [ORCL-SEC-005](#orcl-sec-005)).
- **Behavior (Effects)**:
  1. Step 1: `(wbtcBtc, down1) = _getOracleAnswer(wbtcBtcOracle)` (WBTC/BTC peg monitor). If `down1`, shutdown
  2. Step 2: `(btcUsd, down2) = _getOracleAnswer(collUsdOracle)` (BTC/USD). If `down2`, shutdown
  3. Step 3: `market = wbtcBtc * btcUsd / 1e18`, `canonical = btcUsd`. Normal `fetchPrice()` uses `min(market, canonical)` so WBTC is capped at BTC when the peg monitor is above 1 and depegs below 1 are immediately reflected
  4. Step 4: `fetchRedemptionPrice()` uses `max(market, canonical)` when the two are within `WBTC_BTC_DEVIATION_THRESHOLD` (2%), matching the Liquity rETH/wstETH redemption-oracle-arbitrage mitigation and the Asymmetry USDaf V2 audit fix pattern. Outside the threshold, use the conservative `min(market, canonical)` so a real WBTC depeg is not masked
  5. Step 5: `wbtcJpy = _convertUsdPriceToJpyWithFreeze(wbtcUsd)` (JPY/USD). JPY leg failure does not immediately shutdown and uses `lastGoodJpyRate` (soft-freeze bounded 24h, then standard shutdown; [ORCL-SEC-005](#orcl-sec-005)). WBTC/BTC and BTC/USD failures shutdown as usual
  6. `lastGoodPrice = _applyBackingRatio(wbtcJpy)`, return `(price, false)`
- **Revert / early return**: WBTC/BTC and BTC/USD leg failures, and JPY soft-freeze expiry beyond `MAX_JPY_FREEZE_DURATION`, transition to shutdown. JPY-leg failure alone continues with fallback instead of immediate shutdown (only gas-griefing OOG reverts raw with `InsufficientGasForExternalCall`).
- **Emitted event**: `JpyRateFrozen` / `JpyRateUnfrozen` (JPY soft-freeze). WBTC/BTC and BTC/USD leg shutdown uses the upstream mechanism.
- **Design notes**: `_fetchPricePrimary()` pseudocode:
  ```javascript
  _fetchPricePrimary() {
      // Step 1: WBTC/BTC peg monitor
      (wbtcBtc, down1) = _getOracleAnswer(wbtcBtcOracle);
      if (down1) return shutdown(wbtcBtcOracle);

      // Step 2: BTC/USD (collUsdOracle initialized as BTC/USD)
      (btcUsd, down2) = _getOracleAnswer(collUsdOracle);
      if (down2) return shutdown(collUsdOracle);

      // Step 3: Synthetic WBTC/USD market price and canonical BTC price
      market = wbtcBtc * btcUsd / 1e18;
      canonical = btcUsd;

      // Step 4: Normal path is conservative. Redemption path uses the
      // worse redeemer price when the peg monitor is within the 2% lag band.
      if (isRedemption && withinDeviation(market, canonical, 2%)) {
          wbtcUsd = max(market, canonical);
      } else {
          wbtcUsd = min(market, canonical);
      }

      // Step 5: JPY/USD (shared dependency -> soft-freeze)
      wbtcJpy = _convertUsdPriceToJpyWithFreeze(wbtcUsd);
      // JPY failure -> lastGoodJpyRate fallback, no shutdown

      lastGoodPrice = _applyBackingRatio(wbtcJpy);
      return (lastGoodPrice, false);
  }
  ```
  Three Chainlink oracles used (mainnet; staleness is [ORCL-TBD-001](#orcl-tbd-001), final values in [Parameters](../../../Parameters.md)):

  | # | Layer | Chainlink Address |
  | --- | --- | --- |
  | 1 | WBTC/BTC peg monitor | `0xfdFD9C85aD200c506Cf9e21F1FD8dd01932FBB23` |
  | 2 | BTC/USD | `0xF4030086522a5bEEa4988F8cA5B36dbC97BeE88c` |
  | 3 | JPY/USD (shared) | `0xBcE206caE7f0ec07b545EddE332A47C2F75bbeb3` |

  Why Peg Monitor is required ([ORCL-SEC-006](#orcl-sec-006)):
  - **1. Chainlink Ethereum Mainnet has no direct WBTC/USD feed**: synthetic composition (WBTC/BTC × BTC/USD) is the only way to obtain WBTC USD price. Other collateral (WETH and stablecoins) has direct Coll/USD feeds and does not require Peg Monitor.
  - **2. WBTC is a centralized BitGo-custodied wrapper and 1:1 peg to BTC is not guaranteed**: using BTC/USD directly as WBTC price overvalues collateral during depeg, causing under-collateralized borrowing and liquidation failure. WBTC/BTC Peg Monitor correctly lowers collateral valuation during depeg.
  - **3. Historical depegs**: divergence to 0.985 during the 2022 FTX collapse / 0.98 during the 2024 BiT Global and Justin Sun issue (Aave and MakerDAO reduced WBTC parameters).
  - **4. Industry-standard alignment**: Aave v3 uses an equivalent composite approach (WBTC/BTC × BTC/USD adapter). Direct BTC/USD for WBTC has received multiple High/Medium audit findings and is avoided.
  - **5. Peg Monitor is Chainlink-only**: WBTC/BTC peg monitoring is Chainlink feed based; on failure it conservatively shuts down immediately.
- **Verification**: unit (shutdown branches for WBTC/BTC and BTC/USD, JPY-leg soft-freeze, synthetic calculation, normal min-vs-canonical cap, redemption max-within-threshold behavior), fork (real WBTC/BTC and BTC/USD), integration.

#### <a id="orcl-fr-012"></a>ORCL-FR-012: Archived composite-rate candidate pattern (sUSDS [Yield Bearing])

- **Type**: Functional | **Source**: adopted reconstruction plan / upstream-derived `CompositePriceFeed` pruned for sUSDS
- **Signature**: `_fetchPricePrimary()` + `_getCanonicalRate()` (`sUSDSPriceFeed`, inheriting pruned `CompositePriceFeed`)
- **Purpose**: Compose sUSDS (Savings USDS, a yield-bearing token that earns yield by depositing USDS) value as **canonical rate (USDS per sUSDS) × USDS/USD** to obtain sUSDS/USD, then convert to JPY. This reuses the Liquity v2 LST composite idea of "USD anchor × canonical rate," but the current implementation keeps only the **USDS/USD × sUSDS canonical rate** primary path and removes the WSTETH/RETH LST secondary fallback.
- **Authorization**: none (internal).
- **Preconditions (Checks)**: `collUsdOracle` (= USDS/USD) is within staleness and `answer > 0`; canonical rate is readable (rate provider does not revert or return 0). `jpyUsdOracle` is used and updated if healthy; if failed, use `lastGoodJpyRate` (soft-freeze, [ORCL-SEC-005](#orcl-sec-005)).
- **Behavior (Effects)**:
  1. `(usdsUsd, down1) = _getOracleAnswer(collUsdOracle)` (USDS/USD, normalized to 18 decimals). If `down1`, shutdown
  2. `(usdsPerSusds, rateDown) = _getCanonicalRate()` (USDS per sUSDS, 18 decimals). If `rateDown`, `_shutDownAndSwitchToLastGoodPrice(rateProviderAddress)`
  3. `susdsUsd = usdsUsd * usdsPerSusds / 1e18` (sUSDS/USD, 18 decimals)
  4. `susdsJpy = _convertUsdPriceToJpyWithFreeze(susdsUsd)` (JPY/USD). JPY-leg failure does not immediately shutdown and uses `lastGoodJpyRate` (soft-freeze bounded 24h; [ORCL-SEC-005](#orcl-sec-005))
  5. `lastGoodPrice = _applyBackingRatio(susdsJpy)`, return `(price, false)`
- **Revert / early return**: canonical rate or USD anchor read failure conservatively branch-shuts down and falls back to `lastGoodPrice` (pruned `CompositePriceFeed` primary -> `lastGoodPrice` behavior). Only the JPY leg continues with fallback instead of immediate shutdown (bounded by `MAX_JPY_FREEZE_DURATION` 24h, then standard shutdown).
- **Emitted event**: `JpyRateFrozen` / `JpyRateUnfrozen` (JPY soft-freeze). Canonical/USD leg shutdown is upstream mechanism.
- **Design notes**:
  - canonical rate is read directly from the **sUSDS contract (`0xa3931d71877C0E7a3148CB7Eb4463524FEc27fbD`, rate provider)**, not Chainlink. Because sUSDS is ERC-4626, `convertToAssets(1e18)` (= USDS per 1 sUSDS, 18 decimals) is the canonical rate (equivalent to wstETH `stEthPerToken()`). `_getCanonicalRate()` calls this. The constructor also reads the rate provider's `asset()`, verifies that the underlying asset contract exists, and verifies that both sUSDS and `asset()` use 18 decimals. There is no Chainlink staleness concept.
  - `_fetchPricePrimary()` pseudocode (`collUsdOracle = USDS/USD`):
    ```javascript
    _fetchPricePrimary() {
        (usdsUsd, down1) = _getOracleAnswer(collUsdOracle);    // USDS/USD (Chainlink, normalized to 18 decimals)
        if (down1) return _shutDownAndSwitchToLastGoodPrice(collUsdOracle);

        (usdsPerSusds, rateDown) = _getCanonicalRate();         // USDS per sUSDS (sUSDS contract, 18 decimals)
        if (rateDown) return _shutDownAndSwitchToLastGoodPrice(rateProviderAddress);

        susdsUsd = usdsUsd * usdsPerSusds / 1e18;               // sUSDS/USD (18 decimals)

        susdsJpy = _convertUsdPriceToJpyWithFreeze(susdsUsd);   // JPY/USD (Chainlink, shared)
        // JPY failure -> lastGoodJpyRate fallback, no shutdown (soft-freeze)

        lastGoodPrice = _applyBackingRatio(susdsJpy);
        return (lastGoodPrice, false);
    }
    ```
  - **Scale**: `usdsUsd` / `usdsPerSusds` / `susdsUsd` are all 18 decimals. Raw Chainlink values (8 decimals) are normalized to 18 decimals by `_getOracleAnswer` (`×1e10`) ([§3.5 assumptions](#35-assumptions)). canonical rate (USDS per sUSDS) is also 18-decimal scale (e.g. `1.05e18` = 1.05 USDS per 1 sUSDS). Dividing as if still raw 8 decimals would be off by `1e10`.
  - **No `ETHUSDxCanonical` state**: sUSDS has a single USD source, USDS/USD, and no separate market feed like wstETH. Therefore the `ETHUSDxCanonical` state in [§12](#12-failure-and-exception-behavior-err) (fallback to "base USD × canonical rate" on market feed failure) does not occur for this feed. Production `CompositePriceFeed` removes that unused LST secondary fallback, and failures fall back to `lastGoodPrice`.
  - Oracles used (mainnet; staleness is [ORCL-TBD-001](#orcl-tbd-001), final values in [Parameters](../../../Parameters.md)):

    | Layer | Source | Address / status |
    | --- | --- | --- |
    | USDS/USD (USD anchor) | Chainlink | ✅ `0xfF30586cD0F29eD462364C7e81375FC0C71219b1` (EACAggregatorProxy. Also used by Compound v3 [comet] USDS market and old implementation `USDSPriceFeed.sol`) |
    | sUSDS canonical rate (USDS per sUSDS) | sUSDS contract `0xa3931d71877C0E7a3148CB7Eb4463524FEc27fbD` (ERC-4626 `convertToAssets(1e18)`, non-Chainlink) | ✅ Verified |
    | JPY/USD (shared) | Chainlink | `0xBcE206caE7f0ec07b545EddE332A47C2F75bbeb3` |

    Note: because USDS is DAI's 1:1 successor, if USDS/USD is deprecated in the future, DAI/USD (`0xAed0c38402a5d19df6E4c03F4E2DceD6e29c1ee9`) is a possible replacement through `PriceFeedProxy` (fallback option). Final checksum must be compared against Chainlink official addresses page.
  - Price example:

    | Assumption | Value |
    | --- | --- |
    | USDS/USD | $1.00 |
    | USDS per sUSDS | 1.05 |
    | JPY/USD | 0.006667 (1 dollar = 150 yen) |

    ```javascript
    sUSDS/USD = 1.05 × 1.00      = $1.05
    sUSDS/JPY = 1.05 / 0.006667  ≈ ¥157.5
    ```
  - **Difference from Peg-monitored**: Peg-monitored ([ORCL-FR-011](#orcl-fr-011) / [ORCL-FR-013](#orcl-fr-013)) inserts monitoring feeds (WBTC/BTC, XAUT/XAU, etc.) to detect wrapper vs underlying **peg divergence** and value conservatively; Composite rate uses a **legitimately increasing exchange rate** as canonical rate (reflecting yield, not detecting divergence).
- **Verification**: unit (USDS/USD and canonical-rate shutdown branches, JPY soft-freeze branch, synthetic calculation), fork (sUSDS `convertToAssets`, real USDS/USD), integration.

#### <a id="orcl-fr-013"></a>ORCL-FR-013: Composite peg pattern for a future XAUT candidate

- **Type**: Functional | **Source**: [ORCL-SEC-006](#orcl-sec-006)
- **Purpose**: If XAUT is evaluated as a future collateral candidate, reflect downside depeg through XAUT/XAU or a direct XAUT/USD market price.
- **Calculation**: `min(1, XAUT/XAU) × XAU/USD ÷ JPY/USD × min(1, backingRatio)`, or an equivalent direct XAUT/USD market price.
- **Failure policy**: a market, peg, or XAU-leg failure is a branch oracle failure. JPY/USD uses bounded soft-freeze.
- **Activation gate**: feed quality, market hours, staleness, liquidation liquidity, cap, and monitoring/incident operations must be approved as one package. XAU/USD alone or off-chain monitoring alone is insufficient for activation.
- **Current status**: candidate only. This requirement does not bind XAUT to any branch in the current branch map and does not authorize activation.
- **Authorization**: none (internal).
- **Preconditions (Checks)**: adopted market/peg legs are within staleness and return valid values; `jpyUsdOracle` follows [ORCL-SEC-005](#orcl-sec-005).
- **Candidate behavior**:
  1. Read the adopted XAUT market/peg primitive and XAU/USD where required; any invalid leg triggers shutdown.
  2. Cap premium and reflect downside depeg with `min(1, XAUT/XAU) × XAU/USD`, or use an approved equivalent direct XAUT/USD market price.
  3. Convert through JPY/USD, apply the backing ratio, and return the final dToken collateral value.
- **Revert / early return**: market/peg/XAU-leg failures transition to shutdown. JPY-leg failure follows bounded soft-freeze.
- **Emitted event**: `JpyRateFrozen` / `JpyRateUnfrozen` (JPY soft-freeze). Collateral-leg shutdown is upstream mechanism.
- **Historical research record (non-normative)**: The material below records the feed-availability research and rejected former Day-1 design. It does not override the candidate-only status or activation gate above.
  - **Normative peg-monitoring requirement and Day-1 constraint**: normative form is a WBTC-like composite peg (**XAUT/XAU peg monitor × XAU/USD**). However, as of re-checking (2026-06-10, observed through Chainlink official feed registry), **Chainlink Ethereum mainnet (308 entries) has XAU/USD only and no XAUT/XAU or XAUT/USD feed** (`0x214eD9Da11D2fbe465a6fc601a91E62EbEc1a0D6`). XAUT/USD is available only on non-mainnet chains in the observed set (**Hyperliquid** [standard + SVR 2 proxies] and **Plasma**; heartbeat 24h, deviation 0.5%, feedCategory "new"; not an exhaustive chain listing). Arbitrum registry's XAUT/USD-RefPrice entry has no deployed contract (not consumable). No direct XAUT/XAU ratio feed was found from any checked provider. Mainnet does have **PAXG/USD** (direct market feed for Paxos Gold wrapper; heartbeat 24h, deviation 0.5%) but not XAUT. Outside Chainlink, Pyth `Crypto.XAUT/USD` (pull type) and RedStone (multi-CEX aggregated XAUt data; mainnet permanent push feed unconfirmed) exist, but they are outside the Chainlink push (AggregatorV3) single trust boundary ([`ADR-005`](../architecture/Architecture-Decision-Records.md#adr-005) / Product Overview §10) and require ADR revision + due diligence before adoption. Therefore Composite peg cannot be built directly on Day 1.
  - **Rejected former Day-1 path**: XAU/USD plus off-chain peg monitoring cannot guarantee on-chain downside-depeg reflection. It is retained only as historical research and must not be used to activate an XAUT candidate.
  - **Residual risk (explicit)**: cap and deposit pause do not reprice existing collateral or stop Core borrowing against already minted dToken. A future activation therefore requires an on-chain market/peg leg before any exposure exists.
  - Day-1 Standard `_fetchPricePrimary()` pseudocode:
    ```javascript
    _fetchPricePrimary() {
        (xauUsd, down1) = _getOracleAnswer(collUsdOracle);   // XAU/USD (Chainlink, collUsdOracle = XAU/USD)
        if (down1) return _shutDownAndSwitchToLastGoodPrice(collUsdOracle);

        xautJpy = _convertUsdPriceToJpyWithFreeze(xauUsd);    // JPY/USD (Chainlink, shared)
        // JPY failure -> lastGoodJpyRate fallback, no shutdown (soft-freeze)

        lastGoodPrice = _applyBackingRatio(xautJpy);
        return (lastGoodPrice, false);
    }
    ```
    Day-1 oracles (mainnet; staleness is [ORCL-TBD-001](#orcl-tbd-001), final values in [Parameters](../../../Parameters.md)):

    | Layer | Address |
    | --- | --- |
    | XAU/USD (= `collUsdOracle`) | ✅ Chainlink `0x214eD9Da11D2fbe465a6fc601a91E62EbEc1a0D6` (EACAggregatorProxy) |
    | JPY/USD (shared) | Chainlink `0xBcE206caE7f0ec07b545EddE332A47C2F75bbeb3` |

    Price example (Day-1 Standard):

    | Assumption | Value |
    | --- | --- |
    | XAU/USD | $2,400 (treat 1 XAUT ≈ 1 XAU) |
    | JPY/USD | 0.006667 (1 dollar = 150 yen) |

    ```javascript
    XAUT/JPY = 2,400 / 0.006667 ≈ ¥359,982
    ```
  - **Future composite-peg form (candidate only)**: XAUT is an archived candidate; this bullet does not describe a deployed branch. If a future activation package evaluates XAUT once an XAUT/XAU (or XAUT/USD) feed is available on mainnet, it must first confirm quality criteria (price-source liquidity, feedCategory, operating history, weekend behavior = [ORCL-TBD-003](#orcl-tbd-003)) and must include, from the start, an oracle that reflects XAUT/XAU or direct XAUT/USD downside ([ORCL-FR-013](#orcl-fr-013) / [ORCL-SEC-006](#orcl-sec-006)); the rejected XAU/USD-anchor design above must not be revived (Aave's XAUt precedent likewise rejected a below-quality dedicated XAUt/USD feed). If the provided primitive is XAUT/USD (market) rather than a direct ratio, the final design choice between ratio synthesis vs Standard replacement, weekend market-hour mismatch, and premium cap is [ORCL-TBD-003](#orcl-tbd-003). The candidate `_fetchPricePrimary()` has the same structure as WBTC ([ORCL-FR-011](#orcl-fr-011), BTC replaced by XAU):
    ```javascript
    _fetchPricePrimary() {
        (xautXau, down1) = _getOracleAnswer(xautXauOracle);   // Step 1: XAUT/XAU peg monitor
        if (down1) return shutdown(xautXauOracle);

        (xauUsd, down2) = _getOracleAnswer(collUsdOracle);    // Step 2: XAU/USD
        if (down2) return shutdown(collUsdOracle);

        xautUsd = xautXau * xauUsd / 1e18;                    // Step 3: Synthetic XAUT/USD = XAUT/XAU × XAU/USD

        xautJpy = _convertUsdPriceToJpyWithFreeze(xautUsd);   // Step 4: JPY/USD (shared -> soft-freeze)
        // JPY failure -> lastGoodJpyRate fallback, no shutdown

        lastGoodPrice = _applyBackingRatio(xautJpy);
        return (lastGoodPrice, false);
    }
    ```
    Example (composite peg): XAUT/XAU = 0.999, XAU/USD = $2,400 -> XAUT/USD = $2,397.6 -> XAUT/JPY = 2,397.6 / 0.006667 ≈ ¥359,622. Alternative **(B) using Tether Gold on-chain proof-of-reserves or similar as peg source** is possible (requires due diligence).
- **Verification**: unit (peg cap and each failure leg), fork (adopted feed), integration (backing ratio and JPY soft-freeze), manual (liquidity and monitoring).

#### <a id="orcl-fr-014"></a>ORCL-FR-014: Reflect dToken backing peg (shared final layer for all collateral)

- **Type**: Functional | **Source**: formalization of old CollateralVault TODO "oracle reflection of dToken collateral value during Strategy impairment" / CollateralVault accounting (`A` vs `L_effective`, [CollateralVault Requirements Specification](CollateralVault.md) `VAULT-INV-001`)
- **Signature**: call `_applyBackingRatio(uint256 collJpy)` as the **final step** of each collateral `_fetchPricePrimary()`. The shared logic lives in `JpyFreezeLib`; standard / peg `DFPriceFeedBase` and composite feeds (`sUSDSPriceFeed` / `DFWstETHPriceFeed`) only hold state and wiring. Pricing backing is `CollateralVault.backingRatioForPricing() -> (uint256 ratio, bool available)` (ratio is 1e18 scale, **downward-only** `<= 1e18`, defined in [CollateralVault Requirements Specification](CollateralVault.md) `VAULT-FR-016`).
- **Purpose**: dToken is a 1:1 claim on Underlying principal, but if Strategy hacking, bad debt, or slashing causes **actual Underlying holdings to fall below principal**, dToken depegs against Underlying. Returning only market price (collateral/JPY) would not reflect backing impairment and would cause **collateral overvaluation -> over-borrowing -> JPYdf bad debt**. Therefore multiply market price by **backing ratio** and return actual dToken collateral value.
- **Why placed at the final step of each inheritance path**: sUSDS uses the `CompositePriceFeed` inheritance path separate from `DFPriceFeedBase` ([ORCL-FR-012](#orcl-fr-012)). If backing multiplication were only in `DFPriceFeedBase`, composite-rate collateral would be missed. The composite feeds (`sUSDSPriceFeed` / `DFWstETHPriceFeed`) therefore hold the state of the shared `JpyFreezeLib` conversion/backing library locally; the logic is not duplicated, and the actual JPY cache/freeze state remains exclusively in `JpyUsdRateProvider`. Proxy responsibility is unchanged.
- **Authorization**: none (internal, read through Proxy).
- **Preconditions (Checks)**: source (actual PriceFeed) references the corresponding `CollateralVault` (constructor-set, one feed per Vault; [§5](#5-interface-specification)). Collateral-specific `_fetchPricePrimary()` has already calculated market price `collJpy` (JPY-denominated, 18dec).
- **Behavior (Effects)** (final step of `_fetchPricePrimary()`, immediately before recording `lastGoodPrice`):
  1. Calculate market price `collJpy` via collateral-specific pattern ([ORCL-FR-010](#orcl-fr-010)-[ORCL-FR-013](#orcl-fr-013))
  2. `try CollateralVault.backingRatioForPricing() -> (r, available)`: a normal revert or `available == false` enters the standard oracle-failure path (`lastGoodPrice` shutdown) without updating `lastGoodBacking`; gas-guard revert is re-reverted. When available, clamp `r` (`> 1e18` to `1e18`; measured `== 0` to `1` [1 wei]) and store `lastGoodBacking = r`
  3. `dTokenJpy = collJpy * r / 1e18`
  4. Store `lastGoodPrice = dTokenJpy` and return `(dTokenJpy, false)`
  5. Redemption path (source `fetchRedemptionPrice` path) applies the same logic (**symmetrically on both consumer paths** = [ORCL-SEC-004](#orcl-sec-004))
- **Revert / fallback**: a normal call revert or `available == false` is not passed through using `lastGoodBacking`; it enters the standard oracle-failure path (`lastGoodPrice` shutdown). Otherwise an unreadable Strategy would be misclassified as measured total loss, potentially making every Trove on the branch liquidatable while the feed reports no oracle failure. A successfully measured `r == 0` remains a real near-total backing loss and is floored to `1` wei; `r > 1e18` is capped. A gas-starved call re-reverts with `InsufficientGasForExternalCall`, and `PriceFeedProxy` also re-reverts. Strategy valuation failures may still use a bounded fresh Vault cache; only live-and-cache unavailability sets `available == false`. Placeholder (`L_effective == 0`) returns `(1e18, true)` and remains consistent with `PriceFeedPlaceholder` ([ORCL-FR-008](#orcl-fr-008)) `(1e18, false)`.
- **Design notes**:
  - **Same shape as `CompositePriceFeed`**: replace the rate in "market price × rate" composition with backing ratio (analogous to canonical rate in [ORCL-FR-012](#orcl-fr-012)). **Core remains unchanged** (core does not know backing exists).
  - **Double defense (live + finalization)**: backing is a live value from `totalUnderlying()`. If `est` reflects loss, it automatically moves downward; when GOV `writeoffStrategyPrincipal` ([CollateralVault Requirements Specification](CollateralVault.md) `VAULT-FR-009`) lowers principal, `A` decreases and is finalized. Only temporary external view failures use Vault-side Strategy-level fresh cache.
  - **Upside cap (`min(1e18, ...)`)**: operating profit with `A > L_effective` still caps backing at `1e18` (dToken has no yield and profit belongs to Treasury).
  - **Severe impairment = price decline only**: live backing ratio lowers price and relies on existing liquidation / TCR<SCR branch shutdown / Urgent Redemptions (**no dedicated backing shutdown threshold**). No global smoothing of real loss on Day 1.
  - **Immediate reflection only for confirmed loss (ADR-006)**: the policy of immediate downward reflection of backing with no smoothing is [`ADR-006`](../architecture/Architecture-Decision-Records.md#adr-006). Only confirmed loss (market depeg or loss appearing in Strategy valuation) is reflected; a temporary liquidity shortage is not a loss and does not lower backing (no writeoff). An external deficit not visible in accounting is finalized via `writeoffStrategyPrincipal` only as the residual after recovery.
  - **Stability Pool is not the replenisher**: Stability Pool handles liquidation of unsafe Troves after price decrease. dToken backing repair is handled by Vault-side Strategy recovery, `writeoffStrategyPrincipal`, `backstopDeposit` (protected reserve deposit), and `releaseBackstopToBuffer` (explicit release to redemption liquidity, [CollateralVault Requirements Specification](CollateralVault.md) `VAULT-FR-017`); SP depositors do not directly bear Strategy loss.
  - **`lastGoodBacking` is managed separately from market `lastGoodPrice`** (healthy market price and healthy backing value are independent).
  - **Scale discipline**: `collJpy` (18dec) × `r` (1e18 scale) / 1e18 = 18dec.
- **Verification**: unit (`min` cap, `L_effective==0` gives `(1e18,true)`, both consumers symmetric, backing call revert or unavailable valuation -> shutdown, measured zero -> 1-wei floor without oracle failure), fork (multiplication with real Vault backing value), integration (Strategy impairment -> backing ratio drops -> dToken collateral value drops -> core liquidation activates).

#### <a id="orcl-fr-015"></a>ORCL-FR-015: dwstETH market / canonical composite

- **Type**: Functional | **Source**: wstETH PriceFeed policy (Owner decision) / Day-1 launch gate / `DFWstETHPriceFeed`
- **Purpose**: Reflect stETH/USD market movement including downside depeg, reflect slashing or negative rebase through the canonical rate, convert through JPY/USD, and apply dToken backing impairment to dwstETH borrow, liquidation, and redemption prices.
- **Normal price (borrowing and liquidation)**:

  ```text
  stETH/USD market (Chainlink 0xCfE54B5cD566aB89272946F602D76Ea879CAb4a8,
                    staleness = PRM-ORACLE-003)
  × stETH per wstETH canonical rate (wstETH.stEthPerToken(), read from the
    collateral token itself; no staleness concept)
  ÷ JPY/USD (shared JpyUsdRateProvider)
  × min(1, dToken backing ratio)
  ```

  A decline in the canonical rate reflects slashing or negative rebase.
- **Redemption price**: replace the USD leg with `max(stETH/USD direct, ETH/USD × stETH/ETH)`, then apply the same canonical rate, shared JPY/USD, and backing ratio once. The stETH/ETH leg uses Chainlink `0x86392dC19c0b719886221c78AB11eb8Cf5c52812` (18 decimals, `PRM-ORACLE-007`). No divergence threshold is used. This keeps `redemptionPrice >= normalPrice`, separates genuine stETH depeg from a delayed direct stETH/USD update, and leaves borrowing/liquidation on direct stETH/USD so depegged collateral is not overvalued. A stale-high direct or derived leg can underpay the wind-down redeemer while it remains policy-valid; Product / Protocol Risk tracks that settlement trade-off.
- **Implementation**: `DFWstETHPriceFeed` inherits the pruned `CompositePriceFeed` base. It reuses upstream `ethUsdOracle` for direct stETH/USD and holds separate ETH/USD and stETH/ETH redemption oracles. JPY conversion/freeze/backing runs once through shared `JpyFreezeLib`. The constructor validates all three Chainlink feeds, the wstETH rate provider's 18 decimals and nonzero rate, and the initial normal price. Normal and urgent redemption quotes do not update the source's shared `lastGoodPrice`; PriceFeedProxy owns the separate normal-redemption cache and urgent has no cache.
- **Failure policy**: direct stETH/USD, canonical-rate, or backing failure enters recoverable oracle pause. An unavailable ETH/USD or stETH/ETH auxiliary leg makes normal redemption emit `RedemptionReferenceUnavailable` and fail closed without direct-only fallback; urgent returns source failure and Proxy reverts `UrgentRedemptionPriceUnavailable`. Recovered live normal pricing may still serve liquidation and `TCR < SCR`; CORE-MOD-014 also permits collateral additions and debt repayments against that healthy direct price. Normal redemption, collateral withdrawal, and debt increase remain paused until Owner validates all three consumer paths and resumes. Gas-griefing OOG re-reverts `InsufficientGasForExternalCall`. Shared JPY/USD follows `ORCL-SEC-005`.
- **Accounting boundary**: canonical-rate growth is native wstETH staking appreciation and remains in borrower collateral value. It is not swept as Strategy profit; an external Strategy's increase in wstETH quantity is accounted separately.
- **Difference from upstream**: normal composition matches upstream `WSTETHPriceFeed`. Normal and urgent redemption use `max(direct, ETH/USD × stETH/ETH)` without upstream's 1% comparison gate. The recoverable pause keeps retrying `primary` to prove recovery and does not use `ETHUSDxCanonical`.
- **Day-1 launch gate**: finalize feed addresses, heartbeat/staleness values, canonical-rate source, fork/integration/invariant tests, monitoring, and frontend display before launch. Product / Protocol Risk records stale-high direct/derived risk and shared-JPY lag on normal/urgent paths as staleness trade-offs. ORCL-FR-005 / `PRM-ORACLE-008` separately reduces only normal-redemption feed-silence exposure to 30h; the 96h policy envelope is not a guaranteed profit or High exploit bound.
- **Verification**: unit (lag/depeg composite, reference fail-closed events, each failure leg, source-cache isolation, one JPY conversion, OOG pass-through), fork (same-block three-Chainlink rounds and canonical rate), integration (Proxy caches, backing, JPY freeze, pause/resume), invariant (`redemptionPrice >= normalPrice`, scale, backing symmetry).

#### <a id="orcl-fr-016"></a>ORCL-FR-016: `fetchUrgentRedemptionPrice` after irreversible shutdown

- **Type**: Functional | **Source**: BOLD oracle-lag incident mitigation / CORE-MOD-012
- **Signature**: `fetchUrgentRedemptionPrice() -> (uint256 price, bool oracleFailure)`
- **Purpose**: Keep lag/depeg-sensitive settlement pricing in wind-down and fail closed when any required live input is unavailable, rather than settling from an unknown-age cache.
- **Behavior**: Standard and placeholder sources match their healthy normal quote. dwstETH uses ORCL-FR-015's `max(direct, ETH/USD × stETH/ETH)`. Any unavailable auxiliary, direct, canonical, JPY, backing, source, zero/max, or failure result makes Proxy revert `UrgentRedemptionPriceUnavailable(source)`. Core therefore receives only a source-policy-valid quote.
- **Cache boundary**: urgent has no third cache, does not update either existing Proxy cache, and never falls back to those caches or a direct-only quote.
- **JPY boundary**: after selecting the USD leg, urgent uses the same shared JPY provider once. The 72h validity plus 24h soft-freeze can leave normal price and urgent inside a 96h policy envelope. ORCL-FR-005 / `PRM-ORACLE-008` shortens only normal-redemption exposure to 30h. The residual does not imply same-direction market movement or guaranteed extractable profit and remains a Product / Protocol Risk staleness trade-off.
- **Source management**: constructor, `proposeSource`, and confirmation reject a direct source returning the `IPriceFeedProxy.source()` marker. This 32-byte getter check is a one-level type screen and does not rule out forwarding wrappers or cycles, so ORCL-GOV-004 dependency evidence is mandatory for both initial deployment and replacement. Constructor seeds a valid `lastGoodPrice`, requires a successful urgent path and fresh JPY provenance, and rejects malformed/invalid paths as specified; confirmation requires all three paths and applies the normal price-difference guard to urgent as well.
- **Recovery**: a temporary feed outage recovers on the first healthy live read. A recoverable BO pause requires Owner `resumeFromOracleFailure()` after all three price paths are healthy; only source replacement waits the 12h source timelock. Irreversibly shut-down branches have no BO resume. Governance-dead plus oracle-dead can permanently stop urgent redemption and remains an explicit risk acceptance.
- **Launch evidence**: before mainnet launch, retain (1) PriceFeedProxy Owner/Safe custody, threshold, and backup coverage for the full wind-down period; (2) a reviewed replacement-source inventory; (3) stable-Proxy-identity `ALRT-ORCL-012` trigger, human receipt, and resolution; (4) a test showing CORE-BO-FR-009 close succeeds while urgent pricing is unavailable after irreversible shutdown; and (5) risk-owner acceptance of governance-dead plus oracle-dead. Missing evidence remains a launch blocker.
- **Verification**: unit (Core wiring, lag/depeg, all input failures/reverts, gas guard, no third cache, JPY live/frozen/expired), integration / fork.

### 6.C Placeholder Branches and Post-Launch Binding

All 8 dToken slots are registered on Day 1. Branches 0–1 start with real sources. Branches 2–7 have no bound Underlying, `mintCap = 0`, and a placeholder source; activation requires the [Inert Branch Activation Runbook](../../operations/runbooks/Inert-Branch-Activation-Runbook.md).

#### <a id="orcl-fr-008"></a>ORCL-FR-008: Initial source for placeholder branches (`PriceFeedPlaceholder`)

- **Type**: Functional | **Source**: dToken placeholder branch operations / reconstruction plan
- **Signature**: `PriceFeedPlaceholder.fetchPrice() -> (1e18, false)` / `fetchRedemptionPrice() -> (1e18, false)` (external view)
- **Purpose**: To fix Proxy addresses for Underlying-unfinalized branches on Day 1, set the initial source to a **stub that always returns `(1e18, false)`**. `PriceFeedProxy` constructor rejects `source == address(0)` with `InvalidSource`, so a non-zero-price stub is passed instead of `address(0)`.
- **Authorization**: none (external view).
- **Preconditions (Checks)**: none.
- **Behavior (Effects)**: always returns `(1e18, false)`. For Proxy provenance validation it explicitly returns `jpyUsdRateProvider() = address(this)` and `lastGoodJpyUpdatedAt() = block.timestamp`; this synthetic freshness is safe only because Vault/dToken activation guards make the branch inert.
- **Revert / early return**: none.
- **Emitted event**: none.
- **Design notes**: `1e18` does not satisfy invalid-price checks (`price == 0` or `type(uint256).max`), so it **does not trigger branch shutdown**. Even though the price looks healthy, the placeholder branch is effectively inoperable through the following defense in depth ([ORCL-SEC-007](#orcl-sec-007)):
  1. [CollateralVault](CollateralVault.md) is initialized with `underlying = address(0)`, and `deposit()` / `redeem()` / `redeemWithPermit()` revert with `UnderlyingNotSet`
  2. [CollateralVault](CollateralVault.md) user value flows also require `dToken.underlying() == vault.underlying()`; mismatch (including unset dToken) reverts with `UnderlyingMismatch`
  3. [dToken](dToken.md) has no `TokenInfo` (`_decimalMultiplier == 0`), so `convertToDToken` / `convertToUnderlying` revert with `TokenInfoNotSet` ([DTKN-FR-003](dToken.md))
  4. Explicitly set `dToken.setCap(0)` at deployment ([DTKN-FR-006](dToken.md))
- **Verification**: unit (always `(1e18, false)`, does not trigger shutdown), integration (Vault/dToken multi-guards make value flows impossible).

#### <a id="orcl-fr-009"></a>ORCL-FR-009: Post-launch Underlying binding flow for unfinalized branches

- **Type**: Functional | **Source**: reconstruction plan (Day 2 activation) / dToken-first order
- **Signature**: 5 GOV calls + cap pre-check (`dToken.setTokenInfo` / `vault.setUnderlying` / `priceFeedProxy.proposeSource` -> `confirmSource` / `confirmSourceEmergency` / `dToken.setCap`)
- **Purpose**: Activate a placeholder branch on Day 2 using only GOV-authorized calls. **No redeployment of protocol core, dToken, or Proxy is required**.
- **Authorization**: GOV (dToken Owner / Vault Owner / `PriceFeedProxy` Owner; production = multisig).
- **Preconditions (Checks)**: each call's preconditions hold (`dToken.totalSupply() == 0`, cap is 0, `dToken.underlying() == token`, etc.).
- **Behavior (Effects)** (per branch, 5 GOV calls + cap pre-check):
  1. **Determine Underlying** and finalize corresponding Chainlink feeds and oracle pattern (Standard / Composite rate / Peg-monitored / Composite peg / fixed value, etc., §6.B). Deploy the real PriceFeed (standard/peg feeds use `DFPriceFeedBase`; composite-rate feeds inherit the sUSDS-pruned `CompositePriceFeed` + DF JPY layer; add extra Oracle storage if needed, as in WBTC)
  2. **Confirm cap remains 0**. If not, call `dToken.setCap(0)` before activation to keep minting closed during the procedure
  3. `dToken.setTokenInfo(name, symbol, token)` — first fix dToken to the real Underlying, decimals, name, and symbol (requires `totalSupply() == 0`)
  4. `vault.setUnderlying(token)` — one-shot set real token into placeholder `underlying` (`address(0)`). If `dToken.underlying() != token`, revert `UnderlyingMismatch`
  5. `priceFeedProxy.proposeSource(realFeed)` -> **12h timelock** -> `confirmSource()` / `confirmSourceEmergency()` — replace `PriceFeedPlaceholder` with real PriceFeed. Use normal `confirmSource()` when the old/new price difference is within the guard, and use `confirmSourceEmergency()` when the placeholder sentinel to real-price switch exceeds it ([ORCL-FR-001](#orcl-fr-001) / [ORCL-FR-002](#orcl-fr-002))
  6. `dToken.setCap(N)` — set cap and release deposits
- **Revert / early return**: dToken-first order violation (calling `vault.setUnderlying` before `dToken.setTokenInfo`) -> dToken-side Underlying is still `address(0)`, so `UnderlyingMismatch`.
- **Emitted event**: events from each call (`TokenInfoSet` / `SourceUpdated`, etc.).
- **Design notes**:
  - **dToken-first order**: this prevents divergence between the asset held by Vault and dToken decimals/valuation.
  - **Expected pattern by collateral category (which branch belongs to which category is canonical in [Parameters](../../../Parameters.md))**:

    | Collateral category | Expected pattern |
    | --- | --- |
    | USD Stablecoin (including RWA / US Treasuries) | Standard ([ORCL-FR-010](#orcl-fr-010)) |
    | Yield Bearing (yield-bearing USD stable type) | Composite rate ([ORCL-FR-012](#orcl-fr-012), analogous to sUSDS. canonical rate × underlying/USD) |
    | BTC type | Peg-monitored ([ORCL-FR-011](#orcl-fr-011), analogous to WBTC) |
    | GOLD type | Composite peg if XAUT/XAU or similar peg feed is available ([ORCL-FR-013](#orcl-fr-013)); otherwise Standard (XAU/USD) + mandatory off-chain peg monitoring ([ORCL-SEC-006](#orcl-sec-006)). Day-1 XAUT is Standard + off-chain peg monitoring |
    | JPY Stablecoin | Standard-like if Chainlink-supported feed exists. If unavailable, fixed-value base (e.g. 1:1 fixed feed) + future replacement path. Fixed feed cannot detect depeg, so liquidation parameters are set more conservatively than other stablecoins |
  - `proposeSource()` -> 12h timelock -> `confirmSource()` enables, without redeploying protocol: replacement on Chainlink deprecation / collateral token change (e.g. USDT -> USDC, BTC wrapper change) / Day-2 activation of unfinalized branches.
  - Deploy one `PriceFeedProxy` for each of all 8 branches; finalized branches use real PriceFeeds and unfinalized branches use `PriceFeedPlaceholder` as initial source (`DeployLiquity2.s.sol` `_deployPriceFeed` creates feed, then wraps with `new PriceFeedProxy(feed, deployer, borrowerOperations)`).
- **Verification**: unit (dToken-first order enforced, preconditions for each call), integration (complete Day-2 activation flow), manual (GOV runbook review).

---

## 7. State Variables and Accounting Model

The oracle layer has no value accounting (principal/profit/buffer). It holds only price-source references, last healthy price for failure fallback, and last healthy dToken backing ratio (`lastGoodBacking`). Backing ratio calculation and accounting are performed by [CollateralVault](CollateralVault.md) (`VAULT-FR-016`); the oracle **only reads it** ([ORCL-FR-014](#orcl-fr-014)).

**PriceFeedProxy (outer fixed reference)**

| Variable | Type | Description | Fixed by |
| --- | --- | --- | --- |
| `source` | `address` | Actual PriceFeed delegated to. A direct `source()` marker is rejected, but this is only a one-level type screen; semantic forwarding/cycles are excluded by dependency evidence. Replaceable | constructor (non-zero contract, direct marker rejected) / `confirmSource` update |
| pending source proposal | `(address newSource, uint256 readyAt)` | Recorded by `proposeSource`, cleared by `confirmSource`/`cancelSourceProposal` | `proposeSource` |
| `_lastGoodPrice` | `uint256` | Proxy self-defense cache for the normal price path. Returned by `fetchPrice` when source is bricked (permanent DoS prevention) | updated by constructor / `fetchPrice` / `confirmSource` |
| `_lastGoodRedemptionPrice` | `uint256` | Proxy self-defense cache for the redemption price path. For WBTC-like sources where normal and redemption prices can diverge, a bricked source must not collapse redemption fallback to the normal-price cache | updated by constructor / `fetchRedemptionPrice` / `confirmSource` |
| `TIMELOCK_DELAY` | `constant` | `12 hours` | constant |
| `owner` / `pendingOwner` | `address` | `Ownable2Step`. 2-step transfer. `renounceOwnership` disabled | constructor / transfer |
| `borrowerOperations` | `address` | Oracle-failure pause/resume target (`shutdownFromOracleFailure()` / `resumeFromOracleFailure()`) | constructor |

**DF PriceFeed implementations (inner source)**

| Variable | Type | Ownership | Description |
| --- | --- | --- | --- |
| `ethUsdOracle` (= collateral/USD; pseudocode `collUsdOracle`) | `Oracle{aggregator, stalenessThreshold, decimals}` | 🔵 upstream | Chainlink aggregator for collateral/USD. Upstream constructor asserts `decimals == 8`. Storage name remains upstream name (renaming would also be an edit) |
| `jpyUsdRateProvider` | `address immutable` | 🟢 DF (every active feed source) | Same `JpyUsdRateProvider` address in every branch. Feed sources do not duplicate JPY cache or freeze state |
| `jpyUsdOracle` / `lastGoodJpyRate` / `lastGoodJpyUpdatedAt` / `jpyFrozenSince` / `jpyFreezeExpired` | provider state | 🟢 DF (`JpyUsdRateProvider`) | One shared Chainlink binding, cache provenance, freeze onset, and expiry decision for the current freeze episode. A fresh response clears the episode state. Provider constructor requires a fresh 8-decimal response |
| `wbtcBtcOracle` | `Oracle{...}` | 🟢 DF (`DFWBTCPriceFeed`) | WBTC/BTC peg monitor (additional storage specific to Peg-monitored) |
| `xautXauOracle` | `Oracle{...}` | 🟢 DF (future `DFXAUTPriceFeed`) | XAUT/XAU peg monitor (added on Composite peg upgrade) |
| `rateProviderAddress` | `address immutable` | 🔵 upstream-derived (pruned `CompositePriceFeed`) | canonical rate source (for sUSDS: `0xa3931d71877C0E7a3148CB7Eb4463524FEc27fbD`) |
| `priceSource` | `enum PriceSource` | 🔵 upstream | Enum with `primary` / `ETHUSDxCanonical` / `lastGoodPrice`; production feeds use only `primary` / `lastGoodPrice` ([§12](#12-failure-and-exception-behavior-err)) |
| `lastGoodPrice` | `uint256` | 🔵 upstream | Last healthy price per feed (JPY-denominated and **after backing multiplication**, because backing is applied inside `_fetchPricePrimary`; [ORCL-FR-014](#orcl-fr-014)) |
| `collateralVault` | `address immutable` | 🟢 DF (backing multiplication layer, each feed implementation) | CollateralVault reference for backing ratio (constructor-set, feed↔Vault one-to-one; [ORCL-FR-014](#orcl-fr-014)) |
| `lastGoodBacking` | `uint256` | 🟢 DF (backing multiplication layer, each feed implementation) | Last healthy backing ratio (initial `1e18`, updated only by an available pricing read). Retained for monitoring/verification, but not used to continue pricing on call failure or `available == false`. Managed separately from `lastGoodPrice` |

**Accounting model**: The oracle layer only supplies prices (JPY-denominated) and has no collateral/debt accounting. Price is always derived as "collateral/USD (upstream base) -> JPY conversion (DF base) -> dToken backing-ratio multiplication (backing multiplication layer in each feed implementation, [ORCL-FR-014](#orcl-fr-014))" and recorded in `lastGoodPrice` (JPY-denominated, after backing multiplication). The subject that determines `A < L_effective` is not Oracle but CollateralVault / Strategy Underlying-denominated accounting; Oracle only multiplies an available `backingRatioForPricing()` value into market price. The ratio is **read only** from CollateralVault (accounting stays in Vault); read failure or unavailable valuation enters the standard oracle-failure path to avoid both continued overvaluation and misclassifying unreadable valuation as total loss. Proxy also has `_lastGoodPrice` / `_lastGoodRedemptionPrice` (JPY-denominated) as self-defense caches to prevent permanent DoS and cache mixing between consumer paths if source is bricked.

---

## 8. Invariants (INV)

| ID | Invariant | Verification |
| --- | --- | --- |
| ORCL-INV-001 | The `PriceFeedProxy` address seen by Protocol is immutable (core oracle reference is fixed). Only the `source` behind Proxy is replaced | manual / integration |
| ORCL-INV-002 | `source` replacement is possible only through `proposeSource` -> 12h timelock elapsed -> `confirmSource` / `confirmSourceEmergency` (no immediate replacement). The emergency path does not call the old source, so an old-source revert or all-gas consumption cannot destroy replacement liveness | unit / invariant |
| ORCL-INV-003 | `confirmSource` succeeds only at or after `proposedAt + TIMELOCK_DELAY` | unit |
| ORCL-INV-004 | `source` is always a non-zero real PriceFeed. Constructor/confirmation reject non-contracts, direct `IPriceFeedProxy.source()` markers, and invalid JPY provenance. The marker is a one-level type screen and does not prove dependency-graph acyclicity. Constructor requires valid `lastGoodPrice`, fresh provenance, and a successful urgent path while tolerating cache-backed normal/redemption fetch reverts. Confirmation requires all three price paths; aged provenance is allowed but not cached for normal redemption | unit / manual |
| ORCL-INV-005 | `fetchPrice` / `fetchRedemptionPrice` re-revert only gas guard revert (`InsufficientGasForExternalCall`, exactly 4 bytes, selector match); all other reverts / invalid prices go to shutdown path | unit / integration |
| ORCL-INV-006 | Even if source is bricked, Proxy returns its path-specific caches. A quote observed at or after `PRM-ORACLE-008` never replaces `_lastGoodRedemptionPrice`; urgent redemption never settles from either cache | unit |
| ORCL-INV-007 | All collateral prices are JPY-denominated (`collJpy = collUsd × 1e18 / jpyUsdRate`). Both `collUsd` and `jpyUsdRate` are normalized to 18 decimals | unit / fork |
| ORCL-INV-008 | Diffs against upstream price acquisition bases are explicitly managed. The `MainnetPriceFeedBase` diff is limited to invalidating incomplete Chainlink rounds (`roundId == 0` / `answeredInRound < roundId`) and invalid timestamps (`updatedAt == 0` / future timestamp), plus an internal provenance helper that returns the response `updatedAt` alongside the existing result without changing normal `_getOracleAnswer` semantics. `CompositePriceFeed` keeps only the sUSDS primary -> `lastGoodPrice` path, and static diff review confirms the unused WSTETH/RETH LST secondary fallback is removed. JPY conversion and backing multiplication stay inside DF files | manual / static diff review / unit |
| ORCL-INV-009 | Placeholder branches use `PriceFeedPlaceholder` (always `(1e18, false)` plus explicit self/current-time synthetic JPY provenance), do not trigger branch shutdown or the 30h gate, and remain inoperable through Vault / dToken multi-guards | unit / integration |
| ORCL-INV-010 | Active production feeds do not use `ETHUSDxCanonical`. After an oracle-failure pause they retry `primary` to prove recovery. The BO pause flag remains set until Owner resume and prevents automatic reopening of normal redemption and risk-increasing BO operations, while collateral additions and debt repayments against a healthy normal price follow CORE-MOD-014. `lastGoodPrice` state remains only for legacy/archived source compatibility. JPY/USD follows `ORCL-SEC-005` | unit |
| ORCL-INV-011 | dToken backing ratio is downward-only `backingRatio ∈ (0, 1e18]` (healthy `== 1e18`) and is symmetrically applied to all collateral prices as `dTokenJpy = collJpy × backingRatio / 1e18` on both consumers. If the pricing view returns `available == false` or the call fails, `lastGoodBacking` is not used as pass-through and the branch shuts down; a gas-guard revert is re-reverted. Only a measured zero with all Strategies valued receives the 1-wei floor ([ORCL-FR-014](#orcl-fr-014)) | unit / fork |
| ORCL-INV-012 | An active DF PriceFeed constructor succeeds only when its initial fetch leaves `priceSource == primary && lastGoodPrice != 0`. An unhealthy shared-JPY expiry, collateral oracle / canonical / backing failure, or failed shutdown call from an unregistered feed must revert with `InvalidInitialPrice` rather than deploy a zero cache; deployment resumes after fresh JPY recovery | unit / integration |
| ORCL-INV-013 | Healthy dwstETH normal and urgent redemption use `max(direct stETH/USD, ETH/USD × stETH/ETH)` and apply canonical rate, JPY, and backing exactly once in the same order. Urgent succeeds only while every input is valid under its leg policy, and has neither a third cache nor a direct-only fallback | unit / integration / fork |
| ORCL-INV-014 | Continuously compare Chainlink decimals stored by the current source/provider with live proxy `decimals()` at an RPC safe head. Day-1 covers two collateral/USD feeds, two dwstETH redemption auxiliaries, and one shared JPY/USD feed. Mismatch, configured/live read failure, or incomplete auxiliary-getter coverage is stable-key P0 `ALRT-ORCL-015`; one unreadable role does not suppress another. Only an explicit chain/address allowlist may exempt a legacy source without auxiliary getters | Ops unit / safe-block integration / labeled delivery |

---

## 9. Security Requirements (SEC)

### <a id="orcl-sec-001"></a>ORCL-SEC-001: Minimize upstream PriceFeed base diffs

- Type: Security
- Statement: Diffs against upstream PriceFeed bases must be minimized and justified. `MainnetPriceFeedBase` is allowed only the current Chainlink response-validation hardening. `CompositePriceFeed` keeps the primary -> `lastGoodPrice` path used by sUSDS and removes the upstream WSTETH/RETH LST secondary fallback. JPY conversion and backing multiplication stay in DF-owned files. The dwstETH behavior in `ORCL-FR-015`—direct stETH/USD for the normal price, redemption-only ETH/USD and stETH/ETH auxiliaries, and no `ETHUSDxCanonical` runtime fallback—is implemented in the DF-specific `DFWstETHPriceFeed` (reusing the pruned `CompositePriceFeed` base) rather than reintroducing or editing the pruned upstream fallback.
- Verification: manual (inheritance review), static diff review, unit (incomplete-round / invalid-timestamp branch shutdown / JPY soft-freeze)

### <a id="orcl-sec-002"></a>ORCL-SEC-002: Accuracy of gas griefing protection pass-through

- Type: Security
- Statement: `PriceFeedProxy` try/catch must re-revert raw only when the `MainnetPriceFeedBase` gas-griefing protection revert (`InsufficientGasForExternalCall`) matches by **selector and exactly 4 bytes**, while real oracle failures (e.g. `CallerNotPriceFeed()` also arriving as 4 bytes) must still go to the shutdown path. Selector-prefix-with-extra-data reverts must not be re-reverted (strict `== 4` length). The comparison selector must directly reference `MainnetPriceFeedBase.InsufficientGasForExternalCall.selector` and compile-time bind to upstream, so upstream rename/removal cannot silently disable the protection.
- Verification: unit (selector match, strict length, distinction from real failure), integration

### <a id="orcl-sec-003"></a>ORCL-SEC-003: MEV mitigation through source replacement timelock

- Type: Security
- Statement: source replacement must be 2-step: `proposeSource` -> 12h timelock -> `confirmSource` / `confirmSourceEmergency`, publishing planned switch time and new source 12h in advance (no unannounced replacement). This is shorter than the 24h shared JPY soft-freeze bound, while timelock alone still does not eliminate price-jump MEV in the `confirmSource` block. Normal `confirmSource` therefore limits normal/redemption price differences to within 1% of live old-source prices when healthy and the Proxy's path-specific last-good caches when unhealthy. If placeholder activation, a major price correction, or incident recovery requires exceeding the guard, GOV uses `confirmSourceEmergency` with private sending and combines it with monitoring, cap stop, keeper bundle, etc.
- Verification: unit (timelock enforcement, live/cached price-difference guard, no implicit bypass on old-source failure, emergency bypass, replacement liveness when the old source consumes all gas), manual (private-send operations and incident runbook)

### <a id="orcl-sec-004"></a>ORCL-SEC-004: Common consumer defenses and the explicit 30h exception

- Type: Security
- Statement: All three consumers share gas-guard pass-through and backing validation. Normal and normal-redemption failures retain pause and cache fallback; urgent uses FR-016 fail-closed behavior. The 30h provenance gate applies to normal redemption and BorrowerOperations price use. Liquidation and urgent pricing retain source-policy validity, including bounded JPY grace.
- Verification: unit (equivalent branches on both paths), integration

### <a id="orcl-sec-005"></a>ORCL-SEC-005: JPY/USD shared dependency failsafe

- Type: Security
- Statement: The JPY/USD oracle is shared by every branch and has the widest blast radius. Pure repayments and additions remain available without oracle reads. The 30h threshold plus 24h grace allows liquidation only while age is below 54h and all other inputs remain valid; earlier invalid responses can shorten that window. Exactly one `JpyUsdRateProvider` is deployed and injected into every active source. The provider stores `lastGoodJpyRate` with the same response's `lastGoodJpyUpdatedAt`, sets the bounded freeze onset, and continues reading fresh responses after expiry. A response is eligible for either the fresh or stale-but-new adoption path only when live `decimals()` matches the constructor-pinned 8-decimal value. A mismatch or ordinary decimals-read failure uses the bounded cached-rate policy without scaling or updating either cache field; an insufficient-gas decimals read re-reverts through the existing gas guard. A later fresh response after decimals returns to 8 can recover normally. At `PRM-ORACLE-008`, Proxy stops normal redemption before caching and also rejects BorrowerOperations price use, without `_handleFailedFetch`, `SourceFailureHandled`, or BO pause; the first fresh round clears this age gate automatically. During an unhealthy expired episode the source returns `failure=true`; the registered Proxy latches the recoverable BO pause. Active feeds stay on `primary` so recovery can be observed, but fresh provider recovery alone does not clear that BO flag. The exact freeze boundary is a frozen rate with `failure=false` while `freeze age < PRM-ORACLE-006`, and `failure=true` at exact expiry and beyond (`>=`). Economic shutdown requires JPY provenance younger than 30h and `TCR < SCR`; the `failure=true` result at exact expiry does not proceed to the TCR check or directly trigger irreversible shutdown. Collateral, peg-monitor, canonical-rate, and backing failures use the same recoverable pause and are evaluated before JPY fallback. An active source constructor must seed a primary nonzero price. Monitor provider and Proxy events externally and fail preflight if active sources reference different providers.
- Verification: unit (cache provenance, freeze and 30h redemption boundaries, runtime-decimals mismatch/revert/gas grief on fresh and stale-but-new paths, recovery after decimals returns to 8, recovery before/after expiry, repeated episode, active-source retry with BO pause retained, Standard/dwstETH constructor rejection under expiry and deployment after fresh recovery), integration (Proxy path), fork (JPY/USD staleness), manual (heartbeat × N and weekend history)
- Parameters: `PRM-ORACLE-001`, `PRM-ORACLE-006`, `PRM-ORACLE-008`

### <a id="orcl-sec-006"></a>ORCL-SEC-006: Peg monitoring for centralized wrapper collateral

- Type: Security
- Statement: A wrapper or receipt-token PriceFeed must not be activated unless its market depeg is reflected in on-chain collateral value. WBTC-type collateral uses wrapper/original peg monitoring; an XAUT candidate uses XAUT/XAU or direct XAUT/USD; wstETH uses the stETH/USD market price. Off-chain monitoring supports incident response but is not a substitute for on-chain price reflection.
- Verification: unit (synthetic calculation, shutdown on peg leg), fork (real peg feed), manual (mainnet feed availability and off-chain peg monitoring operations)

### <a id="orcl-sec-007"></a>ORCL-SEC-007: Placeholder branch inoperability (multi-guard)

- Type: Security
- Statement: Even though placeholder branches look healthy in price (`PriceFeedPlaceholder` returns `(1e18, false)`), they must be effectively inoperable through multi-guards in Vault (`underlying == address(0)` causing `deposit`/`redeem` revert and `UnderlyingMismatch`) and dToken (`TokenInfoNotSet`, `setCap(0)`). Do not rely on price stub alone.
- Verification: unit (each guard revert), integration (all value flows impossible in placeholder branch)

### <a id="orcl-sec-008"></a>ORCL-SEC-008: Live-price safety for urgent redemption

- Type: Security
- Statement: After irreversible shutdown, urgent settlement still uses oracle-lag/depeg-sensitive pricing and succeeds only while each input, including auxiliary feeds, is valid under that leg's policy. JPY/USD remains usable only inside ORCL-SEC-005's 24-hour soft-freeze; expiry is failure. Any input failure or source revert fails closed without cache or direct-only fallback. Preserve the gas-guard selector and add no urgent cache, governance settlement price, or raw ETH/USD-par substitute. This closes stale-low extraction on the collateral/USD leg; it does not claim to eliminate shared-JPY denominator lag or stale-high direct/derived underpayment selected by `max`.
- Verification: unit (every input failure, source revert, OOG, and no-cache fallback), integration / adversarial review

> **Reentrancy**: Oracle-layer reads (`fetchPrice` / `fetchRedemptionPrice`) only acquire prices and delegate shutdown; they do not transfer value. CEI / ReentrancyGuard is the responsibility of consumers ([CollateralVault](CollateralVault.md) / core). Although source is replaceable, Proxy does not fully trust source and treats reverts / invalid prices / brick defensively.

---

## 10. Governance, Operations, and Upgrade Requirements (GOV)

### <a id="orcl-gov-001"></a>ORCL-GOV-001: Owner is governance / multisig

- Statement: `PriceFeedProxy` Owner (authority for `proposeSource` / `confirmSource` / `cancelSourceProposal`) must be governance / multisig in production. Initial deployment may be owned by deployer EOA and transferred during production transition. In production the GOV multisig holds the Owner directly and is **not** placed under the common TimelockController (source replacement carries a built-in 12h, so routing it through the Timelock would double the delay and lose cancel immediacy; see Governance.md §5).
- Verification: manual (deployment and production transition configuration review)

### <a id="orcl-gov-002"></a>ORCL-GOV-002: Owner transfer is 2-step

- Statement: Owner transfer must use `Ownable2Step` (`transferOwnership` -> `acceptOwnership` by new owner) to prevent erroneous transfer from typos, etc. This aligns with dToken ([DTKN-GOV-002](dToken.md)) and Vault GOV operations.
- Verification: manual, unit (same as [ORCL-FR-006](#orcl-fr-006))

### <a id="orcl-gov-003"></a>ORCL-GOV-003: Disable Owner renounce

- Statement: `renounceOwnership()` must always revert. Permanently locking source would make JPY/USD shared dependency incident response, Chainlink deprecation, placeholder branch deferred binding, and future feed replacement impossible. Owner authority must not be burned; it is transferred to the GOV multisig through 2-step transfer (not placed under the common TimelockController; see Governance.md §5).
- Verification: manual (production transition configuration review), unit ([ORCL-FR-007](#orcl-fr-007))

### <a id="orcl-gov-004"></a>ORCL-GOV-004: Source replacement operations (feed-level replacement)

- Day-1 initial sources do not pass through the 12-hour proposal lifecycle. Freeze every initial Proxy/source dependency graph before broadcast in a fork dry-run and verify it after deployment under [Mainnet Deploy Env Freeze Runbook §3.1.2](../../launch/gates/Mainnet-Deploy-Env-Freeze-Runbook.md#312-initial-source-dependency-evidence).
- Statement: Logic changes are performed by deploying a new PriceFeed and replacing the feed-level source through `proposeSource()` -> 12h timelock -> `confirmSource()`, not by `upgradeTo` (`PriceFeedProxy` is non-upgradeable). Chainlink deprecation, collateral token changes, and Day-2 placeholder activation are handled without protocol redeployment.
- JPY/USD replacement is coordinated globally. Deploy one healthy replacement `JpyUsdRateProvider`, then deploy every replacement feed source against that exact provider address and verify the manifest/preflight provider-equality invariant before proposing any source. Manage all branch proposals, confirmations, and price-difference checks as one change set. Never deploy one provider per branch. Use normal `confirmSource()` when the new source is within 1% of the applicable live or path-specific cached references, including when the old source is unhealthy; use `confirmSourceEmergency()` privately only when the required correction exceeds that guard or the normal path cannot complete ([ORCL-SEC-003](#orcl-sec-003)).
- At proposal and again immediately before confirmation, record at one pinned block the target Proxy and proposed-source addresses/runtime codehashes; implementation addresses/codehashes for upgradeable nodes; immutable bindings; every forwarding/delegation edge; mutable routing state; and the administrators/owners able to change those edges. An independent reviewer confirms that the resulting dependency graph has no path back to the target PriceFeedProxy and no unreviewed mutable edge. Any drift or unknown edge requires cancellation rather than confirmation.
- The dependency graph is the semantic acyclicity evidence; addresses, codehashes, and routing state bind it to deployed state. The 12h lifecycle is review time and the three smoke calls prove only current ABI/price health. Neither independently proves acyclicity. Re-read source, codehashes, routing state, and events after confirmation.
- Verification: manual (replacement runbook), integration (replacement flow and JPY/USD source swap)

### <a id="orcl-gov-005"></a>ORCL-GOV-005: GOV procedure for Day-2 activation

- Statement: Unfinalized branch activation must follow the dToken-first order in [ORCL-FR-009](#orcl-fr-009) (`dToken.setTokenInfo` -> `vault.setUnderlying` -> `proposeSource`/`confirmSource` -> `setCap`) and GOV procedure must include cap pre-check. Order violation reverts with `UnderlyingMismatch`.
- Verification: manual (GOV runbook review), integration

---

## 11. Events and Monitoring Requirements (EVT)

| ID | Event | Purpose (off-chain) |
| --- | --- | --- |
| ORCL-EVT-001 | `SourceProposed` (new source and confirmable time) | Detect source replacement proposal, monitor 12h timelock, start pre-audit |
| ORCL-EVT-002 | `SourceUpdated(oldSource, newSource)` | Detect source replacement finalization (feed switch complete) |
| ORCL-EVT-003 | `SourceProposalCancelled` | Detect cancellation of pending proposal |
| ORCL-EVT-004 | Proxy `SourceFailureHandled(source)` and source `ShutDownFromOracleFailure(failedOracleAddr)` | P0 alert for recoverable oracle-failure pause; `failedOracleAddr` identifies the underlying oracle/backing/rate dependency |
| ORCL-EVT-005 | OZ `OwnershipTransferStarted` / `OwnershipTransferred` | Monitor ownership transfer (deployer -> multisig) |
| ORCL-EVT-006 | `SourceSwitchValidated` (old/reference and new prices, oldSourceHealthy, priceGuardBypassed) | Distinguish normal replacement / cached-reference recovery / explicit emergency bypass; audit price jumps |
| ORCL-EVT-007 | `JpyRateFrozen(timestamp, frozenRate)` | Detect JPY soft-freeze. `timestamp` is the earlier of first observation and the cached JPY rate's stale boundary, so it may predate the emission block |
| ORCL-EVT-008 | `JpyRateUnfrozen` | Detect return to the live JPY/USD rate |
| ORCL-EVT-009 | `JpyFreezeExpired(timestamp, frozenRate)` | Earliest stable P0 signal that the shared-JPY freeze expired; confirm each active branch's oracle-failure pause and user-action block |
| ORCL-EVT-010 | `RedemptionReferenceUnavailable(oracle, stEthUsdPrice)` | P0 signal that dwstETH's ETH/USD or stETH/ETH redemption protection is unavailable and redemption failed closed without direct-only fallback |
| ORCL-EVT-011 | `OracleFailureShutdownResumed(source, validatedPrice, validatedRedemptionPrice)` | Evidence that Owner validated all three price paths and cleared the BO oracle-failure pause. With aged/invalid JPY provenance the reported redemption quote is not cached and the normal-redemption gate remains |
| ORCL-EVT-012 | `UrgentRedemptionReferenceUnavailable(oracle, stEthUsdPrice)` | Diagnostic event identifying the failed auxiliary feed on a direct source call. It rolls back when the Proxy fail-closed transaction reverts and is not a primary alert source |

- Price itself and fallback to `lastGoodPrice` are observed through upstream-base events/state (this document does not define those event bodies).
- Pause body is `borrowerOperations.shutdownFromOracleFailure()` and Proxy makes it observable through ORCL-EVT-004. Read auxiliary-feed `latestRoundData.updatedAt` and configured thresholds at the same safe head; for stETH/ETH, emit `ALRT-ORCL-001` at age `>= 88,200s` (24.5h, chosen above the feed's own ~24h heartbeat so ordinary updates stay silent) and `ALRT-ORCL-012` at age `>= 90,000s`, resolving the same incident key on a fresh round. Enabled monitors for ORCL-EVT-004/009/010 must deliver to a human escalation target; launch verification includes a labeled test incident through creation, receipt, and resolution. Deduplicate repeated failure events at the alert layer.
- A permissionless keeper calls `fetchPrice()` and `fetchRedemptionPrice()` so failure is latched even when a reverting user BO transaction rolls back its nested pause/event, and probes the cache-free urgent path externally. Recovery uses Owner Safe `resumeFromOracleFailure()` and readbacks ORCL-EVT-011, `isOracleFailureShutdown == false`, and all three paths. A recovered current source can resume immediately; only source replacement waits the 12h timelock. Aged/invalid JPY provenance is not written into the redemption cache, so the normal-redemption and BorrowerOperations age gates remain until a fresh round.
- The `PRM-ORACLE-008` gate emits no event. At one hash-rechecked safe block, the external synthetic reads Proxy normal/normal-redemption/urgent, current-source normal-redemption, BO pause, and the current source/provider cached timestamp and limit. Proxy-only normal-redemption `failure=true`, with the other three price reads healthy and BO pause false, is the user-path truth; cached age/provenance is diagnostic because a simulated fresh provider update inside `eth_call` need not match persisted state. Use `ALRT-ORCL-016` and stable identity `chainId + PriceFeedProxy + normal-redemption-jpy-age`. Prove labeled delivery through the existing SNS-to-Amazon-Q route, human receipt, and same-key resolution.

---

## 12. Failure and Exception Behavior (ERR)

**Price acquisition path (`fetchPrice` / `fetchRedemptionPrice`, [ORCL-FR-004](#orcl-fr-004) / [ORCL-FR-005](#orcl-fr-005))**

| Trigger | Behavior |
| --- | --- |
| source success with valid price | normal path returns live price with `false` for liquidation, `TCR < SCR`, and CCR-checked close. Redemption cache updates, but returns `failure == true` while the BO pause is active |
| source success with invalid JPY provenance, or valid provenance and round age `>= PRM-ORACLE-008` | normal redemption alone returns `(price, true)`; no cache write, `_handleFailedFetch`, BO pause, or failure event. `fetchPrice` and urgent behavior are unchanged |
| gas guard revert (`InsufficientGasForExternalCall`, exactly 4 bytes, selector match) | re-revert as is (no shutdown, whole call reverts) = do not misclassify OOG as failure |
| other revert / invalid price (`0` or `type(uint256).max`) | delegate `shutdownFromOracleFailure()` to latch a recoverable pause -> if source `lastGoodPrice()` is readable, return it; if source is bricked, return Proxy's path-specific cache |

**Price source state machine (`PriceSource`, upstream `MainnetPriceFeedBase` definition retained)**

```javascript
enum PriceSource { primary, ETHUSDxCanonical, lastGoodPrice }
```

```javascript
        fetchPrice() OK
primary ──────────────▶ primary   (normal = Chainlink healthy)
   │                         ▲
   │ individual-leg failure │ retry primary to prove recovery
   ▼                         │
return lastGoodPrice + BO oracle-failure pause
```

- Active Standard and dwstETH sources retain `priceSource == primary`, retry live primary, and use `lastGoodPrice` only as the failure return value. Legacy/archived sources may still enter `lastGoodPrice` through the compatibility helper. `ETHUSDxCanonical` is not used; JPY/USD follows `ORCL-SEC-005`.

**JPY/USD weekends and holidays**

- `JPY/USD` is an FX market price, and markets normally close on weekends. If Chainlink feed `updatedAt` stops around Friday close but remains within the staleness threshold, treat it as "last healthy FX rate during market close," not an oracle failure.
- Implementation has no weekday/holiday logic. `MainnetPriceFeedBase` only checks `block.timestamp - updatedAt < stalenessThreshold`, so production staleness includes weekend margin. 48h is not adopted because `updatedAt` timing, on-chain update delay, and strict `<` comparison can cause boundary stop even on normal weekends.
- Monday FX gaps are assumed to be reflected by Chainlink deviation threshold / heartbeat updates. If update is delayed beyond staleness, JPY/USD still does not branch-shutdown because it is shared; it soft-freezes with `lastGoodJpyRate`. The tradeoff between weekend continuity and stale-gap risk immediately after Monday open is managed by final staleness values in [Parameters](../../../Parameters.md), monitoring `jpyFrozenSince` / `JpyRateFrozen`, and source replacement runbook if needed.

**Placeholder phase (Underlying unset) behavior**

| Layer | Placeholder phase | Active phase |
| --- | --- | --- |
| `PriceFeedPlaceholder.fetchPrice()` | `(1e18, false)` (does not trigger shutdown) | real PriceFeed JPY-denominated price |
| Vault `deposit`/`redeem` | `UnderlyingNotSet` / `UnderlyingMismatch` revert | executable |
| dToken `convertTo*` | `TokenInfoNotSet` revert | converted value |
| cap | `0` (cannot mint) | released with `setCap(N)` |

**Error catalog**

| Error | Trigger |
| --- | --- |
| `InvalidSource` | `PriceFeedProxy` constructor / `proposeSource` / confirmation sees a zero/non-contract/Proxy-marker source or a required initial/switch smoke-test failure. The constructor rejects both invalid and aged JPY provenance; confirmation rejects invalid provenance, while an aged source may be confirmed without updating the redemption cache ([ORCL-FR-001](#orcl-fr-001) / [ORCL-INV-004](#8-invariants-inv)) |
| `SameSource` | `proposeSource` / `confirmSource` receives a new source equal to the current `source` |
| `NoProposalPending` | `confirmSource` / `confirmSourceEmergency` / `cancelSourceProposal` is called without a pending proposal |
| `TimelockNotElapsed` | `confirmSource` / `confirmSourceEmergency` is called before `TIMELOCK_DELAY` (12h) has elapsed |
| `ZeroOwnerAddress` | `_ownerAddress == address(0)` in the `PriceFeedProxy` constructor |
| `InvalidAddress` | `_borrowerOperations == address(0)` in the `PriceFeedProxy` constructor |
| `SourcePriceDeviationTooLarge` | Normal `confirmSource` sees a new normal/normal-redemption/urgent quote more than `MAX_SOURCE_SWITCH_DEVIATION_BPS` (1%) from its reference. With a healthy old source, normal and urgent use live values; normal redemption uses its live value only with fresh provenance and otherwise uses `_lastGoodRedemptionPrice`. If the old source is unhealthy, the Proxy caches are used |
| `RenounceOwnershipDisabled` | `PriceFeedProxy.renounceOwnership()` call ([ORCL-FR-007](#orcl-fr-007) / [ORCL-GOV-003](#orcl-gov-003)) |
| `InsufficientGasForExternalCall` (re-revert) | Proxy passes through upstream gas griefing protection ([ORCL-FR-004](#orcl-fr-004)) |
| `CallerNotPriceFeed` (upstream) | Underlying feed directly calling `shutdownFromOracleFailure()` has `msg.sender != address(priceFeed)`. Proxy delegation avoids this ([ORCL-FR-004](#orcl-fr-004)) |
| `InvalidCollateralVault` | `DFPriceFeedBase` / `sUSDSPriceFeed` constructor receives a backing CollateralVault reference that is not a contract |
| `InvalidInitialPrice` | Initial fetch in an active `DFPriceFeedBase` / `DFWstETHPriceFeed` constructor leaves `priceSource != primary` or `lastGoodPrice == 0` (ORCL-INV-012) |
| `InvalidRateProvider` | `sUSDSPriceFeed` constructor receives an sUSDS rate provider, or the provider's `asset()`, that is not a contract |
| `InvalidRateProviderDecimals` | `sUSDSPriceFeed` constructor sees sUSDS or its asset using decimals other than 18 |
| `UnderlyingNotSet` (Vault side) | `deposit`/`redeem` in placeholder branch ([ORCL-FR-008](#orcl-fr-008)) |
| `UnderlyingMismatch` (Vault side) | dToken-first order violation / `dToken.underlying() != token` ([ORCL-FR-009](#orcl-fr-009)) |
| `TokenInfoNotSet` (dToken side) | `convertTo*` during placeholder phase ([ORCL-FR-008](#orcl-fr-008)) |

---

## 13. Acceptance Criteria and Verification Plan

Pass condition for each requirement = the verification method in the table is satisfied (test names and execution results are not written in this document; only the type of method is specified).

| ID | Requirement (summary) | Verification method |
| --- | --- | --- |
| ORCL-FR-001 | proposeSource (Owner-only; reject `address(0)` / EOA / self / direct marker; start timelock; separately review dependency graph) | unit, manual |
| ORCL-FR-002 | confirmSource / confirmSourceEmergency (only after timelock; recheck direct marker and dependency evidence; replacement reflected; normal price-difference guard; emergency bypass; old-source gas exhaustion cannot block emergency replacement) | unit, manual |
| ORCL-FR-003 | cancelSourceProposal (Owner-only, proposal cleared) | unit |
| ORCL-FR-004 | fetchPrice (failure pass-through, shutdown delegation, gas guard re-revert, brick fallback) | unit, fork, integration |
| ORCL-FR-005 | fetchRedemptionPrice (real-failure priority, 30h−1s / 30h boundary, provenance fail-closed, cache isolation, first-call recovery, Helper zero-fill/refund) | unit, integration, safe-head synthetic |
| ORCL-FR-006 | 2-step ownership transfer (mistaken-transfer prevention) | unit, manual |
| ORCL-FR-007 | renounceOwnership disabled (owner/source proposal/pendingOwner unchanged) | unit, manual |
| ORCL-FR-008 | PriceFeedPlaceholder (`(1e18, false)`, no shutdown, multi-guard) | unit, integration |
| ORCL-FR-009 | Day-2 activation flow (dToken-first order, cap pre-check) | unit, integration, manual |
| ORCL-FR-010 | Standard (WETH / USDC; collateral/USD failure shutdown, JPY/USD failure soft-freeze) | unit, fork, integration |
| ORCL-FR-011 | Peg-monitored (WBTC; peg/collateral/USD failure shutdown, JPY/USD failure soft-freeze) | unit, fork, integration |
| ORCL-FR-012 | Composite rate (sUSDS; USDS/USD/canonical rate failure shutdown, JPY/USD failure soft-freeze) | unit, fork, integration |
| ORCL-FR-013 | Future XAUT candidate uses on-chain downside-depeg reflection as a mandatory activation condition | unit, fork, integration, manual |
| ORCL-FR-014 | Apply dToken backing to all three consumers in the same order and fail closed when valuation is unavailable | unit, fork, integration |
| ORCL-FR-015 | dwstETH (stETH/USD × canonical rate composite, JPY/USD, backing ratio) | unit, fork, integration, invariant |
| ORCL-FR-016 | urgent wind-down price (composite-aware, succeeds only with policy-valid live inputs, no cache fallback) | unit, fork, integration |
| ORCL-INV-001..014 | Each invariant in §8 | unit / invariant / fork / manual / CI (as specified in §8) |
| ORCL-SEC-001..008 | Each security requirement in §9 | unit / fork / integration / manual / CI |
| ORCL-GOV-004 | Initial/replacement dependency-graph acyclicity, pinned state, independent review, and abort on drift | manual |
| ORCL-EVT-001..012 | Each event/monitoring requirement in §11 | unit / integration / Ops unit / labeled delivery (as specified in §11) |

---

## 14. Open Items (TBD)

### ORCL-TBD-001

Open: finalize `PRM-ORACLE-003` and `PRM-ORACLE-004` before mainnet broadcast. Branches 2–7 have no collateral/USD input until a separately approved activation package binds an exact Underlying. `PRM-ORACLE-001`, `006`, and `008` define the audit remediation candidate; `PRM-ORACLE-002` / `007` protect dwstETH redemption. `PRM-ORACLE-008` reduces normal-redemption feed-silence exposure to 30h, while the 54h liquidation/urgent policy envelope, sub-30h divergence, same-value heartbeat updates, and stale-high `max(direct, derived)` settlement remain Product / Protocol Risk trade-offs rather than guaranteed exploit amounts.

Historical evidence record (non-normative; active values are canonical only in [Parameters](../../../Parameters.md)):

- In Chainlink official feed data (`https://reference-data-directory.vercel.app/feeds-mainnet.json`), the target Ethereum mainnet standard feed metadata is ETH/USD heartbeat 3600s / deviation 0.5%, JPY/USD heartbeat 86400s / deviation 0.15% / marketHours `Forex`, XAU/USD heartbeat 86400s / deviation 0.3% / marketHours `Precious_Metals`, USDC/USD and USDS/USD heartbeat 82800s, USDT/USD heartbeat 86400s.
- `MainnetPriceFeedBase` stale determination is the strict `<` of `block.timestamp - updatedAt < stalenessThreshold`. Therefore using a 24h threshold directly on a 24h heartbeat feed leaves zero margin near a normal heartbeat and retains a false-shutdown risk.
- The staleness threshold is needed to separate "`latestRoundData()` returns" from "that price is usable for the current market." Without a threshold, over-borrowing at an old high, over-liquidation at an old low, and delayed JPY conversion propagate directly into collateral valuation, redemption, and liquidation. Conversely, too short a threshold causes false shutdown from a feed's regular heartbeat / market hours / on-chain update delay, so margin is placed according to each feed's heartbeat and blast radius.
- ETH/USD has an official 1h heartbeat, so the candidate value **24h** equals upstream ETH/USD's operating value and is clearly stricter than a daily heartbeat feed.
- USDC/USD, USDT/USD, and USDS/USD have official heartbeats of about 23h–24h, so the candidate value **48h** is a 2-heartbeat approximation. 24h is not adopted because it gives zero margin against the strict `<` and the observed max gap of 23–24.0h.
- XAU/USD research remains historical only; a future XAUT activation must adopt an on-chain downside-depeg-reflecting design and freeze its own staleness policy.
- JPY/USD is shared by all branches. Use **30h (108,000 seconds)** plus 24h cached-rate grace. Historical observations near the 24h heartbeat do not justify treating nearly 72h of silence as normal weekend behavior. See the [decision memo](../../launch/decisions/jpyusd-staleness-threshold-determination.md) for the retained historical sample and residual trade-off.

Implementation behavior on threshold exceedance:

- If a branch-local collateral/USD leg (ETH/USD, USDC/USD, USDT/USD, USDS/USD, XAU/USD, etc.) becomes stale / invalid / revert, `fetchPrice()` latches the branch's recoverable oracle pause and returns `lastGoodPrice` with the failure flag. While the current normal price remains unhealthy, price-dependent BorrowerOperations and normal redemption stop, interest continues, and urgent redemption remains disabled. Once the normal price is healthy, liquidation, the `TCR < SCR` check, CCR-constrained `closeTrove`, collateral additions, and debt repayments can run before Owner resume; normal redemption, collateral withdrawal, and debt increase still wait for the Proxy owner to validate all consumer paths and call `resumeFromOracleFailure()` (CORE-MOD-014).
- If the JPY/USD leg becomes stale / invalid / revert, to avoid simultaneous shutdown of all branches it does not shut down immediately and uses `lastGoodJpyRate`. The feed stores the matching healthy `updatedAt` and records `jpyFrozenSince` as the earlier of first observation and that cached rate's stale boundary. If it returns fresh within the remaining 24h window, it emits `JpyRateUnfrozen` and returns to the live rate. If the freeze has continued for `MAX_JPY_FREEZE_DURATION` (24h) or more, including before the first post-dormancy call, it transitions to standard `lastGoodPrice` shutdown.
- Monitoring / keepers treat `JpyRateFrozen.timestamp` and `jpyFrozenSince` as the failure boundary rather than the event block, and separately monitor `latestRoundData.updatedAt`, `JpyRateUnfrozen`, and `ShutDownFromOracleFailure`.
- A Chainlink read failure due to insufficient gas is re-reverted as `InsufficientGasForExternalCall` and not converted into a false shutdown / false freeze.

Generic test fixtures may use COLL/USDS 24h and JPY 72h; these are not deployment defaults. The 30h/54h integration fixture is for strict `<` boundary-semantics validation; production freeze reconciles the frozen `PRM-ORACLE-*` seconds in [Parameters](../../../Parameters.md) against env / manifest / fork evidence. Related: [ORCL-SEC-005](#orcl-sec-005).

### ORCL-TBD-002

Resolved: incorporated into `ORCL-FR-012`, `ORCL-FR-014`, and `ORCL-SEC-001`.

### ORCL-TBD-003

If XAUT is evaluated as a collateral candidate, finalize feed-quality criteria and the Composite peg implementation. This does not bind XAUT to the current branch map or imply activation.

- **Finalize quality criteria**: determine minimum price-source liquidity, feed category, mainnet operating history, weekend behavior, deviation, and heartbeat. Do not activate while available feeds are below the approved criteria.
- **Availability status (2026-06-10, Chainlink official feed registry observation)**: Ethereum mainnet has XAU/USD only (no XAUT/XAU or XAUT/USD; PAXG/USD exists). XAUT/USD is available on non-mainnet chains in observed set (Hyperliquid [standard + SVR 2 proxies] and Plasma; heartbeat 24h, deviation 0.5%; not exhaustive). Arbitrum registry XAUT/USD-RefPrice entry has no deployed contract and is not consumable. No direct XAUT/XAU ratio feed was found from checked providers. Before implementation, re-check Chainlink official addresses page.
- **Finalize implementation form on upgrade**: if the primitive provided is XAUT/USD (market), decide between (i) ratio synthesis (`xautXau = xautUsd × 1e18 / xauUsd` used as peg leg in WBTC-like structure) or (ii) Standard replacement with `collUsdOracle = XAUT/USD`. Design caution: XAU/USD follows Precious_Metals market hours (weekends see only last-value heartbeat updates), while XAUT/USD is Crypto 24/7, so on weekends the ratio can appear divergent only due to gold off-market movement (false depeg signal). Also decide whether to count premium side (XAUT > XAU) into collateral value or cap with `min(1e18, ratio)`.
- **Off-chain peg-monitoring alert threshold and runbook (Day-1 finalized)**: continuously monitor the downside peg ratio `r = XAUT/USD market median / XAU/USD` using at least two independent XAUT/USD market sources plus Chainlink XAU/USD. Premium (`r > 1`) is not credited to collateral value or used to justify a mintCap increase. The monitor only pages operators; it must not auto-pause contracts because weekend market-hour mismatch and venue noise can create false peg signals.
  - **Watch**: `r < 0.99` for two consecutive samples, any sample `r < 0.985`, or source dispersion above 1.5%. Notify ops, check source health, no on-chain action by default.
  - **Incident**: 1h median `r < 0.98` or any sample `r < 0.97`. Guardian manually calls XAUT Vault `pauseDeposit` and `pauseAllocation`; redeem/claim remain open unless there is a separate Vault solvency or transferability incident. GOV queues `dToken.setCap(0)` (or an equivalent no-new-mint cap) if the condition persists or source quality is disputed.
  - **Critical**: 1h median `r < 0.96`, any sample `r < 0.94`, failed Tether redemption/transferability evidence, or prolonged source disagreement. Keep deposit/allocation paused, execute/queue cap freeze, start source-replacement review, and assess whether branch shutdown preconditions/economics are met. Branch shutdown remains a last resort because it is irreversible and may preserve an overstated last-good price.
  - **Recovery**: unpause only after at least 24h with 1h median `r >= 0.99`, source dispersion <= 1%, and explicit guardian/GOV sign-off. The static MCR haircut uses 7.616% downside depeg; the incident/critical bands intentionally trigger well before that loss budget is consumed.
- **Alternative peg source**: Tether Gold on-chain proof-of-reserves or similar (requires due diligence). Non-Chainlink sources (Pyth `Crypto.XAUT/USD` [pull], RedStone [multi-CEX aggregation; mainnet permanent push feed unconfirmed]) change the Chainlink-only trust boundary ([`ADR-005`](../architecture/Architecture-Decision-Records.md#adr-005)), so ADR revision must precede adoption.

### ORCL-TBD-004

Fallback feed if USDS/USD is deprecated — because USDS is DAI's 1:1 successor, if USDS/USD is deprecated in the future, replacing it with DAI/USD (`0xAed0c38402a5d19df6E4c03F4E2DceD6e29c1ee9`) through `PriceFeedProxy` is an option. Final checksum must be compared against Chainlink official addresses page. Related: [ORCL-FR-012](#orcl-fr-012).

### ORCL-TBD-005

Resolved: incorporated into `ORCL-SEC-003`.

### ORCL-TBD-006

Resolved: incorporated into `ORCL-FR-014` and `VAULT-INV-012`.

> Note (Sepolia): on Sepolia testnet, staleness for all feeds is relaxed to 7 days (separate from production finalization in [ORCL-TBD-001](#orcl-tbd-001)).

---

## 15. References

- [Product Overview](../Product-Overview.md) — overall architecture, responsibility separation, and no-core-modification policy
- [Liquity-v2-Core-Spec](Liquity-v2-Core-Spec.md) — 🔵 core collateral, liquidation, Redemption, and upstream PriceFeed bases (`MainnetPriceFeedBase` / sUSDS-pruned `CompositePriceFeed`, `PriceSource`, shutdown, gas griefing protection)
- [dToken Requirements Specification](dToken.md) — placeholder branches, `setTokenInfo`, cap, `convertTo*` (dToken-first coordination for Day-2 activation)
- [CollateralVault Requirements Specification](CollateralVault.md) — `setUnderlying`, `UnderlyingNotSet`/`UnderlyingMismatch`, mint/redeem (placeholder multi-guard coordination)
- [Parameters.md](../../../Parameters.md) — canonical source for branch↔collateral allocation, finalized status, staleness values, MCR/LLTV/CCR, depeg haircut values
- 🔵 `contracts/src/PriceFeeds/MainnetPriceFeedBase.sol` — **upstream-derived with a hardening diff**. Chainlink acquisition, 18-decimal normalization, `PriceSource`, shutdown (does not include JPY conversion). Treats `roundId == 0`, `answeredInRound < roundId`, `updatedAt == 0`, and future `updatedAt` as invalid, and can return the response `updatedAt` alongside the existing internal result as provenance.
- 🔵 `contracts/src/PriceFeeds/CompositePriceFeed.sol` — **upstream-derived with sUSDS pruning**. Composite base for `USDS/USD × canonical rate` (`sUSDSPriceFeed` parent). WSTETH/RETH LST secondary fallback is removed from production `src`
- 🟢 `contracts/src/PriceFeeds/JpyUsdRateProvider.sol` — **DF new**. Single deployment-wide JPY/USD Chainlink cache, freeze timer, recovery, and latched expiry state machine
- 🟢 `contracts/src/PriceFeeds/DFPriceFeedBase.sol` — **DF new**. `is MainnetPriceFeedBase`. Consumes `JpyUsdRateProvider` for USD->JPY conversion and adds `collateralVault.backingRatioForPricing()` multiplication (parent of standard/peg DF feeds)
- 🟢 `contracts/src/PriceFeeds/PriceFeedProxy.sol` — **DF new**. Source replacement (12h timelock), try/catch shutdown, `Ownable2Step`
- 🟢 `contracts/src/PriceFeeds/DFUSDCPriceFeed.sol` — **DF new**. Collateral-specific PriceFeed (inherits `DFPriceFeedBase`, returns JPY-denominated prices). Archived candidates: `contracts/src/PriceFeeds/archive/DFUSDTPriceFeed.sol` / `contracts/src/PriceFeeds/archive/DFXAUTPriceFeed.sol` / `contracts/src/PriceFeeds/archive/DFWBTCPriceFeed.sol`
- 🟢 `contracts/src/PriceFeeds/JpyFreezeLib.sol` — **DF new**. Shared JPY conversion / freeze / backing library; feeds hold only its state
- 🟢 `contracts/src/PriceFeeds/DFWstETHPriceFeed.sol` — **DF new**. dwstETH stETH/USD × canonical-rate composite in `ORCL-FR-015` (inherits the pruned `CompositePriceFeed`), including canonical rate, JPY conversion, and backing multiplication
- 🟢 `contracts/src/PriceFeeds/archive/sUSDSPriceFeed.sol` — **DF new (archived candidate)**. Composite rate (sUSDS-pruned `CompositePriceFeed` + shared-provider JPY conversion + local backing multiplication)
- 🟢 `contracts/src/PriceFeeds/PriceFeedPlaceholder.sol` — **DF new**. Initial source for placeholder branches
- `contracts/script/DeployLiquity2.s.sol` — feed, staleness, and address wiring
- Chainlink Data Feeds: [https://data.chain.link/](https://data.chain.link/)
- [Requirements Specification Standard](../../../README.md#requirements-spec-standard) — the standard this document follows
