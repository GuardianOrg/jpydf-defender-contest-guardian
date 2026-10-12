# 🟢 MorphoV2Strategy Requirements

## 0. Metadata

| Item | Value |
| --- | --- |
| Status | Draft (implementation and tests merged; requirements are being canonicalized) |
| Owner | DeltaForesight |
| Target contracts | `contracts/src/Strategies/MorphoV2Strategy.sol` (Morpho Vaults V2 Strategy; inherits `BaseStrategy`; UUPS) |
| Related documents | [Strategy](Strategy.md) (canonical source for `IStrategy` / `BaseStrategy` / push model / shared authorization / shared risks) / [ERC4626Strategy](ERC4626Strategy.md) (generic ERC-4626 adapter this Strategy deliberately does not reuse) / [CollateralVault](../CollateralVault.md) (whitelist / addStrategy / receiveFromStrategy caller side) / [Morpho-Operation-Policy](../../../operations/policies/Morpho-Operation-Policy.md) (venue gates for V2: gates, sentinel, timelocks, maxRate, penalty) / [Morpho-Day1-Vault-Freeze-Package](../../../launch/gates/Morpho-Day1-Vault-Freeze-Package.md) (per-vault evidence fields) |

> This document follows the [requirements specification document standard](../../../../README.md#requirements-spec-standard). `MorphoV2Strategy` is a dedicated adapter for Morpho Vaults V2 vaults whose `asset()` is the Strategy Underlying. It exists because Morpho Vaults V2 keeps the ERC-4626 call surface but returns 0 from `maxDeposit` / `maxMint` / `maxWithdraw` / `maxRedeem` unconditionally, so the generic `ERC4626Strategy` — which uses the max\* views as recovery limits — is not applicable (see `ERC4626Strategy.md` §5 item 7).

---

## 1. Purpose, Scope, and Non-Responsibilities

`MorphoV2Strategy` deposits the Underlying allocated by CollateralVault into **one Morpho Vaults V2 vault**, holds vault shares, converts them back into Underlying during recovery, and pushes the Underlying to the Vault. It is deployed via the `morpho-v2` Strategy kind; the Day-1 mapping is branch 1 (`dUSDC`, USDC-asset V2 vault). Branch 0 (`dwstETH`) has no Morpho V2 venue until a credible wstETH-denominated V2 vault exists.

- **This document specifies**: initialization validation including the init-frozen `maxForceDeallocatePenaltyBps` bound, the isolated-frame deposit / withdraw hooks that never consult the max\* views, `_ownShares` accounting and donation exclusion, the staged emergency recovery `emergencyWithdrawFromMorphoV2`, the Vault-only `forceDeallocate` wrapper and its total-penalty versus tracked-loss accounting, and receipt-token sweep protection.
- **This document does not specify**: which V2 vault, curator, or market set is adopted; venue-side gate / sentinel / timelock / maxRate / adapter-registry policy; Vault-side caps, weights, or `writeoffStrategyPrincipal` decisions. Those are the responsibility of [Morpho-Operation-Policy](../../../operations/policies/Morpho-Operation-Policy.md), [Morpho-Day1-Vault-Freeze-Package](../../../launch/gates/Morpho-Day1-Vault-Freeze-Package.md), and [CollateralVault](../CollateralVault.md).
- **Applicability condition**: `morphoVault.asset() == underlying` is mandatory. The adapter assumes the venue behaviors listed in §2; a vault that violates them (in-kind redemption, non-Merkl pull rewards, gates that cannot be evidenced unset) must not be registered.

---

## 2. Design Policy

- **Never rely on the max\* views**: Morpho Vaults V2 returns 0 from `maxDeposit` / `maxMint` / `maxWithdraw` / `maxRedeem` by design. This adapter clamps requests only to the value of its own tracked shares and attempts the venue call inside an isolated self-call frame; the venue itself is the authority on whether the call succeeds.
- **Deposits are synchronous but rejectable**: a V2 deposit can revert when the liquidity adapter's caps are hit or a receive gate is set. The rejection reverts the isolated frame and is re-raised as `MorphoV2DepositRejected`; `BaseStrategy.deposit` catches it and routes the exact receipt back to the Vault (Low-01 recovery), so no funds are stranded in the Strategy.
- **Liquidity shortage is not treated as loss (ADR-006)**: V2 withdrawals pay from idle then deallocate from the single liquidity adapter; liquidity-short reverts bubble up as untyped lower-level errors. If the full request fails, the adapter halves the request and retries up to eight total attempts in the same call. The first successful partial amount is returned; only an all-attempt failure becomes fail-soft `0`, with each failed venue frame rolled back. This satisfies the per-strategy conservative guard of [`ADR-006`](../../architecture/Architecture-Decision-Records.md#adr-006).
- **Only self-minted shares are normally valued**: `estimatedTotalUnderlying()` values `min(_ownShares, shareBalance)` via `convertToAssets`, so share-token donations do not inflate `realizedYield()`. Donated shares are recoverable only through the emergency path.
- **Share / asset balance deltas are authoritative**: every venue call compares `balanceOf(this)` before/after with the reported minted / burned shares, and the withdraw / redeem paths also compare the actual Underlying delta. Mismatches revert inside the isolated frame (`MorphoV2ShareBalanceMismatch` / `MorphoV2ZeroShares` / `MorphoV2AssetAmountMismatch`) so a lying or hostile venue response rolls back its own effects.
- **Losses are immediate; gains are rate-capped**: venue losses reflect immediately in `convertToAssets` and therefore in `estimatedTotalUnderlying()` / Vault `totalUnderlying()`. The V2 `maxRate` caps gains only; `maxRate = 0` is the venue deployment default and withholds yield — that is a venue monitoring knob (see Morpho-Operation-Policy), not a Strategy loss.
- **`forceDeallocate` is wrapped and bounded through Vault incident rails**: the venue function is permissionless, but the penalty (per-adapter `forceDeallocatePenalty`, protocol max 2%) burns the caller-designated `onBehalf` shares. The Strategy wrapper is `onlyVault`; the canonical entry is `CollateralVault.forceDeallocateMorphoV2`, restricted to `WRITEOFF_ROLE`. The Vault atomically pauses allocation / deposit / redeem / claim, recovers released liquidity in the same transaction, then enforces the caller's nonzero actual-receipt minimum and post-operation backing floor. The wrapper measures the actual share burn against the init-frozen `maxForceDeallocatePenaltyBps` (≤ 200 bps, no setter), lets donated (untracked) shares absorb the penalty first, and resyncs `_ownShares` to the remaining balance. It returns total `penaltyAssets` separately from tracked `valuationLossAssets`; the latter plus recovered assets reduce fallback valuation cache. There is no haircut machinery; unrecoverable residue routes to `Vault.writeoffStrategyPrincipal`.
- **Venue freeze policy — gates unset**: deploy only against V2 vaults whose receive- / send- share and asset gates are all unset. Gate installation is curator-timelocked, but an installed gate's allowlist can freeze an address instantly, so "all four gates unset" is the venue freeze criterion. A gate installed later surfaces as a recovered deposit rejection or a fail-soft withdraw, never as stranded funds.
- **Rewards are Merkl-only**: the V2 URD path is deprecated and all Morpho rewards flow through Merkl, so the inherited `BaseStrategy.claimMerklRewards` / `sweepRewardToken` suffice; no venue-specific claim surface is added.

---

## 3. Interface Specification

| Function | Visibility | Summary |
| --- | --- | --- |
| `initialize(address vault, IERC20 underlying, address owner, address upgrader, IMorphoVaultV2 morphoVault, uint256 maxForceDeallocatePenaltyBps)` | external initializer | Initializes BaseStrategy, separates Owner / Upgrader, rejects zero / non-contract vaults, validates `asset()`, freezes the penalty bound (≤ 200 bps), and max-approves the Morpho vault |
| `ownShares()` | external view | Vault shares currently attributed to this Strategy's own deposits |
| `_doDeposit(uint256 amount)` | internal | Attempts `depositIntoMorphoVault` in an isolated self-call; any venue rejection is re-raised as `MorphoV2DepositRejected` for BaseStrategy exact-receipt recovery |
| `depositIntoMorphoVault(uint256 amount)` | external (self-only) | Executes `morphoVault.deposit`, compares reported minted shares with the share balance delta, rejects zero-share mints, and adds actual minted shares to `_ownShares` |
| `_doWithdraw(uint256 amount)` | internal | Clamps to `min(amount, convertToAssets(min(_ownShares, shareBalance)))`; on failure, halves the request for up to eight total attempts and returns the first successful partial amount, or fail-soft `0` if all attempts fail (ADR-006) |
| `withdrawFromMorphoVault(uint256 assets)` | external (self-only) | Executes `morphoVault.withdraw`, compares reported burned shares, share balance delta, and actual Underlying delta, and subtracts actual burned shares from `_ownShares` |
| `_estimatedTotalUnderlying()` | internal view | Returns `convertToAssets(min(_ownShares, morphoVault.balanceOf(this)))` |
| `_isSweepProtectedToken(address token)` | internal view | Protects the Morpho vault share token from sweeping in addition to the Underlying |
| `emergencyWithdrawFromMorphoV2(uint256 maxShares)` | external onlyOwner nonReentrantStrategy | Redeems up to `min(shareBalance, maxShares)` (donated shares included), verifies redeem share / asset deltas, pushes idle Underlying to the Vault in the same tx, and accounts the Vault receipt as returned principal |
| `forceDeallocate(address adapter, bytes data, uint256 assets)` | external onlyVault nonReentrantStrategy | Called only by `CollateralVault.forceDeallocateMorphoV2`; measures the actual penalty burn, reverts above `assets * maxForceDeallocatePenaltyBps / 10000 + 1`, charges donated shares first, resyncs `_ownShares = min(_ownShares, shareBalanceAfter)`, and returns `(penaltyShares, penaltyAssets, valuationLossAssets, withdrawnAssets)` |
| `claimMerklRewards(...)` | external onlyOwner (inherited from BaseStrategy) | Rejects the Morpho share token / protected position tokens before claim; settles Underlying rewards to the Vault buffer and ordinary reward tokens to Treasury |

`OwnSharesUpdated(uint256 newOwnShares)` is emitted whenever `_ownShares` changes (deposit, withdrawal, emergency recovery, penalty). `ForceDeallocated(adapter, assets, penaltyShares, penaltyAssets)` records each wrapped force deallocation.

---

## 4. Functional Requirements

| ID | Requirement | Verification |
| --- | --- | --- |
| MV2-FR-001 | `initialize` must reject a zero-address or non-contract Morpho vault, reject `asset() != underlying` with `InvalidMorphoVaultAsset`, and reject `maxForceDeallocatePenaltyBps > 200` with `ForceDeallocatePenaltyAboveMax`. The bound is frozen at initialization (no setter) | unit |
| MV2-FR-002 | Deposits execute in an isolated self-call frame with exact share-delta checks; a venue rejection (liquidity-adapter cap, receive gate, zero-share mint, reported/actual share mismatch) rolls back the frame, re-raises `MorphoV2DepositRejected`, and `BaseStrategy.deposit` recovers the exact receipt to the Vault and skips this Strategy (Low-01 recovery). Allocation and recovery must work despite all max\* views returning 0 | unit |
| MV2-FR-003 | `_doWithdraw` clamps the request to the value of `min(_ownShares, shareBalance)` and executes in an isolated frame. An untyped liquidity-short or send-gate revert rolls back that frame, halves the requested amount, and retries for up to eight total attempts. It returns the first successful partial amount, or fail-soft `0` only if all attempts fail (ADR-006). Successful withdrawals subtract actual burned shares from `_ownShares`, and share-price yield can be harvested without reducing principal | unit |
| MV2-FR-004 | `emergencyWithdrawFromMorphoV2(maxShares)` redeems up to `min(shareBalance, maxShares)` — donated shares included, as this is their only recovery path — verifies redeem share / asset deltas, pushes all idle Underlying to the Vault in the same transaction, and accounts the Vault receipt as returned principal. `maxShares` staging lets the owner size each step to the venue's redeemable portion; residual shortfall routes to `Vault.writeoffStrategyPrincipal` | unit |
| MV2-FR-005 | The `onlyVault` `forceDeallocate` wrapper calls the venue-permissionless function with the Strategy as `onBehalf`. Its canonical entry is the `WRITEOFF_ROLE`-only `CollateralVault.forceDeallocateMorphoV2`, which atomically pauses allocation / deposit / redeem / claim and enforces a post-operation backing floor. The wrapper measures the actual share burn, reverts with `ForceDeallocatePenaltyExceeded` above the init-frozen bound (+1 wei rounding allowance), charges donated shares first, and separates total penalty from tracked valuation loss. Only `valuationLossAssets` is a confirmed backing loss. The same call withdraws up to `assets` of tracked value directly to the Vault; actual receipt reduces principal, and the Vault enforces a nonzero minimum receipt or rolls the penalty and recovery back together | unit |

---

## 5. Security Requirements

| ID | Requirement | Verification |
| --- | --- | --- |
| MV2-SEC-001 | Share token donation must not increase `estimatedTotalUnderlying()` / `realizedYield()`; only shares minted through this Strategy's own deposits are valued | unit |
| MV2-SEC-002 | `depositIntoMorphoVault` / `withdrawFromMorphoVault` are self-only (`Unauthorized` otherwise), and venue reentry into Strategy entry points during a venue deposit / withdraw is blocked by `nonReentrantStrategy` | unit |
| MV2-SEC-003 | Every venue call compares the share balance before/after with the venue-reported minted / burned shares, and withdraw / emergency redeem also compare the actual Underlying delta; a hostile venue response (lying return value, zero-share mint or burn, short asset delivery) reverts inside its isolated frame — deposit mismatches become a recovered skip, withdraw mismatches fail-soft to `0`, and emergency redeem mismatches revert | unit |
| MV2-SEC-004 | The `forceDeallocate` penalty bound is fail-closed: the wrapper allows only `assets * maxForceDeallocatePenaltyBps / 10000 + 1` wei. Because the venue rounds the penalty up while `convertToAssets` rounds down, a venue sitting exactly on the bound can exceed it by up to one share's asset value and revert; the operator remedy is to retry with a smaller `assets` so the rounding contribution shrinks — never to accept more than the frozen bound | unit |
| MV2-SEC-005 | Deployment is restricted to V2 vaults whose four gates (receive-shares / send-shares / receive-assets / send-assets) are all unset (venue freeze criterion; see Morpho-Operation-Policy). A gate installed after deployment must surface as a recovered deposit rejection or a fail-soft `0` withdraw — never as stranded funds | unit + venue freeze evidence |
| MV2-SEC-006 | The Morpho vault share token is a position token and cannot be sent to Treasury with `sweepRewardToken` | unit |
| MV2-SEC-007 | Venue asset loss must be reflected downward immediately in `estimatedTotalUnderlying()` and Vault `totalUnderlying()` via `convertToAssets`. `maxRate` caps gains only; a `maxRate = 0` venue withholds yield and is a monitoring item, not a Strategy loss | unit |

---

## 6. Invariants

| ID | Requirement | Verification |
| --- | --- | --- |
| MV2-INV-001 | The valuation and withdraw basis is always `min(_ownShares, morphoVault.balanceOf(this))`; `_ownShares` changes only through this Strategy's own deposit / withdraw / emergency / penalty paths, floors at 0 (never underflows), and every change emits `OwnSharesUpdated` | unit |
| MV2-INV-002 | Only Underlying ever arrives from venue withdraw / redeem / force-deallocation follow-up (no in-kind redemption); the Strategy holds no venue token other than the vault share, and rewards are Merkl-only through the inherited BaseStrategy claim path | unit / code review |
| MV2-INV-003 | The derived contract reserves exactly 50 storage slots (3 state variables + `uint256[47]` gap) so future upgrades keep the BaseStrategy layout budget | code review |

---

## 7. Venue Freeze Conditions (Morpho Vaults V2)

Before registering a V2 vault through `MorphoV2Strategy`, the activation package must evidence at least the following, per [Morpho-Operation-Policy](../../../operations/policies/Morpho-Operation-Policy.md) and the [Morpho-Day1-Vault-Freeze-Package](../../../launch/gates/Morpho-Day1-Vault-Freeze-Package.md):

1. `asset()` exactly matches the branch Underlying.
2. All four gates (receive-shares / send-shares / receive-assets / send-assets) are unset.
3. Sentinel is set and its holder is explained.
4. Per-selector timelock values are read back per vault — they **default to zero**, so nonzero values are a freeze checklist item, not a protocol guarantee.
5. `maxRate` is nonzero (or the yield-withholding default is explicitly accepted) and monitored.
6. Every adapter's `forceDeallocatePenalty` is ≤ the Strategy's init-frozen `maxForceDeallocatePenaltyBps`.
7. The liquidity adapter's deallocatable liquidity is read back, and idle-balance + `forceDeallocate` dry-runs replace the max\*-based withdrawability evidence used for ERC-4626 vaults.

---

## 8. Verification

- `MorphoV2StrategyTest` (unit, mock V2 vault with caps / gates / lying-response and penalty modes)
  - initialize rejects asset mismatch, non-contract vault, and penalty bound above the protocol max
  - allocate and sendToVault work despite hard-zero max\* views
  - share-price yield harvest preserves principal
  - deposit rejection (liquidity-adapter cap / receive gate / zero-share mint / return-value mismatch) recovers the exact receipt and skips
  - withdrawal recovers a bounded partial amount after a full-size liquidity failure, and fail-softs to 0 when all attempts fail because of liquidity shortage, send gate, return-value mismatch, or zero-share burn
  - share donation does not inflate realized yield; share token sweep rejected
  - asset loss reflected immediately in Strategy estimate and Vault total
  - emergency full drain, partial `maxShares` recovery with returned-principal accounting, donated-share recovery after full unwind, and redeem asset-delta mismatch revert
  - Vault-routed forceDeallocate atomically pauses incident surfaces, enforces penalty/backing bounds, charges donated shares before tracked shares, separates total penalty from valuation loss, and rejects direct Strategy/non-WRITEOFF callers
  - atomic recovery flow: liquidity short → forceDeallocate and withdrawal in one transaction, with insufficient receipt rolling back all effects
  - self-only isolated frames and reentrancy blocking during venue deposit / withdraw
- `MorphoV2BackingRatioTest`: `backingRatio()` stays within bounded gas at the 32-Strategy maximum
- `DeployLiquity2StrategySelectorTest`: `morpho-v2` kind deploy binding, penalty-bound env validation, and Day-1 branch policy (branch 1 requires `aave` + `morpho-v2`; `morpho-v2` outside the Day-1 branch is rejected)
