# 🟢 CollateralYieldZapper Requirements

## 0. Metadata

| Item | Value |
| --- | --- |
| Status | Draft (`CollateralYieldZapper` / `SkyUsdcSUsdsYieldZapper` / `SkyUsdcSUsdsConverter` / `UniV4Exchange` implementations exist. Flash Loan close / Balancer / Uniswap v3 routes remain outside the Day-1 ABI. Remaining gates are user-app flow adoption, Sky route fork evidence, and production JPYdf/USDC v4 route enablement.) |
| Owner | DeltaForesight |
| Target contracts | Active: `contracts/src/Zappers/CollateralYieldZapper.sol`, `contracts/src/Zappers/Modules/Exchanges/UniV4Exchange.sol`, and `IZapper`. Archived reference: `contracts/src/Zappers/archive/SkyUsdcSUsdsYieldZapper.sol` |
| Related documents | [Product-Overview](../Product-Overview.md) (architecture and responsibility split) / [CollateralVault](CollateralVault.md) (dependency for deposit/redeem/delayed redemption) / [dToken](dToken.md) (dependency for conversion and permit) / [Oracle](Oracle.md) / [Liquity-v2-Core-Spec](Liquity-v2-Core-Spec.md) (BorrowerOperations, etc.) / [Parameters](../../../Parameters.md) |

> This document follows the [requirements specification document standard](../../../README.md#requirements-spec-standard). Requirements, invariants, and security requirements have persistent IDs (`ZAP-...`), and cross-references use those IDs.
>
> 📌 **Requirement provenance**: this contract is a 🟢 new file, but **individual requirements are a mix of Liquity v2 base-derived and DeltaForesight-new**. Each requirement's provenance (**B** = inherited from base / **B+** = base updated / **N** = entirely new) is shown in the §1.5 classification table and the "Provenance" column of the §5 summary table.
>
> 📌 **Implementation sync note (2026-06-19)**: the `CollateralYieldZapper` route in this document is a production UX acceptance condition. Active-branch deploy scripts, manifest, `frontend/df-shared`, and app env bindings are wired, and the Uniswap v4 `IExchange` adapter (`UniV4Exchange`) is included in Day-1 audit scope with unit evidence. Day-1 JPYdf DEX liquidity is limited to JPYdf/USDC Uniswap v4 after JPYdf deploy / issuance per the Japanese source-of-truth [Liquidity-Route-Policy](../policies/Liquidity-Route-Policy.md), and Curve / Balancer are not adopted. Under the fresh-deploy assumption, legacy ABI compatibility is not preserved: Flash Loan close, Balancer adapter, fail-fast exchange placeholder, swap-backed close, collateral-funded repay, and Multiply are removed from production `src` and ABI. If provided later, they must not depend on Balancer or the removed Flash Loan callback and must be added as a new audited entrypoint after route config and fork evidence for the JPYdf/USDC v4 final leg and any asset-specific pre-leg are complete. Current production PASS for `SYS-FR-008` / `FRNT-FR-013` / `FRNT-FR-014` is scoped to open / add / withdraw / close-with-JPYdf / Sky USDC ingress.

---

## 1. Purpose, Scope, and Non-Responsibilities

`CollateralYieldZapper` is a **stateless UX Router** that completes "deposit Underlying (WETH / WBTC / USDC, etc.) and borrow JPYdf / repay and receive Underlying" in **one transaction and in Underlying terms**. It temporarily holds dToken (CollateralVault token) internally and passes it to the core, so users do not need to be aware of dToken at all. It follows the `GasCompZapper` pattern and treats collateral as dToken (18dec ERC-20).

### 1.1 Purpose and Background (Why a Zapper Is Needed)

Liquity v2 `BorrowerOperations.openTrove` pulls collateral from `msg.sender` and mints the base debt token (JPYdf in DF) to `msg.sender`. If the dToken Layer is inserted naively, user operations increase:

- **Original Liquity v2**: 1. collateral approval → 2. collateral transfer & JPYdf borrow (2 steps)
- **Simple dToken implementation**: 1. collateral approval → 2. collateral transfer & dToken receipt → 3. dToken approval → 4. dToken transfer & JPYdf borrow (4 steps)
- **With Zapper**: 1. collateral approval → 2. call Zapper (collateral transfer, dToken receipt, dToken transfer, and JPYdf borrow in one continuous path)

A contract is necessarily required to relay multiple steps, "hold collateral," receive minted JPYdf, and transfer it to the user. Pushing this into the Vault or Liquity core would violate the **zero core modification principle**. `CollateralYieldZapper` is therefore placed as an optional external module to combine **zero core modifications** with good UX.

### 1.2 Scope Specified by This Document (`CollateralYieldZapper` Responsibilities)

- **One-tx Trove operations in Underlying terms**
  - open (`openTroveWithRawETH` / `...AndReferral`), add collateral and adjust borrow/repay (`addCollWithUnderlying` / `adjustTroveWithUnderlying` / `adjustZombieTroveWithUnderlying`), repay (`repayJpydf`), collateral withdrawal (`withdrawCollToUnderlying` / `...WithMin`), borrow withdrawal (`withdrawJpydf`), close (`closeTroveToUnderlying` / `...WithMin`)
- **EIP-2612 Permit support** (no prior approve): `openTroveWithUnderlyingPermit` / `...AndReferral`
- **Removed from the Day-1 ABI**: Flash Loan close / collateral-funded repay / Multiply are not active production scope ([ZAP-FR-011](#zap-fr-011-removed-from-the-day-1-abi-flash-loan-close--collateral-funded-close) / [ZAP-FR-012](#zap-fr-012-removed-from-the-day-1-abi-flash-loan-callback)).
- **Off-chain referralCode tracking**: `ReferralDeposit` event (open flows only)
- **ARCHIVED Sky route variant**: historical candidate-collateral ingress, absent from the official deploy path and active audit scope.

### 1.3 Items Not Specified Here (Non-Responsibilities / Other Documents)

- **Liquity v2 Fork (core)**: behavior of `BorrowerOperations` / `TroveManager` / `TroveNFT` / `JpydfToken` → [Liquity-v2-Core-Spec](Liquity-v2-Core-Spec.md)
- **dToken Layer**: `CollateralVault.deposit` / `redeem` / delayed redemption / claim, dToken conversion and permit body specifications → [CollateralVault](CollateralVault.md) / [dToken](dToken.md)
- **Exchange / route modules**: Day-1 liquidity / route policy is canonical in [Liquidity-Route-Policy](../policies/Liquidity-Route-Policy.md). `UniV4Exchange` is included in Day-1 audit scope as route-adapter evidence for the JPYdf/USDC v4 final leg, but it is not a constructor dependency or user-facing entrypoint of current `CollateralYieldZapper`.
- **Leverage operations**: out of scope for this contract. Day-1 removes leverage callbacks and router interfaces from production `src`; if leverage with dToken collateral becomes necessary, design it as a separate contract ([ZAP-TBD-004](#zap-tbd-004)).
- **Sky LitePSMWrapper route**: `SkyUsdcSUsdsYieldZapper` delegates USDC→USDS conversion to `ISkyUsdcSUsdsConverter`. The concrete adapter binds Sky's official LitePSMWrapper-USDS-USDC immutably and validates fees, halt state, decimals, and balance deltas ([ZAP-TBD-009](#zap-tbd-009)).
- **Collateral-specific parameters** (mintCap / buffer, etc.) finalized values → [Parameters](../../../Parameters.md)

### 1.4 Positioning Among Zapper Contracts

Liquity v2 base has **multiple Zapper contracts** per collateral type (`WETHZapper` = collateral treated as native ETH for WETH, `GasCompZapper` = non-WETH ERC-20 collateral, `LeverageWETHZapper` / `LeverageLSTZapper` = leverage using Flash Loan). They assume collateral ERC-20 is passed **as-is** to `BorrowerOperations` and know nothing about dToken / CollateralVault.

In DeltaForesight, collateral = dToken (18dec ERC-20 across all collateral branches), so `CollateralYieldZapper` adopts the following design decisions (rationale in §2):

- **Follow the `GasCompZapper` pattern**: receive only the ETH amount for gas compensation through `msg.value`; pull collateral as **Underlying ERC-20** through `transferFrom`. Convert pulled Underlying to dToken with `CollateralVault.deposit`, and pass that dToken as collateral to `BorrowerOperations`.
- **Handle all collaterals with one contract**: all collateral is normalized to dToken (18dec ERC-20), so a separate contract per collateral type like `WETHZapper` is unnecessary. Pulling an ERC-20 Underlying and converting it to a dToken is the default path on every branch, and `msg.value` is dedicated to gas compensation. The single exception is the dwstETH branch's native-ETH on-ramp ([ZAP-FR-015](#zap-fr-015-native-eth-on-ramp-ethstethwstethdwsteth)), which exists only on instances where it was explicitly enabled at deployment.
- **Inherit `BaseZapper` for shared safety mechanisms**: inherit `AddRemoveManagers` (owner / add manager / remove manager and receiver permission checks) and `LeftoversSweep` (leftover return) directly from the Liquity v2 base, minimizing custom implementation.
- **Leverage / Flash Loan close are out of scope**: the Day-1 leverage callback / router surface and Flash Loan close surface are removed from production `src` / ABI. If needed later, add them as a separately audited entrypoint / contract with route config and fork evidence.

The upstream-derived `WETHZapper` / `GasCompZapper` / `LeverageWETHZapper` / `LeverageLSTZapper` contracts and `ILeverageZapper` interface have been removed from production `contracts/src`. DF's only user-facing production target is `CollateralYieldZapper`; `SkyUsdcSUsdsYieldZapper` is an archived candidate-ingress variant (reactivation requires an activation package and Owner approval). Native-ETH collateral and leverage UI are not provided.

**Positioning of the Sky route variant**: all Sky-ingress requirements below, including ZAP-FR-014 and ZAP-INV-009, describe archived source. They are not Day-1 requirements or activation approval. Reactivation requires Owner approval, implementation review, and an additional-audit decision.

### 1.5 Requirement Provenance (Base-inherited / Base-updated / Entirely new)

This contract is a 🟢 new file, but **individual requirements differ in provenance**. Using the upstream Liquity v2 base `IZapper` normative interface and the `GasCompZapper` pattern (the non-WETH ERC-20 collateral Zapper that DF follows) as the baseline, each requirement is classified with the markers below (cross-referenced with the "Provenance" column of the §5 summary table).

- **B (Base-inherited)**: an equivalent function exists upstream and is inherited almost as-is (signature/behavior essentially identical).
- **B+ (Base-updated)**: an equivalent function exists upstream, but is modified for collateral = dToken (e.g., inserting Underlying↔dToken conversion).
- **N (Entirely new)**: a DeltaForesight-original requirement with no upstream counterpart.

| Requirement | Provenance | Note (diff vs base) |
| --- | :---: | --- |
| ZAP-FR-001 `openTroveWithRawETH` | B+ | `IZapper` normative. Pulls collateral as Underlying → `deposit` → dToken (base pulls the real collateral directly) |
| ZAP-FR-002 `…AndReferral` | B+／N | open is base-derived; the `…AndReferral` suffix + `ReferralDeposit` is new |
| ZAP-FR-003/004 `openTroveWithUnderlyingPermit(…)` | N | upstream non-WETH/WETH Zappers have no permit-open |
| ZAP-FR-005 `addCollWithUnderlying` | B+ | base `addColl` updated to Underlying→dToken |
| ZAP-FR-006 `withdrawCollToUnderlying` / `...WithMin` | B+ | base `withdrawColl` updated to dToken→Underlying redeem, with a DF-added received-Underlying lower bound |
| ZAP-FR-007 `withdrawJpydf` | B+ | base `withdrawBold` renamed to JPYdf terminology; behavior remains base-shaped |
| ZAP-FR-008 `repayJpydf` | B+ | base `repayBold` renamed to JPYdf terminology; `_returnLeftovers` is base-derived |
| ZAP-FR-009 `adjustTroveWithUnderlying` / `adjustZombieTroveWithUnderlying` | N | upstream non-WETH/WETH Zappers have no combined adjust wrapper. Wraps core `adjustTrove` / `adjustZombieTrove` in Underlying terms, with DF-added `...WithMin` variants |
| ZAP-FR-010 `closeTroveToUnderlying` / `...WithMin` | B+ | base `closeTroveToRawETH` updated to dToken→Underlying redeem + gasComp, with a DF-added received-Underlying lower bound |
| ZAP-FR-011 `closeTroveFromCollateral` | Deferred | Removed from the Day-1 production ABI under the fresh-deploy policy. If added later, redesign it as a new audited entrypoint |
| ZAP-FR-012 close-from-coll callback | Deferred | Removed from the Day-1 production ABI with Flash Loan close. No callback surface exists in the current implementation |
| ZAP-FR-013 `receive` | B+ | allows only ETH received from gas-compensation `WETH.withdraw`; old leverage callback surface is removed |
| ZAP-FR-014 Sky USDC route | N | via `SkyUsdcSUsdsYieldZapper` / `ISkyUsdcSUsdsConverter`. No upstream counterpart |
| ZAP-FR-015 native ETH on-ramp | N | upstream `WETHZapper` treats ETH as the collateral itself; this route converts ETH to stETH then wstETH and rejoins the existing dToken path. Enabling it is a deployment parameter, which also has no upstream counterpart |

> Non-functional provenance: structural items (`BaseZapper`/`AddRemoveManagers`/`LeftoversSweep` inheritance, stateless/immutable = ZAP-INV-001, `nonReentrant` = ZAP-SEC-001, manager/receiver consistency = ZAP-SEC-002, leftover return = ZAP-SEC-003/ZAP-INV-003, gasComp transfer check = ZAP-SEC-007) are **B (base-derived)**. dToken relay (`collToken==dToken` = ZAP-INV-002), referral (ZAP-EVT-001/ZAP-INV-005/ZAP-GOV-003), and Sky (ZAP-INV-009, `minUsdsOut`/`minSUsdsOut` in ZAP-SEC-005) are **N (new)**. Flash Loan callback caller verification (old ZAP-SEC-004) is treated as absence of the removed Day-1 ABI surface.

---

## 2. Background and Design Policy

`CollateralYieldZapper` is an **optional module for UX improvement** and follows the principles below. The `GasCompZapper` pattern is **followed** because collateral is normalized to dToken (18dec ERC-20), which makes the non-WETH ERC-20 collateral shape (`msg.value` only for gas comp + ERC-20 pull) work with minimal changes.

- **Call core, Vault, and dToken "in sequence," without changing the owner of state and responsibilities**.
- Liquity v2 core does not know the Zapper (no hooks or special handling in core).
- dToken Layer does not know the Zapper (uses generic CollateralVault interfaces as-is: `deposit(amount)` / `redeem(amount, receiver)` / `redeemWithPermit(...)`; no Zapper-specific signatures are added to Vault, following the "No Router" policy).
- referralCode is not passed to Vault / Liquity core. It is kept inside the Zapper and emitted as an event for off-chain tracking only ([ZAP-EVT-001](#zap-evt-001-referraldeposit)).
- The design rationale for referral instrumentation type, payload, and indexing is maintained in this document (the Zapper is immutable / non-upgradeable, so function signatures and event ABI cannot change after deploy; the referral surface is frozen before Day-1).
- **The Zapper itself holds no persistent protocol-configuration or accounting state** (returns tokens to user every tx; route / core references are fixed in the constructor. Mutable storage is limited to the `ReentrancyGuard` transient lock and the per-trove delegation authorizations inherited from `AddRemoveManagers`; [ZAP-INV-001](#8-invariants-inv)).
- All user-facing external state-changing functions that move value or make untrusted external calls are protected with `nonReentrant` (the three `AddRemoveManagers`-inherited manager setters are explicit exceptions). The Day-1 ABI has no Flash Loan callback, so there is no callback-specific non-`nonReentrant` exception ([ZAP-SEC-001](#zap-sec-001-nonreentrant-for-user-facing-external-state-changing-functions) / [ZAP-SEC-004](#zap-sec-004-no-flash-loan-callback-in-the-day-1-abi)).

#### Three Roles Performed by CollateralYieldZapper

1. **Hide dToken from users** — dToken is an intermediate protocol token used to normalize collateral to 18 decimals and manage yield behind the scenes. It is only a 1:1 claim token and has no standalone yield for the user. Users should only need the mental model "deposit Underlying and borrow JPYdf / repay and receive Underlying." This avoids confusion from unfamiliar dWETH / dWBTC appearing in wallets / explorers / accounting tools, phishing or operational mistakes through dToken approval, and misunderstandings in tax or portfolio displays. The Zapper temporarily holds dToken and passes it directly to Liquity core, so users do not need to hold or handle it directly.
2. **Provide one-tx continuous execution** — compress the 4-step simple dToken flow in §1.1 into 2 steps and provide an experience comparable to original Liquity v2. With EIP-2612 Permit-compatible Underlying (USDC, etc.), approval can also be executed in the same transaction, achieving **fully one-tx operation**.
3. **Make inflow source (referral) trackable on-chain** — identify traffic channels such as KOLs, wallet partners, and aggregators on-chain, enabling revenue-share designs. Because referralCode is **off-chain aggregation metadata** that does not affect smart-contract accounting logic, it is not passed to Vault / Liquity core (keeps Vault API surface small and preserves zero core modification). The Zapper emits `ReferralDeposit` only on openTrove flows.

> The basic principle of responsibility separation is canonically defined in [Product Overview](../Product-Overview.md).

---

## 3. Terms, External Dependencies, and Assumptions

**Terms**

| Term | Meaning |
| --- | --- |
| Underlying | Real collateral asset users deposit/withdraw (WETH / WBTC / USDC, etc.). All Zapper inputs and outputs are Underlying-denominated |
| dToken | 1:1 claim token that normalizes Underlying to 18 decimals. Collateral from the core's perspective (`collToken == dToken`). The Zapper temporarily holds it and passes it to the core |
| collToken | Collateral token from the core's perspective (= ERC-20 view of dToken). `collToken == dToken` |
| gas compensation | Liquidation compensation locked for each Trove in `ETH_GAS_COMPENSATION` (WETH-denominated). Separate from collateral |
| referralCode | Off-chain metadata for identifying acquisition channel (`bytes32`). Does not affect accounting. `bytes32(0)` means no referral |
| receiver | Address receiving output tokens from Trove operations. The Zapper temporarily becomes receiver and ultimately delegates to endUser |
| stateless | Property of holding no persistent protocol-configuration or accounting state and returning balances to user every tx (mutable storage is limited to the `ReentrancyGuard` lock and the `AddRemoveManagers` delegation authorizations = [ZAP-INV-001](#8-invariants-inv)) |

**External dependencies (trusted externals)**

External interfaces called by `CollateralYieldZapper` are specified below. The canonical body specification for each interface is in the referenced document. Approval targets are limited to trusted components by [ZAP-SEC-006](#zap-sec-006-approval-targets-limited-to-trusted-components).

| Dependency | Functions used (normative interface) | Reference |
| --- | --- | --- |
| **CollateralVault** | `deposit(uint256 _underlyingAmount) returns (uint256 dTokenAmount)` | [CollateralVault requirements](CollateralVault.md) |
| | `redeem(uint256 _dTokenAmount, address _receiver) returns (uint256 underlyingReceived, uint256 requestId)` | [CollateralVault requirements](CollateralVault.md) |
| **dToken** | `convertToDToken(uint256 underlyingAmount) returns (uint256)` (Underlying→18dec, multiplication, exact) | [DTKN-FR-003](dToken.md) |
| | `convertToUnderlying(uint256 dTokenAmount) returns (uint256)` (18dec→Underlying, floor) | [DTKN-FR-003](dToken.md) |
| **BorrowerOperations** | `openTrove` / `openTroveAndJoinInterestBatchManager` / `addColl` / `withdrawColl` / `withdrawJpydf` / `repayJpydf` / `adjustTrove` / `adjustZombieTrove` / `closeTrove` / `removeManagerReceiverOf` | [Liquity-v2-Core-Spec](Liquity-v2-Core-Spec.md) |
| **TroveManager** | `getLatestTroveData(troveId)` / **TroveNFT** `ownerOf(troveId)` | [Liquity-v2-Core-Spec](Liquity-v2-Core-Spec.md) |
| **JpydfToken** | `transfer` / `transferFrom` | [JpydfToken](JpydfToken.md) |
| **Exchange / route adapter** | `UniV4Exchange` is included in Day-1 audit scope as route-adapter evidence for the JPYdf/USDC Uniswap v4 final leg. Current `CollateralYieldZapper` has no Exchange constructor dependency and no swap-backed close / collateral-funded repay / Multiply user-facing entrypoint. The only production-reviewed JPYdf final leg is JPYdf/USDC Uniswap v4. Curve, Uniswap v3 routes, and direct USDT/USDS/WETH/XAUT JPYdf pools are out of scope. v4 production wiring is handled after the [ZAP-TBD-010](#zap-tbd-010) route config and evidence gate, as a new audited entrypoint. | [Product Overview](../Product-Overview.md) / [Japanese Liquidity-Route-Policy](../policies/Liquidity-Route-Policy.md) |
| **AddressesRegistry** | `collToken()` / `borrowerOperations()` / `troveManager()` / `jpydfToken()` / `WETH()` | Liquity v2 base-derived Registry (no additional getters required) |
| **Sky USDC→USDS Adapter** | `convertUsdcToUsds(usdcAmount, minUsdsOut, receiver) returns (usdsOut)` | `ISkyUsdcSUsdsConverter` (`SkyUsdcSUsdsConverter` is the concrete implementation) |
| **sUSDS ERC4626 Vault** | `asset()` / `deposit(assets, receiver)` | ERC4626. Assert `asset() == USDS` in constructor |

**Adapter / helper surface treatment**:

- Any sqrt price calculation required for pool initialization belongs in off-chain / script tooling. The production `UniV4Exchange` ABI does not expose auxiliary read-only helpers.
- `UniV4Exchange.swapFromJpydf(jpydfAmount, minCollAmount)` is a v4 single-pool
  **exact-output** call. `minCollAmount` is both the lower bound and the target
  collToken amount passed to the router. `jpydfAmount` is the maximum input, and
  unused JPYdf is returned to the caller.
- `UniV4Exchange.swapToJpydf(collAmount, minJpydfAmount)` is a v4 single-pool
  **exact-input** call. The adapter spends the specified collToken amount and
  reverts if actual JPYdf received is below `minJpydfAmount`.
- v4 action / command calldata is generated by the adapter. It does not accept
  user supplied calldata, and `TAKE_ALL` receives to Universal Router
  `msgSender()` (the `UniV4Exchange` caller from the router's perspective).

> 📌 **Registry non-extension policy**: do not add `collateralVault()` / `dToken()` / `underlyingToken()` to `AddressesRegistry`. Zapper-specific `collateralVault` / `underlyingToken` are constructor arguments to `CollateralYieldZapper`, and `dToken` is derived from existing `AddressesRegistry.collToken()` (= core collateral). This aligns with the Retrospective guardrail "do not inject vault/dToken/underlying into AddressesRegistry." Deployment asserts `collToken == dToken`, `vault.underlying() == underlyingToken`, and CYZ `borrowerOperations` / `jpydfToken` bindings ([ZAP-TBD-003](#zap-tbd-003)).

**Assumptions**

- There is no reverse dependency (Vault / Liquity core / dToken do not reference Zapper).
- referralCode is not passed to Vault (Vault has no referral concept). `ReferralDeposit` is emitted only on open flows through Zapper ([ZAP-EVT-001](#zap-evt-001-referraldeposit)).
- EIP-2612 Permit can be used only with permit-compatible Underlying (USDC, etc.). Non-compatible tokens use the prior-approve path ([ZAP-FR-004](#zap-fr-004-opentrovewithunderlyingpermitandreferral-permit-open--referral) / [ZAP-TBD-006](#zap-tbd-006)).

---

## 4. Actors, Roles, and Trust Boundaries

| Actor | Operation | Trust boundary |
| --- | --- | --- |
| **endUser (Trove owner)** | Calls open / addColl / withdrawColl / adjust / repay / withdrawJpydf / close in Underlying terms | Only their own Trove. Manager / receiver consistency (`AddRemoveManagers`) prevents operating on another user's Trove ([ZAP-SEC-002](#zap-sec-002-beneficiary-and-executor-consistency-managerreceiver)) |
| **add manager / remove manager** | Delegated by owner for add-collateral/repay (add) or withdraw-collateral/borrow/close (remove) operations | Checked by shared `BaseZapper` (`AddRemoveManagers`) functions |
| **Zapper itself** | Temporarily becomes add/remove manager and receiver for a Trove and temporarily holds dToken / JPYdf | Stateless. Returns leftovers to user every tx ([ZAP-SEC-003](#zap-sec-003-leftover-return-and-avoidance-of-stuck-funds)). Finally delegates to user-specified manager / receiver |

- **Invariant owner of authority**: the Zapper only calls components in sequence. It does not change the owner of state or responsibility (collateral owner = Trove owner; debtor = Trove owner).
- **No upgrade authority**: the Zapper is non-upgradeable (`immutable` references, no proxy) and holds no protocol-configuration state ([ZAP-GOV-002](#zap-gov-002-stateless--non-upgradeable)). If replacement is required, deploy a new contract and switch frontend / deployment configuration references.

---

## 5. Interface Specification

Normative interface `IZapper` (from Liquity v2 base) + DeltaForesight extensions. Behavior is specified in §6 Functional Requirements; visibility is summarized below (non-normative). As a shared rule, **borrowed JPYdf is first received by the Zapper and then transferred to the user (or specified receiver)** because `BorrowerOperations` mints to `msg.sender = Zapper`.

| Function | Visibility | Provenance | Summary | Normative requirement |
| --- | --- | :---: | --- | --- |
| `openTroveWithRawETH(OpenTroveParams) → troveId` | external payable | B+ | open (delegates to referral=`bytes32(0)`) | ZAP-FR-001 |
| `openTroveWithRawETHAndReferral(OpenTroveParams, bytes32) → troveId` | external payable nonReentrant | B+／N | open + referral | ZAP-FR-002 |
| `openTroveWithUnderlyingPermit(OpenTroveParams, deadline, v, r, s) → troveId` | external payable | N | permit open (delegates to referral=`bytes32(0)`) | ZAP-FR-003 |
| `openTroveWithUnderlyingPermitAndReferral(OpenTroveParams, deadline, v, r, s, bytes32) → troveId` | external payable nonReentrant | N | permit open + referral | ZAP-FR-004 |
| `addCollWithUnderlying(troveId, underlyingAmount)` | external nonReentrant | B+ | add collateral (Underlying-denominated) | ZAP-FR-005 |
| `withdrawCollToUnderlying(troveId, dTokenAmount) → (underlyingReceived, requestId)` | external nonReentrant | B+ | withdraw collateral (receive Underlying) | ZAP-FR-006 |
| `withdrawCollToUnderlyingWithMin(troveId, dTokenAmount, minUnderlyingReceived) → (underlyingReceived, requestId)` | external nonReentrant | N | withdraw collateral with received-Underlying lower bound | ZAP-FR-006 |
| `withdrawJpydf(troveId, jpydfAmount, maxUpfrontFee)` | external nonReentrant | B+ | increase borrow | ZAP-FR-007 |
| `repayJpydf(troveId, jpydfAmount)` | external nonReentrant | B+ | repay | ZAP-FR-008 |
| `adjustTroveWithUnderlying(troveId, underlyingChange, isCollIncrease, jpydfChange, isDebtIncrease, maxUpfrontFee) → (dTokenChange, underlyingReceived, requestId)` | external nonReentrant | N | adjust collateral and debt together | ZAP-FR-009 |
| `adjustTroveWithUnderlyingWithMin(troveId, underlyingChange, isCollIncrease, jpydfChange, isDebtIncrease, maxUpfrontFee, minUnderlyingReceived) → (dTokenChange, underlyingReceived, requestId)` | external nonReentrant | N | adjust collateral and debt together with lower bound | ZAP-FR-009 |
| `adjustZombieTroveWithUnderlying(troveId, underlyingChange, isCollIncrease, jpydfChange, isDebtIncrease, upperHint, lowerHint, maxUpfrontFee) → (dTokenChange, underlyingReceived, requestId)` | external nonReentrant | N | adjust zombie Trove | ZAP-FR-009 |
| `adjustZombieTroveWithUnderlyingWithMin(troveId, underlyingChange, isCollIncrease, jpydfChange, isDebtIncrease, upperHint, lowerHint, maxUpfrontFee, minUnderlyingReceived) → (dTokenChange, underlyingReceived, requestId)` | external nonReentrant | N | adjust zombie Trove with lower bound | ZAP-FR-009 |
| `closeTroveToUnderlying(troveId) → (underlyingReceived, requestId)` | external nonReentrant | B+ | close (user holds JPYdf) | ZAP-FR-010 |
| `closeTroveToUnderlyingWithMin(troveId, minUnderlyingReceived) → (underlyingReceived, requestId)` | external nonReentrant | N | close with received-Underlying lower bound | ZAP-FR-010 |
| `receive()` | external payable | B (IF) | Allows ETH receipt only from `WETH.withdraw` | ZAP-FR-013 |
| `openTroveWithUsdc(OpenTroveParams, minUsdsOut, minSUsdsOut) → troveId` | external payable nonReentrant | N | Sky route open (USDC→USDS→sUSDS→dUSDS) | ZAP-FR-014 |
| `openTroveWithUsdcAndReferral(OpenTroveParams, minUsdsOut, minSUsdsOut, referralCode) → troveId` | external payable nonReentrant | N | Sky route open + referral | ZAP-FR-014 |
| `addCollWithUsdc(troveId, usdcAmount, minUsdsOut, minSUsdsOut)` | external nonReentrant | N | Sky route add collateral | ZAP-FR-014 |
| `lidoReferral() → address`                                                                                                                                                                                                   | public view                   |     N      | Protocol-designated referral passed to Lido `submit` by the native-ETH route (updatable only by the Timelock) | ZAP-FR-015            |
| `openTroveWithNativeEth(OpenTroveParams, minWstEthOut) → troveId` | external payable nonReentrant | N | native ETH route open (ETH→stETH→wstETH→dwstETH) | ZAP-FR-015 |
| `openTroveWithNativeEthAndReferral(OpenTroveParams, minWstEthOut, referralCode) → troveId` | external payable nonReentrant | N | native ETH route open + referral | ZAP-FR-015 |

---

## 6. Functional Requirements (FR)

### ZAP-FR-001: openTroveWithRawETH (delegation to open)

- **Type**: Functional | **Source**: Product-Overview "Zapper (UX Router)" / `IZapper` normative interface
- **Signature**: `openTroveWithRawETH(OpenTroveParams _params) payable returns (uint256 troveId)`
- **Purpose**: Override the function name required by `IZapper` and delegate to `openTroveWithRawETHAndReferral(_params, bytes32(0))` (referralCode = `bytes32(0)`).
- **Permission**: permissionless (actual permissions and manager setup are performed by [ZAP-FR-002](#zap-fr-002-opentrovewithrawethandreferral-open--referral)).
- **Preconditions / Checks**: follows delegated function.
- **Behavior / Effects**: call `openTroveWithRawETHAndReferral(_params, bytes32(0))` and return `troveId`.
- **Reverts / early returns**: follows delegated function ([ZAP-FR-002](#zap-fr-002-opentrovewithrawethandreferral-open--referral)).
- **Emitted event**: none (`ReferralDeposit` is also not emitted because referral=`bytes32(0)`).
- **Design notes**: provides a no-referral standard entrypoint so existing wallets / SDKs can call the `IZapper` standard name.
- **Verification**: unit (returns the same troveId as the delegated function).

### ZAP-FR-002: openTroveWithRawETHAndReferral (open + referral)

- **Type**: Functional | **Source**: Product-Overview "Zapper / referral" / §1.1 flow compression
- **Signature**: `openTroveWithRawETHAndReferral(OpenTroveParams _params, bytes32 _referralCode) payable nonReentrant returns (uint256 troveId)`
- **Purpose**: One-tx entrypoint that pulls Underlying → converts to dToken → opens a Trove using it as core collateral → transfers minted JPYdf to the user. It does not receive ETH as collateral; it receives exactly the gas compensation amount as ETH.
- **Permission**: permissionless (Trove is created with `msg.sender` as owner. Internally the Zapper is temporarily made manager, then delegates to user-specified manager / receiver at the end).
- **Preconditions / Checks**:
  - `msg.value == ETH_GAS_COMPENSATION` (collateral ETH is not accepted)
  - batch consistency: `_params.batchManager == address(0) || _params.annualInterestRate == 0`
  - Caller has approval / balance allowing the Zapper to pull `_params.collAmount` of `underlyingToken`
- **Behavior / Effects**:
  1. `WETH.deposit{value: msg.value}()` — wrap received ETH as WETH (gas compensation source)
  2. Execute shared internal `_openTroveWithUnderlying(_params, _referralCode)` (steps a-g below)
  - **Steps inside `_openTroveWithUnderlying`**:
    - a. `underlyingToken.safeTransferFrom(msg.sender, address(this), _params.collAmount)` — pull Underlying (`collAmount` is **Underlying-denominated**)
    - b. `dTokenAmount = collateralVault.deposit(_params.collAmount)` — convert Underlying to dToken (dToken minted to Zapper)
    - c. `index = _getTroveIndex(_params.ownerIndex)` — include `msg.sender` in the index (required for troveId derivation)
    - d. `borrowerOperations.openTrove(owner, index, dTokenAmount, jpydfAmount, ..., addManager=address(this), removeManager=address(this), receiver=address(this))` creates the Trove with user as owner (Zapper holds the dToken collateral). If `batchManager != 0`, use `openTroveAndJoinInterestBatchManager`
    - e. `jpydfToken.transfer(msg.sender, _params.jpydfAmount)` — transfer minted JPYdf to user
    - f. `_setAddManager` / `_setRemoveManagerAndReceiver` reset to the **user-specified** manager / receiver (delegate away from the temporary Zapper manager)
    - g. If `_referralCode != bytes32(0)`, emit `ReferralDeposit(msg.sender, troveId, collAmount, dTokenAmount, jpydfAmount, referralCode)` ([ZAP-EVT-001](#zap-evt-001-referraldeposit))
- **Reverts / early returns**: `msg.value != ETH_GAS_COMPENSATION`; batch inconsistency; insufficient approval / balance for `collAmount`; `CollateralVault.deposit` cap exceeded or Underlying unset (`TokenInfoNotSet`); `jpydfAmount` below MIN_DEBT (values in [Parameters.md](../../../Parameters.md), 🔵 checks in [Liquity-v2-Core-Spec.md](Liquity-v2-Core-Spec.md)), etc.
- **Emitted event**: `ReferralDeposit` only when `_referralCode != bytes32(0)` ([ZAP-EVT-001](#zap-evt-001-referraldeposit)). Core-side open events are defined in [Liquity-v2-Core-Spec](Liquity-v2-Core-Spec.md).
- **Design notes**:
  - **This FR does not receive native ETH collateral**: collateral is always pulled as ERC-20 `underlyingToken` and `msg.value` is dedicated to gas compensation. Where WETH is the Underlying the user approves/transfers WETH (ERC-20), and for users holding only native ETH the frontend inserts a prior `WETH.deposit`. The only payable collateral entrypoint is the dwstETH branch's on-ramp ([ZAP-FR-015](#zap-fr-015-native-eth-on-ramp-ethstethwstethdwsteth)); none is added to this path ([ZAP-TBD-005](#zap-tbd-005)).
  - **Zero leftovers**: open flow has no leftovers because all dToken returned by `deposit` is pulled by `openTrove`, and all minted JPYdf is transferred to user. `_returnLeftovers` is therefore unnecessary ([ZAP-INV-004](#8-invariants-inv)).
- **Verification**: unit (strict `msg.value`, batch consistency, referral emission condition), integration (Underlying→dToken→openTrove→JPYdf transfer end-to-end; zero leftovers).

### ZAP-FR-003: openTroveWithUnderlyingPermit (delegation to permit open)

- **Type**: Functional | **Source**: §1.1 "fully one-tx" / [DTKN-FR-007](dToken.md) (permit dependency)
- **Signature**: `openTroveWithUnderlyingPermit(OpenTroveParams _params, uint256 _deadline, uint8 _v, bytes32 _r, bytes32 _s) payable returns (uint256)`
- **Purpose**: Delegate to `openTroveWithUnderlyingPermitAndReferral(_params, _deadline, _v, _r, _s, bytes32(0))` (referralCode = `bytes32(0)`).
- **Permission**: permissionless (actual behavior is delegated to [ZAP-FR-004](#zap-fr-004-opentrovewithunderlyingpermitandreferral-permit-open--referral)).
- **Preconditions / Checks**: follows delegated function.
- **Behavior / Effects**: call delegated function and return its value.
- **Reverts / early returns**: follows delegated function.
- **Emitted event**: none (referral=`bytes32(0)`).
- **Design notes**: provides a standard no-referral entrypoint for permit route as well.
- **Verification**: unit (same return value as delegated function).

### ZAP-FR-004: openTroveWithUnderlyingPermitAndReferral (permit open + referral)

- **Type**: Functional | **Source**: §1.1 "fully one-tx" / [DTKN-FR-007](dToken.md) permit path
- **Signature**: `openTroveWithUnderlyingPermitAndReferral(OpenTroveParams _params, uint256 _deadline, uint8 _v, bytes32 _r, bytes32 _s, bytes32 _referralCode) payable nonReentrant returns (uint256)`
- **Purpose**: Same as [ZAP-FR-002](#zap-fr-002-opentrovewithrawethandreferral-open--referral), but executes **EIP-2612 permit** before pulling Underlying, removing the need for prior Underlying approval (fully one-tx).
- **Permission**: permissionless (Trove owner = `msg.sender`).
- **Preconditions / Checks**:
  - `msg.value == ETH_GAS_COMPENSATION`; batch consistency (same as [ZAP-FR-002](#zap-fr-002-opentrovewithrawethandreferral-open--referral))
  - `underlyingToken` supports EIP-2612 permit (assumption)
- **Behavior / Effects**:
  1. Execute `IERC20Permit(underlyingToken).permit(msg.sender, address(this), _params.collAmount, _deadline, _v, _r, _s)` in `try/catch` (on failure, revert with `CollateralYieldZapper__PermitFailed`)
  2. `WETH.deposit{value: msg.value}()`
  3. `_openTroveWithUnderlying(_params, _referralCode)` (same steps a-g as [ZAP-FR-002](#zap-fr-002-opentrovewithrawethandreferral-open--referral))
- **Reverts / early returns**: `msg.value` mismatch; batch inconsistency; permit failure (`CollateralYieldZapper__PermitFailed`); after that, same as [ZAP-FR-002](#zap-fr-002-opentrovewithrawethandreferral-open--referral).
- **Emitted event**: `ReferralDeposit` when `_referralCode != bytes32(0)` ([ZAP-EVT-001](#zap-evt-001-referraldeposit)).
- **Design notes / cautions**:
  - For non-permit Underlying (token without `permit`, or mistakenly specified EOA), `try/catch` may not catch ABI decode failure / no-code call and may revert. Permit route assumes EIP-2612-compatible Underlying (USDC, etc.); non-compatible tokens use [ZAP-FR-001](#zap-fr-001-opentrovewithraweth-delegation-to-open) (prior-approve path) ([ZAP-TBD-006](#zap-tbd-006)).
- **Verification**: unit (permit success opens without prior approval; permit failure reverts), integration (fully one-tx with permit-compatible Underlying).

### ZAP-FR-005: addCollWithUnderlying (add collateral, Underlying-denominated)

- **Type**: Functional | **Source**: §1.2 collateral operation
- **Signature**: `addCollWithUnderlying(uint256 _troveId, uint256 _underlyingAmount) nonReentrant`
- **Purpose**: Add collateral to an existing Trove in Underlying terms.
- **Permission**: owner or add manager only (checked by `AddRemoveManagers`; [ZAP-SEC-002](#zap-sec-002-beneficiary-and-executor-consistency-managerreceiver)).
- **Preconditions / Checks**: caller is owner / add manager; `_underlyingAmount` can be pulled from `underlyingToken`.
- **Behavior / Effects**:
  1. Pull `underlyingToken`
  2. Convert to dToken through `collateralVault.deposit`
  3. Call `borrowerOperations.addColl(_troveId, dTokenAmount)`
- **Reverts / early returns**: unauthorized; pull failure; `deposit` cap exceeded / unset.
- **Emitted event**: none (core-side `addColl` events are in [Liquity-v2-Core-Spec](Liquity-v2-Core-Spec.md)).
- **Design notes**: adding collateral has no output token, so no leftovers arise.
- **Verification**: unit (owner/add manager only), integration (Underlying→dToken→addColl).

### ZAP-FR-006: withdrawCollToUnderlying (withdraw collateral and receive Underlying)

- **Type**: Functional | **Source**: §1.2 collateral operation
- **Signatures**:
  - `withdrawCollToUnderlying(uint256 _troveId, uint256 _dTokenAmount) nonReentrant returns (uint256 underlyingReceived, uint256 requestId)`
  - `withdrawCollToUnderlyingWithMin(uint256 _troveId, uint256 _dTokenAmount, uint256 _minUnderlyingReceived) nonReentrant returns (uint256 underlyingReceived, uint256 requestId)`
- **Purpose**: Withdraw collateral dToken from a Trove, exchange it to Underlying, and deliver it to endUser.
- **Permission**: owner or remove manager only (receiver is obtained).
- **Preconditions / Checks**: `_requireZapperIsReceiver` confirms that the Zapper is the receiver for this Trove ([ZAP-SEC-002](#zap-sec-002-beneficiary-and-executor-consistency-managerreceiver)).
- **Behavior / Effects**:
  1. `borrowerOperations.withdrawColl(_troveId, _dTokenAmount)` withdraws dToken to the Zapper
  2. `_redeemDTokenToUnderlying` computes `redeemable = convertToDToken(convertToUnderlying(_dTokenAmount))` and `dust = _dTokenAmount - redeemable`. It calls `collateralVault.redeem(redeemable, receiver)` only when `redeemable > 0`, and returns any `dust` to the receiver as dToken.
  3. `WithMin` reverts the entire operation when immediate `underlyingReceived`—the receiver's actual Underlying balance increase after the Vault transfer, excluding queued value and dToken dust—is below `_minUnderlyingReceived`. This remains true for fee-on-transfer Underlying. The non-`WithMin` entrypoint uses zero. If `redeemable == 0`, the Vault call is skipped and the whole amount is returned as dToken dust only when the minimum is zero.
- **Reverts / early returns**: unauthorized; Zapper is not receiver.
- **Emitted event**: none. Delayed redemption tracking uses Vault `WithdrawRequested` as in §7.2 ([CollateralVault requirements](CollateralVault.md)).
- **Design notes**: `_dTokenAmount` is **dToken-denominated**. If the frontend wants to specify Underlying terms, it converts with [DTKN-FR-003](dToken.md) `convertToDToken`. Amounts below one Underlying base unit are returned as dToken instead of discarded, preserving the Vault exact-conversion guard for 6/8-decimal assets. Dust is returned in the same transaction even when the redeemable remainder is queued. `requestId` is not re-emitted ([ZAP-TBD-001](#zap-tbd-001)).
- **Verification**: unit (owner/remove manager, receiver, receiver-balance lower bound including fee-on-transfer Underlying, 6/8/18 decimals, only-dust, and queued+dust), integration (withdrawColl→redeem).

### ZAP-FR-007: withdrawJpydf (increase borrow)

- **Type**: Functional | **Source**: §1.2 debt operation
- **Signature**: `withdrawJpydf(uint256 _troveId, uint256 _jpydfAmount, uint256 _maxUpfrontFee) nonReentrant`
- **Purpose**: Borrow additional JPYdf from an existing Trove and send it to receiver.
- **Permission**: owner or remove manager only (Zapper must be receiver).
- **Preconditions / Checks**: authorization; `_requireZapperIsReceiver`.
- **Behavior / Effects**:
  1. `borrowerOperations.withdrawJpydf(_troveId, _jpydfAmount, _maxUpfrontFee)`
  2. `jpydfToken.transfer(receiver, _jpydfAmount)`
- **Reverts / early returns**: unauthorized; Zapper is not receiver; `_maxUpfrontFee` exceeded (🔵 core).
- **Emitted event**: none (core-side).
- **Design notes**: borrowed amount is transferred directly to receiver and not left in Zapper.
- **Verification**: unit (authorization and receiver checks), integration (withdrawJpydf→transfer).

### ZAP-FR-008: repayJpydf (repay)

- **Type**: Functional | **Source**: §1.2 debt operation
- **Signature**: `repayJpydf(uint256 _troveId, uint256 _jpydfAmount) nonReentrant`
- **Purpose**: Pull JPYdf, repay an existing Trove, and return excess to user.
- **Permission**: owner or add manager only.
- **Preconditions / Checks**: authorization; `_jpydfAmount` can be pulled from `jpydfToken`.
- **Behavior / Effects**:
  1. Record balance baseline with `_setInitialTokensAndBalances(collToken, jpydfToken)` ([ZAP-SEC-003](#zap-sec-003-leftover-return-and-avoidance-of-stuck-funds))
  2. Pull JPYdf with `jpydfToken.transferFrom(msg.sender, this, _jpydfAmount)`
  3. Call `borrowerOperations.repayJpydf(_troveId, _jpydfAmount)`
  4. Return excess repayment amount (unspent JPYdf, etc.) to user with `_returnLeftovers`
- **Reverts / early returns**: unauthorized; pull failure.
- **Emitted event**: none (core-side).
- **Design notes**: even if the core rounds the repayment amount, `_returnLeftovers` returns leftovers reliably (zero stuck Zapper balance; [ZAP-INV-003](#8-invariants-inv)).
- **Verification**: unit (add manager only, excess repayment leftovers returned), integration.

### ZAP-FR-009: adjustTroveWithUnderlying (adjust collateral and debt together)

- **Type**: Functional | **Source**: §1.2 Trove adjustment
- **Signatures**:
  - `adjustTroveWithUnderlying(uint256 _troveId, uint256 _underlyingChange, bool _isCollIncrease, uint256 _jpydfChange, bool _isDebtIncrease, uint256 _maxUpfrontFee) nonReentrant returns (uint256 dTokenChange, uint256 underlyingReceived, uint256 requestId)`
  - `adjustTroveWithUnderlyingWithMin(uint256 _troveId, uint256 _underlyingChange, bool _isCollIncrease, uint256 _jpydfChange, bool _isDebtIncrease, uint256 _maxUpfrontFee, uint256 _minUnderlyingReceived) nonReentrant returns (uint256 dTokenChange, uint256 underlyingReceived, uint256 requestId)`
  - `adjustZombieTroveWithUnderlying(uint256 _troveId, uint256 _underlyingChange, bool _isCollIncrease, uint256 _jpydfChange, bool _isDebtIncrease, uint256 _upperHint, uint256 _lowerHint, uint256 _maxUpfrontFee) nonReentrant returns (uint256 dTokenChange, uint256 underlyingReceived, uint256 requestId)`
  - `adjustZombieTroveWithUnderlyingWithMin(uint256 _troveId, uint256 _underlyingChange, bool _isCollIncrease, uint256 _jpydfChange, bool _isDebtIncrease, uint256 _upperHint, uint256 _lowerHint, uint256 _maxUpfrontFee, uint256 _minUnderlyingReceived) nonReentrant returns (uint256 dTokenChange, uint256 underlyingReceived, uint256 requestId)`
- **Purpose**: Adjust collateral (Underlying-denominated) and debt (JPYdf) together in one tx. For zombie Troves, the same Underlying-denominated path is provided over the core `adjustZombieTrove` hint-based entrypoint.
- **Permission**: `_checkAdjustTroveManagers` determines authorization and receiver (add-side for collateral increase / repayment; remove-side for collateral decrease / borrow).
- **Preconditions / Checks**: authorization decision above; record balance baseline with `_setInitialTokensAndBalances(collToken, jpydfToken)`.
- **Behavior / Effects** (pre / collateral amount resolution / body / post):
  1. **pre** (`_adjustTroveWithUnderlyingPre`): determine authorization and receiver, record balance baseline. If `!_isDebtIncrease && _jpydfChange > 0`, pull JPYdf for repayment.
  2. **collateral amount resolution**: when `_underlyingChange > 0`, collateral increase pulls Underlying and uses the return value of `collateralVault.deposit` as `dTokenChange`; collateral decrease uses `dToken.convertToDToken(_underlyingChange)` as `dTokenChange`.
  3. **body**: normal entrypoints call `borrowerOperations.adjustTrove(_troveId, dTokenChange, _isCollIncrease, _jpydfChange, _isDebtIncrease, _maxUpfrontFee)`, while zombie entrypoints call `borrowerOperations.adjustZombieTrove(_troveId, dTokenChange, _isCollIncrease, _jpydfChange, _isDebtIncrease, _upperHint, _lowerHint, _maxUpfrontFee)`.
  4. **post** (`_adjustTroveWithUnderlyingPost`): on collateral decrease, apply the same normalization as [ZAP-FR-006](#zap-fr-006-withdrawcolltounderlying-withdraw-collateral-and-receive-underlying), redeem only the dToken amount representable in Underlying base units, and return any remainder as dToken. `WithMin` compares only immediate `underlyingReceived`. If `_isDebtIncrease && _jpydfChange > 0`, transfer borrowed JPYdf to receiver. Finally call `_returnLeftovers`.
- **Reverts / early returns**: unauthorized; pull failure; `deposit` cap/unset; `_maxUpfrontFee` exceeded (🔵 core).
- **Emitted event**: none (core-side). Delayed redemption tracking for collateral decrease uses Vault `WithdrawRequested` (§7.2).
- **Design notes / points**:
  - On collateral increase, the implementation uses the `collateralVault.deposit` return value directly as `dTokenChange` ([ZAP-TBD-002](#zap-tbd-002)).
  - On collateral decrease, withdraw dToken equal to `convertToDToken(_underlyingChange)` and redeem. This is normally exactly representable, while the shared helper also handles non-exact amounts and returns dToken dust to the receiver instead of leaving it in the Vault or Zapper.
  - `adjustZombieTrove` variants are implemented and follow the same pre/post, leftover-return, and received-Underlying lower-bound rules as normal adjust.
- **Verification**: unit (all four quadrants: increase/decrease collateral × borrow/repay; zombie hint path; authorization, transfers, and lower bounds), integration (full simultaneous adjustment and zero leftovers).

### ZAP-FR-010: closeTroveToUnderlying (close when JPYdf is held)

- **Type**: Functional | **Source**: §1.2 close
- **Signatures**:
  - `closeTroveToDToken(uint256 _troveId) nonReentrant returns (uint256 collateral)`
  - `closeTroveToUnderlying(uint256 _troveId) nonReentrant returns (uint256 underlyingReceived, uint256 requestId)`
  - `closeTroveToUnderlyingWithMin(uint256 _troveId, uint256 _minUnderlyingReceived) nonReentrant returns (uint256 underlyingReceived, uint256 requestId)`
- **Purpose**: When the user holds JPYdf, pull the repayment JPYdf, close the Trove, convert collateral to Underlying, and return it.
- **Permission**: owner or remove manager only (Zapper must be receiver).
- **Preconditions / Checks**: authorization; `_requireZapperIsReceiver`.
- **Behavior / Effects**:
  1. Read `entireDebt` with `trove = troveManager.getLatestTroveData(_troveId)`, then pull repayment JPYdf with `jpydfToken.transferFrom(msg.sender, this, trove.entireDebt)`
  2. `borrowerOperations.closeTrove(_troveId)` → collateral dToken returns to Zapper
  3. Pass the pre-close `trove.entireColl` through the normalization in [ZAP-FR-006](#zap-fr-006-withdrawcolltounderlying-withdraw-collateral-and-receive-underlying). Redeem the maximum amount representable in Underlying base units and return sub-unit dust as dToken. `WithMin` compares only immediate `underlyingReceived`, excluding queued value and dust, and reverts the whole operation on failure.
  4. Convert gas compensation (`ETH_GAS_COMPENSATION`) to ETH through `WETH.withdraw` and send to receiver (`safeTransferETH` reverts on failure; [ZAP-SEC-007](#zap-sec-007-revert-on-failed-gas-compensation-eth-transfer))
- **Reverts / early returns**: unauthorized; Zapper not receiver; insufficient JPYdf balance/approval; received-Underlying lower-bound failure; ETH transfer failure.
- **Emitted event**: none. Delayed redemption uses Vault `WithdrawRequested` (§7.2).
- **DToken exit**: `closeTroveToDToken` uses the same authorization, receiver, exact debt repayment, and gas-compensation path, but transfers the full collateral as dToken without calling the Vault. This lets the owner or local remove manager close during a Vault redemption pause or illiquidity. Unrelated dToken already held by the Zapper is not transferred. Core close restrictions still apply.
- **Design notes**: A redemption may make `entireColl` non-exact for a 6/8-decimal Underlying; this must not block close. The Vault exact-conversion guard remains unchanged because the Zapper separates redeemable value from dToken dust. `requestId` is not re-emitted ([ZAP-TBD-001](#zap-tbd-001)). Close does not necessarily return Underlying immediately; see §7.4.
- **Verification**: unit (authorization, receiver, lower bound, gas comp, and closing non-exact 6-decimal collateral after redemption), integration (close→redeem→ETH return).

### ZAP-FR-011: Removed From The Day-1 ABI (Flash Loan close / collateral-funded close)

- **Type**: Deferred / Removed from Day-1 production ABI | **Provenance**: fresh deploy simplification
- **Current specification**: `CollateralYieldZapper` does not expose `closeTroveFromCollateral`. Closing without holding JPYdf by sourcing repayment from collateral, collateral-funded repay, and Multiply are not part of the Day-1 production ABI.
- **Rationale**:
  1. Day-1 JPYdf liquidity is the JPYdf/USDC Uniswap v4 pool added after JPYdf deploy / issuance; non-USDC reverse routes need asset-specific pre-legs and fork evidence.
  2. dToken collateral has no DEX market, so collateral-funded close crosses Underlying / dToken / JPYdf / Vault buffer and materially expands audit blast radius.
  3. Fresh deploy does not need unused legacy/helper compatibility ABI.
- **Implementation requirement**: production `contracts/src`, generated ABI, deploy script, and app flow must not contain `closeTroveFromCollateral`, a flash-loan provider dependency, a Balancer Flash Loan adapter, or fail-fast exchange placeholder dependency.
- **Future addition condition**: if collateral-funded close / Multiply is reconsidered, Balancer must not return as a candidate venue. `UniV4Exchange` is included in Day-1 audit scope, but user-facing flows still require a new audited entrypoint after the JPYdf/USDC v4 final leg, asset-specific pre-leg, hook policy, slippage floor, allowance cleanup, and fork evidence are complete, without reusing the removed Flash Loan callback / provider surface.
- **Verification**: manual / build artifact review (ABI absence, deploy wiring absence, frontend flow absence).

### ZAP-FR-012: Removed From The Day-1 ABI (Flash Loan callback)

- **Type**: Deferred / Removed from Day-1 production ABI | **Provenance**: fresh deploy simplification
- **Current specification**: `receiveFlashLoanOnCloseTroveFromCollateral` / `CloseTroveParams` / `IFlashLoanReceiver` / `IFlashLoanProvider` / the Balancer Flash Loan adapter do not exist in production `src` or ABI. Balancer is excluded from both Day-1 and future plans.
- **Security intent**: remove the callback surface itself rather than auditing caller verification for an unused path. This excludes callback spoofing, provider misbinding, flash-loan repayment paths, and Flash Loan callback-specific return-data / allowance boundaries from Day-1 audit scope. `UniV4Exchange` Universal Router / Permit2 allowance boundaries remain included in Day-1 audit scope.
- **Future policy**: do not assume Flash Loan callback / Balancer adapter reintroduction. If a separate atomic-liquidity feature is proposed, specify provider / callback / repayment / Vault buffer / delayed redeem / reentrancy boundaries as new scope, do not reuse existing IDs, and redesign it without Balancer dependency.
- **Verification**: manual / build artifact review (callback selector absence, interface absence, deploy dependency absence).

### ZAP-FR-013: receive (ETH receipt from WETH)

- **Type**: Functional | **Source**: §1.4 Leverage out of scope / gas compensation transfer
- **Signature**: `receive() external payable`
- **Purpose**: Accept ETH only from `WETH.withdraw` (gas compensation conversion) and reject ETH sent by anyone other than WETH.
- **Permission**: ETH receipt only when `msg.sender == WETH`.
- **Preconditions / Checks**: `msg.sender == address(WETH)`.
- **Behavior / Effects**: receive ETH from WETH only.
- **Reverts / early returns**: reverts with `CollateralYieldZapper__OnlyWETH` when ETH is sent by anyone other than WETH.
- **Emitted event**: none.
- **Design notes**: if leverage with dToken collateral becomes necessary, design a separate future contract such as `LeverageCollateralYieldZapper` ([ZAP-TBD-004](#zap-tbd-004)). The old leverage callback / router interface has been removed from Day-1 production `src`.
- **Verification**: unit (`receive()` accepts only ETH from `WETH.withdraw`).

### ZAP-FR-014: ARCHIVED Sky USDC route variant (USDC→USDS→sUSDS→dUSDS)

- **Type**: Functional | **Source**: Sky / MakerDAO collateral route requirements
- **Target**: `SkyUsdcSUsdsYieldZapper`
- **Signatures**:
  - `openTroveWithUsdc(OpenTroveParams _params, uint256 _minUsdsOut, uint256 _minSUsdsOut) payable returns (uint256 troveId)`
  - `openTroveWithUsdcAndReferral(OpenTroveParams _params, uint256 _minUsdsOut, uint256 _minSUsdsOut, bytes32 _referralCode) payable returns (uint256 troveId)`
  - `addCollWithUsdc(uint256 _troveId, uint256 _usdcAmount, uint256 _minUsdsOut, uint256 _minSUsdsOut) returns (uint256 usdsAmount, uint256 susdsAmount, uint256 dTokenAmount)`
- **Purpose**: Receive USDC directly as UX input and open / add collateral to a dUSDS collateral Trove through the Sky route.
- **Permission**: open is permissionless; add collateral is owner or add manager only (same as parent `CollateralYieldZapper`).
- **Preconditions / Checks**:
  - open flows require `msg.value == ETH_GAS_COMPENSATION` and batch consistency (same as [ZAP-FR-002](#zap-fr-002-opentrovewithrawethandreferral-open--referral))
  - constructor asserts `sUSDS.asset() == USDS`
  - constructor fixes route decimal assumptions: `USDC.decimals() == 6`, `USDS.decimals() == 18`, `sUSDS.decimals() == 18`
  - `collAmount` / `usdcAmount` must not be 0
  - The USDC→USDS converter return value must match the actual USDS balance delta; the USDC→USDS result must be at least `_minUsdsOut`; the USDS→sUSDS deposit result must be at least `_minSUsdsOut`
  - At each stage (USDC→USDS converter, USDS→sUSDS vault, sUSDS→CollateralVault deposit), the Zapper's intermediate token balance must return to the pre-call baseline
- **Behavior / Effects**:
  1. Pull USDC from user to Zapper
  2. Temporarily approve only the required USDC to the converter, call `ISkyUsdcSUsdsConverter.convertUsdcToUsds(usdcReceived, minUsdsOut, address(this))` to convert to USDS, then reset allowance to 0. Compare the converter-reported USDS amount with the Zapper's actual USDS balance delta
  3. Temporarily approve only the required USDS to the ERC4626 sUSDS vault, deposit USDS and receive sUSDS shares, then reset allowance to 0
  4. Convert to dUSDS with `CollateralVault.deposit(susdsAmount)`
  5. Open flows create a Trove with dUSDS as collateral and transfer minted JPYdf to user. Add-collateral flow adds dUSDS to the existing Trove
- **Reverts / early returns**: `collAmount == 0` / `usdcAmount == 0`; USDC / USDS / sUSDS decimals mismatch; USDC pull failure; converter revert; converter-reported amount and actual USDS delta mismatch -> `SkyUsdcSUsdsYieldZapper__UsdsAmountMismatch`; `usdsAmount < minUsdsOut`; `susdsAmount == 0 || susdsAmount < minSUsdsOut`; intermediate token balance does not return to pre-call baseline; reverts from parent Zapper / Liquity core / CollateralVault.
- **Emitted events**:
  - `SkyUsdcRouteDeposit(user, troveId, usdcAmount, usdsAmount, susdsAmount, dTokenAmount, referralCode)`
  - `SkyUsdcRouteAddColl(user, troveId, usdcAmount, usdsAmount, susdsAmount, dTokenAmount)`
  - In open with `_referralCode != bytes32(0)`, parent `ReferralDeposit` is also emitted. `underlyingAmount` is the user-facing USDC amount for this route.
  - `usdcAmount` is not the requested `_params.collAmount` / `_usdcAmount`; it is the actual received USDC amount confirmed by Zapper balance-diff.
- **Design notes / cautions**:
  - The Zapper does not hold a concrete Sky PSM / LitePSM interface. LitePSMWrapper halt, fees, decimals, and target binding are absorbed by the `ISkyUsdcSUsdsConverter` adapter.
  - `_params.collAmount` in the Sky route is the **USDC-denominated input amount**; actual collateral entering the Trove is `dTokenAmount` after the route. UI / SDK must always specify `minUsdsOut` / `minSUsdsOut`.
  - LitePSM / PSM paths may have governance fees (`tin` / `tout`) or halt states. The USDC→USDS adapter should reflect fee/halt and revert in the route, and the Zapper also rechecks final received amount with `minUsdsOut`. A concrete adapter with an explicit fee cap should expose parameters such as `allowedTin`.
  - USDC converter and sUSDS vault are external route boundaries; the Zapper does not keep permanent max approval to them. It uses per-route `forceApprove(amount)` / `forceApprove(0)` only.
  - Return asset is sUSDS (= this branch's Underlying) because parent withdraw / close paths are inherited. USDC reverse-conversion UX is a separate route.
- **Verification**: unit / integration (USDC→USDS→sUSDS→dUSDS→open, slippage lower bounds, zero leftovers, temporary allowance reset to zero, referral).

---

### ZAP-FR-015: native ETH on-ramp (ETH→stETH→wstETH→dwstETH)

- **Type**: Functional | **Source**: dwstETH branch onboarding requirement (Branch 0's Underlying moved WETH → wstETH)
- **Target**: `CollateralYieldZapper`, deployed on the dwstETH branch with the route enabled
- **Signatures**:
  - `openTroveWithNativeEth(OpenTroveParams _params, uint256 _minWstEthOut) payable returns (uint256 troveId)`
  - `openTroveWithNativeEthAndReferral(OpenTroveParams _params, uint256 _minWstEthOut, bytes32 _referralCode) payable returns (uint256 troveId)`
- **Purpose**: let native-ETH holders open a dwstETH Trove without sourcing wstETH themselves. The existing wstETH ERC-20 path is unchanged.
- **Authorization**: permissionless (open only; this route has no add-collateral or exit variant).
- **Route enablement**: the constructor's `_expectedStEth` is authoritative. Passing `address(0)` means the route does not exist and every call reverts with `CollateralYieldZapper__NativeEthRouteUnavailable`. Passing a nonzero value reads the Underlying's (wstETH's) `stETH()` getter and **reverts at deployment** if the value does not match or is not a contract. The route is never enabled implicitly by an interface probe.
- **Lido referral binding**: the constructor sets the initial `lidoReferral`, shared by both native-ETH entrypoints when they call Lido `submit`; after deployment only the immutable `lidoReferralManager` Timelock can update it through `setLidoReferral`. The general contract permits `address(0)` to disable attribution, while the production mainnet Day-1 deploy gate requires an exact match with the nonzero value in `config/day1-branch-manifest.json`. No user input or JPYdf borrow-campaign `bytes32 referralCode` can change it.
- **Preconditions (checks)**:
  - `stEthToken != address(0)` (the instance has the route enabled)
  - `_params.collAmount != 0` and `msg.value == ETH_GAS_COMPENSATION + _params.collAmount`
  - open owner is `msg.sender`, and batch parameters are consistent (same as [ZAP-FR-002](#zap-fr-002-opentrovewithrawethandreferral-open--referral))
  - the wstETH balance delta after wrapping is at least `_minWstEthOut` and nonzero
- **Behavior (effects)**:
  1. Wrap `ETH_GAS_COMPENSATION` via `WETH.deposit` (gas compensation is handled exactly as on the other routes)
  2. Stake the remaining `collAmount` through `stETH.submit{value: collAmount}(lidoReferral)`, measuring stETH received as a balance delta
  3. `forceApprove` exactly that amount of stETH to wstETH, `wrap`, then reset the allowance to 0; measure wstETH received as a balance delta
  4. Sweep the 1–2 wei of stETH that Lido share rounding can leave behind back to the caller
  5. `CollateralVault.deposit(wstEthAmount)` to obtain dwstETH, open the Trove against it, and transfer the minted JPYdf to the user
- **Reverts / early returns**:
  - calling an instance where the route is disabled (`CollateralYieldZapper__NativeEthRouteUnavailable`)
  - `collAmount == 0` or a `msg.value` mismatch (`CollateralYieldZapper__WrongETH`)
  - a failed `submit` — Lido staking paused or capped — is re-raised with its reason wrapped (`CollateralYieldZapper__StEthSubmitFailed(reason)`), leaving the direct wstETH deposit path unaffected
  - `wstEthAmount < _minWstEthOut` or `wstEthAmount == 0` (`CollateralYieldZapper__InsufficientWstEthOut`)
  - deployment-time `stETH()` mismatch (`CollateralYieldZapper__StEthMismatch`) or non-contract (`CollateralYieldZapper__NotContract`)
  - reverts propagated from the parent Zapper, Liquity Core, or CollateralVault
- **Emitted events**:
  - `NativeEthRouteDeposit(user, troveId, ethAmount, stEthAmount, wstEthAmount, dTokenAmount, referralCode)`
  - when `_referralCode != bytes32(0)`, the parent's `ReferralDeposit` also fires. Its `underlyingAmount` is denominated in **wstETH** (the amount actually received after the route), matching the ERC-20 path
- **Design notes**:
  - on this route `_params.collAmount` is the **amount of ETH to stake**; the collateral that actually enters the Trove is the resulting `dTokenAmount`. UI / SDK must always set `_minWstEthOut`
  - approvals to stETH / wstETH are per-route `forceApprove(amount)` / `forceApprove(0)`; no permanent max approval is held
  - the Lido referral (`address`) is Protocol deployment configuration; it is independent in type, recording destination, and authority from the JPYdf borrow-campaign referral (`bytes32`)
  - exits inherit the parent paths (`withdrawCollToUnderlying` / `closeTroveToUnderlying`), so **withdrawals return wstETH**. No reverse conversion to native ETH is offered
  - the route runs under `nonReentrant`, so reentry during `submit` is blocked by the guard
- **Verification**: unit / integration (stake→wrap→open, both native-ETH entrypoints passing the same Protocol-designated Lido referral, zero-address referral support, independence from the JPYdf `bytes32 referralCode`, slippage floor, typed revert when `submit` is paused and the direct path staying unaffected, `msg.value` mismatch, rounding-residue sweep, route-disabled instance, close returning wstETH, reentrancy block).

---

## 7. State Variables and Accounting Model

`CollateralYieldZapper` holds no persistent accounting state. Protocol references and `lidoReferralManager` are `immutable`, fixed in the constructor from the existing `AddressesRegistry` (core references) and Zapper-specific arguments (`collateralVault` / `underlyingToken` / `expectedStEth` / `lidoReferralManager`); only `lidoReferral` is updatable, by the Timelock alone, and it never affects collateral, debt, or receivers. Other mutable storage is limited to the `ReentrancyGuard` transient lock (slot 2 `_status`) and the per-trove delegation authorizations inherited from `AddRemoveManagers` (slot 0 `addManagerOf` / slot 1 `removeManagerReceiverOf`) ([ZAP-INV-001](#8-invariants-inv)). Tokens temporarily held in each tx must be returned to user / receiver, with no stuck Zapper balances ([ZAP-INV-003](#8-invariants-inv)).

**Reference storage**

| Variable | Type | Role |
| --- | --- | --- |
| `collateralVault` | `ICollateralVault` | Target for Underlying ↔ dToken deposit / redeem |
| `dToken` | `IDToken` | dToken body; used for `convertToDToken` conversion |
| `underlyingToken` | `IERC20` | Underlying for this branch (WETH / WBTC / USDC, etc.) |
| `collToken` | `IERC20` | Collateral token from the core's perspective (= ERC-20 view of dToken). `collToken == dToken` ([ZAP-INV-002](#8-invariants-inv)) |
| `lidoReferralManager` | `address immutable` | Timelock allowed to update `lidoReferral` |
| `lidoReferral` | `address` | Protocol-designated referral passed to every Lido `submit` on the native-ETH route (Lido Rewards Share attribution); Timelock-updatable, with `address(0)` disabling attribution |

In addition, `BaseZapper` holds `borrowerOperations` / `troveManager` / `WETH` / `jpydfToken` as `immutable`.

`SkyUsdcSUsdsYieldZapper` additionally holds `usdcToken` / `usdsToken` / `susdsVault` / `usdcUsdsConverter` as `immutable`. Parent `underlyingToken` is sUSDS; constructor verifies `collateralVault.underlying() == sUSDS`, `AddressesRegistry.collToken() == dUSDS`, `sUSDS.asset() == USDS`, and route token decimals (USDC=6, USDS/sUSDS=18).

**Constructor and approvals**

Constructor calls `BaseZapper(_addressesRegistry)`, fixes `collateralVault` / `underlyingToken` from Zapper-specific arguments, and fixes `collToken` from existing `AddressesRegistry.collToken()`. `dToken` is derived as `IDToken(address(collToken))`; no additional Registry getter is used. It then performs the following approvals **once at deployment** (avoid per-call approval gas; approval targets are trusted components only, [ZAP-SEC-006](#zap-sec-006-approval-targets-limited-to-trusted-components)):

1. `WETH → BorrowerOperations` (gas compensation, `type(uint256).max`)
2. `dToken(collToken) → BorrowerOperations` (collateral transfer, `max`)
3. `underlyingToken → CollateralVault` (deposit, `max`)
For `SkyUsdcSUsdsYieldZapper`, `USDC → ISkyUsdcSUsdsConverter` and `USDS → sUSDS Vault` are temporarily approved only for the required amount during route execution and reset to 0 after success. Concrete Sky PSM / LitePSM contracts are managed inside the adapter, so the Zapper does not grant permanent max allowance to external route boundaries.

**Accounting model**: the Zapper is a pass-through relay and does not account for value. Collateral and debt accounting belong to the core (Trove) and Vault (buffer/principal). The Zapper only performs transient "pull → convert → call core/Vault → return leftovers" flows. Underlying ↔ dToken quantity relationships follow [DTKN-FR-003](dToken.md) (`convertToDToken` exact multiplication / `convertToUnderlying` floor to safe side).

---

## 8. Invariants (INV)

| ID | Invariant | Verification |
| --- | --- | --- |
| ZAP-INV-001 | The Zapper holds no persistent protocol-configuration or accounting state. Route / core references do not change after constructor finalization, and mutable storage is limited to the `ReentrancyGuard` transient lock plus the per-trove delegation authorizations inherited from `AddRemoveManagers` (`addManagerOf` / `removeManagerReceiverOf`: settable only by the trove owner; an authorization state that restricts who may exercise the manager permission the Zapper holds on the core side) | machine (`forge inspect` storage layout) |
| ZAP-INV-002 | `collToken == dToken` (core collateral = dToken). `dToken` is derived from `AddressesRegistry.collToken()` and does not require an additional `AddressesRegistry.dToken()` getter | manual / unit (deployment assert; [ZAP-TBD-003](#zap-tbd-003)) |
| ZAP-INV-003 | After any external function completes normally, the Zapper has no stuck `underlyingToken` / `collToken` / `jpydfToken` balance. `collToken` below one Underlying base unit is not passed to the Vault and is returned to the receiver as dToken. On the native ETH route, any stETH residue carrying shares must be returned to the caller; only zero-share (untransferable) nominal Lido share-rounding dust of at most 2 wei may remain | invariant |
| ZAP-INV-004 | Open flows ([ZAP-FR-002](#zap-fr-002-opentrovewithrawethandreferral-open--referral) / [ZAP-FR-004](#zap-fr-004-opentrovewithunderlyingpermitandreferral-permit-open--referral)) are structurally zero-leftover (`openTrove` pulls all dToken returned by `deposit`, and JPYdf is fully transferred to user) → `_returnLeftovers` unnecessary | unit |
| ZAP-INV-005 | `ReferralDeposit` is emitted exactly once only for open flows (including permit version) when `_referralCode != bytes32(0)`, and referralCode is not passed to Vault / core | unit |
| ZAP-INV-006 | The old leverage callback / router surface does not exist in production `src` | manual |
| ZAP-INV-007 | Day-1 production ABI has no Flash Loan callback / provider dependency / Balancer adapter / fail-fast exchange placeholder | manual (ABI and deploy wiring review) |
| ZAP-INV-008 | All user-facing external state-changing functions that move value or make untrusted external calls are non-reentrant. No callback-specific non-`nonReentrant` exception exists. The `AddRemoveManagers`-inherited `setAddManager` / `setRemoveManager` / `setRemoveManagerWithReceiver` are explicit exceptions (owner check only; no untrusted external calls and no value movement) | manual (modifier coverage) / unit |
| ZAP-INV-009 | After a normal Sky route completion, USDC / USDS / sUSDS / dUSDS / JPYdf do not remain in the Zapper | unit / invariant |

---

## 9. Security Requirements (SEC)

### ZAP-SEC-001: nonReentrant for user-facing external state-changing functions

- Type: Security
- Statement: The contract must inherit `ReentrancyGuard` and attach `nonReentrant` to **all user-facing external state-changing functions that move value or make untrusted external calls** (considering reentrancy across Vault / Strategy / Token combinations). The Day-1 ABI has no Flash Loan callback, so there is no callback-specific non-`nonReentrant` exception. The `AddRemoveManagers`-inherited `setAddManager` / `setRemoveManager` / `setRemoveManagerWithReceiver` are explicit exceptions: all three perform only the trove-owner check and make no untrusted external call and no value movement (the only external call is the in-protocol view `troveNFT.ownerOf`), and `setRemoveManager` calls `setRemoveManagerWithReceiver` internally, so naively attaching the modifier to both would self-lock via `ReentrancyGuard` and always revert. The shared base `AddRemoveManagers` is unmodified liquity/bold upstream, is also inherited by `BorrowerOperations`, and drew no finding in the external audit (Zapper / route scope).
- Verification: manual (modifier coverage), unit (reentrancy attack reverts). invariant=[ZAP-INV-008](#8-invariants-inv)

### ZAP-SEC-002: beneficiary and executor consistency (manager/receiver)

- Type: Security
- Statement: owner / add manager / remove manager and receiver consistency must be checked through shared `BaseZapper` (`AddRemoveManagers`) functions. For collateral withdrawal, borrow, and close paths, `_requireZapperIsReceiver` must verify "the Zapper is the receiver for this Trove," and third parties must not operate on other users' Troves.
- Verification: unit (third-party operation reverts; add/remove manager role separation), manual

### ZAP-SEC-003: leftover return and avoidance of stuck funds

- Type: Security
- Statement: Flows where the Zapper may temporarily hold multiple tokens ([ZAP-FR-008](#zap-fr-008-repayjpydf-repay) / [ZAP-FR-009](#zap-fr-009-adjusttrovewithunderlying-adjust-collateral-and-debt-together) / close-with-JPYdf) must use `_setInitialTokensAndBalances` / `_setInitialBalancesAndReceiver` + `_returnLeftovers`, and assets must not remain stuck in the Zapper. For dToken→Underlying conversion, only the amount exactly representable in Underlying base units is passed to the Vault; remaining dToken dust is returned to the receiver. On the native ETH route, any stETH residue carrying shares must be returned to the caller. Because stETH balances are derived from shares, a nominal balance of 1–2 wei corresponds to 0 shares when the share price exceeds 1 and cannot be removed by transfer; only this zero-share nominal dust of at most 2 wei may remain ([ZAP-INV-003](#8-invariants-inv)). Open flow is structurally zero-leftover and does not need this ([ZAP-INV-004](#8-invariants-inv)).
- Verification: unit (excess repayment / dust returned), invariant=[ZAP-INV-003](#8-invariants-inv)

### ZAP-SEC-004: No Flash Loan callback in the Day-1 ABI

- Type: Security
- Statement: `CollateralYieldZapper` / `BaseZapper` / `IZapper` / deploy scripts / generated ABI must not expose a Flash Loan callback, Flash Loan provider getter, Balancer Flash Loan adapter, or fail-fast exchange placeholder dependency. Callback spoofing and provider misbinding are eliminated by surface removal rather than caller guards.
- Verification: manual (ABI, selector, and deploy wiring review), invariant=[ZAP-INV-007](#8-invariants-inv)

### ZAP-SEC-005: slippage protection

- Type: Security
- Statement: `withdrawCollToUnderlyingWithMin` / `adjustTroveWithUnderlyingWithMin` / `adjustZombieTroveWithUnderlyingWithMin` / `closeTroveToUnderlyingWithMin` must guarantee `_minUnderlyingReceived` against the receiver's actual immediate Underlying balance increase and revert if below. Vault nominal transfer amount, queued claims, and returned dToken dust do not satisfy the floor; fee-on-transfer Underlying therefore cannot bypass it. The Day-1 ABI has no swap-backed close JPYdf-swap slippage surface.
- In the Sky route, `minUsdsOut` and `minSUsdsOut` must guarantee lower bounds for both USDC→USDS conversion and USDS→sUSDS deposit. If the USDC→USDS adapter uses LitePSM / PSM, adverse execution due to fee/halt is prevented both by adapter revert and `minUsdsOut`.
- Verification: unit (lower-bound violation and fee-on-transfer receiver-delta violation revert atomically), fork (lower-bound guarantee under swap price movement)

### ZAP-SEC-006: approval targets limited to trusted components

- Type: Security
- Statement: constructor `max` approvals (§7) must be limited to trusted components (BorrowerOperations / CollateralVault). Because the Zapper assumes no persistent balance, the impact of unlimited approval is contained within the trust boundary.
- In the Sky route, `USDC → ISkyUsdcSUsdsConverter` and `USDS → sUSDS ERC4626 vault` are additional approval targets. `SkyUsdcSUsdsConverter` is included in audit scope, and deployment creates it from the configured LitePSMWrapper rather than accepting arbitrary adapter replacement.
- Per-swap approvals made by the v4 adapter to external routers / pools are treated as temporary allowances. Curve adapters and Uniswap v3 routes are out of Day-1 scope and are not included in production routes. Use `forceApprove(amount)` for zero-first token compatibility and reset unused allowance with `forceApprove(0)` after swap. The Uniswap v4 route must reset both ERC-20→Permit2 allowance and Permit2→Universal Router allowance to zero after swap. For exact-output swaps especially, unused input allowance may remain; both leftover token return and allowance reset are verification targets.
- Verification: manual (approval target review), unit (zero-first token + partial-spend router allowance reset / successful repeat swap)

### ZAP-SEC-007: revert on failed gas compensation ETH transfer

- Type: Security
- Statement: ETH transfer in `closeTroveToUnderlying` ([ZAP-FR-010](#zap-fr-010-closetrovetounderlying-close-when-jpydf-is-held)) must use `SafeTransferLib.safeTransferETH` and revert on transfer failure.
- Verification: unit (transfer failure reverts)

> **Temporary asset holding assumption**: the Zapper temporarily holds dToken / JPYdf, and minted JPYdf is minted to `msg.sender = Zapper`. Implementation mistakes directly translate into asset loss. Return, transfer, and zero-balance behavior must be strict and clearly separated as test and audit targets (§7.1 risk).

---

## 10. Governance, Operations, and Upgrade Requirements (GOV)

### ZAP-GOV-001: non-invasive to core, Vault, and dToken

- Statement: the Zapper is an optional external module and must not add any Zapper-specific hooks / signatures / state to Liquity core, CollateralVault, or dToken ("No Router" policy; zero core modification). It uses only generic Vault interfaces (`deposit` / `redeem` / `redeemWithPermit`).
- Verification: manual (core and Vault diff review)

### ZAP-GOV-002: stateless / non-upgradeable

- Statement: the Zapper is non-upgradeable (`immutable` references, no proxy) and holds no persistent protocol-configuration or accounting state (the bound on mutable storage is [ZAP-INV-001](#8-invariants-inv)). If logic replacement is required, deploy a new contract and switch frontend / deployment configuration references (do not modify an existing Zapper in place).
- Verification: manual (deployment configuration review)

### ZAP-GOV-003: referralCode off-chain boundary

- Statement: referralCode is off-chain metadata that does not affect accounting and remains inside the Zapper. It must not be passed to Vault / Liquity core. Aggregation is performed only through events ([ZAP-EVT-001](#zap-evt-001-referraldeposit)).
- Verification: manual (review that Vault/core have no referral arguments)

---

## 11. Events and Monitoring Requirements (EVT)

### ZAP-EVT-001: ReferralDeposit

- **Event**: `ReferralDeposit(address indexed user, uint256 indexed troveId, uint256 underlyingAmount, uint256 dTokenAmount, uint256 jpydfAmount, bytes32 indexed referralCode)`
- **Emission condition**: emitted only when `_referralCode != bytes32(0)` in open flows ([ZAP-FR-002](#zap-fr-002-opentrovewithrawethandreferral-open--referral) / Permit version [ZAP-FR-004](#zap-fr-004-opentrovewithunderlyingpermitandreferral-permit-open--referral))
- **Indexed fields**: `user` / `troveId` / `referralCode` (for channel and user filtering)
- **Purpose (off-chain)**: referralCode is not passed to Vault / Liquity core; it is kept inside the Zapper and recorded only as this event. Subgraph / off-chain aggregation uses `user` / `troveId` / `referralCode` as keys to calculate channel/partner inflow, debt volume, and revenue share. `jpydfAmount` is the user-received borrow amount (`_params.jpydfAmount`), not upfront-fee-inclusive `entireDebt`.

> **Related Vault-side events** (`Deposited` / `WithdrawRequested` / `WithdrawClaimed` / `Redeemed`, etc.) are described in [CollateralVault requirements](CollateralVault.md). Delayed redemption tracking for close / collateral withdrawal uses Vault `WithdrawRequested(user, receiver indexed, requestId, amount, claimableAt)` filtered by `receiver == userAddress` as described in §7.2 (Zapper does not re-emit `requestId`; [ZAP-TBD-001](#zap-tbd-001)).

---

## 12. Failure / Exception Behavior (ERR)

**Error catalog (Zapper level)**

| Error / trigger | Condition |
| --- | --- |
| `CollateralYieldZapper__ZeroAddress` / `CollateralYieldZapper__NotContract` | CollateralVault / Underlying is zero or undeployed in the constructor |
| `CollateralYieldZapper__InvalidVaultDToken` / `CollateralYieldZapper__InvalidVaultUnderlying` | Vault dToken / Underlying does not match the Zapper constructor arguments |
| `CollateralYieldZapper__WrongETH` | ETH other than the gas compensation amount is sent to open flows ([ZAP-FR-002](#zap-fr-002-opentrovewithrawethandreferral-open--referral) / [ZAP-FR-004](#zap-fr-004-opentrovewithunderlyingpermitandreferral-permit-open--referral)) |
| `CollateralYieldZapper__CannotChooseInterestIfJoiningBatch` | `_params.batchManager != 0 && _params.annualInterestRate != 0` (open flows) |
| `CollateralYieldZapper__PermitFailed` | Permit route catches permit failure in `try/catch` ([ZAP-FR-004](#zap-fr-004-opentrovewithunderlyingpermitandreferral-permit-open--referral)). For non-permit tokens / EOAs, failure may not be catchable and may revert ([ZAP-TBD-006](#zap-tbd-006)) |
| unauthorized | owner / add manager / remove manager mismatch ([ZAP-SEC-002](#zap-sec-002-beneficiary-and-executor-consistency-managerreceiver)) |
| Zapper is not receiver | `_requireZapperIsReceiver` fails for collateral withdrawal, borrow, or close flows |
| `CollateralYieldZapper__InsufficientUnderlyingReceived` | `underlyingReceived < _minUnderlyingReceived` ([ZAP-SEC-005](#zap-sec-005-slippage-protection); each redeem path) |
| `CollateralYieldZapper__OnlyWETH` | ETH is sent to `receive()` by anyone other than WETH |
| ETH transfer failure | gas compensation ETH transfer fails ([ZAP-SEC-007](#zap-sec-007-revert-on-failed-gas-compensation-eth-transfer)) |
| `UniV4Exchange__ZeroAddress` / `UniV4Exchange__NotContract` / `UniV4Exchange__IdenticalTokens` | Uniswap v4 adapter constructor receives an invalid route configuration. collToken / JPYdf / Universal Router / Permit2 must be deployed contracts |
| `UniV4Exchange__AmountTooLarge` | amount cannot be safely narrowed to Universal Router / Permit2 `uint128` / `uint160` |
| `UniV4Exchange__InsufficientOutput` | v4 swap actual output is below the requested lower bound |
| `SkyUsdcSUsdsYieldZapper__ZeroAddress` / `SkyUsdcSUsdsYieldZapper__NotContract` | Sky route constructor receives zero or undeployed USDC / USDS / USDC→USDS converter. The sUSDS vault is checked as the parent `CollateralYieldZapper` Underlying via `CollateralYieldZapper__NotContract` |
| `SkyUsdcSUsdsYieldZapper__ZeroAmount` | Sky route `collAmount` / `usdcAmount` is 0 |
| `SkyUsdcSUsdsYieldZapper__InvalidSUsdsAsset` | Sky route constructor sees `sUSDS.asset() != USDS` |
| `SkyUsdcSUsdsYieldZapper__InvalidUsdcDecimals` / `SkyUsdcSUsdsYieldZapper__InvalidUsdsDecimals` / `SkyUsdcSUsdsYieldZapper__InvalidSUsdsDecimals` | Sky route constructor sees route token decimals not matching USDC=6 and USDS/sUSDS=18 |
| `SkyUsdcSUsdsYieldZapper__UsdsAmountMismatch` | The USDC→USDS converter return value does not match the Zapper's actual USDS balance delta |
| `SkyUsdcSUsdsYieldZapper__InsufficientUsdsOut` | Sky route receives less USDS than `_minUsdsOut` after USDC→USDS conversion |
| `SkyUsdcSUsdsYieldZapper__InsufficientSUsdsOut` | Sky route receives 0 shares or fewer than `_minSUsdsOut` after USDS→sUSDS deposit |
| `SkyUsdcSUsdsYieldZapper__UnexpectedTokenResidue` | USDC / USDS / sUSDS intermediate token balance does not return to the pre-route baseline |

**Dependency-originated reverts (propagated)**

| Trigger | Origin |
| --- | --- |
| `CapExceeded` / `TokenInfoNotSet` | `CollateralVault.deposit` (placeholder branch: `cap = 0` / Underlying unset; [dToken requirements](dToken.md)). UX disclosure is [ZAP-TBD-008](#zap-tbd-008) |
| below MIN_DEBT / `_maxUpfrontFee` exceeded / other core checks | 🔵 `BorrowerOperations` (values in [Parameters.md](../../../Parameters.md); behavior in [Liquity-v2-Core-Spec.md](Liquity-v2-Core-Spec.md)) |
| Sky adapter halt / fee / route unavailable | `ISkyUsdcSUsdsConverter` implementation ([ZAP-FR-014](#zap-fr-014-sky-usdc-route-variant-usdcusdsusdsdusds)) |
| Lido staking paused / capped, making `submit` fail | Lido stETH ([ZAP-FR-015](#zap-fr-015-native-eth-on-ramp-ethstethwstethdwsteth); re-raised as `CollateralYieldZapper__StEthSubmitFailed` with the reason, leaving the direct wstETH path unaffected) |

> **Delayed redemption immediacy**: `redeem` returns Underlying immediately only when Buffer is sufficient. If insufficient, it creates a delayed `WithdrawRequest`; claim can also revert if Buffer is insufficient ([CollateralVault requirements](CollateralVault.md)). UX must disclose that close / collateral withdrawal may not return Underlying immediately (§7.4).

---

## 13. Acceptance Criteria and Verification Plan

Passing condition for each requirement = the required **behavior** is satisfied (not test names or execution results). The table below is the acceptance criteria and verification ledger.

**Acceptance criteria (specified as functional behavior)**

1. **One-tx completion**: open / addColl / withdrawColl / adjust / zombie adjust / repay / withdrawJpydf / close-with-JPYdf complete in one tx in Underlying terms.
2. **dToken hidden**: users complete all operations with only Underlying and JPYdf, without holding, approving, or operating dToken.
3. **Referral separation**: the JPYdf borrow campaign emits `ReferralDeposit` exactly once only when `_referralCode != bytes32(0)` in open and does not pass referralCode to Vault / core. The native-ETH route passes the Protocol-designated `lidoReferral` to Lido `submit` from both entrypoints, independently of whether `_referralCode` is present.
4. **Permit**: with EIP-2612-compatible Underlying, open completes without prior approval.
5. **Zero leftovers / return**: in temporary multi-token holding cases, `_returnLeftovers` returns leftovers to user and no assets remain in the Zapper. Open flow has no leftovers.
6. **Authorization**: owner / add manager / remove manager and receiver consistency are checked; third parties cannot operate another user's Trove.
7. **Reentrancy**: user-facing external state-changing functions are `nonReentrant`. No callback-specific non-`nonReentrant` exception exists in the Day-1 ABI.
8. **Flash Loan close absent**: `closeTroveFromCollateral` / Flash Loan callback / Flash Loan provider dependency / Balancer adapter / fail-fast exchange placeholder do not exist in production `src`, deploy wiring, or generated ABI.
9. **Leverage unsupported**: the old leverage callback / router surface does not exist in production `src`.
10. **Sky route**: USDC→USDS→sUSDS→dUSDS open / addColl complete in one tx, revert below `minUsdsOut` / `minSUsdsOut`, and no USDC / USDS / sUSDS / dUSDS / JPYdf remains in the Zapper.

**Verification ledger (requirements × method)**

| ID | Requirement (summary) | Verification method |
| --- | --- | --- |
| ZAP-FR-001 | openTroveWithRawETH (referral=`bytes32(0)` delegation) | unit |
| ZAP-FR-002 | open + referral (Underlying→dToken→open→JPYdf transfer) | unit, integration |
| ZAP-FR-003 | permit open (referral=`bytes32(0)` delegation) | unit |
| ZAP-FR-004 | permit open + referral (no prior approval) | unit, integration |
| ZAP-FR-005 | addCollWithUnderlying (add collateral) | unit, integration |
| ZAP-FR-006 | withdrawCollToUnderlying (withdraw collateral→Underlying) | unit, integration |
| ZAP-FR-007 | withdrawJpydf (increase borrow) | unit, integration |
| ZAP-FR-008 | repayJpydf (repay and return excess) | unit, integration |
| ZAP-FR-009 | adjustTroveWithUnderlying / adjustZombieTroveWithUnderlying (collateral + debt simultaneous adjustment) | unit, integration |
| ZAP-FR-010 | closeTroveToUnderlying (close with JPYdf held) | unit, integration |
| ZAP-FR-011 | Removed from Day-1 ABI (Flash Loan close / collateral-funded close) | manual / build artifact review |
| ZAP-FR-012 | Removed from Day-1 ABI (Flash Loan callback) | manual / build artifact review |
| ZAP-FR-013 | receive | unit |
| ZAP-FR-014 | Sky USDC route (USDC→USDS→sUSDS→dUSDS) | unit, integration |
| ZAP-FR-015 | native ETH on-ramp (ETH→stETH→wstETH→dwstETH) | unit, integration |
| ZAP-INV-001..009 | Each invariant in §8 | manual / unit / invariant (as listed in §8) |
| ZAP-SEC-001..007 | Each security requirement in §9 | unit / fork / manual (as listed in §9) |
| ZAP-EVT-001 | ReferralDeposit (conditions, indexes, non-propagation) | unit |

---

## 14. Open Items (TBD / Decision Register)

### ZAP-TBD-001

Resolved in `ZAP-FR-006`, `ZAP-FR-010`, and `ZAP-EVT-001`.

### ZAP-TBD-002

Resolved in `ZAP-FR-009`.

### ZAP-TBD-003

Resolved in `ZAP-INV-001` and `ZAP-GOV-001`.

### ZAP-TBD-004

**Deferred: leverage support** — dToken-collateral leverage (open leveraged / lever up / lever down) is not MVP-critical. The user app does not expose Multiply for dToken branches. If provided later, it must not depend on Balancer or the removed Flash Loan callback; specify the JPYdf/USDC v4 final leg, asset-specific pre-leg, and Vault buffer / delayed redeem constraints as new requirements, either in a separate contract such as `LeverageCollateralYieldZapper` or an explicit route selector.

### ZAP-TBD-005

Resolved (2026-08-05, for the dwstETH branch): Branch 0's Underlying moved WETH → wstETH, and to keep native-ETH holders onboardable a **1 Tx native ETH route for open** was added as [ZAP-FR-015](#zap-fr-015-native-eth-on-ramp-ethstethwstethdwsteth) (ETH→stETH→wstETH→dwstETH). The route exists only on instances where it was explicitly enabled by a deployment parameter.

Still open: **native ETH add-collateral**, and native ETH UX on branches whose Underlying is WETH. For both, Day-1 adds no contract entrypoint; the frontend keeps inserting a prior `WETH.deposit` transaction for the shortfall.

### ZAP-TBD-006

Resolved in `ZAP-FR-003` and `ZAP-FR-004`.

### ZAP-TBD-007

Resolved in `ZAP-FR-009`.

### ZAP-TBD-008

**Frontend UX task: behavior when Cap / Underlying is unset** — Zapper calls on placeholder branches (`cap = 0` / Underlying unset) revert through dependency behavior (`CapExceeded` / `TokenInfoNotSet`). No additional Zapper guard is required. The frontend / admin console should hide user-facing flows and display branch inactive / cap zero / underlying unset.

### ZAP-TBD-009

**Resolved in code / activation still conditional: Sky USDC→USDS adapter** — `SkyUsdcSUsdsConverter` is the concrete implementation shared by Strategy and Zapper through `ISkyUsdcSUsdsConverter`. It uses Sky LitePSMWrapper-USDS-USDC `sellGem` / `buyGem`, validates `tin/tout` halt and fee bounds, 6↔18 decimal conversion, min-out, balance deltas, temporary allowance cleanup, and reverse-route refunds. The deploy script accepts `DF_STRATEGY_SKY_USDC_USDS_PSM_WRAPPER_i` and creates the concrete adapter instead of injecting an arbitrary converter. Before activation, mainnet-fork evidence must re-confirm the official wrapper and token bindings, current fees, halt state, and available liquidity, and operations must monitor governance fee/halt changes.

### ZAP-TBD-010

**Conditional: USDC-only liquidity / swap route production enablement** — Day-1 JPYdf DEX liquidity standardizes only the JPYdf/USDC Uniswap v4 pair after JPYdf deploy / issuance. `UniV4Exchange` is included in Day-1 audit scope. Curve routes, Uniswap v3 routes, direct USDT/USDS/WETH/XAUT JPYdf pools, and dToken/JPYdf pools are out of scope. Swap-backed close / collateral-funded repay / Multiply do not exist in the current ABI, and open / addColl / withdraw / close-with-JPYdf do not need them. If these flows are introduced later, finalize the JPYdf/USDC pool token addresses, fee, tick spacing, hook policy, pool key, position owner, slippage floor, frontend route selector, liquidity script, JPYdf / USDC amounts, and funding source, then retain fork/integration evidence. If non-USDC collateral needs a reverse route, do not add extra JPYdf pools; split the path into an Underlying→USDC pre-leg plus the JPYdf/USDC final leg, with separate asset-specific adapters and evidence. Enable v4 user-facing flow only after route config covers hook allowlist / no-hook policy, pool key, Universal Router / Permit2, and allowance cleanup, then add a new audited entrypoint.

---

## 15. References

- [Product Overview](../Product-Overview.md) — overall architecture and responsibility separation
- [CollateralVault requirements](CollateralVault.md) — deposit / redeem / delayed redemption / claim (dependency)
- [dToken requirements](dToken.md) — decimals / conversion (`convertToDToken` / `convertToUnderlying`) / permit (dependency)
- [Oracle requirements](Oracle.md)
- [Liquity-v2-Core-Spec.md](Liquity-v2-Core-Spec.md) — BorrowerOperations / TroveManager / safety mechanisms
- [Parameters.md](../../../Parameters.md) — finalized values such as collateral-specific mintCap / MIN_DEBT
- [requirements specification document standard](../../../README.md#requirements-spec-standard) — standard followed by this document
