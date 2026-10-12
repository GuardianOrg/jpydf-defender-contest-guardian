# 🟢 CollateralVault Requirements Specification

## 0. Metadata

| Item | Value |
| --- | --- |
| Status | Draft (implementation exists; requirements are being canonicalized) |
| Owner | DeltaForesight |
| Target contracts | `contracts/src/CollateralVault.sol` (main implementation, UUPS) / `contracts/src/Interfaces/ICollateralVault.sol` (specified interface) / `IDToken` (mint/burn target) / `IStrategy` (push receiver and allocation destination) |
| Related documents | [Product-Overview](../Product-Overview.md) (architecture and responsibility separation) / [dToken](dToken.md) (collateral beneficiary-right token that is minted/burned) / [Strategy](strategies/Strategy.md) (deployment destinations and push source) / [Oracle](Oracle.md) (PriceFeed consistency) / [Zapper](Zapper.md) (permit and referral path) / [Parameters](../../../Parameters.md) (values such as buffer / allocator / mintCap) |

> This document follows the [requirements specification standard](../../../README.md#requirements-spec-standard). Requirements, invariants, and security requirements are assigned persistent IDs (`VAULT-...`), and cross-references use those IDs.

---

## 1. Purpose, Scope, and Non-Responsibilities

CollateralVault is the **core contract of the dToken layer** (one per collateral asset, UUPS). It is responsible for custody of Underlying (WETH / USDC, etc.), calling dToken mint/burn, liquid buffer accounting, allocation to Strategies (`allocate`) and push receipts from Strategies (`receiveFromStrategy`), backstop replenishment reserve that does not mint dToken (`backstopDeposit` / `releaseBackstopToBuffer`), transfer of yield to Treasury, delayed redemption (request/claim), and deferred Underlying binding. From the Liquity v2 core, it appears only as the issuer of an ordinary 18-decimal ERC-20 collateral token (dToken) and exposes none of the underlying asset, Strategy operations, buffer, or delayed-redemption internals.

- **Specified by this document**: Mint / Redeem (permissionless) / buffer accounting (conservative `min(est, principal)` valuation, first-come-takes-all + delayed rules) / Allocation (fixed weight allocation) / Strategy -> Vault push receipt (`receiveFromStrategy`) / backstop replenishment reserve (`backstopDeposit` / `releaseBackstopToBuffer`) / delayed redemption (`WithdrawRequest` / claim) / Treasury yield transfer (`transferYieldToTreasury`) / Strategy management (whitelist, registration CRUD, principal writeoff) / deferred Underlying binding (`setUnderlying` / `whenUnderlyingReady`) / GOV configuration setters / view functions / Pause and Unpause / UUPS upgrades / role design.
- **Not specified by this document (non-responsibilities and other documents)**:
  - dToken token specification itself (decimals / conversion / collateral cap / `setTokenInfo` / EIP-2612 Permit / internal mint and burn authorization) -> [dToken Requirements Specification](dToken.md)
  - Strategy implementation, `IStrategy` / `BaseStrategy`, and Strategy-side function bodies (`sendToVault` / `sendProfitToVault` / `writeoffPrincipal` / `emergencyWithdraw`) -> [Strategy Requirements Specification](strategies/Strategy.md)
  - Final Day-1 collateral-specific parameter values (`bufferTargetBps` / `bufferFloor` / `allocatorCooldown` / `allocateMaxMove` / `withdrawDelay` / mintCap, etc.) -> [Parameters.md](../../../Parameters.md)
  - Zapper UX Router / permit / referral recording / Sky ingress (Flash Loan close is outside the Day-1 ABI) -> [Zapper Requirements Specification](Zapper.md)
  - 🔵 Liquity core borrowing, liquidation, Redemption, Stability Pool, Surplus, and related behavior -> [Liquity-v2-Core-Spec](Liquity-v2-Core-Spec.md)
- **Responsibility boundary (intentionally unaware)**: The Vault only accumulates Underlying received from Strategies into the liquid buffer; it does not distinguish at receipt time whether it is principal recovery or profit (Treasury yield transfer is a separate function). Only backstop deposits are accounted for separately as protected reserve. The Vault also does not know whether an external protocol is synchronous or asynchronous; that distinction is contained inside each Strategy implementation.

---

## 2. Background and Design Policy

CollateralVault is designed consistently as the "custody and accounting layer" for a collateral wrapper that allows the **Liquity v2 core to be used unchanged**.

- **Only dToken is exposed to the core**: The core treats dToken as 18-decimal collateral ERC-20 and knows nothing about the real Underlying, Strategy operations, buffer, or delayed redemption behind it. The Vault absorbs that complexity.
- **Push model**: funds returning from Strategy to Vault are Strategy-initiated. Principal returns, protocol-specific emergency recovery, and generic idle rescue routes that should reduce the Strategy valuation cache are consolidated into `receiveFromStrategy` ([VAULT-FR-005](#vault-fr-005)). Yield-only pushes such as `sendProfitToVault` and Underlying reward claims transfer directly into the Vault buffer and do not reduce Strategy principal or Vault valuation caches. The Vault does not pull principal from Strategies; Strategies push to the Vault. The approval direction is therefore reversed: **Strategy max-approves the Vault during initialization** (a premise of `sendToVault`, etc. in [Strategy Requirements Specification](strategies/Strategy.md)). Synchronous/asynchronous differences are contained in each Strategy implementation and are not represented in Vault accounting (`StrategyConfig`).
- **Conservative accounting (`min(est, principal)`)**: Solvency valuation uses live `min(estimatedTotalUnderlying, principal)` and falls back to a bounded last-good cache only when valuation fails. However, the pre-state guard on `deposit` / `redeem` / `redeemWithPermit` / `claim` never uses cache: it proves full backing from `A_confirmed`, consisting only of the Vault raw balance and available live conservative values. An unreadable Strategy contributes zero, and the operation fails closed before changing state or tokens when `A_confirmed < L_effective` ([VAULT-SEC-010](#vault-sec-010)). Allocation and Treasury transfer never send against cached value or an incomplete partial system view; if any registered Strategy lacks a live valuation, `managedUnderlying` is zero and the entire outbound operation returns early. `managedUnderlying` also excludes protected backstop reserve ([VAULT-INV-005](#vault-inv-005) and [§7](#7-state-variables-and-accounting-model)).
- **First-come-takes-all + delayed redemption**: Only while healthy with `A_confirmed >= L_effective`, `redeem` completes in one transaction when liquid buffer is sufficient. When insufficient, the current liquid buffer is paid to the first caller and the remainder becomes a delayed `WithdrawRequest`. `pendingWithdrawals` protects claim funds from flowing out to Strategies ([VAULT-FR-002](#vault-fr-002) and [VAULT-FR-006](#vault-fr-006)).
- **Buffer / backstop responsibility separation**: `bufferBalance()` represents only liquidity available for redeem / claim / allocate / Treasury transfer. `backstopDeposit()` records Underlying in the same Vault as protected reserve; it is included in `totalUnderlying()` / `backingRatio()` but cannot be used for redeem / claim until GOV explicitly releases it through `releaseBackstopToBuffer()`. This prevents replenishment funds for Strategy impairment from being drained first-come-first-served by normal redeems ([VAULT-FR-017](#vault-fr-017)).
- **Two-stage monetization**: Stage 1 = each Strategy pushes realized Underlying-denominated profit to the buffer via `Strategy.sendProfitToVault` ([Strategy Requirements Specification](strategies/Strategy.md)); Stage 2 = `transferYieldToTreasury` sends buffer surplus to Treasury ([VAULT-FR-007](#vault-fr-007)). Profit remaining inside a Strategy cannot be reached by Stage 2 alone due to the buffer clamp, so ALLOCATOR first pulls it up in Stage 1. Non-Underlying, non-position reward tokens such as Aave incentives / Merkl are outside this two-stage accounting and are sent to Treasury through the shared Strategy `sweepRewardToken`. This prevents one Strategy failure from cascading to others.
- **Deferred initialization (placeholder) policy**: The Vault can be deployed as a placeholder with `underlying == address(0)` and fixed exactly once later through `setUnderlying`. Because Underlying binding is split into two independent one-shot setters, one on the Vault (`setUnderlying`) and one on dToken (`setTokenInfo`), `whenUnderlyingReady` forces consistency **at use time** and prevents silent misvaluation across different assets or decimals ([VAULT-FR-011](#vault-fr-011) and [VAULT-SEC-002](#vault-sec-002)).
- **Least privilege and asymmetric pause**: Fund movement authority is limited to the four ALLOCATOR_ROLE functions, with destinations constrained to pre-registered Strategies, the Vault, or fixed Treasury. For speed, pause (four independent flags) and reversible emergency neutralization (`emergencyDisableStrategy` / `removeStrategy` / `removeFromWhitelist`) are GUARDIAN (immediate), while recovery and risk-increasing operations including unpause are GOV only (holder = shared TimelockController, 12h delay). This ensures that a compromised guardian key can only stop or neutralize reversibly. Manual markdown paths (`writeoffStrategyPrincipal` and async Strategy pending valuation bps changes) are separated into independent WRITEOFF_ROLE (high-quorum GOV multisig, immediate) ([§10](#10-governance-operations-and-upgrade-requirements-gov)).
- **Behavior on backing impairment**: the finalized policy when backing < 1 (`A < L_effective`) is [`ADR-006`](../architecture/Architecture-Decision-Records.md#adr-006). The relevant mechanisms in this Vault are [VAULT-SEC-010](#vault-sec-010) (automatic on-chain stop-the-bleed) / [VAULT-FR-014](#vault-fr-014) (operational defense in depth) / [VAULT-FR-017](#vault-fr-017) (backstop replenishment) / `VAULT-FR-009` (recognizing confirmed loss) / [§12](#12-failure-and-exception-behavior-err) (operational treatment after confirmed permanent loss).

> The canonical source for the overall no-core-modification policy and the background that dToken is core collateral is [Product-Overview](../Product-Overview.md) §4 / §5.

---

## 3. Terms, External Dependencies, and Assumptions

**Terms**

| Term | Meaning |
| --- | --- |
| Underlying | The real collateral asset held by the Vault (WETH / USDC, etc.). The underlying asset wrapped by dToken |
| dToken | The collateral beneficiary-right token minted/burned by this Vault ([dToken Requirements Specification](dToken.md)) |
| buffer | Liquid Underlying currently held by the Vault and usable for redeem / claim / allocate / Treasury transfer (`underlying.balanceOf(vault) - backstop reserve`) |
| backstop reserve | Protected Underlying deposited for replenishment via `backstopDeposit`. Included in `totalUnderlying()` but excluded from `bufferBalance()` until `releaseBackstopToBuffer` |
| Strategy | Deployment destination that manages Underlying in an external protocol ([Strategy Requirements Specification](strategies/Strategy.md)) |
| `principal` | Invested principal self-managed by each Strategy. Used as the conservative side of solvency valuation |
| `estimatedTotalUnderlying` | Total recoverable Underlying estimated by a Strategy (including profit and after loss) |
| WithdrawRequest | Claim generated by a buffer-insufficient redeem for delayed redemption |
| `pendingWithdrawals` | Total unclaimed WithdrawRequests (used to protect claim funds) |
| GOV_MULTISIG | Subject of Vault `GOV_ROLE` / `DEFAULT_ADMIN_ROLE` (governance multisig) |
| ALLOCATOR | Subject of `ALLOCATOR_ROLE`. Its mainnet physical holder and execution form are governed by the role-assignment policy |
| GUARDIAN | Subject of `GUARDIAN_ROLE` (renamed and expanded from previous PAUSE_GUARDIAN_ROLE). Can only perform emergency stops (four pause paths) and reversible neutralization (no unpause) |
| WRITEOFF | Subject of `WRITEOFF_ROLE` (held directly by high-quorum GOV multisig, immediate). Can call only `writeoffStrategyPrincipal` and async Strategy pending valuation bps changes |
| placeholder phase / active phase | State before `setUnderlying` (Underlying unset) / after it (fixed) |
| Treasury | Destination address for operating profit (updated by GOV through `setTreasury`) |

**External dependencies (trusted external components)**

- Corresponding dToken ([dToken Requirements Specification](dToken.md)) — calls `mint` / `burn` / `convertToDToken` / `convertToUnderlying` / `permit` / `underlying()`. The Vault is the only mint/burn subject for dToken ([DTKN-SEC-001](dToken.md)).
- Registered Strategies ([Strategy Requirements Specification](strategies/Strategy.md)) — receive allocation through `deposit`, push funds back through `receiveFromStrategy`, and provide `estimatedTotalUnderlying()` / `principal()` for view valuation. Strategy max-approves the Vault during initialization.
- Underlying ERC-20 — `safeTransfer` / `safeTransferFrom` / `balanceOf`. It is handled through `SafeERC20`; receipt paths use balance-delta accounting. Immediate redemption also returns the receiver's measured balance increase rather than the nominal transfer argument. A negative-rebase-style decrease during payout fails closed through checked subtraction.
- OpenZeppelin Contracts (upgradeable) — `AccessControl` (5 roles) / `ReentrancyGuard` (`nonReentrant`) / custom flags equivalent to `Pausable` / UUPS.

**Assumptions**

- The Liquity core treats collateral as 18-decimal ERC-20 (= dToken).
- `vault.underlying() == dToken.underlying()` always holds in the active phase (enforced in code by [VAULT-SEC-002](#vault-sec-002)). Because dToken `setTokenInfo` ([DTKN-FR-002](dToken.md)) fixes address and conversion multiplier from the same argument atomically and exactly once, address equality implies decimals and conversion-multiplier consistency ([VAULT-FR-011](#vault-fr-011)).
- Each Strategy self-manages invested principal as `principal`; the Vault does not hold this value ([§7](#7-state-variables-and-accounting-model)).

---

## 4. Actors, Roles, and Trust Boundaries

| Actor | Operations | Trust boundary |
| --- | --- | --- |
| **GOV_MULTISIG** (`DEFAULT_ADMIN_ROLE` / `GOV_ROLE`; **holder = shared TimelockController [minDelay 12h] only**) | Risk-increasing Strategy management (addToWhitelist / addStrategy / updateStrategy [increase or re-enable]) / GOV configuration setters (setBufferConfig / setAllocatorConfig / setWithdrawDelay / setTreasury / setStrategyValuationMaxAge) / `releaseBackstopToBuffer` / `setUnderlying` / `invalidateStrategyValuationCache` / unpause (four paths) / UUPS upgrade authorization / `grantRole` and `revokeRole` through `DEFAULT_ADMIN_ROLE` | Strongest authority over funds, parameters, and contracts. **Holder must be only the shared TimelockController**, applying a 12h public delay to all GOV operations (GOV multisig proposes/executes through the Timelock and does not directly hold Vault GOV_ROLE / DEFAULT_ADMIN; [VAULT-GOV-004](#vault-gov-004)). Does not participate in normal fund movement |
| **ALLOCATOR** (`ALLOCATOR_ROLE`) | **Only four functions**: `allocate` / `Strategy.sendToVault` / `Strategy.sendProfitToVault` / `transferYieldToTreasury` | Receives no destination or ratio in arguments; follows preconfigured Strategies/weights. If compromised, damage is limited to sending to registered Strategies, recovering Strategy -> buffer, and sending buffer surplus to fixed Treasury. Vault outbound operations (`allocate` / `transferYieldToTreasury`) can be stopped immediately with `pauseAllocation` ([VAULT-SEC-005](#vault-sec-005)) |
| **GUARDIAN** (`GUARDIAN_ROLE`; renamed and expanded from previous PAUSE_GUARDIAN_ROLE) | `pauseDeposit` / `pauseRedeem` / `pauseClaim` / `pauseAllocation` (stop only) / `emergencyDisableStrategy` / `removeStrategy` (requires `principal == 0` and live `estimatedTotalUnderlying == 0`) / `removeFromWhitelist` | Guardian multisig (immediate). Only reversible fail-safes (stop/neutralize), no markdown authority that can lower backing. Cannot unpause, re-enable, or increase risk (GOV=Timelock only). Asymmetric design |
| **WRITEOFF** (`WRITEOFF_ROLE`) | `writeoffStrategyPrincipal` / async Strategy `setPendingWithdrawalValuationBps` | **Held directly by high-quorum GOV multisig (not through Timelock = immediate)**. Writeoff and pending valuation bps changes are price-moving paths that reflect real loss or uncertainty around unclaimed async requests into backing. Delaying them would allow new borrowing against overstated collateral and compound bad debt. Downward async pending valuation changes require `pausedAllocation == true`; restoration / upward changes do not require pause. Resistance to malicious markdown (unjust markdown -> unjust liquidation) is provided by four layers: high quorum, allocation freeze before downward markdown, immediate `pauseRedeem` by GUARDIAN to close the cash-out exit if detected, and the fact that these operations do not transfer funds |
| **dToken Owner (GOV_MULTISIG)** | `dToken.setTokenInfo` / `dToken.setCap` / dToken upgrade authorization | Authority on the dToken side ([dToken Requirements Specification](dToken.md)). Coordinates with this Vault's `setUnderlying` and activation order |
| **Registered Strategy** | `receiveFromStrategy` (only caller set for push receipt) | Determined by membership in `strategies[]`, not a role. Receipt is allowed while it remains in `strategies[]`, whether enabled or disabled |
| **Anyone (permissionless)** | `deposit` / `redeem` / `redeemWithPermit` / `claim` (fixed request-owner payout) / `backstopDeposit` / views | No trust required. Mint/Redeem/claim are executable only when the relevant pause flag (`pausedDeposit` / `pausedRedeem` / `pausedClaim`) is false and `whenUnderlyingReady` holds. A claim caller cannot redirect the request-owner payout. Backstop deposit only increases replenishment reserve and does not mint dToken |

- **Initial role concentration and separation**: `initialize` grants `_admin` all **5 roles** (`DEFAULT_ADMIN_ROLE` / `GOV_ROLE` / `ALLOCATOR_ROLE` / `GUARDIAN_ROLE` / `WRITEOFF_ROLE`) in one batch. In production, `DEFAULT_ADMIN_ROLE` / `GOV_ROLE` move to the shared TimelockController, `ALLOCATOR_ROLE` to `DF_ALLOCATOR`, `GUARDIAN_ROLE` to the Guardian multisig, and `WRITEOFF_ROLE` to high-quorum GOV multisig, with all deployer roles revoked. Post-deployment role rearrangement is part of activation ([VAULT-FR-010](#vault-fr-010), [VAULT-GOV-001](#vault-gov-001), [VAULT-GOV-004](#vault-gov-004)).
- **Authority separation**: ALLOCATOR cannot `setTreasury`, register Strategies, or upgrade. GOV does not participate in normal fund movement (emergency writeoff is WRITEOFF_ROLE; immediate Strategy neutralization/removal and whitelist removal are GUARDIAN_ROLE).

---

## 5. Interface Specification

Specified interface `ICollateralVault`. Behavior is defined in §6 Functional Requirements; only visibility is summarized below (non-normative).

| Function | Visibility | Summary | Requirement |
| --- | --- | --- | --- |
| `deposit(uint256) -> uint256` | external (permissionless, whenUnderlyingReady) | Underlying -> dToken | VAULT-FR-001 |
| `redeem(uint256, address) -> (uint256, uint256)` | external (permissionless, whenUnderlyingReady) | dToken -> Underlying (immediate/delayed) | VAULT-FR-002 |
| `redeemWithPermit(uint256, uint256, uint8, bytes32, bytes32, address) -> (uint256, uint256)` | external (permissionless, whenUnderlyingReady) | redeem through permit | VAULT-FR-003 |
| `allocate()` | external (ALLOCATOR_ROLE) | Allocate buffer surplus to Strategies | VAULT-FR-004 |
| `receiveFromStrategy(uint256) -> uint256` | external (registered Strategy only) | Strategy -> Vault push receipt | VAULT-FR-005 |
| `backstopDeposit(uint256) -> uint256` | external (permissionless, whenUnderlyingReady) | Replenishment reserve deposit without minting dToken | VAULT-FR-017 |
| `releaseBackstopToBuffer(uint256) -> uint256` | external (GOV_ROLE, whenUnderlyingReady) | Explicitly release protected reserve to liquid buffer | VAULT-FR-017 |
| `claim(uint256)` | external (permissionless trigger, fixed request-owner payout) | Receive delayed redemption | VAULT-FR-006 |
| `transferYieldToTreasury() -> uint256` | external (ALLOCATOR_ROLE, `pausedAllocation == false`) | Send buffer surplus to Treasury | VAULT-FR-007 |
| `addToWhitelist(address)` | external (GOV_ROLE) | Add Strategy whitelist entry | VAULT-FR-008 |
| `removeFromWhitelist(address)` | external (GUARDIAN_ROLE) | Remove Strategy whitelist entry (fail-safe, immediate) | VAULT-FR-008 |
| `addStrategy(IStrategy, uint256, uint256)` | external (GOV_ROLE) | Register Strategy | VAULT-FR-008 |
| `updateStrategy(IStrategy, uint256, uint256, bool)` | external (GOV_ROLE) | Update weights / cap / enabled (includes increases and re-enable, so delayed) | VAULT-FR-009 |
| `emergencyDisableStrategy(IStrategy)` | external (GUARDIAN_ROLE) | Immediate disable of a registered Strategy (`enabled=false`, `weight=0`) | VAULT-FR-019 |
| `removeStrategy(IStrategy)` | external (GUARDIAN_ROLE) | Remove Strategy registration (`principal == 0` and live `estimatedTotalUnderlying == 0` required, fail-safe) | VAULT-FR-008 |
| `writeoffStrategyPrincipal(IStrategy, uint256, uint256)` | external (WRITEOFF_ROLE) | Finalize principal impairment with a post-writeoff backing-ratio guard (high quorum, immediate) | VAULT-FR-009 |
| `forceDeallocateMorphoV2(IStrategy, address, bytes, uint256, uint256, uint256)` | external (WRITEOFF_ROLE) | Realize a bounded Morpho V2 penalty with atomic incident pauses and a post-operation backing guard | VAULT-FR-009 |
| `refreshStrategyValuation(IStrategy) -> bool` | external (permissionless) | Explicitly refresh conservative Strategy valuation cache | VAULT-FR-013 |
| `invalidateStrategyValuationCache(IStrategy)` | external (GOV_ROLE) | Explicitly discard Strategy conservative valuation cache | VAULT-FR-013 |
| `initialize(IERC20, IDToken, address, address)` | external (initializer) | Proxy initialization (placeholder capable) | VAULT-FR-010 |
| `setUnderlying(IERC20)` | external (GOV_ROLE) | Deferred Underlying binding (one-shot) | VAULT-FR-011 |
| `setBufferConfig(uint256, uint256)` | external (GOV_ROLE) | Update buffer policy | VAULT-FR-012 |
| `setAllocatorConfig(uint256, uint256)` | external (GOV_ROLE) | Update allocator guardrails | VAULT-FR-012 |
| `setStrategyValuationMaxAge(uint256)` | external (GOV_ROLE) | Update Strategy valuation cache TTL (0 disables fallback) | VAULT-FR-012 |
| `setWithdrawDelay(uint256)` | external (GOV_ROLE) | Update delayed redemption waiting period | VAULT-FR-012 |
| `setTreasury(address)` | external (GOV_ROLE) | Update yield destination | VAULT-FR-012 |
| `bufferBalance() -> uint256` | external view | Liquid buffer balance (excludes backstop reserve, placeholder-safe) | VAULT-FR-013 |
| `backstopBalance() -> uint256` | external view | Protected backstop reserve balance (placeholder-safe) | VAULT-FR-013 |
| `totalUnderlying() -> uint256` | external view | Vault actual Underlying (buffer + backstop reserve) + sum of Strategy conservative valuations (live `min(est, principal)`, fresh cache on valuation failure, stale/missing = 0) | VAULT-FR-013 |
| `pausedAllocation() -> bool` | external view | Allocation / Treasury sweep pause state. Also guards downward async pending valuation changes | VAULT-FR-014 |
| `strategyValuationMaxAge() -> uint256` | external view | Valuation cache TTL | VAULT-FR-013 |
| `strategyValuationCaches(IStrategy) -> (uint256,uint256,bool)` | external view | Per-Strategy last-good conservative valuation cache | VAULT-FR-013 |
| `getStrategiesCount() -> uint256` | external view | Number of registered Strategies | VAULT-FR-013 |
| `getStrategyAt(uint256) -> (IStrategy, StrategyConfig)` | external view | Strategy and config at index | VAULT-FR-013 |
| `getAllStrategies() -> (IStrategy[], StrategyConfig[], uint256[])` | external view | All Strategies, configs, and balances | VAULT-FR-013 |
| `getStrategyStatuses() -> StrategyStatus[]` | external view | Per-Strategy alloc / principal / conservative valuation / estimated PnL / cap headroom | VAULT-FR-013 |
| `backingRatio() -> uint256` | external view | dToken backing ratio `min(1e18, A / L_effective)` (oracle multiplies; downward only) | VAULT-FR-016 |
| `backingRatioForPricing() -> (uint256, bool)` | external view | Same ratio plus valuation availability; unavailable valuation is an oracle failure, not measured zero | VAULT-FR-016 |
| `actualLiabilities() -> uint256` | external view | `L_effective = dToken claims + pendingWithdrawals` | VAULT-FR-018 |
| `backingShortfall() -> uint256` | external view | Shortfall to 100% backing `max(L_effective - A, 0)` | VAULT-FR-018 |
| `backstopRequiredForRatio(uint256) -> uint256` | external view | Replenishment required to reach target backing ratio (round up) | VAULT-FR-018 |
| `pauseDeposit()` / `pauseRedeem()` / `pauseClaim()` / `pauseAllocation()` | external (GUARDIAN_ROLE) | Emergency stop (four independent flags) | VAULT-FR-014 |
| `unpauseDeposit()` / `unpauseRedeem()` / `unpauseClaim()` / `unpauseAllocation()` | external (GOV_ROLE) | Resume | VAULT-FR-014 |
| `_authorizeUpgrade(address)` | internal (GOV_ROLE) | UUPS authorization | VAULT-FR-015 |

---

## 6. Functional Requirements (FR)

### <a id="vault-fr-001"></a>VAULT-FR-001: `deposit` (Underlying -> dToken)

- **Type**: Functional | **Source**: Product-Overview "dToken Layer" / user mint flow
- **Signature**: `deposit(uint256 _underlyingAmount) returns (uint256 dTokenAmount)`
- **Purpose**: Deposit Underlying into the Vault and issue the corresponding dToken to `msg.sender` as a 1:1 claim. The purpose is to obtain an 18-decimal dToken usable as Liquity core collateral.
- **Authorization**: permissionless (no role required; executable only when `pausedDeposit == false` and `whenUnderlyingReady`).
- **Preconditions (Checks)**:
  - `pausedDeposit == false` (revert while paused)
  - `whenUnderlyingReady`: `vault.underlying() != address(0)` and `dToken.underlying() == vault.underlying()` ([VAULT-FR-011](#vault-fr-011))
  - `_underlyingAmount != 0`
  - `L_effective == 0`, or cache-free confirmed assets `A_confirmed >= L_effective` ([VAULT-SEC-010](#vault-sec-010))
- **Behavior (Effects)** (CEI order):
  1. Pause check (revert if not satisfied)
  2. Underlying-ready check (revert if not satisfied)
  3. Input validation (`_underlyingAmount == 0` reverts)
  4. **Checks: pre-state full backing** — when `L_effective != 0`, calculate `A_confirmed`; if `A_confirmed < L_effective`, revert with `BackingRatioBelowMinimum(actual, 1e18)`. The deposit's own incoming funds must not be counted in advance as proof of backing
  5. **Receive Underlying** — record the Vault balance before receipt and pull `_underlyingAmount` from `msg.sender` into the Vault with `safeTransferFrom`
  6. **Calculate dToken amount** — determine `received` from the post-receipt balance delta and convert to 18 decimals with `dTokenAmount = dToken.convertToDToken(received)` ([DTKN-FR-003](dToken.md))
  7. **Issue dToken** — mint to `msg.sender` via `dToken.mint(msg.sender, dTokenAmount)` ([DTKN-FR-004](dToken.md))
- **Revert / early return**: `pausedDeposit` -> `Paused`; Vault Underlying unset -> `UnderlyingNotSet`; Vault/dToken mismatch (including uninitialized dToken) -> `UnderlyingMismatch`; `_underlyingAmount == 0` or actual received amount `received == 0` -> `ZeroAmount`; `A_confirmed < L_effective` -> `BackingRatioBelowMinimum(actual, 1e18)`; `safeTransferFrom` failure (balance/allowance) -> upstream revert; dToken cap exceeded -> `CapExceeded` ([DTKN-FR-004](dToken.md)).
- **Emitted event**: `Deposited(user, underlyingAmount, dTokenAmount)` (`user = msg.sender`, `underlyingAmount` is actual `received`, not declared; [VAULT-EVT-001](#11-events-and-monitoring-requirements-evt)).
- **Design notes**:
  - **Mint recipient is always `msg.sender`** (no `receiver` argument). Referral recording is handled through Zapper ([Zapper Requirements Specification](Zapper.md)). Because Zapper is `msg.sender`, dToken is minted to Zapper and can flow directly into openTrove.
  - **Mint actual received amount**: as with `receiveFromStrategy` / `backstopDeposit`, `received` is determined by balance delta. This prevents over-minting if fee-on-transfer / rebasing behavior causes actual receipt to be lower than declared.
  - **Pre-state guard**: the initial deposit is allowed when `L_effective == 0`. Otherwise, the check uses `A_confirmed` before the incoming transfer so a new deposit cannot both fill an impaired Vault's existing loss and create a new dToken liability. Repair uses `backstopDeposit`, which mints no dToken.
  - **`nonReentrant`**: dToken mint is an external contract call, so ReentrancyGuard protects the function.
  - **Cap check location**: cap upper bound is validated on the dToken side; the Vault does not duplicate the guard ([DTKN-FR-004](dToken.md)).
- **Verification**: unit (pause/ready/zero/reverts, actual-received conversion, underbacked pre-transfer stop, initial deposit), integration (approve -> deposit -> mint).

### <a id="vault-fr-002"></a>VAULT-FR-002: `redeem` (dToken -> Underlying)

- **Type**: Functional | **Source**: Product-Overview "dToken Layer" / redemption flow
- **Signature**: `redeem(uint256 _dTokenAmount, address _receiver) returns (uint256 underlyingReceived, uint256 requestId)`
- **Purpose**: Burn dToken and receive Underlying back. When buffer is sufficient, this completes in one transaction; when insufficient, it connects to delayed redemption ([VAULT-FR-006](#vault-fr-006)). The purpose is for dToken holders to receive the physical Underlying for their principal claim.
- **Authorization**: permissionless (`pausedRedeem == false` and `whenUnderlyingReady`).
- **Preconditions (Checks)**: not paused; `whenUnderlyingReady`; `_dTokenAmount != 0`; `_receiver != address(0)`; cache-free `A_confirmed >= L_effective` ([VAULT-SEC-010](#vault-sec-010)).
- **Behavior (Effects)** (**strict Checks-Effects-Interactions order**):
  1. Pause check (`Paused`)
  2. Underlying-ready check (`UnderlyingNotSet` / `UnderlyingMismatch`)
  3. Input validation (`_dTokenAmount == 0` -> `ZeroAmount`)
  4. Receiver validation (`_receiver == address(0)` -> `ZeroAddress`)
  5. **Checks: exact required Underlying calculation** — calculate `underlyingNeeded = dToken.convertToUnderlying(_dTokenAmount)` and require both `underlyingNeeded != 0` and `dToken.convertToDToken(underlyingNeeded) == _dTokenAmount`. dToken dust not divisible by the multiplier reverts with `InvalidDTokenAmount` and is not burned
  6. **Checks: pre-state full backing** — if `A_confirmed < L_effective`, revert with `BackingRatioBelowMinimum(actual, 1e18)`. The lower post-burn liability must not be counted in advance. Then fix `bufferBal = bufferBalance()` before any state change
  7. **Effects: burn dToken** — `dToken.burn(msg.sender, _dTokenAmount)` (burn from `msg.sender`; insufficient balance reverts on dToken side, [DTKN-FR-005](dToken.md))
  8. **Interactions: immediate path when buffer is sufficient** — if `bufferBal >= underlyingNeeded`, transfer nominal `underlyingNeeded` to `_receiver` via `safeTransfer`, set `underlyingReceived` to the receiver's before/after `balanceOf` delta, and set `requestId = 0`
  9. **Interactions: mixed path when buffer is insufficient** — follow the "first-come-takes-all + delayed rule" below
- **First-come-takes-all + delayed rule (buffer insufficient only)**:
  - **Immediate part**: Transfer the entire nominal current buffer balance `bufferBal` to `_receiver` via `safeTransfer`. If `bufferBal == 0`, skip transfer. The return value and `Redeemed.underlyingPaidNow` are the receiver's actual balance increase. A transfer fee is not shifted into the delayed liability: `remaining = underlyingNeeded - nominalSent` remains unchanged.
  - **Delayed part**: Register the shortfall `remaining = underlyingNeeded - bufferBal` as `WithdrawRequest{ owner: _receiver, underlyingAmount: remaining, claimableAt: block.timestamp + withdrawDelay, claimed: false }`, and increase `pendingWithdrawals += remaining` (protecting claim funds from flowing out through `allocate`, [VAULT-FR-004](#vault-fr-004) / [VAULT-FR-006](#vault-fr-006)). The queue is always recorded in Underlying base units; dToken dust is not requestified.
- **Revert / early return**: `_dTokenAmount == 0` -> `ZeroAmount`; `_receiver == address(0)` -> `ZeroAddress`; dToken amount not an integer multiple of the Underlying base unit / `underlyingNeeded == 0` -> `InvalidDTokenAmount`; `A_confirmed < L_effective` -> `BackingRatioBelowMinimum(actual, 1e18)`; `pausedRedeem` -> `Paused`; Underlying unset -> `UnderlyingNotSet`; mismatch -> `UnderlyingMismatch`; insufficient balance in `dToken.burn` -> ERC20 revert; `safeTransfer` failure -> upstream revert.
- **Emitted event**: `Redeemed(user, receiver, dTokenAmount, underlyingPaidNow, requestId)` (`requestId == 0` means immediate completion) / additionally `WithdrawRequested(user, receiver, requestId, amount, claimableAt)` only when buffer is insufficient ([VAULT-EVT-002](#11-events-and-monitoring-requirements-evt) / [VAULT-EVT-003](#11-events-and-monitoring-requirements-evt)).
- **Design notes**:
  - **Intent of `_receiver`**: separates caller (`msg.sender`) from final receiver (`_receiver`). When buffer is sufficient, `_receiver` receives immediate payment; when insufficient, `WithdrawRequest.owner = _receiver` records the fixed payout recipient. Anyone may trigger `claim()`, but cannot redirect payment, so a contract receiver needs no claim integration when a keeper or other caller settles the request ([VAULT-FR-006](#vault-fr-006)). `_receiver = address(0)` is not a valid recipient, so it is rejected with `ZeroAddress` before burn/request creation.
  - **CEI order**: required amount calculation -> pre-state backing check -> burn -> transfer is enforced to prevent inconsistent state under reentrancy.
  - **Prevent queue preemption**: while `A_confirmed < L_effective`, neither immediate payment nor burn and `WithdrawRequest` creation occurs. This closes the route in which impaired dToken is bought cheaply and converted into a future full-value queue claim.
  - **Decimal / dust policy**: dToken is always 18 decimals, but for USDC(6) the minimum redeem unit is `1e12` dToken and for WBTC(8) it is `1e10` dToken. Amounts below this or not divisible by the multiplier would floor to 0 Underlying, so they are rejected with `InvalidDTokenAmount` to avoid silently burning user value.
  - **`nonReentrant`**: both `dToken.burn` and `safeTransfer` are external calls and are protected.
  - **Partial redeem is not explicitly split by input**: `_dTokenAmount` is always burned in full; immediate/delayed allocation is represented by return values (`underlyingReceived` and `requestId`).
  - Example for a standard ERC-20: `bufferBal = 100`, `underlyingNeeded = 300` -> transfer 100 immediately to `_receiver`, register 200 as `WithdrawRequest`, `underlyingReceived = 100`, `requestId = N`, `pendingWithdrawals += 200`. For a fee token, nominal sent and queued amount remain 100/200 while `underlyingReceived` is the receiver delta.
- **Verification**: unit (immediate/insufficient branches, first-come-takes-all, receiver balance delta, fee-on-transfer, each revert, underbacked pre-burn/queue stop), invariant=[VAULT-INV-002](#vault-inv-002) / [VAULT-INV-003](#vault-inv-003), integration (burn -> request Effects -> transfer order).

### <a id="vault-fr-003"></a>VAULT-FR-003: `redeemWithPermit` (redeem through permit)

- **Type**: Functional | **Source**: [Zapper](Zapper.md) permit path / transaction-count reduction for delegated contracts
- **Signature**: `redeemWithPermit(uint256 _dTokenAmount, uint256 _deadline, uint8 _v, bytes32 _r, bytes32 _s, address _receiver) returns (uint256 underlyingReceived, uint256 requestId)`
- **Purpose**: Use EIP-2612 Permit to combine redeem into one transaction without prior approve. This helper is provided for Zapper Router permit paths and transaction-count reduction for delegated contracts.
- **Authorization**: permissionless (`pausedRedeem == false` and `whenUnderlyingReady`).
- **Preconditions (Checks)**: not paused; `whenUnderlyingReady`; `_dTokenAmount != 0`; `_receiver != address(0)`; `_dTokenAmount` exactly corresponds to an Underlying base unit; cache-free `A_confirmed >= L_effective`; a valid permit signature, or the permit has already been executed and allowance to the Vault is at least `_dTokenAmount`.
- **Behavior (Effects)**:
  1. Pause check (`Paused`)
  2. Underlying-ready check (`UnderlyingNotSet` / `UnderlyingMismatch`, [VAULT-FR-011](#vault-fr-011))
  3. Input validation (`_dTokenAmount == 0` -> `ZeroAmount`)
  4. **Receiver validation** — `_receiver == address(0)` reverts with `ZeroAddress` before permit nonce consumption
  5. **Checks: exact required Underlying calculation** — execute the same exact check as [VAULT-FR-002](#vault-fr-002) before permit. If `InvalidDTokenAmount`, do not consume permit nonce or allowance
  6. **Checks: pre-state full backing** — execute the [VAULT-SEC-010](#vault-sec-010) `A_confirmed` check before permit. On failure, do not change permit nonce, allowance, or dToken balance
  7. **Execute Permit / check allowance** — `dToken.permit(msg.sender, vault, _dTokenAmount, _deadline, _v, _r, _s)` issues allowance to the Vault. If permit fails but `allowance(msg.sender, vault) >= _dTokenAmount` already holds, such as after a third party submitted the same permit first, continue; otherwise revert with `PermitFailed` ([DTKN-FR-007](dToken.md))
  8. **Move dToken to Vault** — `safeTransferFrom(msg.sender, vault, _dTokenAmount)`, and the Vault temporarily holds the dToken
  9. **Checks: measure buffer** — `bufferBal = bufferBalance()`
  10. **Effects: burn dToken** — `dToken.burn(address(this), _dTokenAmount)` (**burn dToken held by the Vault itself**; this is the only difference from `redeem`)
  11. **Interactions: thereafter identical to redeem** — if buffer is sufficient, pay immediately; if insufficient, first-come-takes-all + WithdrawRequest registration ([VAULT-FR-002](#vault-fr-002))
- **Revert / early return**: `_dTokenAmount == 0` -> `ZeroAmount`; `_receiver == address(0)` -> `ZeroAddress` (before permit nonce consumption); dToken amount not divisible by multiplier / `underlyingNeeded == 0` -> `InvalidDTokenAmount` (before permit nonce consumption); `A_confirmed < L_effective` -> `BackingRatioBelowMinimum(actual, 1e18)` (before permit nonce / allowance consumption); `pausedRedeem` -> `Paused`; Underlying unset -> `UnderlyingNotSet`; mismatch -> `UnderlyingMismatch`; `dToken.permit` failure with insufficient existing allowance to the Vault -> `PermitFailed`; `safeTransferFrom` failure -> upstream revert; later paths inherit [VAULT-FR-002](#vault-fr-002) failure paths.
- **Emitted event**: `Redeemed(user, receiver, dTokenAmount, underlyingPaidNow, requestId)` (same signature as redeem; `user = msg.sender` = permit signer) / `WithdrawRequested(...)` only when buffer is insufficient.
- **Design notes**:
  - **Only difference from `redeem`**: the burn target is `address(this)` (the Vault itself), not `msg.sender`. Permit -> transferFrom temporarily moves dToken to the Vault.
  - This function assumes dToken implements EIP-2612 Permit ([DTKN-FR-007](dToken.md)).
  - **Permit front-run resistance**: a third party can submit an EIP-2612 permit first. If that consumes the nonce but leaves sufficient allowance, redemption continues so the signer's bundled operation cannot be griefed.
  - **DOMAIN_SEPARATOR follows the actual token name**: dToken overrides `_EIP712Name()` to return `name()`, so after `setTokenInfo` fixes `name`, the EIP-712 DOMAIN_SEPARATOR reflects the real name (e.g. `dWBTC`). Permit signatures built by standard wallets from `name()` verify directly (basis: [DTKN-FR-007](dToken.md)).
- **Verification**: unit (permit -> burn(self) -> branches and reverts, existing allowance after permit front-run, nonce/allowance unchanged while underbacked), integration (standard wallet signature verifies).

### <a id="vault-fr-004"></a>VAULT-FR-004: `allocate` (allocate buffer surplus to Strategies)

- **Type**: Functional | **Source**: Product-Overview "Strategy allocation" / push model
- **Signature**: `allocate()`
- **Purpose**: Allocate surplus Vault buffer across pre-registered Strategies according to fixed weights. The purpose is to shrink buffer down to target level. The function receives no destination or ratio arguments; it only follows preconfigured Strategies and weights.
- **Authorization**: `ALLOCATOR_ROLE` only. `pausedAllocation == false` (`whenNotPausedAllocation`).
- **Preconditions (Checks)**: `block.timestamp >= lastAllocatorTime + allocatorCooldown`; `pausedAllocation == false`.
- **Behavior (Effects)**:
  1. **Measure managed assets and buffer** — `M = managedUnderlying = bufferBalance() + Σ live min(Strategy_i.estimatedTotalUnderlying(), Strategy_i.principal())`. Protected backstop reserve and cached Strategy value are not allocation targets or target-buffer inputs. If any registered Strategy lacks a live valuation, regardless of enabled state or weight, treat `M` as zero and fail closed for all outbound movement. If `M == 0`, return without updating `lastAllocatorTime` or emitting `Allocated`, allowing an immediate retry after dependency recovery without waiting for cooldown
  2. **Calculate target buffer** — `B_target = max(M * bufferTargetBps / 10000, bufferFloor) + pendingWithdrawals` (reason for adding `pendingWithdrawals`: prevent claim funds from flowing out to Strategies, [VAULT-FR-006](#vault-fr-006))
  3. **Determine allocation amount `excess`** — `excess = min(max(B - B_target, 0), allocateMaxMove)`
  4. **Allocate `excess` across Strategies** (allocation rules below. Actual allocation per Strategy emits `StrategyAllocated(strategy, amount)`)
  5. **Live recheck full backing after a non-zero allocation** — when `excess != 0`, require cache-free `A_confirmed >= L_effective`. If ERC-4626 / Morpho share mint and `convertToAssets` rounding, or a valuation read failure immediately after deposit, prevents proof of full backing, revert the entire `allocate()` call with `BackingRatioBelowMinimum(actual, 1e18)` and restore Vault/Strategy balances, shares, principal, cache, and `lastAllocatorTime` to the pre-allocation state. When `excess == 0`, no backing-changing transfer can occur, so skip this post-check and preserve the specified `Allocated` event and cooldown update
  6. **Set `lastAllocatorTime = block.timestamp`**
- **Allocation rules**:
  - Only registered Strategies with `enabled = true` are targets
  - Allocation to each Strategy is prorated by `weightBps_i / totalWeightBps`
  - Allocation **first transfers Underlying with `safeTransfer(strategy, share)`, measures the Strategy's net `received` amount by balance delta, and then calls `strategy.deposit(share, received)`**. The Strategy returns `received` on success or 0 after exact recovery and skip
  - Do not send an amount that exceeds each Strategy's cap headroom (`cap_i - estimatedTotalUnderlying_i`). If the managed-assets preflight cannot read `estimatedTotalUnderlying()` or `principal()` for any registered Strategy, return early from the entire allocation run. If only the per-Strategy cap reread fails after preflight, skip that Strategy's share
  - `BaseStrategy.deposit` executes `_doDeposit(received)` in a separate self-only call frame. A non-zero `share` with zero `received` fails closed. If the external protocol rejects a non-zero receipt, that frame's protocol effects roll back. Only when `share == received` (no outbound transfer fee) and both the Strategy decrease and Vault increase equal `received` does it return the idle Underlying to the Vault and return 0. The Vault emits `StrategyAllocationSkipped` and continues to later Strategies
  - If `share != received`, the return transfer fails, or fee-on-transfer / rebasing makes either balance delta differ, `DepositRecoveryFailed` reverts the whole `allocate()` call back through the initial `safeTransfer`. A simple catch that leaves Underlying idle in the Strategy is not permitted
  - A successful deposit cannot use fallback cache as authority to commit allocation. If the live post-allocation state cannot prove `A_confirmed >= L_effective`, revert the whole call. Do not add a rounding epsilon. Pre-fund any required rounding cushion through the existing protected `backstopDeposit` reserve without increasing liabilities. Derive the cushion from fork measurements at approved venues, actual share prices, and `allocateMaxMove`; do not assume a fixed one-unit bound
  - **Amounts reduced by caps and shares skipped due to a post-preflight valuation reread or deposit failure are not reallocated to other Strategies** (they remain in the Vault buffer)
  - Operationally, maintain `totalWeightBps == 10000`. If intentionally lower, note that the amount prorated among registered Strategies increases
- **Revert / early return**: `block.timestamp < lastAllocatorTime + allocatorCooldown` -> `CooldownNotMet`; `pausedAllocation == true` -> revert; `M == 0` (zero assets or any registered Strategy lacks live valuation) -> early return (no event/time update); a deposit rejection that cannot be recovered exactly -> whole-call revert with `DepositRecoveryFailed`; after non-zero allocation, live `A_confirmed < L_effective` -> whole-call revert with `BackingRatioBelowMinimum(actual, 1e18)`. Only a rejection with exact recovery skips that Strategy.
- **Emitted event**: `StrategyAllocated(strategy, amount)` (actual allocation per Strategy) / `StrategyAllocationSkipped(strategy)` (post-preflight cap valuation reread unavailable, cap reached, or exact recovery after deposit rejection) / `Allocated(bufferBefore, targetBuffer, bufferAfter)` (aggregate buffer before/target/after for one `allocate()` run, [VAULT-EVT-004](#11-events-and-monitoring-requirements-evt)). Managed-assets preflight failure returns without outbound movement, cooldown consumption, or an event; external monitoring correlates `getStrategyStatuses()` availability with a missing `Allocated` event after the keeper call. A skip with healthy availability and cap headroom identifies deposit rejection.
- **Design notes**:
  - Per-Strategy invested amounts can be tracked via `StrategyAllocated`. Current value, AUM, and estimated PnL use `getStrategyStatuses()` as the primary source and are time-series snapshotted by subgraph (The Graph) operations ([§11](#11-events-and-monitoring-requirements-evt)).
  - Example: `excess = 1000`, A (`weightBps = 5000`, cap headroom 200), B (`weightBps = 5000`, cap headroom 1000), `totalWeightBps = 10000` -> A computes 500 -> capped to 200, A=200; B computes 500 -> cap allows, B=500; **remaining 300 stays in Vault buffer**. If A valuation (estimate or principal) reverts during managed-assets preflight, the entire allocation run returns early and B receives nothing.
- **Verification**: unit (cooldown, pause, M==0, cap clamp, underbacked `allocateMaxMove == 0` remains an observable zero-move run that consumes cooldown, all-outbound stop plus no cooldown consumption and automatic recovery on estimate/principal failure, exact recovery plus continuation after deposit rejection, full revert when transfer fees prevent exact recovery, no reallocation, full-state rollback on ERC-4626/Morpho share-rounding shortfall and post-deposit valuation failure, success with a measured protected cushion), invariant=[VAULT-INV-006](#vault-inv-006).

### <a id="vault-fr-005"></a>VAULT-FR-005: `receiveFromStrategy` (Strategy -> Vault push receipt)

- **Type**: Functional | **Source**: Product-Overview "push model" / [Strategy](strategies/Strategy.md) `sendToVault` / protocol-specific emergency recovery
- **Signature**: `receiveFromStrategy(uint256 _declaredAmount) returns (uint256 received)`
- **Purpose**: The **principal-return Strategy -> Vault intake** in the push model. Routes that return principal or should reduce the Strategy valuation cache are consolidated here, including `sendToVault`, protocol-specific emergency recovery, and generic idle rescue. Yield-only pushes such as `sendProfitToVault` and Underlying reward claims transfer directly into the Vault buffer and do not reduce principal or valuation caches ([Strategy Requirements Specification](strategies/Strategy.md)).
- **Authorization**: registered Strategies only (`msg.sender` must exist in `strategies[]`; membership, not a role. Allowed while it remains in `strategies[]`, whether enabled or disabled).
- **Preconditions (Checks)**: `msg.sender` is a registered Strategy.
- **Behavior (Effects)**:
  1. **Registration validation** — if `msg.sender` is not a registered Strategy, revert with `NotRegisteredStrategy`
  2. **Zero short-circuit** — if `_declaredAmount == 0`, emit `ReceivedFromStrategy(msg.sender, 0, 0)` and return `0` (do not revert)
  3. **Actual received accounting** — record Vault balance before receipt, pull `_declaredAmount` with `safeTransferFrom(msg.sender, vault, _declaredAmount)`, and determine `received` as balance delta
  4. **Valuation cache reconciliation** — on exact delivery (`received == _declaredAmount`), reduce the fallback cache's `conservativeValue` by `received` without updating `updatedAt` only while a positive residual remains. If `received` exhausts or exceeds that estimate, invalidate the cache: subtraction-to-zero is not a live observation of a zero-valued position. A receipt proves delivery into the Vault buffer, not a full valuation of what remains in the Strategy. On a fee-on-transfer / rebase mismatch, invalidate the cache because the receipt alone cannot prove how much upstream position value moved. This prevents an ambiguous or expired cache from reaching pricing as fresh during a live valuation outage
  5. **Emit `ReceivedFromStrategy(msg.sender, _declaredAmount, received)`**
- **Revert / early return**: unregistered Strategy -> `NotRegisteredStrategy`; `_declaredAmount == 0` -> emit `ReceivedFromStrategy(_, 0, 0)` and return `0` (no revert); `safeTransferFrom` failure (balance/allowance) -> upstream revert.
- **Emitted event**: `ReceivedFromStrategy(strategy, declaredAmount, received)` (`declaredAmount` is requested amount; `received` is actual Vault balance delta; [VAULT-EVT-005](#11-events-and-monitoring-requirements-evt)).
- **Design notes**:
  - **Approval direction is Strategy -> Vault**: during initialization, the Strategy performs `underlying.safeApprove(vault, type(uint256).max)` **to the Vault**, allowing the Vault to pull with `safeTransferFrom` ([VAULT-FR-011](#vault-fr-011) / [Strategy Requirements Specification](strategies/Strategy.md)).
  - **Declared vs actual receipt separation**: `received` is not the declared amount; it is **balance delta**, preventing accounting drift if fee-on-transfer / rebasing behavior makes actual receipt lower than declared. The calling Strategy reduces its own `principal` based on this `received` value (= return value; [Strategy Requirements Specification](strategies/Strategy.md)).
  - **Principal-return cache reconciliation**: exact delivery reduces a positive residual cache by actual receipt; exhaustion (including an already-zero cache) or a declared/received mismatch invalidates it. Yield-only `sendProfitToVault` / Underlying reward claims bypass this function and do not move principal or cache. Treasury yield transfer is handled by `transferYieldToTreasury` ([VAULT-FR-007](#vault-fr-007)).
  - **Partial recovery does not renew cache TTL**: an exact receipt proves only that a known amount moved from the Strategy into the Vault, not the current value of the remaining position. Advancing `updatedAt` would let repeated small recoveries indefinitely renew an old high cache that may contain unobserved loss. TTL therefore continues from the last successful full live valuation and fails closed after expiry even during partial recovery. Pricing availability returns as soon as both live valuation reads recover. Permissionless `refreshStrategyValuation` then stores that full valuation in the bounded cache for subsequent transient read failures. Incident writeoff finalizes confirmed accounting loss but does not restore availability while valuation remains unreadable ([VAULT-FR-009](#vault-fr-009)).
  - **`nonReentrant`**.
- **Verification**: unit (unregistered revert, zero short-circuit, balance-delta accounting, cache invalidation and live recovery after declared/received mismatch, partial recovery does not extend TTL, live-read recovery restores availability, full refresh repopulates the cache), invariant=[VAULT-INV-005](#vault-inv-005).

### <a id="vault-fr-006"></a>VAULT-FR-006: `claim` (receive delayed redemption for a WithdrawRequest)

- **Type**: Functional | **Source**: redemption flow (delay on buffer shortage)
- **Signature**: `claim(uint256 _requestId)`
- **Purpose**: Allow a user to withdraw from the Vault after `withdrawDelay` has elapsed for a `WithdrawRequest` issued during a buffer-insufficient redeem. The purpose is to receive the remaining amount that could not be paid immediately.
- **Authorization**: permissionless. Anyone may trigger settlement of a matured request, but payment is fixed to the recorded `req.owner`; the caller cannot redirect it. It is **not affected by `pausedDeposit` / `pausedRedeem`, but is subject to `pausedClaim` (GUARDIAN, [VAULT-FR-014](#vault-fr-014))**. In addition, an unsettled claim is subject to the on-chain full-backing guard in [VAULT-SEC-010](#vault-sec-010), which stops a first-come buffer drain during actual Strategy loss before Guardian response.
- **Preconditions (Checks)**: `pausedClaim == false` (`Paused` while stopped); request exists. Settlement of an unsettled request requires `block.timestamp >= req.claimableAt`, cache-free `A_confirmed >= L_effective`, and `bufferBalance() >= req.underlyingAmount`. An already-settled request returns `0` idempotently.
- **Behavior (Effects)** (Checks -> buffer validation -> Effects -> Interaction CEI order):
  1. **Existence validation** — if `withdrawRequests[_requestId].owner == address(0)`, revert with `RequestNotFound` (prevents calls to unissued IDs)
  2. **Settled short-circuit** — if `req.claimed == true`, return `0` without changing state, transferring funds, or emitting an event. A permissionless settlement that front-runs the owner's transaction does not make the owner's retry revert
  3. **Time validation** — if `block.timestamp < req.claimableAt`, revert with `RequestNotReady` (no early claim)
  4. **Checks: pre-state full backing** — if `A_confirmed < L_effective`, revert with `BackingRatioBelowMinimum(actual, 1e18)`. The post-claim decrease in `pendingWithdrawals` or assets must not be counted in advance
  5. **Buffer balance validation** — if `bufferBalance() < req.underlyingAmount`, revert with `InsufficientBuffer` (no partial claim; retry after buffer recovery)
  6. **State update (Effects)** — `req.claimed = true`, `pendingWithdrawals -= req.underlyingAmount`
  7. **Payment (Interactions)** — transfer `req.underlyingAmount` to the recorded `req.owner` via `safeTransfer`; there is no caller payout or arbitrary receiver parameter
- **Revert / early return**: `pausedClaim` -> `Paused`; `_requestId == 0` or unissued ID -> `RequestNotFound`; already claimed -> early return `0`; `block.timestamp < req.claimableAt` -> `RequestNotReady`; `A_confirmed < L_effective` -> `BackingRatioBelowMinimum(actual, 1e18)`; `bufferBalance() < req.underlyingAmount` -> `InsufficientBuffer` (state changes roll back; retry after buffer/backing recovery).
- **Emitted event**: `WithdrawClaimed(user, requestId, amount)` (`user` is `req.owner` regardless of caller, `amount` is `req.underlyingAmount`, [VAULT-EVT-006](#11-events-and-monitoring-requirements-evt)).
- **Design notes**:
  - **WithdrawRequest struct**: issued during a buffer-insufficient redeem and persisted in `withdrawRequests[requestId]`. Fields: `owner` (address, fixed payout recipient; records redeem `_receiver`) / `underlyingAmount` (uint256, shortfall `remaining`) / `claimableAt` (uint256, `block.timestamp + withdrawDelay`) / `claimed` (bool, double-claim prevention). `requestId` is assigned by `nextRequestId` (initial 1, +1 per redeem issuance). `requestId = 0` is reserved for "immediate completion" and is not registered in `withdrawRequests`.
  - **Permissionless trigger / fixed payout**: even when redeem `msg.sender` (caller) and `_receiver` (final receiver) differ, `WithdrawRequest.owner = _receiver` stores the entitlement and fixed payout recipient. For an EOA, Safe, or contract with no arbitrary execution function, the owner, a keeper, or any third party may trigger `claim()` and the Underlying still goes only to the owner. The caller cannot steal or redirect it.
  - **Idempotent retry**: if a permissionless caller front-runs the owner's claim transaction, the owner's later call succeeds with `0` and performs no second transfer, event, or `pendingWithdrawals` decrement. The caller still pays gas for an already-settled transaction; this hardening removes the revert-based grief and failed UX, not the cost of an unnecessary transaction.
  - **Ordering**: no FIFO constraint. Requests past `claimableAt` can be claimed in any order. There is a **race condition** where the first user to call after buffer recovery receives funds; the accepted risk and operational response are in [§12](#12-failure-and-exception-behavior-err).
  - **Stop during impairment**: while `A_confirmed < L_effective`, a claim cannot settle even when the buffer can pay that request. Once backstop replenishment or Strategy recovery restores confirmed full backing, the same request can be retried without a manual unpause.
  - **Expiration**: none. A request remains claimable indefinitely while `claimed == false`.
  - **Partial claim**: not allowed. If buffer is insufficient, the full claim reverts.
  - **Role of `pendingWithdrawals`**: tracks the total unclaimed balance. It is added in `allocate()` as `B_target += pendingWithdrawals` to prevent claim funds from flowing to Strategies ([VAULT-FR-004](#vault-fr-004)). In `transferYieldToTreasury()` it (a) is treated as a user liability via `L_effective = L_user + L_pending` to prevent accounting over-transfer, and (b) is part of the liquidity reserve `B_reserve` (the same one `allocate` keeps, including `pendingWithdrawals`) that the transfer cap subtracts from the liquid buffer, so claim liquidity is not drained by a Treasury sweep ([VAULT-FR-007](#vault-fr-007)).
  - **CEI note**: if buffer is insufficient, the function reverts before Effects, so `claimed = true` is not persisted. The settled short-circuit exits before any external call. `nonReentrant` also prevents reentrancy.
  - Example: user A calls `redeem(100, A)` with buffer 30 / shortfall 70 -> `WithdrawRequest{owner:A, underlyingAmount:70, claimableAt: now+1day, claimed:false}` is issued with requestId=5. After 24h, ALLOCATOR replenishes 70 into the buffer via `sendToVault(70)` on the target Strategy. Keeper B calls `claim(5)` -> existence/unclaimed/time/buffer OK -> `claimed=true`, `pendingWithdrawals -= 70` -> send 70 to A while B receives nothing. A retry by A returns `0` without another transfer, event, or accounting update. An unissued ID still reverts with `RequestNotFound`.
- **Verification**: unit (existence/time/buffer reverts, settled idempotent return, owner retry after permissionless front-run, fixed payout, no caller receipt, contract receiver, no partial claim, no expiry, underbacked pre-effects stop and restart after repair), invariant=[VAULT-INV-004](#vault-inv-004).

### <a id="vault-fr-007"></a>VAULT-FR-007: `transferYieldToTreasury` (Treasury transfer of profit)

- **Type**: Functional | **Source**: Product-Overview "Treasury monetization" / Stage 2 of push-model monetization
- **Signature**: `transferYieldToTreasury() returns (uint256 transferred)`
- **Purpose**: Send to Treasury only the portion of the Vault liquid buffer for which managed assets exceed liabilities. Push-model monetization has two stages; this function is the Vault-side Stage 2. Stage 1 = each Strategy pulls realized profit into the buffer via `Strategy.sendProfitToVault` (Strategy function; [Strategy Requirements Specification](strategies/Strategy.md); ALLOCATOR calls one Strategy at a time).
- **Authorization**: `ALLOCATOR_ROLE`, `nonReentrant` (Stage 1 `Strategy.sendProfitToVault` is also ALLOCATOR). `pausedAllocation == false` (treasury sweep leaving the Vault is stopped by emergency allocation pause). Not subject to `allocatorCooldown`.
- **Preconditions (Checks)**: caller has ALLOCATOR_ROLE; `pausedAllocation == false`.
- **Accounting principles**:
  - `A = totalUnderlying()`: total assets for backing / oracle. Vault raw Underlying balance (liquid buffer + backstop reserve) plus each Strategy's conservative valuation
  - `M = managedUnderlying`: managed assets for allocation / Treasury. `bufferBalance() + Σ live min(estimatedTotalUnderlying, principal)`, excluding protected backstop reserve. If any registered Strategy valuation cannot be read, do not send against cached value or a partial sum; set `M = 0` and return early from the entire outbound operation
  - `L_user = actual dToken liabilities`: based on `convertToUnderlying(dToken.totalSupply())`, rounded up to 1 base unit if total supply contains dust not exactly corresponding to an Underlying base unit due to legacy/migration
  - `L_pending = pendingWithdrawals`: unclaimed balance of issued delayed redemptions ([VAULT-FR-006](#vault-fr-006))
  - `L_effective = L_user + L_pending`
  - Principle: **always maintain `A >= L_effective`** (`A < L_effective` is principal impairment. It is primarily prevented through buffer / cap / Strategy selection; if it occurs, `backingRatio()` reflects it downward into the oracle = [VAULT-FR-016](#vault-fr-016) / [VAULT-INV-001](#vault-inv-001))
  - Buffer surplus (transferable profit): `surplus = max(M - L_effective, 0)`. Backstop reserve does not create surplus
- **Behavior (Effects)**:
  1. **Calculate excess** — `M = managedUnderlying`, `L = L_effective`. If `M <= L`, emit `YieldTransferredToTreasury(0, treasury)` and return `0`
  2. **Clamp by buffer above the liquidity reserve** — `surplus = M - L`. The transfer is capped at the liquid buffer above the same liquidity reserve that `allocate` keeps, `B_reserve = max(M * bufferTargetBps / 10000, bufferFloor) + pendingWithdrawals` (identical to `B_target` in [VAULT-FR-004](#vault-fr-004); implemented as the shared helper `_requiredBuffer`): `transferred = min(surplus, max(bufferBalance() - B_reserve, 0))`. **Using buffer as the upper bound** avoids consuming Underlying inside Strategies or protected backstop reserve, and **subtracting `B_reserve`** prevents a Treasury sweep from draining the liquidity reserved for pending claims (`pendingWithdrawals`) and the buffer target ([VAULT-FR-006](#vault-fr-006)). `surplus` (= `M - L_effective`) is retained as the accounting upper bound, so principal is never sent even when the buffer above the reserve includes it
  3. **Transfer** — if `transferred > 0`, `safeTransfer` to `treasury`
  4. **Emit `YieldTransferredToTreasury(transferred, treasury)`**
- **Revert / early return**: non-ALLOCATOR -> revert; `pausedAllocation == true` -> `Paused`; `M <= L` -> emit `YieldTransferredToTreasury(0, treasury)` and return `0` (no revert).
- **Emitted event**: `YieldTransferredToTreasury(amount, treasury)` (emitted by Vault; `amount` is amount sent to Treasury and is emitted even when 0, [VAULT-EVT-007](#11-events-and-monitoring-requirements-evt)). Stage 1 `ProfitSentToVault` is emitted **by Strategy** ([Strategy Requirements Specification](strategies/Strategy.md)).
- **Design notes**:
  - **Reason for two-stage separation**: Profit residing inside Strategies cannot be reached by this function alone (due to the buffer cap). ALLOCATOR first pulls profit into the buffer through Strategy `sendProfitToVault` ([Strategy Requirements Specification](strategies/Strategy.md)), then sends it to Treasury through this function.
  - **Suppressing over-transfer**: `M` uses conservative `min(estimatedTotalUnderlying, principal)` to prevent pre-recognition of unrealized profit (`est > principal`), and transfer is capped by buffer so Strategy assets and backstop reserve are not consumed. However, if a loss is not reflected in `est` (or writeoff is delayed) and `est` does not fall below principal, surplus can be overstated and buffer can be over-transferred. Timely `writeoffStrategyPrincipal` ([VAULT-FR-009](#vault-fr-009)) and conservative estimates mitigate this ([§9](#9-security-requirements-sec) / [§12](#12-failure-and-exception-behavior-err)).
  - **Isolation of individual Strategy failures**: in the push model, ALLOCATOR calls each Strategy one by one with `sendProfitToVault`, so one failure does not cascade to others. This function preflights every registered Strategy valuation view; if any is unavailable, `managedUnderlying = 0` and the entire Treasury transfer returns early. It does not transfer against cached value or an incomplete partial sum.
  - **Non-Underlying and non-position reward tokens are out of scope**: `transferYieldToTreasury` handles only Underlying in the Vault liquid buffer and does not touch backstop reserve. Other-token rewards such as Aave incentives / Merkl are excluded from `totalUnderlying()` / `backingRatio()` and sent to Treasury through Strategy-side `sweepRewardToken`. Position / receipt / accounting tokens such as Aave aToken, Morpho vault shares, or Euler eToken / vault shares are not rewards and are rejected from sweeps as protected tokens in derived Strategies. If rewards are used for backing repair, Treasury/backstop converts them to Underlying and explicitly deposits through `backstopDeposit` or similar.
  - Example: Strategy A (`principal=1000`, `est=1080`), buffer=50, backstop reserve=0, `L_effective=1000` -> before Stage 1, `M = 50 + min(1080,1000) = 1050`, `surplus=50` (80 profit inside Strategy is hidden by conservative valuation). ALLOCATOR calls `A.sendProfitToVault()` (Strategy function): realized 80 enters buffer, buffer=130, principal unchanged. ALLOCATOR calls `transferYieldToTreasury()`: `M = 130 + min(1000,1000) = 1130`, `surplus=130`, `transferred = min(130,130) = 130` -> Treasury receives 130 (this example assumes `bufferTargetBps=0` and `pendingWithdrawals=0`, so `B_reserve=0` and no reserve is subtracted; with `pendingWithdrawals>0` or `bufferTargetBps>0` the transfer shrinks to `min(surplus, max(bufferBalance()-B_reserve,0))`). If backstop reserve exists, it is excluded from `M`, so reserve deposits alone do not create Treasury surplus.
- **Verification**: unit (M<=L early path, buffer clamp, min valuation, backstop exclusion), invariant=[VAULT-INV-005](#vault-inv-005).

### <a id="vault-fr-008"></a>VAULT-FR-008: Strategy whitelist, registration, and removal (`addToWhitelist` / `removeFromWhitelist` / `addStrategy` / `removeStrategy`)

- **Type**: Functional | **Source**: Product-Overview "Strategy allocation" / risk control (two-stage approval)
- **Signature**: `addToWhitelist(address strategy)` / `removeFromWhitelist(address strategy)` / `addStrategy(IStrategy strategy, uint256 weightBps, uint256 cap)` / `removeStrategy(IStrategy strategy)`
- **Purpose**: Because Strategy registration creates large fund risk, "whitelist registration (prior approval) -> actual addition (production activation)" is explicitly separated into two stages. Removal deletes a registered Strategy (requires `principal == 0` and live `estimatedTotalUnderlying == 0`).
- **Authorization**: risk-increasing operations (`addToWhitelist` / `addStrategy`) are GOV_MULTISIG (Vault `GOV_ROLE`, holder = Timelock = 12h delay). Fail-safe operations (`removeFromWhitelist` / `removeStrategy`) are `GUARDIAN_ROLE` (immediate). Removal operations do not affect backing valuation (remove requires `principal == 0` and live `estimatedTotalUnderlying == 0`, meaning contribution and residual assets are already 0; whitelist removal does not affect registered Strategies), so immediate execution is safe ([VAULT-GOV-004](#vault-gov-004)).
- **Preconditions (Checks)**:
  - `addToWhitelist`: `strategy != address(0)`; `strategy.code.length > 0`; not already whitelisted (`AlreadyWhitelisted` if already true)
  - `addStrategy`: `whitelistedStrategies[strategy] == true` (`NotWhitelisted` if not approved); **`vault.underlying() != address(0)`** (cannot register in inactive placeholder, `UnderlyingNotSet`) and **`strategy.underlying() == vault.underlying()`** (`UnderlyingMismatch` if collateral asset differs); not already registered (`StrategyAlreadyExists`); `strategies.length < MAX_STRATEGIES` (`MAX_STRATEGIES = 32`, `TooManyStrategies`); `totalWeightBps + weightBps <= 10000` (`WeightExceedsBps`)
  - `addStrategy`: `strategy != address(0)`; `strategy.code.length > 0` (EOA / undeployed address not allowed)
  - `removeFromWhitelist`: already whitelisted
  - `removeStrategy`: target is registered. **`strategy.principal() == 0`** (`StrategyHasPrincipal` if remaining principal remains or `principal()` cannot be read) and live **`strategy.estimatedTotalUnderlying() == 0`**. If live valuation cannot be read, or residual assets / uncollected yield remain, `StrategyHasAssets`. Executable regardless of whether enabled or disabled while still in `strategies[]`
- **Behavior (Effects)**:
  1. `addToWhitelist`: set `whitelistedStrategies[strategy] = true`, emit `StrategyWhitelisted(strategy)`
  2. `removeFromWhitelist`: set `whitelistedStrategies[strategy] = false`, emit `StrategyRemovedFromWhitelist(strategy)` (does not affect existing registrations)
  3. `addStrategy`: after all checks, append to `strategies[]`, set `strategyConfigs[strategy] = {enabled, weightBps, cap}`, update `totalWeightBps += weightBps` (derived value recalculation, [§7](#7-state-variables-and-accounting-model)), emit `StrategyAdded(strategy, weightBps, cap)`
  4. `removeStrategy`: after confirming `principal == 0` and live `estimatedTotalUnderlying == 0`, remove from `strategies[]`, discard valuation cache, and emit `StrategyRemoved(strategy)`
- **Revert / early return**: `addToWhitelist`: `ZeroAddress` / `NotContract` / `AlreadyWhitelisted`. `removeFromWhitelist`: not whitelisted -> `StrategyNotFound`. `addStrategy`: `ZeroAddress` / `NotContract` / `NotWhitelisted` / `UnderlyingNotSet` / `UnderlyingMismatch` / `StrategyAlreadyExists` / `TooManyStrategies` / `WeightExceedsBps`. `removeStrategy`: not registered -> `StrategyNotFound`; remaining or unreadable principal -> `StrategyHasPrincipal`; live valuation failure or residual assets -> `StrategyHasAssets`.
- **Emitted event**: `StrategyWhitelisted(strategy)` / `StrategyRemovedFromWhitelist(strategy)` / `StrategyAdded(strategy, weightBps, cap)` / `StrategyRemoved(strategy)` ([VAULT-EVT-008](#11-events-and-monitoring-requirements-evt)).
- **Design notes**:
  - **Whitelist removal != Strategy removal**: recovery of funds from existing Strategies (`Strategy.sendToVault`, [Strategy Requirements Specification](strategies/Strategy.md)) and principal zeroing (`writeoffStrategyPrincipal`, [VAULT-FR-009](#vault-fr-009)) are preconditions for `removeStrategy`. Before removal, any unrecoverable amount must be written off to zero `principal`, and any recoverable residual assets/uncollected yield must be returned until live `estimatedTotalUnderlying() == 0`. Strategies whose live valuation cannot be read fail closed on removal to avoid erroneous deletion. Completion emits `StrategyRemoved` (there is no failed-removal retry rescue mechanism; withdrawal failures are handled by push recovery + writeoff).
  - **Underlying invariant in `addStrategy` (restores pre-activation guard)**: In the push model, the Underlying approval direction is reversed (**Strategy approves Vault at initialization**, [VAULT-FR-005](#vault-fr-005)), and `addStrategy` does not touch Underlying. Therefore the implicit pre-activation guard that a placeholder Vault (`underlying == address(0)`) would revert on `underlying.safeApprove` is lost. It is restored through **explicit preconditions** (`underlying != address(0)` and `strategy.underlying() == vault.underlying()`). Effects: (1) force activation order (`setUnderlying` ([VAULT-FR-011](#vault-fr-011)) -> `addStrategy`), (2) guarantee Vault/Strategy **collateral asset equality** at registration (preventing accidental registration of a Strategy for a different asset and later sending/pulling the wrong Underlying).
  - **Strategy count bound**: `MAX_STRATEGIES = 32` is an explicit gas and operability bound for every strategy-list loop (`totalUnderlying` / `backingRatio`, `allocate`, `getStrategyStatuses`, `removeStrategy`, and registered checks). More venues require replacing/removing an existing Strategy after funds are recovered or written off, rather than growing the registry unbounded.
  - **Valuation gas regression bound**: `ExternalAuditGas01BackingRatioTest` registers up to 32 independent real `SkyUsdcSUsdsStrategy` proxies, implementations, sUSDS vaults, and converters with live positions in a real `CollateralVault`. Under the baseline compiler configuration, `backingRatio()` costs 1,332,387 gas for a cold 32-Strategy read, 261,884 gas for the warm repeat in the same transaction, and 237,535 gas for a cold five-Strategy read. The test enforces a per-branch cold bound below 2,000,000 gas and a valuation-only bound below 20,000,000 gas for the cold + warm two-pass path when the protocol maximum of ten `CollateralRegistry.redeemCollateral` branches each contain 32 Strategies (12,754,168 gas for the current eight-branch DF topology; 15,942,710 gas for ten branches). This extrapolation is not a full-transaction bound: it excludes surrounding PriceFeed / TroveManager work and the actual Trove redemption loop. Activating a new Strategy type requires rerunning the same maximum-count replay and estimating the target-chain block gas together with `_maxIterationsPerCollateral`; configurations exceeding the regression bound are not approved.
  - **Allocation gas regression bound**: The existing 0 / 1 / 5 / 32 Strategy fixtures measure the `allocate()` body and enforce `< 15,000,000` gas at 32 Strategies. The baseline is 9,057,803 gas for Sky and 4,543,947 gas for Morpho V2. This is a fixture-level CI regression bound, not a guarantee for a real venue. After a Strategy addition, Strategy implementation upgrade, or venue replacement, rerun the maximum-count test and the candidate-specific fork's real `allocate` receipt against the same ceiling; do not approve a configuration that exceeds it.
  - **Why there is no within-block cache**: `backingRatio()` is a solvency read propagated into borrowing, redemption, and liquidation prices. It can change within one block after a Strategy loss, recovery, writeoff, or backstop deposit in an earlier transaction. A block cache added only for gas would create additional invalidation surfaces and a stale-price window, so it is not adopted.
- **Verification**: unit (whitelist guard, guardian remove, Underlying invariant, already registered, max strategy count, weight limit, removal rejection for `principal != 0` / live `estimatedTotalUnderlying != 0` / valuation failure, real Sky valuation gas and Sky / Morpho V2 allocation gas at 32 Strategies, maximum ten-branch two-pass extrapolation), invariant=[VAULT-INV-007](#vault-inv-007) / [VAULT-INV-008](#vault-inv-008).

### <a id="vault-fr-009"></a>VAULT-FR-009: `updateStrategy` / `emergencyDisableStrategy` / `writeoffStrategyPrincipal` (adjust registered Strategy and finalize principal impairment)

- **Type**: Functional | **Source**: Product-Overview "Strategy allocation" / staged emergency recovery
- **Signature**: `updateStrategy(IStrategy _strategy, uint256 _weightBps, uint256 _cap, bool _enabled)` / `writeoffStrategyPrincipal(IStrategy _strategy, uint256 _amount, uint256 _minBackingRatioAfter)` / `forceDeallocateMorphoV2(IStrategy _strategy, address _adapter, bytes _data, uint256 _assets, uint256 _minReceived, uint256 _minBackingRatioAfter) -> (uint256 penaltyShares, uint256 penaltyAssets, uint256 valuationLossAssets)`
- **Purpose**: `updateStrategy` lets GOV update allocation weight (`weightBps`), cap, and enabled flag for a registered Strategy (delayed because it can increase risk or re-enable). Emergency disable is handled immediately by [VAULT-FR-019](#vault-fr-019) `emergencyDisableStrategy`. `writeoffStrategyPrincipal` reduces a Strategy's `principal` to finalize book impairment when `estimatedTotalUnderlying()` is permanently below `principal`, or when an external protocol's effective loss does not appear in the Strategy valuation view. `forceDeallocateMorphoV2` realizes a Morpho V2 share-paid penalty together with same-transaction pauses, valuation refresh, and a post-operation backing guard.
- **Authorization**: `updateStrategy` is GOV_MULTISIG (Vault `GOV_ROLE`, holder = Timelock = 12h delay). `writeoffStrategyPrincipal` and `forceDeallocateMorphoV2` are **`WRITEOFF_ROLE` (held directly by high-quorum GOV multisig, immediate)**. If real loss reflection is delayed, new borrowing can continue against overvalued collateral and bad debt can compound (the Core has no arbitrary reversible borrow-stop switch), so confirmed-loss operations do not go through timelock ([VAULT-GOV-004](#vault-gov-004)).
- **Preconditions and behavior (`updateStrategy`)**:
  1. **Registration validation** — `_strategy` must be registered (remain in `strategies[]`) or revert with `StrategyNotFound`. Disabled Strategies can also have cap / weight / enabled reset by GOV
  2. **Disabled weight invariant** — if `_enabled == false` and `_weightBps > 0`, revert with `InvalidWeight` (**disabled Strategies must always have `weightBps == 0`**. This invariant supports [§7](#7-state-variables-and-accounting-model) / writeoff / remove; [VAULT-INV-009](#vault-inv-009))
  3. **Total weight upper bound** — if `totalWeightBps - old weightBps + _weightBps > 10000`, revert with `WeightExceedsBps`
  4. **Commit** — recalculate `totalWeightBps` (derived value; subtract old and add new, [§7](#7-state-variables-and-accounting-model)) and update config `weightBps` / `cap` / `enabled`
  5. **Emit `StrategyUpdated(strategy, weightBps, cap, enabled)`**
- **Preconditions and behavior (`emergencyDisableStrategy`)**:
  1. **Registration validation** — `_strategy` must be registered or revert with `StrategyNotFound`
  2. **Immediate stop** — record current `weightBps` as `oldWeightBps`, set `totalWeightBps -= oldWeightBps`, `weightBps = 0`, `enabled = false`. Do not change `cap` / `principal` / valuation cache
  3. **Events** — emit `StrategyUpdated(strategy, 0, cap, false)` and `StrategyEmergencyDisabled(strategy, oldWeightBps)`
- **Preconditions and behavior (`writeoffStrategyPrincipal`)**:
  1. **Registration validation** — `_strategy` must be registered (enabled or disabled but still in `strategies[]`) or revert with `StrategyNotFound`
  2. **Backing-impact guard validation** — `_minBackingRatioAfter <= 1e18` or revert. The caller sets this from an incident dry-run so a fat-finger, stale state, or unexpected concurrent recovery/loss cannot markdown backing more than intended
  3. **Subtract on Strategy side** — call `writtenOff = _strategy.writeoffPrincipal(_amount)` (Strategy-side requirements are in [Strategy Requirements Specification](strategies/Strategy.md). Over-specified amounts are clamped to remaining `principal` by the Strategy, and the return value is the actual writeoff amount)
  4. **Post-writeoff backing guard** — after cache refresh/reduction, recompute `backingRatio()`. If it is below `_minBackingRatioAfter`, revert the entire writeoff transaction (including Strategy principal reduction and user-flow pauses)
  5. **Emit `StrategyPrincipalWrittenOff(_strategy, writtenOff)`**. Emit actual principal reduction, not requested amount
- **Preconditions and behavior (`forceDeallocateMorphoV2`)**:
  1. Require `_assets != 0`, `_minReceived != 0`, `_minBackingRatioAfter <= 1e18`, and a registered `_strategy`
  2. In the same transaction, set allocation / deposit / redeem / claim pauses
  3. Call the registered Strategy's Vault-only wrapper and receive total `penaltyShares` / `penaltyAssets` plus tracked `valuationLossAssets`. Donated shares absorb the penalty before tracked shares; exceeding the init-frozen Strategy penalty bound reverts. In that same call, withdraw up to `_assets` of tracked value, transfer it directly to the Vault and reduce principal only by actual receipt
  4. Revert if the Vault balance increase is below `_minReceived`. Refresh the live valuation cache; if unreadable, subtract tracked loss plus withdrawn assets from the cache. Invalidate it if withdrawn assets and actual receipt differ
  5. Revert the entire penalty, recovery and pause transaction if post-operation `backingRatio()` is below `_minBackingRatioAfter`
  6. Emit `MorphoV2ForceDeallocated(strategy, adapter, assets, penaltyShares, penaltyAssets, valuationLossAssets, backingRatioAfter)`
- **Revert / early return**: `updateStrategy`: `StrategyNotFound` / `InvalidWeight` / `WeightExceedsBps`. `emergencyDisableStrategy`: `StrategyNotFound`. `writeoffStrategyPrincipal`: `InvalidBackingRatioGuard` / `StrategyNotFound` / `StrategyWriteoffNotReady` / `BackingRatioBelowMinimum`. `forceDeallocateMorphoV2`: `ZeroAmount` / `InvalidBackingRatioGuard` / `StrategyNotFound` / Strategy penalty guard / `RecoveryBelowMinimum` / `BackingRatioBelowMinimum`.
- **Emitted event**: `StrategyUpdated(strategy, weightBps, cap, enabled)` / `StrategyEmergencyDisabled(strategy, oldWeightBps)` / `StrategyPrincipalWrittenOff(strategy, amount)` / `MorphoV2ForceDeallocated(strategy, adapter, assets, penaltyShares, penaltyAssets, valuationLossAssets, backingRatioAfter)` ([VAULT-EVT-008](#11-events-and-monitoring-requirements-evt) / [VAULT-EVT-009](#11-events-and-monitoring-requirements-evt)).
- **Design notes**:
  - **Canonical registration path is `addStrategy`** (passes whitelist and Underlying-invariant guards, [VAULT-FR-008](#vault-fr-008)). `updateStrategy` only adjusts existing registrations and does not re-check whitelist / Underlying consistency.
  - **Disable procedure**: in emergencies, use `emergencyDisableStrategy(strategy)` (GUARDIAN, immediate, [VAULT-FR-019](#vault-fr-019)). For planned disable, use `updateStrategy(strategy, 0, cap, false)` (with `weightBps` set to 0 per step 2). Either way, the Strategy remains in `strategies[]` and remains a target for push recovery via `receiveFromStrategy`, `writeoffStrategyPrincipal`, and `removeStrategy`. Re-enable is only through delayed-side `updateStrategy` (`addStrategy` re-registration is rejected with `StrategyAlreadyExists`).
  - **Writeoff is bookkeeping only**: no asset movement. Recoverable amounts are first returned to the Vault through `Strategy.sendToVault` ([Strategy Requirements Specification](strategies/Strategy.md)) / emergency recovery (`Strategy.emergencyWithdraw`, [Strategy Requirements Specification](strategies/Strategy.md)), and only unrecoverable residual is written off. Even if Strategy `estimatedTotalUnderlying()` does not reflect loss, GOV can determine the unrecoverable amount and write it off; then the `principal` side of `min(est, principal)` decreases and `totalUnderlying()` / `backingRatio()` reflect it downward.
  - **Writeoff and pricing availability are separate boundaries**: if a full live valuation fails after writeoff, the Vault reduces the cache's `conservativeValue` by the actual writeoff but does not advance `updatedAt` beyond the last full valuation. Once that original TTL has expired, `backingRatioForPricing()` remains unavailable even when a full writeoff reduces cache and principal to zero. Writeoff reflects confirmed accounting loss; it is not evidence that an unreadable valuation is now available. Availability returns as soon as both live reads recover; permissionless full refresh stores that value in the bounded cache.
  - **Safety of over-writeoff requests**: if `_amount > principal`, Strategy clamps, so `principal` cannot go negative. Vault event `amount` is actual reduction, not requested amount. `_minBackingRatioAfter` adds an operator-specified backing-impact guard, so immediate writeoff does not become a silent over-markdown if the requested amount, units, or live state differ from the incident dry-run. Can also be executed on disabled Strategies (`weightBps == 0`).
- **Verification**: unit (registration validation, weight invariant, upper bound, guardian emergency disable, over-writeoff clamp, writeoff on disabled Strategy, full writeoff of a stale cache does not restore pricing availability), invariant=[VAULT-INV-009](#vault-inv-009).

### <a id="vault-fr-010"></a>VAULT-FR-010: `initialize` (placeholder-capable proxy initialization)

- **Type**: Functional | **Source**: Product-Overview "placeholder branch" / deferred binding operations
- **Signature**: `initialize(IERC20 _underlying, IDToken _dToken, address _treasury, address _admin)` (`initializer`, UUPS initialization)
- **Purpose**: Initialize exactly once through the UUPS proxy. At deployment time, the Vault can launch with Underlying unset (placeholder), then be fixed later through [VAULT-FR-011](#vault-fr-011) `setUnderlying` (deferred initialization flow for placeholder branches).
- **Authorization**: Part of deployment procedure (proxy initialization). Binds initial roles to `_admin`.
- **Preconditions (Checks)**:
  - `_dToken` / `_treasury` / `_admin` being `address(0)` reverts with `ZeroAddress`
  - `_dToken.code.length > 0` (EOA / undeployed address not allowed)
  - Only `_underlying` may be `address(0)` (placeholder Vault)
  - For immediate active deploy with `_underlying != address(0)`, require `_dToken.allowedUnderlying(_underlying) == true`
  - Multiple initialization is not allowed (`initializer`)
- **Behavior (Effects)**:
  1. Bind `_underlying` (placeholder allowed) / `_dToken` / `_treasury`
  2. **Initial role grant** — grant `_admin` all **5 roles**: `DEFAULT_ADMIN_ROLE` / `GOV_ROLE` / `ALLOCATOR_ROLE` / `GUARDIAN_ROLE` / `WRITEOFF_ROLE` (in production, `DEFAULT_ADMIN_ROLE` / `GOV_ROLE` move to the shared TimelockController, `ALLOCATOR_ROLE` to `DF_ALLOCATOR`, `GUARDIAN_ROLE` to Guardian multisig, `WRITEOFF_ROLE` to high-quorum GOV multisig, and deployer is revoked from all roles. Post-deploy role rearrangement is part of activation; [§4](#4-actors-roles-and-trust-boundaries) and [VAULT-GOV-004](#vault-gov-004))
  3. **Set deployment defaults** (Day-1 values are canonical in [Parameters.md](../../../Parameters.md) and are overwritten during activation via setters in [VAULT-FR-012](#vault-fr-012)): `bufferTargetBps = 2000` (20%) / `bufferFloor = 0` / `allocateMaxMove = type(uint256).max` (unlimited) / `allocatorCooldown = 0` / `strategyValuationMaxAge = 1 day` / `withdrawDelay = 1 day` / `nextRequestId = 1`. The Day-1 deploy's `_treasury` is supplied via the `DeployLiquity2` required env `DF_TREASURY`; the deploy fails fast if it is unset. handover/verify must also match the same `DF_TREASURY`.
- **Revert / early return**: `_dToken` / `_treasury` / `_admin` zero -> `ZeroAddress`; `_dToken` EOA / undeployed -> `NotContract`; immediate active deploy with Underlying not allowlisted -> `UnderlyingNotAllowed`; re-initialization -> revert.
- **Emitted event**: none (deferred Underlying binding is observed through [VAULT-EVT-010](#11-events-and-monitoring-requirements-evt) `UnderlyingSet`).
- **Design notes**: A placeholder Vault (`underlying == address(0)`) cannot move funds: `deposit` / `redeem` / `redeemWithPermit` / `backstopDeposit` / `releaseBackstopToBuffer` all revert via `whenUnderlyingReady` (inactive). Views (`bufferBalance` / `backstopBalance` / `totalUnderlying`) are placeholder-safe ([VAULT-FR-013](#vault-fr-013)).
- **Verification**: unit (zero-address revert, re-initialization revert, defaults, five roles granted), manual (deployment configuration review).

### <a id="vault-fr-011"></a>VAULT-FR-011: `setUnderlying` (deferred binding, one-shot)

- **Type**: Functional | **Source**: Product-Overview "placeholder branch" / [dToken](dToken.md) deferred-binding consistency
- **Signature**: `setUnderlying(IERC20 _underlying)`
- **Purpose**: Bind the intended Underlying **exactly once** later to a placeholder Vault whose `underlying = address(0)` (Path-B placeholder branch operations). It enforces Vault↔dToken Underlying consistency and prevents silent misvaluation across different assets or decimals.
- **Authorization**: GOV_MULTISIG (Vault `GOV_ROLE`) only.
- **Preconditions (Checks)**: `_underlying != address(0)`; `underlying == address(0)` (unset); `dToken.underlying() == _underlying` (dToken-first); `dToken.allowedUnderlying(_underlying) == true`.
- **Behavior (Effects)**:
  1. **Zero validation** — `_underlying == address(0)` reverts with `ZeroAddress`
  2. **One-shot validation** — if `underlying != address(0)` (already fixed), revert with `UnderlyingAlreadySet` (no overwrite)
  3. **Immediate dToken consistency validation** — if `dToken.underlying() != _underlying`, revert with `UnderlyingMismatch` (requires dToken already fixed to the same Underlying = **enforces dToken-first order**)
  4. **Allowlist validation** — if `dToken.allowedUnderlying(_underlying) == false`, revert with `UnderlyingNotAllowed`
  5. **Commit** — set `underlying = _underlying` and emit `UnderlyingSet(_underlying)`
- **`whenUnderlyingReady` (use-time consistency guard)**: modifier on `deposit` / `redeem` / `redeemWithPermit` / `backstopDeposit` / `releaseBackstopToBuffer`. At the beginning of each call, if `underlying == address(0)`, revert `UnderlyingNotSet`; if `dToken.underlying() != underlying`, revert `UnderlyingMismatch`. Because the check is at use time, **both immediate path (`initialize` with underlying fixed) and delayed path (`setUnderlying`) are covered regardless of activation order**. If the immediate path passes an incorrect Underlying to `initialize`, this guard fails closed at `deposit`.
- **Revert / early return**: `ZeroAddress` / `UnderlyingAlreadySet` / `UnderlyingMismatch` / `UnderlyingNotAllowed`.
- **Emitted event**: `UnderlyingSet(underlying)` (emitted exactly once when the placeholder Vault's Underlying is deferred-bound, [VAULT-EVT-010](#11-events-and-monitoring-requirements-evt)).
- **Design notes**:
  - **Why this is necessary**: `deposit` receives **Vault-side `underlying`** with `safeTransferFrom`, while mint amount is calculated from **dToken-side decimals** (`convertToDToken`). Because Underlying binding is split into **two independent one-shot setters**, one on the Vault (`initialize` / `setUnderlying`) and one on dToken (`setTokenInfo`), binding different assets or decimals silently misvalues collateral and is irreversible once both setters succeed (not only in delayed path, but also in immediate path). Therefore `Vault.underlying == dToken.underlying` is **enforced in code** ([VAULT-SEC-002](#vault-sec-002)).
  - **Why address equality implies decimals/valuation equality**: `whenUnderlyingReady` / `setUnderlying` check only Underlying address equality, but this is enough to guarantee decimals and conversion multiplier consistency. dToken `setTokenInfo` ([DTKN-FR-002](dToken.md)) fixes the `underlying` address and `_decimalMultiplier = 10**(18 - underlyingDecimals)` **from the same token argument atomically**, and only once. Therefore if `dToken.underlying() == underlying`, the multiplier necessarily corresponds to that Underlying's `decimals()`.
  - **Safety constraints**: `setUnderlying` succeeds once only (`UnderlyingAlreadySet`). dToken-side `setTokenInfo` ([DTKN-FR-002](dToken.md)) is also one-shot. Both are immutable thereafter. Activation order is **dToken-first** (`setTokenInfo` -> `setUnderlying`). Reverse order reverts with `UnderlyingMismatch`.
  - **No funds flow to operations before activation (defense in depth)**: (1) the **Underlying invariant** in `addStrategy` ([VAULT-FR-008](#vault-fr-008)) prevents registering Strategies to a placeholder (`UnderlyingNotSet`), (2) `deposit` / `backstopDeposit` / `releaseBackstopToBuffer` revert via `whenUnderlyingReady`, (3) `bufferBalance()` / `backstopBalance()` / `totalUnderlying()` treat `underlying == address(0)` as 0 ([VAULT-FR-013](#vault-fr-013)), (4) `allocate()` effectively early-returns with `managedUnderlying() == 0` ([VAULT-FR-004](#vault-fr-004)). Together, these layers prevent funds from flowing to operations before activation.
  - **PriceFeed (third asset)**: the branch PriceFeed is the "third asset" that must match Vault / dToken. During placeholder activation, keep cap at 0 until the real PriceFeed completes `confirmSourceEmergency()`, then release new minting with `dToken.setCap(N)` ([DTKN-FR-002](dToken.md) / [DTKN-FR-006](dToken.md) / [Oracle Requirements Specification](Oracle.md)). Normal source replacement can use `confirmSource()` when old/new price difference is within 1%, but replacing a placeholder sentinel with a real price exceeds the price-difference guard and uses the emergency path. Wiring is handled in the Path-B deployment process (outside this requirement's scope).
  - **Activation runbook (placeholder -> active complete procedure)**: ordering matters; reverse order is rejected by guards.
    1. **Underlying allowlist** — `dToken.setAllowedUnderlying(WBTC, true)` (pre-review canonical token address)
    2. **Fix dToken** — `dToken.setTokenInfo("dWBTC", "dWBTC", WBTC)` (dToken-first, [DTKN-FR-002](dToken.md))
    3. **Fix Vault** — `vault.setUnderlying(WBTC)` (succeeds after verifying `dToken.underlying() == WBTC` and allowlist. Reverse order reverts `UnderlyingMismatch`)
    4. **Fix PriceFeed** — complete `confirmSourceEmergency()` on the branch's real PriceFeed ([Oracle Requirements Specification](Oracle.md)). Cap remains 0 until completion
    5. **Strategy whitelist** — `vault.addToWhitelist(strategy)` (contract-only, [VAULT-FR-008](#vault-fr-008))
    6. **Strategy registration** — `vault.addStrategy(strategy, weightBps, cap)`. The Underlying invariant means this **cannot succeed before step 3 (`setUnderlying`)** (`UnderlyingNotSet` in placeholder, `UnderlyingMismatch` for different-asset Strategy)
    7. **buffer / allocator parameters** — set `setBufferConfig` / `setAllocatorConfig`, etc. using Day-1 values from [Parameters.md](../../../Parameters.md)
    8. **Release minting** — finally call `dToken.setCap(N)` to release new deposits (cap is the final inactivity layer; no funds flow before wiring completes)
    - Conversion example: after steps 1-2, user calls `vault.deposit(5e8)` (5 WBTC, 8dec) -> `convertToDToken(5e8) = 5e8 * 10**(18-8) = 5e18` (mints 5 dWBTC, 18dec).
- **Verification**: unit (zero, one-shot, dToken-first, bidirectional `whenUnderlyingReady` guard), invariant=[VAULT-INV-010](#vault-inv-010), manual (activation runbook order).

### <a id="vault-fr-012"></a>VAULT-FR-012: GOV configuration setters (`setBufferConfig` / `setAllocatorConfig` / `setStrategyValuationMaxAge` / `setWithdrawDelay` / `setTreasury`)

- **Type**: Functional | **Source**: operational parameter management / [Parameters.md](../../../Parameters.md)
- **Signature**: `setBufferConfig(uint256 _targetBps, uint256 _floor)` / `setAllocatorConfig(uint256 _maxMove, uint256 _cooldown)` / `setStrategyValuationMaxAge(uint256 _maxAge)` / `setWithdrawDelay(uint256 _delay)` / `setTreasury(address _treasury)`
- **Purpose**: GOV updates Vault operating parameters and yield destination. Day-1 concrete values per collateral are canonical in [Parameters.md](../../../Parameters.md); this requirement defines each setter's signature, validation, and default behavior.
- **Authorization**: each setter is GOV_MULTISIG (Vault `GOV_ROLE`) only.
- **Preconditions and behavior**:
  - **setBufferConfig (update buffer policy)**:
    1. **Upper-bound validation** — if `_targetBps > 10000`, revert with `InvalidBufferConfig` (BPS ratio must be `<= 100%`)
    2. **Commit** — `bufferTargetBps = _targetBps`, `bufferFloor = _floor` (`bufferFloor` is an absolute amount and has no upper-bound validation). Values apply immediately to the next `allocate()` target buffer calculation ([VAULT-FR-004](#vault-fr-004))
  - **setAllocatorConfig (update allocator guardrails)**:
    - Update `allocateMaxMove = _maxMove` (maximum buffer -> Strategy movement per `allocate()` call) and `allocatorCooldown = _cooldown` (minimum interval between `allocate()` calls in seconds). **No validation**. `allocatorCooldown = 0` disables cooldown; `allocateMaxMove = 0` stops outbound allocation; `allocateMaxMove = type(uint256).max` means effectively no movement upper bound. These apply only to `allocate()` and not to `Strategy.sendToVault` (principal recovery) ([§9](#9-security-requirements-sec))
  - **setStrategyValuationMaxAge (update valuation cache TTL)**:
    - Update `strategyValuationMaxAge = _maxAge`. `_maxAge = 0` disables cache fallback on valuation failure, so live read failure returns to immediate 0 valuation. There is no upper-bound validation; GOV runbook / Parameters manage the value
  - **setWithdrawDelay (delayed redemption waiting period)**:
    - Update `withdrawDelay = _delay` (seconds; waiting period for `WithdrawRequest` issued on redeem shortfall, [VAULT-FR-006](#vault-fr-006)). **If `_delay > 30 days`, revert with `InvalidBufferConfig`** (upper bound 30 days). Changes apply **only to future request `claimableAt`**; existing requests' waiting times do not change. Default is `1 day` ([VAULT-FR-010](#vault-fr-010))
  - **setTreasury (update yield destination)**:
    1. **Zero validation** — `_treasury == address(0)` reverts with `ZeroAddress`
    2. **Commit** — `treasury = _treasury`
- **Revert / early return**: `setBufferConfig` (`_targetBps > 10000`) / `setWithdrawDelay` (`_delay > 30 days`): `InvalidBufferConfig`. `setTreasury`: `ZeroAddress`. `setAllocatorConfig` / `setStrategyValuationMaxAge`: no upper-bound validation (only non-GOV reverts).
- **Emitted events**: each setter emits `BufferConfigUpdated(oldTargetBps, newTargetBps, oldFloor, newFloor)` / `AllocatorConfigUpdated(oldMaxMove, newMaxMove, oldCooldown, newCooldown)` / `StrategyValuationMaxAgeUpdated(oldMaxAge, newMaxAge)` / `WithdrawDelayUpdated(oldDelay, newDelay)` / `TreasuryUpdated(oldTreasury, newTreasury)`. Monitoring uses events as the canonical source and verifies post-state through corresponding views (`bufferTargetBps` / `bufferFloor` / `allocateMaxMove` / `allocatorCooldown` / `strategyValuationMaxAge` / `withdrawDelay` / `treasury`) ([VAULT-EVT-011](#11-events-and-monitoring-requirements-evt)).
- **Design notes**:
  - **treasury is mutable by GOV**, but **not by ALLOCATOR**. `transferYieldToTreasury` always sends only to current `treasury`, so a compromised ALLOCATOR key cannot redirect the destination to an arbitrary address ([§9](#9-security-requirements-sec) / [VAULT-SEC-005](#vault-sec-005)). "Fixed Treasury" means **fixed from ALLOCATOR's perspective**.
  - Changing treasury is a critical operation requiring GOV_MULTISIG approval, and `TreasuryUpdated` is monitored.
- **Verification**: unit (GOV-only, `InvalidBufferConfig` / `ZeroAddress`, immediate reflection, existing requests unchanged, valuation cache TTL update).

### <a id="vault-fr-013"></a>VAULT-FR-013: View group (`bufferBalance` / `backstopBalance` / `totalUnderlying` / Strategy enumeration)

- **Type**: Functional | **Source**: monitoring / subgraph / frontend
- **Signature**: `bufferBalance() -> uint256` / `backstopBalance() -> uint256` / `totalUnderlying() -> uint256` / `strategyValuationMaxAge() -> uint256` / `strategyValuationCaches(IStrategy) -> (uint256 conservativeValue, uint256 updatedAt, bool initialized)` / `getStrategiesCount() -> uint256` / `getStrategyAt(uint256) -> (IStrategy, StrategyConfig)` / `getAllStrategies() -> (IStrategy[], StrategyConfig[], uint256[])` / `getStrategyStatuses() -> StrategyStatus[]` (views are external view and permissionless) / `refreshStrategyValuation(IStrategy) -> bool` (external, permissionless) / `invalidateStrategyValuationCache(IStrategy)` (external, GOV_ROLE)
- **Purpose**: Views for monitoring, subgraph, and frontend to read Vault state, plus helper functions for keeper/GOV to manage Strategy valuation cache.
- **Authorization**: views are permissionless. `refreshStrategyValuation` is permissionless (caller only pays gas to record live value into cache). `invalidateStrategyValuationCache` is GOV_ROLE.
- **Preconditions (Checks)**: view getters generally have none (`getStrategyAt` range-checks only). `refreshStrategyValuation` / `invalidateStrategyValuationCache` require target is a registered Strategy.
- **Behavior (Effects)**:
  - `bufferBalance()` — liquid Underlying balance currently held by the Vault and usable for redeem / claim / allocate / Treasury transfer (`max(underlying.balanceOf(address(this)) - _backstopReserve, 0)`). **placeholder-safe**: returns 0 when `underlying == address(0)` ([VAULT-FR-011](#vault-fr-011))
  - `backstopBalance()` — live balance of protected backstop reserve (`min(_backstopReserve, underlying.balanceOf(address(this)))`). Increased by `backstopDeposit`, decreased by `releaseBackstopToBuffer`. 0 in placeholder
  - `totalUnderlying()` — Vault raw Underlying balance (liquid buffer + backstop reserve) plus conservative valuation of each registered Strategy (normally `underlying.balanceOf(vault) + Σ min(estimatedTotalUnderlying_i, principal_i)`, [§7](#7-state-variables-and-accounting-model)). If no Strategies are registered, equal to Vault raw Underlying balance. If Strategy `estimatedTotalUnderlying()` or `principal()` reverts, use fresh `cachedConservativeValue` within `strategyValuationMaxAge`; if cache is missing/stale/disabled (TTL=0), value is 0
  - `strategyValuationMaxAge()` — maximum age for using last-good cache on valuation failure. Default 1 days, GOV can update via `setStrategyValuationMaxAge`, and 0 disables fallback
  - `strategyValuationCaches(strategy)` — cache of last successful `min(est, principal)` (`conservativeValue` / `updatedAt` / `initialized`). Updated by `addStrategy` / `allocate` / `writeoffStrategyPrincipal` / `refreshStrategyValuation`. If post-deposit refresh in `allocate` fails, cache is still incrementally adjusted by known outflow from Vault to Strategy. `receiveFromStrategy` reduces cache by actual receipt on exact delivery and invalidates it on declared/received mismatch
  - `getStrategiesCount()` — number of registered Strategies (`strategies.length`)
  - `getStrategyAt(_index)` — Strategy at `_index` and its `StrategyConfig{ enabled, weightBps, cap }`. If `_index >= strategies.length`, revert with **custom error `StrategyNotFound`**
  - `getAllStrategies()` — batch returns all registered Strategies, their `StrategyConfig`, and balances as three aligned arrays. `_balances[i]` is the **raw `estimatedTotalUnderlying()` value** for each Strategy when readable, or 0 if the estimate read fails (no `min` clamp with `principal`)
  - `getStrategyStatuses()` — fail-soft snapshot of all registered Strategies. Each element includes `strategy` / `config` / `estimatedUnderlying` / `principal` / `conservativeValue` / `cachedConservativeValue` / `cacheUpdatedAt` / `estimatedGain` / `estimatedLoss` / `capRemaining` / `estimateAvailable` / `principalAvailable` / `usingCachedConservativeValue` / `cacheAvailable` / `cacheStale`. If both live `estimatedTotalUnderlying()` and `principal()` can be read, it shows `conservativeValue = min(est, principal)` and estimated PnL. If either reverts, unreadable fields are 0, corresponding `...Available` is `false`, and only fresh cache is placed in `conservativeValue` with `usingCachedConservativeValue = true`. If cache is stale/missing, conservative valuation is 0
  - `refreshStrategyValuation(strategy)` — reads live `estimatedTotalUnderlying()` and `principal()` for a registered Strategy; if both succeed, stores `min(est, principal)` in cache and returns `true`. If either fails, leaves cache unchanged and returns `false`
  - `invalidateStrategyValuationCache(strategy)` — GOV discards cache for a registered Strategy. This explicit reset prevents double counting after external protocol emergency recovery or direct emergency transfer
- **Revert / early return**: `getStrategyAt`: `_index >= strategies.length` -> `StrategyNotFound`. `getAllStrategies()` reads raw `estimatedTotalUnderlying()` fail-soft and reports 0 for a Strategy whose estimate view reverts. `getStrategyStatuses()` is fail-soft and does not revert the entire snapshot. `refreshStrategyValuation` / `invalidateStrategyValuationCache` on unregistered Strategy -> `StrategyNotFound`.
- **Emitted event**: `StrategyValuationMaxAgeUpdated`. Cache updates, invalidations, refresh failures, and conservative reductions are detected through views/statuses and cache getter.
- **Design notes**:
  - **Why placeholder-safe**: a naive balance view would call `address(0)` when `underlying == address(0)`, causing a revert that cascades into `totalUnderlying()` / `allocate()` / `transferYieldToTreasury()`. That is fail-closed, but it breaks subgraphs/monitoring that merely view placeholder branches (Day-1 inert, `mintCap = 0`; canonical targets are in [Parameters.md](../../../Parameters.md)). Therefore `bufferBalance()` / `backstopBalance()` / `totalUnderlying()` return 0 when `underlying == address(0)` (fund movement is separately blocked by the Underlying invariant, `whenUnderlyingReady`, and cap=0, so returning 0 does not weaken inactivity).
  - **Strategy valuation bounded last-good**: `totalUnderlying()` always uses live `min(est, principal)` while live valuation can be read. Only if valuation view reverts does it temporarily use last-good conservative cache within `strategyValuationMaxAge`; stale/missing/disabled cache becomes 0. This avoids temporary external view failure immediately causing mistaken liquidation of all Troves, while preventing permanent overvaluation from cached values.
  - **Cache continuity from known flows**: after depositing to Strategy in `allocate`, the Vault attempts live refresh. If refresh fails, it still incrementally adjusts cache by the known outflow from Vault raw balance to Strategy, preventing backing from being temporarily understated merely because `raw balance` decreased. When live valuation recovers, live `min(est, principal)` always takes precedence.
  - **Prevent cache double counting**: `receiveFromStrategy` reduces cache by actual receipt on exact delivery and invalidates it on declared/received mismatch. The Vault does not guess an upstream-position decrease from an anomalous receipt. Principal returns, protocol-specific emergency recovery, and generic idle rescue use this reconciliation path. Yield-only pushes such as `sendProfitToVault` and Underlying reward claims enter the Vault buffer by direct Strategy transfer and do not move the cache. `writeoffStrategyPrincipal` attempts refresh after writeoff and reduces cache by writeoff amount if refresh fails. `removeStrategy` discards cache.
  - **`getAllStrategies` `_balances` are raw-or-zero values**: raw `estimatedTotalUnderlying()` values when readable, or 0 when the estimate read fails. They are not the `min(est, principal)` used for solvency valuation ([§7](#7-state-variables-and-accounting-model)). To observe divergence from `principal` (positive = unrealized gain, negative = principal impairment signal, [§11](#11-events-and-monitoring-requirements-evt)), read Strategy-side `principal()` as well. Use `getStrategyStatuses()` when monitoring needs availability flags, principal, cache, and conservative valuation context.
  - **`getStrategyStatuses` is an aggregate operational view**: Strategy valuation view reverts do not revert the entire snapshot. Unlike `getAllStrategies()`, this view exposes read availability, cache status, and conservative valuation fields. `estimatedGain` is the difference between estimate and principal; it does not prove profit can actually be recovered or transferred. If external protocol loss does not appear in the Strategy estimate, this view alone cannot automatically determine it; GOV recovery/writeoff/backstop operations are required.
  - **Definition of "registered" in enumeration**: Strategy enumeration views return **membership in the `strategies[]` array** (whether enabled or disabled and still in `strategies[]`, until `removeStrategy`). This is the same definition of "registered" used by `receiveFromStrategy` ([VAULT-FR-005](#vault-fr-005)) and `writeoffStrategyPrincipal` ([VAULT-FR-009](#vault-fr-009)).
- **Verification**: unit (placeholder returns 0, index out of bounds, `getAllStrategies` fail-soft, raw vs min, status fail-soft, estimated PnL, fresh cache fallback, TTL expiry, cache increment after allocation refresh failure, cache reduction), manual (subgraph/keeper integration).

### <a id="vault-fr-014"></a>VAULT-FR-014: Pause / Unpause (emergency stop)

- **Type**: Functional | **Source**: emergency response / incident response / 2026-06-12 governance design finalized ([../policies/Governance-Roles-Timelock.md](../policies/Governance-Roles-Timelock.md))
- **Signature**: `pauseDeposit()` / `unpauseDeposit()` / `pauseRedeem()` / `unpauseRedeem()` / `pauseClaim()` / `unpauseClaim()` / `pauseAllocation()` / `unpauseAllocation()`
- **Purpose**: Emergency-stop deposit (mint), redeem, claim, and allocation with **four independent flags**. pause (stop) is separated to `GUARDIAN_ROLE` for speed; unpause (resume) is separated to `GOV_ROLE` only (holder = Timelock = 12h delay) to prevent mistaken or malicious resumption (asymmetric design: easy to pull the brake, slow to release it).
- **Authorization**: pause is `GUARDIAN_ROLE` (`_admin` also has it by default in `initialize`) / unpause is `GOV_ROLE` only.
- **Preconditions (Checks)**: pause caller has `GUARDIAN_ROLE`; unpause caller has `GOV_ROLE`.
- **Behavior (Effects)**:
  - `pauseDeposit()` — `pausedDeposit = true`, emit `DepositPaused()`. `deposit` reverts with `Paused` ([VAULT-FR-001](#vault-fr-001))
  - `pauseRedeem()` — `pausedRedeem = true`, emit `RedeemPaused()`. `redeem` / `redeemWithPermit` revert with `Paused` ([VAULT-FR-002](#vault-fr-002) / [VAULT-FR-003](#vault-fr-003))
  - `pauseClaim()` — `pausedClaim = true`, emit `ClaimPaused()`. `claim` reverts with `Paused` ([VAULT-FR-006](#vault-fr-006))
  - `pauseAllocation()` — `pausedAllocation = true`, emit `AllocationPaused()`. `allocate()` and `transferYieldToTreasury()` revert under `whenNotPausedAllocation` ([VAULT-FR-004](#vault-fr-004) / [VAULT-FR-007](#vault-fr-007)). **`Strategy.sendToVault` (principal recovery) and `Strategy.sendProfitToVault` (profit pull-up to Vault) are not targets** because they safely move funds back to the Vault buffer ([§9](#9-security-requirements-sec))
  - `unpauseDeposit()` / `unpauseRedeem()` / `unpauseClaim()` / `unpauseAllocation()` (`GOV_ROLE`) — set each flag back to false and emit corresponding `*Unpaused()`
- **Revert / early return**: pause: non-GUARDIAN -> revert. unpause: non-GOV -> revert.
- **Emitted event**: `DepositPaused()` / `DepositUnpaused()` / `RedeemPaused()` / `RedeemUnpaused()` / `ClaimPaused()` / `ClaimUnpaused()` / `AllocationPaused()` / `AllocationUnpaused()` ([VAULT-EVT-012](#11-events-and-monitoring-requirements-evt)).
- **Design notes**:
  - **Why stops are separated (different scenarios need different actions)**: (1) In collateral peg/depeg situations, it may be necessary to stop **only new inflow** while leaving holder exit (redeem) open -> `pauseDeposit` only (previous `pauseMintRedeem` style would unfairly block exit). (2) During actual Strategy loss, [VAULT-SEC-010](#vault-sec-010) automatically stops the four user paths before Guardian response, while `pauseDeposit` / `pauseRedeem` / `pauseClaim` remain defense-in-depth for an explicit incident-wide freeze, UI/keeper coordination, and investigation. Restore `A_confirmed >= L_effective` through `backstopDeposit` and, when needed, `releaseBackstopToBuffer` ([VAULT-FR-017](#vault-fr-017)), then release any operational pause (equitable repair; the overall policy is [`ADR-006`](../architecture/Architecture-Decision-Records.md#adr-006)).
  - **Why claim remains pausable**: the on-chain backing guard stops balance-sheet impairment but cannot represent incorrect valuation, an external loss not yet reflected by the Strategy, or incident investigation and coordination. `pauseRedeem` alone cannot stop interaction with existing vested claims, so `pauseClaim` remains a defense-in-depth mechanism for an explicit incident-wide freeze.
  - **Cost (explicit)**: governance can freeze vested liabilities (vested claims), weakening non-custodial properties by one step. Mitigations: guardian is multisig, stop direction is conservative, and unpause is GOV=Timelock. **`unpauseClaim` also has 12h delay**, so a false-positive claim freeze lasts at least 12h; GUARDIAN must use claim pause only with high confidence. During freeze, 🔵 Core Redemption/liquidation does not stop (core unchanged). A redeemer who receives dXXX cannot convert to Underlying while the Vault exit is frozen, temporarily weakening JPYdf Redemption arbitrage (peg defense); operations assume the repair window is kept short.
  - Four independent flags allow selective recovery such as "resume deposit only while redeem remains paused." During emergency staged recovery, allocation can be stopped while buffer replenishment for redeem continues ([§12](#12-failure-and-exception-behavior-err)).
  - `initialize` grants `_admin` (GOV) `GUARDIAN_ROLE` as well by default, but production assumes separation to Guardian multisig ([§4](#4-actors-roles-and-trust-boundaries)).
- **Verification**: unit (pause by GUARDIAN, unpause by GOV, four flags independent, claim pause/resume, sendToVault/sendProfitToVault not targeted, transferYieldToTreasury targeted by pause).

### <a id="vault-fr-015"></a>VAULT-FR-015: Upgrades (UUPS)

- **Type**: Functional | **Source**: Product-Overview "dToken Layer (UUPS)"
- **Signature**: `_authorizeUpgrade(address newImpl)` (internal, UUPS authorization)
- **Purpose**: Allow future changes to Vault custody, accounting, allocation, redemption, and related behavior through UUPS logic replacement. Vault-side feature updates are done by this upgrade; the dToken `vault` reference is not changed (dToken `vault` immutability in [DTKN-FR-001](dToken.md)).
- **Authorization**: new implementation approval is **GOV_MULTISIG (Vault `GOV_ROLE`, holder = Timelock) only**. Operational roles (ALLOCATOR / GUARDIAN / WRITEOFF / Strategy, etc.) are not allowed.
- **Preconditions (Checks)**: `caller` has `GOV_ROLE`.
- **Behavior (Effects)**:
  1. Replace implementation address (UUPS). Storage is append-only (no reordering or type changes for existing slots; gap reserves future slots)
  2. Emit ERC1967 `Upgraded(newImpl)`
  3. For existing proxies upgraded from pre-cache implementations, `strategyValuationMaxAge` starts from storage default 0 (fallback disabled). GOV explicitly enables it through `setStrategyValuationMaxAge(nonZeroMaxAge)`
- **Revert / early return**: non-GOV -> revert.
- **Emitted event**: ERC1967 `Upgraded(newImpl)` ([VAULT-EVT-013](#11-events-and-monitoring-requirements-evt)).
- **Design notes**: UUPS upgrade itself has no built-in delay. **On mainnet, holders of `GOV_ROLE` / `DEFAULT_ADMIN_ROLE` are only the shared TimelockController (minDelay 12h), applying 12h public delay to all GOV operations including upgrades (finalized 2026-06-12, [VAULT-GOV-004](#vault-gov-004))**. Oracle PriceFeedProxy separately has a built-in 12h timelock for feed source replacement ([Oracle Requirements Specification](Oracle.md)).
- **Verification**: unit (GOV-only authorization, operational roles revert), manual (storage layout review, gap reserved).

### <a id="vault-fr-016"></a>VAULT-FR-016: `backingRatio` (provide dToken backing ratio)

- **Type**: Functional | **Source**: [Oracle Requirements Specification](Oracle.md) `ORCL-FR-014` (dToken backing peg) / §7 accounting principle (`A` vs `L_effective`)
- **Signature**: `backingRatio() -> uint256` (external view, 1e18 scale, **downward-only** `<= 1e18`) / `backingRatioForPricing() -> (uint256 ratio, bool available)`
- **Purpose**: Return the dToken **backing ratio** (actual Underlying held / principal claims) in 1e18 scale as a read-only view. Oracle Layer (the backing multiplication layer inside each DF PriceFeed, [Oracle Requirements Specification](Oracle.md) `ORCL-FR-014`) reads this and multiplies market price to reflect dToken depeg from Strategy impairment in collateral value. **All value accounting is completed on this Vault side**; the oracle only reads the ratio.
- **Authorization**: none (external view, permissionless).
- **Preconditions (Checks)**: none (placeholder / zero supply returns `1e18` as below).
- **Behavior (Effects)**:
  1. `L_effective = actualLiabilities()` (`L_user + L_pending` from §7 accounting principle. Round up to 1 Underlying base unit if dToken total-supply dust exists)
  2. If `L_effective == 0`, return `1e18` (placeholder / zero supply, avoid division by zero)
  3. Otherwise use `A = totalUnderlying()` (Vault raw Underlying balance + Σ live `min(est, principal)`, fresh cache on Strategy valuation failure, stale/missing/disabled cache = 0) and return `min(1e18, A * 1e18 / L_effective)`
  4. `backingRatioForPricing()` uses the same sum and ratio, but returns `(1e18, true)` when known conservative assets already cover all dToken and queued-claim liabilities, even if another Strategy is unavailable. Below that coverage it returns `(0, false)` when a registered Strategy has neither a live valuation nor a fresh cache. Measured zero with every Strategy valued is `(0, true)`. `L_effective == 0` is `(1e18, true)`
- **Revert / early return**: `L_effective == 0` -> `1e18`. Otherwise always returns computed value (view designed not to revert; Strategy valuation failure is handled in `totalUnderlying()` via bounded last-good or 0 valuation).
- **Emitted event**: none (view).
- **Design notes**:
  - **Directly corresponds to `VAULT-INV-001`**: `backingRatio == 1e18 <=> A >= L_effective` (healthy). When `A < L_effective` (principal impairment), return below `1e18`, and impairment rate becomes the downward factor.
  - **Upside cap (`min(1e18, ...)`)**: even if operating profit makes `A > L_effective`, cap at `1e18`. This matches dToken as a 1:1 principal claim with no yield (operating profit belongs to Treasury) and does not inflate collateral value with unrealized gains.
  - **pari passu (Design B)**: pending (already redeemed) and current dToken are evaluated at the **same rate** in `L_effective` (not as priority repayment deducted from current dToken). This matches the premise that, because full payment of `claim` depends on buffer, pending claims can also effectively depreciate in severe cases.
  - **Operational/pricing separation**: `backingRatio()` always returns a number for monitoring and incident use and preserves the conservative behavior of valuing an unavailable Strategy at zero. `backingRatioForPricing()` attaches availability to the same result, so an unreadable valuation is not confused with measured total loss. Oracle treats `available == false` as standard oracle failure. Backing can still be overstated when loss is not reflected in `est`, `writeoffStrategyPrincipal` is delayed, or real impairment occurs during the fresh-cache window.
  - **placeholder-safe**: in placeholder with `totalSupply() == 0` and `pendingWithdrawals == 0`, `L_effective == 0` -> `1e18`. This is consistent with oracle-side `PriceFeedPlaceholder` (`(1e18, false)`).
- **Verification**: unit (`L_effective==0` returns `1e18`, `min` cap, below `1e18` on impairment, floor), fork (decrease under real Strategy impairment), invariant=[VAULT-INV-012](#vault-inv-012).

### <a id="vault-fr-017"></a>VAULT-FR-017: `backstopDeposit` (replenishment deposit without minting dToken)

- **Type**: Functional | **Source**: rescue policy for dToken backing impairment (no SP replenishment; Vault/backstop replenishment)
- **Signature**:
  - `backstopDeposit(uint256 _underlyingAmount) returns (uint256 received)` (external, permissionless, `whenUnderlyingReady`, `nonReentrant`)
  - `releaseBackstopToBuffer(uint256 _amount) returns (uint256 released)` (external, `GOV_ROLE`, `whenUnderlyingReady`)
- **Purpose**: Inject Underlying from Treasury, insurance, or any backstop as protected reserve and restore `A = totalUnderlying()` and `backingRatio()` without minting new dToken. This is the repair path for shortfall remaining after Strategy recovery/writeoff, and it avoids imposing Vault loss on the Liquity Stability Pool. Deposited reserve cannot be consumed by normal redeem / claim first-come-first-served; only the amount explicitly released by GOV through `releaseBackstopToBuffer` becomes liquid buffer.
- **Authorization**: `backstopDeposit` has no role (permissionless). Expected callers are Treasury / insurance / backstop multisig, but third-party donations are allowed because they only improve Vault solvency. `releaseBackstopToBuffer` is GOV_MULTISIG only.
- **Preconditions (Checks)**: `whenUnderlyingReady`; `backstopDeposit`: `_underlyingAmount != 0`. `releaseBackstopToBuffer`: `_amount != 0` and `_amount <= backstopBalance()`.
- **Behavior (Effects)**:
  1. Input validation (`_underlyingAmount == 0` / `_amount == 0` -> `ZeroAmount`)
  2. `backstopDeposit` records Vault raw underlying balance before receipt
  3. Pull `_underlyingAmount` from `msg.sender` into the Vault with `safeTransferFrom`
  4. Determine `received` as the post-receipt balance delta (actual receipt, not declared amount)
  5. `backstopDeposit` increases reserve accounting with `_backstopReserve += received`, emits `BackstopDeposited(msg.sender, _underlyingAmount, received)`, and returns `received`
  6. `releaseBackstopToBuffer` decreases reserve accounting with `_backstopReserve -= _amount`, making the same Underlying usable as liquid buffer, emits `BackstopReleased(msg.sender, _amount)`, and returns `_amount` (no ERC-20 transfer occurs)
- **Revert / early return**: Vault Underlying unset -> `UnderlyingNotSet`; Vault/dToken mismatch -> `UnderlyingMismatch`; `_underlyingAmount == 0` / `_amount == 0` or actual received `received == 0` -> `ZeroAmount`; `_amount > backstopBalance()` in `releaseBackstopToBuffer` -> `InsufficientBackstop`; `safeTransferFrom` failure (balance/allowance) -> upstream revert.
- **Emitted event**: `BackstopDeposited(backstop, declaredAmount, received)` / `BackstopReleased(caller, amount)` ([VAULT-EVT-014](#11-events-and-monitoring-requirements-evt) / [VAULT-EVT-015](#11-events-and-monitoring-requirements-evt)).
- **Design notes**:
  - **Does not mint dToken**: unlike deposit, it does not call `dToken.mint`. It only strengthens backing for existing dToken / pending claims.
  - **Not affected by pause**: unaffected by `pausedDeposit` / `pausedRedeem` / `pausedClaim` / `pausedAllocation`. Replenishment can continue even while paused (enables backstop injection during repair freeze).
  - **Automatic liveness recovery**: once `backstopDeposit` restores `A_confirmed`, including the raw balance, to at least `L_effective`, the [VAULT-SEC-010](#vault-sec-010) automatic guard passes with no separate reset. A claim still needs liquid buffer, so GOV uses `releaseBackstopToBuffer` only when protected reserve must become payout liquidity. Any explicitly set operational pause still requires the existing GOV unpause decision.
  - **Accumulates in reserve, not buffer**: replenishment remains as physical Underlying in the Vault but is excluded from `bufferBalance()`. `redeem` / `claim` / `allocate` / `transferYieldToTreasury` can use only liquid buffer, so replenishment funds for Strategy impairment cannot be drained by normal redeem first-come-first-served or Treasury sweep.
  - **Explicit release**: `releaseBackstopToBuffer` is an accounting move, not a fund transfer; it converts reserve back to liquid buffer. The incident runbook determines how much should be used for paying pending claims or as normal redeem liquidity (the overall policy is [`ADR-006`](../architecture/Architecture-Decision-Records.md#adr-006)).
  - **Actual-received accounting**: as with `receiveFromStrategy`, `received` is balance delta to avoid over-accounting under fee-on-transfer / rebasing anomalies.
  - **Separate from SP responsibility**: Stability Pool only processes Trove liquidations after oracle price decreases; it does not replenish Underlying to the Vault. Backing repair is contained on the Vault side through Strategy recovery, writeoff, and this function. Use views in [VAULT-FR-018](#vault-fr-018) to confirm required replenishment.
- **Verification**: unit (ready/zero/transfer failure, actual receipt, no mint event, not buffer, GOV release), invariant=[VAULT-INV-013](#vault-inv-013), integration (impairment -> user-flow stop -> backstopDeposit -> `A_confirmed` / `backingRatio` recovery -> automatic restart -> release -> pending claim possible).

### <a id="vault-fr-018"></a>VAULT-FR-018: Backing ops views (replenishment operation helpers)

- **Type**: Functional | **Source**: [VAULT-FR-016](#vault-fr-016) / [VAULT-FR-017](#vault-fr-017) / backing repair runbook
- **Signature**:
  - `actualLiabilities() -> uint256` (external view)
  - `backingShortfall() -> uint256` (external view)
  - `backstopRequiredForRatio(uint256 _targetRatio) -> uint256` (external view, `_targetRatio` is 1e18 scale)
- **Purpose**: During dToken backing impairment, off-chain runbooks / keepers / governance can read **current effective liabilities, shortfall to 100% backing, and replenishment required to reach a target backing ratio** under the same accounting formula. No state changes; the canonical value read by the oracle remains `backingRatio()`.
- **Authorization**: none (external view, permissionless).
- **Preconditions (Checks)**: `backstopRequiredForRatio` requires `_targetRatio <= 1e18`. `actualLiabilities` / `backingShortfall` have no input.
- **Behavior (Effects)**:
  1. `actualLiabilities()` returns `L_effective = L_user + pendingWithdrawals`. `L_user` is based on `convertToUnderlying(dToken.totalSupply())`, rounded up to 1 base unit if dToken total supply contains dust not exactly corresponding to an Underlying base unit
  2. `backingShortfall()` returns `max(L_effective - A, 0)` from `A = totalUnderlying()` and `L_effective`
  3. `backstopRequiredForRatio(_targetRatio)` returns `0` if `_targetRatio == 0` or `L_effective == 0`
  4. Otherwise calculate `requiredAssets = ceil(L_effective * _targetRatio / 1e18)` and return `max(requiredAssets - A, 0)`
- **Revert / early return**: `_targetRatio > 1e18` -> `InvalidBackingTarget`. `_targetRatio == 0` / `L_effective == 0` -> `0`.
- **Emitted event**: none (view).
- **Design notes**:
  - **Operational helper, not a solvency gate**: read-only helpers reduce duplicated replenishment calculations. Oracle integration is complete with `backingRatio()` only.
  - **Includes pending**: uses the same `L_effective` as `backingRatio()` and treats already-redeemed pending claims at the same rate.
  - **Round up**: `actualLiabilities()` rounds dToken total-supply dust up to 1 base unit, and target-ratio replenishment uses `ceil` to avoid underestimating due to integer division.
  - **Separate from SP responsibility**: shortfall replenishment is handled by Vault operations (`backstopDeposit`, Strategy recovery, writeoff), not automatic Stability Pool replenishment.
- **Verification**: unit (liability / shortfall / target=0 / target=1e18 / rounding up / `_targetRatio > 1e18` revert), integration (impairment -> required amount -> backstopDeposit -> `backingRatio` recovery).

### <a id="vault-fr-019"></a>VAULT-FR-019: `emergencyDisableStrategy` (immediate disable of a registered Strategy)

- **Type**: Functional | **Source**: 2026-06-12 governance design finalized ([../policies/Governance-Roles-Timelock.md](../policies/Governance-Roles-Timelock.md)). Because disabling through `updateStrategy` is delayed 12h after GOV=Timelock, this separates a fail-safe path that can immediately stop new allocation to a suspect Strategy
- **Signature**: `emergencyDisableStrategy(IStrategy _strategy)`
- **Purpose**: GUARDIAN immediately removes a registered Strategy from new allocation targets (`enabled = false`, `weightBps = 0`). It does not touch backing valuation (estimated / principal / cache) at all = pure flow control with no markdown authority.
- **Authorization**: `GUARDIAN_ROLE` only.
- **Preconditions (Checks)**: `_strategy` is registered (remains in `strategies[]`); unregistered -> `StrategyNotFound`.
- **Behavior (Effects)**:
  1. `totalWeightBps -= config.weightBps` (derived value recalculation, [§7](#7-state-variables-and-accounting-model))
  2. Set `config.weightBps = 0`, `config.enabled = false` (maintains [VAULT-INV-009](#vault-inv-009) "disabled has weight 0")
  3. Emit `StrategyEmergencyDisabled(strategy, oldWeightBps)`
- **Revert / early return**: unregistered -> `StrategyNotFound`. Calls on an already disabled Strategy are idempotent (weight already 0, no state change).
- **Emitted event**: `StrategyEmergencyDisabled(strategy, oldWeightBps)` ([VAULT-EVT-008](#11-events-and-monitoring-requirements-evt)).
- **Design notes**:
  - **Key asymmetric control**: disable (risk reduction) is GUARDIAN immediate; re-enable and weight/cap increase (risk increase) are only through `updateStrategy` (GOV=Timelock, 12h, [VAULT-FR-009](#vault-fr-009)). After disable, the Strategy remains in `strategies[]`, so it remains a target for push recovery via `receiveFromStrategy`, `writeoffStrategyPrincipal`, and `removeStrategy`; registeredness also causes `addStrategy` re-registration to be rejected with `StrategyAlreadyExists`, making delayed `updateStrategy` the only re-enable path.
  - First action in disaster is `pauseAllocation` (stop outbound to all Strategies). This function is used when only a specific Strategy should be removed while continuing the rest of operations.
- **Verification**: unit (GUARDIAN-only, weight zeroing, totalWeightBps recalculation, idempotent, backing unchanged, re-enable only through updateStrategy), invariant=[VAULT-INV-009](#vault-inv-009).

---

## 7. State Variables and Accounting Model

### Vault Level

| Variable | Type | Description | Fixed by |
| --- | --- | --- | --- |
| `underlying` | `IERC20` | Underlying held by the Vault. Unset is `address(0)` (placeholder) | `initialize` (immediate) / `setUnderlying` (one deferred bind) |
| `dToken` | `IDToken` | Corresponding dToken to mint/burn | Fixed in `initialize` |
| `treasury` | `address` | Yield destination | `initialize` / `setTreasury` updates |
| `strategies[]` | `IStrategy[]` | Registered Strategies (multiple per collateral asset allowed) | `addStrategy` / `removeStrategy` |
| `whitelistedStrategies` | `mapping` | Strategy whitelist (GOV prior-approved set; guard before `addStrategy`) | `addToWhitelist` / `removeFromWhitelist` |
| `strategyConfigs[strategy]` | `StrategyConfig` | Three fields `{ enabled, weightBps, cap }` | `addStrategy` / `updateStrategy` |
| `totalWeightBps` | `uint256` | Sum of registered Strategy `weightBps` (derived value; implementation enforces `<= 10000`; no direct GOV setter) | Automatically recalculated by `addStrategy` / `updateStrategy` / `removeStrategy` |
| `bufferTargetBps` | `uint256` | Target inventory ratio (BPS) | `initialize` default / `setBufferConfig` |
| `bufferFloor` | `uint256` | Absolute minimum inventory | `initialize` default / `setBufferConfig` |
| `allocateMaxMove` | `uint256` | Maximum movement per `allocate()` call (applies only to `allocate()`. `0` stops allocation, `type(uint256).max` is effectively unlimited) | `initialize` default / `setAllocatorConfig` |
| `allocatorCooldown` | `uint256` | Minimum cooldown seconds between `allocate()` executions | `initialize` default / `setAllocatorConfig` |
| `lastAllocatorTime` | `uint256` | Last execution time of `allocate()` (cooldown check) | `allocate()` |
| `withdrawDelay` | `uint256` | Waiting period for delayed redemption (default 1 day) | `initialize` default / `setWithdrawDelay` |
| `withdrawRequests[id]` | `mapping -> WithdrawRequest` | Delayed redemption records, unclaimed or claimed | `redeem` (issue) / `claim` (settle) |
| `nextRequestId` | `uint256` | requestId assignment (initial 1, +1 per issuance) | `initialize` default / `redeem` |
| `pendingWithdrawals` | `uint256` | Total unclaimed WithdrawRequests (used for buffer protection) | `redeem` (+) / `claim` (-) |
| `_backstopReserve` | `uint256` | Book amount of protected backstop reserve. Excluded from `bufferBalance()` and included in `totalUnderlying()` as Vault raw balance | `backstopDeposit` (+) / `releaseBackstopToBuffer` (-) |
| `pausedDeposit` / `pausedRedeem` / `pausedClaim` / `pausedAllocation` | `bool` | Pause flags (four independent paths) | `pause*` / `unpause*` |

> 📌 **Concrete Day-1 values per collateral** (`bufferTargetBps` / `bufferFloor` / `allocatorCooldown` / `allocateMaxMove` / `withdrawDelay` / mintCap) are canonical in [Parameters.md](../../../Parameters.md). This document defines only each parameter's meaning and default behavior.

### Strategy Level (`strategyConfigs[strategy]` = `StrategyConfig`)

- `weightBps`: allocation weight (sum of registered Strategies `<= 10000`)
- `cap`: maximum invested amount (risk limit)
- `enabled`: enabled/disabled (individual stop)

> `StrategyConfig` has only three fields: `{ enabled, weightBps, cap }`. It has no synchronous/asynchronous distinction; whether an external protocol is synchronous or asynchronous is contained inside each Strategy implementation ([Strategy Requirements Specification](strategies/Strategy.md)). Each Strategy's invested principal is **self-managed by the Strategy as `principal`**, and the Vault uses `min(estimatedTotalUnderlying, principal)` for solvency valuation ([VAULT-FR-007](#vault-fr-007)).

### WithdrawRequest Struct

| Field | Type | Meaning |
| --- | --- | --- |
| `owner` | `address` | Fixed claim payout recipient / entitlement owner. Records `_receiver` from redeem |
| `underlyingAmount` | `uint256` | Underlying amount received on claim (shortfall `remaining` from buffer-insufficient redeem) |
| `claimableAt` | `uint256` | Time at which claim becomes possible (`block.timestamp + withdrawDelay`) |
| `claimed` | `bool` | Double-claim prevention flag |

### Accounting Principles

- **Conservative valuation (`min(est, principal)`)**: Solvency (`totalUnderlying`) values each Strategy at live `min(estimatedTotalUnderlying, principal)` to prevent pre-recognition of unrealized profit (`est > principal`). If Strategy valuation view reverts, use last-good conservative cache within `strategyValuationMaxAge` temporarily; stale/missing/disabled cache is 0. In contrast, outbound `managedUnderlying` does not send against cached value or live values from only part of the registry; if any registered Strategy lacks live valuation, the entire value is 0. `getAllStrategies` returns raw `est` values for monitoring when readable, or 0 for unreadable estimates.
- **Liability definition**: `L_user = convertToUnderlying(dToken.totalSupply())`, rounded up to 1 base unit if dToken total supply contains dust not exactly corresponding to an Underlying base unit (same as `actualLiabilities()`). `L_pending = pendingWithdrawals`, `L_effective = L_user + L_pending`.
- **A/L is Underlying-denominated accounting, not a price oracle**: `A = totalUnderlying()` and `L_effective` are compared in the Underlying units of the Vault. `A < L_effective` does not mean "JPY market price fell"; it is an accounting comparison between recoverable Underlying from Strategies and dToken/pending claims in the same asset. dToken itself has no price oracle; Oracle Layer only multiplies market price by the Vault's `backingRatio()`.
- **Confirmed assets for user flows**: `A_confirmed = underlying.balanceOf(vault) + Σ_i (liveAvailable_i ? min(estimatedTotalUnderlying_i, principal_i) : 0)`. `A_confirmed` covers every registered Strategy, enabled or disabled, but never includes bounded cache. Because an unreadable Strategy contributes a lower bound of zero, `A_confirmed >= L_effective` is sufficient proof that true assets cover all liabilities. If the Vault raw balance alone proves full backing, remaining Strategy reads are unnecessary.
- **Solvency principle**: the system aims to maintain `A = totalUnderlying() >= L_effective` at all times. Here, `A` is for backing / `backingRatio()` and includes protected backstop reserve. Transferable profit is computed internally from `M = managedUnderlying = bufferBalance() + Σ live min(est, principal)` with `surplus = max(M - L_effective, 0)`, and Treasury transfer is clamped by the liquid buffer above the reserve `B_reserve` (buffer target + `pendingWithdrawals`, the same one `allocate` keeps, [VAULT-FR-004](#vault-fr-004)). On Strategy valuation failure, `A` may use fresh cache, but `M` uses neither cache nor a partial sum and becomes 0 in full. Therefore backstop reserve, cached Strategy value, and an incomplete system view do not become allocation or Treasury surplus ([VAULT-FR-007](#vault-fr-007) / [VAULT-INV-001](#vault-inv-001)).
- **Backing ratio supplied to oracle**: derive `backingRatioForPricing() = (min(1e18, A / L_effective), available)` from the same `A` and `L_effective` ([VAULT-FR-016](#vault-fr-016)), and Oracle Layer multiplies an available value into dToken collateral price ([Oracle Requirements Specification](Oracle.md) `ORCL-FR-014`). This means measured `A < L_effective` propagates downward, while unavailable valuation takes the oracle-failure path instead of being misclassified as total loss.
- **Treatment of replenishment deposits**: `backstopDeposit` does not increase `L_effective` or dToken supply; it increases only protected reserve and `A`. Therefore during impairment it restores `backingRatio()`, but using it as source for claims during buffer shortage requires GOV `releaseBackstopToBuffer`.
- **`totalWeightBps` is a derived value**: automatically recalculated by `addStrategy` / `updateStrategy` / `removeStrategy`, with implementation enforcing `<= 10000`. No direct GOV setter.

---

## 8. Invariants (INV)

| ID | Invariant | Verification |
| --- | --- | --- |
| <a id="vault-inv-001"></a>VAULT-INV-001 | Solvency principle: in healthy state, `totalUnderlying() >= L_effective` (`= L_user + L_pending`). `A < L_effective` (principal impairment) is primarily **prevented** through buffer / cap / Strategy selection. If it occurs, `backingRatio()` returns below `1e18` and lowers collateral value through the oracle; at the same time, `deposit` / `redeem` / `redeemWithPermit` / unsettled `claim` must not change token, queue, or request state until cache-free `A_confirmed >= L_effective` is restored. Repair/recovery entry points remain open, and user flows restart automatically once confirmed assets recover ([VAULT-SEC-010](#vault-sec-010)) | invariant |
| <a id="vault-inv-002"></a>VAULT-INV-002 | Successful redeem preserves CEI order (exact required amount calculation -> pre-state backing check -> `dToken.burn` -> `safeTransfer`), and `_dTokenAmount` is fully burned after immediate/delayed allocation. A non-exact dToken amount or underbacked state reverts before burn ([VAULT-FR-002](#vault-fr-002) / [VAULT-SEC-010](#vault-sec-010)) | invariant |
| <a id="vault-inv-003"></a>VAULT-INV-003 | In buffer-insufficient redeem, `immediate payment + WithdrawRequest.underlyingAmount == underlyingNeeded`, and `pendingWithdrawals` increases by `remaining` (first-come-takes-all + delayed rule, [VAULT-FR-002](#vault-fr-002)) | invariant |
| <a id="vault-inv-004"></a>VAULT-INV-004 | `pendingWithdrawals == Σ(unclaimed WithdrawRequest.underlyingAmount)`. The first successful claim reduces exactly that amount; an already-settled retry returns `0` without changing accounting, transfer, or event state (`claimed` flag, [VAULT-FR-006](#vault-fr-006)) | invariant |
| <a id="vault-inv-005"></a>VAULT-INV-005 | `totalUnderlying() == underlying.balanceOf(vault) + Σ strategyConservativeValue_i`. Strategies with live valuation readable use `min(estimatedTotalUnderlying_i, principal_i)`; valuation failure uses fresh cache; stale/missing/disabled cache is 0. This raw balance is the sum of liquid buffer and protected backstop reserve, while `bufferBalance()` excludes reserve. If live refresh fails after Vault->Strategy allocation, fallback cache is incremented by known outflow without freshening an old/stale cache. `receiveFromStrategy` accounts `received` by balance delta, not declared amount; exact delivery reduces fallback cache by actual receipt but does not advance `updatedAt` because it is not a full valuation, while declared/received mismatch invalidates it ([VAULT-FR-005](#vault-fr-005) / [VAULT-FR-007](#vault-fr-007)) | invariant |
| <a id="vault-inv-006"></a>VAULT-INV-006 | Per-call buffer->Strategy movement by `allocate()` is at most `allocateMaxMove`, and each Strategy allocation is at most cap headroom (`cap_i - est_i`). A failed managed-assets preflight stops all outbound movement. After a successful preflight, amounts reduced by caps or skipped due to a per-Strategy valuation reread/deposit failure are not reallocated and remain in buffer. Deposit rejection is skipped only after exact recovery; any mismatch reverts the whole call. Committing allocation requires live cache-free proof that post-state `A_confirmed >= L_effective`; share rounding or valuation failure otherwise reverts all allocation state ([VAULT-FR-004](#vault-fr-004)) | invariant |
| <a id="vault-inv-007"></a>VAULT-INV-007 | `addToWhitelist` / `addStrategy` reject EOA / undeployed strategy, and `addStrategy` succeeds only when `whitelistedStrategies[strategy] == true`, `vault.underlying() != address(0)`, and `strategy.underlying() == vault.underlying()` ([VAULT-FR-008](#vault-fr-008)) | invariant |
| <a id="vault-inv-008"></a>VAULT-INV-008 | `removeStrategy` succeeds only when `strategy.principal() == 0` and live `strategy.estimatedTotalUnderlying() == 0` (remaining principal -> `StrategyHasPrincipal`; live valuation failure or residual assets -> `StrategyHasAssets`, [VAULT-FR-008](#vault-fr-008)) | invariant |
| <a id="vault-inv-009"></a>VAULT-INV-009 | Disabled Strategies (`enabled == false`) always have `weightBps == 0`. `totalWeightBps == Σ(registered Strategy weightBps) <= 10000` ([VAULT-FR-009](#vault-fr-009)) | invariant |
| <a id="vault-inv-010"></a>VAULT-INV-010 | `setUnderlying` succeeds only once (`UnderlyingAlreadySet`) and `underlying` is immutable after binding. In active phase, `dToken.underlying() == vault.underlying()` always holds (`whenUnderlyingReady` enforces at use time, [VAULT-FR-011](#vault-fr-011)) | invariant |
| <a id="vault-inv-011"></a>VAULT-INV-011 | In placeholder (`underlying == address(0)`), `deposit` / `redeem` / `redeemWithPermit` / `backstopDeposit` / `releaseBackstopToBuffer` / `addStrategy` all revert; `bufferBalance()` / `backstopBalance()` / `totalUnderlying()` return 0; and `allocate()` early-returns (no funds move, [VAULT-FR-011](#vault-fr-011) / [VAULT-FR-013](#vault-fr-013)) | invariant |
| <a id="vault-inv-012"></a>VAULT-INV-012 | `backingRatio()` returns `1e18` when `L_effective == 0`; otherwise returns `min(1e18, totalUnderlying() * 1e18 / L_effective)` (downward-only `<= 1e18`, healthy `== 1e18`). Strategy valuation failure is handled by fresh cache or 0 valuation and does not make the view revert ([VAULT-FR-016](#vault-fr-016)) | invariant |
| <a id="vault-inv-013"></a>VAULT-INV-013 | `backstopDeposit` does not change dToken `totalSupply` or `pendingWithdrawals`; it increases `backstopBalance()` / `totalUnderlying()` by actual `received` and does not increase `bufferBalance()`. `releaseBackstopToBuffer` does not change `totalUnderlying()`, decreases `backstopBalance()`, and increases `bufferBalance()`. Therefore it must not lower `backingRatio()` under the same `L_effective` ([VAULT-FR-017](#vault-fr-017)) | invariant |
| <a id="vault-inv-014"></a>VAULT-INV-014 | `actualLiabilities()` / `backingRatio()` / `backstopRequiredForRatio()` do not understate dToken total-supply dust and round it up to an Underlying base unit ([VAULT-FR-016](#vault-fr-016) / [VAULT-FR-018](#vault-fr-018)) | unit / invariant |

---

## 9. Security Requirements (SEC)

### <a id="vault-sec-001"></a>VAULT-SEC-001: CEI / Reentrancy

- Type: Security
- Statement: Functions that transfer value (`deposit` / `redeem` / `redeemWithPermit` / `receiveFromStrategy` / `backstopDeposit` / `claim` / `allocate` / `transferYieldToTreasury`) must be protected by `nonReentrant`, and `redeem` / `claim` must follow Checks-Effects-Interactions order (state determination -> burn / `claimed` update -> external transfer). `allocate` must reject state-mutating Vault reentry during Strategy transfer / deposit, and any read-only view reentry before valuation cache refresh must not overstate backing. A buffer-insufficient claim must revert before Effects and must not persist `claimed = true`.
- Verification: unit (reentrancy tests and allocate read-only observation test), invariant=[VAULT-INV-002](#vault-inv-002) / [VAULT-INV-004](#vault-inv-004) / [VAULT-INV-006](#vault-inv-006)

### <a id="vault-sec-002"></a>VAULT-SEC-002: Use-time Underlying consistency enforcement (fail-closed)

- Type: Security
- Statement: `deposit` / `redeem` / `redeemWithPermit` must not execute while Vault and dToken Underlying diverge. `whenUnderlyingReady` validates `dToken.underlying() == vault.underlying()` at use time and fails closed with `UnderlyingMismatch` (unset -> `UnderlyingNotSet`). It covers both immediate and delayed paths regardless of activation order ([VAULT-FR-011](#vault-fr-011)).
- Verification: unit (mismatch and unset reverts, both paths), invariant=[VAULT-INV-010](#vault-inv-010)

### <a id="vault-sec-003"></a>VAULT-SEC-003: Received amount is accounted by balance delta (declared-independent)

- Type: Security
- Statement: `receiveFromStrategy` must determine `received` from the balance delta before/after receipt, not the declared amount, so fee-on-transfer / rebasing behavior cannot shift accounting when actual receipt is below declared amount ([VAULT-FR-005](#vault-fr-005)).
- Verification: unit (balance-delta accounting with fee-on-transfer mock, cache invalidation, valuation recovery), invariant=[VAULT-INV-005](#vault-inv-005)

### <a id="vault-sec-004"></a>VAULT-SEC-004: Fund containment before activation (defense in depth)

- Type: Security
- Statement: Funds must not flow to operations in a placeholder Vault (`underlying == address(0)`). Defense in depth: (1) `addStrategy` Underlying invariant prevents registration, (2) `deposit` reverts via `whenUnderlyingReady`, (3) views return 0, and (4) `allocate()` early-returns ([VAULT-FR-011](#vault-fr-011)).
- Verification: unit (each containment layer), invariant=[VAULT-INV-011](#vault-inv-011)

### <a id="vault-sec-005"></a>VAULT-SEC-005: Minimal ALLOCATOR authority (fixed destination and fixed ratio)

- Type: Security
- Statement: ALLOCATOR may call only the four functions `allocate` / `Strategy.sendToVault` / `Strategy.sendProfitToVault` / `transferYieldToTreasury`; destinations must be limited to pre-registered Strategies, recovery target to Vault, and yield destination to current `treasury` (fixed from ALLOCATOR's perspective; only GOV `setTreasury` changes it). A compromised ALLOCATOR key must not be able to send to arbitrary addresses, and Vault outbound operations (`allocate` / `transferYieldToTreasury`) must be stoppable through `pauseAllocation` ([§10](#10-governance-operations-and-upgrade-requirements-gov) / [VAULT-FR-012](#vault-fr-012)).
- Verification: unit (ALLOCATOR cannot change treasury, fixed destination, outbound stopped while paused), manual (role configuration review)

### <a id="vault-sec-006"></a>VAULT-SEC-006: Asymmetric pause/unpause authority

- Type: Security
- Statement: pause (four paths) and emergency neutralization (`emergencyDisableStrategy` / `removeStrategy` / `removeFromWhitelist`) must be `GUARDIAN_ROLE`, while unpause, re-enable, and increases must be `GOV_ROLE` (holder = Timelock) only. A compromised guardian key can only perform "reversible stop/neutralize" actions, and resume requires GOV approval through Timelock (12h). GUARDIAN_ROLE operations must not be able to lower backing valuation (estimated / principal / valuation cache) at all (no markdown authority, [VAULT-FR-014](#vault-fr-014) / [VAULT-FR-019](#vault-fr-019)).
- Verification: unit (pause/neutralize by GUARDIAN, unpause by GOV only, backing unchanged by GUARDIAN operations)

### <a id="vault-sec-007"></a>VAULT-SEC-007: Limit upgrade authority

- Type: Security
- Statement: New implementation approval must be limited to GOV_MULTISIG (`GOV_ROLE`; on mainnet holder = shared TimelockController only = 12h delay), and operational roles (ALLOCATOR / GUARDIAN / WRITEOFF / Strategy, etc.) must not be able to upgrade. Storage must be append-only (no reordering or type changes for existing slots, [VAULT-FR-015](#vault-fr-015)).
- Verification: unit (non-GOV authorization revert), manual (storage layout review)

### <a id="vault-sec-008"></a>VAULT-SEC-008: Prevent silent burn of dToken dust

- Type: Security
- Statement: If `_dTokenAmount` in `redeem` / `redeemWithPermit` does not exactly correspond to an Underlying base unit, the call must revert with `InvalidDTokenAmount` before burn / permit nonce consumption / request creation. For USDC(6), `1e12` dToken is the minimum redeem unit; for WBTC(8), `1e10` dToken is the minimum. dToken dust below this must not be burned for 0 Underlying.
- Verification: unit (USDC6 / WBTC8 dust, permit nonce not consumed), invariant=[VAULT-INV-002](#vault-inv-002) / [VAULT-INV-014](#vault-inv-014)

### <a id="vault-sec-009"></a>VAULT-SEC-009: Isolate individual reverts for blacklistable tokens

- Type: Security
- Statement: If a blacklistable Underlying such as USDC reverts on transfer, `redeem` / `claim` state updates (burn, request creation, `claimed`, `pendingWithdrawals`) must roll back through full transaction revert. The Vault does not perform batch payout, so blacklist failures are confined to that user's individual transaction/request.
- Verification: unit (blacklisted receiver / request owner transfer revert rolls back state), manual (token risk review)

### <a id="vault-sec-010"></a>VAULT-SEC-010: Live full-backing guard on user flows (fail-closed)

- Type: Security
- Statement: `deposit` / `redeem` / `redeemWithPermit` / unsettled `claim` must require `L_effective == 0` or `A_confirmed >= L_effective` in the pre-state before changing value, liabilities, or queue state. `A_confirmed` is the Vault raw Underlying balance, including protected backstop reserve, plus `min(est, principal)` for every registered Strategy whose live `estimatedTotalUnderlying()` and `principal()` reads both succeed. A Strategy without both live reads contributes a lower bound of zero; valuation cache must never be included, even when fresh. If confirmed assets alone cannot cover all liabilities, revert with `BackingRatioBelowMinimum(A_confirmed / L_effective, 1e18)`.
- Ordering: check `deposit` before Underlying `transferFrom`; `redeem` before burn / request / transfer; `redeemWithPermit` before permit nonce / allowance consumption; and `claim` before `claimed` / `pendingWithdrawals` updates and transfer. Existing errors or idempotent returns for unissued, settled, or immature requests may occur first.
- Recovery boundary: this guard does not apply to `backstopDeposit` / `releaseBackstopToBuffer` / `receiveFromStrategy` / Strategy recovery, writeoff, valuation refresh, or emergency rails; repair paths must stay open. User flows resume without a manual reset as soon as raw balance or restored live valuation proves `A_confirmed >= L_effective`. A single valuation failure must not become permanent denial of service when other confirmed assets alone prove full backing.
- Residual: the guard cannot detect an external venue loss that a Strategy's live `estimatedTotalUnderlying()` / `principal()` does not reflect. Conservative Strategy-specific valuation, caps, monitoring, recovery/writeoff, and backstop remain required.
- Verification: unit (underbacked revert and unchanged token / permit / queue / request state on all four paths, fresh cache rejected, `L_effective == 0`, automatic restart after backstop or live-valuation recovery), invariant=[VAULT-INV-001](#vault-inv-001)

---

## 10. Governance, Operations, and Upgrade Requirements (GOV)

### <a id="vault-gov-001"></a>VAULT-GOV-001: Role separation (initial concentration -> production separation)

- Statement: `initialize` grants `_admin` five roles in a concentrated initial state, but in production (1) `DEFAULT_ADMIN_ROLE` / `GOV_ROLE` are held **only by the shared TimelockController (minDelay 12h)**, (2) `WRITEOFF_ROLE` only by high-quorum GOV multisig, (3) `GUARDIAN_ROLE` only by Guardian multisig, (4) `ALLOCATOR_ROLE` only by `DF_ALLOCATOR`, and `_admin` is **revoked from all roles**. Single-holder status is mechanically verified as a deployment gate ([§4](#4-actors-roles-and-trust-boundaries) / [VAULT-FR-010](#vault-fr-010) / [VAULT-GOV-004](#vault-gov-004)).
- Verification: manual (deployment configuration review) + holder asserts in deploy script / integration test

### <a id="vault-gov-002"></a>VAULT-GOV-002: Role x operation matrix

- Statement: Major operations map to roles as follows.

| Operation | GOV (=Timelock 12h) | WRITEOFF (GOV multisig, immediate) | ALLOCATOR | GUARDIAN (immediate) | permissionless |
| --- | --- | --- | --- | --- | --- |
| deposit (mint) | | | | | ✓ |
| redeem | | | | | ✓ |
| claim (settle WithdrawRequest to owner) | | | | | ✓ (any caller, fixed owner payout, when `pausedClaim == false`) |
| allocate | | | ✓ | | |
| `Strategy.sendToVault` (principal push recovery) | | | ✓ | | |
| `Strategy.sendProfitToVault` (profit push, outside allocation pause) | | | ✓ | | |
| `transferYieldToTreasury` (buffer surplus -> Treasury, allocation-pause target) | | | ✓ | | |
| `receiveFromStrategy` (push receipt) | | | | | ✓ (registered Strategy only) |
| `backstopDeposit` (replenishment deposit, no dToken mint) | | | | | ✓ |
| `releaseBackstopToBuffer` (explicit release of replenishment reserve) | ✓ | | | | |
| `writeoffStrategyPrincipal` (finalize principal impairment) | | ✓ | | | |
| Async Strategy `setPendingWithdrawalValuationBps` (pending valuation markdown; downward changes require `pausedAllocation == true`) | | ✓ | | | |
| Add Strategy (addToWhitelist / addStrategy) | ✓ | | | | |
| Remove Strategy (removeFromWhitelist / removeStrategy, fail-safe) | | | | ✓ | |
| `emergencyDisableStrategy` (immediate disable, [VAULT-FR-019](#vault-fr-019)) | | | | ✓ | |
| Update weights / caps / re-enable (updateStrategy) | ✓ | | | | |
| Update buffer / allocator parameters (setBufferConfig / setAllocatorConfig / setWithdrawDelay / setStrategyValuationMaxAge) | ✓ | | | | |
| Change Treasury destination (setTreasury, not one-shot) | ✓ (Vault GOV_ROLE) | | | | |
| Explicitly invalidate valuation cache (invalidateStrategyValuationCache; not placed under GUARDIAN because of markdown capability) | ✓ | | | | |
| Cap update (dToken.setCap) | ✓ (dToken Owner = Timelock) | | | | |
| Initial Underlying setting (dToken.setTokenInfo, one-shot) | ✓ (dToken Owner = Timelock) | | | | |
| Deferred Underlying binding (setUnderlying, one-shot) | ✓ (Vault GOV_ROLE) | | | | |
| pause (pauseDeposit / pauseRedeem / pauseClaim / pauseAllocation) | | | | ✓ | |
| unpause (unpauseDeposit / unpauseRedeem / unpauseClaim / unpauseAllocation) | ✓ | | | | |
| `Strategy.emergencyWithdraw` / `Strategy.emergencyWithdrawFromAave` (destination fixed to Vault) | | | | ✓ (Strategy Owner = Guardian multisig) | |
| `Strategy.sweepRewardToken` (non-Underlying and non-position reward -> fixed Treasury) | | | | ✓ (Strategy Owner = Guardian multisig) | |
| Strategy Upgrade (UUPS, upgrader = Timelock) | ✓ | | | | |
| Contract Upgrade (UUPS) | ✓ | | | | |
| Role grant / revoke (`grantRole` / `revokeRole`) | ✓ (`DEFAULT_ADMIN_ROLE`) | | | | |
| Renounce own role (`renounceRole`) | ✓ (self only) | ✓ (self only) | ✓ (self only) | ✓ (self only) | |

- For details, see the corresponding FR in §6 (the "Authorization" item). Bodies of `Strategy.sendToVault` / `sendProfitToVault` / `emergencyWithdraw` / `sweepRewardToken` are in [Strategy Requirements Specification](strategies/Strategy.md).
- Verification: manual (coverage of authority tests)

### <a id="vault-gov-003"></a>VAULT-GOV-003: Role design considerations

- Statement:
  - **GOV_MULTISIG (holder = shared TimelockController)**: holds critical power over funds, parameters, and contracts, but **all operations have a 12h public delay** (GOV multisig is Timelock PROPOSER/EXECUTOR). It has no immediate emergency operation; emergency loss finalization is separated to WRITEOFF_ROLE (`writeoffStrategyPrincipal` / async pending valuation bps), and immediate neutralization/removal is separated to GUARDIAN_ROLE (`emergencyDisableStrategy` / `removeStrategy` / `removeFromWhitelist`). Actual asset withdrawal is done through ALLOCATOR `Strategy.sendToVault` or Strategy-owner (= Guardian multisig) emergency functions.
  - **WRITEOFF (high-quorum GOV multisig, immediate)**: only `writeoffStrategyPrincipal` and async Strategy pending valuation bps changes. Downward bps changes require `pausedAllocation == true`, so they can affect liquidation pricing only after Guardian has stopped new allocation and Treasury sweep. Because timing is determined by role holder, supporting "writeoff/markdown immediate, other GOV operations delayed" requires a separate role from GOV_ROLE. If co-located, either markdown is delayed 12h or immediate multisig can also execute unpause, etc. It is also not put under Guardian's immediate role: Guardian operates with lower quorum for fast emergency response, while markdown can cause unjust markdown -> unjust liquidation and requires high quorum. Co-locating would make either pause slow or markdown too easy.
  - **ALLOCATOR**: restricted to `allocate()`, `Strategy.sendToVault()`, `Strategy.sendProfitToVault()`, and `transferYieldToTreasury()`, following preconfigured Strategies/weights/registrations. If the bot key is compromised, damage is limited to sending to registered Strategies, recovering Strategy -> Vault buffer, and sending buffer surplus to `treasury` (only one current `treasury`; ALLOCATOR cannot change it and only GOV `setTreasury` can). However, `transferYieldToTreasury` can over-send depending on AUM valuation, so it remains role-gated and stoppable by `pauseAllocation` with human monitoring ([§12](#12-failure-and-exception-behavior-err)). It is not permissionless (decided in [VAULT-TBD-004](#vault-tbd-004)). Liveness is achieved by granting `ALLOCATOR_ROLE` to multiple subjects (AccessControl supports multiple holders).
  - **GUARDIAN**: Guardian multisig. Allowed only emergency stop (four pause paths) and reversible neutralization (`emergencyDisableStrategy` / `removeStrategy` / `removeFromWhitelist`). Resume/re-enable is GOV=Timelock only. It cannot go through Timelock or it would not function as emergency stop. In production, it is separated from Timelock as a Guardian multisig. Allowed operations are limited to "backing-neutral or pure flow control"; no markdown authority (writeoff / `invalidateStrategyValuationCache`). invalidateCache is GOV (delayed) because clearing cache during live valuation failure can value that Strategy at 0 and trigger liquidations; urgency is low because cache expires automatically through `strategyValuationMaxAge`.
- Verification: manual

### <a id="vault-gov-004"></a>VAULT-GOV-004: Separation of timelock and emergency pause

- Statement (finalized 2026-06-12): mainnet requires the following holder configuration (canonical design decision: [../policies/Governance-Roles-Timelock.md](../policies/Governance-Roles-Timelock.md). Principle: operations that can cause fund outflow, dilution, or markdown are delayed or high quorum; reversible fail-safe is immediate; recovery is delayed).
  - **The shared TimelockController (minDelay = 12h) is the only holder of `GOV_ROLE` / `DEFAULT_ADMIN_ROLE`**. PROPOSER / EXECUTOR = GOV multisig, CANCELLER = the same Admin multisig as PROPOSER / EXECUTOR [updated 2026-06-29; Day-1 adopts the OZ `TimelockController` default in which the proposer is also granted `CANCELLER_ROLE`], Timelock's own admin already renounced (prevents changing timelock configuration without delay). It is the **same Timelock** shared with dToken Owner, Strategy upgrader, and future Treasury components.
  - **The only role GOV multisig directly holds on Vault is `WRITEOFF_ROLE`** (directly holding GOV_ROLE / DEFAULT_ADMIN is prohibited because it bypasses the entire 12h delay).
  - **GUARDIAN_ROLE = Guardian multisig** (four pause paths + emergency neutralization, immediate). Emergency stop does not go through timelock.
  - **`ALLOCATOR_ROLE` = operations bot / multisig**.
  - unpause, re-enable, increases, setting changes, and upgrades all go through GOV (= Timelock, 12h) ("easy to pull the brake, slow to release it").
  - **deploy gate (mechanical verification required)**: single holder for each role / deployer revoked from all roles / Timelock PROPOSER-EXECUTOR-CANCELLER configuration and admin renounce / bounded `allocateMaxMove` and `allocatorCooldown` values (do not enter operations with initialize defaults `type(uint256).max` / `0`).
- Verification: manual (deployment configuration review) + holder and Timelock configuration asserts in deploy script / integration test

---

## 11. Events and Monitoring Requirements (EVT)

| ID | Event | Purpose (off-chain) |
| --- | --- | --- |
| VAULT-EVT-001 | `Deposited(user, underlyingAmount, dTokenAmount)` | Track deposit/Mint. `user = msg.sender`. Does not include referralCode (referral recorded on Zapper side) |
| VAULT-EVT-002 | `Redeemed(user, receiver, dTokenAmount, underlyingPaidNow, requestId)` | Track redeem. `requestId == 0` means immediate completion |
| VAULT-EVT-003 | `WithdrawRequested(user, receiver, requestId, amount, claimableAt)` | Detect delayed redemption (buffer shortage). Reconstruct unclaimed queue by diffing against `WithdrawClaimed` |
| VAULT-EVT-004 | `Allocated(bufferBefore, targetBuffer, bufferAfter)` / `StrategyAllocated(strategy, amount)` / `StrategyAllocationSkipped(strategy)` | Buffer before/target/after for `allocate()` aggregate, actual allocation per Strategy, and a Strategy skipped because its post-preflight cap valuation reread was unavailable, its cap was reached, or its rejected deposit was recovered exactly. Managed-assets preflight failure returns without an event and is monitored through status availability plus the keeper receipt |
| VAULT-EVT-005 | `ReceivedFromStrategy(strategy, declaredAmount, received)` | Push receipt from registered Strategy. Difference between `declaredAmount` and `received` detects fee-on-transfer / token anomalies |
| VAULT-EVT-006 | `WithdrawClaimed(user, requestId, amount)` | Receipt of delayed redemption. `user = req.owner`, `amount = req.underlyingAmount` |
| VAULT-EVT-007 | `YieldTransferredToTreasury(amount, treasury)` | Treasury transfer of buffer surplus (emitted even when `amount == 0`). Monitor for excessive frequency/amount |
| VAULT-EVT-008 | `StrategyWhitelisted` / `StrategyRemovedFromWhitelist` / `StrategyAdded(strategy, weightBps, cap)` / `StrategyUpdated(strategy, weightBps, cap, enabled)` / `StrategyEmergencyDisabled(strategy, oldWeightBps)` / `StrategyRemoved(strategy)` | Track Strategy management (GOV / GUARDIAN operations). `StrategyEmergencyDisabled` is GUARDIAN immediate disable ([VAULT-FR-019](#vault-fr-019)) = incident response start signal |
| VAULT-EVT-009 | `StrategyPrincipalWrittenOff(strategy, amount)` | WRITEOFF finalizes unrecoverable principal. `StrategyPrincipalWrittenOff.amount` is actual principal reduction, not requested amount. Valuation cache updates, failures, reductions, and invalidations are monitored through `strategyValuationCaches` / `getStrategyStatuses()` / `cacheStale` status, not runtime events |
| VAULT-EVT-010 | `UnderlyingSet(underlying)` | Emitted once when a placeholder Vault's Underlying is deferred-bound |
| VAULT-EVT-011 | `BufferConfigUpdated(oldTargetBps, newTargetBps, oldFloor, newFloor)` / `AllocatorConfigUpdated(oldMaxMove, newMaxMove, oldCooldown, newCooldown)` / `StrategyValuationMaxAgeUpdated(oldMaxAge, newMaxAge)` / `WithdrawDelayUpdated(oldDelay, newDelay)` / `TreasuryUpdated(oldTreasury, newTreasury)` | Track old/new GOV setter values. In particular, `TreasuryUpdated` monitors yield destination changes and `StrategyValuationMaxAgeUpdated` is canonical for fallback TTL changes |
| VAULT-EVT-012 | `DepositPaused` / `DepositUnpaused` / `RedeemPaused` / `RedeemUnpaused` / `ClaimPaused` / `ClaimUnpaused` / `AllocationPaused` / `AllocationUnpaused` | Detect emergency stop/resume (four independent paths). `ClaimPaused` is the most critical alert because it freezes vested liabilities |
| VAULT-EVT-013 | ERC1967 `Upgraded(newImpl)` | Track UUPS upgrades |
| VAULT-EVT-014 | `BackstopDeposited(backstop, declaredAmount, received)` | Replenishment deposit without minting dToken. Difference between declared and received detects fee-on-transfer / token anomalies |
| VAULT-EVT-015 | `BackstopReleased(caller, amount)` | Track GOV operation that releases protected reserve to liquid buffer |

> dToken-side events (`CapUpdated` = [DTKN-FR-006](dToken.md), `TokenInfoSet` = [DTKN-FR-002](dToken.md)) and Strategy-side events (`Deposited` / `SentToVault` / `ProfitSentToVault` / `PrincipalWrittenOff` / `EmergencyWithdrawn`, [Strategy Requirements Specification](strategies/Strategy.md)) are emitted from their respective contracts. See each canonical document for signatures and meaning.

**Minimum monitoring metrics**

- `A - L_effective` (surplus/shortfall) / buffer ratio (liquid buffer/A) / `backstopBalance`
- Total unprocessed request amount / average wait time (diff between `WithdrawRequested` and `WithdrawClaimed`; must match `pendingWithdrawals` view)
- GOV setting change events (VAULT-EVT-011) and post-state view consistency
- Per-Strategy invested amount (`StrategyAllocated`), allocation skips (`StrategyAllocationSkipped` + status availability / capRemaining and remaining buffer), cap utilization, current alloc. Current values use `getStrategyStatuses()`; compatible list, `StrategyConfig`, and estimated balance use `getAllStrategies()`; count uses `getStrategiesCount()` as primary source ([VAULT-FR-013](#vault-fr-013))
- Per-Strategy divergence between `estimatedUnderlying` and `principal` (`estimatedLoss > 0` is principal impairment signal, `estimatedGain > 0` is estimated upside signal). `estimateAvailable == false` / `principalAvailable == false` are monitoring alerts
- Amount/frequency/backstop address for `BackstopDeposited` (match replenishment plan) and amount/timing for `BackstopReleased` (confirm approval to fund claims)
- Frequency/amount of `transferYieldToTreasury` (detect over-transfer)
- Difference between `requested` and `actual` (= `sent`) in `Strategy.sendToVault` (liquidity stress signal, [Strategy Requirements Specification](strategies/Strategy.md))
- Difference between `declaredAmount` and `received` in `ReceivedFromStrategy` (fee-on-transfer / token anomaly detection)
- Continued `getStrategyStatuses().usingCachedConservativeValue == true`, `estimateAvailable == false`, `principalAvailable == false`, `cacheStale == true` (external protocol view failure / cache expiry proximity)

---

## 12. Failure and Exception Behavior (ERR)

> This section covers system-level exception behavior (pause / Underlying unset / buffer shortage / Strategy failure and principal impairment / known delayed-redemption risks). For the no-core-modification policy, see [Product-Overview](../Product-Overview.md) §5. For Strategy-specific risk, see [Strategy Requirements Specification](strategies/Strategy.md). For dToken / Permit, see [dToken Requirements Specification](dToken.md).

### Placeholder phase (Underlying unset) behavior

| Function | Placeholder phase (`underlying == 0`) | Active phase |
| --- | --- | --- |
| `deposit` / `redeem` / `redeemWithPermit` | `UnderlyingNotSet` revert (`whenUnderlyingReady`) | executable (when not paused and [VAULT-SEC-010](#vault-sec-010) is satisfied) |
| `backstopDeposit` / `releaseBackstopToBuffer` | `UnderlyingNotSet` revert (`whenUnderlyingReady`) | executable (release is GOV only) |
| `addStrategy` | `UnderlyingNotSet` revert (Underlying invariant) | executable (when whitelisted and collateral matches) |
| `bufferBalance()` / `backstopBalance()` / `totalUnderlying()` | returns `0` (placeholder-safe) | actual balance and conservative valuation total |
| `allocate()` | early return as if `managedUnderlying() == 0` | executable |

### Underlying setting risk ([VAULT-SEC-002](#vault-sec-002))

- If the wrong Underlying is specified during deferred initial setting, it cannot be changed later -> strictly enforce GOV_MULTISIG procedure from deployment through `dToken.setTokenInfo` -> `vault.setUnderlying` completion (multisig approval and pre-testnet validation).
- If Vault and dToken Underlying diverge, custody asset and 18-decimal conversion/valuation diverge -> `setUnderlying` and all user value flows enforce `dToken.underlying() == vault.underlying()` and fail closed with `UnderlyingMismatch`.
- Underlying changes while issued balances exist are structurally impossible (contract-side revert) -> physically prevented by the double guard `underlying == address(0)` and dToken-side `totalSupply() == 0` ([DTKN-FR-002](dToken.md)).

### Redemption liquidity risk (inventory shortage -> increased delays)

- When users want to redeem dToken to Underlying, insufficient buffer creates delay; if persistent, this can harm dToken trust and market value.
- Mitigations: optimize `bufferTargetBps` per collateral (not fixed 20%, [Parameters.md](../../../Parameters.md)) / use multiple Strategies with guaranteed immediate-recovery capacity / operate and monitor `Strategy.sendToVault` bot and emergency stops.

### Strategy risk (smart contract, liquidity, peg, unbonding) and staged recovery

- Strategy addition authority is GOV (= Timelock, 12h) only. Risk is limited by Strategy-level caps (maximum allocation per Strategy).
- **Emergency path: disable + staged recovery** (`writeoffStrategyPrincipal` is [VAULT-FR-009](#vault-fr-009); `Strategy.emergencyWithdraw` is [Strategy Requirements Specification](strategies/Strategy.md)):
  - Stage 1: GUARDIAN sets `pausedAllocation = true` to stop ALLOCATOR `allocate` and `transferYieldToTreasury` (`Strategy.sendToVault` / `Strategy.sendProfitToVault` remain outside pause and can continue recovering/pulling funds to Vault)
  - Stage 2: GUARDIAN calls `emergencyDisableStrategy(strategy)` to immediately disable the problem Strategy (exclude from new allocation, [VAULT-FR-019](#vault-fr-019))
  - Stage 3: ALLOCATOR recovers through `Strategy.sendToVault(full amount equivalent)`. During external-protocol incidents, use Strategy-specific owner emergency functions and use `emergencyWithdraw` (destination fixed to Vault) for directly held idle donations / residuals. These paths route through `receiveFromStrategy`: exact delivery reduces valuation cache by actual receipt, while declared/received mismatch invalidates it. GOV / ops reconcile `StrategyValuationCacheReduced` / `StrategyValuationCacheInvalidated` with `ReceivedFromStrategy`, then run `refreshStrategyValuation` to prove recovery
  - Stage 4: unrecoverable amount is finalized by WRITEOFF_ROLE (high-quorum GOV multisig, immediate) via `writeoffStrategyPrincipal`. If `A_confirmed < L_effective`, [VAULT-SEC-010](#vault-sec-010) has already stopped user flows. As needed, GUARDIAN sets `pauseDeposit` / `pauseRedeem` / `pauseClaim` as defense-in-depth for incident coordination ([VAULT-FR-014](#vault-fr-014))
  - Stage 5: if `A_confirmed < L_effective` remains after recovery/writeoff, Treasury / insurance / backstop deposits Underlying as protected reserve through `backstopDeposit`
  - Stage 6: GOV releases only the amount that should fund pending claims / normal redeem liquidity by `releaseBackstopToBuffer`
- Individual stop through `enabled` flag. Full removal through `removeStrategy` (requires `principal == 0` and live `estimatedTotalUnderlying == 0`; unrecoverable amount must be written off first, and recoverable residual assets returned to Vault before removal).

### Oracle reflection of dToken backing impairment (downward propagation of collateral value)

- If Strategy hacking, bad debt, or slashing causes actual holdings `A = totalUnderlying()` to fall below principal claims `L_effective`, dToken **depegs** against Underlying (dToken is a 1:1 claim but under-backed). Because `dToken.totalSupply()` does not decrease, using only market price for collateral valuation **overvalues** collateral and causes over-borrowing / JPYdf bad debt.
- **Source of determination**: `A < L_effective` is not determined by a dToken price oracle. The Vault builds `A` from raw Underlying balance (liquid buffer + backstop reserve) plus each Strategy's `min(estimatedTotalUnderlying(), principal())`. If Strategy loss appears in `estimatedTotalUnderlying()`, backing decreases automatically. If external protocol loss is not reflected in the Strategy valuation view, it cannot be automatically detected on-chain and depends on recovery, individual disable, `writeoffStrategyPrincipal`, and `backstopDeposit` operations.
- **Temporary valuation failure handling**: while live valuation can be read, always use live `min(est, principal)` and reflect loss into backing immediately. Only if `estimatedTotalUnderlying()` or `principal()` read reverts does the Vault use a bounded last-good cache per Strategy. If cache is over TTL, uninitialized, or invalidated, valuation returns to 0.
- **Mitigation (downward propagation to oracle)**: this Vault supplies an available `backingRatioForPricing()` value ([VAULT-FR-016](#vault-fr-016)); Oracle Layer ([Oracle Requirements Specification](Oracle.md) `ORCL-FR-014`) multiplies it into dToken collateral price. Thus measured backing impairment propagates as a downward collateral-value adjustment into **Liquity core liquidation / TCR<SCR branch shutdown / Urgent Redemptions** (applied symmetrically to both consumers), while unavailable valuation triggers standard oracle failure.
- **Mitigation (automatic stop of user flows)**: [VAULT-SEC-010](#vault-sec-010) uses only cache-free `A_confirmed` and stops deposit / redeem / queue reservation / claim in the pre-state while full backing cannot be proved. Fresh cache may temporarily keep oracle pricing available, but it cannot open user flows; the automatic guard clears after backstop replenishment or live-valuation recovery.
- **Double defense**: conservative `min(est, principal)` automatically lowers backing if `est` reflects loss; WRITEOFF `writeoffStrategyPrincipal` ([VAULT-FR-009](#vault-fr-009)) lowers `principal` and permanently confirms `A` downward.
- **Separation from Stability Pool responsibility**: Stability Pool only processes Trove liquidation after backing-driven price decrease; it does not replenish Underlying to the Vault. To avoid directly imposing Strategy loss on SP depositors, dToken backing repair is contained on the Vault side through Strategy recovery, writeoff, and `backstopDeposit` ([VAULT-FR-017](#vault-fr-017)).
- **Replenishment path**: `backstopDeposit` does not mint dToken; it accumulates Underlying in protected reserve and restores `totalUnderlying()` / `backingRatio()`. Reserve is not usable for normal redeem / claim until GOV releases it. Buffer-insufficient `claim` can be retried after GOV releases the required amount to liquid buffer via `releaseBackstopToBuffer`.
- **Residual issues**: if `est` does not promptly reflect external protocol loss, the automatic guard cannot observe the loss either and timeliness depends on writeoff. If real impairment occurs during a fresh-cache period while valuation view is unavailable, pricing can remain overvalued until TTL, although the user-flow guard does not use cache. If the pricing call fails or its live/cache valuation is unavailable, PriceFeed does not keep pricing through `lastGoodBacking`; it enters the standard oracle-failure path (branch shutdown + `lastGoodPrice`). Severe measured impairment does not have a dedicated backing shutdown threshold; the policy is to rely on price decrease and existing mechanisms.

### Impact of ALLOCATOR key compromise (damage limited by fixed destination and fixed ratios, [VAULT-SEC-005](#vault-sec-005))

- ALLOCATOR is limited to **four** callable paths: `allocate`, `Strategy.sendToVault`, `Strategy.sendProfitToVault`, and `transferYieldToTreasury`. Destinations are constrained to pre-registered Strategies, recovery target to Vault, and `treasury` (fixed from ALLOCATOR's perspective; only GOV `setTreasury` changes it), making arbitrary-address draining easier to prevent.
- **Remaining risks**:
  - Excessive repeated `allocate` calls (gas / operational burden)
  - Abuse of `Strategy.sendToVault` / `Strategy.sendProfitToVault` (lower yield / operational instability). Funds still stay in-system because destination is fixed to Vault buffer
  - **Over-transfer to Treasury through `transferYieldToTreasury` (Vault buffer Underlying exits the system)**: if AUM (`estimatedTotalUnderlying`) is overvalued or loss is not reflected in `est`, `surplus = M - L_effective` can be inflated and buffer over-transferred. `M = managedUnderlying` excludes protected backstop reserve and cached Strategy value, so backstop deposits or valuation fallback alone do not create Treasury surplus. Unlike `sendToVault` / `sendProfitToVault` (in-system), this function **leaves the Vault buffer**. Mitigations: conservative `min(estimatedTotalUnderlying, principal)`, buffer cap, timely `writeoffStrategyPrincipal`, and emergency `pauseAllocation`. Non-Underlying and non-position reward token `Strategy.sweepRewardToken` is aggregation of separate assets to Treasury and does not directly move Vault buffer/backing accounting
- **Guardrails (implementation state variable names)**:
  - `allocatorCooldown` (applies to `allocate`; uses `lastAllocatorTime` as last execution time. **`Strategy.sendToVault` is not cooldown-limited** because user redeem-driven buffer replenishment requires immediate response)
  - `allocateMaxMove` (**per-call buffer -> Strategy movement upper bound for `allocate()`**. Does not apply to `Strategy.sendToVault`)
  - `pausedAllocation` (GUARDIAN can stop it. **Scope is `allocate()` and `transferYieldToTreasury()`**, outbound operations from Vault to Strategy / Treasury. `Strategy.sendToVault` / `Strategy.sendProfitToVault` are not paused because recovery direction safely returns funds to Vault buffer). **Emergency path**: while `pausedAllocation = true` stops outbound, GUARDIAN can `emergencyDisableStrategy`, WRITEOFF_ROLE can `writeoffStrategyPrincipal`, and ALLOCATOR can continue recovery via `Strategy.sendToVault` / `Strategy.sendProfitToVault`, enabling "stop new allocation and Treasury outflow while performing staged recovery"
  - `strategyValuationMaxAge` (last-good cache TTL on valuation failure; 0 disables fallback). In normal operations, keeper / monitoring watches `refreshStrategyValuation` and `getStrategyStatuses`; near stale, GOV/ALLOCATOR runbooks decide refresh, pause, individual disable, or cache invalidation

### AUM valuation and monetization (over-transfer) risk ([VAULT-FR-007](#vault-fr-007))

- If `estimatedTotalUnderlying()` is overvalued, `transferYieldToTreasury` can inflate `surplus = M - L_effective`.
- **Guardrails**:
  - Conservative valuation in each Strategy implementation (subtract withdrawal friction and penalties). Vault values Strategy portions of both `A = totalUnderlying()` and `M = managedUnderlying` at live `min(estimatedTotalUnderlying, principal)` and does not include unrealized "paper profit" in `transferYieldToTreasury`. On valuation failure, `A` may use bounded cache, but `M` does not send against cached value or a partial sum and becomes 0 in full. `M` also excludes protected backstop reserve
  - Add `pendingWithdrawals` to liabilities (`L_effective`) so unclaimed claims do not flow to Treasury
  - **Transfer is buffer-capped** ([VAULT-FR-007](#vault-fr-007)). `transferYieldToTreasury` can only send on-hand buffer surplus (cannot send assets that do not exist); profit realization is handled by `Strategy.sendProfitToVault` (bounded by `realizedYield()`) plus Strategy-side Vault balance-delta accounting for the yield-only direct transfer. `min(est, principal)` prevents pre-recognition when `est > principal`, but if loss is not reflected in `est` (or writeoff is delayed) and `est` exceeds true recoverable amount, over-transfer risk remains and is mitigated by timely writeoff and conservative valuation
  - Non-Underlying and non-position reward tokens (Aave incentives / Merkl, etc.) are excluded from `estimatedTotalUnderlying()` and `totalUnderlying()` and are not targets of `transferYieldToTreasury`. If rewards are used for backing repair, they are separately converted to Underlying and explicitly deposited through `backstopDeposit` or similar. Position / receipt / accounting tokens are protected tokens in derived Strategies and rejected from reward sweep
  - Initially, `sendProfitToVault` / `transferYieldToTreasury` are role-gated (ALLOCATOR) and monitored operationally

### Accepted risks and operational response for delayed redemption (WithdrawRequest) ([VAULT-TBD-002](#vault-tbd-002))

- **First-mover fairness**: a large redeem can drain the buffer immediately and
  send later users fully into delay. Pro-rata epoch / batch queues enlarge the
  audit surface, remove one-transaction completion from every user even when the
  buffer is sufficient, and do not remove the first-mover incentive. Day-1 does
  not adopt them. It also does not apply continuous automatic pro-rata on
  backing impairment. Instead, it preserves 1:1 through the automatic stop in
  [VAULT-SEC-010](#vault-sec-010), the operational freeze in
  [VAULT-FR-014](#vault-fr-014), and replenishment under
  [VAULT-FR-017](#vault-fr-017). Governance reserves only the distribution
  decision after a permanent loss is confirmed.
- **Race at claim time**: claims and new redeems compete first-come-first-served
  as soon as the buffer recovers, which can favor bots. Earmarking
  `pendingWithdrawals` in the immediate redeem path would queue every new redeem
  while `buffer <= pendingWithdrawals`, let unclaimed requests reduce immediate
  capacity indefinitely, and weaken Redemption arbitrage under stress. Day-1
  accepts the race. ALLOCATOR must promptly replenish to `B_target` including
  all `pendingWithdrawals`, while operations monitor request age
  (`WithdrawRequested` to `WithdrawClaimed`) and repeated claim
  `InsufficientBuffer` reverts. Reconsider earmarking, including a
  matured-request-only form, only if production shows claim starvation after
  replenishment.
- **Old requests**: expiry that destroys a claim is not adopted. Keeping an
  unclaimed request in `pendingWithdrawals` correctly records it in
  `L_effective` / `B_target`; the cost is only forgone yield on reserved
  liquidity. If monitoring later proves that stale reservations cause material
  harm, reconsider a **non-forfeiting reservation release** that removes the
  request only from `B_target` reservation while preserving the owner's claim
  and its liability in `L_effective`. Never confiscate an expired amount to
  Treasury; the claim remains permanent.

> UX residual issues when integrated with Zapper (requestId propagation, etc.) are covered in [Zapper Requirements Specification](Zapper.md).

### Known behavior of blacklistable Underlying (USDC, etc.)

- USDC is blacklistable, and `transfer` / `transferFrom` can revert under blacklist status.
- The Vault has no batch payout / batch claim, so a blacklisted receiver does not batch-stop other users' redeem / claim.
- If `safeTransfer` to `_receiver` reverts during buffer-sufficient `redeem`, the whole transaction reverts and dToken burn or request creation roll back.
- If `safeTransfer` to request owner reverts during `claim`, `claimed=true` and `pendingWithdrawals -= amount` roll back, and the request remains unclaimed. It can be retried after blacklist removal or other operational decision.
- Alternative receiver selection such as `claimTo` is not provided at this stage. It could bypass token issuer blacklist behavior, so adding it requires separate governance / legal / compliance review.

### Error catalog

| Error | Trigger |
| --- | --- |
| `Paused` | deposit under `pausedDeposit`; redeem/redeemWithPermit under `pausedRedeem`; claim under `pausedClaim`; allocate/transferYieldToTreasury under `pausedAllocation` ([VAULT-FR-001](#vault-fr-001)-[VAULT-FR-004](#vault-fr-004) / [VAULT-FR-006](#vault-fr-006) / [VAULT-FR-007](#vault-fr-007) / [VAULT-FR-014](#vault-fr-014)) |
| `UnderlyingNotSet` | Vault Underlying unset (`whenUnderlyingReady` / `addStrategy`) |
| `UnderlyingMismatch` | Vault / dToken Underlying mismatch (`whenUnderlyingReady` / `setUnderlying` / `addStrategy`, including uninitialized dToken) |
| `UnderlyingAlreadySet` | second call to `setUnderlying` ([VAULT-FR-011](#vault-fr-011)) |
| `UnderlyingNotAllowed` | Underlying not approved by dToken allowlist in `initialize` / `setUnderlying` |
| `ZeroAmount` | `_underlyingAmount == 0` / `_dTokenAmount == 0` (deposit/redeem/redeemWithPermit/backstopDeposit/releaseBackstopToBuffer) |
| `ZeroAddress` | zero `_dToken`/`_treasury`/`_admin` in `initialize`; zero `_receiver` in `redeem` / `redeemWithPermit`; zero address in `setUnderlying`, `setTreasury` |
| `InvalidDTokenAmount` | dToken amount in `redeem` / `redeemWithPermit` does not exactly correspond to an Underlying base unit |
| `PermitFailed` | permit fails in `redeemWithPermit` and existing allowance to the Vault is below `_dTokenAmount` |
| `NotContract` | `_dToken` in `initialize`, or Strategy in `addToWhitelist` / `addStrategy`, is EOA or undeployed |
| `CapExceeded` (dToken side) | dToken cap exceeded during deposit ([DTKN-FR-004](dToken.md)) |
| `CooldownNotMet` | `allocatorCooldown` not elapsed for `allocate()` ([VAULT-FR-004](#vault-fr-004)) |
| `InvalidBufferConfig` | `_targetBps > 10000` in `setBufferConfig` ([VAULT-FR-012](#vault-fr-012)) |
| `NotRegisteredStrategy` | `receiveFromStrategy` called by unregistered Strategy ([VAULT-FR-005](#vault-fr-005)) |
| `NotWhitelisted` | `addStrategy` without whitelist approval ([VAULT-FR-008](#vault-fr-008)) |
| `StrategyAlreadyExists` | `addStrategy` for already registered Strategy |
| `TooManyStrategies` | `addStrategy` when `strategies.length >= MAX_STRATEGIES` (`MAX_STRATEGIES = 32`) |
| `WeightExceedsBps` | `addStrategy` / `updateStrategy` causes `totalWeightBps` to exceed 10000 |
| `InvalidWeight` | `_enabled == false` and `_weightBps > 0` in `updateStrategy` ([VAULT-FR-009](#vault-fr-009)) |
| `StrategyNotFound` | target validation failure in `updateStrategy` / `writeoffStrategyPrincipal` |
| `StrategyHasPrincipal` | `principal != 0` in `removeStrategy` ([VAULT-FR-008](#vault-fr-008)) |
| `StrategyHasAssets` | live `estimatedTotalUnderlying()` cannot be read, or `estimatedTotalUnderlying != 0`, in `removeStrategy` |
| `RequestNotFound` | unissued ID in `claim` (an already-settled ID returns `0`, [VAULT-FR-006](#vault-fr-006)) |
| `RequestNotReady` | `claim` called before `claimableAt` |
| `InsufficientBuffer` | insufficient buffer during `claim` (no partial claim; retry later) |
| `InsufficientBackstop` | `_amount > backstopBalance()` in `releaseBackstopToBuffer` |
| `InvalidBackingTarget` | `_targetRatio > 1e18` in `backstopRequiredForRatio` ([VAULT-FR-018](#vault-fr-018)) |
| `BackingRatioBelowMinimum(actual, minimum)` | Pre-state `A_confirmed < L_effective` on `deposit` / `redeem` / `redeemWithPermit` / unsettled `claim`, or live post-allocation `A_confirmed < L_effective` on `allocate` (`minimum = 1e18`, [VAULT-SEC-010](#vault-sec-010)); or a caller-specified backing guard fails during writeoff / forced deallocation |
| `StrategyNotFound` | out-of-range index in `getStrategyAt` ([VAULT-FR-013](#vault-fr-013)) |

---

## 13. Acceptance Criteria and Verification Plan

Pass condition for each requirement = the verification method in the table is satisfied (test names and execution results are not written in this document; only the type of method is specified). Values are in [Parameters.md](../../../Parameters.md); 🔵 core behavior is in [Liquity-v2-Core-Spec.md](Liquity-v2-Core-Spec.md).

| ID | Requirement (summary) | Verification method |
| --- | --- | --- |
| VAULT-FR-001 | deposit (pause/ready/zero, pre-transfer backing, conversion, mint) | unit, integration |
| VAULT-FR-002 | redeem (pre-burn backing, immediate/delayed, first-come-takes-all, CEI, exact amount) | unit, integration, invariant=VAULT-INV-001/002/003/014 |
| VAULT-FR-003 | redeemWithPermit (exact/backing check -> permit -> burn(self), each revert) | unit, integration |
| VAULT-FR-004 | allocate (cooldown/pause/M==0, all-outbound stop and automatic recovery on partial valuation, cap clamp, fixed weights, deposit-failure skip, post-allocation exact backing) | unit, invariant=VAULT-INV-006 |
| VAULT-FR-005 | receiveFromStrategy (registration check, balance delta, zero short-circuit) | unit, invariant=VAULT-INV-005 |
| VAULT-FR-006 | claim (permissionless trigger, fixed owner payout, settled idempotent return, existence/time/backing/buffer, no partial, no expiry, pausedClaim stop) | unit, invariant=VAULT-INV-001/004 |
| VAULT-FR-007 | transferYieldToTreasury (M<=L early path, buffer clamp, min valuation, backstop exclusion) | unit, invariant=VAULT-INV-001/005 |
| VAULT-FR-008 | whitelist/addStrategy/removeStrategy (guards, Underlying invariant, principal==0, live estimatedTotalUnderlying==0, add=GOV / remove=GUARDIAN) | unit, invariant=VAULT-INV-007/008 |
| VAULT-FR-009 | updateStrategy (GOV) / writeoffStrategyPrincipal and forceDeallocateMorphoV2 (WRITEOFF, incident guards) | unit, invariant=VAULT-INV-009 |
| VAULT-FR-010 | initialize (placeholder capable, 5 roles, defaults) | unit, manual |
| VAULT-FR-011 | setUnderlying / whenUnderlyingReady (one-shot, dToken-first, both paths) | unit, invariant=VAULT-INV-010/011, manual |
| VAULT-FR-012 | GOV setters (authorization, validation, immediate reflection) | unit |
| VAULT-FR-013 | View group (placeholder-safe, index, raw vs min) | unit, manual |
| VAULT-FR-014 | pause/unpause (GUARDIAN/GOV asymmetry, four independent paths, defense-in-depth for automatic backing guard) | unit |
| VAULT-FR-015 | upgrade (GOV-only, storage append-only) | unit, manual |
| VAULT-FR-016 | operational backingRatio plus pricing availability (downward-only, liability dust rounding up, placeholder-safe) | unit, fork, invariant=VAULT-INV-012/014 |
| VAULT-FR-017 | backstopDeposit / releaseBackstopToBuffer (actual receipt, no mint, backing / user-flow liveness recovery, explicit release) | unit, integration, invariant=VAULT-INV-013 |
| VAULT-FR-018 | backing ops views (liability / shortfall / target-ratio replenishment amount, rounding up) | unit, integration, invariant=VAULT-INV-014 |
| VAULT-FR-019 | emergencyDisableStrategy (GUARDIAN immediate, weight zeroing, backing unchanged, re-enable only through updateStrategy) | unit, invariant=VAULT-INV-009 |
| VAULT-INV-001..014 | Each invariant in §8 | invariant (as specified in §8) |
| VAULT-SEC-001..010 | Each security requirement in §9 | unit, manual |

---

## 14. Open Items (TBD)

### VAULT-TBD-002

Fairness and accumulation in delayed redemption (WithdrawRequest) — whether to use pro-rata allocation instead of first-come-takes-all, how to mitigate claim race conditions, and whether to introduce request expiry. Related: [VAULT-FR-002](#vault-fr-002) / [VAULT-FR-006](#vault-fr-006) / [§12](#12-failure-and-exception-behavior-err).

**Partial decision**: continuous automatic pro-rata refunds on backing impairment are not adopted. On real loss, 1:1 is maintained through stop-the-bleed ([VAULT-FR-014](#vault-fr-014)) + backstop replenishment ([VAULT-FR-017](#vault-fr-017)), and only the distribution on confirmed permanent loss is reserved for governance judgment (basis: [`ADR-006`](../architecture/Architecture-Decision-Records.md#adr-006)). **Remaining open**: mitigation of the normal-time claim race and whether to introduce request expiry.

### VAULT-TBD-003

Resolved (founder decision 2026-06-12): the Vault itself has no built-in timelock; holders of `GOV_ROLE` / `DEFAULT_ADMIN_ROLE` are **only the shared TimelockController (minDelay = 12h, PROPOSER/EXECUTOR = GOV multisig, CANCELLER = the same Admin multisig as PROPOSER / EXECUTOR [updated 2026-06-29; Day-1 adopts the OZ `TimelockController` default in which the proposer is also granted `CANCELLER_ROLE`], Timelock's own admin already renounced)**. The same Timelock is shared with dToken Owner and Strategy upgrader. There is no emergency bypass; emergency response is separated into `GUARDIAN_ROLE` (four pause paths + `emergencyDisableStrategy` / `removeStrategy` / `removeFromWhitelist`, immediate) and `WRITEOFF_ROLE` (`writeoffStrategyPrincipal` / async Strategy pending valuation bps changes, high-quorum GOV multisig, immediate). Canonical source of this design decision: [../policies/Governance-Roles-Timelock.md](../policies/Governance-Roles-Timelock.md). Reflected in: [VAULT-FR-014](#vault-fr-014) / [VAULT-FR-015](#vault-fr-015) / [VAULT-FR-019](#vault-fr-019) / [VAULT-GOV-001](#vault-gov-001) / [VAULT-GOV-004](#vault-gov-004).

### VAULT-TBD-004

Permissionless `transferYieldToTreasury` — initially ALLOCATOR-only with human monitoring for over-transfer, but determine whether to make it permissionless after conservative valuation, buffer cap, and timely writeoff operations mature sufficiently. Related: [VAULT-FR-007](#vault-fr-007) / [VAULT-GOV-003](#vault-gov-003).

---

## 15. References

- [Product Overview](../Product-Overview.md) — overall architecture, responsibility separation, and no-core-modification policy (§4 / §5)
- [dToken Requirements Specification](dToken.md) — collateral beneficiary-right token that is minted/burned (conversion [DTKN-FR-003](dToken.md) / cap [DTKN-FR-004](dToken.md) / [DTKN-FR-006](dToken.md) / setTokenInfo [DTKN-FR-002](dToken.md) / permit [DTKN-FR-007](dToken.md))
- [Strategy Requirements Specification](strategies/Strategy.md) — `IStrategy` / push model / `sendToVault` / `sendProfitToVault` / `writeoffPrincipal` / `emergencyWithdraw`
- [AaveV3Strategy Requirements Specification](strategies/AaveV3Strategy.md) — Aave V3 individual Strategy implementation
- [Oracle Requirements Specification](Oracle.md) — PriceFeedProxy (`confirmSource` / comparison target for timelock)
- [Zapper Requirements Specification](Zapper.md) — permit path / referral / Sky ingress / removed Flash Loan close surface / UX residual issues
- [Parameters.md](../../../Parameters.md) — finalized values per collateral for `bufferTargetBps` / `bufferFloor` / `allocatorCooldown` / `allocateMaxMove` / `withdrawDelay` / mintCap
- [Liquity-v2-Core-Spec.md](Liquity-v2-Core-Spec.md) — 🔵 inherited explanation of core borrowing / Redemption / liquidation / Stability Pool behavior
- [Requirements Specification Standard](../../../README.md#requirements-spec-standard) — the standard this document follows
