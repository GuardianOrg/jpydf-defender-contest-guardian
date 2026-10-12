# 🟢 ERC4626Strategy Requirements

## 0. Metadata

| Item | Value |
| --- | --- |
| Status | Draft (implementation exists; requirements are being canonicalized) |
| Owner | DeltaForesight |
| Target contracts | `contracts/src/Strategies/ERC4626Strategy.sol` (generic ERC-4626 Strategy; inherits `BaseStrategy`; UUPS) |
| Related documents | [Strategy](Strategy.md) (canonical source for `IStrategy` / `BaseStrategy` / push model / shared authorization / shared risks) / [CollateralVault](../CollateralVault.md) (whitelist / addStrategy / receiveFromStrategy caller side) / [Product-Overview](../../Product-Overview.md) / [Parameters](../../../../Parameters.md) / [Morpho-Operation-Policy](../../../operations/policies/Morpho-Operation-Policy.md) |

> This document follows the [requirements specification document standard](../../../../README.md#requirements-spec-standard). `ERC4626Strategy` is a generic adapter for ERC-4626 vaults whose `asset()` matches the Strategy Underlying, such as Morpho Vault / EulerEarn / sUSDS.

---

## 1. Purpose, Scope, and Non-Responsibilities

`ERC4626Strategy` is a Strategy that deposits the Underlying allocated by CollateralVault into **one ERC-4626 vault**, holds vault shares, converts them back into Underlying during recovery, and pushes the Underlying to the Vault. The initial candidate targets are ERC-4626-style venues such as Morpho Vault and EulerEarn.

- **This document specifies**: ERC-4626-specific additional storage (`erc4626Vault` / `_ownShares`), `asset()` validation and Owner / Upgrader arguments in `initialize`, mapping of the three hooks to the ERC-4626 interface, the protocol-specific emergency recovery function `emergencyWithdrawFromERC4626`, protections against share token donation, zero-share minting, and receipt token sweeping, and the accounting boundary for external reward tokens / Merkl claims on Morpho / Euler style venues.
- **This document does not specify**: Vault-side allocation decisions, cap/weight, `writeoffStrategyPrincipal`, Treasury transfer, individual Morpho/Euler market selection, curator/tranche risk, or oracle/LTV design. Those are the responsibility of [CollateralVault](../CollateralVault.md), [Parameters](../../../../Parameters.md), and protocol-specific operation runbooks.
- **Applicability condition**: `IERC4626.asset() == underlying` is mandatory. This Strategy is not used for asset-transforming strategies such as converting USDC into USDS/sUSDS. Such routes must be explicitly designed as a Zapper or a separate Strategy.

---

## 2. Design Policy

- **1 Strategy = 1 Underlying = 1 ERC-4626 vault**: `erc4626Vault` is fixed in `initialize`; no setter is provided. To change the investment venue, create a new Strategy and update the Vault whitelist / addStrategy registration.
- **Only self-minted shares are normally valued**: ERC-4626 share tokens are ERC-20 tokens, so a third party can transfer them directly to the Strategy. If `balanceOf(this)` were valued as-is, donations would inflate `realizedYield()`. The Strategy therefore tracks `_ownShares`, which are shares minted by its own `deposit`.
- **Share / asset balance deltas are authoritative**: ERC-4626 defines return values for `deposit` / `withdraw` / `redeem`, but the adapter does not trust return values alone. It compares `balanceOf(this)` before/after with the reported minted/burned shares and fail-fasts on mismatch. Normal `withdraw` also reverts with `ERC4626ZeroShares` when the share burn is zero, and reverts with `ERC4626AssetAmountMismatch` when the requested asset amount does not match the actual Underlying balance delta. `emergencyWithdrawFromERC4626()` also compares the asset amount reported by `redeem` with the actual Underlying balance delta. Like the Aave adapter uses aToken / scaled-balance deltas, this Strategy uses position-token and asset-token balance deltas as the accounting basis.
- **Share donations are excluded from normal accounting but recovered in emergencies**: `estimatedTotalUnderlying()` values only `min(_ownShares, shareBalance)`. In contrast, `emergencyWithdrawFromERC4626()` redeems as many of all held shares as possible and immediately pushes recovered Underlying to the Vault. After an emergency redemption sized from raw shares, it sets `_ownShares = min(ownSharesBefore, shareBalanceAfter)`, consuming donated shares first while preserving the valuation of remaining owned shares.
- **Zero-share deposits are forbidden**: If an ERC-4626 vault `deposit()` returns 0 shares, principal would increase while AUM would not, so the inner frame reverts with `ERC4626ZeroShares`. BaseStrategy skips only this Strategy after exact Underlying recovery and reverts the whole allocation only when recovery mismatches.
- **Emergency recovery uses atomic push**: A transaction must not end with Underlying redeemed from the ERC-4626 vault and left idle in the Strategy. Recovery pushes through `receiveFromStrategy` into the Vault buffer, reduces the Vault-side valuation cache at the same time, and accounts the Vault actual receipt as returned principal.
- **External rewards are not mixed into backing accounting by accident**: Morpho / Euler incentives and Merkl rewards are sent to Treasury only when they are neither Underlying nor the ERC-4626 share token. Underlying rewards are pushed to the Vault buffer by `claimMerklRewards`, while the share token remains protected and is rejected before the distributor call.
- **Liquidity shortage is not treated as loss (the per-strategy guard of ADR-006)**: `_doWithdraw` withdraws conservatively with `min(amount, convertToAssets(_ownShares), maxWithdraw(this))` (§3), and even if `maxWithdraw` / `maxRedeem` return a liquidity limit it clamps to the currently withdrawable amount rather than reverting (§5-4). This satisfies, for ERC4626, the per-strategy conservative guard of [`ADR-006`](../../architecture/Architecture-Decision-Records.md#adr-006) that "a temporary liquidity shortage is not treated as loss." In contrast, a share-price decline (confirmed loss such as bad debt) is reflected downward immediately into `estimatedTotalUnderlying()` / Vault `totalUnderlying()` via `convertToAssets` (`E4626-SEC-005`).

---

## 3. Interface Specification

| Function | Visibility | Summary |
| --- | --- | --- |
| `initialize(address vault, IERC20 underlying, address owner, address upgrader, IERC4626 erc4626Vault)` | external initializer | Initializes BaseStrategy, separates Owner / Upgrader, validates `asset()`, and max-approves the ERC-4626 vault |
| `_doDeposit(uint256 amount)` | internal | Executes `erc4626Vault.deposit(amount, this)`, compares reported minted shares with the share balance delta, and adds actual minted shares to `_ownShares`; 0 shares / mismatch revert |
| `_doWithdraw(uint256 amount)` | internal | Withdraws up to `min(amount, convertToAssets(_ownShares), maxWithdraw(this))`, compares reported burned shares, share balance delta, and actual Underlying delta, and subtracts actual burned shares from `_ownShares` |
| `_estimatedTotalUnderlying()` | internal view | Returns `convertToAssets(min(_ownShares, erc4626Vault.balanceOf(this)))` |
| `emergencyWithdrawFromERC4626()` | external onlyOwner | Redeems raw shares up to `maxRedeem(this)`, clamps `_ownShares` to the remaining raw balance to preserve donation-first accounting, pushes idle Underlying through `receiveFromStrategy`, and accounts returned principal |
| `_isSweepProtectedToken(address token)` | internal view | Protects the ERC-4626 share token from sweeping in addition to the Underlying |
| `claimMerklRewards(...)` | external onlyOwner (inherited from BaseStrategy) | Rejects ERC-4626 share token / protected position tokens before claim; settles Underlying rewards to the Vault buffer and ordinary reward tokens to Treasury |

`OwnSharesUpdated(uint256 newOwnShares)` is emitted whenever `_ownShares`
changes after deposit, withdrawal, or emergency recovery.

---

## 4. Security Requirements

| ID | Requirement | Verification |
| --- | --- | --- |
| E4626-SEC-001 | `initialize` must verify `erc4626Vault.asset() == underlying` and reject mismatches with `InvalidERC4626Asset` | unit |
| E4626-SEC-002 | Share token donation must not increase `estimatedTotalUnderlying()` / `realizedYield()` | unit |
| E4626-SEC-003 | The ERC-4626 share token is a position token and cannot be sent to Treasury with `sweepRewardToken` | unit |
| E4626-SEC-004 | If `deposit()` returns 0 shares, the call must revert with `ERC4626ZeroShares` | unit |
| E4626-SEC-005 | ERC-4626-side asset loss must be reflected downward in `estimatedTotalUnderlying()` and Vault `totalUnderlying()` | unit |
| E4626-SEC-006 | Emergency recovery must push redeemed Underlying to the Vault in the same tx, account Vault actual receipt as returned principal, and avoid a temporary undervaluation window in `backingRatio()` | unit |
| E4626-SEC-007 | `deposit` / `withdraw` / `redeem` must compare share balance before/after with ERC-4626 return values and revert accounting mismatches with `ERC4626ShareBalanceMismatch`. Normal `withdraw` / `emergencyWithdrawFromERC4626` also compare the requested asset amount or `redeem`-reported asset amount with the actual Underlying delta and revert mismatches with `ERC4626AssetAmountMismatch`. Normal `withdraw` reverts with `ERC4626ZeroShares` if assets arrive but the share burn is zero | unit |
| E4626-SEC-008 | Merkl / external reward claims must allow only non-Underlying, non-ERC-4626-share reward tokens for Treasury sweep; Underlying rewards are pushed to the Vault buffer and share tokens are rejected before the distributor call | unit |
| E4626-SEC-009 | After a partial emergency redemption of raw shares that include donations, `_ownShares` must equal `min(ownSharesBefore, shareBalanceAfter)`, so donated shares are consumed before owned shares. Combining a share-price loss, repair donation, and partial recovery must not create an additional tracker-only loss in the remaining owned position | unit |

---

## 5. Applicability Conditions for Morpho / Euler

Before applying `ERC4626Strategy` to Morpho Vault / EulerEarn, the following minimum checks are required:

1. `asset()` exactly matches the Vault Underlying.
2. Even if the share token is transferable, normal valuation is limited to `_ownShares`.
3. `convertToAssets` reflects bad debt / share price loss downward.
4. Even if `maxWithdraw` / `maxRedeem` returns a liquidity limit, `sendToVault` is limited to the currently withdrawable amount instead of reverting.
5. Curator / allocator / market selection / oracle / liquidation risk is controlled through the adopted vault's governance, cap, weight, and runbook, not through Strategy code.
6. External rewards such as Merkl are limited to non-Underlying, non-share reward tokens for Treasury sweep. ERC-4626 share token / protected position-token rewards are rejected before the distributor call; Underlying rewards are pushed to the Vault buffer.
7. A vault such as Morpho Vault V2 whose `maxWithdraw` / `maxRedeem` are zero by design must not be
   adopted through this adapter, because the recovery limit would always be zero. Morpho Vaults V2
   is adopted through the dedicated [`MorphoV2Strategy`](MorphoV2Strategy.md) (kind `morpho-v2`),
   which does not rely on the max\* views; its activation gates live in
   [Morpho-Operation-Policy](../../../operations/policies/Morpho-Operation-Policy.md).
8. If rewards remain in an external distributor and require a pull claim, as with Euler Reward Streams,
   the current `ERC4626Strategy` cannot recover them through `claimMerklRewards` or `sweepRewardToken`.
   Registration and allocation must remain disabled until activation evidence proves that reward path is
   not enabled for the target vault, or a venue-specific claim implementation, settlement unit/fork tests,
   and additional audit are complete. Unclaimed rewards are not included in `estimatedTotalUnderlying()`
   or backing.

---

## 6. Verification

- `ERC4626StrategyTest`
  - asset mismatch reject
  - share token sweep reject / reward sweep allow
  - share donation does not inflate AUM/yield
  - zero-share deposit reject
  - ERC-4626 return value / share balance delta mismatch reject
  - ERC-4626 withdraw zero-share burn / asset delta mismatch reject
  - ERC-4626 emergency redeem reported assets / actual Underlying delta mismatch reject
  - asset loss reflected in Strategy and Vault totals
  - withdrawal respects ERC-4626 maxWithdraw
  - share-price yield harvest preserves principal
  - emergency redeem + atomic Vault push + returned principal accounting
  - partial emergency recovery followed by residual writeoff
  - asset loss + share donation + partial emergency recovery preserves remaining owned-share valuation
  - emergency path does not transiently discount `backingRatio()`
  - Merkl reward claim sweeps ordinary reward token to Treasury without changing Strategy / Vault accounting
  - Merkl Underlying reward claim pushes actual received amount to Vault buffer
  - Merkl claim rejects ERC-4626 share token before distributor call
