# InterestRouter (InterestRouterForwarder) Requirements

## 0. Metadata

| Item | Value |
| --- | --- |
| Status | Draft (implementation exists; requirements being made canonical) |
| Owner | DeltaForesight |
| Target contract | `contracts/src/InterestRouterForwarder.sol` (Original, non-UUPS, minimal immutable contract. It does not inherit `IInterestRouter`; it is bound as an address in ActivePool's `interestRouter`) |
| Related documents | [Liquity-v2-Core-Spec](Liquity-v2-Core-Spec.md) (`CORE-AP-FR-003/007` aggregate-interest SP/PIL 75/25 split, `CORE-AP-FR-001/015` immutable `interestRouter`, `CORE-AP-TBD-001` receiver-binding decision, and `SP_YIELD_SPLIT` constants table) / [Product-Overview](../Product-Overview.md) (PIL = borrowing-interest liquidity incentive) / [Architecture Decision Records](../architecture/Architecture-Decision-Records.md#adr-005) / [Treasury](../../roadmap/spec/Treasury.md) (collateral yield is a separate path; PIL is not a Treasury responsibility) / [Governance-Roles-Timelock](../policies/Governance-Roles-Timelock.md) (shared Timelock and handover) |

> This document follows the [Requirements Spec Standard](../../../README.md#requirements-spec-standard). Requirement IDs use `IRTR-*`.
> **No-core-modification principle**: aggregate-interest SP/PIL distribution, minting to `interestRouter`, and immutable binding are Core normative behavior (`CORE-AP-*`). This document does not respecify them; it only references their IDs. This document specifies the Original `InterestRouterForwarder` used as that mint receiver.
> **Markers**: Core (inherited unmodified from Liquity v2) / Original (DeltaForesight-specific new file; does not affect core no-modification CI guard).

---

## 1. Purpose, Scope, and Non-Responsibilities

In Liquity v2 core, the residual aggregate interest after the SP share (`SP_YIELD_SPLIT`) is minted as JPYdf to an immutable address called `interestRouter` (`CORE-AP-FR-007`). `interestRouter` is immutable in `AddressesRegistry` and cannot change after deployment (`CORE-AP-FR-001`).

Upstream Liquity connects `interestRouter` to ve-LQTY governance (PIL voting). JPYdf cannot use that route on Day-1 because DFT is not issued and upstream external dependencies are unrelated to the Day-1 requirement (`CORE-AP-TBD-001`). JPYdf resolves the "mint target cannot change" constraint by placing a thin `InterestRouterForwarder` at the immutable receiver. This is the same pattern as [`ADR-005`](../architecture/Architecture-Decision-Records.md#adr-005), where `PriceFeedProxy` makes the source behind a fixed oracle reference changeable.

- **Specified here**:
  - `InterestRouterForwarder`: receiver that holds JPYdf minted by core for the PIL share and transfers the full balance to the current `recipient` via `route()`. Owner can change `recipient`; owner transfer is 2-step, renounce is disabled, and ownership is handed to the shared Timelock.
  - Its single shared instance across all collateral branches (§2.3) and deploy / handover wiring requirements (§10).
- **Not specified here**:
  - Aggregate-interest SP/PIL distribution, minting to `interestRouter`, and immutable binding -> [Liquity-v2-Core-Spec](Liquity-v2-Core-Spec.md) (`CORE-AP-FR-003/007/008`, `CORE-AP-FR-001/015`). `SP_YIELD_SPLIT = 75%` is a Core inherited constant; the canonical value lives in `Constants.sol` and the Core spec constants table. Parameters.md is canonical only for DF-adjusted values and does not list `SP_YIELD_SPLIT`.
  - PIL distribution logic (DEX liquidity gauge distribution, allocation voting, distributor, etc.) -> Day-2 PIL/governance layer, out of scope.
  - Collateral yield distribution / buyback -> [Treasury](../../roadmap/spec/Treasury.md), a separate path from PIL with a separate receiver env (§2.4).
  - Concrete `recipient` / `owner` addresses and handover execution -> deploy env and [Governance-Roles-Timelock](../policies/Governance-Roles-Timelock.md).

---

## 2. Background and Design Policy

### 2.1 Fixed Core Constraints

| # | Fact (Core, unmodified) | Consequence |
| --- | --- | --- |
| 1 | On aggregate-interest mint, the PIL residual `mintedAmount - spYield` is minted to `interestRouter` by `jpydfToken.mint(interestRouter, ...)` (`CORE-AP-FR-007`). `spYield = SP_YIELD_SPLIT x mintedAmount` (`SP_YIELD_SPLIT = 75%`; value in `Constants.sol` / Core spec constants table) | PIL funds arrive as JPYdf at `interestRouter`. There is **no callback** on receipt |
| 2 | `interestRouter` is an immutable read by ActivePool constructor (`CORE-AP-FR-001/015`). `AddressesRegistry.setAddresses` runs once and owner is renounced | The mint target address **cannot change after deploy**. This is asymmetric with Treasury, whose address can later change through `setTreasury` |
| 3 | `IInterestRouter` is an empty interface. The receiver may be an EOA, multisig, or contract | The receiver can contain the ability to change the final delivery destination later |

### 2.2 Design Policy

1. **Use the receiver to add mutability without modifying core**: bind the immutable `interestRouter` to a thin `InterestRouterForwarder`, then change the final PIL destination (`recipient`) inside the Forwarder. Day-2 PIL/Treasury/governance can be reached without redeploying core.
2. **Pass-through and holding only; no accounting**: hold received JPYdf and transfer the full balance to current `recipient` through `route()`. No budget, ratio, claim, or distribution accounting.
3. **Fixed-destination principle**: funds can exit only to `recipient`. `route()` takes no destination argument and always sends the full balance to the current `recipient`. Only owner may change `recipient`.
4. **Owner separation and handover**: owner can change `recipient`; ownership is 2-step, renounce is disabled, and Day-1 handover moves owner to the shared TimelockController (12h). Recipient changes get public delay.
5. **Separate Day-1 recipient accounting**: Day-1 `recipient` is a PIL-dedicated address, separate from the collateral-yield Treasury Safe (§2.4).
6. **Required deploy inputs and fail-fast**: initial `recipient` / `owner` are provided by deploy env and deploy stops if missing (§10).

### 2.3 Single Shared Forwarder (All Branches -> One Receiver)

DF dToken wiring deploys exactly one Forwarder (CREATE2 deterministic address) and binds that same address as immutable `interestRouter` for all collateral branches.

- **Cross-branch PIL aggregation**: every branch ActivePool mints PIL JPYdf to the same Forwarder. The Forwarder balance is the aggregate PIL amount across all branches, and `route()` sends the aggregate to one `recipient`.
- **Accounting implication**: the Forwarder does not distinguish branch-level PIL. If branch-level allocation or external fee/revenue reporting such as DeFiLlama is needed, reconstruct it off-chain from each ActivePool's `AggregateInterestMinted` event.
- Handover/verify mechanically checks that every branch points to the same `interestRouter` (§10, IRTR-INV-006).

### 2.4 Recipient vs Treasury Separation

Deploy has two receiver paths.

| Path | Env | Meaning |
| --- | --- | --- |
| **PIL (this document)** | `DF_INTEREST_ROUTER_RECIPIENT` | Final destination for borrowing-interest PIL JPYdf (Day-1 = PIL-dedicated address) |
| Collateral yield ([Treasury](../../roadmap/spec/Treasury.md)) | `DF_TREASURY` | CollateralVault `treasury` (Day-1 = Foundation/GOV Safe retention) |

They are separate env values and separate addresses, allowing PIL and collateral yield to be tracked independently from Day-1.

---

## 3. Terms, External Dependencies, and Assumptions

### 3.1 Terms

| Term | Meaning |
| --- | --- |
| PIL | Protocol Incentivised Liquidity, funded by residual borrowing interest |
| `interestRouter` | Immutable address where core ActivePool mints PIL funds (`CORE-AP-FR-001/015`). In DF dToken wiring this is the single `InterestRouterForwarder` |
| `SP_YIELD_SPLIT` | SP share of aggregate interest (75%); residual 25% is PIL. The canonical value is in `Constants.sol` / [Liquity-v2-Core-Spec](Liquity-v2-Core-Spec.md) (`CORE-AP-FR-003/007` and constants table) |
| `route()` | Permissionless function that transfers the full JPYdf balance held by the Forwarder to the current `recipient`, returning the amount |
| `recipient` | Final PIL destination, changeable by owner. Day-1 = PIL-dedicated address |
| `owner` | Authority that can change `recipient`; 2-step transfer, renounce disabled. Handover to shared Timelock on Day-1 |
| `pendingOwner` | Pending target of 2-step ownership transfer. `transferOwnership(0)` cancels pending ownership |

### 3.2 Trusted External Dependencies

- **ActivePool (Core, per branch)**: sole mint source of PIL JPYdf. Forwarder never calls ActivePool.
- **JpydfToken (JPYdf, Core)**: token transferred by `route()`, fixed immutably in constructor. `constructor` and `setRecipient` reject current blocked Core destinations through `requireValidRecipient`. Assumes standard ERC-20 with no transfer hook (IRTR-SEC-004).
- **Shared TimelockController (DF)**: post-handover owner. Applies 12h delay to `setRecipient` ([Governance-Roles-Timelock](../policies/Governance-Roles-Timelock.md)).

### 3.3 Assumptions

- The Forwarder treats only JPYdf as legitimate funds. `route()` transfers only `jpydfToken` balance.
- No `receive()` / payable path; ETH cannot be received. There is no rescue for mistakenly sent non-JPYdf tokens (IRTR-TBD-003).
- Legacy/mainnet upstream path without dToken wiring binds the Governance address directly. This Forwarder is for DF dToken wiring only (§10, IRTR-GOV-005).

---

## 4. Actors, Roles, and Trust Boundaries

| Actor | Operation | Trust boundary |
| --- | --- | --- |
| **ActivePool (Core, per branch)** | Mints PIL funds to the single Forwarder | Core. Receipt only, no callback |
| **owner** (after handover = shared TimelockController with 12h delay) | `setRecipient`, 2-step ownership transfer / pending cancellation | Only privileged actor. Recipient changes have 12h delay. Renounce disabled |
| **route caller (anyone)** | `route()` | Trustless. Destination is fixed to current `recipient` regardless of caller |
| **recipient** | Receives funds only | Day-1 = PIL-dedicated address. Day-2 = PIL Distributor / governance. Use after receipt is out of scope |

Intent: separate "authority to change recipient" (owner=Timelock, delayed) from "operation to move funds to recipient" (permissionless, harmless). Even if owner is compromised, it does not provide an immediate fund-stealing route (IRTR-SEC-001).

---

## 5. Interface Specification

Behavior is normative in §6; this table is a terse non-normative visibility summary. The implementation does not inherit `IInterestRouter`, but because deploy binds it as `IInterestRouter(address)`, it satisfies the empty-interface contract.

| Function / element | Visibility | Summary | Requirements |
| --- | --- | --- | --- |
| `constructor(IERC20 _jpydfToken, address _recipient, address _owner)` | - | Set immutable `jpydfToken`, initial `recipient`, and initial `owner`; reject zeroes and JPYdf-blocked Core recipients; emit initial events | IRTR-FR-001 |
| `route() returns (uint256 amount)` | external permissionless | Transfer the full held JPYdf balance to current `recipient`, returning amount | IRTR-FR-002 |
| `setRecipient(address newRecipient)` | external onlyOwner | Change final destination; reject zero and JPYdf-blocked Core recipients | IRTR-FR-003 |
| `transferOwnership(address newOwner)` | external onlyOwner | Start 2-step transfer. `newOwner = 0` cancels pending transfer | IRTR-FR-004 |
| `acceptOwnership()` | external onlyPendingOwner | Complete 2-step transfer | IRTR-FR-004 |
| `renounceOwnership()` | external view onlyOwner | Disabled. Owner call reverts `RenounceOwnershipDisabled`; non-owner reverts `Unauthorized` | IRTR-FR-004 |
| `owner()` / `pendingOwner()` / `recipient()` / `jpydfToken()` | external view | Observable state | IRTR-FR-005 |

Errors: `ZeroAddress` / `Unauthorized` / `RenounceOwnershipDisabled`. This is a self-implemented 2-step ownership pattern, not OZ `Ownable2Step`. `JpydfToken__CannotTransferToProtocolContract` bubbles from JpydfToken when a recipient is a blocked Core destination.

---

## 6. Functional Requirements (FR)

### IRTR-FR-001: constructor (establish receiver and fail-fast)

- **Type**: Functional | **Source**: §2.2 / `CORE-AP-TBD-001`
- **Signature**: `constructor(IERC20 _jpydfToken, address _recipient, address _owner)`
- **Purpose**: Establish the PIL receiver. Fix the transferred token (JPYdf) immutably, and set initial `recipient` and `owner`.
- **Permission**: deploy only.
- **Preconditions (Checks)**: `_jpydfToken != 0`, `_recipient != 0`, `_owner != 0`; zero reverts `ZeroAddress`. `IJpydfToken(_jpydfToken).requireValidRecipient(_recipient)` must also succeed.
- **Behavior (Effects)**: store immutable `jpydfToken`; set `recipient` and `owner`; emit `RecipientUpdated(0, _recipient)` and `OwnershipTransferred(0, _owner)`.
- **Design notes**: initial values come from deploy env (IRTR-GOV-002). A missing or currently JPYdf-blocked recipient stops deployment. Forwarder has deterministic CREATE2 address. The only mutable item is `recipient`; redeploying would require branch rewiring. Because Core address registration continues after Forwarder construction, deploy-tail verification repeats recipient validation.
- **Verification**: unit.

### IRTR-FR-002: route (transfer PIL funds, permissionless)

- **Type**: Functional | **Source**: §2.2
- **Signature**: `route() returns (uint256 amount)`
- **Purpose**: Transfer the full JPYdf balance held by this contract to the current `recipient`.
- **Permission**: permissionless.
- **Preconditions (Checks)**: none; zero balance is no-op.
- **Behavior (Effects)**:
  1. `amount = jpydfToken.balanceOf(address(this))`
  2. if `amount == 0`, `return 0` without event
  3. `jpydfToken.safeTransfer(recipient, amount)`; destination is fixed to current `recipient`
  4. emit `Routed(recipient, amount)` and return `amount`
- **revert / early return**: zero balance -> `return 0`.
- **Design notes**: because caller cannot choose destination, permissionless calls cannot misdirect funds. Anyone can flush and minimize retention. CEI is satisfied and standard ERC-20 JPYdf leaves no useful reentrancy path (IRTR-SEC-004).
- **Verification**: unit, invariant=IRTR-INV-001/002, integration (core mint -> route -> recipient).

### IRTR-FR-003: setRecipient (change final destination)

- **Type**: Functional / Governance | **Source**: §2.2
- **Signature**: `setRecipient(address newRecipient)`
- **Purpose**: Change the final destination of PIL funds (for example Day-1 PIL address -> Day-2 Distributor/governance).
- **Permission**: `onlyOwner` (after handover, shared Timelock with 12h delay).
- **Preconditions (Checks)**: `newRecipient != 0`, otherwise `ZeroAddress`; `IJpydfToken(jpydfToken).requireValidRecipient(newRecipient)` must also succeed.
- **Behavior (Effects)**: set `recipient = newRecipient`; emit `RecipientUpdated(oldRecipient, newRecipient)`.
- **revert**: non-owner -> `Unauthorized`; zero -> `ZeroAddress`; a currently blocked JPYdf Core destination -> `JpydfToken__CannotTransferToProtocolContract`. A failed update preserves the current `recipient`.
- **Design notes**: ActivePool immutable still points to Forwarder; only the delivery destination changes. Change is future-effective from the next `route()`.
- **Verification**: unit.

### IRTR-FR-004: ownership (self-implemented 2-step transfer, renounce disabled)

- **Type**: Governance / Security | **Source**: `CORE-AP-TBD-001` / [Governance-Roles-Timelock](../policies/Governance-Roles-Timelock.md)
- **Purpose**: Safely transfer owner authority, especially to the shared Timelock, and avoid accidental transfer or permanent strand.
- **Requirements**:
  - `transferOwnership(newOwner)` (onlyOwner) sets `pendingOwner = newOwner` and emits `OwnershipTransferStarted`. Passing `address(0)` cancels pending transfer instead of reverting.
  - `acceptOwnership()` requires `msg.sender == pendingOwner`; otherwise `Unauthorized`. It updates `owner`, clears `pendingOwner`, and emits `OwnershipTransferred`.
  - `renounceOwnership()` always reverts (`external view onlyOwner`; owner call -> `RenounceOwnershipDisabled`, non-owner -> `Unauthorized`) because ownerless state would permanently strand the ability to update `recipient`.
- **Design notes**: same shape as dToken / Strategy disabled-renounce 2-step ownership, but self-implemented and with `transferOwnership(0)` cancellation (IRTR-SEC-005).
- **Verification**: unit.

### IRTR-FR-005: View Functions

- `owner()` / `pendingOwner()` / `recipient()` / `jpydfToken()`. Used for monitoring, subgraph, and handover verification.
- **Verification**: unit.

---

## 7. State Variables and Accounting Model

| Variable | Type | Description |
| --- | --- | --- |
| `jpydfToken` | `IERC20 immutable` | Transfer token (JPYdf), fixed in constructor |
| `owner` | `address` | Authority for `setRecipient`; after handover = shared Timelock |
| `pendingOwner` | `address` | Pending 2-step transfer target; `transferOwnership(0)` cancels |
| `recipient` | `address` | Current PIL destination. Day-1 = PIL-dedicated address |

Accounting model: no budget, ratio, claim, or distribution accounting. Held balance = `jpydfToken.balanceOf(this)`, the untransferred aggregate PIL funds across all branches (§2.3). `route()` sends the full balance to `recipient`. Any branch-level allocation is Day-2 distribution / off-chain responsibility.

---

## 8. Invariants (INV)

| ID | Invariant | Verification |
| --- | --- | --- |
| IRTR-INV-001 | Funds can exit only to `recipient`; there is no destination-argument transfer function and no rescue function | unit / manual |
| IRTR-INV-002 | `route()` sends the full held JPYdf balance to current `recipient`; there is no partial-send or alternate-destination path | unit / invariant |
| IRTR-INV-003 | Only `owner` (after handover = Timelock) can change `recipient`; zero and destinations currently blocked by JPYdf are forbidden | unit |
| IRTR-INV-004 | `owner` cannot renounce; a live owner always exists so update ability is not permanently stranded | unit |
| IRTR-INV-005 | No state-changing calls to Core (does not call ActivePool; receive only; core no-modification CI guard has zero diff because this is a new file) | manual / CI |
| IRTR-INV-006 | In DF dToken wiring, every branch's `interestRouter` points to the same single Forwarder | deploy / handover verification |

---

## 9. Security Requirements (SEC)

### IRTR-SEC-001: Damage boundary for owner key compromise

- **Statement**: owner can only execute `setRecipient` and ownership transfer. It has no immediate fund-stealing route. After handover, owner is the shared Timelock (12h), so malicious recipient changes are delayed and can be detected/responded to. `route()` is permissionless but always sends to current `recipient`.
- **Residual risk**: if the team does not respond within 12h, future PIL can flow to the new recipient. Monitoring of IRTR-EVT-002 and incident response are required. Before handover completes (owner = deployer/admin), there is no delay, so deploy -> handover completion must happen promptly with strict key handling.
- **Verification**: unit / manual.

### IRTR-SEC-002: Permissionless route safety

- **Statement**: anyone can call `route()`, but the caller controls neither destination nor amount (always full balance to current `recipient`). Third-party calls must not create misdirection or MEV theft. Zero-balance calls are no-op.
- **Verification**: unit.

### IRTR-SEC-003: Prevent strand through invalid recipient or renounce

- **Statement**: `recipient` cannot be zero or a JPYdf-blocked Core destination (IRTR-FR-001/003), and owner cannot renounce (IRTR-FR-004). A rejected update preserves the current recipient and its live `route()` path. This structurally prevents known configuration errors from making PIL funds undeliverable.
- **Verification**: unit.

### IRTR-SEC-004: Reentrancy / CEI

- **Statement**: `route()` has a single external call, `jpydfToken.safeTransfer`, and the contract is stateless pass-through for funds, leaving no useful reentrancy path. `setRecipient` only updates storage. This relies on JPYdf being a standard ERC-20 without transfer hooks (§3.2). No `nonReentrant` guard is needed.
- **Verification**: unit / manual.

### IRTR-SEC-005: Abuse boundary for pending ownership cancellation

- **Statement**: pending cancellation by `transferOwnership(0)` is owner-only. After handover (owner = Timelock), it is subject to the same 12h delay as IRTR-SEC-001. Before handover completes, current owner (deployer/admin) can unilaterally interrupt, so Timelock `acceptOwnership` should be executed promptly after deploy.
- **Verification**: unit / manual.

---

## 10. Governance, Operations, and Upgrade Requirements (GOV)

### IRTR-GOV-001: Role structure and handover

- Initial `owner` is deploy env `DF_INTEREST_ROUTER_OWNER`. Day-1 handover (`PrepareDFGovernanceHandover` / `VerifyDFGovernanceHandover`) transfers ownership 2-step to the shared TimelockController (minDelay 12h, same as dToken / CollateralVault / Strategy).
- Handover reads each branch `interestRouter` from the deploy manifest, starts `transferOwnership(<shared Timelock>)` on the single Forwarder, and asserts every branch uses the same `interestRouter` (idempotent).
- **Assumption**: because handover requires `current owner == execution actor (currentAdmin)`, initial `DF_INTEREST_ROUTER_OWNER` should match the handover actor (deployer/admin). If the initial owner is directly Timelock, the start step is skipped and Timelock must run `acceptOwnership` separately.
- Completion (`acceptOwnership`) is executed by Timelock proposal. Verify checks `owner == shared Timelock`, or `pendingOwner == shared Timelock` when intermediate state is allowed.

### IRTR-GOV-002: Deploy inputs and fail-fast

- DF dToken wiring (IRTR-GOV-005) requires env `DF_INTEREST_ROUTER_RECIPIENT` (initial `recipient`, Day-1 PIL-dedicated address) and `DF_INTEREST_ROUTER_OWNER` (initial `owner`). If either is zero or the recipient is rejected by JPYdf, deploy stops. One CREATE2 Forwarder is deployed and bound to every branch's `interestRouter`.
- Deploy-tail and handover/verify/accept scripts fail-fast on binding consistency (`interestRouter == Forwarder`, `recipient` / `owner` match env) and repeat `requireValidRecipient(recipient)` after Core address registration (IRTR-TBD-006 is resolved).

### IRTR-GOV-003: Day-1 -> Day-2 delivery migration

- The Day-1 default initial `recipient` is a PIL-dedicated holding Safe/address with no distribution. Even if `PILAllocator` is deployed on the same day, the initial `DF_INTEREST_ROUTER_RECIPIENT` is not `PILAllocator`. When Phase-A PIL allocation (`PILAllocator`) or a future Distributor / governance layer goes live, owner (Timelock) changes destination with `setRecipient`; no redeploy required. Any retained balance can be flushed with `route()`.
- The `pil-activation-manifest.json` produced by `DeployPILAllocatorPhaseA` is deploy-ready evidence. `DF_INTEREST_ROUTER_RECIPIENT=PILAllocator` or `setRecipient(PILAllocator)` is executed only after a later activation package explicitly approves the Merkl official address, poolId, weights, campaign params, fork simulation, and Timelock bundle. Same-launch activation is an exception, not the standard launch, and must be explicitly approved in the same activation package.

### IRTR-GOV-004: Upgrade policy

- Non-UUPS and non-upgradeable. The logic is intentionally minimal to simplify audit. Any behavior change requires deploying a new Forwarder and rewiring all branches.

### IRTR-GOV-005: Chain-specific wiring gate

- DF dToken wiring (dToken collateral + PriceFeedProxy + this Forwarder) is enabled by default on non-mainnet. On mainnet, the Day-1 8-branch wiring is entered only when `DF_ENABLE_MAINNET_DTOKEN_WIRING=true` and full production env are explicitly supplied; otherwise deploy reverts. Mainnet real values for `DF_INTEREST_ROUTER_RECIPIENT` / `DF_INTEREST_ROUTER_OWNER` are required (IRTR-TBD-001). Include both env values in the Mainnet Launch Risk Gate address freeze.

---

## 11. Event and Monitoring Requirements (EVT)

| ID | Event (indexed args) | Off-chain use |
| --- | --- | --- |
| IRTR-EVT-001 | `Routed(address indexed recipient, uint256 amount)` | PIL delivery record and retained-balance monitoring |
| IRTR-EVT-002 | `RecipientUpdated(address indexed oldRecipient, address indexed newRecipient)` | Destination change tracking with Timelock proposal/execution immediate alert. Constructor also emits the initial value |
| IRTR-EVT-003 | `OwnershipTransferStarted` / `OwnershipTransferred` (`previousOwner` / `newOwner` indexed) | Handover tracking and verify reconciliation. Constructor emits initial owner |

Monitoring metrics: Forwarder held balance (aggregate PIL across all branches), current `recipient` (expected = PIL-dedicated or Day-2 Distributor), current `owner` (expected = shared Timelock), immediate alerts on `RecipientUpdated` / `OwnershipTransferStarted`.

---

## 12. Failure and Exceptional Behavior (ERR)

| Event | Behavior |
| --- | --- |
| `route()` with zero balance | `return 0` without revert or event; safe for anyone to call |
| Constructor or `setRecipient` receives a current JPYdf-blocked Core destination | Revert with `JpydfToken__CannotTransferToProtocolContract`; a setter failure preserves the current recipient and route path |
| Malicious `setRecipient` by owner-key compromise | After handover, runs through Timelock (12h delay). Detect/respond during the delay via `RecipientUpdated`/Timelock events (IRTR-SEC-001) |
| `recipient` is a nonfunctional contract | Standard ERC-20 `transfer` does not depend on receiver logic, so Forwarder send succeeds. Retention at recipient is recipient-management issue and can be corrected by owner `setRecipient` |
| Non-JPYdf token mistakenly sent | No rescue function; token remains stuck. `route()` transfers only `jpydfToken`. ETH cannot be received (IRTR-TBD-003) |
| Current owner calls `transferOwnership(0)` before handover completes | Pending Timelock transfer is cancelled. Mitigate by completing handover promptly (IRTR-SEC-005) |
| Day-1 PIL distribution layer is not live | Funds remain at the PIL-dedicated `recipient` without distribution, as designed. Day-2 changes recipient with `setRecipient` |

---

## 13. Acceptance Criteria and Verification Plan

| ID | Requirement summary | Verification |
| --- | --- | --- |
| IRTR-FR-001 | constructor (zero / JPYdf-blocked recipient rejection, initial values, initial events) | unit |
| IRTR-FR-002 | route (full amount, fixed destination, zero-balance no-op, permissionless, return value) | unit, invariant=IRTR-INV-001/002, integration |
| IRTR-FR-003 | setRecipient (owner-only, zero / JPYdf-blocked recipient rejection, preserve live route on failure, future-effective) | unit |
| IRTR-FR-004 | 2-step ownership, pending cancellation, renounce disabled | unit |
| IRTR-FR-005 | view functions | unit |
| IRTR-INV-001..006 | §8 invariants | unit / invariant / manual / CI / deploy-handover |
| IRTR-SEC-001..005 | §9 security requirements | unit / manual |
| Wiring (handover) | owner moves 2-step to shared Timelock | integration |
| Wiring (deploy) | `interestRouter == Forwarder`; `recipient` / `owner` match env; core mint -> route -> recipient end-to-end | deploy / integration (IRTR-TBD-006 is resolved; deploy-tail checks token / recipient / owner / pendingOwner / all-branch sameness) |

Core-side verification for PIL residual mint and SP/PIL split belongs to [Liquity-v2-Core-Spec](Liquity-v2-Core-Spec.md) (`CORE-AP-FR-007`). This document verifies only receiver behavior and wiring consistency.

---

## 14. Open Issues (TBD)

### IRTR-TBD-001

**Concrete Day-1 PIL-dedicated holding Safe/address mainnet value**: the Day-1 default is to set `DF_INTEREST_ROUTER_RECIPIENT` to a dedicated multisig/Safe, or to a holding address with separate accounting inside an existing governance Safe (accounting separation is mandatory and the concrete address is finalized before activation). `PILAllocator` remains deploy-ready / evidence-ready, and `DF_INTEREST_ROUTER_RECIPIENT = PILAllocator` is not used in the standard launch. Phase-A active routing is separately approved by a later activation package after `DeployPILAllocatorPhaseA` `pil-activation-manifest.json` plus the PILAllocator / initiative / Merkl / poolId / weights freeze package is completed under [Parameters](../../../Parameters.md) §2-F. Non-mainnet tests may use temporary addresses.

### IRTR-TBD-002

Resolved (2026-08-09): `route()` uses keeper operations. The standard entrypoint is `frontend/ops route-interest`, with dry-run default, explicit live mode, no raw private key, a dedicated AWS KMS `ECC_SECG_P256K1` remote signer, signer / account / region / key-state readback, RPC `chainId`, all-branch `interestRouter` sameness, expected Forwarder / recipient, Forwarder `jpydfToken()`, a positive route threshold, the fixed `route()` selector, gas / fee / signer ETH balance caps, pre-send simulation, rejection of unresolved nonces, receipt timeout, and receipt / event / post-state verification. A zero balance is a no-op after KMS identity verification; a balance below `IRTR_MIN_ROUTE_AMOUNT` is threshold-skipped. The canonical operational procedure is [InterestRouterForwarder Route Runbook](../../operations/runbooks/InterestRouterForwarder-Route-Runbook.md).

### IRTR-TBD-003

**Whether to support rescue for mistakenly sent tokens**: current design has no rescue function (mistaken non-JPYdf tokens cannot be recovered). Default policy is "no rescue + monitoring"; if needed, deploy a new Forwarder and rewire all branches because this contract is non-upgradeable. Even if rescue is added, JPYdf (legitimate funds) must be excluded and the fixed-destination principle (IRTR-INV-001) must remain intact.

### IRTR-TBD-004

Resolved: when `recipient` changes to Phase-A `PILAllocator` / future PIL Distributor / governance, the Forwarder needs no extra notification. It remains pass-through, and allocation / claim / campaign creation are implemented by the recipient layer.

### IRTR-TBD-005

Resolved (2026-06-22): `SP_YIELD_SPLIT` is a Core inherited constant defined as `75%` in `Constants.sol` and canonicalized in [Liquity-v2-Core-Spec](Liquity-v2-Core-Spec.md) `CORE-AP-FR-003/007` plus the constants table. Parameters.md is canonical only for DF-adjusted values and does not list `SP_YIELD_SPLIT`. This document only references the value as receiver context; it does not affect Forwarder requirements.

### IRTR-TBD-006

Resolved (2026-06-18): deploy-tail DF wiring verification fail-fast checks that every branch's `interestRouter` is the single `InterestRouterForwarder`, and that Forwarder `jpydfToken` / `recipient` / `owner` / `pendingOwner` match deploy env.

---

## 15. References

- [Liquity-v2-Core-Spec](Liquity-v2-Core-Spec.md): `CORE-AP-FR-007/008` (aggregate-interest SP/PIL mint), `CORE-AP-FR-001/015` (`interestRouter` immutable and views), `CORE-AP-TBD-001` (receiver-binding decision)
- [Product-Overview](../Product-Overview.md): PIL
- [Architecture Decision Records](../architecture/Architecture-Decision-Records.md#adr-005): replaceability behind a fixed reference
- [Mainnet Launch Risk Gate](../../launch/gates/Mainnet-Launch-Risk-Gate.md): system-wide launch risk
- [Treasury](../../roadmap/spec/Treasury.md): collateral-yield distribution; separate from PIL and uses `DF_TREASURY`
- [Governance-Roles-Timelock](../policies/Governance-Roles-Timelock.md): shared TimelockController and Day-1 handover
- [Parameters](../../../Parameters.md): finalized operational values such as the PIL-dedicated recipient. `SP_YIELD_SPLIT` is a Core inherited constant whose source of truth is Core spec / `Constants.sol`.
