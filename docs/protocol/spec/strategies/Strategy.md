# 🟢 Strategy Requirements

## 0. Metadata

| Item | Value |
| --- | --- |
| Status | Draft (implementation exists; requirements are being canonicalized) |
| Owner | DeltaForesight |
| Target contracts | `contracts/src/Interfaces/IStrategy.sol` (normative interface `IStrategy`) / `contracts/src/Strategies/BaseStrategy.sol` (abstract base; UUPS). Every active Strategy derives from `BaseStrategy` directly; there is no async base in active scope, because `contracts/src/Strategies/archive/AsyncRequestStrategy.sol` was archived with its only two subclasses (see [Contract-Audit-Scope-And-nSLOC](../../../../engineering/guides/Contract-Audit-Scope-And-nSLOC.md) section 3.5). Concrete implementations are defined in child documents, for example [AaveV3Strategy requirements](AaveV3Strategy.md) / [ERC4626Strategy requirements](ERC4626Strategy.md) / [MorphoV2Strategy requirements](MorphoV2Strategy.md) |
| Related documents | [Product-Overview](../../Product-Overview.md) (architecture and responsibility split) / [CollateralVault](../CollateralVault.md) (allocate / push intake / roles) / [dToken](../dToken.md) (collateral token) / [AaveV3Strategy](AaveV3Strategy.md) (concrete implementation) / [ERC4626Strategy](ERC4626Strategy.md) (ERC-4626 adapter for Morpho / Euler, etc.) / [LidoStrategy](../../../../archive/LidoStrategy.md) (Lido stETH async Strategy) / [EtherfiWeETHStrategy](../../../../archive/EtherfiWeETHStrategy.md) (Etherfi eETH / weETH async Strategy) / [Collateral-Asset-Management-Policy](../../../operations/policies/Collateral-Asset-Management-Policy.md) (candidate venues and adapter coverage) / [Strategy-Selection-Policy](../../../operations/policies/Strategy-Selection-Policy.md) (external venue adoption gate) / [Parameters](../../../../Parameters.md) (cap / buffer / weight values) |

> This document follows the [requirements specification document standard](../../../../README.md#requirements-spec-standard). Requirements, invariants, and security requirements have persistent IDs (`STGY-...`), and cross-references use those IDs. This document specifies only the items shared by all Strategies. Requirements specific to individual Strategies, such as Aave V3 / Lido stETH + Withdrawal Queue / Morpho / Euler, are documented in child documents.

---

## 1. Purpose, Scope, and Non-Responsibilities

Strategy is the **yield adapter layer** (UUPS) that deposits, recovers, and values the Underlying sent by CollateralVault through `allocate` into **one external yield venue** (Aave V3 / Lido stETH + Withdrawal Queue / Morpho / Euler, etc.). It is the translation layer for external protocol interfaces. Recovery and yield transfer are initiated by the Strategy side and **pushed** to the Vault (push model).

- **This document specifies**: items common to all Strategies: the normative `IStrategy` interface ([STGY-FR-001](#stgy-fr-001-deposit-deposit-into-the-external-protocol) through [STGY-FR-008](#stgy-fr-008-view-getters-principal--realizedyield--estimatedtotalunderlying--underlying)); the `BaseStrategy` base (shared accounting, `principal` management, hook conventions); `AsyncRequestStrategy` (shared async requestId, pending amount, and self-owned idle Underlying accounting for Lido / Etherfi-style Strategies); shared authorization design (ALLOCATOR / Owner / upgrader boundaries); shared monitoring and event policy; and shared risks.
- **This document does not specify (non-responsibilities / other documents)**:
  - Decisions about "which Strategy receives how much" based on buffer / cap / weights (`allocate`), transfer of Underlying to Strategies, push intake `receiveFromStrategy`, finalization of principal impairment through `writeoffStrategyPrincipal`, the second-stage `transferYieldToTreasury`, and the canonical role definitions such as `ALLOCATOR_ROLE` → [CollateralVault requirements](../CollateralVault.md)
  - External-protocol-specific requirements for each concrete Strategy (additional storage / hook implementation / protocol-specific emergency recovery functions / reward tokens / specific risks) → child documents such as [AaveV3Strategy requirements](AaveV3Strategy.md)
  - dToken collateral token specification → [dToken requirements](../dToken.md)
  - Finalized collateral-specific parameters such as cap / buffer / weight → [Parameters requirements](../../../../Parameters.md)
  - 🔵 Liquity core collateral, liquidation, and Redemption behavior → [Liquity-v2-Core-Spec](../Liquity-v2-Core-Spec.md)
  - Adapter coverage and candidate-venue inventory → [Collateral-Asset-Management-Policy](../../../operations/policies/Collateral-Asset-Management-Policy.md)
  - Risk / governance / monitoring gates for approving an external venue → [Strategy-Selection-Policy](../../../operations/policies/Strategy-Selection-Policy.md)
- **Responsibility boundary (intentionally unaware)**: an individual Strategy is responsible only for "how to deposit the received Underlying into one external protocol, how to recover it, and what value it has." It is unaware of Vault-side allocation decisions, buffer accounting, and destination decisions. It also does not know the external protocol's internal state; it only calls that protocol's interface.

---

## 2. Background and Design Policy

The Strategy layer is the yield-venue adapter for the dToken collateral model that **uses Liquity v2 core without modification**. The canonical source for the overall no-core-modification policy and the background for dToken as the core collateral is [Product Overview](../../Product-Overview.md) §5.

- **Push model (recovery is Strategy-initiated)**: the Vault does not pull funds from the Strategy. Principal/cache-reconciliation routes (`sendToVault` / protocol-specific emergency recovery / generic idle `emergencyWithdraw`) push through `receiveFromStrategy` into the Vault buffer. Exact delivery reduces the Vault-side Strategy valuation cache by actual receipt; a declared/received mismatch invalidates the cache because receipt alone cannot prove the upstream-position decrease. Yield-only routes (`sendProfitToVault` / Underlying reward claims) transfer directly into the Vault buffer and do not move principal or valuation caches.
- **Self-managed `principal`**: each Strategy manages its deployed principal `principal` in its own ledger. `principal` is not an observed value from the external protocol. It increases by the amount sent by the Vault (the `deposit` argument), and decreases on recovery by the amount actually received by the Vault (principal-first / `sent`-based subtraction described below). This prevents drift between `principal` and the Vault buffer.
- **Conservative valuation**: AUM valuation through `estimatedTotalUnderlying()` must be conservative because overvaluation can over-send yield. The Vault performs solvency and `managedUnderlying` valuation with `min(estimatedTotalUnderlying, principal)`. This is not a price oracle; it is the Strategy's estimate of recoverable Underlying-denominated value from the external protocol. Yield transfer is defended in two layers: the Strategy-side `realizedYield()` upper bound and the Vault-side `managedUnderlying` surplus + buffer cap (`transferYieldToTreasury`).
- **Synchronous/asynchronous behavior is internal to implementations**: whether an external protocol supports immediate withdrawal (synchronous) or requires waiting such as unbonding (asynchronous) is hidden inside the Strategy implementation and is not surfaced in `IStrategy`. Asynchronous external protocols are absorbed by returning only the amount immediately withdrawable at that time inside `_doWithdraw` ([STGY-FR-002](#stgy-fr-002-sendtovault-principal-recovery-push) / [STGY-ERR-002](#stgy-err-002-handling-asynchronous-external-protocols)). The Vault therefore does not hold `requestKey`, branch on `isAsyncWithdraw`, or implement asynchronous liquidation paths such as `claimWithdraw` / `claimHarvest`. Structural issues such as "no liquidation path for asynchronous principal recovery" or "yield claims do not validate requestKey purpose" do not arise. Principal/yield distinction and `principal` accounting stay inside the Strategy; the Vault receives principal/cache-reducing pushes through `receiveFromStrategy` and yield-only pushes as direct buffer transfers.
- **Shared implementation is centralized in BaseStrategy / AsyncRequestStrategy**: `BaseStrategy` (abstract, UUPS) provides the bodies of `deposit` / `sendToVault` / `sendProfitToVault` / `writeoffPrincipal`, push-model accounting, and `principal` management. Derived classes implement only hooks (`_doDeposit` / `_doWithdraw` / `_estimatedTotalUnderlying`). Async Strategies with request / claim lifecycles, such as Lido and Etherfi, inherit `AsyncRequestStrategy`, which centralizes the unclaimed requestId set, `pendingWithdrawAmount`, and claimed self-owned idle Underlying accounting. This localizes protocol-specific differences to hooks and request/claim interfaces.
- **Async pending valuation**: Lido / Etherfi-style async Strategies value unclaimed requests as `pendingWithdrawAmount * pendingWithdrawalValuationBps / 10000` with floor rounding. The effective default is 10000 bps, so normal unstaking does not make pending principal disappear from AUM. Fresh initialization stores 10000 bps with configured=true; if storage is unset after an implementation upgrade, the getter and valuation still use 10000 bps as the effective default. During incidents where finalization / claim proceeds are uncertain, the Vault `WRITEOFF_ROLE` may lower the bps to conservatively value only the pending component before claim. Downward changes (`newBps < oldBps`) require `pausedAllocation == true`, so they can only affect backing after incident freeze; restoration / upward changes (`newBps >= oldBps`) do not require pause.
- **Deployment unit = 1 Underlying × 1 external yield venue**: one Strategy instance = one Underlying = one external yield venue. Even for the same external protocol, different Underlyings use separate instances. One CollateralVault can register multiple Strategy instances through `addStrategy`.
- **Separation into child documents**: §15 preserves the structure convention for individual Strategy child documents. Shared items reference this document; child documents contain only external-protocol-specific items.

### 2.1 Strategy-Kind Operational Differences

The `IStrategy` surface is shared, but `estimatedTotalUnderlying()`, immediately
recoverable assets, and the evidence required before writeoff differ by implementation.
Operational decisions use the registered Strategy implementation, not the branch symbol.
[Strategy Selection Policy](../../../operations/policies/Strategy-Selection-Policy.md) is
authoritative for each venue's current adoption status. A temporary withdrawal queue or
venue pause is not automatically principal loss; writeoff follows implementation-specific
valuation and recovery evidence. Existing Lido instances, if any, are recovery and
retirement cases rather than a basis for new activation.

Self-appreciation of a yield-bearing Underlying through its canonical rate belongs to
borrower collateral value. It is distinct from growth in Underlying quantity generated
by an external Strategy.

### 2.2 Dedicated-Strategy Boundary

Use the common ERC-4626 adapter for a venue whose `asset() == underlying`; a venue name
alone does not justify a new adapter. A dedicated Strategy is warranted only when the
position token differs from Underlying, conversion crosses assets, valuation needs a
protocol-specific rate, reward handling changes backing treatment, or recovery requires
protocol-specific asynchronous steps.

### 2.3 Deploy Selector / Multi-Strategy Initial Registration

`DeployLiquity2` adopts `aave` / `erc4626` / `etherfi-weeth` /
`sky-susds` / `none`; current code also recognizes the legacy `lido` selector.
Selection must follow the adoption status in Strategy Selection Policy.
A single-Strategy branch reads the legacy-compatible
`DF_STRATEGY_KIND_i` / `DF_STRATEGY_WEIGHT_BPS_i` / `DF_STRATEGY_CAP_i` env
keys. A branch that should be initialized with multiple Strategies sets
`DF_STRATEGY_COUNT_i=N` and uses `DF_STRATEGY_KIND_i_j` /
`DF_STRATEGY_WEIGHT_BPS_i_j` / `DF_STRATEGY_CAP_i_j` plus kind-specific
`..._i_j` env keys. Do not place `none` inside the array form; `none` only
represents a single branch with no external venue.

The deployment manifest emits all Strategies only under `dfYield[i].strategies[]`.
Fresh deploy does not emit legacy-compatible top-level `strategy` /
`strategyKind` / `strategyWeightBps` / `strategyCap`. Deploy-tail verification
checks the Vault registered Strategy count, primary strategy, each Strategy
`vault()` / `underlying()`, and total weight. Governance prepare / verify /
accept helpers compare manifest `strategies[]` length with the live Vault
registered Strategy list, so secondary Strategies receive the same owner /
upgrader handover as the primary Strategy.

### 2.4 External Venue Address Update Policy

External venue addresses such as Aave Pool / aToken, ERC-4626 vault, the Lido
venue set, Etherfi LiquidityPool / weETH / WithdrawAdapter / WithdrawRequestNFT,
and Sky converter / sUSDS vault are fixed in each Strategy `initialize`.
Ordinary operation must not swap them through setters such as `setPool`,
`setVault`, or `setWithdrawalQueue`. If a venue must be changed, deploy a new
Strategy proxy and replace the Vault registration through `addToWhitelist` →
`addStrategy` / `updateStrategy` → old Strategy `sendToVault`,
protocol-specific emergency recovery, and `writeoffStrategyPrincipal` if needed
→ `removeStrategy`.

This replacement does not require an implementation upgrade or migration setter
on the old Strategy proxy. Old and new Strategies can remain registered together:
the old one is set to zero weight / disabled to stop new allocation, then a
synchronous venue is recovered atomically or an asynchronous venue remains
registered until request / claim completion. `removeStrategy` requires both
`principal == 0` and `estimatedTotalUnderlying() == 0` on chain, so registration
cannot be removed while an accounted position remains.

The reason is that venue setters create an attack surface where the Strategy
Owner can move the destination of funds after deployment, and they expand the
scope of allowance, storage-layout, and external-protocol invariant review.
Position shares, self-owned amount ledgers, asynchronous request IDs / NFTs, and
token allowances are also bound to the old venue graph; overwriting only an
address can lose the valuation, claim, or protected-token boundary for the old
position. The one-shot core-branch `AddressesRegistry` must not be repurposed as
a mutable venue registry for multiple Strategies. If a
future protocol truly requires setter-style venue updates, specify it as a
separate upgrade design that includes timelock, preflight, and runbook
requirements.

Changing only the implementation behind an existing proxy requires a separate
proof that Solidity inheritance order and storage layout are compatible. In
particular, moving accounting storage into a shared base such as
`AsyncRequestStrategy` is not assumed to be layout-compatible with older
per-Strategy implementations. Even for pre-mainnet / local deployments where
backward compatibility is not required, the operational path is to deploy a
fresh Strategy proxy and replace the Vault registration.

---

## 3. Terms, External Dependencies, and Assumptions

**Terms**

| Term | Meaning |
| --- | --- |
| Underlying | The real asset managed by the Strategy (WETH / USDC, etc.). Same as the asset wrapped by dToken |
| vault | The corresponding CollateralVault that registers this Strategy and performs `allocate` / push intake |
| External protocol | The yield venue itself (Aave V3 / Lido stETH + Withdrawal Queue / Morpho / Euler, etc.). The Strategy only calls its interface |
| `principal` | Deployed principal self-managed by this Strategy (ledger value) |
| `estimatedTotalUnderlying` | Underlying-denominated value of assets this Strategy manages in the external protocol (conservative valuation). Not a price oracle; input to Vault `A = totalUnderlying()` |
| `realizedYield` | `max(estimatedTotalUnderlying - principal, 0)`. Upper bound for unrealized yield |
| push model | Recovery model in which the Strategy initiates funds returning to the Vault: principal/cache-reducing returns go through `receiveFromStrategy`, while yield-only returns are direct transfers to the Vault buffer |
| hook | External-protocol translation point implemented by derived classes (`_doDeposit` / `_doWithdraw` / `_estimatedTotalUnderlying`) |
| synchronous / asynchronous | Whether the external protocol can withdraw immediately (synchronous) or requires waiting such as unbonding (asynchronous) |
| Owner | Emergency operator for the Strategy (Guardian multisig; immediate multisig. Finalized on 2026-06-12) |
| upgrader | Dedicated UUPS upgrade authorization authority (separated from Owner; holder = shared TimelockController; 12h) |
| ALLOCATOR | Holder of the Vault's `ALLOCATOR_ROLE`. Triggers Strategy `sendToVault` / `sendProfitToVault` |

**External dependencies (trusted externals)**

- **Corresponding CollateralVault**: trusted as the only caller of `onlyVault` functions (`deposit` / `writeoffPrincipal`), provider of push intake `receiveFromStrategy`, and reference source for AccessControl such as `ALLOCATOR_ROLE`. The canonical source for role definitions is [CollateralVault requirements](../CollateralVault.md) (role definitions).
- **External protocols** (Aave V3 / Sky USDS-sUSDS / Lido stETH + Withdrawal Queue / Etherfi eETH-weETH / Morpho / Euler, etc.): trusted interfaces for supply / stake / transform / withdraw. Smart-contract and economic attack risks are handled in §6 (shared risks) and child documents.
- **OpenZeppelin Contracts (upgradeable)**: `OwnableUpgradeable` / UUPS (Ownable and UUPS initialization and upgrade authorization for `BaseStrategy`).

**Assumptions**

- The Strategy Underlying matches the corresponding Vault Underlying. Vault `addStrategy` verifies on-chain that `strategy.underlying() == vault.underlying()` ([CollateralVault requirements](../CollateralVault.md) `addStrategy`).
- In the deployment direction, the Vault performs `safeTransfer` immediately **before** calling `deposit` (the Underlying is already in the Strategy balance when `deposit` is received).
- Of the currently registrable Strategies, Aave V3 / ERC-4626 / Sky USDC-sUSDS / Mock withdraw synchronously, while the Lido stETH and Etherfi weETH Strategies keep asynchronous withdrawal internal to the Strategy. All keep the same `IStrategy` surface and Vault registration interface ([STGY-ERR-002](#stgy-err-002-handling-asynchronous-external-protocols)).

---

## 4. Actors, Roles, and Trust Boundaries

Role definitions are canonically defined in [CollateralVault requirements](../CollateralVault.md) (role definitions). The operation permissions for an individual Strategy are summarized below:

| Actor | Operations | Trust boundary |
| --- | --- | --- |
| **Owner (Guardian multisig)** | `initialize` (once immediately after deployment) / `emergencyWithdraw` (rescue directly held funds to Vault) / `sweepRewardToken` (send non-Underlying, non-position rewards to Treasury) / `claimMerklRewards` (Merkl claim + fixed-destination settlement) / protocol-specific emergency recovery functions (`emergencyWithdrawFrom{Protocol}()`) / `transferOwnership` | Immediate emergency operator. Allowed operations are limited to fixed-destination fail-safes (return to Vault, settle Underlying rewards to Vault, or sweep ordinary rewards to Treasury). Must be multisig. Owner transfer is 2-step; `renounceOwnership` is disabled. Damage boundary: [STGY-SEC-002](#stgy-sec-002-owner-key-compromise-damage-boundary) |
| **upgrader (shared TimelockController)** | UUPS `upgradeTo` / `upgradeToAndCall` (`_authorizeUpgrade`) | Malicious implementation replacement through `upgradeTo` is the largest threat, so authorization is separated from Owner and the holder is the shared TimelockController (minDelay 12h). Reassigning upgrader can be done only by the upgrader itself (= through Timelock with delay), not by Owner (prevents invalidating separation; [STGY-FR-009](#stgy-fr-009-upgrades-uups)) |
| **pendingOwner** | `acceptOwnership` | Transfer candidate designated by Owner. Owner authority does not move until acceptance |
| **vault (corresponding CollateralVault)** | `deposit` (called by Vault from `allocate`) / `writeoffPrincipal` (called from `writeoffStrategyPrincipal`) = both `onlyVault` | Fully trusted. Fixed in `initialize` |
| **ALLOCATOR (Vault role)** | `sendToVault` / `sendProfitToVault` (calls Strategy directly; Strategy checks Vault AccessControl) | Funds are only **pushed to the Vault** and cannot be sent to arbitrary addresses. Damage boundary: [STGY-SEC-001](#stgy-sec-001-allocator-key-compromise-damage-boundary) |
| **WRITEOFF (Vault role)** | Async Strategy `setPendingWithdrawalValuationBps` (calls Strategy directly; Strategy checks Vault AccessControl and `pausedAllocation`) | Price-moving operation that can lower valuation for pending async withdrawals. Downward changes require `pausedAllocation == true`; restoration / upward changes do not require pause. It does not move funds, but it affects backing and is limited to the high-quorum immediate GOV multisig. Damage boundary: [STGY-SEC-004](#stgy-sec-004-conservative-accounting-against-aum-overvaluation) |
| **Anyone (permissionless)** | `principal` / `realizedYield` / `estimatedTotalUnderlying` / `underlying` (view) | No trust required |

- **Authorization separation**: ALLOCATOR can only trigger **push recovery** of principal/yield, with destination (Vault) and ratios pre-fixed. `deposit` (deployment into the external protocol) is limited to the Vault through `onlyVault`. Owner can rescue directly held funds to the Vault with `emergencyWithdraw`, but the destination is fixed to the Vault and there is no arbitrary `_to` ([STGY-SEC-003](#stgy-sec-003-emergencywithdraw-destination-fixed-to-vault)). `sweepRewardToken` sends only non-Underlying, non-position rewards to the Vault's current `treasury`. `claimMerklRewards` settles Underlying rewards to the Vault buffer, sends non-Underlying ordinary rewards to the Vault's current `treasury`, and rejects non-Underlying protocol position / receipt / accounting tokens before the Merkl distributor call. Async pending valuation markdown is gated by Vault `WRITEOFF_ROLE`, not Owner or ALLOCATOR, and downward markdown requires Vault `pausedAllocation`. UUPS upgrade is authorized only by the dedicated `upgrader`, not by Owner.

---

## 5. Interface Specification

Normative interface `IStrategy` (and abstract base `BaseStrategy`, UUPS standard). Behavior is specified in §6 Functional Requirements; visibility is summarized below (non-normative). Each Strategy implementation must satisfy all required methods in this table.

| Function | Visibility | Summary | Normative requirement |
| --- | --- | --- | --- |
| `deposit(uint256 _declaredAmount, uint256 _receivedAmount) -> uint256 deposited` | external (onlyVault) | Deposit the net receipt and return it; return 0 after exact recovery on rejection | STGY-FR-001 |
| `deployUnderlying(uint256 _amount)` | external (self-only) | Execute `_doDeposit` in an isolated call frame; external callers receive `Unauthorized` | STGY-FR-001 |
| `sendToVault(uint256 _amount) → uint256 sent` | external (ALLOCATOR) | Principal recovery push. `_doWithdraw` → `receiveFromStrategy` → subtract `principal` | STGY-FR-002 |
| `sendProfitToVault() → uint256 sent` | external (ALLOCATOR) | Directly push only realized yield to the Vault buffer. `principal` unchanged | STGY-FR-003 |
| `writeoffPrincipal(uint256 _amount) → uint256 writtenOff` | external (onlyVault) | Finalize principal impairment. `principal -= min(_amount, principal)` and return actual writeoff amount | STGY-FR-004 |
| `emergencyWithdraw(uint256 _amount)` | external (onlyOwner) | Rescue directly held funds to the Vault (destination fixed to Vault) | STGY-FR-005 |
| `sweepRewardToken(IERC20 token, uint256 amount) → uint256 swept` | external (onlyOwner) | Send non-Underlying, non-position rewards to the Vault's current Treasury | STGY-FR-010 |
| `claimMerklRewards(IMerklDistributor distributor, address[] tokens, uint256[] amounts, bytes32[][] proofs) → uint256[] settledAmounts` | external (onlyOwner) | Claim this Strategy's Merkl rewards and settle non-Underlying, non-position rewards to Treasury and Underlying rewards to the Vault | STGY-FR-012 |
| `principal() → uint256` | external view | Self-managed deployed principal | STGY-FR-008 |
| `realizedYield() → uint256` | external view | `max(estimatedTotalUnderlying - principal, 0)` | STGY-FR-008 |
| `estimatedTotalUnderlying() → uint256` | external view | Underlying valuation of assets managed in the external protocol (conservative) | STGY-FR-008 |
| `underlying() → address` | external view | Underlying address of this Strategy | STGY-FR-008 |
| `_doDeposit(uint256 amount)` | internal (hook, implemented by derived class) | supply / stake into external protocol | STGY-FR-006 |
| `_doWithdraw(uint256 amount) → uint256 actual` | internal (hook, implemented by derived class) | Withdraw from external protocol to the Strategy itself (return actual amount) | STGY-FR-006 |
| `_estimatedTotalUnderlying() → uint256` | internal (hook, implemented by derived class) | Convert external-protocol holdings to Underlying (conservative) | STGY-FR-006 |
| `__BaseStrategy_init(address _vault, address _underlying, address _owner, address _upgrader)` | internal (init) | Initialize Ownable/UUPS, zero / contract-code checks, `forceApprove(vault, max)`, and fixed upgrader | STGY-FR-007 |
| `initialize(...)` | external (initializer) | Derived class: BaseStrategy initialization + additional storage + prior approvals | STGY-FR-007 |
| `_authorizeUpgrade(address newImpl)` | internal (upgrader only) | UUPS authorization (upgrader = shared Timelock; separated from Owner) | STGY-FR-009 |
| `setUpgrader(address _newUpgrader)` | external (upgrader only) | Reassign upgrade authorization authority (nonzero required; emits `UpgraderUpdated`) | STGY-FR-009 |
| `pendingOwner()` / `transferOwnership(address)` / `acceptOwnership()` / `renounceOwnership()` | public | 2-step Owner transfer / disabled renounce | STGY-FR-011 |
| `emergencyWithdrawFrom{Protocol}()` | external (onlyOwner, derived-specific) | Withdraw recoverable funds from the external protocol and atomically push them to the Vault in the same tx. Account the Vault receipt as returned principal | STGY-FR-005 |

`emergencyWithdrawFrom{Protocol}` is specification-level abstract notation, not a common `IStrategy` function name. Implementations use derived Strategy-specific names, for example `emergencyWithdrawFromAave`, `emergencyWithdrawFromLido`, `emergencyWithdrawFromERC4626`, or `emergencyWithdrawFromSky`. Audit tooling and SPECA-style property mapping must not search for the abstract notation as a literal `emergencyFromProtocol` / `emergencyWithdrawFromProtocol` function.

### 5.1 Component Relationship (Reference Diagram)

```text
[Allocation] allocate (Vault -> Strategy)
  CollateralVault (per Underlying)
    │ 1. safeTransfer(strategy, amount)   (send Underlying from Vault to Strategy first)
    │ 2. strategy.deposit(declared, received)
    ▼
  IStrategy implementation (per Underlying, UUPS)
    │ 3. supply / stake in an external self-call frame
    │    reject -> inner-frame rollback -> exact recovery to Vault -> return 0
    ▼
  External protocol (Aave V3 / Lido stETH/WQ / Morpho / Euler / ...)

[Principal recovery] push (Strategy -> Vault)
  ALLOCATOR calls strategy.sendToVault(amount)
    │ 4. withdraw from external protocol (_doWithdraw, to Strategy itself)
    │ 5. vault.receiveFromStrategy(actual) (Vault pulls into buffer and reduces cache)
    ▼
  CollateralVault buffer

[Yield recovery] yield-only push (Strategy -> Vault)
  ALLOCATOR calls strategy.sendProfitToVault()
    │ 6. withdraw realized yield from external protocol (_doWithdraw, to Strategy itself)
    │ 7. Strategy direct safeTransfer to Vault buffer (principal / cache unchanged)
    ▼
  CollateralVault buffer
```

| Layer | Responsibility |
| --- | --- |
| CollateralVault | Decides allocation target and amount based on buffer / cap / weights (`allocate`). Transfers Underlying to Strategy (safeTransfer) and calls `deposit`. Provides principal-return push intake `receiveFromStrategy` (records actual receipt by balance delta; exact delivery reduces cache, mismatch invalidates it). Finalizes principal impairment through `writeoffStrategyPrincipal` |
| **Individual Strategy** | How to deposit, recover, and value received Underlying in one external protocol. Translation layer for external protocol interfaces. Principal recovery is Strategy-initiated and pushed to `receiveFromStrategy` (`sendToVault` / protocol-specific emergency recovery). Yield recovery is a direct transfer to the Vault buffer (`sendProfitToVault` / Underlying reward claims). Self-manages deployed principal `principal` |
| External protocol | Yield venue itself. The Strategy only calls its interface and does not know internal state |

---

## 6. Functional Requirements (FR)

> Accounting is based on the Strategy's self-managed `principal` and the external protocol valuation `estimatedTotalUnderlying()`, with `realizedYield() = max(estimatedTotalUnderlying() - principal, 0)`. The bodies of `deposit` / `sendToVault` / `sendProfitToVault` / `writeoffPrincipal` are provided by `BaseStrategy` ([STGY-FR-007](#stgy-fr-007-basestrategy-initialization-__basestrategy_init--derived-initialize)); derived classes implement only hooks (`_doDeposit` / `_doWithdraw` / `_estimatedTotalUnderlying`, [STGY-FR-006](#stgy-fr-006-derived-hooks-_dodeposit--_dowithdraw--_estimatedtotalunderlying)).

### STGY-FR-001: deposit (deposit into the external protocol)

- **Type**: Functional | **Source**: Product-Overview "Strategy Layer" / push model
- **Signature**: `deposit(uint256 _declaredAmount, uint256 _receivedAmount) returns (uint256 deposited)`
- **Purpose**: Called immediately **after** the Vault transfers Underlying to the Strategy through `safeTransfer` in `allocate()` ([CollateralVault requirements](../CollateralVault.md)); deposits the already received Underlying into the external protocol. BaseStrategy provides the body.
- **Permission**: `onlyVault` (any non-Vault caller reverts with `OnlyVault`).
- **Preconditions / Checks**: `caller == vault`. Underlying has already moved Vault -> Strategy before this call. `_declaredAmount` is the Vault-buffer debit; `_receivedAmount` is the Strategy's net balance-delta receipt.
- **Behavior / Effects**:
  1. Verify `onlyVault`
  2. If `_receivedAmount == 0`, return 0 without changes only when `_declaredAmount == 0`; otherwise revert with `DepositRecoveryFailed` so a burned or 100%-fee outbound transfer cannot be hidden as a skip
  3. Externally self-call self-only `deployUnderlying(_receivedAmount)`, which invokes `_doDeposit(_receivedAmount)` in that isolated frame
  4. On success, increase `principal` by `_receivedAmount`, emit `Deposited`, and return `_receivedAmount`
  5. On rejection, after the inner frame rolls back all effects, require `_declaredAmount == _receivedAmount`, snapshot Strategy and Vault balances, and transfer `_receivedAmount` directly back to the Vault. Return 0 only if both the Strategy decrease and Vault increase equal `_receivedAmount`
- **Reverts / early returns**: non-Vault -> `OnlyVault`; external `deployUnderlying` caller -> `Unauthorized`; `_declaredAmount == 0 && _receivedAmount == 0` -> 0; non-zero declared amount with zero receipt, any other declared/received mismatch during rejection recovery, return-transfer failure, or either balance-delta mismatch -> `DepositRecoveryFailed` and the outer allocation also reverts.
- **Emitted event**: `Deposited(uint256 amount, uint256 newPrincipal)` (STGY-EVT-001).
- **Design notes**: `principal` increases by the Strategy's net receipt, not an external-protocol observation. A rejection is never merely caught and left idle: EVM call-frame rollback plus sender/recipient balance deltas prove exact recovery. `Deposited` fires only on success; after return 0, the Vault emits `StrategyAllocationSkipped`. Allocation rules remain in the Vault ([CollateralVault requirements](../CollateralVault.md), allocation rules).
- **Verification**: unit (onlyVault, self-only executor, zero receipt no-op, principal increase, inner-state rollback, exact recovery, fail-closed with transfer fees), integration (allocate -> deposit and continuation past a failed Strategy).

### STGY-FR-002: sendToVault (principal recovery push)

- **Type**: Functional | **Source**: Product-Overview "push model" / [CollateralVault](../CollateralVault.md) redeem / rebalancing
- **Signature**: `sendToVault(uint256 _amount) returns (uint256 sent)`
- **Purpose**: Withdraw the requested amount from the external protocol and push it back to the Vault buffer through `receiveFromStrategy` ([CollateralVault requirements](../CollateralVault.md)). ALLOCATOR uses this for buffer replenishment for user redemption, rebalancing, and preprocessing before `removeStrategy`.
- **Permission**: Vault `ALLOCATOR_ROLE` (Strategy verifies through Vault AccessControl).
- **Preconditions / Checks**: Caller holds Vault `ALLOCATOR_ROLE`. cap / pause / cooldown do not apply to recovery direction (they apply only to deployment through `allocate()`). The ALLOCATOR authorization boundary is defined in [CollateralVault requirements](../CollateralVault.md).
- **Behavior / Effects**:
  1. **Role check**: verify caller holds Vault `ALLOCATOR_ROLE` (by reading Vault AccessControl). If not, revert with `Unauthorized`
  2. **Input check**: if `_amount == 0`, do nothing and return `0`
  3. **Withdraw from external protocol**: execute `_doWithdraw(_amount)` and obtain actual withdrawn amount `actual` (may be less than requested because of liquidity, etc.). If `actual == 0`, emit `SentToVault(_, _amount, 0, principal)` and return `0`
  4. **Push to Vault**: call `vault.receiveFromStrategy(actual)` and obtain the amount actually received by the Vault, `sent`
  5. **Subtract principal (principal-first)**: `principal -= min(sent, principal)`. Any part of `sent` above remaining `principal` is early yield recovery; it remains in the Vault buffer and becomes subject to `transferYieldToTreasury` ([CollateralVault requirements](../CollateralVault.md))
- **Reverts / early returns**:
  - `_amount == 0` → do nothing and return `0`
  - caller is not ALLOCATOR → revert with `Unauthorized`
  - `_doWithdraw` returns `0` (zero liquidity, etc.) → emit `SentToVault(_, _amount, 0, principal)` and return `0`
  - `receiveFromStrategy` reverts because the Strategy is not registered → propagate (normally does not occur because the Strategy is registered)
- **Emitted event**: `SentToVault(caller, requested, actual, newPrincipal)` (STGY-EVT-002) — `requested = _amount`; the `actual` field contains `sent`, the amount received by `receiveFromStrategy` (the Vault also emits `ReceivedFromStrategy`, see [CollateralVault requirements](../CollateralVault.md)).
- **Design notes**:
  - **Synchronous/asynchronous abstraction**: whether the external protocol is synchronous or asynchronous is internal to the Strategy implementation. There is no `requestKey` / `isAsyncWithdraw` branching ([STGY-ERR-002](#stgy-err-002-handling-asynchronous-external-protocols)).
  - **Principal subtraction is `sent`-based**: subtract by the amount actually received by the Vault, not by declared amount or `_doWithdraw` return value. This prevents drift between `principal` and the Vault buffer.
  - **cap is irrelevant**: this is recovery, not deployment, so no cap check is performed (cap applies only to Vault `allocate` deployment direction). Behavior when the requested amount exceeds AUM is implementation-dependent; synchronous Strategies such as AaveV3 may revert on the Aave side.
- **Examples**:
  - Strategy A (`principal = 1000`, `estimatedTotalUnderlying = 1050`), ALLOCATOR calls `A.sendToVault(100)`: `_doWithdraw(100)` withdraws 100 → `receiveFromStrategy(100)` increases Vault buffer by 100, `sent = 100` → `principal = 900`
  - Same Strategy, `A.sendToVault(1050)` (request full AUM): `_doWithdraw(1050)` → `receiveFromStrategy(1050)` with `sent = 1050` → `principal -= min(1050, 1000) = 1000` (`principal = 0`), excess 50 remains in the buffer as yield and becomes subject to `transferYieldToTreasury`
- **Verification**: unit (ALLOCATOR-only, `_amount==0` / `actual==0` early return, `sent`-based subtraction, principal-first), fork/integration (external protocol withdrawal → Vault receipt).

### STGY-FR-003: sendProfitToVault (yield-only push)

- **Type**: Functional | **Source**: Product-Overview "monetization" / [CollateralVault](../CollateralVault.md) harvest stage 1
- **Signature**: `sendProfitToVault() returns (uint256 sent)`
- **Purpose**: Push only the **realized yield** of this Strategy to the Vault buffer (stage 1 of Vault-side harvest; stage 2 `transferYieldToTreasury` is defined in [CollateralVault requirements](../CollateralVault.md)). No arguments; the Strategy computes `realizedYield()`.
- **Permission**: Vault `ALLOCATOR_ROLE`.
- **Preconditions / Checks**: caller holds Vault `ALLOCATOR_ROLE`.
- **Behavior / Effects**:
  1. **Role check**: if caller does not hold Vault `ALLOCATOR_ROLE`, revert with `Unauthorized`
  2. **Compute yield**: `yield = realizedYield() = max(estimatedTotalUnderlying() - principal, 0)`. If `yield == 0`, emit `ProfitSentToVault(_, 0, 0)` and return `0`
  3. **Withdraw**: execute `_doWithdraw(yield)` (if `actual == 0`, emit `ProfitSentToVault(_, yield, 0)` and return `0`)
  4. **Separate excess principal**: if `actual > yield`, push `actual - yield` through `receiveFromStrategy` and reduce principal by the actual Vault receipt. This is a principal return, not harvested yield. Limit the remaining yield-only amount to `yield`.
  5. **Yield-only push to Vault buffer**: the Strategy measures the Vault Underlying balance delta and `safeTransfer`s `min(actual, yield)` directly to the Vault. **The yield-only portion leaves `principal` unchanged**; any excess was accounted as a separate principal return. `receiveFromStrategy` is not used, so the Vault Strategy valuation cache is not reduced as a principal/cache-reducing return
  6. Emit `ProfitSentToVault(caller, yield, sent)` (STGY-EVT-003)
- **Reverts / early returns**: non-ALLOCATOR → `Unauthorized`; `yield == 0` → emit `ProfitSentToVault(_, 0, 0)` and return `0`; `actual == 0` → emit `ProfitSentToVault(_, yield, 0)` and return `0`.
- **Emitted event**: `ProfitSentToVault(address caller, uint256 yield, uint256 actual)` (STGY-EVT-003).
- **Design notes**: Keeping `principal` and the Vault Strategy valuation cache unchanged aligns with Vault conservative valuation (`totalUnderlying()` / the Strategy portion of `managedUnderlying` both use `min(estimatedTotalUnderlying, principal)`, see [CollateralVault requirements](../CollateralVault.md), accounting principles). If yield-only receipts went through `receiveFromStrategy`, fallback cache would be reduced as though principal/cache-reducing funds had returned, creating unnecessary conservative understatement during temporary live valuation failures. Over-sending yield is prevented both by the Strategy-side `realizedYield()` cap and the Vault-side `managedUnderlying` surplus + buffer cap (`transferYieldToTreasury`).
- **Verification**: unit (ALLOCATOR-only, `yield==0`/`actual==0` early return, `principal` unchanged), fork/integration (yield withdrawal → Vault receipt).

### STGY-FR-004: writeoffPrincipal (finalize principal impairment)

- **Type**: Functional | **Source**: [CollateralVault](../CollateralVault.md) `writeoffStrategyPrincipal`
- **Signature**: `writeoffPrincipal(uint256 _amount) returns (uint256 writtenOff)`
- **Purpose**: Called from Vault `writeoffStrategyPrincipal` ([CollateralVault requirements](../CollateralVault.md)) to ledger-writeoff principal that has become unrecoverable.
- **Permission**: `onlyVault` (through Vault `writeoffStrategyPrincipal`).
- **Preconditions / Checks**: `caller == vault`. Recoverable amounts are first returned to the Vault through `sendToVault` ([STGY-FR-002](#stgy-fr-002-sendtovault-principal-recovery-push)) / `emergencyWithdraw` ([STGY-FR-005](#stgy-fr-005-emergencywithdraw-rescue-directly-held-funds-to-vault)); **only the remaining unrecoverable amount** is written off.
- **Behavior / Effects**:
  1. Verify `onlyVault`
  2. `principal -= min(_amount, principal)` (overspecified amount is clamped to remaining `principal`)
  3. Return `writtenOff = min(_amount, oldPrincipal)`
  4. Emit `PrincipalWrittenOff(writtenOff, principal)` (STGY-EVT-004). `writtenOff` is the actual principal decrease, not the requested amount
- **Reverts / early returns**: non-Vault → `OnlyVault`. Even if `_amount > principal`, `principal` is clamped through `min` and cannot become negative (no revert).
- **Emitted event**: `PrincipalWrittenOff(uint256 amount, uint256 newPrincipal)` (STGY-EVT-004). `amount` is the actual writeoff amount.
- **Design notes**: This is **ledger-only** and does not move assets. Even if `_amount > principal`, `principal` is clamped to 0 ([STGY-INV-002](#stgy-inv-002)). If external protocol losses are not automatically reflected in `estimatedTotalUnderlying()`, Vault GOV can finalize the unrecoverable amount and call `writeoffStrategyPrincipal` to reflect the loss downward in dToken backing through the `principal` side.
- **Verification**: unit (onlyVault, `min` clamp, non-negative under overspecification), invariant=STGY-INV-002.

### STGY-FR-005: emergencyWithdraw (rescue directly held funds to Vault)

- **Type**: Functional | **Source**: [CollateralVault](../CollateralVault.md) emergency orchestration
- **Signature**: `emergencyWithdraw(uint256 _amount)`
- **Purpose**: Return Underlying that the Strategy **directly holds** instead of having deposited into the external protocol (stuck balance after emergency withdrawal, mistaken transfer, intermediate upgrade state, etc.) to the Vault. Vault-side orchestration (standard emergency flow) is defined in [CollateralVault requirements](../CollateralVault.md).
- **Permission**: Strategy Owner (`onlyOwner`).
- **Preconditions / Checks**: `caller == Owner`. The target is limited to rescuing accidental idle balances that should not appear during normal operation.
- **Behavior / Effects**:
  1. If `_amount == 0`, do nothing and return
  2. Call `ICollateralVault(vault).receiveFromStrategy(_amount)` so the Vault pulls the actual received amount through `safeTransferFrom` and accounts it into the buffer
  3. Emit `EmergencyWithdrawn(sent)` (STGY-EVT-005), where `sent` is the amount actually received by the Vault
- **Reverts / early returns**: non-Owner → revert; `_amount == 0` → no-op return.
- **Emitted event**: `EmergencyWithdrawn(uint256 amount)` (STGY-EVT-005).
- **Design notes**:
  - **Destination fixed to Vault**: there is no arbitrary `_to`. This blocks a path where the Strategy owner (which may be separate from the operations role) could remove Underlying to an arbitrary address without GOV approval ([STGY-SEC-003](#stgy-sec-003-emergencywithdraw-destination-fixed-to-vault)).
  - **`principal` is not reduced**: the Vault values Strategy holdings live with `min(estimatedTotalUnderlying, principal)`, and `estimatedTotalUnderlying` (for example, Aave self-scaled balance) represents only the external-protocol deposit. As long as live valuation is readable, pushing directly held funds to the Vault does not double-count. If unrecoverable principal remains, it is finalized by Vault `writeoffStrategyPrincipal` ([STGY-FR-004](#stgy-fr-004-writeoffprincipal-finalize-principal-impairment)).
  - **Relationship with Vault valuation cache**: `emergencyWithdraw` goes through `receiveFromStrategy`, so exact delivery reduces the cache by actual receipt and declared/received mismatch invalidates it. This keeps emergency idle-balance recovery on the same accounting path as normal Strategy pushes and avoids `buffer + ambiguous cache` overvaluation.
  - **Rescue cases**: (1) funds left at the Strategy address after a Vault `safeTransfer` when `deposit` was not called (Vault bug, operational mistake, or future path); (2) mistaken third-party transfer (ERC-20 transfer can increase the receiver's balance without consent); (3) intermediate state during upgrade where old implementation balances appear as directly held by the new implementation.
- **Relationship with withdrawing from the external protocol (atomic direct-push principle)**: protocol-specific functions that withdraw balances from the external protocol (`emergencyWithdrawFrom{Protocol}()`) should atomically push from the external protocol to the Vault in the same tx. Leaving withdrawn Underlying idle in the Strategy would create a **suspended** state where the funds are counted neither in `_estimatedTotalUnderlying` (idle excluded) nor in Vault buffer, potentially undervaluing `backingRatio` and causing improper liquidation. Protocol-specific functions therefore follow **external protocol → Vault atomic direct-push** (withdrawal and `receiveFromStrategy` push in the same tx; if the external side reverts, the whole transaction fails closed). AaveV3 is already unified into atomic direct-push in [AaveV3Strategy requirements](AaveV3Strategy.md) AAVE-FR-006. Because `receiveFromStrategy` accepts only Strategies still registered in the Vault (`strategies[]` remains), a removed Strategy will fail closed. If residual external-protocol funds are discovered after removal, recover by re-whitelisting → `addStrategy` (GOV=Timelock; 12h) → recovery. `emergencyWithdraw` remains for donation / residual accidental idle balances.
- **Verification**: unit (onlyOwner, `_amount==0` no-op, destination fixed to Vault, `principal` unchanged), integration (protocol-specific atomic direct-push and residual recovery via emergencyWithdraw).

### STGY-FR-010: sweepRewardToken (send non-Underlying, non-position rewards to Treasury)

- **Type**: Functional | **Source**: Prevent missed external protocol rewards (Aave incentives / Merkl, etc.)
- **Signature**: `sweepRewardToken(IERC20 _token, uint256 _amount) returns (uint256 swept)`
- **Purpose**: Send **non-Underlying and non-position ERC20 rewards** already received by the Strategy (Aave incentives / Merkl rewards / mistakenly transferred reward tokens, etc.) to the Vault's current `treasury`. This is separate from normal Underlying yield / principal recovery and is not mixed directly into backing accounting. Aave aToken, Morpho vault share, Euler eToken / vault share, and similar position / receipt / accounting tokens are Strategy claims, not rewards, and are excluded.
- **Permission**: Strategy Owner (`onlyOwner`).
- **Preconditions / Checks**:
  - `_token != address(0)` (otherwise `ZeroAddress`)
  - `_isSweepProtectedToken(address(_token)) == false` (otherwise `CannotSweepProtectedToken` for Underlying or derived Strategy protected position / receipt / accounting tokens)
  - `_amount == 0` is a no-op returning `0`. `_amount == type(uint256).max` means sweep the full balance of that reward token held by the Strategy
  - `ICollateralVault(vault).treasury() != address(0)` (otherwise `ZeroAddress`)
- **Behavior / Effects**:
  1. Read `recipient = ICollateralVault(vault).treasury()` (follows GOV `setTreasury` changes)
  2. Measure `recipient` `_token.balanceOf` before and after transfer
  3. If `_amount == type(uint256).max`, resolve `amount = _token.balanceOf(address(this))`
  4. Send reward token to Treasury through `_token.safeTransfer(recipient, amount)`
  5. Return `swept = max(balanceAfter - balanceBefore, 0)` (actual received amount for fee-on-transfer reward tokens)
  6. Emit `RewardTokenSwept(token, recipient, requested, swept)` (STGY-EVT-007). `requested` is the actual transferred `amount`, not `type(uint256).max`
- **Reverts / early returns**: non-Owner → revert; zero token / zero treasury → `ZeroAddress`; protected token → `CannotSweepProtectedToken`; `_amount == 0` or full-balance sweep with balance 0 → no transfer and return `0`.
- **Emitted event**: `RewardTokenSwept(address indexed token, address indexed treasury, uint256 requested, uint256 received)` (STGY-EVT-007).
- **Design notes**:
  - **Underlying / position tokens cannot be swept**: principal / Underlying yield is returned to Vault through `sendToVault` / `sendProfitToVault` / `emergencyWithdraw`. Protocol position tokens such as Aave aToken, Morpho vault shares, and Euler eToken / vault shares are converted back to Underlying through protocol-specific withdraw paths. Sending them directly to Treasury through `sweepRewardToken` would bypass Vault buffer / backing / `principal` accounting and is forbidden.
  - **Derived Strategy protected-token hook**: `BaseStrategy` treats Underlying as a default protected token. Derived Strategies override `_isSweepProtectedToken` to add protocol-specific position / receipt / accounting tokens. Aave must protect `aToken`; Morpho / Euler must protect the relevant market share / receipt token.
  - **Destination fixed to Treasury**: there is no arbitrary `_to`. Owner cannot redirect reward tokens to arbitrary addresses; the function follows the Vault `treasury` setting.
  - **Not automatically counted in backing**: non-Underlying, non-position reward tokens are excluded from `estimatedTotalUnderlying()` and are not automatically used to repair dToken backing. To repair backing, Treasury / backstop must separately convert rewards to Underlying and deposit explicitly, for example with `backstopDeposit`.
  - **Relationship with claims**: this function only sweeps reward tokens already received by the Strategy. Merkl's standard distributor claim is implemented by [STGY-FR-012](#stgy-fr-012-claimmerklrewards-merkl-reward-claim--sweep). After claim, non-Underlying rewards reuse `_sweepRewardToken`; Underlying rewards use `_sendUnderlyingToVault`. Aave RewardsController-specific claims, swaps, and backing repair remain separate designs.
- **Verification**: unit (onlyOwner, reject Underlying / position token, destination fixed to current treasury, fee-on-transfer actual amount, `_amount==0` no-op, `type(uint256).max` full sweep).

### STGY-FR-012: claimMerklRewards (Merkl reward claim + sweep)

- **Type**: Functional / Security | **Source**: capturing external distributor rewards such as Merkl
- **Signature**: `claimMerklRewards(IMerklDistributor _distributor, address[] calldata _tokens, uint256[] calldata _amounts, bytes32[][] calldata _proofs) returns (uint256[] settledAmounts)`
- **Purpose**: Claim this Strategy's rewards from a Merkl distributor, sweep non-Underlying, non-position reward tokens to the Vault's current `treasury`, and push Underlying rewards to the Vault buffer as yield. The reward claim and settlement accounting boundary stays in `BaseStrategy`, without arbitrary calldata, arbitrary recipients, or position-token movement.
- **Permission**: Strategy Owner (`onlyOwner`).
- **Preconditions / Checks**:
  - `_distributor != address(0)` (otherwise `ZeroAddress`)
  - `_distributor.code.length != 0` (otherwise `InvalidMerklDistributor` for EOAs / undeployed addresses)
  - `_tokens.length > 0` and `_tokens.length == _amounts.length == _proofs.length` (otherwise `InvalidMerklClaim`)
  - `_tokens.length <= MAX_MERKL_TOKENS_PER_CLAIM` (implementation constant is `16`; otherwise `TooManyMerklTokens(tokenCount, maxTokenCount)`)
  - each `_tokens[i] != address(0)` (otherwise `ZeroAddress`)
  - `_tokens` must not contain duplicates (otherwise `DuplicateMerklToken(token)`)
  - Underlying is allowed. For non-Underlying tokens, `_isSweepProtectedToken(token) == true` position / receipt / accounting tokens fail fast with `CannotSweepProtectedToken` before the distributor call
- **Behavior / Effects**:
  1. Build a `users` array where every element is `address(this)` (claim recipient fixed to the Strategy)
  2. Record each token balance before the claim
  3. Call `_distributor.claim(users, _tokens, _amounts, _proofs)`. Only Merkl's standard `claim` selector is used; the function does not accept arbitrary calldata or recipients
  4. If the token is Underlying, push only the balance delta to the Vault buffer through `_sendUnderlyingToVault` and emit `MerklUnderlyingRewardsClaimed(distributor, token, cumulativeAmount, sentToVault)`
  5. If the token is not Underlying, call `_sweepRewardToken(IERC20(token), type(uint256).max)` to send the Strategy's full remaining balance of that reward token to Treasury, emitting `RewardTokenSwept` and `MerklRewardsClaimed(distributor, token, cumulativeAmount, swept)`
- **Reverts / early returns**: non-Owner -> revert; invalid distributor / arrays / token / duplicate token / protected token -> errors above; invalid Merkl proof or distributor failure -> distributor revert propagates; zero Treasury or token transfer failure -> `_sweepRewardToken` revert propagates.
- **Emitted events**: `RewardTokenSwept` for non-Underlying token sweeps, `MerklRewardsClaimed(address indexed distributor, address indexed token, uint256 cumulativeAmount, uint256 swept)`, and `MerklUnderlyingRewardsClaimed(address indexed distributor, address indexed token, uint256 cumulativeAmount, uint256 sentToVault)` (STGY-EVT-010).
- **Design notes**:
  - **Recipient fixed**: `users[i] = address(this)` prevents using the Strategy as an arbitrary Merkl claim router for other users or recipients.
  - **Underlying rewards go to the Vault buffer**: Underlying rewards are not swept to Treasury. They are pushed to the Vault buffer as yield and do not change `principal`, keeping Morpho / Euler / Merkl-style Underlying rewards inside the backing-accounting boundary.
  - **Position tokens rejected before claim**: if position / receipt / accounting tokens are claimed into the Strategy, they fall outside both Treasury sweep and normal backing accounting. The generic claim path therefore fails before the distributor call. Any exceptional protected-token distribution must use a separate runbook and Vault recovery path.
  - **Non-Underlying rewards are not automatically counted in backing**: non-Underlying reward tokens remain outside `estimatedTotalUnderlying()` / `principal` / Vault buffer. If they are used for backing repair, Treasury / backstop must convert them to Underlying and explicitly deposit them, for example through `backstopDeposit`.
- **Verification**: unit (onlyOwner, distributor code check, array length check, recipient fixed, duplicate token rejection, position-token pre-claim rejection, Underlying reward Vault push, Treasury actual receipt, fee-on-transfer reward token).

### STGY-FR-006: derived hooks (`_doDeposit` / `_doWithdraw` / `_estimatedTotalUnderlying`)

- **Type**: Functional | **Source**: Product-Overview "Strategy Layer" / external protocol translation layer
- **Signature**: `_doDeposit(uint256 amount)` / `_doWithdraw(uint256 amount) → uint256 actual` / `_estimatedTotalUnderlying() → uint256` (all internal hooks implemented by derived classes)
- **Purpose**: Translation points to the external protocol interface. BaseStrategy bodies (`deposit` / `sendToVault` / `sendProfitToVault`) call these hooks, localizing protocol-specific differences.
- **Permission**: internal (called from BaseStrategy bodies; not externally callable).
- **Preconditions / Checks**: required prior approvals for each derived implementation (for supply to external protocol) are completed ([STGY-FR-007](#stgy-fr-007-basestrategy-initialization-__basestrategy_init--derived-initialize)).
- **Behavior / Effects**:
  1. `_doDeposit(amount)`: deposit Underlying into the external protocol (for example, `aavePool.supply(...)`)
  2. `_doWithdraw(amount) → actual`: for normal recovery and yield recovery, withdraw Underlying from the external protocol to the **Strategy itself**. BaseStrategy then routes principal/cache-reducing returns through `receiveFromStrategy` and yield-only returns through a direct transfer to the Vault buffer. Return actual withdrawn amount, which may be less than requested. **For asynchronous external protocols, return only the amount immediately withdrawable at that time** ([STGY-ERR-002](#stgy-err-002-handling-asynchronous-external-protocols))
  3. `_estimatedTotalUnderlying() → uint256`: return the Strategy's own holdings in the external protocol converted to Underlying (conservative valuation). This is not the dToken JPY-denominated price; it is the input used by the Vault to compare `A` and `L_effective` in the same Underlying units
- **Reverts / early returns**: external protocol interface failures may propagate (for example, if requested amount exceeds AUM, the external protocol may revert; see design notes in [STGY-FR-002](#stgy-fr-002-sendtovault-principal-recovery-push)).
- **Emitted events**: hooks themselves do not emit shared events (the calling BaseStrategy body emits STGY-EVT-001..003). Protocol-specific emergency recovery functions (`emergencyWithdrawFrom{Protocol}()`, `onlyOwner`, external protocol withdrawal and atomic direct-push to Vault as in [STGY-FR-005](#stgy-fr-005-emergencywithdraw-rescue-directly-held-funds-to-vault)) should emit derived-specific `Emergency*Withdrawn(uint256 amount)` events ([STGY-EVT-006](#11-events-and-monitoring-requirements-evt)).
- **Design notes**: each derived Strategy implements only (1) additional storage (protocol-specific addresses such as Pool / Adapter), (2) `initialize` (BaseStrategy initialization + additional storage + prior approvals), (3) the three hooks above, and (4) protocol-specific emergency recovery functions if needed. Bodies of `deposit` / `sendToVault` / `sendProfitToVault` / `writeoffPrincipal` are provided by BaseStrategy. Because `_estimatedTotalUnderlying` depends on protocol accounting, protocols with loss, slashing, withdrawal penalties, etc. must implement it without overvaluation. Example: AaveV3Strategy caps self-managed scaled balance by actual Aave-side scaled balance and multiplies by normalized income, excluding third-party donations while reflecting Aave-side balance decreases.
- **Verification**: integration/fork (each child document verifies mapping to external protocol interfaces; for example [AaveV3Strategy requirements](AaveV3Strategy.md)), unit (conservative valuation and `actual` return).

### STGY-FR-007: BaseStrategy initialization (`__BaseStrategy_init` / derived `initialize`)

- **Type**: Functional | **Source**: Product-Overview "Strategy Layer (UUPS)" / push-model approval direction
- **Signature**: `__BaseStrategy_init(address _vault, address _underlying, address _owner, address _upgrader)` (internal) / derived `initialize(...)` (external initializer)
- **Purpose**: Initialize the Strategy through a UUPS proxy and establish shared storage, Ownable, UUPS, and push-model approval.
- **Permission**: part of the deployment procedure (proxy initialization). `_owner` binds Owner (Guardian multisig; [STGY-GOV-001](#stgy-gov-001-owner-and-upgrader-holder-configuration)).
- **Preconditions / Checks**: `_vault` / `_underlying` / `_owner` / `_upgrader` are nonzero. `_vault` and `_underlying` are deployed contracts. Multiple initialization is not allowed (initializer).
- **Preconditions / Checks** (`__BaseStrategy_init`):
  - `_vault != address(0)`
  - `_underlying != address(0)`
  - `_owner != address(0)`
  - `_upgrader != address(0)`
  - `_vault.code.length != 0`
  - `_underlying.code.length != 0`
  - Derived `initialize` rejects zero and undeployed external protocol dependencies such as Aave Pool / aToken, ERC-4626 vault, Lido stETH / wstETH / Withdrawal Queue, Etherfi LiquidityPool / eETH / weETH / WithdrawAdapter / WithdrawRequestNFT, and Sky USDS / sUSDS vault / converter.
- **Behavior / Effects** (`__BaseStrategy_init`):
  1. Initialize OZ Ownable / UUPS
  2. Perform zero-address / contract-code checks
  3. Save shared storage (`vault` / `underlyingToken` / `_principal`)
  4. Transfer ownership to `_owner` = Owner (Guardian multisig)
  5. `underlying.forceApprove(vault, type(uint256).max)` (**approve the Vault**). This lets `receiveFromStrategy` collect Underlying from the Strategy through `safeTransferFrom` (push model: approval direction is Strategy → Vault)
  6. Derived `initialize` then sets additional storage and prior approval for external-protocol supply
- **Reverts / early returns**: zero address → revert; EOA / undeployed contract → `NotContract(target)`; reinitialization → revert.
- **Emitted events**: none specific to initialization. Operational events are STGY-EVT-001..005.
- **Design notes**: BaseStrategy provides shared storage, the `onlyVault` modifier (revert non-Vault with `OnlyVault`), the `ALLOCATOR_ROLE` guard for `sendToVault` / `sendProfitToVault` (through `onlyVaultRole(role)` reading Vault AccessControl), a local `nonReentrantStrategy` guard for entry points that make external calls, the bodies of `deposit` / `sendToVault` / `sendProfitToVault` / `writeoffPrincipal`, view getters (`underlying()` / `principal()` / `realizedYield()` / `estimatedTotalUnderlying()`, with `realizedYield = max(estimatedTotalUnderlying - principal, 0)`), `emergencyWithdraw`, `_authorizeUpgrade`, and `setUpgrader`. Derived classes implement only hooks and protocol-specific items.
- **Verification**: unit (zero-address revert, EOA / undeployed contract revert, reinitialization revert, ownership transfer, upgrader saved, `forceApprove(vault, max)`, nested guarded entry reverts with `ReentrantCall`), manual (deployment configuration review).

### STGY-FR-008: view getters (principal / realizedYield / estimatedTotalUnderlying / underlying)

- **Type**: Functional | **Source**: [CollateralVault](../CollateralVault.md) solvency valuation / subgraph
- **Signature**: `principal() → uint256` / `realizedYield() → uint256` / `estimatedTotalUnderlying() → uint256` / `underlying() → address` (all external view)
- **Purpose**: Provide read interfaces used for Vault solvency valuation, allocate ratio calculation, yield determination, subgraph AUM history, and on-chain Underlying consistency checks.
- **Permission**: none (external view; permissionless).
- **Preconditions / Checks**: none.
- **Behavior / Effects**: no state change (view).
  - `principal()`: returns deployed principal self-managed by this Strategy. Used by Vault `removeStrategy` (`principal == 0` and live `estimatedTotalUnderlying() == 0` required) and solvency valuation (`min(estimatedTotalUnderlying, principal)`)
  - `realizedYield()`: returns `max(estimatedTotalUnderlying() - principal, 0)`. Withdrawal cap for `sendProfitToVault`
  - `estimatedTotalUnderlying()`: returns the Underlying-denominated valuation of the Strategy-managed assets (conservative). Not a price oracle. Used for Vault allocate ratio calculation / yield determination / subgraph AUM history / dToken backing `A = totalUnderlying()`
  - `underlying()`: returns the Underlying address of this Strategy. Vault `addStrategy` verifies on-chain that `strategy.underlying() == vault.underlying()` ([CollateralVault requirements](../CollateralVault.md) `addStrategy`). Also used for subgraph labeling
- **Reverts / early returns**: not applicable (view).
- **Emitted events**: none (view).
- **Design notes**: provided by BaseStrategy. If `estimatedTotalUnderlying()` is overvalued, it can over-send yield; the Vault applies layered defenses with `min(estimatedTotalUnderlying, principal)` conservative valuation + `realizedYield()` cap + buffer cap ([STGY-SEC-004](#stgy-sec-004-conservative-accounting-against-aum-overvaluation)).
- **Verification**: unit (`realizedYield` calculation and conservative valuation), integration (Vault `addStrategy` Underlying match verification).

### STGY-FR-009: upgrades (UUPS)

- **Type**: Functional | **Source**: Product-Overview "Strategy Layer (UUPS)"
- **Signature**: `_authorizeUpgrade(address newImpl)` (internal UUPS authorization) / `setUpgrader(address _newUpgrader)`. Externally through UUPS `upgradeTo` / `upgradeToAndCall`.
- **Purpose**: Allow future logic replacement through UUPS to fix external-protocol translation, accounting, etc.
- **Permission**: new implementation approval is **only** by the dedicated `upgrader` (holder = shared TimelockController, minDelay 12h). Owner (Guardian multisig) and operational roles (vault / ALLOCATOR, etc.) cannot authorize upgrades (finalized 2026-06-12: `_authorizeUpgrade` is separated from Owner to combine Owner's immediate emergency authority with delayed upgrade control. One variable is allocated from `__gap`).
- **Preconditions / Checks**: `_authorizeUpgrade` / `setUpgrader` require `caller == upgrader`. `setUpgrader` requires `_newUpgrader != address(0)`.
- **Behavior / Effects**:
  1. `_authorizeUpgrade` verifies `msg.sender == upgrader` and replaces the implementation address (UUPS)
  2. `setUpgrader` can be called only by the current `upgrader`; it saves `_newUpgrader` and emits `UpgraderUpdated(oldUpgrader, newUpgrader)`
  3. Emit ERC1967 `Upgraded(newImpl)`
- **Reverts / early returns**: upgrade / `setUpgrader` by non-upgrader (including Owner) → revert. `setUpgrader(address(0))` → `ZeroAddress`.
- **Emitted events**: ERC1967 `Upgraded(newImpl)`, `UpgraderUpdated(oldUpgrader, newUpgrader)`.
- **Design notes**: malicious implementation replacement through `upgradeTo` is the largest threat. Authorization is placed on a dedicated `upgrader` separated from Owner, with the holder set to the shared TimelockController (12h). **Reassigning upgrader can be done only by the upgrader itself (= through Timelock; 12h), not by Owner**; otherwise Owner could set upgrader to itself and invalidate separation ([STGY-SEC-002](#stgy-sec-002-owner-key-compromise-damage-boundary) / [STGY-GOV-003](#stgy-gov-003-upgrader-timelock)). Because deployment is fresh, `upgrader` must always be initialized in `__BaseStrategy_init`; there is no backward-compatible migration entry point for old proxies.
- **Verification**: unit (upgrader-only authorization, Owner / operational roles revert, only upgrader can reassign upgrader), manual (storage layout review).

### STGY-FR-011: Owner transfer (2-step) and disabled renounce

- **Type**: Functional / Security | **Source**: mainnet authorization operations and consistency with dToken / Oracle ownership policy
- **Signature**: `pendingOwner() → address` / `transferOwnership(address newOwner)` / `acceptOwnership()` / `renounceOwnership()`
- **Purpose**: Strategy Owner has strong authority over emergency recovery, reward sweep, and ownership operations. One-step transfer to the wrong address or ownership renounce must not lose rescue paths. Owner transfer requires explicit acceptance by the candidate, and Owner renounce reverts in code. UUPS upgrade is handled by `upgrader`, not Owner.
- **Permission**:
  - `transferOwnership`: current Owner only
  - `acceptOwnership`: `pendingOwner` only
  - `renounceOwnership`: callable only by current Owner but always reverts
- **Behavior / Effects**:
  1. `transferOwnership(newOwner)` saves `_pendingOwner = newOwner` and emits `OwnershipTransferStarted(owner, newOwner)`. `newOwner == address(0)` is treated as cancellation of the pending transfer
  2. `acceptOwnership()` transfers `owner = pendingOwner` and clears `pendingOwner` (emits OZ `OwnershipTransferred`)
  3. `renounceOwnership()` reverts with `RenounceOwnershipDisabled` and preserves Owner
- **Design notes**: `_pendingOwner` is added by consuming one slot from BaseStrategy's own storage gap. Existing `OwnableUpgradeable` inheritance order is unchanged, and existing storage slots are not moved.
- **Verification**: unit (2-step transfer, pending cancel, non-pending accept revert, renounce disabled, zero owner init revert).

---

## 7. State Variables and Accounting Model

| Variable | Type | Description | Finalization |
| --- | --- | --- | --- |
| `vault` | `address` | Corresponding CollateralVault used for `onlyVault` checks, push destination, and AccessControl reference | Fixed in `__BaseStrategy_init` |
| `underlyingToken` | `address` | Underlying of this Strategy | Fixed in `__BaseStrategy_init` |
| `_principal` | `uint256` | Self-managed deployed principal (ledger value) | Increased by `deposit`; decreased by `sendToVault` / protocol-specific returned principal / `writeoffPrincipal` |
| `_pendingOwner` | `address` | Candidate for 2-step Owner transfer | `transferOwnership` / `acceptOwnership` |
| `upgrader` | `address` | UUPS upgrade authorization authority. Separated from Owner | `__BaseStrategy_init` / `setUpgrader` |
| `_reentrancyStatus` | `uint256` | Local reentrancy guard state for Strategy entry points | `nonReentrantStrategy` (one slot consumed from BaseStrategy's storage gap) |
| External-protocol-specific addresses | (derived) | Pool / Adapter / aToken, etc. | Derived `initialize` |

**Accounting model**: the Strategy self-manages deployed principal `principal` and derives `realizedYield() = max(estimatedTotalUnderlying() - principal, 0)` from the relationship with the external protocol valuation `estimatedTotalUnderlying()`.

- **`principal` changes**: `deposit` increases by "the amount sent by the Vault" (not an external observed value). `sendToVault` subtracts "the `sent` amount actually received by the Vault" by `min(sent, principal)` (principal-first). `writeoffPrincipal` subtracts `min(_amount, principal)`. `sendProfitToVault` / `emergencyWithdraw` / `sweepRewardToken` / `claimMerklRewards` do not change it.
- **Early yield recovery**: when `sent` from `sendToVault` exceeds remaining `principal`, the excess is yield. It remains in the Vault buffer and becomes subject to `transferYieldToTreasury`.
- **Consistency with conservative valuation**: the Vault values Strategy holdings as `min(estimatedTotalUnderlying, principal)`. `sendProfitToVault` not changing `principal` and `emergencyWithdraw` moving only directly held assets outside `estimatedTotalUnderlying` are consistent with this conservative valuation without double-counting.
- **Non-Underlying, non-position rewards are outside accounting**: reward tokens such as Aave incentives or Morpho/Euler Merkl are excluded from `estimatedTotalUnderlying()` and dToken backing. If received by the Strategy, they are sent to Treasury by `sweepRewardToken`. Unclaimed Merkl rewards can be claimed by `claimMerklRewards`: Underlying rewards are pushed to the Vault buffer as yield, while non-Underlying, non-position rewards are swept to Treasury. Backing repair with non-Underlying rewards must be explicit, for example by converting to Underlying and using `backstopDeposit`. Protocol position / receipt / accounting tokens are not reward tokens and must be rejected by derived Strategy protected-token hooks before sweep or claim.

---

## 8. Invariants (INV)

| ID | Invariant | Verification |
| --- | --- | --- |
| STGY-INV-001 | `deposit` / `writeoffPrincipal` can be executed only by `vault`; `sendToVault` / `sendProfitToVault` can be executed only by a holder of the Vault `ALLOCATOR_ROLE` (missing authorization reverts with `OnlyVault` / `Unauthorized`) | invariant |
| STGY-INV-002 | `principal` never becomes less than `0` (`sendToVault` clamps with `min(sent, principal)`; `writeoffPrincipal` clamps with `min(_amount, principal)`) | invariant |
| STGY-INV-003 | `sendProfitToVault` and `emergencyWithdraw` do not change `principal` (yield push and directly held fund rescue do not affect the principal ledger) | invariant |
| STGY-INV-004 | `realizedYield() == max(estimatedTotalUnderlying() - principal, 0)` (identity) | unit |
| STGY-INV-005 | `principal` subtraction is based on the Vault actual received amount `sent`, not the declared amount, so it does not create drift between `principal` and Vault buffer | invariant |
| STGY-INV-006 | `underlying()` for one Strategy instance is immutable and matches the corresponding Vault Underlying (verified by Vault `addStrategy`) | invariant |
| STGY-INV-007 | `vault` / `underlyingToken` are immutable after `__BaseStrategy_init` | invariant |
| STGY-INV-008 | `sweepRewardToken` rejects Underlying and position / receipt / accounting tokens protected by the derived Strategy. `claimMerklRewards` allows Underlying only as Vault-buffer yield settlement and rejects non-Underlying protected tokens before claim. Neither path changes `principal` / `estimatedTotalUnderlying`; non-Underlying, non-position rewards are sent to Treasury outside backing accounting | unit |
| STGY-INV-009 | Owner changes only when `acceptOwnership` succeeds, and does not change through `renounceOwnership` | unit |
| STGY-INV-010 | UUPS upgrades can be authorized only by `upgrader`, not by Owner / ALLOCATOR / vault. `upgrader` cannot be set to the zero address | unit |
| STGY-INV-011 | Strategy entry points protected by `nonReentrantStrategy` cannot be executed nested in the same tx; a callback from an external protocol / token into another guarded entry point reverts with `ReentrantCall` | unit |

---

## 9. Security Requirements (SEC)

### STGY-SEC-001: ALLOCATOR key compromise damage boundary

- Type: Security
- Statement: ALLOCATOR can directly call Strategy `sendToVault` / `sendProfitToVault`, but both only **push funds to the Vault** and cannot send funds to arbitrary addresses. `deposit` (deployment into external protocol) must be limited to the Vault through `onlyVault`, and destinations/ratios must be pre-fixed.
- Verification: unit (ALLOCATOR cannot send to arbitrary addresses; `deposit` is onlyVault), manual

### STGY-SEC-002: Owner key compromise damage boundary

- Type: Security
- Statement: Owner can use `emergencyWithdraw` to send directly held Strategy Underlying **to the Vault** (destination fixed to Vault; no arbitrary `_to`). The target is limited to rescuing accidental idle balances that should not appear in normal operation. Owner can also sweep / claim non-Underlying, non-position rewards, but the destination is fixed to the Vault's current Treasury and protected tokens are rejected before claim. Malicious implementation replacement through `upgradeTo` is the largest threat, and the authorization must be held by a dedicated `upgrader` separated from Owner (holder = shared TimelockController; 12h). As a result, even if the Owner (Guardian multisig) key is compromised, possible actions are limited to fixed routes: returning funds to Vault, settling Underlying rewards to the Vault, and sweeping ordinary rewards to Treasury; logic replacement and backing markdown are not possible. Emergency recovery remains on the immediate Owner side, so the timelock does not enlarge emergency-response damage (no emergency bypass needed).
- Verification: unit (emergencyWithdraw destination fixed; Owner cannot upgrade; Owner cannot change async pending valuation), manual (multisig / Timelock operations review)

### STGY-SEC-003: emergencyWithdraw destination fixed to Vault

- Type: Security
- Statement: `emergencyWithdraw` must fix the destination to the Vault and must not have an arbitrary `_to`. This blocks a route where the Strategy owner (which may be separated from operational roles) could extract Underlying to an arbitrary address without GOV approval.
- Verification: unit (cannot send to arbitrary address; destination is Vault only)

### STGY-SEC-004: conservative accounting against AUM overvaluation

- Type: Security
- Statement: To prevent over-sending yield due to overvaluation in `estimatedTotalUnderlying()`, valuation must be conservative. The Vault must defend in layers with `min(estimatedTotalUnderlying, principal)` conservative valuation, `realizedYield()` cap for yield transfer, and `managedUnderlying` surplus + buffer cap (`transferYieldToTreasury`).
- In `AsyncRequestStrategy` implementations, `setPendingWithdrawalValuationBps` affects Vault conservative valuation / backing for pending async withdrawals. It is therefore gated by the Vault's `WRITEOFF_ROLE`, not Strategy Owner or ALLOCATOR. Downward changes additionally require `pausedAllocation == true` and must be paired with incident logs, bot pause checks, and finalization evidence.
- Verification: unit (conservative valuation; pending valuation bps requires WRITEOFF_ROLE; downward changes require allocation pause), integration (cannot over-send yield)

### STGY-SEC-005: liquidity shortage treated as normal path (DoS resistance)

- Type: Security
- Statement: `sendToVault` must push only the amount the external protocol can return (`actual`) and treat less than requested (including `actual==0`) as a normal path. One unhealthy Strategy must not stop overall recovery (`bufferTargetBps` / `bufferFloor` maintain inventory). This "do not treat illiquidity as loss" principle is also the basis for [`ADR-006`](../../architecture/Architecture-Decision-Records.md#adr-006) backing-impairment behavior. Clamp-style Strategies satisfy the no-revert requirement by pushing only externally returnable amounts: ERC4626 uses conservative `maxWithdraw` / `convertToAssets`, while AaveV3 caps `_doWithdraw` to `min(requested amount, Aave accounting value, aToken liquid underlying)` and returns partial / `0` ([AAVE-FR-004](AaveV3Strategy.md)). Revert propagation is limited to fail-closed cases such as reserve `paused` / complete Aave stoppage ([AAVE-ERR-002](AaveV3Strategy.md) / [AAVE-ERR-003](AaveV3Strategy.md)); system-wide recovery continuity is provided by per-Strategy separation plus buffer.
- Verification: unit (`actual<requested` / `actual==0` does not revert), integration (one unhealthy Strategy does not stop the whole system)

### STGY-SEC-006: accounting boundary for non-Underlying, non-position reward sweep

- Type: Security
- Statement: `sweepRewardToken` must reject Underlying and protocol position / receipt / accounting tokens, and must fix the destination to the Vault's current `treasury`. `claimMerklRewards` must fix the recipient to the Strategy itself, must not accept arbitrary calldata or recipients, must settle Underlying rewards only to the Vault buffer, must settle non-Underlying rewards only to the Vault's current `treasury`, and must reject non-Underlying protected position / receipt / accounting tokens before claim. Non-Underlying, non-position reward tokens must not be automatically counted in dToken backing / `estimatedTotalUnderlying` / `principal`; if used for backing repair, Treasury / backstop must convert them to Underlying and replenish explicitly.
- Verification: unit (sweep rejects Underlying / position token, fixed Treasury destination, fee-on-transfer actual amount, fixed Merkl recipient, protected-token pre-claim rejection, Underlying reward Vault push), manual (accounting review when adding reward claim / swap adapters)

### STGY-SEC-007: prevent Owner authority loss

- Type: Security
- Statement: Owner transfer must be 2-step so emergency recovery, reward sweep, and ownership authority are not lost through a mistaken one-step transfer to a wrong address. `renounceOwnership` must always revert to prevent permanently losing rescue paths.
- Verification: unit (2-step transfer, renounce disabled, zero owner init revert)

### STGY-SEC-008: Upgrader key compromise damage boundary

- Type: Security
- Statement: UUPS upgrade can be authorized only by `upgrader`; Owner / ALLOCATOR / vault must not be able to execute it. If the `upgrader` key is compromised, malicious implementation replacement becomes possible, so `upgrader` must be held by a multisig or external TimelockController / Safe module separated from Owner. `setUpgrader` can be executed only by the current `upgrader`, and updating to zero address is forbidden.
- Verification: unit (only upgrader can upgrade / setUpgrader; zero upgrader reverts), manual (upgrader operations review)

> **reentrancy / CEI**: BaseStrategy does not inherit OZ `ReentrancyGuardUpgradeable`; instead it stores a local `_reentrancyStatus` after existing storage (one slot from the gap) and uses `nonReentrantStrategy` to protect shared mutating entry points (`deposit` / `sendToVault` / `sendProfitToVault` / `writeoffPrincipal` / `emergencyWithdraw` / `sweepRewardToken` / `claimMerklRewards`). Derived Strategies apply the same guard to public entry points that call external protocols, tokens, or reward claimers. Vault `receiveFromStrategy` remains protected by Vault-side `nonReentrant`, actual-received accounting, and exact-delivery cache reduction / mismatch cache invalidation. `sendProfitToVault` and Underlying reward claims are yield-only direct transfers into the Vault buffer and do not move principal / cache as principal returns.

---

## 10. Governance, Operations, and Upgrade Requirements (GOV)

### STGY-GOV-001: Owner and upgrader holder configuration

- Statement (revised 2026-06-12): Owner (authority for `emergencyWithdraw` / protocol-specific emergency recovery / reward sweep / ownership operations) must be **Guardian multisig (immediate multisig)**, and UUPS upgrade authorization (`upgrader`) must be separated from Owner and held by the **shared TimelockController (12h)** ([STGY-FR-009](#stgy-fr-009-upgrades-uups) / [STGY-GOV-003](#stgy-gov-003-upgrader-timelock)). Single EOAs are forbidden for both.
- Verification: manual (deployment configuration review; assert Owner / upgrader holder)

### STGY-GOV-004: Owner transfer and renounce

- Statement: Owner transfer is performed in 2 steps (`transferOwnership` → `acceptOwnership`). If the wrong address is specified, pending transfer can be canceled with `transferOwnership(address(0))`. Owner renounce is disabled with `RenounceOwnershipDisabled`.
- Verification: unit, manual

### STGY-GOV-002: emergency operations

- Statement: If an external protocol smart-contract / economic attack is suspected, GUARDIAN must be able to stop new deployment into the Strategy through Vault `emergencyDisableStrategy` (immediate; [CollateralVault requirements](../CollateralVault.md) VAULT-FR-019), and Owner (Guardian multisig) must be able to move funds to the Vault through a protocol-specific emergency recovery function (`emergencyWithdrawFrom{Protocol}()` with atomic direct-push to Vault). Residual idle funds are recovered through `emergencyWithdraw`. Concentrated deployment is avoided by Vault-side `cap`.
- Verification: manual (emergency runbook review), integration (updateStrategy → emergency recovery)

### STGY-GOV-003: Upgrader timelock

- Statement (finalized 2026-06-12): the Strategy itself does not include an embedded timelock. **UUPS upgrade authorization (`upgrader`) is separated from Owner, and the holder is the shared TimelockController (minDelay = 12h; PROPOSER/EXECUTOR = GOV multisig; CANCELLER = the same Admin multisig as PROPOSER / EXECUTOR [updated 2026-06-29; Day-1 adopts the OZ `TimelockController` default in which the proposer is also granted `CANCELLER_ROLE`])** (shared with Vault `GOV_ROLE`, dToken Owner, and the same Timelock). Owner (emergency recovery / reward sweep) is Guardian multisig (immediate), so emergency recovery for external protocol incidents is not delayed. Because the emergency side is not timelocked, no emergency bypass is needed. Canonical design decision: [../../policies/Governance-Roles-Timelock.md](../../policies/Governance-Roles-Timelock.md). Related: [STGY-FR-009](#stgy-fr-009-upgrades-uups) / [STGY-SEC-002](#stgy-sec-002-owner-key-compromise-damage-boundary).
- Verification: manual (deployment configuration review; holder assert)

### STGY-GOV-005: Dedicated upgrader holder

- Statement: UUPS `upgrader` must be an explicit dedicated holder and must not be implicitly the Strategy Owner. Day-1 holder is the shared TimelockController; deployment and handover verification must assert `upgrader == shared Timelock`. Emergency Owner remains Guardian multisig and cannot upgrade.
- Verification: manual (deployment / handover holder assertion), unit (only upgrader can upgrade / setUpgrader)

---

## 11. Events and Monitoring Requirements (EVT)

Common events emitted by BaseStrategy:

| ID | Event | Purpose (off-chain) |
| --- | --- | --- |
| STGY-EVT-001 | `Deposited(uint256 amount, uint256 newPrincipal)` | Detect completion of `deposit` into external protocol; track cumulative deployed amount and principal history |
| STGY-EVT-002 | `SentToVault(address caller, uint256 requested, uint256 actual, uint256 newPrincipal)` | On `sendToVault` (principal push recovery). `actual` is Vault actual received amount `sent`. `requested - actual` is the recovery gap (liquidity stress signal) |
| STGY-EVT-003 | `ProfitSentToVault(address caller, uint256 yield, uint256 actual)` | On `sendProfitToVault` (yield push). Tracks yield transfer |
| STGY-EVT-004 | `PrincipalWrittenOff(uint256 amount, uint256 newPrincipal)` | On `writeoffPrincipal` (principal impairment finalization). `amount` is the actual principal decrease |
| STGY-EVT-005 | `EmergencyWithdrawn(uint256 amount)` | On `emergencyWithdraw` (directly held funds to Vault) |
| STGY-EVT-006 | `Emergency*Withdrawn(uint256 amount)` (derived-specific, recommended) | Emitted by derived-specific emergency recovery functions (`emergencyWithdrawFrom{Protocol}()`) |
| STGY-EVT-007 | `RewardTokenSwept(address token, address treasury, uint256 requested, uint256 received)` | Treasury sweep of non-Underlying, non-position reward tokens. `requested - received` is actual-received difference such as fee-on-transfer |
| STGY-EVT-008 | `OwnershipTransferStarted(address previousOwner, address newOwner)` / OZ `OwnershipTransferred` | Start and finalization of Owner transfer |
| STGY-EVT-009 | `UpgraderUpdated(address oldUpgrader, address newUpgrader)` / ERC1967 `Upgraded(newImpl)` | Track Upgrader changes and UUPS upgrades |
| STGY-EVT-010 | `MerklRewardsClaimed(address distributor, address token, uint256 cumulativeAmount, uint256 swept)` / `MerklUnderlyingRewardsClaimed(address distributor, address token, uint256 cumulativeAmount, uint256 sentToVault)` | Merkl claim settlement tracking. Non-Underlying rewards reconcile Treasury receipt with `RewardTokenSwept`; Underlying rewards track Vault buffer receipt |
| STGY-EVT-011 | `PrincipalReturned(uint256 amount, uint256 newPrincipal)` | Emitted when protocol-specific emergency recovery accounts the Vault actual receipt as returned principal. `amount` is the actual principal decrease |
| STGY-EVT-012 | `PendingWithdrawalValuationBpsUpdated(uint256 oldBps, uint256 newBps)` | Conservative valuation bps change for async pending withdrawals. Reconcile against incident logs and finalization evidence |

**Shared monitoring metrics**:

| Metric | Source |
| --- | --- |
| AUM (`estimatedTotalUnderlying()`) time series | Periodic snapshots through Vault `getStrategyStatuses()` / subgraph |
| Cumulative deployed amount, cumulative recovered amount, principal history | Vault `StrategyAllocated` and Strategy events (STGY-EVT-001 / STGY-EVT-002 / STGY-EVT-003) |
| Recovery request vs actual push gap | `SentToVault` `requested - actual` (= Vault actual received `sent`). Nonzero indicates liquidity stress ([CollateralVault requirements](../CollateralVault.md)) |
| Allocation deposit rejection | A Vault `StrategyAllocationSkipped` whose contemporaneous `getStrategyStatuses()` is live-available with cap headroom. Investigate venue supply halt or external cap exhaustion |
| Divergence between `estimatedTotalUnderlying` and `principal` | `estimatedLoss` / `estimatedGain` from `getStrategyStatuses()`. Negative = principal impairment signal; positive = estimated upside signal. If external protocol loss is not visible in the valuation view, it cannot be detected automatically and requires recovery, `writeoffPrincipal`, and backstop operations |
| Async pending valuation bps | `PendingWithdrawalValuationBpsUpdated` and `pendingWithdrawalValuationBps()`. Audit trail for pre-claim conservative discounts / restoration in Lido, Etherfi, and similar async Strategies |
| External protocol health | Protocol-specific dashboards / Governance forums (off-chain) |

---

## 12. Failure / Exception Behavior (ERR)

### STGY-ERR-001: shared risks and failure behavior

Applies to all Strategies (individual Strategy-specific risks are documented in each child document following the §15 convention):

1. **External protocol smart-contract / economic attack risk**: avoid concentrated deployment through Vault-side `cap`; in emergencies, GUARDIAN immediately stops new allocation through Vault `emergencyDisableStrategy`, and the Strategy Owner (Guardian multisig) responds with protocol-specific emergency recovery functions. Permanent cap/weight changes and re-enabling are performed by GOV (through the Timelock) ([STGY-GOV-002](#stgy-gov-002-emergency-operations))
2. **Liquidity risk**: `sendToVault` pushes only the amount the external protocol can return (`actual`) and treats less than requested as a normal path (one unhealthy Strategy does not stop overall recovery; [STGY-SEC-005](#stgy-sec-005-liquidity-shortage-treated-as-normal-path-dos-resistance)). Inventory is maintained through `bufferTargetBps` / `bufferFloor`
3. **AUM valuation risk**: if `estimatedTotalUnderlying()` is overvalued, yield may be over-sent. Vault values conservatively with `min(estimatedTotalUnderlying, principal)` and defends yield transfer with `realizedYield()` cap + buffer cap ([STGY-SEC-004](#stgy-sec-004-conservative-accounting-against-aum-overvaluation) / [CollateralVault requirements](../CollateralVault.md))
4. **ALLOCATOR / Owner / Upgrader key compromise**: see [STGY-SEC-001](#stgy-sec-001-allocator-key-compromise-damage-boundary) / [STGY-SEC-002](#stgy-sec-002-owner-key-compromise-damage-boundary) / [STGY-SEC-008](#stgy-sec-008-upgrader-key-compromise-damage-boundary)

**Error catalog**

| Error | Trigger |
| --- | --- |
| `OnlyVault` | `deposit` / `writeoffPrincipal` by a non-Vault caller ([STGY-SEC-001](#stgy-sec-001-allocator-key-compromise-damage-boundary)) |
| `Unauthorized` | `sendToVault` / `sendProfitToVault` by a non-ALLOCATOR, UUPS upgrade / `setUpgrader` by a non-upgrader, or `deployUnderlying` by any caller other than the Strategy itself |
| `DepositRecoveryFailed` | After deposit rejection, declared/received differ, return transfer fails, or the Strategy decrease / Vault increase does not equal the net receipt |
| `ZeroAddress` | `_vault` / `_underlying` / `_owner` / `_upgrader` during initialization, `setUpgrader(address(0))`, zero token / zero treasury in `sweepRewardToken`, or zero distributor / token in `claimMerklRewards` |
| `NotContract(address target)` | EOA or undeployed address passed as `_vault`, `_underlying`, or a derived Strategy external-protocol dependency during initialization |
| `ReentrantCall` | Nested call into a guarded Strategy entry point while `nonReentrantStrategy` is already executing |
| `CannotSweepProtectedToken` | `sweepRewardToken` called with Underlying or a position / receipt / accounting token protected by a derived Strategy, or `claimMerklRewards` called with a non-Underlying protected token |
| `InvalidMerklDistributor` | `claimMerklRewards` called with an EOA / undeployed distributor |
| `InvalidMerklClaim` | `claimMerklRewards` receives empty token arrays or mismatched token / amount / proof array lengths |
| `TooManyMerklTokens` | `claimMerklRewards` receives more than `MAX_MERKL_TOKENS_PER_CLAIM` tokens (implementation constant `16`) |
| `DuplicateMerklToken` | `claimMerklRewards` receives the same token more than once |
| `AsyncPendingRequestLimitExceeded` | An `AsyncRequestStrategy` implementation would exceed `MAX_ASYNC_PENDING_REQUESTS` (implementation constant `128`) unclaimed requests |
| `RenounceOwnershipDisabled` | `renounceOwnership` call (STGY-FR-011 / STGY-SEC-007) |

### STGY-ERR-002: handling asynchronous external protocols

In the push model, whether an external protocol is synchronous (immediate withdrawal) or asynchronous (requires waiting such as unbonding) is **internal to the Strategy implementation**. The Vault does not hold `requestKey`, does not branch on `isAsyncWithdraw`, and does not have asynchronous liquidation paths such as `claimWithdraw` / `claimHarvest`. Principal/cache-reducing pushes reach the buffer through `receiveFromStrategy`; yield-only pushes reach it through direct Strategy transfers. The distinction between principal/yield and principal accounting is internal to the Strategy. Structural issues such as "no liquidation path for asynchronous principal recovery" or "yield claims do not validate requestKey purpose" do not occur.

Implementation policy when making an asynchronous external protocol (such as Lido stETH + Withdrawal Queue) into a Strategy:

- Inside `sendToVault` / `sendProfitToVault`, `_doWithdraw` returns **only the amount immediately withdrawable at that time**. `sendToVault` pushes through `receiveFromStrategy` as a principal return, while `sendProfitToVault` transfers directly into the Vault buffer as yield-only. If nothing is immediately withdrawable, return `0`; after unbonding completes, a later call pushes the actual amount. `sent` being less than requested is treated as a normal path ([STGY-SEC-005](#stgy-sec-005-liquidity-shortage-treated-as-normal-path-dos-resistance))
- Multi-step management such as issuing unbond requests, waiting, and receiving funds remains inside that Strategy's internal state and is not exposed on the `IStrategy` surface (§5)
- The total unclaimed request count in `AsyncRequestStrategy` implementations is capped by `MAX_ASYNC_PENDING_REQUESTS` (128) to prevent storage bloat / UI retrieval failure from ALLOCATOR misoperation or key compromise. Claim batches remain capped at 32 requests per transaction, so keepers / UI must chunk `getPendingRequestIds()` results across multiple transactions.
- LidoStrategy is the implementation example for this section: it has `requestLidoWithdrawal` / `claimLidoWithdrawals` as Strategy-specific keeper functions, while keeping the `IStrategy` surface the same as a synchronous Strategy

---

## 13. Acceptance Criteria and Verification Plan

Passing condition for each requirement = satisfy the verification method in the table below (do not write test names or execution results in this document; specify only the method type).

| ID | Requirement (summary) | Verification method |
| --- | --- | --- |
| STGY-FR-001 | deposit (onlyVault, isolated self-call, principal increase on success, exact recovery / 0 on rejection, incomplete-recovery fail-closed) | unit, integration |
| STGY-FR-002 | sendToVault (ALLOCATOR-only, `sent`-based subtraction, early return) | unit, fork/integration |
| STGY-FR-003 | sendProfitToVault (ALLOCATOR-only, principal unchanged, early return) | unit, fork/integration |
| STGY-FR-004 | writeoffPrincipal (onlyVault, `min` clamp) | unit, invariant=STGY-INV-002 |
| STGY-FR-005 | emergencyWithdraw (onlyOwner, destination fixed to Vault, principal unchanged) | unit, integration |
| STGY-FR-006 | derived hooks (_doDeposit / _doWithdraw / _estimatedTotalUnderlying) | unit, integration/fork |
| STGY-FR-007 | BaseStrategy initialization (zero / contract-code checks, reinitialization revert, owner/upgrader saved, forceApprove(vault)) | unit, manual |
| STGY-FR-008 | view getters (realizedYield identity, conservative valuation, underlying match) | unit, integration |
| STGY-FR-009 | upgrades (upgrader-only, Owner/operational roles revert, old proxy upgrader migration, storage layout) | unit, manual |
| STGY-FR-010 | sweepRewardToken (non-Underlying, non-position rewards, current treasury destination, actual received amount, full-balance mode) | unit |
| STGY-FR-011 | Owner transfer (2-step) and disabled renounce | unit, manual |
| STGY-FR-012 | claimMerklRewards (distributor validation, fixed recipient, protected-token pre-claim rejection, Vault/Treasury actual receipt) | unit |
| STGY-INV-001..011 | Each invariant in §8 | unit / invariant (as listed in §8) |
| STGY-SEC-001..008 | Each security requirement in §9 | unit, manual, integration (as listed in §9) |
| STGY-EVT-001..012 | Each event in §11 | unit |
| STGY-ERR-001..002 | Shared risks and asynchronous handling in §12 | manual, integration |

---

## 14. Open Items (TBD)

### STGY-TBD-001

Resolved (founder decision on 2026-06-12): the Strategy itself does not include an embedded timelock. `_authorizeUpgrade` is gated by a dedicated `upgrader` separated from Owner, and its holder is the **shared TimelockController (minDelay = 12h; PROPOSER/EXECUTOR = GOV multisig; CANCELLER = the same Admin multisig as PROPOSER / EXECUTOR [updated 2026-06-29; Day-1 adopts the OZ `TimelockController` default in which the proposer is also granted `CANCELLER_ROLE`]; Timelock's own admin renounced)** (shared with Vault `GOV_ROLE` / `DEFAULT_ADMIN_ROLE` and dToken Owner). Owner (emergency recovery / reward sweep) = Guardian multisig (immediate). Because the emergency recovery side is not delayed, no emergency bypass is required. Canonical design decision: [../../policies/Governance-Roles-Timelock.md](../../policies/Governance-Roles-Timelock.md). Reflected in: [STGY-FR-009](#stgy-fr-009-upgrades-uups) / [STGY-GOV-001](#stgy-gov-001-owner-and-upgrader-holder-configuration) / [STGY-GOV-003](#stgy-gov-003-upgrader-timelock) / [STGY-SEC-002](#stgy-sec-002-owner-key-compromise-damage-boundary).

---

### STGY-TBD-002

Resolved (implemented): conservative Strategy-specific **withdraw caps / partial recovery** are implemented in derived Strategies, and each Strategy satisfies "do not treat illiquidity as loss" (STGY-SEC-005). Aave caps `_doWithdraw` to reserve liquid underlying ([AaveV3Strategy](AaveV3Strategy.md) `AAVE-TBD-008` / `AAVE-FR-004`); ERC4626 uses conservative `maxWithdraw` / `convertToAssets`. **Neither path lowers valuation (`estimatedTotalUnderlying` / `backingRatio`) merely because liquidity is temporarily unavailable; only confirmed loss is reflected.** Remaining improvements, if any, are precision of each liquidity-cap measurement ([`ADR-006`](../../architecture/Architecture-Decision-Records.md#adr-006)).

## 15. References

- [Product Overview](../../Product-Overview.md) — overall architecture, responsibility separation, no-core-modification policy (§5)
- [CollateralVault requirements](../CollateralVault.md) — canonical source for `allocate`, push intake `receiveFromStrategy`, `writeoffStrategyPrincipal`, `transferYieldToTreasury`, role definitions (`ALLOCATOR_ROLE`), buffer, cap, and weights
- [dToken requirements](../dToken.md) — collateral token (claim token wrapping the Underlying managed by Strategy). Post-hoc Underlying finalization is `DTKN-FR-002`; cap / unset guard for mint is `DTKN-FR-004`
- [AaveV3Strategy requirements](AaveV3Strategy.md) — concrete Strategy implementation for Aave V3 (child document of this document; hook implementation, protocol-specific emergency recovery function, and specific risks)
- [ERC4626Strategy requirements](ERC4626Strategy.md) — ERC-4626 vault adapter for Morpho Vault / EulerEarn, etc. (share donation defense, protocol-specific emergency recovery function, and specific risks)
- [LidoStrategy requirements](../../../../archive/LidoStrategy.md) — asynchronous Strategy implementation for Lido stETH + Withdrawal Queue (implementation example of STGY-ERR-002)
- [SkyUsdcSUsdsStrategy requirements](SkySUsdsStrategy.md) — dUSDC asset-transforming Strategy for USDC -> USDS -> sUSDS and USDC recovery
- [EtherfiWeETHStrategy requirements](../../../../archive/EtherfiWeETHStrategy.md) — dETH asynchronous Strategy for Ether.fi eETH / weETH and WithdrawRequestNFT recovery
- [Strategy Selection Policy](../../../operations/policies/Strategy-Selection-Policy.md) — current adoption status for each venue
- [Strategy Incident / Liquidation Safety Runbook](../../../operations/runbooks/Strategy-Incident-Liquidation-Safety-Runbook.md) — incident recovery, writeoff, and liquidation-bot restart decisions
- [Parameters requirements](../../../../Parameters.md) — finalized collateral-specific cap / buffer (`bufferTargetBps` / `bufferFloor`) / weight values
- [Liquity-v2-Core-Spec](../Liquity-v2-Core-Spec.md) — 🔵 core collateral, liquidation, and Redemption behavior (not re-specified here)
- [requirements specification document standard](../../../../README.md#requirements-spec-standard) — standard followed by this document

### Deploy Selection and Verification

The DF dToken wiring in `DeployLiquity2` can select the Strategy kind per active branch. Strategy kind / weight / cap must be specified explicitly at deploy time and fail-fast if unspecified. Do not make Aave-fixed, 100% weight, and unlimited cap implicit defaults.

- `DF_STRATEGY_KIND` / `DF_STRATEGY_KIND_<branchIndex>`: adopted values are `aave` / `erc4626` / `etherfi-weeth` / `sky-susds` / `none`. Current code also recognizes legacy `lido`; its use is governed by Strategy Selection Policy. If a branch-specific env exists, it takes precedence; otherwise the shared env is used. If neither exists, deploy stops.
- `DF_STRATEGY_WEIGHT_BPS` / `DF_STRATEGY_WEIGHT_BPS_<branchIndex>`: weight at Vault registration. If a branch-specific env exists, it takes precedence; otherwise the shared env is used. If neither exists, deploy stops.
- `DF_STRATEGY_CAP` / `DF_STRATEGY_CAP_<branchIndex>`: cap at Vault registration. If a branch-specific env exists, it takes precedence; otherwise the shared env is used. If neither exists, deploy stops.
- `erc4626`: `DF_STRATEGY_ERC4626_VAULT_<branchIndex>` is required, and `ERC4626Strategy.initialize` verifies `asset() == underlying`
- legacy `lido`: current code reads the WETH-branch env keys `DF_STRATEGY_LIDO_STETH_<branchIndex>` / `DF_STRATEGY_LIDO_WSTETH_<branchIndex>` / `DF_STRATEGY_LIDO_WITHDRAWAL_QUEUE_<branchIndex>` / optional `DF_STRATEGY_LIDO_REFERRAL_<branchIndex>`
- `etherfi-weeth`: selectable only for the WETH branch. `DF_STRATEGY_ETHERFI_LIQUIDITY_POOL_<branchIndex>` / `DF_STRATEGY_ETHERFI_EETH_<branchIndex>` / `DF_STRATEGY_ETHERFI_WEETH_<branchIndex>` / `DF_STRATEGY_ETHERFI_WITHDRAW_ADAPTER_<branchIndex>` / `DF_STRATEGY_ETHERFI_WITHDRAW_REQUEST_NFT_<branchIndex>` are required; `DF_STRATEGY_ETHERFI_REFERRAL_<branchIndex>` is optional
- `sky-susds`: selectable only for branch index 1 with the deployment-wide 6-decimal USDC underlying. `DF_STRATEGY_SKY_USDS_<branchIndex>` / `DF_STRATEGY_SKY_SUSDS_VAULT_<branchIndex>` / `DF_STRATEGY_SKY_USDC_USDS_PSM_WRAPPER_<branchIndex>` / `DF_STRATEGY_SKY_MAX_CONVERSION_LOSS_BPS_<branchIndex>` are required; the deploy script creates the audited concrete converter

The deploy-tail verify does not cast to a concrete type (such as Aave); it verifies branch wiring through the BaseStrategy-shared `vault()` and `IStrategy.underlying()`. The validity of each external-protocol-specific address (zero address / undeployed contract / semantic consistency) is handled by the derived Strategy's `initialize` and the child document's fork/integration tests.

### Child Document Structure Convention

Each individual Strategy child document should use the following structure while referencing shared items centralized in this document (shared items should reference this document; child documents should contain only external-protocol-specific items):

1. **Target Underlying / external protocol** — which Underlying and which protocol (version, chain, Pool / Adapter address) are handled
2. **Additional storage** — Strategy-specific state variables not held by BaseStrategy
3. **`initialize`** — arguments, processing flow, and prior approval
4. **Hook implementation details** — mapping to external protocol interfaces (`_doDeposit` / `_doWithdraw` / `_estimatedTotalUnderlying`)
5. **Protocol-specific emergency recovery function** — `emergencyWithdrawFrom{Protocol}()`, etc.
6. **Deployment and initial configuration parameters** — Pool / aToken / Cap / weight for each supported Underlying
7. **Reward token handling** — claim path / swap necessity / return to Treasury
8. **Specific risks** — external-protocol-specific risks and mitigations (reference shared risks at [STGY-ERR-001](#stgy-err-001-shared-risks-and-failure-behavior))
9. **Known TODO / open items**
10. **References**

AaveV3Strategy is the first child document. ERC-4626-style Morpho / Euler, etc. are handled by the common ERC4626Strategy adapter when `asset() == underlying`. Lido stETH + Withdrawal Queue, Etherfi weETH, USDC -> USDS -> sUSDS, Yo Protocol / sUSDe / sGHO, etc. that cannot be expressed through ERC-4626 should add individual Strategies as needed.
