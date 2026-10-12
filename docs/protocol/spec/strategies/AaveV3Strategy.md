# 🟢 AaveV3Strategy Requirements

## 0. Metadata

| Item | Value |
| --- | --- |
| Status | Draft (implementation exists; requirements are being canonicalized) |
| Owner | DeltaForesight |
| Target contract | `contracts/src/Strategies/AaveV3Strategy.sol` (Aave V3 concrete Strategy; inherits `BaseStrategy`; UUPS) |
| Related documents | [Strategy](Strategy.md) (canonical source for `IStrategy` / `BaseStrategy` / push model / shared authorization / shared risks) / [CollateralVault](../CollateralVault.md) (whitelist / addStrategy / receiveFromStrategy caller side) / [Product-Overview](../../Product-Overview.md) (architecture and responsibility split) / [Parameters](../../../../Parameters.md) (collateral allocation / cap / weightBps values) |

> This document follows the [requirements specification document standard](../../../../README.md#requirements-spec-standard). Requirements, invariants, and security requirements have persistent IDs (`AAVE-...`), and cross-references use those IDs.
> **Scope of this document**: this document covers only **Aave V3-specific requirements** for `AaveV3Strategy`. Strategy-wide items (`IStrategy` / `BaseStrategy` conventions, Vault coupling, shared authorization, shared risks, and shared events) use the parent page [Strategy requirements](Strategy.md) as the canonical source and are referenced here by name.

---

## 1. Purpose, Scope, and Non-Responsibilities

`AaveV3Strategy` is a concrete Strategy that **supplies Underlying allocated by CollateralVault to Aave V3 to earn yield** (a child implementation inheriting `BaseStrategy` from [Strategy requirements](Strategy.md)). One instance maps 1:1 to one Underlying and one Aave V3 reserve, and operates with the push model (the Strategy withdraws and pushes to the Vault).

- **This document specifies**: target Underlying and Aave V3 addresses (Pool / aToken); Aave-specific additional storage (`aavePool` / `aToken` / `_ownScaledBalance`); `initialize` (fixed 6 arguments and max approval to Pool); the three hooks mapped to Aave interfaces (`_doDeposit` = `aavePool.supply`, `_doWithdraw` = `aavePool.withdraw`, `_estimatedTotalUnderlying` = scaled balance × normalized income); Aave-specific emergency recovery function `emergencyWithdrawFromAave`; Aave `RewardsController` claim function `claimAaveRewards`; reward token handling policy (received rewards use `BaseStrategy.sweepRewardToken`, Merkl rewards use `BaseStrategy.claimMerklRewards`, and Aave rewards use `claimAaveRewards`, but aToken is a protected token and cannot be swept or settled as a reward); and Aave-specific risks (frozen, paused, supply cap, 100% utilization, aToken valuation, third-party donation resistance).
- **This document does not specify (non-responsibilities / other documents)**:
  - Shared `IStrategy` interface; bodies provided by `BaseStrategy` for `deposit` / `sendToVault` / `sendProfitToVault` / `writeoffPrincipal` / `principal` / `realizedYield` / `estimatedTotalUnderlying` / `underlying`; shared `emergencyWithdraw` (destination fixed to Vault); push-model accounting and `principal` management → [Strategy requirements](Strategy.md) (`BaseStrategy`)
  - Coupling with Vault (whitelist / weights / cap / `addStrategy` / `receiveFromStrategy` / failure resistance) → [CollateralVault requirements](../CollateralVault.md)
  - Finalized dToken / Underlying allocation, cap, and weightBps values for each collateral branch → [Parameters](../../../../Parameters.md)
  - 🔵 Liquity core collateral, liquidation, and Redemption behavior → [Liquity-v2-Core-Spec](../Liquity-v2-Core-Spec.md)
- **Responsibility boundary (intentionally unaware)**: `AaveV3Strategy` does not assume "whose collateral this allocation supports" or "how the Vault buffer / weights are determined." It is responsible only for translating external protocol interfaces: how to deposit received Underlying into the single external protocol Aave V3, how to recover it, and what value it has.

---

## 2. Background and Design Policy

`AaveV3Strategy` is the first concrete implementation for Aave V3 that follows the push model and "1 Strategy = 1 Underlying = 1 external yield venue" principle in [Strategy requirements](Strategy.md).

- **Rationale for choosing Aave V3**:
  - **Broad Underlying coverage**: `AaveV3Strategy` can apply to assets with Ethereum mainnet Aave V3 reserves, including USDC / USDT / WETH / WBTC. Day-1 adoption still follows the branch strategy policy in `Parameters.md` and the deploy runbook.
  - **Immediate withdrawal**: Aave V3 `withdraw` responds immediately (no unbonding). `_doWithdraw` withdraws to the Strategy itself. Then `BaseStrategy.sendToVault` pushes principal returns through `receiveFromStrategy`, while `sendProfitToVault` transfers yield-only funds directly into the Vault buffer (push model in [Strategy requirements](Strategy.md)).
  - **Deep liquidity**: major collaterals usually remain within reasonable utilization ranges, reducing the probability of `withdraw` revert due to insufficient liquidity.
  - **No oracle reference required**: Underlying value including interest can be computed from aToken scaled balance × `getReserveNormalizedIncome` (using self-managed scaled balance, not `balanceOf`, to exclude third-party donations; [AAVE-FR-005](#aave-fr-005-_estimatedtotalunderlying-valuation-calculation) / [AAVE-SEC-002](#aave-sec-002-exclude-aum-inflation-by-third-party-donation)).
  - **Sepolia and mainnet map 1:1**: test deployment is straightforward ([AAVE-GOV-002](#aave-gov-002-testnet-first)).
- **Do not let the Strategy side move the investment venue**: `aavePool` / `aToken` / Underlying / Pool approval are all fixed in `initialize`; there is no `setAavePool` / `setAToken` or similar. If the venue must change later, operations should **recreate the entire Strategy and replace the Vault whitelist & registration**, eliminating storage migration risk and the attack surface where an operations role can move the venue ([AAVE-SEC-001](#aave-sec-001-investment-addresses-fixed-at-initialize) / [AAVE-GOV-001](#aave-gov-001-change-investment-venue-by-recreating-strategy)).
- **Do not include third-party donations in AUM**: Aave V3 `supply(onBehalfOf=anyone)` is permissionless, so anyone can increase this Strategy's aToken balance. If `aToken.balanceOf` were used directly as AUM, a third-party donation could inflate `realizedYield` and route arbitrary amounts to Treasury through yield transfer. This Strategy therefore bases AUM valuation on `_ownScaledBalance`, which changes only through its own supply / withdraw ([AAVE-SEC-002](#aave-sec-002-exclude-aum-inflation-by-third-party-donation)).
- **Emergency recovery is Aave→Vault atomic direct-push with fixed destination**: `emergencyWithdrawFromAave` withdraws the currently liquid part of the Aave position, then atomically pushes all idle Underlying to the Vault (`receiveFromStrategy`) in the **same tx** and accounts the Vault receipt as returned principal. If withdrawn Underlying remains idle in the Strategy, it is counted neither in valuation (`_estimatedTotalUnderlying` excludes idle) nor in the Vault buffer, creating a suspended state that can undervalue `backingRatio` and trigger improper liquidation of Troves in that branch. The intermediate state is structurally removed. The destination is fixed to the Vault, so even a compromised Owner key cannot move funds to an arbitrary address ([AAVE-FR-006](#aave-fr-006-emergencywithdrawfromaave-emergency-liquid-recovery) / [AAVE-SEC-003](#aave-sec-003-fixed-destination-and-authorization-separation-for-emergency-recovery)). `BaseStrategy.emergencyWithdraw` (idle→Vault) remains for donations and residual recovery.
- **Non-Underlying rewards are not mixed into backing**: reward tokens from Aave incentives / Merkl, etc. are separate assets from aToken interest and are not included in `_estimatedTotalUnderlying()` / `realizedYield()` / dToken backing. Reward tokens already received by the Strategy are sent to the Vault's current Treasury through shared `BaseStrategy.sweepRewardToken`, and standard Merkl distributor rewards can be claimed and swept through shared `BaseStrategy.claimMerklRewards`. Aave `RewardsController` rewards can be claimed by Owner through `claimAaveRewards`; Underlying rewards are sent to the Vault buffer as yield, while non-Underlying rewards are swept to Treasury. aToken is an Aave position / accounting token, not a reward, so it is rejected before sweep / Merkl claim / Aave claim settlement. Reward swaps and non-Underlying reward backing replenishment are not included in the current Strategy implementation ([AAVE-FR-007](#aave-fr-007-claimaaverewards-aave-rewardscontroller-reward-claim) / [AAVE-ERR-005](#aave-err-005-missed-reward-tokens) / [AAVE-TBD-005](#aave-tbd-005)).

> The push model and overall `IStrategy` / `BaseStrategy` policy are canonically defined in [Strategy requirements](Strategy.md). The overall no-core-modification policy is canonically defined in [Product-Overview](../../Product-Overview.md) §5.

---

## 3. Terms, External Dependencies, and Assumptions

**Terms**

| Term | Meaning |
| --- | --- |
| Underlying | Real collateral asset managed by this Strategy (one of USDC / USDT / WETH / WBTC) |
| vault | Corresponding CollateralVault that registers this Strategy (`BaseStrategy` fixes it in `initialize`) |
| Owner | Emergency operator for this Strategy (Guardian multisig; immediate multisig. Finalized on 2026-06-12) |
| upgrader | Dedicated authority for UUPS upgrade authorization (separated from Owner; holder = shared TimelockController; 24h. [Strategy requirements](Strategy.md) STGY-FR-009) |
| ALLOCATOR | Vault `ALLOCATOR_ROLE`; operations role that triggers `sendToVault` / `sendProfitToVault` ([Strategy requirements](Strategy.md)) |
| aToken | Aave V3 interest-bearing token for the relevant Underlying (uses `scaledBalanceOf`) |
| scaled balance | RAY-precision normalized aToken balance. Converted back to actual balance by `× getReserveNormalizedIncome / RAY` |
| `_ownScaledBalance` | Scaled balance changed by this Strategy's own supply / withdraw. Excludes third-party donations |
| normalized income | `getReserveNormalizedIncome` (RAY = 1e27). Coefficient to convert scaled balance into Underlying with interest |
| donation | A third party increasing this Strategy's aToken by calling `supply(onBehalfOf=this)` |

**External dependencies (trusted externals)**

- **Aave V3 Pool (`IAaveV3Pool`)**: call target for `supply` / `withdraw` / `getReserveNormalizedIncome`. The Strategy trusts that the Pool is not compromised and that reserve accounting (scaled balance / normalized income) is sound. If the Pool is compromised, temporary Strategy balances and aToken positions may be affected ([AAVE-ERR-001](#aave-err-001-aave-reserve-configuration-change-frozen--paused--supply-cap)).
- **Aave V3 aToken (`IAToken`)**: read target for `scaledBalanceOf(this)` / `balanceOf(this)` / `UNDERLYING_ASSET_ADDRESS()`. `initialize` verifies that the aToken correctly corresponds to the Underlying (misconfiguration is a critical bug; [AAVE-SEC-004](#aave-sec-004-prevent-aave-pool--atoken-address-misconfiguration)).
- **Aave V3 RewardsController (`IAaveRewardsController`)**: call target for `claimRewards(assets, amount, to, reward)`. `claimAaveRewards` fixes `assets` to this Strategy's single `aToken`, so the function cannot be used as a generic claim adapter for unrelated Aave positions ([AAVE-FR-007](#aave-fr-007-claimaaverewards-aave-rewardscontroller-reward-claim)).
- **`BaseStrategy` (parent [Strategy requirements](Strategy.md))**: inherited and trusted for the bodies of `deposit` / `sendToVault` / `sendProfitToVault` / `writeoffPrincipal` / `emergencyWithdraw` / `principal` / `realizedYield` / `estimatedTotalUnderlying` / `underlying`, and push-model accounting.

**Assumptions**

- On Aave V3 Ethereum mainnet, the **Pool address is shared across all reserves**, while **aToken differs per reserve**. Day-1 freezes the adopted WETH / USDC venue values in the [Mainnet Deploy Env Freeze Runbook](../../../launch/gates/Mainnet-Deploy-Env-Freeze-Runbook.md). Other reserves are not registered until the exact Underlying activation package is approved. Final values are checked against [Aave addresses](https://aave.com/docs/resources/addresses) ([AAVE-TBD-007](#aave-tbd-007)).
- Aave V3 `supply(asset, amount, onBehalfOf, referralCode)` allows arbitrary `onBehalfOf` and is permissionless.
- Aave V3 `withdraw` **reverts without clamping** when liquidity is insufficient (100% utilization, etc.) or the requested amount exceeds balance.
- Aave V3 provides a Sepolia test environment with the same interface and 1:1 address mapping to mainnet.

---

## 4. Actors, Roles, and Trust Boundaries

Shared authorization design (operation matrix for Owner / upgrader / ALLOCATOR / permissionless and key-compromise damage boundaries) uses [Strategy requirements](Strategy.md) as the canonical source. Only Aave V3-specific operations are shown below.

| Actor | Aave-specific operations | Trust boundary |
| --- | --- | --- |
| **Owner (Guardian multisig)** | `initialize` (fix investment venue; once only) / `emergencyWithdrawFromAave` (Aave liquid reserve → Vault atomic direct-push and returned-principal accounting) / `claimAaveRewards` (Aave RewardsController reward claim and settlement) | Emergency recovery and protocol-specific reward claim authority. Must be multisig. Emergency destination is fixed to Vault; no arbitrary destination ([AAVE-SEC-003](#aave-sec-003-fixed-destination-and-authorization-separation-for-emergency-recovery)). Reward settlement is fixed to Vault buffer for Underlying rewards and the Vault's current Treasury for non-Underlying rewards ([AAVE-FR-007](#aave-fr-007-claimaaverewards-aave-rewardscontroller-reward-claim)). UUPS upgrade authorization is handled by `upgrader` separated from Owner (= shared TimelockController; 24h, [Strategy requirements](Strategy.md) STGY-FR-009) |
| **ALLOCATOR (Vault role)** | `sendToVault` / `sendProfitToVault` (internally triggers `_doWithdraw` = `aavePool.withdraw`) | Funds are only pushed to Vault; arbitrary destination is impossible. Deposit into Aave (`deposit` → `_doDeposit`) is limited to the Vault path through `onlyVault` |
| **Anyone (permissionless)** | views such as `estimatedTotalUnderlying` / Aave-side donation through `supply(onBehalfOf=this)` | Views require no trust. Donations are not mixed into AUM ([AAVE-SEC-002](#aave-sec-002-exclude-aum-inflation-by-third-party-donation)) |

- **Authorization separation**: `emergencyWithdrawFromAave` is `onlyOwner`; ALLOCATOR (operations bot key) cannot trigger it. Conversely, Owner is not the day-to-day actor for normal recovery (`sendToVault`, etc.). UUPS upgrade is separated to `upgrader` (= shared TimelockController), so Owner (Guardian multisig) cannot replace implementation.

---

## 5. Interface Specification

Functions provided by `BaseStrategy` (`IStrategy`) (`deposit` / `sendToVault` / `sendProfitToVault` / `writeoffPrincipal` / `principal` / `realizedYield` / `estimatedTotalUnderlying` / `underlying` / `emergencyWithdraw` / `sweepRewardToken` / UUPS) use [Strategy requirements](Strategy.md) as the canonical source. This document summarizes only Aave-specific functions and hooks (non-normative).

| Function | Visibility | Summary | Normative requirement |
| --- | --- | --- | --- |
| `initialize(address _vault, IERC20 _underlying, address _owner, address _upgrader, IAaveV3Pool _aavePool, IAToken _aToken)` | external (initializer) | BaseStrategy initialization + fixed investment venue + max approve to Pool | AAVE-FR-001 |
| `_doDeposit(uint256 _amount)` | internal (`deposit` hook) | `aavePool.supply(onBehalfOf=this)` and self-account scaled balance | AAVE-FR-003 |
| `_doWithdraw(uint256 _amount) → uint256 actual` | internal (`sendToVault` / `sendProfitToVault` hook) | Withdraw up to `min(_amount, Aave accounting value, aToken liquid underlying)` to this Strategy and subtract self-accounted scaled balance | AAVE-FR-004 |
| `_estimatedTotalUnderlying() → uint256` | internal view (`estimatedTotalUnderlying` hook) | `mulDiv(min(_ownScaledBalance, aaveScaled), income, RAY)` | AAVE-FR-005 |
| `emergencyWithdrawFromAave() → uint256 sent` | external (onlyOwner) | Withdraw the liquid part of Aave holdings (including liquid donations), push all idle Underlying to Vault in the same tx, and account the Vault receipt as returned principal | AAVE-FR-006 |
| `claimAaveRewards(IAaveRewardsController _rewardsController, uint256 _amount, address _reward) → (uint256 claimed, uint256 settled)` | external (onlyOwner) | Claim only this Strategy's aToken rewards. Underlying rewards go to Vault buffer; non-Underlying rewards are swept to Treasury | AAVE-FR-007 |

---

## 6. Functional Requirements (FR)

> The bodies of `deposit` / `sendToVault` / `sendProfitToVault` / `writeoffPrincipal` / `emergencyWithdraw` (destination fixed to Vault) are provided by `BaseStrategy` ([Strategy requirements](Strategy.md)). `AaveV3Strategy` implements `initialize`, the three hooks (`_doDeposit` / `_doWithdraw` / `_estimatedTotalUnderlying`), the protocol-specific emergency recovery function, and the Aave RewardsController claim function.

### AAVE-FR-001: initialize (fixed investment venue and proxy initialization)

- **Type**: Functional | **Source**: derived-class `initialize` convention in [Strategy requirements](Strategy.md) / Aave V3 supply
- **Signature**: `initialize(address _vault, IERC20 _underlying, address _owner, address _upgrader, IAaveV3Pool _aavePool, IAToken _aToken) external initializer`
- **Purpose**: Initialize once through a UUPS proxy, fix Aave V3 investment venue (`aavePool` / `aToken`) in addition to standard `BaseStrategy` initialization, and max-approve Underlying to the Pool.
- **Permission**: part of the deployment procedure (proxy initialization). `_owner` binds Owner (Guardian multisig), and `_upgrader` binds the shared TimelockController (24h) (`BaseStrategy` sets ownership and upgrader).
- **Preconditions / Checks**:
  - One-time only through `initializer` (multiple initialization reverts). The logic contract itself must not be initializable; initialization is proxy-only
  - `_aavePool != address(0)` (zero reverts with `ZeroAddress`)
  - `_aToken != address(0)` (zero reverts with `ZeroAddress`)
  - `_aToken.UNDERLYING_ASSET_ADDRESS() == address(_underlying)` (mismatch reverts with `InvalidATokenUnderlying`)
  - Zero checks for `_vault` / `_underlying` / `_owner` / `_upgrader` are performed by standard `BaseStrategy` initialization
- **Behavior / Effects**:
  1. `__BaseStrategy_init(_vault, _underlying, _owner, _upgrader)` — standard BaseStrategy initialization. Includes OZ Ownable / UUPS initialization, storage saves, ownership transfer, upgrader save, and **`underlying.safeApprove(vault, type(uint256).max)` to Vault** so `receiveFromStrategy` can pull Underlying from Strategy through `safeTransferFrom` (see `BaseStrategy` in [Strategy requirements](Strategy.md))
  2. Verify aToken / Underlying consistency (`UNDERLYING_ASSET_ADDRESS()`)
  3. `aavePool = _aavePool` (immutable thereafter)
  4. `aToken = _aToken` (immutable thereafter)
  5. `_underlying.safeApprove(address(_aavePool), type(uint256).max)` — max approve to Aave V3 Pool (once at initialize; avoids per-deposit approval gas)
- **Reverts / early returns**: multiple initialization → revert; `_aavePool == 0` / `_aToken == 0` → `ZeroAddress`; aToken underlying mismatch → `InvalidATokenUnderlying`.
- **Emitted event**: none (follows BaseStrategy initialization events; no dedicated event for investment venue finalization).
- **Design notes**:
  - **Fix investment venue and initial authorities in `initialize`**: adding `setAavePool` / `setAToken` later would create an attack surface where the Strategy side can move the investment venue. Aave Pool / aToken / Underlying / Vault are fixed in `initialize` ([AAVE-SEC-001](#aave-sec-001-investment-addresses-fixed-at-initialize)). Owner / Upgrader are initialized through BaseStrategy's shared procedure, and later changes follow shared ownership / `setUpgrader` paths. To change the investment venue, recreate the Strategy ([AAVE-GOV-001](#aave-gov-001-change-investment-venue-by-recreating-strategy)).
  - **Trust assumption for `safeApprove(max)`**: if Aave V3 Pool is compromised, temporary Strategy balances may be drained. This trust assumption ("Pool is not compromised") is the same even with per-deposit approval. Final confirmation of this policy is tracked in [AAVE-TBD-001](#aave-tbd-001).
  - **aToken consistency check**: `initialize` verifies `aToken.UNDERLYING_ASSET_ADDRESS() == address(_underlying)` so a Strategy bound to the wrong reserve aToken cannot enter operation. Deployment scripts also assert the same value to double-check address table mistakes.
- **Verification**: unit (multiple initialization revert, each `ZeroAddress` revert, aToken underlying mismatch revert, Pool max approve established, investment venue fixed).

### AAVE-FR-002: addStrategy precondition (Vault registration contract)

- **Type**: Functional | **Source**: `underlying()` contract in [Strategy requirements](Strategy.md) / [CollateralVault requirements](../CollateralVault.md) `addStrategy`
- **Signature**: `underlying() → address` (provided by `BaseStrategy`)
- **Purpose**: Satisfy the assumptions required for the corresponding CollateralVault to put this Strategy into operation after deployment. `underlying()` returns this Strategy's Underlying, and Vault `addStrategy` verifies it on-chain.
- **Permission**: none (`underlying()` is view). Registration operations (whitelist / `addStrategy`) are GOV_MULTISIG ([CollateralVault requirements](../CollateralVault.md)).
- **Preconditions / Checks**: this Strategy has already been added to the corresponding CollateralVault whitelist (`addToWhitelist`).
- **Behavior / Effects**:
  1. GOV calls `addToWhitelist(strategy)` on the corresponding CollateralVault
  2. GOV calls `addStrategy(strategy, weightBps, cap)` to put it into operation. The Vault verifies on-chain that `strategy.underlying() == vault.underlying()` ([CollateralVault requirements](../CollateralVault.md))
- **Reverts / early returns**: if `strategy.underlying()` does not match the Vault Underlying → Vault-side revert.
- **Emitted event**: follows Vault-side events (no Strategy-specific event).
- **Design notes**: this Strategy is registered only for **collaterals to which AaveV3Strategy applies** (collaterals with Aave V3 reserves). The canonical source for dToken / Underlying allocation across all collateral branches is [Parameters](../../../../Parameters.md); `AaveV3Strategy` applies to a subset, not all branches.
- **Verification**: integration (successful `addStrategy` after whitelist; revert on Underlying mismatch), manual (deployment procedure).

### AAVE-FR-003: `_doDeposit` (supply to Aave V3)

- **Type**: Functional | **Source**: `_doDeposit` hook in [Strategy requirements](Strategy.md) / Aave V3 supply
- **Signature**: `_doDeposit(uint256 _amount)` (internal `deposit` hook)
- **Purpose**: `BaseStrategy.deposit` supplies already received Underlying to Aave V3 Pool and self-accounts only the scaled balance increased by that supply in `_ownScaledBalance`.
- **Permission**: internal hook. Caller `deposit` is `onlyVault` ([Strategy requirements](Strategy.md)). The Vault already sent Underlying to the Strategy through `safeTransfer(strategy, _amount)` immediately before calling `deposit`, so the Strategy does not need `safeTransferFrom`.
- **Preconditions / Checks**: Underlying has been transferred from Vault to Strategy before the call (push-model deposit). The Aave reserve is not `frozen` / `paused` (otherwise supply reverts).
- **Behavior / Effects**:
  1. `scaledBefore = aToken.scaledBalanceOf(address(this))`
  2. `aavePool.supply(asset = address(underlyingToken), amount = _amount, onBehalfOf = address(this), referralCode = 0)` — aToken credit recipient = this Strategy
  3. `scaledAfter = aToken.scaledBalanceOf(address(this))`
  4. `scaledMinted = scaledAfter - scaledBefore`
  5. If `scaledMinted == 0`, revert with `AaveSupplyZeroScaledBalance(_amount)`
  6. `_ownScaledBalance += scaledMinted`
  7. Emit `OwnScaledBalanceUpdated(_ownScaledBalance)`
- **Reverts / early returns**: when Aave cannot accept supply because the reserve is frozen/paused, the supply cap is reached, or the scaled-balance delta is zero, the inner `_doDeposit` frame reverts. `BaseStrategy.deposit` rolls back that frame and skips this allocation after exact Underlying recovery to the Vault; any recovery mismatch reverts the full `allocate` call with `DepositRecoveryFailed`. Dust cannot create principal without a valued position.
- **Emitted event**: `OwnScaledBalanceUpdated(_ownScaledBalance)` (AAVE-EVT-001). `BaseStrategy.deposit` handles `principal += _amount` and emits `Deposited(_amount, newPrincipal)` ([Strategy requirements](Strategy.md)).
- **Design notes**:
  - **`onBehalfOf = address(this)`**: the Strategy itself owns the aToken, allowing it to recover the full amount later on its own. Crediting the Vault directly would leak Aave knowledge into the Vault and break responsibility separation.
  - **Self-accounting scaled balance**: only the scaled amount minted by this `supply` (before/after delta) is added to `_ownScaledBalance`. A zero delta is treated as an unaccountable tiny supply and fails closed. A third-party donation in a parallel transaction raises before and after equally and is not included in the delta ([AAVE-SEC-002](#aave-sec-002-exclude-aum-inflation-by-third-party-donation)).
  - **`referralCode`**: currently hardcoded to `0` with a TODO comment. Use of Aave's referral program is tracked in [AAVE-TBD-002](#aave-tbd-002).
- **Verification**: unit (scaled delta accounting, zero-scaled supply revert, `onBehalfOf=this`), fork (actual Aave V3 supply; revert when frozen/paused), invariant=AAVE-INV-001.

### AAVE-FR-004: `_doWithdraw` (withdraw from Aave V3)

- **Type**: Functional | **Source**: `_doWithdraw` hook in [Strategy requirements](Strategy.md) / Aave V3 withdraw
- **Signature**: `_doWithdraw(uint256 _amount) → uint256 actual` (internal hook for `sendToVault` / `sendProfitToVault`)
- **Purpose**: For normal principal/yield recovery, withdraw up to the amount currently recoverable from Aave V3 Pool to the **Strategy itself**. `BaseStrategy` then routes principal/cache-reducing returns through `receiveFromStrategy` and yield-only returns through direct transfer to the Vault buffer, subtracts the burned scaled amount from `_ownScaledBalance`, and returns actual recovered amount `actual`.
- **Permission**: internal hook. Caller `sendToVault` / `sendProfitToVault` checks Vault `ALLOCATOR_ROLE` ([Strategy requirements](Strategy.md)).
- **Preconditions / Checks**: Aave reserve is withdrawable (`paused` is false). Reserve liquidity shortage is rounded by the Strategy-side liquid cap into partial recovery or 0 recovery.
- **Behavior / Effects**:
  1. `withdrawAmount = min(_amount, _ownedAaveAccountingValue(), underlying.balanceOf(aToken))`
  2. `if withdrawAmount == 0: return 0`
  3. `scaledBefore = aToken.scaledBalanceOf(address(this))`
  4. `aavePool.withdraw(asset = address(underlyingToken), amount = withdrawAmount, to = address(this))` — withdraw to the Strategy itself (Vault pulls later)
  5. `scaledAfter = aToken.scaledBalanceOf(address(this))`
  6. `burned = scaledBefore - scaledAfter`
  7. `actual = underlying.balanceOf(this)` before/after delta
  8. If `actual != 0 && burned == 0`, revert with `AaveWithdrawZeroScaledBurn(actual)`
  9. `_ownScaledBalance = burned > _ownScaledBalance ? 0 : _ownScaledBalance - burned` (clamp at 0)
  10. Emit `OwnScaledBalanceUpdated(_ownScaledBalance)` and `return actual`
- **Reverts / early returns**: `withdrawAmount == 0` → return `0`. If the Aave reserve is `paused` or otherwise rejects `withdraw` itself, the revert propagates. If the Strategy's actual Underlying balance increases while the scaled burn is zero, revert with `AaveWithdrawZeroScaledBurn(actual)`. If Aave reports `0` while the Strategy's actual Underlying balance increases, revert with `AaveWithdrawZeroReported(actual)`.
- **Emitted event**: `OwnScaledBalanceUpdated(_ownScaledBalance)` (AAVE-EVT-001). BaseStrategy handles the Vault push, `principal` subtraction, and emits `SentToVault` / `ProfitSentToVault` ([Strategy requirements](Strategy.md)).
- **Design notes**:
  - **`to = address(this)`**: in the push model, Aave withdraws to the **Strategy itself**. Then `BaseStrategy` routes principal returns by calling `vault.receiveFromStrategy(actual)`, so the Vault pulls into the buffer through `safeTransferFrom`; yield-only pushes are transferred directly by the Strategy to the Vault buffer. Withdrawing to the Strategy instead of directly to the Vault keeps the principal-return / yield-only split inside BaseStrategy.
  - **Strategy-side partial recovery**: Aave V3 reverts rather than clamps on insufficient liquidity or over-balance requests, so the Strategy caps the request by Aave accounting value and aToken liquid Underlying before calling Aave. This treats utilization pressure as a liquidity case, not a solvency loss, and returns only the recoverable amount to the Vault.
  - **Subtract scaled balance**: subtract the scaled amount burned by Aave from `_ownScaledBalance` (clamped at 0). If actual Underlying is received but no scaled balance is burned, fail closed to avoid reducing principal while leaving the position intact.
- **Verification**: unit (scaled subtraction, 0-floor clamp, zero-scaled burn revert, `to=this`, liquid reserve cap, reported-zero guard), fork (actual Aave V3 withdrawal; paused/blocked withdraw revert), invariant=AAVE-INV-001.

### AAVE-FR-005: `_estimatedTotalUnderlying` (valuation calculation)

- **Type**: Functional | **Source**: `_estimatedTotalUnderlying` hook in [Strategy requirements](Strategy.md) (conservative valuation assumption)
- **Signature**: `_estimatedTotalUnderlying() → uint256` (internal view hook for `estimatedTotalUnderlying`)
- **Purpose**: Return the Underlying value managed by this Strategy in Aave V3 from Aave accounting values (scaled balance / normalized income), while excluding third-party donations. This is the basis for `BaseStrategy` `estimatedTotalUnderlying` / `realizedYield`. Actual losses not visible in Aave accounting cannot be detected automatically and are corrected through GOV recovery and writeoff operations.
- **Permission**: none (internal view).
- **Preconditions / Checks**: none (view). Has an early return when `effective == 0`.
- **Behavior / Effects**:
  1. `aaveScaled = aToken.scaledBalanceOf(address(this))`
  2. `effective = min(_ownScaledBalance, aaveScaled)` — exclude donations while reflecting Aave-accounting balance decreases
  3. `if effective == 0: return 0`
  4. `income = aavePool.getReserveNormalizedIncome(address(underlyingToken))` — RAY (1e27)
  5. `return Math.mulDiv(effective, income, RAY)` (avoid multiplication overflow for RAY conversion)
- **Reverts / early returns**: `effective == 0` → return `0`.
- **Emitted event**: none (view).
- **Design notes**:
  - **Donation resistance**: using `aToken.balanceOf(this)` directly as AUM would let third-party donations inflate `realizedYield` and route arbitrary amounts to Treasury through yield transfer. Therefore, valuation is based on `_ownScaledBalance`, which changes only through this Strategy's own supply / withdraw ([AAVE-FR-003](#aave-fr-003-_dodeposit-supply-to-aave-v3) / [AAVE-FR-004](#aave-fr-004-_dowithdraw-withdraw-from-aave-v3)), and converted to Underlying with `getReserveNormalizedIncome` (RAY) ([AAVE-SEC-002](#aave-sec-002-exclude-aum-inflation-by-third-party-donation)).
  - **Meaning of `min(_ownScaledBalance, aaveScaled)`**: Aave-side scaled balance caps valuation so Aave-accounting decreases are reflected in AUM, while third-party donations (which increase only `aaveScaled`) are excluded. In short: "do not claim more than Aave says, but do not count third-party donations."
  - **Possible divergence**: Aave V3 `scaledBalanceOf` / `getReserveNormalizedIncome` do not always prove actual recoverability. In reserve abnormal states (frozen / paused / 100% utilization / large bad debt), accounting claims may remain while recovery is impossible, and `estimatedTotalUnderlying()` may be overvalued. In that case, GUARDIAN stops new allocation with `emergencyDisableStrategy`; GOV sets permanent parameters such as `cap = 0` if needed, returns whatever can be recovered to the Vault, and explicitly reflects the remaining loss in backing through `writeoffStrategyPrincipal`. Whether to add further conservative adjustment is tracked in [AAVE-TBD-003](#aave-tbd-003).
- **Verification**: unit (`min` selection, `effective==0` returns 0, RAY conversion), fork (valuation with actual `getReserveNormalizedIncome`), invariant=AAVE-INV-002.

### AAVE-FR-006: emergencyWithdrawFromAave (emergency liquid recovery)

- **Type**: Functional | **Source**: protocol-specific emergency recovery function (`emergency*From{Protocol}()`) in [Strategy requirements](Strategy.md) / 2026-06-12 finalized governance design (old two-stage structure unified into atomic direct-push; [../../policies/Governance-Roles-Timelock.md](../../policies/Governance-Roles-Timelock.md))
- **Signature**: `emergencyWithdrawFromAave() external onlyOwner returns (uint256 sent)` (`sent` = actual Underlying amount pushed to Vault)
- **Purpose**: Emergency function for Owner (Guardian multisig) to **withdraw all funds deposited in Aave (including third-party donations), then atomically push all Underlying including the Strategy idle balance to the Vault in the same tx** when Aave V3 is emergency-stopped, the reserve is frozen, a critical vulnerability is reported, etc. Not for normal operation.
- **Permission**: `onlyOwner` (Guardian multisig). Separated from operations role (ALLOCATOR) ([AAVE-SEC-003](#aave-sec-003-fixed-destination-and-authorization-separation-for-emergency-recovery)).
- **Preconditions / Checks**: `caller == Owner`. If both Aave balance and Strategy idle Underlying are 0, return `0` early. When a push occurs, **this Strategy must be registered in the Vault (`strategies[]` remains)** because push destination `receiveFromStrategy` accepts only registered Strategies. If already `removeStrategy`-ed, the whole function reverts (`emergencyDisableStrategy` leaves it registered and remains executable).
- **Behavior / Effects**:
  1. `aTokenBalance = aToken.balanceOf(address(this))` — all aToken including donations
  2. `liquidUnderlying = underlying.balanceOf(address(aToken))`
  3. `withdrawAmount = min(aTokenBalance, liquidUnderlying)` — Aave ordinary `withdraw` does not partially fill, so the Strategy caps by liquid reserve before calling
  4. If `withdrawAmount != 0`, call `aavePool.withdraw(asset = address(underlyingToken), amount = withdrawAmount, to = address(this))`, subtract the burned scaled balance from `_ownScaledBalance` with a 0 floor, and emit `OwnScaledBalanceUpdated`
  5. `idle = underlyingToken.balanceOf(address(this))` — drain amount plus existing idle (accidental stuck balance / donation)
  6. `if idle == 0: return 0` — no Underlying to send
  7. `sent = ICollateralVault(vault).receiveFromStrategy(idle)` — push all idle to the **Vault buffer in the same tx** (Vault accounts actual receipt and reduces valuation cache by actual received amount; [CollateralVault requirements](../CollateralVault.md) VAULT-FR-005)
  8. Account `sent` as returned principal with `BaseStrategy._accountReturnedPrincipal`, reducing `principal` by `min(sent, principal)`
  9. Emit `EmergencyWithdrawn(sent)` and return `sent`
- **Reverts / early returns**: `caller != Owner` → revert; after Aave drain, `idle == 0` → return `0` normally with no action; if actual Underlying is received while the scaled burn is zero, revert with `AaveWithdrawZeroScaledBurn(actual)`; if Aave is fully stopped and withdraw itself reverts, **the whole function reverts (fail-closed; no state change)**, so no suspended valuation or undervaluation arises ([AAVE-ERR-003](#aave-err-003-emergency-recovery-impossible-when-aave-is-fully-stopped)).
- **Emitted events**: `OwnScaledBalanceUpdated(ownScaledBalance)` (AAVE-EVT-001 after Aave burn) / shared Strategy `PrincipalReturned(returned, newPrincipal)` and `EmergencyWithdrawn(sent)` ([Strategy requirements](Strategy.md), actual amount pushed to Vault) / Vault-side `ReceivedFromStrategy(strategy, declared, received)`. Whether to add a dedicated Aave drain event (`EmergencyAaveWithdrawn`, etc.) is [AAVE-TBD-004](#aave-tbd-004) (AAVE-EVT-002).
- **Design notes**:
  - **Liquid reserve cap**: Aave V3 ordinary `withdraw` does not partially fill when liquidity is insufficient. Emergency recovery also caps by the smaller of this Strategy's aToken balance and the aToken's liquid Underlying reserve, recovering only what is currently recoverable.
  - **Why atomic direct-push (old two-stage design removed)**: in the old design (Aave → Strategy idle → manual `emergencyWithdraw` → Vault), the interval between withdrawal and push left funds in a **suspended** state counted neither in `_estimatedTotalUnderlying` (idle excluded) nor in Vault buffer. This could undervalue `totalUnderlying` / `backingRatio` by the full withdrawn amount, leading to oracle markdown and improper mass liquidation of all Troves in that branch (permissionless, automatic MEV, irreversible). Relying on multisig multiSend execution is operational discipline, not code-level atomicity; non-atomic execution, partial push, or push failure in an emergency can cause real damage. The function makes the path atomic in code.
  - **Returned-principal accounting**: the Vault receipt `sent` is accounted as returned principal. If a residual amount is later judged unrecoverable, GOV finalizes that loss through `Vault.writeoffStrategyPrincipal` ([CollateralVault requirements](../CollateralVault.md) VAULT-FR-009).
  - **Recovering donations**: third-party donation amounts are not normally included in AUM ([AAVE-FR-005](#aave-fr-005-_estimatedtotalunderlying-valuation-calculation)), but this function recovers all balances including donations into the Vault buffer and counts them in backing (benefits holders).
  - **Relationship with `BaseStrategy.emergencyWithdraw`**: `emergencyWithdraw(uint256 _amount)` remains available to send idle Underlying directly held by the Strategy (donation / accidental stuck balance) to the Vault (do not remove; [Strategy requirements](Strategy.md) STGY-FR-005).
  - **Registration precondition and recovery path**: atomic direct-push relies on the Vault-side registration guard in `receiveFromStrategy`. If residual Aave funds (donations, etc.) are found after `removeStrategy`, recover by re-whitelisting → `addStrategy` (GOV=Timelock; 24h) and then calling this function (fail-closed: while unregistered, funds remain in Aave and do not flow to a wrong destination).
- **Verification**: unit (`onlyOwner`, Aave/idle zero-balance early return, idle-only push, liquid reserve cap, returned-principal accounting, `sent` return value, **same-tx Vault receipt and full revert when Aave withdraw reverts**), fork (liquid recovery from actual Aave → Vault receipt), integration (`backingRatio` does not decrease through the path).

### AAVE-FR-007: claimAaveRewards (Aave RewardsController reward claim)

- **Type**: Functional | **Source**: Aave V3 `RewardsController.claimRewards` / reward settlement policy in [Strategy requirements](Strategy.md)
- **Signature**: `claimAaveRewards(IAaveRewardsController _rewardsController, uint256 _amount, address _reward) external onlyOwner returns (uint256 claimed, uint256 settled)`
- **Purpose**: Let Owner explicitly claim Aave V3 rewards earned by this Strategy's `aToken` position and settle them to a fixed destination based on reward type. Unclaimed rewards are not included in AUM, principal, or realizedYield.
- **Permission**: `onlyOwner` (Guardian multisig). ALLOCATOR and arbitrary callers cannot start protocol-specific reward claims.
- **Preconditions / Checks**:
  - `_rewardsController != address(0)` (`ZeroAddress`)
  - `_rewardsController.code.length != 0` (`InvalidAaveRewardsController`)
  - `_reward != address(0)` (`ZeroAddress`)
  - if `_reward != underlying` and `_isSweepProtectedToken(_reward)`, revert `CannotSweepProtectedToken`; aToken / dToken / other position tokens must not be moved as rewards
- **Behavior / Effects**:
  1. Build `assets = [address(aToken)]`; claim target asset is fixed to this Strategy's aToken
  2. Record the Strategy's `_reward` balance before claim
  3. Call `_rewardsController.claimRewards(assets, _amount, address(this), _reward)` and return its value as `claimed`
  4. If `_reward == underlying`, send only the actual balance delta to the Vault buffer with `_sendUnderlyingToVault`; `principal` is not reduced and Vault actual receipt is `settled`
  5. If `_reward != underlying`, call `BaseStrategy._sweepRewardToken(_reward, type(uint256).max)` and return the Treasury actual receipt as `settled`
- **Reverts / early returns**: authorization failure, invalid controller/reward, protected token, or Aave `claimRewards` revert. If the actual claim receipt is 0, the Underlying branch returns `settled == 0`; the non-Underlying branch's sweep helper returns 0.
- **Emitted events**: Underlying reward emits `AaveUnderlyingRewardsClaimed(rewardsController, reward, requested, claimed, sentToVault)` (AAVE-EVT-004). Non-Underlying reward emits shared `RewardTokenSwept(token, treasury, requested, received)` plus `AaveRewardsClaimed(rewardsController, reward, requested, claimed, settled)` (AAVE-EVT-003).
- **Design notes**:
  - **Not part of AUM**: Aave rewards are separate from aToken normalized income and are not inputs to `_estimatedTotalUnderlying()`. Only Underlying rewards become backing after actual transfer to the Vault buffer, without reducing `principal`.
  - **No swap**: this function does not convert non-Underlying rewards into Underlying. Reward swaps, buybacks, and backstop deposits belong to Treasury / operations runbooks ([AAVE-TBD-005](#aave-tbd-005)).
  - **Position-token protection**: aToken is a position/accounting token, not a reward token. `_isSweepProtectedToken` rejects moving aToken / dToken / Underlying as Treasury rewards; Underlying rewards are only allowed through the Vault buffer path.
- **Verification**: unit (onlyOwner, controller/reward zero, controller code check, assets fixed to aToken, Underlying reward sent to Vault buffer by actual receipt, non-Underlying reward swept to Treasury, aToken/dToken reward rejected, 0 claim return), fork (actual Aave RewardsController claim or no-reward 0 return).

---

## 7. State Variables and Accounting Model

In addition to shared storage held by `BaseStrategy` (`vault` / `underlyingToken` / `_principal`), `AaveV3Strategy` has the following Aave-specific storage. `aavePool` / `aToken` are fixed in `initialize` and immutable thereafter. `_ownScaledBalance` is updated with supply / withdraw.

| Variable | Type | Role | Finalization |
| --- | --- | --- | --- |
| `aavePool` | `IAaveV3Pool` | Aave V3 Pool; call target for `supply` / `withdraw` / `getReserveNormalizedIncome` | Fixed and immutable in `initialize` |
| `aToken` | `IAToken` | aToken corresponding to the Underlying; read through `scaledBalanceOf(this)` / `balanceOf(this)` | Fixed and immutable in `initialize` |
| `_ownScaledBalance` | `uint256` | Scaled balance (RAY precision) increased/decreased by **this Strategy's own** supply / withdraw. Does not increase when a third party donates through `supply(onBehalfOf=this)`. Basis for AUM valuation ([AAVE-FR-005](#aave-fr-005-_estimatedtotalunderlying-valuation-calculation)) | Increased by `_doDeposit` / decreased by `_doWithdraw` and `emergencyWithdrawFromAave` by the burned scaled amount with a 0 floor |

**Accounting model**: self-management of deployed principal `principal` and `realizedYield = max(estimatedTotalUnderlying - principal, 0)` belong to `BaseStrategy` ([Strategy requirements](Strategy.md)). `AaveV3Strategy` handles valuation of the Aave-side position (`_estimatedTotalUnderlying`), based on `_ownScaledBalance` (scaled balance from self supply/withdraw).

- **Why `_ownScaledBalance` is self-managed**: Aave V3 `supply(onBehalfOf=anyone)` is permissionless, so anyone can increase this Strategy's aToken. If `aToken.balanceOf` were used directly as AUM, **third-party donations would inflate `realizedYield`, and `sendProfitToVault` plus Vault yield→Treasury route would let an arbitrary amount be routed into Treasury** ([AAVE-SEC-002](#aave-sec-002-exclude-aum-inflation-by-third-party-donation)). Self-managed scaled balance prevents this.
- **Why there are no setters for `aavePool` / `aToken`**: allowing the Strategy side to move the investment venue after deployment creates an attack surface. Fixing them in `initialize` removes storage migration risk and attack surface (venue changes require Strategy recreation; [AAVE-SEC-001](#aave-sec-001-investment-addresses-fixed-at-initialize) / [AAVE-GOV-001](#aave-gov-001-change-investment-venue-by-recreating-strategy)).
- **Conservativeness and limits of valuation**: `_estimatedTotalUnderlying = mulDiv(min(_ownScaledBalance, aaveScaled), income, RAY)`. Aave-accounting balance decreases are reflected by lower `aaveScaled`, and donations are excluded by the `_ownScaledBalance` cap. Actual losses or withdrawal impossibility not visible in Aave accounting cannot be detected by this view alone; Vault `writeoffStrategyPrincipal` is the manual route to reflect backing downward.
- **Reward token accounting boundary**: non-Underlying reward tokens such as Aave incentives / Merkl are excluded from `_ownScaledBalance` and `estimatedTotalUnderlying()`. Received rewards are sent to Treasury through `BaseStrategy.sweepRewardToken`; standard Merkl distributor rewards are claimed and swept through `BaseStrategy.claimMerklRewards`; Aave `RewardsController` rewards are settled through `claimAaveRewards`. Underlying rewards are sent to the Vault buffer as yield, while non-Underlying rewards are sent to Treasury. Swapping rewards for backing replenishment is a separate design. aToken is the Strategy's Aave claim itself and is a protected token, so it cannot move to Treasury through reward sweep / Merkl claim / Aave claim settlement.

---

## 8. Invariants (INV)

| ID | Invariant | Verification |
| --- | --- | --- |
| AAVE-INV-001 | `_ownScaledBalance` changes only through this Strategy's `_doDeposit` (before/after delta increase), `_doWithdraw` (burned amount subtraction with 0 floor), and `emergencyWithdrawFromAave` (burned amount subtraction with 0 floor). It does not increase through third-party donation | invariant |
| AAVE-INV-002 | `_estimatedTotalUnderlying()` is `mulDiv(min(_ownScaledBalance, aToken.scaledBalanceOf(this)), getReserveNormalizedIncome, RAY)`. Third-party donations are excluded from AUM, while Aave-accounting balance decreases (scaled reduction) are reflected. Actual losses not visible in Aave accounting are corrected by GOV writeoff operations. Returns 0 when `effective == 0` | invariant / fork |
| AAVE-INV-003 | `aavePool` / `aToken` are immutable after `initialize` (no setter) | invariant |
| AAVE-INV-004 | `_doDeposit` `supply` uses `onBehalfOf == address(this)`; normal `_doWithdraw` and `emergencyWithdrawFromAave` Aave `withdraw` use `to == address(this)`. Emergency recovery then pushes to the Vault through `receiveFromStrategy` within the same tx and has no arbitrary destination | unit |
| AAVE-INV-005 | `sweepRewardToken(aToken, ...)` reverts with `CannotSweepProtectedToken`, so the Aave position token cannot be moved to Treasury. Normal reward token sweep remains possible | unit |

---

## 9. Security Requirements (SEC)

### AAVE-SEC-001: investment addresses fixed at initialize

- Type: Security
- Statement: `aavePool` / `aToken` and approval to Pool must be fixed in `initialize`; the Strategy must not have any post-deployment setter such as `setAavePool` / `setAToken` (eliminates the attack surface of "moving the investment venue from the Strategy side" and storage migration risk). To change the investment venue, recreate the Strategy and replace Vault registration ([AAVE-GOV-001](#aave-gov-001-change-investment-venue-by-recreating-strategy)).
- Verification: invariant=AAVE-INV-003, manual (code review for absence of setters)

### AAVE-SEC-002: exclude AUM inflation by third-party donation

- Type: Security
- Statement: Aave V3 `supply(asset, amount, onBehalfOf=anyone, _)` is permissionless, so anyone can increase this Strategy's aToken balance. If `aToken.balanceOf` were used directly as AUM, third-party donation would inflate `realizedYield()` and enable an attack that routes **an arbitrary amount to Treasury** through `sendProfitToVault` + Vault yield→Treasury. To prevent this, `_estimatedTotalUnderlying()` must be based on `_ownScaledBalance`, which changes only through this Strategy's own supply / withdraw ([AAVE-FR-003](#aave-fr-003-_dodeposit-supply-to-aave-v3) / [AAVE-FR-004](#aave-fr-004-_dowithdraw-withdraw-from-aave-v3)), not on `balanceOf`. `min(_ownScaledBalance, aToken.scaledBalanceOf)` reflects Aave-accounting balance decreases while excluding donations. Donation amounts are recovered in emergencies by `emergencyWithdrawFromAave` (which withdraws all aToken).
- Verification: invariant=AAVE-INV-001/002, fork (inject donation and verify `realizedYield` does not increase)

### AAVE-SEC-003: fixed destination and authorization separation for emergency recovery

- Type: Security
- Statement: `emergencyWithdrawFromAave` must be `onlyOwner` and cannot be triggered by operational roles (ALLOCATOR), so a compromised operations bot key cannot trigger emergency recovery. Aave withdrawal and Vault push (`receiveFromStrategy`) must be performed **atomically in the same tx**; withdrawn Underlying must not remain idle in the Strategy (prevents suspended valuation and backing undervaluation). Destination is fixed to the Vault with no arbitrary destination, so a compromised Owner key cannot remove funds to an arbitrary address (funds return to Vault and are reallocated through governance).
- Verification: unit (ALLOCATOR call reverts, same-tx Vault receipt, fixed destination), manual (emergency recovery runbook review)

### AAVE-SEC-004: prevent Aave Pool / aToken address misconfiguration

- Type: Security
- Statement: if the wrong Aave V3 Pool or aToken address is passed to `initialize`, the Strategy may try to supply / withdraw against an unrelated reserve, causing loss of funds or valuation errors. In particular, binding an aToken that does not match the Underlying is a critical bug because AUM would be valued in a different asset. `initialize` must verify on-chain that `aToken.UNDERLYING_ASSET_ADDRESS() == address(_underlying)` and fail-closed with `InvalidATokenUnderlying` on mismatch. Deployment scripts must assert the same and require checking against official Pool / aToken address tables.
- Verification: unit (misconfiguration reverts), manual (deployment-script assert procedure)

### AAVE-SEC-005: forbid sweeping aToken as reward

- Type: Security
- Statement: aToken is an Aave position / accounting token, not a reward token such as Aave incentives / Merkl. If `sweepRewardToken` could move aToken to Treasury, it would bypass the Aave withdraw path, `_ownScaledBalance`, and Vault backing accounting. `AaveV3Strategy` must override `BaseStrategy._isSweepProtectedToken` and include `aToken` as a protected token.
- Verification: unit (`sweepRewardToken(aToken)` reverts; normal reward token sweep succeeds)

> **reentrancy / CEI**: push-path authorization and accounting defenses belong to `BaseStrategy` / CollateralVault ([Strategy requirements](Strategy.md) / [CollateralVault requirements](../CollateralVault.md)) and are not re-specified here. `AaveV3Strategy` hooks account scaled balance deltas before/after external calls (`aavePool.supply` / `withdraw`), so scaled accounting is based on observed external call results.

---

## 10. Governance, Operations, and Upgrade Requirements (GOV)

Shared authorization and upgrade policy (UUPS `_authorizeUpgrade` = upgrader-only, `transferOwnership`, disabled `renounceOwnership`, multisig + future timelock) uses [Strategy requirements](Strategy.md) as the canonical source. Only Aave V3-specific operational requirements are below.

### AAVE-GOV-001: change investment venue by recreating Strategy

- Statement: to change Underlying, Aave Pool, or aToken after deployment, do not move them with setters such as `setAavePool` / `setAToken`. Instead, **recreate the entire Strategy** and replace the corresponding CollateralVault whitelist and registration (`addStrategy`) ([AAVE-SEC-001](#aave-sec-001-investment-addresses-fixed-at-initialize)).
- Verification: manual (operations runbook)

### AAVE-GOV-002: testnet first

- Statement: Aave V3 provides a Sepolia environment with the same address/interface shape as mainnet. Deployment and integration tests are run on Sepolia first, then migrated to mainnet.
- Verification: manual (Sepolia integration test completion)

### AAVE-GOV-003: stop new allocation and recover during abnormal conditions

- Statement: when the Aave reserve shows abnormal signals (frozen / paused / supply cap change / utilization stress / large bad debt), GUARDIAN immediately stops new supply by setting this Strategy `weightBps = 0` / `enabled = false` through Vault `emergencyDisableStrategy`, and GOV sets permanent parameters such as `cap = 0` if needed. Owner recovers all funds to the Vault through `emergencyWithdrawFromAave` when needed. Aave Governance forum and Snapshot voting are monitored continuously.
- Verification: manual (monitoring and operations runbook)

---

## 11. Events and Monitoring Requirements (EVT)

Shared events (`Deposited` / `SentToVault` / `ProfitSentToVault` / `PrincipalWrittenOff` / `EmergencyWithdrawn` / `RewardTokenSwept`) are emitted by `BaseStrategy` ([Strategy requirements](Strategy.md)). Aave V3-specific events and monitoring are below.

| ID | Event | Purpose (off-chain) |
| --- | --- | --- |
| AAVE-EVT-001 | `OwnScaledBalanceUpdated(uint256 ownScaledBalance)` | Track self-accounted scaled balance after `_doDeposit` / `_doWithdraw` / `emergencyWithdrawFromAave`; monitor the basis of AUM over time |
| AAVE-EVT-002 | `EmergencyWithdrawn(uint256 amount)` (shared BaseStrategy event) | Observe Vault direct-push recovery amount from `emergencyWithdrawFromAave`. Combine with `PrincipalReturned` to track returned principal |
| AAVE-EVT-003 | `AaveRewardsClaimed(address rewardsController, address reward, uint256 requested, uint256 claimed, uint256 settled)` | Track non-Underlying rewards claimed from Aave RewardsController and actual Treasury receipt. Reconcile with `RewardTokenSwept` |
| AAVE-EVT-004 | `AaveUnderlyingRewardsClaimed(address rewardsController, address reward, uint256 requested, uint256 claimed, uint256 sentToVault)` | Track Underlying rewards claimed from Aave RewardsController and actual Vault buffer receipt. Monitor as yield settlement that does not reduce principal |

**Aave-specific monitoring metrics**:

- **Utilization** of the relevant reserve: above 80% is an operational signal to lower `weightBps` ([AAVE-ERR-002](#aave-err-002-withdraw-revert-at-100-utilization)).
- **Divergence between AUM and actual recovered amount**: during reserve abnormalities, `_estimatedTotalUnderlying` (`getReserveNormalizedIncome` / actual scaled balance) may diverge from actual recoverability; visualize the divergence in the subgraph ([AAVE-ERR-001](#aave-err-001-aave-reserve-configuration-change-frozen--paused--supply-cap) / [AAVE-TBD-003](#aave-tbd-003)).
- **Aave reserve health**: continuously monitor frozen / paused / supply cap / borrow cap status through Aave Governance forum, Snapshot, and dashboards.
- **Aave rewards settlement**: reconcile `AaveRewardsClaimed` / `AaveUnderlyingRewardsClaimed` with `RewardTokenSwept` / Vault buffer balances and confirm rewards are not mixed into AUM or principal ([AAVE-FR-007](#aave-fr-007-claimaaverewards-aave-rewardscontroller-reward-claim) / [AAVE-ERR-005](#aave-err-005-missed-reward-tokens)).

---

## 12. Failure / Exception Behavior (ERR)

Shared exceptional paths (push handling of liquidity shortage as a normal path and absorption of asynchronous protocols) are described in [Strategy requirements](Strategy.md). This section describes only Aave V3-specific events and mitigations.

### AAVE-ERR-001: Aave reserve configuration change (frozen / paused / supply cap)

- Trigger: Aave Governance changes reserve status and restricts `supply` / `withdraw` (`frozen` / `paused` / supply cap / borrow cap change).
- Behavior: an Aave `supply` revert in `_doDeposit` is isolated by `BaseStrategy.deposit`, producing a per-Strategy skip after exact recovery or a full revert on recovery mismatch. An Aave `withdraw` revert in `_doWithdraw` still propagates through `sendToVault` / `sendProfitToVault`.
- Mitigation: continuously monitor Aave Governance forum and Snapshot voting. If abnormal signals appear, GUARDIAN stops new supply with `emergencyDisableStrategy`, and Owner recovers the liquid portion with `emergencyWithdrawFromAave` ([AAVE-GOV-003](#aave-gov-003-stop-new-allocation-and-recover-during-abnormal-conditions)).

### AAVE-ERR-002: withdraw revert at 100% utilization

- Trigger: if the reserve is at 100% utilization, `withdraw` **reverts without clamping** (requested amount cannot be withdrawn).
- Behavior: `AaveV3Strategy` caps the request before calling `withdraw` by Aave accounting value and aToken liquid Underlying, so simple liquidity shortage returns `0` or a partial recovery from `sendToVault` / `sendProfitToVault`. If the reserve is paused or otherwise rejects `withdraw` itself, the revert propagates.
- Mitigation: continuously monitor reserve utilization and lower `weightBps` above 80%. Maintain inventory with Vault-side `bufferTargetBps` / `bufferFloor` ([CollateralVault requirements](../CollateralVault.md)).

### AAVE-ERR-003: emergency recovery impossible when Aave is fully stopped

- Trigger: Aave side is fully stopped and `withdraw` inside `emergencyWithdrawFromAave` itself reverts.
- Behavior: emergency recovery ([AAVE-FR-006](#aave-fr-006-emergencywithdrawfromaave-emergency-liquid-recovery)) cannot rescue funds through the Aave withdraw leg. Because the path uses atomic evacuation, **the whole function reverts (fail-closed)** and no state change or suspended valuation occurs. If `withdrawAmount == 0` but idle Underlying exists, idle Underlying is still pushed to the Vault; it returns `0` only when both Aave and idle balances are 0.
- Mitigation: higher-level actions are required, such as engaging Aave Governance and retrying later.

### AAVE-ERR-004: aToken valuation assumption breaks

- Trigger: during reserve abnormalities ([AAVE-ERR-001](#aave-err-001-aave-reserve-configuration-change-frozen--paused--supply-cap) / [AAVE-ERR-002](#aave-err-002-withdraw-revert-at-100-utilization), large bad debt), `getReserveNormalizedIncome` or actual scaled balance diverges from actual recoverability.
- Behavior: `estimatedTotalUnderlying()` (`min(_ownScaledBalance, aToken.scaledBalanceOf) × getReserveNormalizedIncome / RAY`, [AAVE-FR-005](#aave-fr-005-_estimatedtotalunderlying-valuation-calculation)) may diverge from actual recoverable amount.
- Mitigation ([AAVE-TBD-003](#aave-tbd-003)): either add no correction and visualize "AUM vs actual recovered amount" in the subgraph, or have GUARDIAN call `emergencyDisableStrategy` during abnormalities and GOV set `cap = 0` if needed to stop new allocation effectively.

### AAVE-ERR-005: missed reward tokens

- Trigger: some Aave V3 reserves have incentive rewards (stkAAVE, etc.) through `RewardsController`, and additional rewards may be distributed by Merkl or similar external distributors.
- Behavior: current `AaveV3Strategy` can claim Merkl standard distributor rewards through `BaseStrategy.claimMerklRewards` and Aave `RewardsController` rewards through `claimAaveRewards`. Non-Underlying, non-protected reward tokens are swept to the Vault's current Treasury; Underlying rewards are sent to the Vault buffer as yield. Non-Underlying, non-protected reward tokens already received by the Strategy can be sent to Treasury through shared `BaseStrategy.sweepRewardToken`. Rewards are not included in `_estimatedTotalUnderlying()` / `realizedYield()` / dToken backing before claim, and only Underlying rewards enter backing after actual Vault receipt. aToken is a position token and is rejected before sweep / Merkl claim / Aave claim settlement.
- Mitigation: claim Aave / Merkl rewards through the explicit functions and consolidate non-Underlying rewards to Treasury. If rewards are used for backing repair, Treasury / operations should convert to Underlying and deposit explicitly through `backstopDeposit`; the Strategy body has no reward swap. Position tokens including aToken are not handled through reward paths; they are converted to Underlying through Aave withdraw / emergency withdraw and returned to Vault.

---

## 13. Acceptance Criteria and Verification Plan

Passing condition for each requirement = satisfy the verification method in the table below (do not write test names or execution results in this document; specify only the method type). Verification for shared functions (`deposit` / `sendToVault` / `sendProfitToVault` / `writeoffPrincipal` / `emergencyWithdraw`) is defined in [Strategy requirements](Strategy.md).

| ID | Requirement (summary) | Verification method |
| --- | --- | --- |
| AAVE-FR-001 | initialize (fixed investment venue, aToken underlying validation, Pool max approve, zero/multiple revert) | unit |
| AAVE-FR-002 | addStrategy precondition (whitelist→addStrategy, Underlying match verification) | integration, manual |
| AAVE-FR-003 | _doDeposit (`supply(onBehalfOf=this)`, scaled delta accounting, zero-scaled supply revert) | unit, fork, invariant=AAVE-INV-001 |
| AAVE-FR-004 | _doWithdraw (`withdraw(to=this)`, scaled subtraction, zero-scaled burn revert, liquid reserve cap with partial / 0 recovery, reported-zero guard) | unit, fork, invariant=AAVE-INV-001 |
| AAVE-FR-005 | _estimatedTotalUnderlying (`min`, RAY conversion, donation exclusion) | unit, fork, invariant=AAVE-INV-002 |
| AAVE-FR-006 | emergencyWithdrawFromAave (onlyOwner, liquid reserve cap, Vault atomic push, returned-principal accounting) | unit, fork |
| AAVE-FR-007 | claimAaveRewards (assets fixed to aToken, Underlying reward to Vault buffer, non-Underlying reward to Treasury, protected token rejection) | unit, fork |
| AAVE-INV-001..005 | Each invariant in §8 | invariant / fork / unit (as listed in §8) |
| AAVE-SEC-001..005 | Each security requirement in §9 | invariant / unit / fork / manual |
| AAVE-EVT-001..004 | Each Aave-specific event in §11 | unit |
| AAVE-ERR-001..005 | Each Aave-specific exceptional path in §12 | unit / fork / manual |

---

## 14. Open Items (TBD)

### AAVE-TBD-001

Final confirmation of the `safeApprove(max)` policy: whether to switch to per-deposit approval, and risk assessment if Aave Pool is compromised. Related: [AAVE-FR-001](#aave-fr-001-initialize-fixed-investment-venue-and-proxy-initialization).

### AAVE-TBD-002

Final `referralCode` value: keep `0` / register Aave referral / use own identifier. Related: [AAVE-FR-003](#aave-fr-003-_dodeposit-supply-to-aave-v3).

### AAVE-TBD-003

Need for conservative adjustment when converting aToken to Underlying: whether to add further conservative correction to `_estimatedTotalUnderlying`. Related: [AAVE-FR-005](#aave-fr-005-_estimatedtotalunderlying-valuation-calculation) / [AAVE-ERR-004](#aave-err-004-atoken-valuation-assumption-breaks).

Current interpretation:

- **Do not mark down temporary illiquidity.** High utilization or a shortage of
  liquid underlying is not confirmed loss while the Aave accounting claim
  remains. Capping `_estimatedTotalUnderlying` / `backingRatio` by liquid reserve
  would cause an improper markdown and liquidation. The withdrawal path instead
  performs partial / zero recovery under [AAVE-TBD-008](#aave-tbd-008).
- **Reflect losses visible in Aave accounting.** A reduction in
  `aToken.scaledBalanceOf(this)` or `getReserveNormalizedIncome` flows naturally
  through the [AAVE-FR-005](#aave-fr-005-_estimatedtotalunderlying-valuation-calculation)
  formula.
- **This TBD covers only real unrecoverable loss absent from Aave accounting.**
  When a reserve deficit, bad debt, or protocol incident makes
  `estimatedTotalUnderlying()` diverge from recoverable value and external
  evidence, recovery transactions, and Aave governance state establish that the
  residual cannot be recovered, first return recovered funds to the Vault, use
  `backstopDeposit` first if replenishment is available, and finally reflect only
  the confirmed residual through `writeoffStrategyPrincipal`. The
  [Strategy Incident / Liquidation Safety Runbook](../../../operations/runbooks/Strategy-Incident-Liquidation-Safety-Runbook.md)
  is authoritative for the procedure.

The remaining question is whether to add an automatic conservative adjustment
from an external risk oracle, reserve-deficit feed, or governance-event watcher
in addition to manual writeoff. Any such design must distinguish temporary
illiquidity from confirmed loss.

### AAVE-TBD-004

Whether to add a dedicated `EmergencyAaveWithdrawn(uint256 withdrawn, uint256 sent)` event to `emergencyWithdrawFromAave()`. Currently the Strategy shared `EmergencyWithdrawn(sent)` observes the Vault push amount. Related: [AAVE-FR-006](#aave-fr-006-emergencywithdrawfromaave-emergency-liquid-recovery) / AAVE-EVT-002.

### AAVE-TBD-005

Whether to capture unclaimed Aave / Merkl rewards. Resolved/scoped (2026-06-18): standard Merkl distributor rewards are captured through shared `BaseStrategy.claimMerklRewards`, and Aave `RewardsController` rewards are captured through `claimAaveRewards`. After claim, Underlying rewards are sent to the Vault buffer as yield, while non-Underlying rewards reuse `BaseStrategy._sweepRewardToken` for fixed Treasury routing, protected-token rejection, and actual-received events. aToken is a protected token and is not handled through this path. Remaining open design is reward swapping and converting non-Underlying rewards to Underlying / `backstopDeposit` if rewards are used for backing repair. Related: [AAVE-FR-007](#aave-fr-007-claimaaverewards-aave-rewardscontroller-reward-claim) / [AAVE-ERR-005](#aave-err-005-missed-reward-tokens).

- **A**: implement claim → settlement / swap path inside this Strategy. Claim → settlement is implemented through `claimMerklRewards` / `claimAaveRewards`; adding a swap router to the Strategy body would increase attack surface.
- **B**: do not use reserves / campaigns with incentives (avoid implementation complexity).
- **C**: extract protocol-specific claims such as Aave `RewardsController` to a separate contract (`AaveRewardsClaimer`, etc.). This option is not used for Aave: `claimAaveRewards` is implemented minimally in the Strategy body, and post-claim transfer is routed through `BaseStrategy._sweepRewardToken` / `_sendUnderlyingToVault`.

For now, the Strategy handles claim / sweep only. Reward swaps and backing replenishment are handled separately by Treasury / operations runbooks. Non-Underlying rewards do not directly enter Strategy AUM, principal, or the Vault buffer.

### AAVE-TBD-006

Resolved: reflected in `AAVE-FR-001` and `AAVE-SEC-004`.

### AAVE-TBD-007

Resolved: reflected in `AAVE-FR-001` and the
[Mainnet Deploy Env Freeze Runbook](../../../launch/gates/Mainnet-Deploy-Env-Freeze-Runbook.md).

### AAVE-TBD-008

Resolved: reflected in `AAVE-FR-004`, `AAVE-FR-005`, `AAVE-ERR-002`, and
`STGY-SEC-005`.

---

## 15. References

### Implementation

- `contracts/src/Strategies/AaveV3Strategy.sol` (Aave V3 concrete Strategy body)

### Related Pages

- [Strategy requirements](Strategy.md) — `IStrategy` / `BaseStrategy` / push model / shared authorization / shared risks / shared events (parent page; canonical source)
- [CollateralVault requirements](../CollateralVault.md) — whitelist / `addStrategy` / `receiveFromStrategy` / buffer, cap, and weights
- [dToken requirements](../dToken.md) — collateral beneficial-interest token (Underlying conversion and Cap)
- [Parameters.md](../../../../Parameters.md) — finalized values for collateral allocation / cap / weightBps / governance holder configuration (Timelock, GOV/Guardian multisig), etc.
- [requirements specification document standard](../../../../README.md#requirements-spec-standard) — standard followed by this document

### External Resources

- [Aave V3 documentation](https://aave.com/docs)
- [Aave addresses (mainnet / testnet)](https://aave.com/docs/resources/addresses)
- [Aave V3 supply](https://aave.com/docs#supply)
