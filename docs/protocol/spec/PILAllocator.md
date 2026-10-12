# 🟢 PILAllocator / PIL Allocation Layer Requirements

## 0. Metadata

| Item | Value |
| --- | --- |
| Status | Draft (initial implementation exists; parameters provisional. Phase-A = admin allocation is the main scope of this document; Phase-B = voting allocation is policy only) |
| Owner | DeltaForesight |
| Target contracts | 🟢 Original: `contracts/src/PILAllocator.sol` (admin weighted allocation, non-UUPS / immutable) / `contracts/src/Interfaces/IInitiative.sol` (compatible with upstream `liquity/V2-gov`, 4 hooks) / `contracts/src/Interfaces/IDistributionCreator.sol` (Merkl interface) / `contracts/src/Initiatives/UniV4MerklInitiative.sol` (Uniswap v4 allocation via Merkl) / the `requireValidRecipient` view helper of `contracts/src/JpydfToken.sol` |
| Related documents | [InterestRouter](InterestRouter.md) (`IRTR-GOV-003` / `IRTR-TBD-004` = the upstream that places this layer as `recipient`) / [Liquity-v2-Core-Spec](Liquity-v2-Core-Spec.md) (`CORE-AP-FR-007` PIL mint) / [Treasury](../../roadmap/spec/Treasury.md) (collateral yield = independent path; separate from PIL) / [Governance-Roles-Timelock](../policies/Governance-Roles-Timelock.md) / [Day1-Self-BS-Initial-Liquidity-Plan](../../../contributors/deltaforesight/commitments/Day1-Self-BS-Initial-Liquidity-Plan.md) (operator self-B/S seed liquidity) / [Mainnet-Deploy-Env-Freeze-Runbook](../../launch/gates/Mainnet-Deploy-Env-Freeze-Runbook.md) (`DeployPILAllocatorPhaseA` activation package) / [Product-Overview](../Product-Overview.md) (PIL) / [Architecture Decision Records](../architecture/Architecture-Decision-Records.md) (ADR-004/005) / [Mainnet Launch Risk Gate](../../launch/gates/Mainnet-Launch-Risk-Gate.md#sys-risk-003) / [Reference study (Liquity/Nerite/Asymmetry)](../../../engineering/historical-reviews/2026-06-25-PIL-DEX-Allocation-Reference-Liquity-Nerite-Asymmetry.md) |

> This document follows the [Requirements Spec Standard](../../../README.md#requirements-spec-standard). Requirement IDs use `PILA-*`.
> **Core parity principle**: aggregate-interest SP/PIL distribution, minting to `interestRouter`, and immutable binding are 🔵 Core normative behavior (`CORE-AP-*`) and are not respecified. The Forwarder that receives the PIL funds is normatively specified by [InterestRouter](InterestRouter.md) (`IRTR-*`). This document specifies only the **allocation layer placed as the Forwarder's `recipient` and everything downstream of it**.
> **Markers**: 🟢 Original (DeltaForesight-specific, added outside Core. Core unmodified, ARCH-001/004).

### 0.1 Phase Terminology (important; reconciliation with other docs)

In this document, **Phase-A / Phase-B are "stages internal to the PIL allocation layer"**, which are on a **separate axis from Day-1 (mainnet launch) / Day-2 (operation of the PIL allocation mechanism)** in [Product-Overview](../Product-Overview.md) / [InterestRouter](InterestRouter.md). The correspondence is as follows.

| Stage in this document | Content | Position in upstream docs |
| --- | --- | --- |
| **Phase-A** | admin (GOV->Timelock) registers initiatives and sets weights. No voting | The **first concrete instance** of what `IRTR-GOV-003` / `IRTR-TBD-004` call the "Day-2 PIL Distributor / governance" |
| **Phase-B** | Time-weighted voting by an undecided voting token (DFT only if separately adopted), limited to weights among allowlisted initiatives. **This document is policy only; separate doc / separate audit** | Successor to the above (recipient swapped to `VotingAllocator`) |

> The Day-1 production policy is **deploy-ready / evidence-ready, but inactive** ([PILA-TBD-006](#pila-tbd-006) is resolved). `PILAllocator` / `UniV4MerklInitiative` may be included in audit scope and the activation package, but the standard launch keeps the initial `InterestRouterForwarder` `recipient` as a PIL-dedicated holding Safe/address. `DF_INTEREST_ROUTER_RECIPIENT=PILAllocator`, initiative registration, active weight setting, and Merkl campaign creation are not executed until a later activation gate. Even after a later gate connects the allocator, if weights are unset, all PIL remains retained at the allocator and the behavior is equivalent to the current `IRTR` "Day-1 = recipient retention" ([PILA-INV-004](#8-invariants-inv)).

---

## 1. Purpose, Scope, and Non-Responsibilities

🔵 Core mints the PIL residual of aggregate interest (the 25% excluding `SP_YIELD_SPLIT`) to `interestRouter` as JPYdf (`CORE-AP-FR-007`). The `InterestRouterForwarder` of [InterestRouter](InterestRouter.md) receives it and flushes it to the current `recipient` via `route()` (`IRTR-FR-002`). This document specifies the **allocation layer placed as that `recipient`**, which allocates PIL to **DEX liquidity incentives**.

The core of the design is to **follow the upstream Liquity v2 structure (`liquity/V2-gov`: `Governance` + `IInitiative` + DEX initiative), while replacing the voting part with admin-configured weights in Phase-A**. This allows migration to Phase-B (DFT voting) by **swapping only the recipient, leaving Core / Forwarder / existing initiatives unmodified** (the same "immutable upstream + replaceable downstream" pattern as ADR-004/005).

- **Specified by this document**:
  - `PILAllocator` — the receiver that splits JPYdf received from the Forwarder among registered initiatives **by admin-configured weights** (Phase-A). It follows the epoch / allocation skeleton of upstream `Governance`, replacing voting with admin weights.
  - `IInitiative` — **fully compatible** with the `IInitiative` of upstream `liquity/V2-gov` (4 hooks). It lets the Phase-B `VotingAllocator` reuse the very same initiatives.
  - `UniV4MerklInitiative` — the sole Phase-A initiative that allocates PIL **to the JPYdf Uniswap v4 pool via Merkl (Angle `DistributionCreator`)** (port of upstream `UniV4MerklRewards`).
  - Phase-A -> Phase-B migration / extension boundary (§10).
- **Not specified by this document (non-responsibilities, other documents)**:
  - Aggregate-interest SP/PIL distribution, minting to `interestRouter`, and immutable binding -> 🔵 [Liquity-v2-Core-Spec](Liquity-v2-Core-Spec.md) (`CORE-AP-FR-003/007`).
  - Receipt of PIL funds, `route()`, and `recipient` replacement -> [InterestRouter](InterestRouter.md) (`IRTR-*`). This document is downstream of it.
  - **Implementation details of Phase-B (DFT voting allocation)** (staking, epoch voting, bribe markets, the voting version of permissionless registration) -> the Day-2 `VotingAllocator` separate doc / separate audit (policy in §10).
  - **Curve-type initiatives** (`CurveGaugeInitiative`, etc.) -> Day-2, **out of Phase-A audit scope** (§10, [PILA-GOV-005](#10-governance-operations-and-upgrade-requirements-gov)). The design is made initiative-agnostic so they can be accepted.
  - Distribution / buyback of collateral yield (Strategy yield) -> [Treasury](../../roadmap/spec/Treasury.md) (a separate path from PIL).
  - Provision and management of the operator's self-B/S seed liquidity itself -> [Day1-Self-BS-Initial-Liquidity-Plan](../../../contributors/deltaforesight/commitments/Day1-Self-BS-Initial-Liquidity-Plan.md) (out of scope of this document).
  - Concrete parameter values (pool id / weight / threshold / Merkl address / blacklist method) -> [Parameters](../../../Parameters.md) (§14 TBD).

---

## 2. Background and Design Policy

### 2.1 Starting Point (immutable upstream constraints)

| # | Fact | Consequence |
| --- | --- | --- |
| 1 | PIL funds arrive at `InterestRouterForwarder` as JPYdf and are pushed in full to the current `recipient` via `route()` (`IRTR-FR-002`). **There is no callback on receipt** | Allocation logic is closed on the recipient side. The allocator is dual-mode: push receipt ("get poked and distribute") and pull invocation |
| 2 | `interestRouter` is immutable, but the Forwarder's `recipient` can be replaced by the owner (Timelock) (`IRTR-FR-003`) | The allocation layer can be **swapped Phase-A->Phase-B without redeploying** |
| 3 | Upstream `liquity/V2-gov` has `interestRouter = Governance` (voting allocation). jpydf cannot vote on Day-1 because DFT is not issued (`CORE-AP-TBD-001` / `IRTR` §1) | Insert a Phase-A that substitutes admin weights for voting |

### 2.2 Design Policy

1. **Follow the upstream structure (for unmodified Phase-B migration)**: make `IInitiative` fully upstream-compatible (4 hooks), and have `PILAllocator` keep the epoch / claim skeleton of upstream `Governance` while replacing "vote-share proration" with "admin-weight proration". In Phase-B, all that is needed is swapping the recipient to `VotingAllocator` (compliant with upstream `Governance`), **reusing the same initiatives**.
2. **Allocation-target agnostic (initiative abstraction)**: `PILAllocator` touches initiatives only through `IInitiative`. DEX-specific implementations such as Uniswap v4 / Curve are not brought into the allocator. Adding Curve, etc., only requires **deploying + registering a new initiative**, keeping the allocator, existing initiatives, and Core unmodified (§10).
3. **Explicit allocation (no treasury sink)**: the active weight total must be **only 0 or `1e18`**. Allowing a partial total (`0 < Σweight < 1e18`) is forbidden because repeated permissionless `distribute()` would break the meaning of the unallocated portion. During periods of no allocation, set `Σweight = 0`; if you want to route PIL to a treasury/Foundation/reserve, register that Safe as **a single initiative** and give it weight (the same shape as upstream registering the grants Safe `defiCollectiveInitiative` as an initiative). Only small amounts below the threshold are carried over to the allocator.
4. **Bounded allocation loop**: because `distribute()` iterates over all registered initiatives, Phase-A fixes `MAX_INITIATIVES = 32` as a contract constant. If more than 32 allocation targets are needed in the future, deploy a new allocator and swap with `forwarder.setRecipient`.
5. **Permissionless allocation, keeper-prioritized campaign creation**: `distribute()` is permissionless (anyone; keeper optional). An initiative's `createCampaign()` can be executed at any time by the `CAMPAIGN_CREATOR`, and a general caller can execute it only within the `CAMPAIGN_CREATION_WINDOW` immediately before `campaignStart`. This prevents front-running grief caused by Merkl's "one campaign per identical start" constraint while leaving a public fallback for keeper failure. Merkl campaigns follow upstream with a fixed `EPOCH_DURATION` (default around 7 days) and `startTimestamp = epochEnd` (§6).
6. **Isolation of malicious initiatives**: hook calls use `safeCallWithMinGas` (minimum-gas guarantee, try-equivalent) so that the failure of one initiative does not stop allocation to other initiatives (follows upstream). Hook success/failure is emitted in events so monitoring can detect failures.
7. **Non-UUPS, replacement migration**: `PILAllocator` and each initiative are immutable (non-upgradeable). Behavior changes or Phase-B migration are done by **deploying a new contract + swapping with `forwarder.setRecipient`** (consistent with ADR-001, audit simplicity; same policy as `IRTR-GOV-004`).
8. **Authority separation**: registration, weights, and pause/unpause go through GOV->shared Timelock (24h). Only emergency pause is immediate by GUARDIAN. owner is 2-step, renounce disabled (same shape as `IRTR-FR-004`).
9. **Activation-agnostic**: even with weights unset and 0 initiatives, funds are retained safely ([PILA-INV-004](#8-invariants-inv)). Day-1 defaults to deploy-ready / inactive, and Phase-A active routing is executed only by a later activation gate with Merkl, pool, weight, and Timelock bundle evidence ([PILA-TBD-006](#pila-tbd-006)).

### 2.3 Correspondence with Upstream (admin substitutes for voting)

| Upstream `liquity/V2-gov` | This document Phase-A (`PILAllocator`) | Phase-B (`VotingAllocator`, separate doc) |
| --- | --- | --- |
| `Governance.sol` (voting allocation) | `PILAllocator` (**admin weight allocation**) | `VotingAllocator` (DFT voting, upstream-compliant) |
| `registerInitiative` (permissionless, fee + threshold) | **admin (Timelock) registration** | permissionless (voting version) |
| Vote share `votes_i/Σvotes × boldAccrued` | **admin weight `weight_i/1e18 × balance`** | Vote share |
| Recycle unclaimed amounts | **all weights 0 / below-threshold carry-over**. When active, `Σweight = 1e18` | Recycle unclaimed amounts |
| `IInitiative` (4 hooks) | Same (fully compatible) | Same |
| `UniV4MerklRewards` / `CurveV2GaugeRewards` | `UniV4MerklInitiative` only | Add Curve, etc. |

---

## 3. Terms, External Dependencies, and Assumptions

### 3.1 Terms

| Term | Meaning |
| --- | --- |
| PIL | Protocol Incentivised Liquidity. A JPYdf liquidity incentive funded by the residual borrowing interest (25%) |
| initiative | One unit of PIL allocation target. **Any address** satisfying `IInitiative` (either a DEX allocation contract or a plain Safe). Granularity is **1 address = 1 allocation target** (not per DEX/protocol; a Curve USDC pool and USDT pool are separate initiatives = [Reference study](../../../engineering/historical-reviews/2026-06-25-PIL-DEX-Allocation-Reference-Liquity-Nerite-Asymmetry.md)) |
| weight | The allocation ratio per initiative (1e18 fixed-point). The total is **0 or `1e18`**. The reserve/Treasury share is also made explicit as an initiative |
| `distribute()` | The permissionless function that prorates the JPYdf held by the allocator by weight and pushes it to each initiative |
| `onClaimForInitiative` | The notification hook called by the allocator after allocating to an initiative (upstream `IInitiative`) |
| `onAfterAllocateLQTY` | The hook that upstream `Governance` calls to an initiative "each time a user changes their voting allocation". The initiative records "who voted how much in which epoch" and uses it as the basis for bribe proration, etc. **Unused in Phase-A (no voting)**, but retained in the interface for Phase-B reuse ([PILA-FR-102](#pila-fr-102-retain-onafterallocatelqty-unused-in-phase-a)) |
| epoch | The fixed cycle of allocation / campaigns. `EPOCH_START` / `EPOCH_DURATION` are immutable (same signature as upstream `Governance`) |
| Merkl | Angle Labs' `DistributionCreator`. Given a reward token, it creates a campaign that distributes to pool LPs by off-chain calculation (used by upstream `UniV4MerklRewards`) |
| campaign blacklist | Addresses excluded from incentives in a Merkl campaign. **Empty on Day-1 (no targets)**. Upstream blacklists one entry, its own Funds Safe |
| campaign creator | The operational keeper / Safe that can execute `UniV4MerklInitiative`'s `createCampaign()` early. A general caller can execute only within the fallback window |
| campaign creation window | The period immediately before `campaignStart` during which `createCampaign()` is opened to general callers. A public fallback to ensure liveness on keeper failure |

### 3.2 External Dependencies (trusted external components)

- **InterestRouterForwarder (🟢 DF, upstream)** — the sole supplier of PIL funds. Pushed via `route()` (`IRTR-FR-002`). The allocator never calls the Forwarder.
- **JpydfToken (JPYdf, 🔵 Core)** — the allocation token. Relies on standard ERC-20 (no transfer hook) ([PILA-SEC-005](#9-security-requirements-sec)).
- **Merkl `DistributionCreator` (Angle Labs, Ethereum mainnet)** — a **new trust boundary** used by `UniV4MerklInitiative` for campaign creation. Depends on its off-chain calculation, claim, fees, and terms of use (`acceptConditions`). Adopts a trust premise equivalent to upstream Liquity ([PILA-SEC-001](#9-security-requirements-sec) / [PILA-TBD-004](#pila-tbd-004)).
- **Shared TimelockController (🟢 DF)** — the allocator's `owner`. Registration, weights, and unpause have a 24h delay ([Governance-Roles-Timelock](../policies/Governance-Roles-Timelock.md)).
- **GUARDIAN (🟢 DF)** — emergency pause (immediate) of `distribute()`.

### 3.3 Assumptions

- The allocator treats only JPYdf as legitimate funds. It has no rescue for mistakenly sent tokens (same policy as [IRTR](InterestRouter.md); out of scope per [PILA-TBD-005](#pila-tbd-005)).
- Phase-A **does not assume** a voting token, staking, voting, or bribes. The Phase-B token remains undecided; DFT is used only if separately adopted.
- Uniswap v4 / Merkl assume Ethereum mainnet (Day-1 single chain, `SYS-CON-005`).

---

## 4. Actors, Roles, and Trust Boundaries

| Actor | Operation | Trust boundary |
| --- | --- | --- |
| **InterestRouterForwarder (🟢 upstream)** | Pushes PIL to the allocator via `route()` | Receipt only, no callback |
| **owner** (= shared TimelockController [24h]) | `registerInitiative` / `unregisterInitiative` / `setWeights` / unpause / 2-step ownership | Privileged. Changes to allocation targets / ratios have a 24h delay. Renounce disabled |
| **GUARDIAN** | Pause of `distribute()` (immediate) | Reversible fail-safe only. Has no fund-movement authority |
| **campaign creator** | Early execution of an initiative's `createCampaign()` | Limited trust. Operator of campaign creation timing. No discretion over allocation targets / ratios / poolId |
| **distribute / public fallback caller (anyone)** | `distribute()` / `createCampaign()` within the fallback window | Trustless. No discretion over allocation targets / ratios (only follows registered initiatives and weights) |
| **initiative (`UniV4MerklInitiative`, etc.)** | Receives JPYdf from the allocator -> allocates to DEX | Limited trust. Receipt is up to the weight cap. Validated at registration to be a recipient capable of receiving JPYdf external transfers, and hook failure cannot brick the allocator (`safeCallWithMinGas`) |
| **Merkl `DistributionCreator`** | Pulls the campaign amount from the initiative | Limited trust (new boundary). approve is per-call and limited to the campaign amount ([PILA-SEC-003](#9-security-requirements-sec)) |

- **Intent of role separation**: separate "the authority to change allocation targets / ratios (owner=Timelock, delayed)" from "the operation to distribute funds (distribute=permissionless, no discretion)". Even with an owner-key compromise, there is no immediate fund-stealing route (same shape as `IRTR-SEC-001`).

---

## 5. Interface Specification (terse, non-normative; normative in §6)

### 5.1 PILAllocator

| Function / element | Visibility | Summary | Requirement |
| --- | --- | --- | --- |
| `constructor(IJpydfToken _jpydf, uint256 _epochStart, uint256 _epochDuration, uint256 _minDistribute, address _owner, address _guardian)` | — | immutable setup, zero rejection, fail-fast | PILA-FR-001 |
| `EPOCH_START()` / `EPOCH_DURATION()` / `epoch()` / `epochStart()` | external view | epoch interface compatible with upstream `Governance` | PILA-FR-002 |
| `MAX_INITIATIVES()` | external view | Upper bound on registered initiative count (32) | PILA-FR-003 |
| `registerInitiative(address)` | external (onlyOwner) | Register initiative + `onRegisterInitiative` hook | PILA-FR-003 |
| `unregisterInitiative(address)` | external (onlyOwner) | Unregister + `onUnregisterInitiative` hook, zero out weight | PILA-FR-004 |
| `setWeights(address[],uint256[])` | external (onlyOwner) | Batch weight setting (`Σ = 0` or `1e18`, registered only) | PILA-FR-005 |
| `distribute()` | external (permissionless, nonReentrant) | Prorate held JPYdf by weight, push to each initiative + hook | PILA-FR-006 |
| `pause()` / `unpause()` | external (GUARDIAN / onlyOwner) | Emergency stop / resume of `distribute()` | PILA-FR-008 |
| `setGuardian(address)` | external (onlyOwner) | Replace the GUARDIAN | PILA-FR-008 |
| `transferOwnership` / `acceptOwnership` / `renounceOwnership` | external | 2-step, renounce disabled (same shape as `IRTR-FR-004`) | PILA-FR-010 |
| views (initiatives / weights / pending / epoch) | external view | Monitoring, subgraph | PILA-FR-009 |

### 5.2 IInitiative (fully compatible with upstream `liquity/V2-gov`)

| Function | Caller | Use in Phase-A |
| --- | --- | --- |
| `onRegisterInitiative(uint256 atEpoch)` | allocator | Used (on registration) |
| `onUnregisterInitiative(uint256 atEpoch)` | allocator | Used (on unregistration) |
| `onAfterAllocateLQTY(uint256,address,UserState,Allocation,InitiativeState)` | allocator/voting | **Unused** (no voting). Retained for Phase-B reuse |
| `onClaimForInitiative(uint256 claimEpoch, uint256 amount)` | allocator | Used (post-allocation notification) |

### 5.3 UniV4MerklInitiative

| Function / element | Visibility | Summary | Requirement |
| --- | --- | --- | --- |
| `constructor(...)` | — | immutable setup of allocator metadata / JPYdf / Merkl / poolId / weights / threshold / epoch, `acceptConditions()` | PILA-FR-201 |
| `createCampaign()` | external (creator / fallback window) | Submit held JPYdf to a Merkl Uniswap v4 campaign (approve per call) | PILA-FR-202 |
| `nextCampaignStart()` / `publicCampaignCreationStart()` / `canCreateCampaign(address)` | external view | Next campaign start, public fallback start time, per-caller creatability (accounting for balance and duplicate campaigns) for monitoring / UI assistance | PILA-FR-202 |
| `getCampaignData()` | external view | Generate Merkl campaignData from poolId / weights / blacklist | PILA-FR-203 |
| `onRegister/onUnregister/onAfterAllocateLQTY/onClaimForInitiative` | external | no-op hooks (Merkl integration is separated into `createCampaign`) | PILA-FR-204 |

---

## 6. Functional Requirements (FR)

### 6.1 PILAllocator

### PILA-FR-001: constructor (establish the allocation layer, fail-fast)
- **Type**: Functional | **Source**: §2.2 / `IRTR-TBD-004`
- **Signature**: `constructor(IJpydfToken _jpydf, uint256 _epochStart, uint256 _epochDuration, uint256 _minDistribute, address _owner, address _guardian)`
- **Purpose**: Establish the allocation token (JPYdf), epoch basis, minimum distribution amount, owner, and guardian.
- **Permission**: deploy only.
- **Preconditions (Checks)**: `_jpydf != 0` / `_jpydf.code.length > 0` / `_owner != 0` / `_guardian != 0` (`ZeroAddress`) / `_epochStart <= block.timestamp` / `_epochDuration > 0` / `_minDistribute > 0` / `_epochDuration <= type(uint32).max`.
- **Behavior (Effects)**: store `jpydfToken`, `EPOCH_START`, `EPOCH_DURATION`, `MIN_DISTRIBUTE` immutably, set `owner` and `guardian`, emit initial events. The registry starts empty.
- **Design notes**: initial values come from deploy env; deploy stops if unspecified. The epoch interface uses the same signature as upstream `Governance` because the initiative (`UniV4MerklInitiative`) references it (Phase-B reuse).
- **Verification**: unit.

### PILA-FR-002: epoch interface (upstream-compatible)
- **Type**: Functional | **Source**: §2.2 (Phase-B reuse)
- **Signature**: `EPOCH_START() / EPOCH_DURATION() / epoch() / epochStart()`
- **Purpose**: Provide the epoch basis for an initiative to determine its campaign period (`startTimestamp = epochEnd`). Same signature as upstream `Governance`.
- **Permission**: view, permissionless.
- **Behavior**: `epoch() = (block.timestamp − EPOCH_START)/EPOCH_DURATION + 1`, `epochStart() = EPOCH_START + (epoch()−1)·EPOCH_DURATION` (follows upstream).
- **Design notes**: Phase-A's `distribute()` itself does not epoch-gate (it prorates the current balance at any time). epoch is used by initiatives only to align campaign periods.
- **Verification**: unit.

### PILA-FR-003: registerInitiative (admin registration)
- **Type**: Functional / Governance | **Source**: §2.2 / §2.3
- **Signature**: `registerInitiative(address initiative)`
- **Purpose**: Register an allocation-target initiative.
- **Permission**: `onlyOwner` (shared Timelock = 24h). **Phase-A uses admin registration**. In Phase-B, initiative registration and allowlist changes also remain T1 actions requiring JIP approval; binding voting does not receive registration authority.
- **Preconditions (Checks)**: `initiative != 0` / not already registered (duplicate -> `AlreadyRegistered`) / registered count below `MAX_INITIATIVES` / the address is a valid JPYdf external-transfer recipient under the same validation as `JpydfToken.transfer`'s recipient restriction (at minimum, it is not the JPYdf token itself, `CollateralRegistry`, or a registered `TroveManager` / `StabilityPool` / `BorrowerOperations` / `ActivePool`).
- **Behavior (Effects)**: add to the registry (weight initialized to 0), best-effort call `onRegisterInitiative(epoch())` via `safeCallWithMinGas`, emit `InitiativeRegistered(initiative, epoch, hookSucceeded)`.
- **revert**: non-owner -> `Unauthorized` / duplicate -> `AlreadyRegistered` / zero -> `ZeroAddress` / over the cap -> `TooManyInitiatives`.
- **Design notes**: an initiative may be a contract / Safe / EOA as long as it is a valid JPYdf external-transfer recipient (including the use of registering a Safe as a treasury receiver = §2.2-3). The registration-time validation is a fail-fast to prevent the accident where `safeTransfer` inside `distribute()` reverts on the JPYdf recipient blacklist and stops allocation to all initiatives. The implementation guarantees equivalence via the `JpydfToken.requireValidRecipient` view helper. Hook failure does not stop the registration itself (follows upstream).
- **Verification**: unit.

### PILA-FR-004: unregisterInitiative (admin unregistration)
- **Type**: Functional / Governance | **Source**: §2.2
- **Signature**: `unregisterInitiative(address initiative)`
- **Purpose**: Remove a registered initiative from the allocation set.
- **Permission**: `onlyOwner` (Timelock).
- **Preconditions (Checks)**: the target initiative is registered and `weightOf[initiative] == 0`. To unregister a weighted initiative, first reallocate `1e18` to the remaining initiatives / a reserve initiative via `setWeights`.
- **Behavior (Effects)**: logically delete from the registry, call `onUnregisterInitiative(epoch())` via `safeCallWithMinGas`, emit `InitiativeUnregistered(initiative, epoch, hookSucceeded)`.
- **Design notes**: the unregistration operation must not create `0 < Σweight < 1e18`. To stop allocation, set all weights to 0.
- **Verification**: unit.

### PILA-FR-005: setWeights (admin allocation ratios)
- **Type**: Functional / Governance | **Source**: §2.2 / §2.3
- **Signature**: `setWeights(address[] initiatives, uint256[] weights)`
- **Purpose**: Batch-set the allocation ratio per initiative (1e18 fixed-point).
- **Permission**: `onlyOwner` (Timelock).
- **Preconditions (Checks)**: matching array lengths / all elements are registered initiatives / no duplicates / the post-update `Σweight` is **0 or `1e18`** (otherwise `InvalidTotalWeight`).
- **Behavior (Effects)**: update each initiative's weight, emit `WeightsUpdated`.
- **Design notes**: when active, make the destination of the full amount explicit. For the portion to be routed to treasury / reserve, register that Safe as an initiative and give it weight (same shape as the upstream grants Safe). There is **no separate treasury sink** ([PILA-INV-002](#8-invariants-inv)).
- **Verification**: unit, invariant=PILA-INV-002.

### PILA-FR-006: distribute (weighted PIL allocation, permissionless)
- **Type**: Functional | **Source**: §2.2 / upstream `Governance.claimForInitiative`
- **Signature**: `distribute() returns (uint256 total)`
- **Purpose**: Push the JPYdf held by the allocator to registered initiatives by weighted proration.
- **Permission**: permissionless (anyone; keeper optional). Not allowed while paused.
- **Preconditions (Checks)**: not paused. If `bal = balanceOf(this)` is below the threshold `minDistribute`, no-op (carry-over).
- **Behavior (Effects)**:
  1. `bal = jpydfToken.balanceOf(address(this))`; `bal < minDistribute` or 0 registered initiatives -> `return 0` (retain).
  2. For each registered initiative `i` (up to `MAX_INITIATIVES=32`): `amount_i = bal × weight_i / 1e18`. If `amount_i > 0`, `jpydfToken.safeTransfer(initiative_i, amount_i)` -> `safeCallWithMinGas(onClaimForInitiative(epoch(), amount_i))` -> emit `Distributed(initiative_i, amount_i, epoch(), hookSucceeded)`.
  3. Because the active weight total is `1e18`, no unallocated residual is created beyond rounding dust. All weights 0 / below threshold remain retained at the allocator.
- **revert / early return**: paused -> `Paused`; below threshold / 0 registered -> `return 0`.
- **Design notes**: reproduces upstream's "recycle unclaimed amounts" in the admin version. Hooks are called after the transfer (funds have already landed at the initiative, and even on hook failure they can be processed later via `createCampaign`). The hook failure of one initiative does not stop the others (`safeCallWithMinGas`, [PILA-INV-003](#8-invariants-inv)). CEI + `nonReentrant` ([PILA-SEC-005](#9-security-requirements-sec)).
- **Verification**: unit, invariant=PILA-INV-001/002/003, integration (Forwarder.route->distribute->initiative->Merkl).

### PILA-FR-007: threshold / carry-over (consolidation of retention)
- **Type**: Functional | **Source**: §2.2-3 / upstream `CurveV2GaugeRewards.remainder`
- **Purpose**: Avoid waste from small allocations (gas, Merkl fees) and carry PIL below the threshold or while inactive forward to the next time. No double definition with a treasury sink.
- **Requirements**:
  - `distribute()` is a no-op when `bal < minDistribute` ([PILA-FR-006](#pila-fr-006-distribute-weighted-pil-allocation-permissionless)). The residual stays retained at the allocator = re-evaluated next time.
  - `0 < Σweight < 1e18` is forbidden. To stop allocation, `Σweight = 0`; for active allocation, `Σweight = 1e18`.
  - **activation-agnostic**: with 0 initiatives / all weights 0, all PIL stays retained at the allocator, equivalent to the current `IRTR` "Day-1 = recipient retention" ([PILA-INV-004](#8-invariants-inv)).
- **Design notes**: the value of `minDistribute` is in [Parameters](../../../Parameters.md) ([PILA-TBD-002](#pila-tbd-002)). Upstream `Governance.MIN_ACCRUAL` is `1000e18` and carries over below-threshold amounts instead of making them epoch funds. In the same shape, PILAllocator does not allocate below-threshold amounts and retains them.
- **Verification**: unit, invariant=PILA-INV-004.

### PILA-FR-008: pause / unpause / setGuardian (emergency stop)
- **Type**: Functional / Governance | **Source**: §2.2-7
- **Permission**: `pause()` = GUARDIAN (immediate) / `unpause()`, `setGuardian(address)` = `onlyOwner` (Timelock 24h).
- **Behavior**: while paused, `distribute()` is disallowed (PIL receipt = landing from the Forwarder continues). `setGuardian` replaces the emergency-stop holder. Emit `Paused`/`Unpaused`/`GuardianUpdated`.
- **Design notes**: separate the reversible fail-safe (to GUARDIAN) from the resume (to Timelock) (consistent with `SYS-NFR-002` exception operations).
- **Verification**: unit.

### PILA-FR-009: View Functions
- `MAX_INITIATIVES()` / `initiatives()` / `initiativeCount()` / `initiativeAt(uint256)` / `registeredInitiatives(address)` / `weightOf(address)` / `pendingDistributable()` (expected next distribute) / epoch views. For monitoring, subgraph, and operational console.
- **Verification**: unit.

### PILA-FR-010: ownership (2-step, renounce disabled)
- **Type**: Governance / Security | **Source**: `IRTR-FR-004` (same shape)
- **Requirements**: `transferOwnership` (onlyOwner, `0` cancels pending) / `acceptOwnership` (onlyPendingOwner) / `renounceOwnership` always reverts (`RenounceOwnershipDisabled`). Handover transfers to the shared Timelock.
- **Design notes**: prevent permanent strand of allocation capability due to an absent owner (same policy as `IRTR-FR-004`).
- **Verification**: unit.

### 6.2 IInitiative

### PILA-FR-101: IInitiative (fully upstream-compatible, 4 hooks)
- **Type**: Functional | **Source**: upstream `liquity/V2-gov:src/interfaces/IInitiative.sol`
- **Purpose**: Define 4 hooks fully compatible with upstream `IInitiative` so that both the Phase-A `PILAllocator` and the Phase-B `VotingAllocator` **can call the same initiatives**.
- **Requirements**: `onRegisterInitiative(uint256)` / `onUnregisterInitiative(uint256)` / `onAfterAllocateLQTY(uint256,address,UserState,Allocation,InitiativeState)` / `onClaimForInitiative(uint256,uint256)`. Whether to restrict the caller is defined per initiative implementation. `UniV4MerklInitiative` has no caller restriction because its hooks are no-ops.
- **Verification**: unit / static (signature match with the upstream interface).

### PILA-FR-102: Retain onAfterAllocateLQTY (unused in Phase-A)
- **Type**: Functional | **Source**: §3.1 (Terms)
- **Purpose**: `onAfterAllocateLQTY` is the notification hook by which upstream "records per-user/total vote amounts to the initiative each time a user changes their voting allocation" (the basis for bribe proration, etc.). **Because Phase-A has no voting, `PILAllocator` does not call it**, but it is retained in the interface so the Phase-B `VotingAllocator` can call it as-is, and Phase-A initiatives implement it as a no-op.
- **Design notes**: this lets the initiative written in Phase-A (`UniV4MerklInitiative`) be reused unmodified in Phase-B (§2.2-1).
- **Verification**: static (interface compatibility).

### 6.3 UniV4MerklInitiative

### PILA-FR-201: constructor (establish Merkl integration)
- **Type**: Functional | **Source**: upstream `UniV4MerklRewards`
- **Purpose**: Fix the allocation token (JPYdf), target Uniswap v4 pool, allocation weights, and threshold immutably, and enable the use of Merkl.
- **Preconditions (Checks)**: `_allocator != 0` / `_jpydfToken != 0 && code.length > 0` / `_merklDistributionCreator != 0 && code.length > 0` / `_campaignCreator != 0` / `_campaignJpydfAmountThreshold > 0` / `0 < _campaignCreationWindow < _epochDuration` / `_uniV4PoolId != 0` / `_epochStart <= block.timestamp` / `_epochDuration > 0` / `_epochDuration <= type(uint32).max` / `WEIGHT_FEES + WEIGHT_TOKEN0 + WEIGHT_TOKEN1 == 10000` (follows upstream).
- **Behavior (Effects)**: store immutably `allocator` (metadata), `jpydfToken`, `merklDistributionCreator`, `CAMPAIGN_CREATOR`, `CAMPAIGN_CREATION_WINDOW`, `UNIV4_POOL_ID`, each weight, `CAMPAIGN_JPYDF_AMOUNT_THRESHOLD`, `EPOCH_START`/`EPOCH_DURATION`. Execute Merkl `DistributionCreator.acceptConditions()` (the premise for signature-less campaign creation). **Do not max-approve JPYdf** (approve per call = [PILA-SEC-003](#9-security-requirements-sec)).
- **Design notes**: 1 instance = 1 pool (poolId immutable). For multiple pools, deploy and register multiple instances (§10 extension).
- **Verification**: unit / fork (Merkl).

### PILA-FR-202: createCampaign (create Merkl Uniswap v4 campaign, creator / fallback)
- **Type**: Functional | **Source**: upstream `UniV4MerklRewards.claimForInitiative`
- **Signature**: `createCampaign()`
- **Purpose**: Submit the JPYdf held by the initiative to a Merkl campaign for the LPs of the target Uniswap v4 pool.
- **Permission**: `CAMPAIGN_CREATOR` can execute at any time. A general caller can execute only when `block.timestamp >= campaignStart - CAMPAIGN_CREATION_WINDOW`. `nonReentrant`.
- **Preconditions (Checks)**: `amount = jpydfToken.balanceOf(this) ≥ CAMPAIGN_JPYDF_AMOUNT_THRESHOLD` (below it -> no-op / `return`).
- **Behavior (Effects)**:
  1. Determine `amount`.
  2. Compute `campaignStart = EPOCH_START + epoch() * EPOCH_DURATION`; if `campaignIdByStartTimestamp[campaignStart] != 0`, emit `MerklCampaignAlreadyCreated` and no-op (balance carry-over).
  3. If the caller is not the `CAMPAIGN_CREATOR` and is before the public fallback window, revert.
  4. **approve per call**: `jpydfToken.forceApprove(merkl, amount)` (no max approve = [PILA-SEC-003](#9-security-requirements-sec)).
  5. `merkl.createCampaign({rewardToken: JPYdf, amount, campaignType: 13 (UNISWAP_V4), startTimestamp: campaignStart, duration: EPOCH_DURATION, campaignData: getCampaignData()})`.
  6. Store `campaignIdByStartTimestamp[campaignStart] = campaignId`.
  7. Restore allowance with `jpydfToken.forceApprove(merkl, 0)`.
  8. Emit `NewMerklCampaign(epoch, amount, campaignId)`.
- **view helpers**: `nextCampaignStart()` is the next campaign's start, `publicCampaignCreationStart()` is when a general caller becomes able to create, and `canCreateCampaign(address caller)` returns true when the balance is at or above the threshold, no campaign for the same start exists, and the caller is the creator or within the fallback window.
- **revert / early return**: below threshold -> no-op (carry-over). A campaign for the same `campaignStart` already created -> no-op (carry-over). General caller before the fallback window -> `CampaignCreationTooEarly`. Merkl returns `campaignId == 0` -> `ZeroCampaignId`.
- **Design notes**: Merkl integration is separated from `distribute()`'s hook (`onClaimForInitiative`) to avoid gas bloat of the allocation loop (follows upstream). Because Merkl's campaign id is determined by creator / reward token / campaign type / start / duration / campaignData and does not include the amount, there is **one campaign per `campaignStart`**. To avoid the grief of an overly early public call consuming the start with a small campaign, normally the keeper/Safe `CAMPAIGN_CREATOR` creates after the planned `route()` / `distribute()`, and a general caller is limited to the late-epoch fallback window. If additional balance enters within the same epoch after a campaign is created, that balance is carried over in the initiative until the next `campaignStart`. Confirm the actual amount Merkl pulls (whether fees are included) and match the approve amount ([PILA-TBD-004/005](#14-open-issues-tbd)).
- **Verification**: unit / fork (Merkl `DistributionCreator`).

### PILA-FR-203: getCampaignData (encode poolId / weight / blacklist)
- **Type**: Functional | **Source**: upstream `UniV4MerklRewards.getCampaignData`
- **Purpose**: Generate the `campaignData` of the Merkl Uniswap v4 campaign (target `UNIV4_POOL_ID`, fee/token0/token1 weights, `IS_OUT_OF_RANGE_INCENTIVIZED=false`, blacklist).
- **Requirements**: keep the blacklist as a standard field of Merkl campaignData and make it **empty on Day-1 (no targets)**. Out-of-range liquidity is excluded (`IS_OUT_OF_RANGE_INCENTIVIZED=false`, follows upstream). If a blacklist becomes necessary in the future (wash-trading that unfairly absorbs incentives, regulatory compliance, etc.), **make immutable-empty the default and handle it with a new instance** (making it settable increases a governance surface of "authority to strip a specific address of rewards" and requires consideration = [PILA-TBD-003](#pila-tbd-003)).
- **Verification**: unit / fork.

### PILA-FR-204: initiative hooks (lightweight no-op)
- **Type**: Functional | **Source**: upstream `UniV4MerklRewards`
- **Requirements**: the 4 hooks of `UniV4MerklInitiative` are no-ops. `onClaimForInitiative` is only a receipt notification (Merkl integration is separated into `createCampaign`). `onAfterAllocateLQTY` is a no-op ([PILA-FR-102](#pila-fr-102-retain-onafterallocatelqty-unused-in-phase-a)). So that the same initiative can be reused in Phase-B, the no-op hooks have no single-allocator-fixed caller restriction. A future initiative with state-updating hooks defines the necessary caller restriction on its own side.
- **Verification**: unit.

---

## 7. State Variables and Accounting Model

| Variable | Type | Description |
| --- | --- | --- |
| `jpydfToken` | `IERC20 immutable` | The allocation token (JPYdf) |
| `EPOCH_START` / `EPOCH_DURATION` | `uint256 immutable` | epoch basis (compatible with upstream `Governance`) |
| `owner` / `pendingOwner` | `address` | Authority to change allocation targets / ratios / guardian (= Timelock after handover). 2-step, renounce disabled |
| `guardian` | `address` | Immediate executor of `pause()` |
| `initiatives` | `address[]` / registry | Enumeration of registered initiatives |
| `weightOf` | `mapping(address=>uint256)` | The allocation ratio per initiative (1e18) |
| `paused` | `bool` | Emergency stop of `distribute()` |
| `MAX_INITIATIVES` | `uint256 constant` | Upper bound on registered initiative count (32). Keeps the loop gas of permissionless `distribute()` bounded |
| `CAMPAIGN_CREATOR` | `address immutable` | The early-campaign-creation keeper / Safe of `UniV4MerklInitiative` |
| `CAMPAIGN_CREATION_WINDOW` | `uint256 immutable` | The window immediately before `campaignStart` that opens campaign creation to general callers |
| `campaignIdByStartTimestamp` | `mapping(uint256=>bytes32)` | Prevents duplicate Merkl campaign creation by `UniV4MerklInitiative`. One campaign per start timestamp |

**Accounting model**: the allocator holds no budget or claim state; it only prorates the balance held at the time of `distribute()` (`balanceOf(this)`) by weight. The active weight is `Σweight = 1e18`; when allocation is stopped, `Σweight = 0` and the full amount is retained. Below-threshold amounts are **carried over as the held balance**. Branch-level PIL breakdown is aggregated like the Forwarder (off-chain reconstruction, `IRTR` §2.3).

---

## 8. Invariants (INV)

| ID | Invariant | Verification |
| --- | --- | --- |
| PILA-INV-001 | The outflow destination of `distribute()` is **registered initiatives only**. Even the owner cannot send to an arbitrary address (there is no function that takes a destination as an argument). Registered initiatives are limited to valid JPYdf external-transfer recipients | unit / invariant / manual |
| PILA-INV-002 | `Σweight` is 0 or `1e18`. The reserve / Treasury share is also made explicit as an initiative, with no unallocated weight from a partial total (**no additional outflow destination such as a treasury sink**) | unit / invariant |
| PILA-INV-003 | A hook revert/OOG of any initiative does not impede allocation to other initiatives (`safeCallWithMinGas` isolation). Hook success/failure is observable via events | unit / fuzz |
| PILA-INV-004 | With 0 initiatives / all weights 0, all PIL stays retained at the allocator (equivalent to the current `IRTR` Day-1 "retention" = activation-agnostic) | unit / integration |
| PILA-INV-005 | No state-changing calls to 🔵 Core / `JpydfToken` / `InterestRouterForwarder` (receipt only; Core diffs are under the jurisdiction of Core spec `CORE-MOD-*`) | manual / static |
| PILA-INV-006 | Registration, unregistration, weights, and unpause can be executed only through the shared Timelock (24h) (the only immediate action is GUARDIAN's pause) | unit / manual |
| PILA-INV-007 | `IInitiative` matches the signatures of upstream `liquity/V2-gov` exactly (the same initiatives can be reused unmodified in Phase-B) | static / diff check |
| PILA-INV-008 | The number of registered initiatives is `MAX_INITIATIVES=32` or fewer. The loop of `distribute()` does not become unbounded via an admin proposal | unit / manual |

---

## 9. Security Requirements (SEC)

### PILA-SEC-001: Trust boundary of the Merkl dependency
- **Statement**: `UniV4MerklInitiative` hands rewards (JPYdf) to Merkl `DistributionCreator` and delegates distribution calculation and claims. This is a **new trust boundary** that depends on Merkl's off-chain calculation, claim infrastructure, fees, and terms, accepted on a premise equivalent to upstream Liquity. Mitigations: immutable campaign parameters, threshold, blacklist (empty on Day-1, only when needed later), and **limiting the pull cap via per-call approve** (PILA-SEC-003).
- **Residual risk**: on a Merkl outage, the campaign is not created and JPYdf stays retained at the initiative (retried next epoch). Damage from a Merkl compromise is limited to "the approve amount of that campaign".
- **Verification**: fork / manual.

### PILA-SEC-002: Damage boundary of admin-key compromise
- **Statement**: the owner (Timelock) can only execute registration, unregistration, weights, unpause, and role operations that carry no fund path (`setGuardian` / 2-step ownership), with no route to immediately steal funds. A malicious weight/registration change has a 24h delay, during which it can be detected and responded to (same shape as `IRTR-SEC-001`). `distribute()` is permissionless, but the caller has no discretion over allocation targets / ratios.
- **Verification**: unit / manual.

### PILA-SEC-003: Merkl approve is per-call and limited to the campaign amount (hardening vs upstream)
- **Statement**: upstream `UniV4MerklRewards` does a `max approve` to Merkl, but this implementation does **`forceApprove(merkl, amount)` per `createCampaign`**, limiting the amount Merkl can pull at any time to that campaign amount. This closes the route by which an entire initiative balance could be drained on a Merkl-side bug/compromise.
- **Impact assessment (side effects of per-call approve)**: (a) no functional impact (approve->createCampaign in the same tx). (b) gas: one extra approve per epoch (≈ one SSTORE). Negligible. (c) `forceApprove` (SafeERC20) avoids allowance races for non-standard ERC-20 (no actual harm because JPYdf is standard). (d) **To confirm**: match approve to the actual amount Merkl's `createCampaign` pulls (whether it is the campaign `amount` or `amount + fee`) ([PILA-TBD-004/005](#14-open-issues-tbd)).
- **Verification**: unit / fork.

### PILA-SEC-004: initiative isolation
- **Statement**: a malicious/faulty initiative can only obtain received JPYdf up to the weight cap, and `safeCallWithMinGas` ensures it cannot brick the allocator or other initiatives ([PILA-INV-003](#8-invariants-inv)).
- **Verification**: unit / fuzz.

### PILA-SEC-005: reentrancy / CEI
- **Statement**: `distribute()` is `nonReentrant`, in the order of accounting (balance read) -> external calls (transfer + hook). It relies on JPYdf being a standard ERC-20 without transfer hooks (§3.2). `createCampaign` is also `nonReentrant`, closing the route by which re-entry during the active allowance window of the Merkl `createCampaign` call could create a double campaign.
- **Verification**: unit / manual.

### PILA-SEC-006: permissionless invocation and campaign front-running prevention
- **Statement**: `distribute()` can be called by anyone, but the caller has no discretion over allocation targets (registered initiatives) / ratios (weights). `createCampaign()` prioritizes `CAMPAIGN_CREATOR`, a general caller is limited to within `CAMPAIGN_CREATION_WINDOW`, and the caller has no discretion over the destination pool (immutable poolId), amount (initiative balance), or start/duration. Below the balance/threshold, no-op.
- **Operational note**: a Merkl campaign can be created only once per identical `campaignStart`. Front-running grief via small campaigns is suppressed by the fallback window restriction, and on keeper failure liveness is ensured by a public call within the window. If additional JPYdf enters the same start after a campaign is created, it is not a loss of funds but is carried over to the next `campaignStart`, so monitor `MerklCampaignAlreadyCreated` and the initiative balance.
- **Verification**: unit.

---

## 10. Governance, Operations, and Upgrade Requirements (GOV)

### PILA-GOV-001: Role structure and handover
- The initial `owner` is `DF_PILA_OWNER` (on mainnet, a contract such as a Safe/Timelock is required). Day-1 handover transfers ownership 2-step to the shared TimelockController (24h; the same as dToken/Vault/Strategy/`IRTR`) ([Governance-Roles-Timelock](../policies/Governance-Roles-Timelock.md)). The GUARDIAN is `DF_PILA_GUARDIAN` (a contract required on mainnet) with pause only. The cross-cutting authority reference is [Governance](../../../Governance.md).

### PILA-GOV-002: Upstream connection (Forwarder recipient)
- When going live, the owner (Timelock) executes `InterestRouterForwarder.setRecipient(PILAllocator)` (`IRTR-FR-003` / `IRTR-GOV-003`). This makes this layer the concrete instance of what `IRTR-TBD-004` calls the "Day-2 PIL allocation mechanism". The Day-1 default does not make this connection; the initial `recipient` is a PIL-dedicated holding Safe/address. Even if the PIL stack is deployed on the same day, the `pil-activation-manifest.json` produced by `DeployPILAllocatorPhaseA` is deploy-ready evidence, not approval for `setRecipient(PILAllocator)` or `DF_INTEREST_ROUTER_RECIPIENT=PILAllocator`. Active routing is proposed / executed by Timelock/Safe only after a separately approved activation package with the Merkl official address, poolId, weights, campaign params, fork simulation, and Timelock bundle.

### PILA-GOV-003: Phase-A activation and activation-agnostic property
- Even after contract deploy and recipient connection, **no allocation occurs until admin registers initiatives and sets weights** (all PIL stays retained at the allocator = [PILA-INV-004](#8-invariants-inv)). `DeployPILAllocatorPhaseA` deploys `PILAllocator` and `UniV4MerklInitiative` and outputs `pil-activation-manifest.json`, but initiative registration, weight setting, and the Forwarder recipient change remain as explicit Safe/Timelock actions. The standard Day-1 launch mode stops at deploy-ready / evidence-ready; PILAllocator active routing requires explicit approval through a later activation gate ([PILA-TBD-006](#pila-tbd-006)).

### PILA-GOV-004: Phase-A -> Phase-B (voting allocation) migration
- Phase-B **newly deploys** a voting-token-independent `VotingAllocator` and swaps it in with `forwarder.setRecipient(VotingAllocator)` (redeploy, Core unmodified). The voting token is undecided; DFT is used only if separately adopted. Time-weighted voting may change only the weight among allowlisted initiatives within one epoch's fixed PIL budget. It cannot change budget size, transfer asset, initiative registration/allowlist, or any external-governance T1 role. Initiative registration and allowlist changes require JIP approval. Sweep the old allocator with a final `distribute()` before switching, and **reuse the same `IInitiative` implementations unmodified** ([PILA-INV-007](#8-invariants-inv)). Phase-B remains a separate specification and audit.

### PILA-GOV-005: Extension boundary (adding initiatives, Curve out of scope)
- **Adding another pool of the same DEX type** (e.g. another pair in addition to Uni v4 JPYdf/USDC): deploy a new `UniV4MerklInitiative` instance (different poolId) -> `registerInitiative` -> `setWeights`. The allocator / existing initiatives / Core are unmodified.
- **Adding another DEX (Curve, etc.)**: deploy a new initiative satisfying `IInitiative` (e.g. `CurveGaugeInitiative` = `gauge.deposit_reward_token` compliant with upstream `CurveV2GaugeRewards`) -> register. **Curve-type initiatives are Day-2, out of Phase-A audit scope** (stated explicitly in [Contract-Audit-Scope-And-nSLOC](../../../engineering/guides/Contract-Audit-Scope-And-nSLOC.md)).
- In all cases, because the allocator touches initiatives only through the initiative abstraction (`IInitiative`), they can be added without touching the Day-1 audited contracts (§2.2-2, ARCH-004).

### PILA-GOV-006: Upgrade policy
- `PILAllocator` and each initiative are **non-UUPS (immutable)**. Behavior changes are handled by deploying a new contract + swapping with `forwarder.setRecipient` (same policy as `IRTR-GOV-004`, audit simplicity).

---

## 11. Events and Monitoring Requirements (EVT)

| ID | Event (indexed) | Off-chain use |
| --- | --- | --- |
| PILA-EVT-001 | `InitiativeRegistered(address indexed initiative, uint256 atEpoch, bool hookSucceeded)` | Track addition of allocation targets, detect registration hook failure |
| PILA-EVT-002 | `InitiativeUnregistered(address indexed initiative, uint256 atEpoch, bool hookSucceeded)` | Track removal of allocation targets, detect unregistration hook failure |
| PILA-EVT-003 | `WeightsUpdated(address[] initiatives, uint256[] weights)` | Track allocation ratio changes (immediate alert together with Timelock proposal/execution) |
| PILA-EVT-004 | `Distributed(address indexed initiative, uint256 amount, uint256 indexed epoch, bool hookSucceeded)` | Monitor allocation results, retention amount, and claim hook failure |
| PILA-EVT-005 | `NewMerklCampaign(uint256 indexed epoch, uint256 amount, bytes32 campaignId)` / `MerklCampaignAlreadyCreated(uint256 indexed epoch, uint256 indexed startTimestamp, uint256 amount, bytes32 campaignId)` | Track Uniswap v4 campaign creation and same-start carry-over |
| PILA-EVT-006 | `Paused()` / `Unpaused()` | Monitor emergency stops |
| PILA-EVT-007 | `GuardianUpdated(address indexed oldGuardian, address indexed newGuardian)` | Track changes of the emergency-stop holder |

- Monitoring metrics: allocator held balance (retention amount), registered initiative count (`MAX_INITIATIVES` or fewer), the weight total of each initiative (expected 0 or `1e18`), per-epoch results of `Distributed`, hookSucceeded=false events, success of `NewMerklCampaign`, the initiative balance carry-over after `MerklCampaignAlreadyCreated`, immediate alerts on `WeightsUpdated`/`InitiativeRegistered`, and on-chain reflection of Merkl campaigns.

---

## 12. Failure and Exceptional Behavior (ERR)

| Event | Behavior |
| --- | --- |
| `distribute()` with 0 initiatives / all weights 0 | `return 0` (all PIL stays retained at the allocator = the normal case before/without activation, [PILA-INV-004](#8-invariants-inv)) |
| Held balance below `minDistribute` | no-op (carry-over). Safe for anyone to call |
| When an invalid JPYdf recipient is about to be registered as an initiative | `registerInitiative` / governance preflight fail-fasts. It does not create a state where `safeTransfer` to a registered initiative reverts on the recipient blacklist and stops the entire allocation |
| Additional registration when the registered initiative count has reached the cap | fail-fast with `TooManyInitiatives`. Either organize the allocation targets or extend with a new allocator deploy + recipient swap |
| `onClaimForInitiative` of some initiative reverts/OOG | Isolated by `safeCallWithMinGas`. The funds have already landed at that initiative and can be processed later via `createCampaign`, etc. Allocation to other initiatives continues ([PILA-INV-003](#8-invariants-inv)) |
| A Merkl campaign for the same `campaignStart` already created | Does not create an additional campaign, no-op. The initiative balance is carried over to the next `campaignStart` |
| Merkl `createCampaign` not created due to below-threshold/outage | JPYdf stays retained at the initiative -> retried next epoch (no loss of funds) |
| Malicious weight/registration from owner-key compromise | Detected and responded to via immediate `WeightsUpdated`/`InitiativeRegistered` alerts during the 24h Timelock delay ([PILA-SEC-002](#9-security-requirements-sec)) |
| Merkl compromise/bug | Damage is limited to the approve amount of that campaign (per-call approve, [PILA-SEC-003](#9-security-requirements-sec)). The GUARDIAN can stop allocation with `pause()` |
| Mistaken send of non-JPYdf | No rescue (retained). `distribute()` targets only JPYdf (same policy as `IRTR`) |

---

## 13. Acceptance Criteria and Verification Plan

| ID | Requirement (summary) | Verification |
| --- | --- | --- |
| PILA-FR-001/002 | constructor, epoch interface (upstream-compatible) | unit |
| PILA-FR-003/004/005 | registration, unregistration, weights (owner-only, JPYdf recipient validation, Σ=0 or 1e18, weighted unregister forbidden) | unit, invariant=PILA-INV-001/002 |
| PILA-FR-006/007 | distribute (weighted proration, threshold, carry-over, hook isolation, permissionless) | unit, fuzz, invariant=PILA-INV-001/003/004, integration |
| PILA-FR-008/010 | pause (GUARDIAN/Timelock), 2-step, renounce disabled | unit |
| PILA-FR-101/102 | IInitiative upstream-compatible, onAfterAllocateLQTY retention | static (interface diff), unit |
| PILA-FR-201..204 | Merkl Uniswap v4 campaign (per-call approve, blacklist, epoch alignment) | unit, fork (Merkl `DistributionCreator`) |
| PILA-INV-001..008 | §8 invariants | unit / fuzz / invariant / static / manual |
| PILA-SEC-001..006 | §9 security requirements | unit / fork / manual |
| Upstream connection | `forwarder.setRecipient(PILAllocator)`->route->distribute->Merkl end-to-end | integration |
| Activation-agnostic | PIL retention when inactive = equivalent to `IRTR` Day-1 | integration |

> Core-side verification (PIL residual mint, SP/PIL distribution) and Forwarder verification are under the jurisdiction of 🔵 [Liquity-v2-Core-Spec](Liquity-v2-Core-Spec.md) (`CORE-AP-FR-007`) / [InterestRouter](InterestRouter.md) (`IRTR-*`). This document verifies only the allocation layer and downstream.

---

## 14. Open Issues (TBD)

### PILA-TBD-001
**Target Uniswap v4 pool** — Day-1 (Phase-A) assumes one `JPYdf/USDC` v4 pool ("direct non-USDC JPYdf pools are out of scope" = consistent with [Product-Overview](../Product-Overview.md) §12.1). The need for multiple pairs is undetermined. The finalized poolId is in [Parameters](../../../Parameters.md). **The extension premise is fixed** (multiple pools = multiple `UniV4MerklInitiative` instances = [PILA-GOV-005](#10-governance-operations-and-upgrade-requirements-gov)).

### PILA-TBD-002
**Allocation parameters** — `EPOCH_DURATION` (default candidate 7 days) / `minDistribute` (allocator threshold) / `CAMPAIGN_JPYDF_AMOUNT_THRESHOLD` (Merkl minimum) / Merkl allocation weights (`WEIGHT_FEES`/`WEIGHT_TOKEN0`/`WEIGHT_TOKEN1`, Σ=10000). The canonical source is [Parameters](../../../Parameters.md) §2-F. Freeze before mainnet activation.

### PILA-TBD-003
**Blacklist method (empty on Day-1, no targets)** — the Day-1 blacklist is empty. Decide the method for when exclusion becomes necessary in the future, for wash-trading addresses that unfairly absorb incentives or for regulatory compliance: **(a) immutable-empty (default, replaced with a new instance, audit-simple)** / (b) settable (settable in-place via Timelock, etc., but increases the governance surface of "authority to strip a specific address of rewards").

### PILA-TBD-004
**Finalizing the Merkl dependency** — canonicalize the Merkl `DistributionCreator` (Angle, mainnet) address, accept `acceptConditions()` / terms of use / KYC, and confirm the fee model (whether the actual amount `createCampaign` pulls is the campaign `amount` or `amount+fee`). The policy is "accept on a basis equivalent to upstream Liquity" (confirmed with the user). The finalized address is in [Parameters](../../../Parameters.md).

### PILA-TBD-005
**Final determination of the approve range** — this document's default is **per-call approve (limited to the campaign amount)** ([PILA-SEC-003](#9-security-requirements-sec), hardening from the upstream max approve). Reflect the Merkl pull-amount confirmation of PILA-TBD-004 to finalize the `forceApprove` amount.

### PILA-TBD-006
Resolved: reflected in `PILA-GOV-003`.

### PILA-TBD-007
Resolved: reflected in `PILA-FR-001` and the [requirement ID convention](../../../README.md#requirements-spec-standard).

### PILA-TBD-008
Resolved: the indexes, active spec lists, and `PILA` prefix registration in `documents/README.md` / `documents/jp/README.md` / `documents/en/README.md` are reflected. [Product-Overview](../Product-Overview.md) / [Governance](../../../Governance.md) / [Parameters](../../../Parameters.md) / [InterestRouter](InterestRouter.md) / [Contract-Audit-Scope-And-nSLOC](../../../engineering/guides/Contract-Audit-Scope-And-nSLOC.md) reflect the Phase-A implementation and the pre-activation freeze items. PIL's DEX allocation is now independent as [Product-Overview](../Product-Overview.md) `SYS-FR-009`.

---

## 15. References

- [InterestRouter](InterestRouter.md) — `IRTR-FR-002` (route) / `IRTR-FR-003` (setRecipient) / `IRTR-GOV-003` (Day-1->Day-2 delivery migration) / `IRTR-TBD-004` (connection with the Day-2 allocation mechanism) = the upstream of this document
- 🔵 [Liquity-v2-Core-Spec](Liquity-v2-Core-Spec.md) — `CORE-AP-FR-007` (PIL residual mint)
- [Treasury](../../roadmap/spec/Treasury.md) — collateral yield (a separate path from PIL)
- [Governance-Roles-Timelock](../policies/Governance-Roles-Timelock.md) — shared Timelock, handover
- [Day1-Self-BS-Initial-Liquidity-Plan](../../../contributors/deltaforesight/commitments/Day1-Self-BS-Initial-Liquidity-Plan.md) — operator self-B/S seed liquidity (out of scope of this document)
- [Contract-Audit-Scope-And-nSLOC](../../../engineering/guides/Contract-Audit-Scope-And-nSLOC.md) — audit scope (Phase-A addition, Curve out of scope)
- [Parameters](../../../Parameters.md) — canonical source for finalized values of pool id / weight / threshold / Merkl / blacklist
- [Product-Overview](../Product-Overview.md) — PIL system requirement
- [Architecture Decision Records](../architecture/Architecture-Decision-Records.md) — ADR-004/005
- [Mainnet Launch Risk Gate](../../launch/gates/Mainnet-Launch-Risk-Gate.md#sys-risk-003) — launch gate for additional SP rewards
- **Reference study (external implementations)**: [2026-06-25 PIL->DEX allocation comparison (Liquity v2 / Nerite / Asymmetry)](../../../engineering/historical-reviews/2026-06-25-PIL-DEX-Allocation-Reference-Liquity-Nerite-Asymmetry.md) — comparison of upstream `liquity/V2-gov` (`Governance` / `IInitiative` / `UniV4MerklRewards` / `CurveV2GaugeRewards` / `BribeInitiative`) with Nerite and Asymmetry implementations. The basis of this design
