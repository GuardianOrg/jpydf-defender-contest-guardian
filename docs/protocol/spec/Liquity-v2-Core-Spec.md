# 🔵 Liquity v2 Core Specification

## 0. Metadata

| Item | Value |
| --- | --- |
| Status | Draft (canonicalizing the inherited core specification) |
| Owner | DeltaForesight |
| Target contracts | The full Liquity v2 core set under `contracts/src/` (see the catalog in §5.1). The normative sources are the immutable upstream reference branch **`base`** (liquity/bold **v1.11.0**) and the DF deltas (🟡 6 value/behavioral/API/rendering deltas + 🟢 1 addition, §2.2). |
| Role of this document | 🔵 The **canonical source for the inherited core specification**. It normatively documents every core contract, every external/public function, every state variable, and every event with IDs, and provides the trace foundation for fork-source parity verification and DF delta management. |
| Related documents | [Product Overview](../Product-Overview.md) (system requirements / architecture) / [Parameters](../../../Parameters.md) (canonical source for parameter values) / [dToken](dToken.md), [CollateralVault](CollateralVault.md), [Strategy](strategies/Strategy.md), [Oracle](Oracle.md), [Zapper](Zapper.md) (🟢 original layers) / [README requirements specification standard](../../../README.md#requirements-spec-standard) |

> This document follows the [requirements specification standard](../../../README.md#requirements-spec-standard) (see §2.4 for how to read it as an inherited core specification). Requirements, invariants, and security requirements are assigned persistent IDs (`CORE-...`), and cross-references use those IDs.
>
> **Marker legend** — 🔵 Core: behavior of code that is byte-identical to `base` / 🟡 Modified: locations changed by DF (tracked in the §2.2 `CORE-MOD-*` ledger) / 🟢 Original: DF-specific additions and surface pruning (within this document's scope, LiquidationCandidateGetter and the Day-1 branch constant surface in Constants. The original layer implementations are covered by the respective component specs).

---

## 1. Purpose, Scope, and Non-Responsibilities

This document is the normative specification for the core contract set that DeltaForesight forks from Liquity v2 (BOLD) and inherits with **base parity as the baseline**.

- **This document specifies**:
  1. The responsibilities, interfaces, functional requirements (all external/public functions), state variables, events, invariants, security properties, and failure/exception behavior of all core contracts (§5-§12).
  2. **A complete ledger of DF deltas applied to the core** (§2.2 `CORE-MOD-*`). CI mechanically detects reintroduction of old BOLD-facing surfaces, while behavioral deltas, copy variants, Constants, etc. are controlled by this ledger and parity verification (§13).
  3. The acceptance criteria and verification plan for fork-source parity (§13): the trace foundation for tests confirming that "all functions and state variables operate the same way as the fork source."
- **This document does not specify (non-responsibilities / other documents)**:
  - 🟢 Requirements for original layers: dToken / CollateralVault / Strategy / Oracle (PriceFeedProxy and DF PriceFeed) / Zapper / Treasury / Frontend → each component spec.
  - **Final values** for collateral-branch parameters (MCR/CCR/SCR/BCR/penalty/mintCap, etc.) → [Parameters.md](../../../Parameters.md). This document specifies only their meaning and constraints.
  - Upstream governance (V2-gov / ve-LQTY / PIL voting) — outside this repository's core contracts and not adopted or finalized in jpydf (CORE-AP-TBD-001).
  - Deployment procedures, addresses, and progress → `development/` and deployment materials.
- **How to read this document**: §2.3 gives the overall intuition and mechanism. The normative body is §6 (functional requirements). For tests and audits, start from §8-§13 and follow the IDs.

---

## 2. Background and Design Policy

### 2.1 Adoption Policy — Base-Parity Fork and "Solving Outside"

JPY DeFi inherits Liquity v2 accounting, liquidation, and Redemption logic in a base-shaped form ([Product-Overview](../Product-Overview.md) `ARCH-001` / [`ADR-001`](../architecture/Architecture-Decision-Records.md#adr-001)). At the same time, the current protocol treats **JPYdf as the canonical debt-token / public API surface**, so BOLD naming surfaces are replaced with JPYdf naming and legacy exchange surfaces outside the Day-1 policy are removed. Behavioral customization is restricted to the following paths, and deltas are managed in the §2.2 ledger:

1. **Swapping generic interfaces** — provide dToken as the collateral ERC-20 and PriceFeedProxy as the price feed (the core does not know that the counterparty is a DF-specific layer).
2. **Parameter values** — constants in `Constants.sol` and branch-specific constructor / one-shot finalization inputs synchronized across AddressesRegistry, BorrowerOperations, and TroveManager storage.
  3. **Adding new deployed surfaces** — add interface-compatible deployed surfaces with minimal differences (DFStabilityPool, JPYdfTroveNFT / JPYdfMetadataNFT) or a new helper (LiquidationCandidateGetter).
4. **JPYdf naming surface** — standardize names that integrators touch, such as the debt token, BorrowerOperations API, and NFT metadata, on JPYdf.

The current mechanical CI guard is the **Core JPYDF surface guard** (`.github/scripts/check-core-jpydf-surface.sh`), which prevents old BOLD public/API names from re-entering owned protocol surfaces. The former blanket upstream byte-identity gate was appropriate while BOLD compatibility was preserved, but it conflicts with the current JPYdf canonical surface / legacy route pruning policy. Static parity against base is checked through the §2.2 ledger, diff review, and parity/unit tests.

### 2.2 DF Delta Ledger (`CORE-MOD-*`) 🟡

**All deltas that DF has applied to the core** are listed below (append-only). Any upstream-derived behavioral delta not listed here is treated as a spec / parity violation, while current CI separately detects reintroduction of old BOLD-facing surfaces. Each 🟡 requirement references this ledger.

> **Scope of the ledger**: This ledger manages only **deltas to core behavior or code** (value changes in upstream files, deployed interface-compatible variants, copy variants, and additions to upstream files). Pure newly added files that do not exist in `base` are outside this ledger unless they are wired into the deployed core in place of an upstream counterpart. 🟢 Original layers (dToken / CollateralVault / Strategy / Oracle / Zapper, etc.) are governed by their component specs; the 🟢 item within this document's scope (LiquidationCandidateGetter) is governed by `CORE-LCG-*`.

#### CORE-MOD-001: JPYdf Naming for the Debt Token 🟡

- **Target**: Debt-token naming surface (`JpydfToken.sol` / `IJpydfToken` / `jpydfToken()` / `JpydfTokenAddressChanged` / `_NAME` / `_SYMBOL`, etc.).
- **base**: `BoldToken` / `IBoldToken` / `boldToken` / `"BOLD Stablecoin"` / `"BOLD"` → **DF**: `JpydfToken` / `IJpydfToken` / `jpydfToken` / `"JPYdf Stablecoin"` / `"JPYdf"`.
- **Type**: Rename of identifiers, ABI getters/events, and ERC-20 metadata. Mint/burn/permit/permission logic remains base-shaped.
- **Reason**: Product naming (JPYdf) and a consistent debt-token surface for integrators.
- **Guard**: Naming deltas are tracked under CORE-MOD-001; parity / unit tests must verify that no behavioral delta is introduced.
- **Specification**: CORE-BT-FR-010.

#### CORE-MOD-002: Rescaling `MIN_DEBT` 🟡

- **Target**: `MIN_DEBT` in `Constants.sol`.
- **base**: `2000e18` (2,000 BOLD ≒ $2,000) → **DF**: `100_000e18` (100,000 JPYdf).
- **Type**: Constant value change.
- **Reason**: Set a JPY-denominated floor for spam-Trove resistance and liquidation viability. The approved production value is 100,000 JPYdf; no claim is made that it is economically equivalent to base's 2,000 BOLD. The canonical source for the final value is [Parameters.md](../../../Parameters.md).
- **Impact scope**: Minimum-debt checks on opening and adjustment, silent cap for repayments, and zombie threshold determination (CORE-BO-FR-001 and others, CORE-TM-FR-004).
- **Specification**: CORE-LIB-FR-002.

#### CORE-MOD-003: Relaxing the Liquidation Collateral Compensation Cap 🟡

- **Target**: TroveManager constructor, reserved-branch risk finalization and `Constants.sol`.
- **Rule**: `min(SP-offset collateral / COLL_GAS_COMPENSATION_DIVISOR, branch cap)`. The 0.5% rate is unchanged. Day1 caps are listed in [Parameters.md](../../../Parameters.md).
- **Reason**: ETH-like collateral and dollar stable collateral have different unit values; the upper limit must be chosen per branch.
- **Specification**: CORE-LIB-FR-003.

#### CORE-MOD-004: DFStabilityPool (SP Variant with Same-Block Settlement Guard) 🟡

- **Target**: New file `DFStabilityPool.sol` (full copy of `StabilityPool.sol` + minimal delta). **This is the Stability Pool that is deployed**; `StabilityPool.sol` is kept unmodified as the parity norm for base identity.
- **Functional delta (exactly 4 items; this is the complete set)**:
  1. Add state variable `mapping(address => uint256) public lastDepositBlock` (with a comment describing the design intent).
  2. In `provideToSP`, when an existing depositor uses `_doClaim=true` to receive current or stashed collateral gains, check `_requireCollGainClaimAfterDeposit()` to require a later block than the deposit block.
  3. In `provideToSP`, record `lastDepositBlock[msg.sender] = block.number` immediately after `DepositOperation` is emitted and before the state-update group.
  4. At the beginning of `withdrawFromSP`, immediately after `_requireUserHasDeposit`, check `_requireWithdrawalAfterDeposit()` (an internal helper added at the end of the contract: `require(lastDepositBlock[msg.sender] < block.number, "StabilityPool: Withdrawal must wait after deposit")`).
  (The mechanical diff also includes the contract-name replacement and the added helper-function hunk.)
- **Type**: Copy + added guards (the Product-Sum accounting is unchanged; collateral-gain payouts and withdrawals require the same block boundary).
- **Reason**: Blocks "liquidation gain sniping" in which flash loans or similar mechanisms atomically execute `provideToSP` → receive proportional liquidation gains → either `withdrawFromSP` or `provideToSP(nonzero, true)` to receive and externally convert the collateral gain in the liquidation block (CORE-SP-SEC-004).
- **Guard**: In the Core JPYDF surface guard this passes as a "newly added file," so **the fact that deltas from the copy source are limited to the 4 items above is managed by this ledger and parity tests (§13)**.
- **Specifications**: CORE-SP-FR-004 / CORE-SP-SEC-004 / CORE-SP-ERR-002.

#### CORE-MOD-005: Day-1 Branch Constant Surface in Constants 🟢

- **Target**: DF branch-specific constants (`MCR_DWSTETH`, etc.; 8 branches × 6 types = 48 constants) in `Constants.sol`.
- **Type**: Clarifies the constant surface used by the Day-1 production deploy. Production-unreferenced upstream fixture constants (`*_WETH` / `*_SETH` / `BCR_ALL`) and helper aliases (`ZERO_ADDRESS` / `MAX_UINT256`) are removed from `contracts/src` and kept inside inherited test fixtures when needed.
- **Reason**: Deployment wiring for the Day-1 eight branches (branch constructor arguments). Active Branches 0–1 use finalized values; reserved Branches 2–7 use bootstrap safety values that keep Core deployment valid until CORE-MOD-013 finalizes values once after the exact Underlying is selected.
- **Canonical source for values**: [Parameters.md](../../../Parameters.md) §2-A (not repeated in this document).
- **Specification**: CORE-LIB-FR-004.

#### CORE-MOD-006: JPYdf Naming for Debt-Token User-Facing APIs 🟡

- **Target**: Debt-token operation names in `BorrowerOperations.sol` / `IBorrowerOperations.sol`.
- **base**: `withdrawBold(uint256,uint256,uint256)` / `repayBold(uint256,uint256)` → **DF**: `withdrawJpydf(uint256,uint256,uint256)` / `repayJpydf(uint256,uint256)`.
- **Type**: ABI / identifier rename. Debt increase/decrease semantics, upfront fee behavior, silent repayment cap, minting, and burning remain base-shaped.
- **Reason**: Align user-facing integration surfaces with the JPYdf debt-token name and remove BOLD-derived function names from new integrations.
- **Impact scope**: BorrowerOperations user-facing borrow/repay functions, Zapper wrapper functions, frontend / SDK / ABI references. The internal accounting meaning (debt-token amount) is unchanged.
- **Specifications**: CORE-BO-FR-006 / CORE-BO-FR-007.

#### CORE-MOD-007: JPYdf TroveNFT / MetadataNFT Deployed Surface 🟡

- **Target**: `JPYdfTroveNFT.sol`, `Interfaces/IMetadataNFT.sol`, `NFTMetadata/JPYdfMetadataNFT.sol`, and `NFTMetadata/utils/JPYdfBaseSVG.sol`. Deployment scripts wire these through `AddressesRegistry.troveNFT()` / `metadataNFT()`. Under the fresh-deploy policy, undeployed upstream `TroveNFT.sol` / `MetadataNFT.sol` / `baseSVG.sol` have been removed from production `src`.
- **base**: Collection `name = "Liquity V2 - " + collToken.name()`, `symbol = "LV2_" + collToken.symbol()`, JSON metadata name / description use Liquity wording. → **DF deployed variant**: collection `name = "JPYdf - " + collToken.name()`, `symbol = "JPYdf_" + collToken.symbol()`, JSON metadata name / description and SVG fixed debt mark use JPYdf wording.
- **Type**: Interface-compatible deployment variant and rendering delta. Ownership, ERC-721 behavior, tokenId mapping, mint/burn authorization, tokenURI data source, and Trove-state coupling remain base-shaped.
- **Reason**: Product-facing NFT collection and on-chain metadata should identify the deployed protocol as JPYdf without relying on frontend/indexer aliases or undeployed upstream reference files.
- **Impact scope**: TroveNFT collection metadata, tokenURI JSON/SVG rendering, non-TM mint/burn error style (`JPYdfTroveNFT__CallerIsNotTroveManager()` custom error instead of upstream require string). No accounting or permission effect.
- **Specifications**: CORE-TN-FR-001 / CORE-TN-FR-002 / CORE-TN-FR-003 / CORE-TN-FR-006 / CORE-TN-ERR-001.

#### CORE-MOD-008: JpydfToken Bridge-Ready Dormant Extension 🟡

- **Target**: `JpydfToken.sol` / `IJpydfToken`
- **base**: `BoldToken` has no bridge admin, bridge minter registry, or bridge-specific mint/burn entrypoints after owner renounce. → **DF**: Core `mint` / `burn` authorization remains base-shaped, while a separate dormant surface adds `bridgeAdmin`, pending admin, a 48h timelocked bridge-minter registry, immediate minter removal, `bridgeMint(address,uint256)`, and self-burn-only `bridgeBurn(uint256)`. `bridgeAdmin` and bridge minters must be contract addresses and cannot overlap.
- **Type**: additive ABI / state / events / authorization. Bridge minters are not OR-added to existing Core `mint` / `burn`.
- **Reason**: Keep Day-1 Ethereum-only and dormant while avoiding a non-upgradeable token freeze that would permanently block future canonical token-only bridging.
- **Impact scope**: `JpydfToken` constructor args / CREATE2 preimage / deploy manifest / governance handover evidence / token supply monitoring. It does not affect Core branch logic, BO/TM/SP/AP mint/burn callers, or dToken collateral logic.
- **Specifications**: CORE-BT-FR-013 / CORE-BT-FR-014 / CORE-BT-FR-015 / CORE-BT-FR-016 / CORE-BT-INV-003 / CORE-BT-SEC-004 / CORE-BT-EVT-010.

#### CORE-MOD-009: JpydfToken Core Address Registration Hardening 🟡

- **Target**: `JpydfToken.setBranchAddresses` / `setCollateralRegistry`
- **base**: branch Core addresses and `CollateralRegistry` address are registered with no input validation beyond `onlyOwner`. → **DF**: registered addresses must be nonzero contract addresses (`code.length > 0`).
- **Type**: deploy-time hardening. Normal fresh-deploy wiring is unchanged; zero-address and codeless miswiring now revert early.
- **Reason**: Once `setCollateralRegistry` executes, owner is renounced and wrong Core address registrations cannot be corrected. Token-side minimum wiring invariants reduce deployment-procedure risk before audit/mainnet.
- **Impact scope**: one-time owner wiring functions in `JpydfToken`. It does not affect normal BO/TM/SP/AP/CR call paths, Core `mint` / `burn` authorization conditions, or the bridge-ready surface.
- **Specifications**: CORE-BT-FR-002 / CORE-BT-FR-003 / CORE-BT-SEC-002 / CORE-BT-ERR-001.

#### CORE-MOD-010: ERC-20 Transfer / Approval Hardening 🟡

- **Target**: `ActivePool.sol` / `BorrowerOperations.sol` / `DefaultPool.sol` / `GasPool.sol` / `RedemptionHelper.sol` / `TroveManager.sol`
- **base**: direct OpenZeppelin ERC-20 `approve` calls and typed token `transfer` / `transferFrom` calls. → **DF**: use `SafeERC20` `forceApprove` / `safeTransfer` / `safeTransferFrom`.
- **Type**: token integration hardening. For normal standard ERC-20 / WETH / JPYdf flows, asset-transfer meaning remains base-shaped; compatibility and failure detection are strengthened for zero-first approval tokens and tokens that do not return a bool.
- **Reason**: Core collateral is dToken, and future branch / adapter ERC-20 implementation differences should not become fragile assumptions. WETH gas compensation and RedemptionHelper JPYdf pull / refund paths also use safe wrappers so failures revert clearly.
- **Impact scope**: allowance setting, collateral transfer, WETH gas compensation, and RedemptionHelper JPYdf pull / refund. Accounting formulas, authorization conditions, and mint/burn conditions are unchanged.
- **Specifications**: CORE-SYS-INV-007 / CORE-SYS-INV-008 / CORE-RH-SEC-001 / CORE-GP-SEC-001.

#### CORE-MOD-011: ActivePool Aggregate Accounting Events 🟡

- **Target**: `ActivePool.sol`
- **base**: aggregate recorded debt / weighted debt / batch management fee state updates do not emit events. → **DF**: emit `ActivePoolAggRecordedDebtUpdated`, `ActivePoolAggWeightedDebtSumUpdated`, `ActivePoolAggBatchManagementFeesUpdated`, and `ActivePoolAggWeightedBatchManagementFeeSumUpdated` immediately after the relevant state updates.
- **Type**: observability-only event addition. State update formulas, rounding, and call order remain base-shaped; only log emission is added.
- **Reason**: ops dashboards / subgraphs / audit trails can track O(1) aggregate debt and batch fee changes.
- **Impact scope**: event ABI and log-emission gas. State variables, accounting formulas, external-call authorization, and return values are unchanged.
- **Specifications**: CORE-AP-EVT-* / SYS-NFR-005.

#### CORE-MOD-012: Dedicated Price Consumer for Urgent Redemption 🟡

- **Target**: `IPriceFeed.sol` / `TroveManager.sol`
- **base**: after irreversible shutdown, `urgentRedemption` uses `fetchPrice()` and bypasses the oracle-lag protection for normal redemption. → **DF**: add `fetchUrgentRedemptionPrice()` to IPriceFeed and connect only urgent lot calculation to this third path.
- **Type**: additive ABI plus post-shutdown price-selection change. Trove scanning, bonus, collateral cap, debt burn, authorization, and state layout are unchanged.
- **Reason**: if only the ETH price rises before the direct stETH/USD round updates, falling back to the normal price after irreversible shutdown can resume excess collateral extraction. The Oracle path uses a depeg-sensitive composite and fails closed instead of settling from cache when a required input is unavailable.
- **Impact scope**: the price used by `urgentRedemption`; the IPriceFeed source / Proxy / placeholder / testnet-mock ABI; and source-switch smoke tests. Normal borrowing, liquidation, and redemption are unaffected.
- **Specifications**: CORE-TM-FR-005 / ORCL-FR-016.

#### CORE-MOD-013: One-Shot Risk-Parameter Finalization for Reserved Branches 🟡

- **Target**: `AddressesRegistry.sol` / `IAddressesRegistry.sol` / `BorrowerOperations.sol` / `IBorrowerOperations.sol` / `TroveManager.sol` / `ITroveManager.sol` / `StabilityPool.sol` / `DFStabilityPool.sol` / `IStabilityPool.sol`.
- **base**: A branch's CCR / MCR / SCR / BCR and two liquidation penalties are copied into immutables at construction with no post-deployment change path. → **DF**: active branches remain finalized at deployment; only reserved branches whose exact Underlying is not yet selected allow the common Timelock fixed in the constructor to finalize the six risk values and collateral compensation cap exactly once.
- **Type**: additive ABI / authorization / lifecycle guard. The Registry's six values and BO/TM consumer copies use storage; the Registry passes the same validated values to `syncRiskParams(...)` in one transaction. Trove opening and `provideToSP` both reject an unfinalized branch before any state change.
- **Reason**: Avoid permanently fixing collateral-dependent risk values on Day 1 before a reserved branch's collateral is known, while still finalizing them together with the exact Underlying before economic activity. No repeatable governance setter is introduced.
- **Safety boundary**: Timelock-only, one-shot, exact-Underlying matching, cap / supply / Trove / debt / collateral / SP deposits all zero, oracle-failure pause cleared, terminal shutdown not executed, and revalidation of `SCR < MCR < CCR` plus penalty and urgent-redemption bounds. Any failure rolls back all state.
- **Impact scope**: Trove-open / SP-deposit gates for reserved branches, risk getter / event ABI, deployment, and the activation ceremony. Accounting, liquidation, redemption, and shutdown logic for finalized branches is unchanged.
- **Specifications**: CORE-AR-FR-001/003/005, CORE-BO-FR-001, CORE-SP-FR-002, CORE-SP-ERR-001, CORE-AR-INV-001, CORE-AR-SEC-002, CORE-SYS-INV-015, and CORE-SYS-GOV-002.

#### CORE-MOD-014: Oracle-Independent Risk-Reducing Adjustments 🟡

- **Target**: shared `_adjustTrove` in `BorrowerOperations.sol`.
- **DF behavior**: before irreversible shutdown, adjustments with `collDecrease == 0 && debtIncrease == 0` require no oracle quote, including during an oracle pause and below MCR or MCR+BCR. Any withdrawal or debt increase retains pause, current-price, ICR, and TCR checks.
- **Reason**: adding collateral and repaying improve backing even when no reliable price is available.
- **Safety boundary**: preserve authorization, repayment cap, nonzero adjustment, MIN_DEBT, batch accounting, and permanent-shutdown restrictions. Zombie reactivation still requires `newDebt >= MIN_DEBT`.
- **Impact scope**: addColl, repayJpydf, safe adjustTrove/adjustZombieTrove, and manager/Zapper routes reaching the shared path. Price-dependent operations use the separate Proxy 30h JPY gate.
- **Specifications**: CORE-BO-FR-003/004/007/008/022 and CORE-BO-ERR-004.

#### CORE-MOD-015: RedemptionHelper Normal-Redemption Availability Parity 🟡

- **Target**: `RedemptionHelper.sol`
- **base**: `simulateRedemption` determines branch redeemability / allocation from the normal price only, and `truncateRedemption` discards the failure bool returned by `fetchRedemptionPrice()`. → **DF**: simulation excludes normal-redemption-price failure branches from fill targets while retaining them in the same allocation denominator as CR. If every branch is unavailable it returns zero fill, and if any second price read fails, truncate zero-fills the whole estimate.
- **Type**: off-chain quote-parity hardening. Actual Core redemption, allocation formulas, burn, collateral transfer, and the wrapper's full refund are unchanged.
- **Reason**: if Helper ignores the PriceFeedProxy ORCL-FR-005 / `PRM-ORACLE-008` normal-redemption gate (30h shared JPY/USD round age), its estimate either over-allocates an unavailable branch's share to remaining branches or calculates an invalid min-out from a failure price.
- **Impact scope**: the quote surface of off-chain-intended `simulateRedemption` / `truncateRedemption`. In direct CR execution, TroveManager returns zero before state mutation; the Helper wrapper returns all unburned JPYdf as before.
- **Specifications**: CORE-RH-FR-002 / CORE-RH-FR-003 / CORE-RH-ERR-001 and ORCL-FR-005.

> **Delta list (summary table)** — Summary for readability; the detailed entries above are authoritative.
>
> | ID | Target file | Delta | Behavioral impact |
> | --- | --- | --- | --- |
> | CORE-MOD-001 🟡 | debt-token naming surface | Rename `BoldToken`/`boldToken`/display name to JPYdf terms | ABI names and metadata (logic remains base-shaped) |
> | CORE-MOD-002 🟡 | `Dependencies/Constants.sol` | `MIN_DEBT` value | Minimum debt and zombie threshold |
> | CORE-MOD-003 🟡 | `Dependencies/Constants.sol` | `COLL_GAS_COMPENSATION_CAP` value | Liquidation compensation cap |
> | CORE-MOD-004 🟡 | `DFStabilityPool.sol` (new) | SP copy + same-block settlement guard | Block-boundary constraint on collateral-gain payouts and SP withdrawals |
> | CORE-MOD-005 🟢 | `Dependencies/Constants.sol` | 48 DF branch-specific constants + removal of unused fixture constants | Day-1 deploy branch params |
> | CORE-MOD-006 🟡 | `BorrowerOperations.sol` / `IBorrowerOperations.sol` | Rename `withdrawBold`/`repayBold` to `withdrawJpydf`/`repayJpydf` | user-facing ABI names |
> | CORE-MOD-007 🟡 | `JPYdfTroveNFT.sol` / `IMetadataNFT.sol` / `JPYdfMetadataNFT.sol` / `JPYdfBaseSVG.sol` | JPYdf-branded TroveNFT and metadata deployed surface | product-facing collection / tokenURI rendering only |
> | CORE-MOD-008 🟡 | `JpydfToken.sol` / `IJpydfToken` | dormant bridge-ready surface | separate future bridge supply path; Day-1 minter count is zero |
> | CORE-MOD-009 🟡 | `JpydfToken.setBranchAddresses` / `setCollateralRegistry` | zero/codeless Core address rejection | deploy-time hardening only |
> | CORE-MOD-010 🟡 | core token transfer / approval call sites | `forceApprove` / `safeTransfer` / `safeTransferFrom` hardening | token integration compatibility and failure detection (accounting formulas remain base-shaped) |
> | CORE-MOD-011 🟡 | `ActivePool.sol` | aggregate accounting state update events | observability only (state update formulas remain base-shaped) |
> | CORE-MOD-012 🟡 | `IPriceFeed.sol` / `TroveManager.sol` | connect urgent redemption to a dedicated price consumer | post-shutdown price selection only (accounting, scanning, and bonus remain base-shaped) |
> | CORE-MOD-013 🟡 | `AddressesRegistry.sol` / BO / TM / SP + interfaces | Timelock-only one-shot risk finalization for reserved branches | synchronize risk values and the compensation cap before activation and gate Trove opening / SP deposits |
> | CORE-MOD-014 🟡 | `BorrowerOperations.sol` | allow pure collateral additions and repayments without oracle reads | safe adjustments remain available during oracle failure; risk increases and permanent-shutdown restrictions remain |
> | CORE-MOD-015 🟡 | `RedemptionHelper.sol` | reflect the normal-redemption failure bool in simulation / truncate | zero-fill estimates while preserving the CR allocation denominator; actual redemption accounting unchanged |
>
> Other "product-level differences from standard Liquity v2" are not core modifications, but instead arise from **how external components are supplied**: collateral = dToken ([dToken.md](dToken.md)); price = JPY-denominated synthesis by PriceFeedProxy ([Oracle.md](Oracle.md)); and the fact that Redemption converts at "1 JPYdf = ¥1 worth of collateral" is a consequence of the oracle returning JPY-denominated prices. The core formulas are identical to base.

### 2.3 Mechanism Overview (Informative, Non-Normative)

> The normative requirements start in §6. This section is a compressed summary for first-time readers; see each ID for details.

- **Branch (collateral-specific market)** — For each collateral type, a full set of BorrowerOperations / TroveManager / StabilityPool (DFStabilityPool) / ActivePool / DefaultPool / CollSurplusPool / GasPool / SortedTroves / TroveNFT / PriceFeed is deployed independently, and AddressesRegistry holds wiring and risk parameters (MCR/CCR/SCR/BCR/liquidation penalties). Active branches finalize values at deployment; reserved branches finalize once before activation, after which values cannot change (CORE-MOD-013). All branches are tied together by singletons (JpydfToken / CollateralRegistry / HintHelpers / MultiTroveGetter / DebtInFrontHelper / RedemptionHelper).
- **Trove (borrowing position)** — An ERC-721 (TroveNFT) position that deposits collateral and borrows JPYdf. `troveId = keccak256(msg.sender, owner, ownerIndex)`. Status is nonExistent / active / closedByOwner / closedByLiquidation / zombie (CORE-TM). On opening, the equivalent of `ETH_GAS_COMPENSATION` in WETH is locked in GasPool (source of gas compensation for liquidation executors; fixed in WETH even when the collateral is dToken).
- **User-set interest rates and aggregate interest** — Borrowers freely set annual interest within `[MIN_ANNUAL_INTEREST_RATE, MAX_ANNUAL_INTEREST_RATE]`. Interest is aggregated in **O(1)** as "weighted debt sum × elapsed time" (CORE-AP-FR-002), minted as JPYdf during arbitrary core operations, and distributed with **75% (`SP_YIELD_SPLIT`) to the SP and the remaining 25% to the interestRouter** (CORE-AP-FR-007. In jpydf's DF dToken wiring, this is bound to `InterestRouterForwarder`, and the final recipient / owner are managed via mandatory env and handover/verify. CORE-AP-TBD-001 is resolved).
- **Upfront fee / premature adjustment fee** — New borrowing and interest-rate changes within the cooldown add a fee equal to "branch average interest rate × 7 days" to the debt, economically discouraging extreme low-rate settings or last-minute changes to avoid redemption (CORE-BO-FR-001/011; estimates are in CORE-HH).
- **Redemption (autonomous correction of downward peg deviation)** — Anyone can exchange JPYdf for "¥1 worth of collateral." CollateralRegistry allocates across branches in proportion to unbacked debt (debt not covered by SP) (CORE-CR-FR-002), and within each branch it applies to **Troves with lower interest rates first** (CORE-TM-FR-004). The fee is a `baseRate` spike plus exponential decay with a 6h half-life (CORE-CR-FR-003-006). A Trove whose debt falls below `MIN_DEBT` due to redemption becomes **zombie** and is removed from SortedTroves (the next redemption exceptionally prioritizes `lastZombieTroveId`).
- **Liquidation (3-way split)** — Anyone can liquidate a Trove with `ICR < MCR` (CORE-TM-FR-002). Amounts covered by SP balance use **SP offset** (collateral with liquidation penalty goes to SP depositors); deficits are **redistributed to other Troves in the same branch** (with a higher penalty). JIT is also possible, where a liquidator deposits JPYdf into the SP on the spot when SP liquidity is thin to make offset possible. The executor receives "0.5% of collateral (cap 🟡 CORE-MOD-003) + WETH gas compensation"; surplus collateral after penalty deduction can be claimed by the borrower from CollSurplusPool.
- **Stability Pool** — Users deposit JPYdf to receive "75% of interest + liquidation collateral (discounted by the penalty)." Accounting uses the P-S-B product/sum snapshot method in O(1) (CORE-SP). **The deployed implementation is DFStabilityPool** (with the 🟡 CORE-MOD-004 guard against same-block collateral-gain settlement and withdrawal sniping). Additional rewards (from Treasury) are designed outside Core; [`SYS-RISK-003`](../../launch/gates/Mainnet-Launch-Risk-Gate.md#sys-risk-003) verifies that they are not presented as active before connection.
- **Safety mechanisms** — MCR / CCR restrictions / irreversible economic shutdown when `TCR < SCR`, plus a separate recoverable oracle-failure pause. Only economic shutdown stops interest and enables urgent redemption. During an oracle pause, normal redemption and risk-increasing adjustments stay blocked; collateral additions and debt repayments require no oracle quote and may proceed before validated resume (CORE-MOD-014). Interest keeps accruing throughout the pause (CORE-BO-FR-021/022, CORE-TM-FR-005).
- **Delegation** — Each Trove can configure an AddManager for deposit-side operations (addColl/repay), a RemoveManager + fixed receiver for withdrawal-side operations (withdraw/close), an Individual Delegate for interest adjustment, and a Batch Manager that manages the rates of multiple Troves together (with management fee and O(1) bulk changes) (CORE-BO-FR-012-020 / 025-027).

### 2.4 Normative Stance — "The Correct Source Is the Base Implementation" and How to Use This Document

- Each 🔵 requirement is not a newly designed DF requirement; it is a **descriptive normative statement of the behavior implemented in `base`**. If this document conflicts with the base implementation, **the base implementation is correct** and this document must be revised (the implementation must not be changed to match this document).
- 🟡 / 🟢 requirements are DF-owned prescriptive requirements. Conflicts are handled like normal requirements issues (determine whether the implementation is buggy or the requirement must be revised).
- The IDs in this document are referenced from (a) parity tests (§13), (b) code NatSpec `@custom:requirement`, and (c) audit findings and PR reviews. **IDs are append-only and must not be reused** (same convention as the [standard](../../../README.md#requirements-spec-standard); sequences are per scope).
- Specification granularity is based on "externally observable behavior of functions (state changes, reverts, events, and return values)." Internal implementation optimizations (such as `unchecked`) are described only when they affect behavior.

---

## 3. Terminology, External Dependencies, and Assumptions

**Terminology** (inherits [Product-Overview](../Product-Overview.md) §14 and adds core-specific terms)

| Term | Meaning |
| --- | --- |
| `base` | Immutable upstream reference branch. A frozen copy of liquity/bold v1.11.0. The norm for byte identity and parity. |
| parity | "Functioning identically to the fork source." Verified through the combination of old BOLD surface exclusion (Core JPYDF surface guard), the §2.2 ledger / diff review, and behavioral identity tests (§13). |
| BOLD / JPYdf | The upstream base concept is BOLD, but the DF implementation debt-token identifiers, getters, events, and metadata use JPYdf terms (`JpydfToken` / `IJpydfToken` / `jpydfToken`, etc.) (🟡 CORE-MOD-001). This document uses JPYdf names for implementation identifiers and BOLD only when describing upstream/base deltas. |
| Branch | An independent market deployed as one full set per collateral type (§2.3). |
| Trove | A borrowing position. Identified by `troveId` (uint256); ownership is represented by TroveNFT. |
| zombie | Status of a Trove whose `debt < MIN_DEBT` as the result of redemption. It is excluded from SortedTroves and normally excluded from redemption targets (liquidation, interest, and redistribution continue). |
| batch | A set of Troves whose interest rates are managed collectively by a Batch Manager. Maintained as a slice (contiguous interval) in SortedTroves. |
| ICR / TCR | Collateral ratio of an individual Trove / the whole branch (price is JPY-denominated as returned by PriceFeed). |
| MCR / CCR / SCR / BCR | Liquidation threshold / critical threshold / shutdown threshold / extra ICR buffer for joining a batch (per branch; active values are finalized at deployment, reserved values once before activation; values are in [Parameters.md](../../../Parameters.md)). |
| upfront fee | Fee added to debt on new borrowing and premature interest-rate changes, equal to "average interest rate × `UPFRONT_INTEREST_PERIOD` (7 days)." |
| baseRate | System-wide redemption fee-rate component managed by CollateralRegistry; spikes according to redemption amount and decays exponentially. |
| offset / redistribution | SP offset of liquidation debt / proportional transfer to other Troves in the same branch. |
| P, S, B | SP product/sum accounting trackers: deposit depletion product P, collateral gain sum S, and yield gain sum B. |
| `ETH_GAS_COMPENSATION` | Liquidation gas compensation locked in WETH when a Trove is opened (WETH-denominated regardless of collateral type). |
| interestRouter | Destination for the remaining 25% of aggregate interest (immutable. In DF dToken wiring, this is `InterestRouterForwarder`. CORE-AP-TBD-001 is resolved). |

**External dependencies (external components trusted by the core)**

| Dependency | How the core sees it | DF implementation |
| --- | --- | --- |
| Collateral ERC-20 (`collToken`) | An ordinary 18-decimal ERC-20. `transfer`/`transferFrom` succeed or fail according to the standard. | dToken ([dToken.md](dToken.md)). dToken guarantees it is not fee-on-transfer or rebasing. |
| Price feed (`priceFeed`) | `fetchPrice()` / `fetchRedemptionPrice()` return "JPY-denominated price of 1 unit of collateral (18 decimals)" and an oracle health flag. | PriceFeedProxy ([Oracle.md](Oracle.md)). On failure it is responsible for calling `shutdownFromOracleFailure`. |
| WETH | ERC-20 used to lock, return, and pay gas compensation. | Canonical WETH9. |
| OpenZeppelin v4.9.5 | Standard implementations such as ERC20Permit (JpydfToken) and ERC721 (TroveNFT). | lib (version pinned). |

**Assumptions**

- The core is deployed on Ethereum mainnet as a single-chain, 8-branch system ([Parameters.md](../../../Parameters.md) §1).
- The core and JpydfToken are **non-upgradeable**. Wiring is immutable after deployment, and branch risk parameters become immutable either at active-branch deployment or after the reserved branch's one-shot finalization (§10).
- Price and collateral reliability are secured outside the core (Oracle / dToken layers). The core operates with those as given.

---

## 4. Actors, Roles, and Trust Boundaries

**External actors**

| Actor | Main operations | Trust |
| --- | --- | --- |
| Borrower (Trove owner) | openTrove / adjustments / closeTrove / claimCollateral / delegation settings | Assumed adversarial (permissionless; aligned by checks and incentives). |
| AddManager / RemoveManager / receiver | Deposit-side operations / withdrawal-side operations (receiver can be fixed). | Appointed by owner (CORE-BO-SEC-001/002). |
| Individual Delegate / Batch Manager | Interest-rate adjustment / batch interest-rate and fee management. | Appointed by owner. Constrained by rate ranges and change intervals. |
| SP depositor | provideToSP / withdrawFromSP / claimAllCollGains | Assumed adversarial (🟡 same-block guard = CORE-MOD-004). |
| Redeemer | CollateralRegistry.redeemCollateral (including through RedemptionHelper) | Assumed adversarial (aligned by fees and routing). |
| Liquidator | batchLiquidateTroves / urgentRedemption | Assumed adversarial (incentivized by compensation). |
| Any third party | Conditional permissionless operations such as shutdown (when TCR<SCR), kickFromBatch, and applyPendingDebt. | Assumed adversarial (CORE-BO-SEC-005). |
| Deployer | Deployment and wiring (AddressesRegistry.setAddresses / JpydfToken.setBranchAddresses, etc.) | **Renounces ownership once wiring is complete**, after which privileges disappear (§10). |
| Risk-parameter finalizer | Finalize the exact Underlying, six risk values and compensation cap for a reserved branch once before activation | Timelock fixed immutably in the constructor; cannot exercise the authority after finalization (CORE-AR-FR-005). |

**Inter-contract trust boundaries (summary of the only-X call graph)** — Normative details are in each SEC requirement.

| Callee ← Caller | Restriction |
| --- | --- |
| TroveManager `on*` hooks ← BorrowerOperations only | CORE-TM-SEC-001 |
| TroveManager.redeemCollateral ← CollateralRegistry only | CORE-TM-SEC-002 |
| BorrowerOperations.onLiquidateTrove ← TroveManager only | CORE-BO-SEC-003 |
| BorrowerOperations.shutdownFromOracleFailure ← priceFeed only | CORE-BO-SEC-003 |
| BorrowerOperations / TroveManager `syncRiskParams` ← AddressesRegistry only | CORE-BO-SEC-006 / CORE-TM-SEC-008 |
| StabilityPool.offset ← TroveManager only / triggerJpydfRewards ← ActivePool only | CORE-SP-SEC-001/002 |
| ActivePool fund and accounting operations ← BO / TM / SP (restricted per function) | CORE-AP-SEC-001 |
| DefaultPool ← ActivePool / TroveManager only | CORE-DP-SEC-001 |
| CollSurplusPool.accountSurplus ← TM / claimColl ← BO | CORE-CSP-SEC-001 |
| SortedTroves writes ← BO / TM only | CORE-ST-SEC-001 |
| TroveNFT.mint/burn ← TroveManager only | CORE-TN-SEC-001 |
| JpydfToken.mint ← BO / AP only. burn ← CR / registered BO, TM, SP. sendToPool/returnFromPool ← SP only | CORE-BT-SEC-001 |

- The core **does not know the internals of dToken** (Underlying or Strategy operation) and trusts only the ERC-20 surface of `collToken` ([Product-Overview](../Product-Overview.md) ARCH-002/003). Impairment of dToken backing is propagated as price (multiplication by backing ratio) and handled by the core's liquidation and shutdown mechanisms.
- **Reentrancy surface**: The core touches only collToken (dToken), WETH, and JPYdf as external tokens, and assumes none has transfer hooks (guaranteed by the dToken layer). The core does not include nonReentrant guards; CEI ordering and caller restrictions are the basis of reentrancy defense (each SEC requirement).

---

## 5. Contract Structure and Interface Specification

### 5.1 Contract Catalog (Full Core)

All contracts that constitute the core and the ID scopes in this document. **Deployment unit**: branch = one per collateral branch / singleton = one per system.

| Contract | Deployment unit | Marker | ID scope | Overview |
| --- | --- | --- | --- | --- |
| BorrowerOperations | branch | 🔵/🟡 | `CORE-BO-*` | Single entry point for borrower and delegate operations (🟡 unfinalized reserved-branch open gate / risk sync) |
| TroveManager | branch | 🔵/🟡 | `CORE-TM-*` | Trove status ledger, liquidation, redemption, and shutdown (🟡 risk sync) |
| StabilityPool (normative) / **DFStabilityPool (deployed implementation)** | branch | 🔵/🟡 | `CORE-SP-*` | JPYdf deposit pool that funds liquidation offsets (🟡 CORE-MOD-004) |
| ActivePool | branch | 🔵 | `CORE-AP-*` | Central accounting for active collateral, aggregate debt, and interest minting |
| DefaultPool | branch | 🔵 | `CORE-DP-*` | Custody of collateral and debt pending redistribution |
| CollSurplusPool | branch | 🔵 | `CORE-CSP-*` | Custody of claims to surplus collateral from liquidations |
| GasPool | branch | 🔵 | `CORE-GP-*` | Custody for locked WETH gas compensation |
| SortedTroves | branch | 🔵 | `CORE-ST-*` | Doubly linked list sorted by descending interest rate (foundation of redemption order) |
| **JPYdfTroveNFT deployed surface** (+ `IMetadataNFT` / **JPYdfMetadataNFT**) | branch | 🔵/🟡 | `CORE-TN-*` | Trove ownership ERC-721 and on-chain metadata (🟡 CORE-MOD-007 for product-facing collection / tokenURI rendering) |
| JpydfToken | singleton | 🔵/🟡 | `CORE-BT-*` | Debt token JPYdf (🟡 debt-token naming surface, CORE-MOD-001) |
| CollateralRegistry | singleton | 🔵 | `CORE-CR-*` | Entry point for cross-branch redemption and baseRate management |
| AddressesRegistry | branch | 🔵/🟡 | `CORE-AR-*` | Holds wiring and risk parameters finalized once (🟡 CORE-MOD-013) |
| HintHelpers | singleton | 🔵 | `CORE-HH-*` | View helper for hint search and upfront fee estimates |
| MultiTroveGetter | singleton | 🔵 | `CORE-MTG-*` | Batch Trove retrieval view |
| DebtInFrontHelper | singleton | 🔵 | `CORE-DFH-*` | Debt-in-front (redemption risk) calculation view |
| RedemptionHelper | singleton | 🔵/🟡 | `CORE-RH-*` | Redemption slippage-protection wrapper and failure-aware simulation (🟡 CORE-MOD-015) |
| LiquidationCandidateGetter | singleton | 🟢 | `CORE-LCG-*` | Paging scan view for liquidation candidates (DF addition) |
| Dependencies (Constants / LiquityBase / LiquityMath / Ownable) and Types | (libraries/base) | 🔵 (partly 🟡/🟢) | `CORE-LIB-*` | Constants (🟡 CORE-MOD-002/003, 🟢 005), common accounting, math, and types |

**Peripheral production `src` surfaces / catalog-only files** (old BOLD surface reintroduction is detected by the Core JPYDF surface guard):

| Path | Treatment |
| --- | --- |
| `PriceFeeds/` (upstream series: CompositePriceFeed / MainnetPriceFeedBase) | DF branches use DF oracle implementations (PriceFeedProxy + DF*PriceFeed). The norm is [Oracle.md](Oracle.md). The undeployed upstream WETH wrapper and WSTETH / RETH collateral feeds have been removed from production `src`. `CompositePriceFeed` is also pruned to the sUSDS primary -> `lastGoodPrice` path, with the WSTETH/RETH LST secondary fallback removed. |
| `Zappers/` (DF-added zappers plus required interfaces/modules) | DF Zapper requirements are in [Zapper.md](Zapper.md). Upstream-derived WETH / GasComp / leverage Zappers and legacy Curve / Hybrid / Uniswap v3 exchange adapter surfaces have been removed from production `src` because they are outside the Day-1 policy. Deployment materials remain canonical for mainnet wiring. |
| `Interfaces/` (current protocol surface interfaces) | The specified IF for each contract is handled in the relevant §5 subsection. Unused upstream LQTY / BOLD IFs (`ILQTYToken` / `ILQTYStaking` / `ICommunityIssuance` / `IBoldToken` / `IBoldRewardsReceiver`) have either been removed when unused or replaced by `IJpydfToken` / `IJpydfRewardsReceiver` for the debt-token surface. The V2-gov / LQTY staking surface is removed from the Day-1 deploy and test paths; `contracts/lib/V2-gov` is treated as a vendored dependency tree outside this specification. Unused WSTETH / RETH price feed interfaces have also been removed from production `src`. |
| `NFTMetadata/utils/` (SVG / JSON / JPYdfBaseSVG / bauhaus / FixedAssets / Utils) | Treated as a catalog item in the TroveNFT section (CORE-TN-FR-006). Undeployed upstream `baseSVG.sol` has been removed. |

> **Coverage (confirmation that nothing is omitted)**: `contracts/src` in `base` (the frozen liquity/bold v1.11.0 reference) has **102** files (breakdown: root 16 / `Dependencies` 6 / `Types` 5 / `Interfaces` 31 / `NFTMetadata` 7 / `PriceFeeds` 5 / `Zappers` 32). Current `contracts/src` has **97** Solidity files (root 21 / `Dependencies` 6 / `Types` 4 / `Interfaces` 30 / `NFTMetadata` 7 / `PriceFeeds` 11 / `Zappers` 11 / `Strategies` 7; excluding `README.md`). At the path level, the delta consists of deleting or replacing base paths such as the BOLD/LQTY naming surface, legacy Curve / Hybrid / Uniswap v3 exchange surface, WETH / GasComp / leverage upstream Zapper surface, WETH / WSTETH / RETH collateral feed surface, undeployed upstream NFT renderer surface, and the unreferenced `Types/TroveId.sol` helper, and adding or replacing paths such as JPYdf token, dToken, CollateralVault, Strategy family, DF Oracle, Uniswap v4, Sky, CollateralYieldZapper, and extracted `IMetadataNFT` interface paths. They are divided into the core normatively specified here (root core contracts + `Dependencies` / `Types` = `CORE-*` / `CORE-LIB-*`), DF Oracle / Zapper / NFT deployed surfaces, and required interfaces; there is no unaccounted file. `test` / `script` / `certora` under `contracts/` are outside the normative scope of all specs (tests, deployment, and formal verification).

> The following sections provide, contract by contract, an "overview + interface list (non-normative)." Behavioral norms are in §6 Functional Requirements.

### BorrowerOperations (Single Entry Point for Borrower Operations) 🔵/🟡

BorrowerOperations (BO) is the sole entry point through which borrowers (and borrower-appointed managers/delegates) operate Troves. One instance is deployed per collateral branch and wired through AddressesRegistry to the same branch's TroveManager / ActivePool / DefaultPool / SortedTroves / CollSurplusPool / GasPool / TroveNFT / JpydfToken / PriceFeed. It inherits `LiquityBase` (branch total coll/debt retrieval and TCR calculation) and `AddRemoveManagers` (per-Trove operation delegation: AddManager / RemoveManager / receiver). This section also specifies the inherited AddRemoveManagers surface (`setAddManager` / `setRemoveManager` / `setRemoveManagerWithReceiver` / `addManagerOf` / `removeManagerReceiverOf`) within the BO scope.

Its responsibility is to perform input validation and health checks (ICR/TCR/MIN_DEBT/upfront fee), then instruct state updates through TroveManager hooks (`onOpenTrove` / `onAdjustTrove`, etc.) and ActivePool aggregation (`mintAggInterestAndAccountForTroveChange`), and execute token movement (collateral = dToken, JPYdf mint/burn, and WETH gas compensation). Trove state itself (records of coll/debt/interest rate, NFT, and batch share accounting) is held by TroveManager (CORE-TM series). The collateral token is the branch's dToken ([dToken.md](dToken.md)), and prices are obtained by calling `fetchPrice()` on PriceFeedProxy ([Oracle.md](Oracle.md)).

Borrowing, adjustment, and shutdown accounting remains base-shaped (🔵). DF deltas are limited to the JPYdf API rename, SafeERC20 hardening, the unfinalized reserved-branch open gate and AddressesRegistry-only risk sync (🟡 CORE-MOD-006/010/013), and the referenced `MIN_DEBT` constant (🟡 CORE-MOD-002 / CORE-LIB-FR-002).

**Interface List (Non-Normative; Behavioral Norms Are in §6)**

| Function | Visibility / Permission | Summary | Spec ID |
| --- | --- | --- | --- |
| `openTrove(address,uint256,uint256,uint256,uint256,uint256,uint256,uint256,address,address,address) → uint256` | external / permissionless | Open a new Trove (individual interest rate) | CORE-BO-FR-001 |
| `openTroveAndJoinInterestBatchManager(OpenTroveAndJoinInterestBatchManagerParams) → uint256` | external / permissionless | Open a new Trove and join a batch at the same time | CORE-BO-FR-002 |
| `adjustTrove(uint256,uint256,bool,uint256,bool,uint256)` | external / owner or managers (depending on change direction) | Combined collateral and debt adjustment | CORE-BO-FR-003 |
| `addColl(uint256,uint256)` | external / owner or AddManager family | Add collateral | CORE-BO-FR-004 |
| `withdrawColl(uint256,uint256)` | external / owner or RemoveManager | Withdraw collateral | CORE-BO-FR-005 |
| `withdrawJpydf(uint256,uint256,uint256)` | external / owner or RemoveManager | Additional borrowing (JPYdf mint) | CORE-BO-FR-006 |
| `repayJpydf(uint256,uint256)` | external / owner or AddManager family | Repay (JPYdf burn) | CORE-BO-FR-007 |
| `adjustZombieTrove(uint256,uint256,bool,uint256,bool,uint256,uint256,uint256)` | external / owner or managers (depending on change direction) | Adjust a zombie Trove and return it to active | CORE-BO-FR-008 |
| `closeTrove(uint256)` | external / owner or RemoveManager | Close Trove (full repayment) | CORE-BO-FR-009 |
| `applyPendingDebt(uint256,uint256,uint256)` | public / permissionless | Apply interest, redistribution, and batch fee to recorded values | CORE-BO-FR-010 |
| `adjustTroveInterestRate(uint256,uint256,uint256,uint256,uint256)` | external / owner or individual interest delegate | Change an individual Trove's interest rate | CORE-BO-FR-011 |
| `setInterestIndividualDelegate(uint256,address,uint128,uint128,uint256,uint256,uint256,uint256,uint256)` | external / owner | Set individual interest delegate | CORE-BO-FR-012 |
| `removeInterestIndividualDelegate(uint256)` | external / owner | Remove individual interest delegate | CORE-BO-FR-013 |
| `registerBatchManager(uint128,uint128,uint128,uint128,uint128)` | external / permissionless (self-registration) | Register a batch manager | CORE-BO-FR-014 |
| `setBatchManagerAnnualInterestRate(uint128,uint256,uint256,uint256)` | external / registered batch manager | Change batch interest rate in bulk | CORE-BO-FR-015 |
| `lowerBatchManagementFee(uint256)` | external / registered batch manager | Lower batch management fee | CORE-BO-FR-016 |
| `setInterestBatchManager(uint256,address,uint256,uint256,uint256)` | public / owner | Join an existing Trove to a batch | CORE-BO-FR-017 |
| `removeFromBatch(uint256,uint256,uint256,uint256,uint256)` | public / owner | Leave a batch (set interest back to individual) | CORE-BO-FR-018 |
| `kickFromBatch(uint256,uint256,uint256)` | external / permissionless | Force removal from a batch whose shares ratio has deteriorated | CORE-BO-FR-019 |
| `switchBatchManager(uint256,uint256,uint256,address,uint256,uint256,uint256)` | external / owner | Switch batches (leave + join) | CORE-BO-FR-020 |
| `shutdown()` | external / permissionless | Branch shutdown when TCR < SCR | CORE-BO-FR-021 |
| `shutdownFromOracleFailure()` | external / PriceFeed only | Enter recoverable oracle-failure pause | CORE-BO-FR-022 |
| `resumeFromOracleFailure()` | external / PriceFeed only | Clear recoverable pause after Proxy validation | CORE-BO-FR-022 |
| `onLiquidateTrove(uint256)` | external / TroveManager only | Clear BO-side mappings during liquidation | CORE-BO-FR-023 |
| `claimCollateral()` | external / permissionless | Withdraw surplus collateral from liquidation (delegates to CollSurplusPool) | CORE-BO-FR-024 |
| `setAddManager(uint256,address)` | external / owner | Set AddManager (AddRemoveManagers inheritance) | CORE-BO-FR-025 |
| `setRemoveManagerWithReceiver(uint256,address,address)` | public / owner | Set RemoveManager + receiver (same) | CORE-BO-FR-026 |
| `setRemoveManager(uint256,address)` | external / owner | Set RemoveManager (receiver=owner; same) | CORE-BO-FR-027 |
| `syncRiskParams(uint256,uint256,uint256,uint256)` | external (AddressesRegistry only) | Synchronize finalized CCR / MCR / BCR / SCR from the Registry | CORE-BO-FR-030 |
| `CCR() → uint256` | public view | Critical threshold CCR (immutable after finalization) | CORE-BO-FR-028 |
| `SCR() → uint256` | public view | Shutdown threshold SCR (immutable after finalization) | CORE-BO-FR-028 |
| `MCR() → uint256` | public view | Minimum collateral ratio for individual Troves (immutable after finalization) | CORE-BO-FR-028 |
| `BCR() → uint256` | public view | Additional buffer for batch-member Troves (immutable after finalization) | CORE-BO-FR-028 |
| `hasBeenShutDown() → bool` | public view | Irreversible economic-shutdown flag | CORE-BO-FR-028 |
| `isOracleFailureShutdown() → bool` | public view | Recoverable oracle-failure pause flag | CORE-BO-FR-028 |
| `interestBatchManagerOf(uint256) → address` | public view | Batch manager to which a Trove belongs | CORE-BO-FR-028 |
| `getInterestBatchManager(address) → InterestBatchManager` | external view | Batch manager registration record | CORE-BO-FR-028 |
| `getInterestIndividualDelegateOf(uint256) → InterestIndividualDelegate` | external view | Individual interest delegate record | CORE-BO-FR-028 |
| `checkBatchManagerExists(address) → bool` | external view | Whether a batch manager is registered | CORE-BO-FR-028 |
| `addManagerOf(uint256) → address` | public view (automatic getter) | Query AddManager (AddRemoveManagers inheritance) | CORE-BO-FR-028 |
| `removeManagerReceiverOf(uint256) → (address,address)` | public view (automatic getter) | Query RemoveManager and receiver (same) | CORE-BO-FR-028 |
| `activePool() → address` | public view | ActivePool reference (LiquityBase inheritance; LIB governs the specification) | CORE-BO-FR-028 |
| `getEntireBranchColl() → uint256` | public view | Total branch collateral (AP+DP; LiquityBase inheritance) | CORE-BO-FR-028 |
| `getEntireBranchDebt() → uint256` | public view | Total branch debt (AP+DP; LiquityBase inheritance) | CORE-BO-FR-028 |


### TroveManager (Core Trove Status Ledger, Liquidation, and Redemption) 🔵/🟡

TroveManager is deployed once per collateral branch and acts as the Trove status ledger and the execution engine for liquidation and Redemption. It has no user-facing borrower entry point. Its surface consists of three groups: (1) permissionless liquidation `batchLiquidateTroves` and post-shutdown `urgentRedemption`, (2) `redeemCollateral`, callable only by CollateralRegistry, and (3) `on*` callbacks, `shutdown`, and `setTroveStatusToActive`, callable only by BorrowerOperations. It holds the Trove struct, Batch struct, and redistribution accounting (`L_coll` / `L_jpydfDebt` / `rewardSnapshots` / `totalStakes`), derives latest Trove/Batch states including interest (`LatestTroveData` / `LatestBatchData`), and provides them to BorrowerOperations, HintHelpers, and others. Fund movement is performed through ActivePool / DefaultPool / StabilityPool / CollSurplusPool / GasPool; TroveManager itself does not custody tokens. The collateral token is dToken ([dToken.md](dToken.md)); price retrieval (`fetchPrice` / `fetchRedemptionPrice`) is delegated to PriceFeedProxy ([Oracle.md](Oracle.md)). The debt token is JpydfToken (JPYdf in DF; see the CORE-BT section). Trove ownership is represented by TroveNFT (ERC-721), and TroveManager instructs minting on open and burning on close.

**Interface List (Non-Normative; Behavioral Norms Are in §6)**

| Function | Visibility / Permission | Summary | Spec ID |
| --- | --- | --- | --- |
| `batchLiquidateTroves(uint256[])` | external (permissionless) | Liquidate the specified Troves whose ICR < MCR | CORE-TM-FR-001 / 002 / 003 |
| `redeemCollateral(address,uint256,uint256,uint256,uint256) → uint256` | external (onlyCollateralRegistry) | Normal Redemption (APR-ascending scan) | CORE-TM-FR-004 |
| `urgentRedemption(uint256,uint256[],uint256)` | external (permissionless; only after shutdown) | Emergency Redemption after shutdown (with bonus) | CORE-TM-FR-005 |
| `shutdown()` | external (onlyBorrowerOperations) | Record branch shutdown and propagate to ActivePool | CORE-TM-FR-006 |
| `getUnbackedPortionPriceAndRedeemability() → (uint256,uint256,bool)` | external (**nonpayable**; permissionless) | Unbacked debt, price, and redeemability (not view because it calls `fetchPrice`) | CORE-TM-FR-012 |
| `getCurrentICR(uint256,uint256) → uint256` | public view | Current ICR including redistribution and interest | CORE-TM-FR-008 |
| `getLatestTroveData(uint256) → LatestTroveData` | external view | Latest Trove state including interest and redistribution | CORE-TM-FR-009 |
| `getLatestBatchData(address) → LatestBatchData` | external view | Latest Batch state including interest and management fee | CORE-TM-FR-010 |
| `getTroveAnnualInterestRate(uint256) → uint256` | external view | Effective annual interest rate of a Trove (batch rate if in a batch) | CORE-TM-FR-011 |
| `onOpenTrove(address,uint256,TroveChange,uint256)` | external (onlyBorrowerOperations) | Record state for Trove opening | CORE-TM-FR-014 |
| `onOpenTroveAndJoinBatch(address,uint256,TroveChange,address,uint256,uint256)` | external (onlyBorrowerOperations) | Open Trove with batch join | CORE-TM-FR-015 |
| `setTroveStatusToActive(uint256)` | external (onlyBorrowerOperations) | Return zombie Trove to active | CORE-TM-FR-016 |
| `onAdjustTrove(uint256,uint256,uint256,TroveChange)` | external (onlyBorrowerOperations) | Record state for Trove adjustment | CORE-TM-FR-017 |
| `onAdjustTroveInterestRate(uint256,uint256,uint256,uint256,TroveChange)` | external (onlyBorrowerOperations) | Record state for individual interest-rate change | CORE-TM-FR-018 |
| `onAdjustTroveInsideBatch(uint256,uint256,uint256,TroveChange,address,uint256,uint256)` | external (onlyBorrowerOperations) | Adjust Trove inside a batch | CORE-TM-FR-019 |
| `onApplyTroveInterest(uint256,uint256,uint256,address,uint256,uint256,TroveChange)` | external (onlyBorrowerOperations) | Record application of accrued interest and redistribution | CORE-TM-FR-020 |
| `onCloseTrove(uint256,TroveChange,address,uint256,uint256)` | external (onlyBorrowerOperations) | Close Trove (`closedByOwner`) | CORE-TM-FR-021 |
| `onRegisterBatchManager(address,uint256,uint256)` | external (onlyBorrowerOperations) | Register batch manager | CORE-TM-FR-022 |
| `onLowerBatchManagerAnnualFee(address,uint256,uint256,uint256)` | external (onlyBorrowerOperations) | Lower batch management fee | CORE-TM-FR-023 |
| `onSetBatchManagerAnnualInterestRate(address,uint256,uint256,uint256,uint256)` | external (onlyBorrowerOperations) | Change batch interest rate | CORE-TM-FR-024 |
| `onSetInterestBatchManager(OnSetInterestBatchManagerParams)` | external (onlyBorrowerOperations) | Join an existing Trove to a batch | CORE-TM-FR-025 |
| `onRemoveFromBatch(uint256,uint256,uint256,TroveChange,address,uint256,uint256,uint256)` | external (onlyBorrowerOperations) | Remove Trove from batch | CORE-TM-FR-026 |
| `syncRiskParams(RiskParams)` | external (AddressesRegistry only) | Synchronize finalized CCR / MCR / SCR, two liquidation penalties and compensation cap | CORE-TM-FR-028 |
| `CCR() → uint256` | public view | Stored branch CCR (immutable after finalization) | CORE-TM-FR-013 |
| `Troves(uint256) → (uint256,uint256,uint256,uint8,uint64,uint64,uint64,uint256,address,uint256)` | public view | Raw Trove struct values (pending values not applied) | CORE-TM-FR-013 |
| `rewardSnapshots(uint256) → (uint256,uint256)` | public view | Trove L_coll / L_jpydfDebt snapshot | CORE-TM-FR-013 |
| `batchIds(uint256) → address` | public view | Batch manager address array | CORE-TM-FR-013 |
| `lastZombieTroveId() → uint256` | public view | Pointer to the most recently partially redeemed zombie Trove | CORE-TM-FR-013 |
| `shutdownTime() → uint256` | public view | Shutdown timestamp (0 = not shut down) | CORE-TM-FR-013 |
| `getTroveIdsCount() → uint256` | external view | Length of TroveIds array | CORE-TM-FR-013 |
| `getTroveFromTroveIdsArray(uint256) → uint256` | external view | Indexed access into TroveIds array | CORE-TM-FR-013 |
| `getTroveStatus(uint256) → Status (uint8)` | external view | Trove Status | CORE-TM-FR-013 |
| `troveNFT() → address` | public view | Connected TroveNFT | CORE-TM-FR-013 |
| `borrowerOperations() → address` | public view | Connected BorrowerOperations | CORE-TM-FR-013 |
| `stabilityPool() → address` | public view | Connected StabilityPool | CORE-TM-FR-013 |
| `sortedTroves() → address` | public view | Connected SortedTroves | CORE-TM-FR-013 |
| `activePool() → address` | public view (LiquityBase inheritance) | Connected ActivePool | CORE-TM-FR-013 |
| `getEntireBranchColl() → uint256` | public view (LiquityBase inheritance) | Total collateral in ActivePool + DefaultPool | CORE-TM-FR-013 |
| `getEntireBranchDebt() → uint256` | public view (LiquityBase inheritance) | Total debt in ActivePool + DefaultPool | CORE-TM-FR-013 |

(ABI has 39 functions. `MCR` / `SCR` / `LIQUIDATION_PENALTY_*` have no getters because they are internal storage values.)


### StabilityPool / DFStabilityPool (JPYdf Deposit Pool that Absorbs Liquidation Offsets) 🔵/🟡

StabilityPool (SP) holds JPYdf deposited by depositors, offsets the debt of liquidated Troves when TroveManager calls `offset` (burning JPYdf), and in exchange distributes liquidation collateral (dToken, [dToken.md](dToken.md)) proportionally to depositors. In addition, it receives the `SP_YIELD_SPLIT` share (75%; see §7) of Trove interest as JPYdf yield through ActivePool and distributes it to depositors. One SP is deployed per branch.

Accounting uses an O(1) Product-Sum method: instead of rewriting every depositor's balance on each liquidation, it updates only the running product `P` (deposit depletion ratio), the P-weighted running sum `S` (collateral gains), and `B` (yield gains). From the snapshot at deposit time (`P_t`, `S_t`, `B_t`, `scale_t`) and current values, each depositor derives their compounded deposit and cumulative gains in O(1) (the derivation is based on the upstream paper *Scalable Reward Distribution with Compounding Stakes*). To prevent `P` from reaching 0 due to floor division, a scale mechanism multiplies by `SCALE_FACTOR` and increments `currentScale` before `P` falls below `P_PRECISION / SCALE_FACTOR`.

**Dual structure (critical)**: `StabilityPool.sol` is retained as the behavior-parity norm after the JPYdf canonical-surface rename. However, **the deployed SP is `DFStabilityPool.sol`** (🟡 CORE-MOD-004 (§2 DF delta ledger)). DFStabilityPool is a full copy of StabilityPool with only four additions: (1) state variable `lastDepositBlock`, (2) a same-block collateral-gain claim guard in `provideToSP`, (3) recording in `provideToSP`, and (4) a same-block withdrawal guard at the beginning of `withdrawFromSP` (apart from the contract name, these are the only functional deltas). The normative body of this section (🔵) describes StabilityPool behavior, while DF deltas are isolated in CORE-SP-FR-004 and "Delta from base" notes under each FR. Both implementations also reject `provideToSP` on an unfinalized branch under CORE-MOD-013; that shared guard is not one of the four relative DFStabilityPool deltas. The ABI is identical except for the added `lastDepositBlock(address)`.

Main interactions: TroveManager (sole caller of `offset`) / ActivePool (SP calls `mintAggInterest` during depositor operations; receives `triggerJpydfRewards`; receives liquidation collateral via `sendColl`) / JpydfToken (`sendToPool` / `returnFromPool` / `burn`) / collToken=dToken (`safeTransfer` for paying gains). SP itself does not call PriceFeed (it holds `priceFeed` from LiquityBase but does not use it).

**Interface List (Non-Normative; Behavioral Norms Are in §6)**

| Function | Visibility / Permission | Summary | Spec ID |
| --- | --- | --- | --- |
| `provideToSP(uint256 _topUp, bool _doClaim)` | external (permissionless on finalized branches) | Deposit or top up JPYdf. Simultaneously settle gains by claiming or stashing. | CORE-SP-FR-002 |
| `withdrawFromSP(uint256 _amount, bool _doClaim)` | external (requires existing deposit) | Withdraw JPYdf (`_amount=0` may be used only to settle gains). Checks `MIN_JPYDF_IN_SP` afterward. | CORE-SP-FR-003 |
| `claimAllCollGains()` | external (requires zero deposit) | User with zero deposit claims stashed collateral gains | CORE-SP-FR-005 |
| `triggerJpydfRewards(uint256 _jpydfYield)` | external (onlyActivePool) | Account JPYdf yield from interest (`B` update / pending accumulation) | CORE-SP-FR-006 |
| `offset(uint256 _debtToOffset, uint256 _collToAdd)` | external (onlyTroveManager) | Liquidation offset: update `S`/`P`, process scale, burn JPYdf, and receive collateral | CORE-SP-FR-007 |
| `getDepositorCollGain(address)` | public view | Calculate unsettled collateral gain (supports scale crossing) | CORE-SP-FR-008 |
| `getDepositorYieldGain(address)` | public view | Calculate unsettled JPYdf yield gain (supports scale crossing) | CORE-SP-FR-009 |
| `getDepositorYieldGainWithPending(address)` | external view | Estimate yield including unminted interest (pending SP yield) | CORE-SP-FR-010 |
| `getCompoundedJpydfDeposit(address)` | public view | Calculate compounded (post-liquidation-depletion) deposit amount | CORE-SP-FR-011 |
| `getCollBalance()` | external view | Internal collateral tracker `collBalance` | CORE-SP-FR-012 |
| `getTotalJpydfDeposits()` | external view | Total deposit tracker `totalJpydfDeposits` | CORE-SP-FR-012 |
| `getYieldGainsOwed()` | external view | Yield amount already allocated but unpaid | CORE-SP-FR-012 |
| `getYieldGainsPending()` | external view | Unallocated (pending) yield amount | CORE-SP-FR-012 |
| `deposits(address) → uint256` | public view (automatic getter) | Depositor `initialValue` (deposit amount at last operation) | CORE-SP-FR-012 |
| `depositSnapshots(address) → (uint256 S, uint256 P, uint256 B, uint256 scale)` | public view (automatic getter) | Depositor snapshot | CORE-SP-FR-012 |
| `stashedColl(address) → uint256` | public view (automatic getter) | Collateral gains stashed (retained without transfer) | CORE-SP-FR-012 |
| `P()` | public view (automatic getter) | Current running product | CORE-SP-FR-012 |
| `currentScale()` | public view (automatic getter) | Current scale | CORE-SP-FR-012 |
| `scaleToS(uint256)` / `scaleToB(uint256)` | public view (automatic getter) | Per-scale cumulative sums S / B | CORE-SP-FR-012 |
| `NAME()` / `P_PRECISION()` / `SCALE_FACTOR()` / `MAX_SCALE_FACTOR_EXPONENT()` / `SCALE_SPAN()` | public view (constant getters) | Contract constants | CORE-SP-FR-012 |
| `collToken()` / `troveManager()` / `jpydfToken()` | public view (immutable getters) | Wiring addresses | CORE-SP-FR-012 |
| `activePool()` | public view (LiquityBase inheritance) | ActivePool address | CORE-SP-FR-012 |
| `getEntireBranchColl()` / `getEntireBranchDebt()` | public view (LiquityBase inheritance) | Total branch collateral and debt | CORE-SP-FR-013 |
| `lastDepositBlock(address) → uint256` 🟡 | public view (automatic getter; **DFStabilityPool only**) | Last deposit block number for depositor | CORE-SP-FR-004 |


### ActivePool (Central Accounting for Active Trove Collateral and Aggregate Liabilities) 🔵

ActivePool is deployed per branch and is the accounting contract that holds collateral for all active Troves (collToken = dToken, [dToken.md](dToken.md)) and aggregate branch debt denominated in JPYdf. It is the core of Liquity v2's interest model: instead of minting interest per Trove each time, it implements **aggregate interest accounting**, which linearly calculates aggregate pending interest from the **interest-rate-weighted debt sum (aggWeightedDebtSum, "S")** and mints JPYdf in bulk during arbitrary state-changing operations. Minted interest (plus upfront fees) is distributed with `SP_YIELD_SPLIT` (75%) to StabilityPool (notified through `triggerJpydfRewards`) and the remaining 25% to `interestRouter`. Batch management fees are handled by analogous aggregate accounting (aggBatchManagementFees / aggWeightedBatchManagementFeeSum).

During liquidation, collateral and liabilities move to StabilityPool (offset portion) and DefaultPool (redistribution portion); during redemption and collateral withdrawal, collateral is sent directly to the recipient. At branch shutdown, `shutdownTime` is recorded through TroveManager, and aggregate interest accumulation stops permanently thereafter.

All state-changing functions restrict callers to BorrowerOperations / TroveManager / StabilityPool / DefaultPool, and there is no permissionless state-changing surface. Address wiring is obtained from AddressesRegistry in the constructor, and all addresses are immutable.

**Interface List (Non-Normative; Behavioral Norms Are in §6)**

| Function | Visibility / Permission | Summary | Spec ID |
| --- | --- | --- | --- |
| `NAME() → string` | external view (public constant) | Contract name `"ActivePool"` | CORE-AP-FR-015 |
| `collToken() → address` | external view (public immutable) | Branch collateral token (dToken) | CORE-AP-FR-015 |
| `borrowerOperationsAddress() → address` | external view (public immutable) | BorrowerOperations address | CORE-AP-FR-015 |
| `troveManagerAddress() → address` | external view (public immutable) | TroveManager address | CORE-AP-FR-015 |
| `defaultPoolAddress() → address` | external view (public immutable) | DefaultPool address | CORE-AP-FR-015 |
| `jpydfToken() → address` | external view (public immutable) | JpydfToken (JPYdf) address | CORE-AP-FR-015 |
| `interestRouter() → address` | external view (public immutable) | Destination for the remaining 25% of interest (in DF dToken wiring, `InterestRouterForwarder`) | CORE-AP-FR-015 / CORE-AP-TBD-001 |
| `stabilityPool() → address` | external view (public immutable) | SP (referenced as `IJpydfRewardsReceiver`) | CORE-AP-FR-015 |
| `getCollBalance() → uint256` | external view | Accounting collateral balance `collBalance` | CORE-AP-FR-015 |
| `aggRecordedDebt() → uint256` | external view (public variable) | Aggregate recorded debt "D" | CORE-AP-FR-015 |
| `aggWeightedDebtSum() → uint256` | external view (public variable) | Interest-rate-weighted debt sum "S" | CORE-AP-FR-015 |
| `lastAggUpdateTime() → uint256` | external view (public variable) | Last finalization timestamp for aggregate interest | CORE-AP-FR-015 |
| `shutdownTime() → uint256` | external view (public variable) | Shutdown timestamp (0 = not shut down) | CORE-AP-FR-015 |
| `aggBatchManagementFees() → uint256` | external view (public variable) | Finalized but unapplied aggregate batch management fees | CORE-AP-FR-015 |
| `aggWeightedBatchManagementFeeSum() → uint256` | external view (public variable) | Debt sum weighted by batch management fee rates | CORE-AP-FR-015 |
| `lastAggBatchManagementFeesUpdateTime() → uint256` | external view (public variable) | Last finalization timestamp for batch-fee aggregation | CORE-AP-FR-015 |
| `calcPendingAggInterest() → uint256` | public view | Calculate aggregate pending interest | CORE-AP-FR-002 |
| `calcPendingSPYield() → uint256` | external view | SP share of pending interest | CORE-AP-FR-003 |
| `calcPendingAggBatchManagementFee() → uint256` | public view | Calculate aggregate pending batch management fee | CORE-AP-FR-004 |
| `getNewApproxAvgInterestRateFromTroveChange(TroveChange) → uint256` | external view | Approximate average interest rate after hypothetically applying a Trove change | CORE-AP-FR-005 |
| `getJpydfDebt() → uint256` | external view | Total active debt (including pending interest and fees) | CORE-AP-FR-006 |
| `mintAggInterest()` | external / BO or SP | Finalize/mint aggregate interest and distribute 75/25 | CORE-AP-FR-007 |
| `mintAggInterestAndAccountForTroveChange(TroveChange, address)` | external / BO or TM | Mint interest + reflect Trove change in aggregation | CORE-AP-FR-008 |
| `mintBatchManagementFeeAndAccountForChange(TroveChange, address)` | external / TM only | Finalize/mint batch management fee and reflect aggregation change | CORE-AP-FR-009 |
| `sendColl(address, uint256)` | external / BO, TM, or SP | Send collateral externally (accounting decrement + transfer) | CORE-AP-FR-010 |
| `sendCollToDefaultPool(uint256)` | external / TM only | Move redistributed collateral to DefaultPool | CORE-AP-FR-011 |
| `receiveColl(uint256)` | external / BO or DP | Receive collateral (accounting increment + pull from caller) | CORE-AP-FR-012 |
| `accountForReceivedColl(uint256)` | public / BO or DP | Accounting reflection only for collateral already sent directly | CORE-AP-FR-013 |
| `setShutdownFlag()` | external / TM only | Record shutdown timestamp (stop interest accumulation) | CORE-AP-FR-014 |
| `hasBeenShutDown() → bool` | external view | Whether shutdown has occurred (`shutdownTime != 0`) | CORE-AP-FR-015 |


### DefaultPool (Custody of Collateral and Liabilities Pending Redistribution) 🔵

DefaultPool is deployed per branch and is the accounting contract that holds pending collateral and JPYdf debt that have been redistributed to active Troves through liquidation redistribution but **have not yet been "applied" to each Trove's struct**. When a Trove performs an operation that applies pending amounts (liquidation, redemption, each BO-mediated Trove operation, or applyPendingDebt), that Trove's share is returned from DefaultPool to ActivePool.

Writes are limited to TroveManager (debt increase/decrease and collateral return) and ActivePool (collateral receipt). Actual collateral tokens (collToken = dToken) move only between DefaultPool and ActivePool; there is no path for direct transfer to external addresses. Wiring is obtained from AddressesRegistry in the constructor, and all references are immutable.

**Interface List (Non-Normative; Behavioral Norms Are in §6)**

| Function | Visibility / Permission | Summary | Spec ID |
| --- | --- | --- | --- |
| `NAME() → string` | external view (public constant) | Contract name `"DefaultPool"` | CORE-DP-FR-006 |
| `collToken() → address` | external view (public immutable) | Branch collateral token (dToken) | CORE-DP-FR-006 |
| `troveManagerAddress() → address` | external view (public immutable) | TroveManager address | CORE-DP-FR-006 |
| `activePoolAddress() → address` | external view (public immutable) | ActivePool address | CORE-DP-FR-006 |
| `getCollBalance() → uint256` | external view | Accounting balance of pending collateral | CORE-DP-FR-006 |
| `getJpydfDebt() → uint256` | external view | JPYdf debt balance pending redistribution | CORE-DP-FR-006 |
| `sendCollToActivePool(uint256)` | external / TM only | Return pending collateral to ActivePool | CORE-DP-FR-002 |
| `receiveColl(uint256)` | external / AP only | Receive redistributed collateral (pull from AP) | CORE-DP-FR-003 |
| `increaseJpydfDebt(uint256)` | external / TM only | Account redistributed debt | CORE-DP-FR-004 |
| `decreaseJpydfDebt(uint256)` | external / TM only | Draw down applied debt | CORE-DP-FR-005 |


### CollSurplusPool (Custody of Claims to Surplus Collateral from Liquidations) 🔵

CollSurplusPool is deployed per branch and holds **collateral surplus** that remains after penalties and other deductions during liquidation, in a form that allows the former Trove owner to claim it later. The creation and amount determination of surplus are handled by TroveManager liquidation logic (TM scope). This contract is responsible only for "recording balances by owner" and "paying out on claim."

Recording (`accountSurplus`) is limited to TroveManager, and payout (`claimColl`) is limited to BorrowerOperations. Actual tokens are brought in through a separate path from the accounting entry (TM sends them to this contract through `ActivePool.sendColl`), and payout transfers directly from this contract to the claimant.

**Interface List (Non-Normative; Behavioral Norms Are in §6)**

| Function | Visibility / Permission | Summary | Spec ID |
| --- | --- | --- | --- |
| `NAME() → string` | external view (public constant) | Contract name `"CollSurplusPool"` | CORE-CSP-FR-004 |
| `collToken() → address` | external view (public immutable) | Branch collateral token (dToken) | CORE-CSP-FR-004 |
| `borrowerOperationsAddress() → address` | external view (public immutable) | BorrowerOperations address | CORE-CSP-FR-004 |
| `troveManagerAddress() → address` | external view (public immutable) | TroveManager address | CORE-CSP-FR-004 |
| `getCollBalance() → uint256` | external view | Total surplus collateral in accounting | CORE-CSP-FR-004 |
| `getCollateral(address) → uint256` | external view | Claimable balance for the specified account | CORE-CSP-FR-004 |
| `accountSurplus(address, uint256)` | external / TM only | Record liquidation surplus | CORE-CSP-FR-002 |
| `claimColl(address)` | external / BO only | Claim and pay out surplus collateral | CORE-CSP-FR-003 |


### GasPool (Custody of WETH for Liquidation Gas Compensation) 🔵

GasPool is a minimal contract deployed per branch with **constructor only, zero functions, and zero state variables**. It holds the fixed amount of gas-compensation WETH collected from borrowers when Troves are opened (`ETH_GAS_COMPENSATION`; value in §7), and enables refunds to borrowers on Trove close (through BorrowerOperations) and payments to liquidators during liquidation (through TroveManager) via infinite approvals set in the constructor. Regardless of which dToken branch the collateral token belongs to, gas compensation is always denominated in WETH.

Both WETH deposits (`WETH.transferFrom(borrower, gasPool, ...)` on open) and withdrawals (`WETH.transferFrom(gasPool, ...)` on close/liquidation) are executed by BO / TM logic. GasPool itself contains no logic.

**Interface List (Non-Normative; Behavioral Norms Are in §6)**

| Function | Visibility / Permission | Summary | Spec ID |
| --- | --- | --- | --- |
| (no external / public functions; ABI is empty) | - | - | CORE-GP-FR-001 |


### SortedTroves (Doubly Linked List Descending by `annualInterestRate`) 🔵

SortedTroves is a doubly linked list that stores active Troves in a branch (excluding zombies) in **descending order of annual interest rate `annualInterestRate`**. **head = highest interest rate, tail = lowest interest rate**; the `nextId` direction points toward lower rates, and the `prevId` direction points toward higher rates (`getFirst()` returns the highest-rate node and `getLast()` returns the lowest-rate node). During Redemption, TroveManager starts from `getLast()` and processes tail-side Troves (lowest rates) sequentially via `getPrev()`, so this list order directly specifies redemption order. One instance is deployed per branch.

- Node ID is `troveId` (uint256; same as the TroveNFT tokenId). The interest-rate value itself is not stored in the node; each ordering check references `troveManager.getTroveAnnualInterestRate(id)`. Reinsertion is required only when the interest rate changes; other system operations preserve ordering.
- **Batch support**: Nodes belonging to the same batch (bulk interest-rate management; the batch manager address is the `BatchId`) form a **contiguous slice** in the list (`batches[id].head` through `batches[id].tail`). Moving and skipping at slice granularity enables O(1) scanning across batches regardless of batch size.
- Optional insertion-position hints (`_prevId`/`_nextId`) are accepted. Even if a hint is invalid, the function does not revert; it always re-searches from the hint to find the correct position (CORE-ST-FR-009).
- The implementation is a modified version of Livepeer's audited SortedDoublyLinkedList (key removed from the node, ordering check changed to reference TroveManager, and major functions internalized with external wrappers).
- Note: The source-header comment saying "the ID property is the address of a Trove owner" is a v1 remnant; the actual ID is troveId (not owner address).
- `BatchId` is a user-defined value type over `address` (`Types/BatchId.sol`). `==`/`!=`/`isZero`/`isNotZero` are attached through global using. `BATCH_ID_ZERO = address(0)`.

**Interface List (Non-Normative; Behavioral Norms Are in §6)**

| Function | Visibility / Permission | Summary | Spec ID |
| --- | --- | --- | --- |
| `insert(uint256 _id, uint256 _annualInterestRate, uint256 _prevId, uint256 _nextId)` | external (BO only) | Insert a non-batch node | CORE-ST-FR-002 |
| `remove(uint256 _id)` | external (BO / TM) | Remove a non-batch node | CORE-ST-FR-003 |
| `reInsert(uint256 _id, uint256 _newAnnualInterestRate, uint256 _prevId, uint256 _nextId)` | external (BO only) | Reinsert a non-batch node after interest-rate change | CORE-ST-FR-004 |
| `insertIntoBatch(uint256 _troveId, BatchId _batchId, uint256 _annualInterestRate, uint256 _prevId, uint256 _nextId)` | external (BO only) | Add a node to a batch (link to batch tail) | CORE-ST-FR-005 |
| `removeFromBatch(uint256 _id)` | external (BO / TM) | Remove a batch node | CORE-ST-FR-006 |
| `reInsertBatch(BatchId _id, uint256 _newAnnualInterestRate, uint256 _prevId, uint256 _nextId)` | external (BO only) | Reinsert an entire batch slice | CORE-ST-FR-007 |
| `validInsertPosition(uint256 _annualInterestRate, uint256 _prevId, uint256 _nextId) → bool` | external view | Validate hint position | CORE-ST-FR-008 |
| `findInsertPosition(uint256 _annualInterestRate, uint256 _prevId, uint256 _nextId) → (uint256, uint256)` | external view | Find insertion position starting from hints | CORE-ST-FR-009 |
| `contains(uint256 _id) → bool` | public view | Whether a node exists | CORE-ST-FR-010 |
| `isBatchedNode(uint256 _id) → bool` | public view | Whether a node belongs to a batch | CORE-ST-FR-010 |
| `isEmptyBatch(BatchId _id) → bool` | external view | Whether a batch is empty | CORE-ST-FR-010 |
| `isEmpty() → bool` | external view | Whether the list is empty | CORE-ST-FR-010 |
| `getSize() → uint256` | external view | Number of nodes (same as `size`) | CORE-ST-FR-010 |
| `getFirst() → uint256` | external view | Head (highest-rate) node ID | CORE-ST-FR-010 |
| `getLast() → uint256` | external view | Tail (lowest-rate) node ID | CORE-ST-FR-010 |
| `getNext(uint256 _id) → uint256` | external view | Next node ID (toward lower rates) | CORE-ST-FR-010 |
| `getPrev(uint256 _id) → uint256` | external view | Previous node ID (toward higher rates) | CORE-ST-FR-010 |
| `NAME() → string` | public (constant getter) | `"SortedTroves"` | CORE-ST-FR-010 |
| `size() → uint256` | public (automatic getter) | Current list size | CORE-ST-FR-010 |
| `nodes(uint256) → (uint256 nextId, uint256 prevId, BatchId batchId, bool exists)` | public (automatic getter) | Node struct reference | CORE-ST-FR-010 |
| `batches(BatchId) → (uint256 head, uint256 tail)` | public (automatic getter) | References to both ends of a batch slice | CORE-ST-FR-010 |
| `borrowerOperationsAddress() → address` | public (immutable getter) | Write-authorized party (BO) | CORE-ST-FR-001 |
| `troveManager() → address` | public (immutable getter) | Write-authorized party and interest-rate reference (TM) | CORE-ST-FR-001 |


### TroveNFT / JPYdfTroveNFT (ERC-721 Representing Trove Ownership, Including MetadataNFT) 🔵/🟡

TroveNFT is the ERC-721 token representing Trove ownership. **tokenId = troveId** (1 Trove : 1 NFT), and the NFT holder is the canonical source for the Trove owner (BO/TM ownership checks reference `ownerOf`; the verification rules themselves are in the BO/TM sections). Only TroveManager may mint/burn, synchronized with the Trove lifecycle (mint on opening; burn on close or liquidation). `tokenURI` delegates to MetadataNFT and returns **fully on-chain** JSON metadata + SVG image as a base64 data URI. One instance is deployed per branch, and name/symbol are derived at deployment from the name/symbol of the collateral token (dToken in jpydf; [dToken.md](dToken.md)). The implementation inherits `ERC721` from OpenZeppelin Contracts **v4.9**.

DF deployment wires `JPYdfTroveNFT` and `JPYdfMetadataNFT` through `AddressesRegistry` (🟡 CORE-MOD-007). Undeployed upstream `TroveNFT` / `MetadataNFT` / `baseSVG` surfaces have been removed from production `src` under the fresh-deploy policy; active branch deployment uses only the JPYdf surface. ERC-721 ownership behavior and Trove coupling remain base-shaped; the DF delta is product-facing collection naming, tokenURI JSON/SVG wording, and the non-TM custom error style.

**Interface List (Non-Normative; Behavioral Norms Are in §6)**

| Function | Visibility / Permission | Summary | Spec ID |
| --- | --- | --- | --- |
| `mint(address _owner, uint256 _troveId)` | external (TM only) | Issue NFT when Trove is opened | CORE-TN-FR-002 |
| `burn(uint256 _troveId)` | external (TM only) | Burn NFT when Trove is closed or liquidated | CORE-TN-FR-003 |
| `tokenURI(uint256 _tokenId) → string` | public view | On-chain metadata (delegates to MetadataNFT) | CORE-TN-FR-004 |
| `transferFrom(address,address,uint256)` | public (ERC-721) | NFT transfer = Trove ownership transfer | CORE-TN-FR-005 |
| `safeTransferFrom(address,address,uint256)` | public (ERC-721) | Transfer with receipt check | CORE-TN-FR-005 |
| `safeTransferFrom(address,address,uint256,bytes)` | public (ERC-721) | Same as above (with data) | CORE-TN-FR-005 |
| `approve(address,uint256)` | public (ERC-721) | Per-token approval | CORE-TN-FR-005 |
| `setApprovalForAll(address,bool)` | public (ERC-721) | Operator approval | CORE-TN-FR-005 |
| `getApproved(uint256) → address` | public view | Query per-token approval | CORE-TN-FR-005 |
| `isApprovedForAll(address,address) → bool` | public view | Query operator approval | CORE-TN-FR-005 |
| `balanceOf(address) → uint256` | public view | Number of NFTs held (= number of Troves held) | CORE-TN-FR-005 |
| `ownerOf(uint256) → address` | public view | Canonical source for Trove owner | CORE-TN-FR-005 |
| `name() → string` | public view | `"JPYdf - " + collToken.name()` in the deployed variant (fixed at deployment) | CORE-TN-FR-001 |
| `symbol() → string` | public view | `"JPYdf_" + collToken.symbol()` in the deployed variant (fixed at deployment) | CORE-TN-FR-001 |
| `supportsInterface(bytes4) → bool` | public view | ERC-165 (IERC721 / IERC721Metadata / IERC165) | CORE-TN-FR-005 |
| `troveManager() → address` | public (immutable getter) | Authority for mint/burn | CORE-TN-FR-001 |
| `metadataNFT() → address` | public (immutable getter) | Metadata rendering delegate | CORE-TN-FR-001 |

(MetadataNFT external surface — `uri(TroveData)` / `attributes(TroveData)` / `dynamicTextComponents(TroveData)` / `assetReader()` — is specified collectively in CORE-TN-FR-006.)


### JpydfToken (System-Wide Stablecoin JPYdf: Non-Upgradeable ERC-20 + EIP-2612 Singleton with Core mint/burn and Dormant Bridge Readiness) 🔵/🟡

The stablecoin contract deployed once for the entire system (shared by all branches). It inherits OZ v4.9.5 `ERC20` / `ERC20Permit` (EIP-2612 / ERC-5267) and the Liquity version of `Ownable`. Core issuance (`mint`) is limited to registered BorrowerOperations / ActivePool, and Core burning (`burn`) is limited to CollateralRegistry and registered BorrowerOperations / TroveManager / StabilityPool. This keeps Core supply changes tied to protocol debt accounting (borrowing, interest issuance, repayment, redemption, and liquidation offset). The Owner registers nonzero contract branch addresses through `setBranchAddresses`, and when `setCollateralRegistry` is finally called with a nonzero contract address, ownership is renounced and the Core permission structure is permanently fixed (additional branches cannot be registered afterward). The token is non-upgradeable. DF deltas are the JPYdf name/symbol constants (CORE-MOD-001), the dormant bridge-ready surface (CORE-MOD-008), and Core address registration hardening (CORE-MOD-009).

**Interface List (Non-Normative; Behavioral Norms Are in §6)**

| Function | Visibility / Permission | Summary | Spec ID |
| --- | --- | --- | --- |
| `setBranchAddresses(address,address,address,address)` | external (onlyOwner) | Register a branch's TM/SP/BO/AP in the mint/burn permission sets | CORE-BT-FR-002 |
| `setCollateralRegistry(address)` | external (onlyOwner) | Set CR address and renounce ownership (fix permissions) | CORE-BT-FR-003 |
| `mint(address,uint256)` | external (registered BO / AP only) | Issue JPYdf | CORE-BT-FR-004 |
| `burn(address,uint256)` | external (CR or registered BO / TM / SP only) | Burn JPYdf (independent of allowance) | CORE-BT-FR-005 |
| `sendToPool(address,address,uint256)` | external (registered SP only) | Internal transfer from depositor to SP | CORE-BT-FR-006 |
| `returnFromPool(address,address,uint256)` | external (registered SP only) | Internal transfer from SP to depositor | CORE-BT-FR-007 |
| `transfer(address,uint256) → bool` | public | ERC-20 transfer (with recipient restrictions) | CORE-BT-FR-008 |
| `transferFrom(address,address,uint256) → bool` | public | ERC-20 transfer (with recipient restrictions) | CORE-BT-FR-008 |
| `approve(address,uint256) → bool` | public | ERC-20 standard | CORE-BT-FR-009 |
| `increaseAllowance(address,uint256) → bool` | public | ERC-20 standard (OZ extension) | CORE-BT-FR-009 |
| `decreaseAllowance(address,uint256) → bool` | public | ERC-20 standard (OZ extension) | CORE-BT-FR-009 |
| `allowance(address,address) → uint256` | public view | ERC-20 standard | CORE-BT-FR-009 |
| `balanceOf(address) → uint256` | public view | ERC-20 standard | CORE-BT-FR-009 |
| `totalSupply() → uint256` | public view | ERC-20 standard | CORE-BT-FR-009 |
| `decimals() → uint8` | public view | Always 18 | CORE-BT-FR-009 |
| `name() → string` | public view | `"JPYdf Stablecoin"` 🟡 | CORE-BT-FR-010 |
| `symbol() → string` | public view | `"JPYdf"` 🟡 | CORE-BT-FR-010 |
| `permit(address,address,uint256,uint256,uint8,bytes32,bytes32)` | public | EIP-2612 signed approve | CORE-BT-FR-011 |
| `nonces(address) → uint256` | public view | EIP-2612 nonce | CORE-BT-FR-011 |
| `DOMAIN_SEPARATOR() → bytes32` | external view | EIP-712 domain | CORE-BT-FR-011 |
| `eip712Domain() → (bytes1,string,string,uint256,address,bytes32,uint256[])` | public view | ERC-5267 domain reporting | CORE-BT-FR-011 |
| `owner() → address` | public view | Current Owner (`address(0)` after renounce) | CORE-BT-FR-012 |
| `isOwner() → bool` | public view | `msg.sender == owner` check | CORE-BT-FR-012 |
| `collateralRegistryAddress() → address` | public view (automatic getter) | Configured CR address | CORE-BT-FR-012 |
| `bridgeAdmin() → address` | public view | Current bridge-readiness admin | CORE-BT-FR-013 |
| `pendingBridgeAdmin() → address` | public view | Pending bridge admin in two-step transfer | CORE-BT-FR-013 / 016 |
| `proposedBridgeMinter() → address` | public view | Proposed bridge minter awaiting timelock | CORE-BT-FR-013 / 014 |
| `bridgeMinterProposedAt() → uint256` | public view | Proposal timestamp | CORE-BT-FR-013 / 014 |
| `bridgeMinterCount() → uint256` | public view | Number of registered bridge minters | CORE-BT-FR-013 / 014 |
| `isBridgeMinter(address) → bool` | external view | Bridge minter registry lookup | CORE-BT-FR-013 / 014 |
| `proposeBridgeMinter(address)` | external (`bridgeAdmin`) | Propose a contract bridge minter | CORE-BT-FR-014 |
| `confirmBridgeMinter()` | external (`bridgeAdmin`) | Confirm proposal after 48h timelock | CORE-BT-FR-014 |
| `cancelBridgeMinterProposal()` | external (`bridgeAdmin`) | Cancel pending minter proposal | CORE-BT-FR-014 |
| `removeBridgeMinter(address)` | external (`bridgeAdmin`) | Remove live minter immediately | CORE-BT-FR-014 |
| `transferBridgeAdmin(address)` | external (`bridgeAdmin`) | Start two-step bridge admin transfer | CORE-BT-FR-016 |
| `acceptBridgeAdmin()` | external (`pendingBridgeAdmin`) | Accept bridge admin transfer | CORE-BT-FR-016 |
| `renounceBridgeAdmin()` | external (`bridgeAdmin`) | Abandon bridge readiness when no minters/proposals exist | CORE-BT-FR-016 |
| `bridgeMint(address,uint256)` | external (bridge minter) | Bridge supply mint to non-protocol recipient | CORE-BT-FR-015 |
| `bridgeBurn(uint256)` | external (bridge minter) | Self-burn bridge minter balance | CORE-BT-FR-015 |


### CollateralRegistry (Single Cross-Branch Redemption Entry Point: Non-Upgradeable Singleton Managing Unbacked-Proportional Routing and System-Wide `baseRate`) 🔵

The redemption router deployed once for the whole system. JPYdf holders call `redeemCollateral` here. The requested amount is allocated to all redeemable branches in proportion to each branch's "unbacked portion" (branch debt minus SP deposits), and each TroveManager performs the actual Trove redemption. `baseRate`, the basis for the redemption fee, is managed here as a single branch-common state value; it is updated by exponential decay over time (6h half-life) and by increases according to redemption size. Initializing with `INITIAL_BASE_RATE` (100%) at deployment creates a bootstrap period in which redemption is economically unattractive immediately after launch. The branch composition (pairs of collateral token and TroveManager, max 10) is fully immutable; branches cannot be added, removed, or replaced after deployment. It has no Owner (does not inherit Ownable) and no administrative functions. In the DF configuration, collateral tokens are dTokens ([dToken.md](dToken.md)).

**Interface List (Non-Normative; Behavioral Norms Are in §6)**

| Function | Visibility / Permission | Summary | Spec ID |
| --- | --- | --- | --- |
| `redeemCollateral(uint256,uint256,uint256)` | external (permissionless) | Execute cross-branch redemption | CORE-CR-FR-002 |
| `getRedemptionRate() → uint256` | external view | Effective rate at current `baseRate` (decay not applied) | CORE-CR-FR-003 |
| `getRedemptionRateWithDecay() → uint256` | public view | Effective rate after applying decay | CORE-CR-FR-004 |
| `getRedemptionRateForRedeemedAmount(uint256) → uint256` | external view | Estimate effective rate for redeeming the specified amount | CORE-CR-FR-005 |
| `getRedemptionFeeWithDecay(uint256) → uint256` | external view | Fee = decay-applied rate × specified quantity | CORE-CR-FR-006 |
| `getEffectiveRedemptionFeeInJpydf(uint256) → uint256` | external view | Effective fee in JPYdf for redeeming the specified amount | CORE-CR-FR-007 |
| `getToken(uint256) → IERC20Metadata` | external view | index → collateral token | CORE-CR-FR-008 |
| `getTroveManager(uint256) → ITroveManager` | public view | index → TroveManager | CORE-CR-FR-008 |
| `totalCollaterals() → uint256` | public view (immutable getter) | Number of branches | CORE-CR-FR-009 |
| `jpydfToken() → IJpydfToken` | public view (immutable getter) | JPYdf token | CORE-CR-FR-009 |
| `baseRate() → uint256` | public view (automatic getter) | Current baseRate (value at last update) | CORE-CR-FR-009 |
| `lastFeeOperationTime() → uint256` | public view (automatic getter) | Last fee operation time (advances at minute granularity) | CORE-CR-FR-009 |


### AddressesRegistry (Registry Holding One Branch's Address Wiring and Risk Parameters Finalized Once) 🔵/🟡

One configuration contract is deployed per branch. `setAddresses` configures all contracts that make up the branch plus shared contracts (JpydfToken / CollateralRegistry / WETH, etc.) exactly once and then renounces ownership. An active branch immediately finalizes the six constructor risk values. For a reserved branch, the finalizer fixed immutably in the constructor finalizes the six risk values and compensation cap exactly once after the exact Underlying is bound and before economic activity. The same transaction synchronizes BO/TM storage copies, after which no value can change. In the DF configuration, the collateral token (`collToken`) is dToken ([dToken.md](dToken.md)) and `priceFeed` is PriceFeedProxy ([Oracle.md](Oracle.md)).

**Interface List (Non-Normative; Behavioral Norms Are in §6)**

| Function | Visibility / Permission | Summary | Spec ID |
| --- | --- | --- | --- |
| `setAddresses(AddressVars)` | external (onlyOwner) | Set all 18 addresses exactly once and renounce ownership | CORE-AR-FR-002 |
| `finalizeRiskParams(address,RiskParams)` | external (immutable finalizer only; one-shot) | Finalize the exact Underlying, six risk values and compensation cap for a reserved branch and synchronize BO/TM | CORE-AR-FR-005 |
| `CCR() → uint256` | public view | Branch Critical CR | CORE-AR-FR-003 |
| `SCR() → uint256` | public view | Branch Shutdown CR | CORE-AR-FR-003 |
| `MCR() → uint256` | public view | Minimum CR for individual Troves | CORE-AR-FR-003 |
| `BCR() → uint256` | public view | Additional buffer CR for joining a batch and adjusting within a batch | CORE-AR-FR-003 |
| `LIQUIDATION_PENALTY_SP() → uint256` | public view | SP offset liquidation penalty | CORE-AR-FR-003 |
| `LIQUIDATION_PENALTY_REDISTRIBUTION() → uint256` | public view | Redistribution liquidation penalty | CORE-AR-FR-003 |
| `riskParamsFinalizer() → address` | public view (immutable getter) | One-shot finalizer for a reserved branch; zero for active branches | CORE-AR-FR-005 |
| `riskParamsFinalized() → bool` | public view | Whether risk values and the compensation cap are finalized | CORE-AR-FR-005 |
| `collToken() → IERC20Metadata` | public view | Collateral token (dToken in DF) | CORE-AR-FR-004 |
| `borrowerOperations() → IBorrowerOperations` | public view | Branch BO | CORE-AR-FR-004 |
| `troveManager() → ITroveManager` | public view | Branch TM | CORE-AR-FR-004 |
| `troveNFT() → ITroveNFT` | public view | Branch TroveNFT | CORE-AR-FR-004 |
| `metadataNFT() → IMetadataNFT` | public view | Metadata generator for TroveNFT | CORE-AR-FR-004 |
| `stabilityPool() → IStabilityPool` | public view | Branch SP (DF deployment uses DFStabilityPool) | CORE-AR-FR-004 |
| `priceFeed() → IPriceFeed` | public view | Branch PriceFeed (PriceFeedProxy in DF) | CORE-AR-FR-004 |
| `activePool() → IActivePool` | public view | Branch AP | CORE-AR-FR-004 |
| `defaultPool() → IDefaultPool` | public view | Branch DP | CORE-AR-FR-004 |
| `gasPoolAddress() → address` | public view | Branch GasPool | CORE-AR-FR-004 |
| `collSurplusPool() → ICollSurplusPool` | public view | Branch CollSurplusPool | CORE-AR-FR-004 |
| `sortedTroves() → ISortedTroves` | public view | Branch SortedTroves | CORE-AR-FR-004 |
| `interestRouter() → IInterestRouter` | public view | Destination for remaining interest | CORE-AR-FR-004 |
| `hintHelpers() → IHintHelpers` | public view | Shared HintHelpers | CORE-AR-FR-004 |
| `multiTroveGetter() → IMultiTroveGetter` | public view | Shared MultiTroveGetter | CORE-AR-FR-004 |
| `collateralRegistry() → ICollateralRegistry` | public view | Shared CollateralRegistry | CORE-AR-FR-004 |
| `jpydfToken() → IJpydfToken` | public view | Shared JpydfToken | CORE-AR-FR-004 |
| `WETH() → IWETH` | public view | WETH for gas compensation (`ETH_GAS_COMPENSATION`) | CORE-AR-FR-004 |
| `owner() → address` | public view | Current Owner (`address(0)` after `setAddresses`) | CORE-AR-FR-004 |
| `isOwner() → bool` | public view | `msg.sender == owner` check | CORE-AR-FR-004 |

### HintHelpers (SortedTroves Hint Search and Upfront Fee Estimation Helper) 🔵

A branch-common **singleton** read-only helper. Starting from `collateralRegistry`, it resolves the target branch (TroveManager / ActivePool / SortedTroves) by `_collIndex`. It has two responsibilities.

1. **Hint search**: `getApproxHint` returns an approximate "Trove closest to the target interest rate" by randomized sampling over the Trove ID array. Off-chain callers then pass this to `SortedTroves.findInsertPosition` (ST section) to obtain the exact insertion position `(prevId, nextId)`, and use those values as `_upperHint` / `_lowerHint` for `openTrove`, `adjustTroveInterestRate`, and similar calls. This is the first stage of that two-step process.
2. **Upfront fee estimation**: Eight view functions estimate upfront fees charged by BorrowerOperations operations (BO section) using the same logic before the operation is executed (`predict*` 7 variants + 1 `force` variant). These are the basis for frontend fee display and `_maxUpfrontFee` settings.

All functions are view, write no state, and hold no assets. No events. Registered in AddressesRegistry as `hintHelpers` (AR section). Byte-identical to base v1.11.0. Note that `IHintHelpers` declares only 7 functions; `predictOpenTroveAndJoinBatchUpfrontFee` / `predictRemoveFromBatchUpfrontFee` exist only on the contract (ABI).

**Interface List (Non-Normative; Behavioral Norms Are in §6)**

| Function | Visibility / Permission | Summary | Spec ID |
| --- | --- | --- | --- |
| `NAME() → string` | external view (constant) | Contract identifier `"HintHelpers"` | CORE-HH-FR-010 |
| `collateralRegistry() → ICollateralRegistry` | external view (immutable) | Referenced CollateralRegistry | CORE-HH-FR-010 |
| `getApproxHint(uint256 _collIndex, uint256 _interestRate, uint256 _numTrials, uint256 _inputRandomSeed) → (uint256 hintId, uint256 diff, uint256 latestRandomSeed)` | external view / permissionless | Approximate hint search by randomized sampling | CORE-HH-FR-001 |
| `predictOpenTroveUpfrontFee(uint256 _collIndex, uint256 _borrowedAmount, uint256 _interestRate) → uint256` | external view / permissionless | Estimate upfront fee for `openTrove` | CORE-HH-FR-002 |
| `predictAdjustInterestRateUpfrontFee(uint256 _collIndex, uint256 _troveId, uint256 _newInterestRate) → uint256` | external view / permissionless | Estimate fee for `adjustTroveInterestRate` (premature adjustment) | CORE-HH-FR-003 |
| `forcePredictAdjustInterestRateUpfrontFee(uint256 _collIndex, uint256 _troveId, uint256 _newInterestRate) → uint256` | external view / permissionless | Unconditional estimate for the same operation (no 0 short-circuit) | CORE-HH-FR-004 |
| `predictAdjustTroveUpfrontFee(uint256 _collIndex, uint256 _troveId, uint256 _debtIncrease) → uint256` | external view / permissionless | Estimate fee for debt-increasing adjustment (`adjustTrove` family) | CORE-HH-FR-005 |
| `predictAdjustBatchInterestRateUpfrontFee(uint256 _collIndex, address _batchAddress, uint256 _newInterestRate) → uint256` | external view / permissionless | Estimate fee for `setBatchManagerAnnualInterestRate` | CORE-HH-FR-006 |
| `predictOpenTroveAndJoinBatchUpfrontFee(uint256 _collIndex, uint256 _borrowedAmount, address _batchAddress) → uint256` | external view / permissionless (not declared in `IHintHelpers`) | Estimate fee for `openTroveAndJoinInterestBatchManager` | CORE-HH-FR-007 |
| `predictJoinBatchInterestRateUpfrontFee(uint256 _collIndex, uint256 _troveId, address _batchAddress) → uint256` | external view / permissionless | Estimate fee for `setInterestBatchManager` (join batch) | CORE-HH-FR-008 |
| `predictRemoveFromBatchUpfrontFee(uint256 _collIndex, uint256 _troveId, uint256 _newInterestRate) → uint256` | external view / permissionless (not declared in `IHintHelpers`) | Estimate fee for `removeFromBatch` (leave batch) | CORE-HH-FR-009 |


### MultiTroveGetter (Frontend Helper for Batch Trove Retrieval) 🔵

A branch-common **singleton** view helper. It is a frontend utility that retrieves multiple Trove states in one `eth_call` along the SortedTroves order (interest-rate order) (source-header comment: "Not part of the core Liquity system"). It resolves a branch by `_collIndex` from `collateralRegistry`. No state writes, no asset custody, and no events. Byte-identical to base v1.11.0. Registered in AddressesRegistry as `multiTroveGetter` (AR section). Loop bounds depend on arguments (unbounded), so on-chain use is not intended.

**Interface List (Non-Normative; Behavioral Norms Are in §6)**

| Function | Visibility / Permission | Summary | Spec ID |
| --- | --- | --- | --- |
| `collateralRegistry() → ICollateralRegistry` | external view (immutable) | Referenced CollateralRegistry | CORE-MTG-FR-003 |
| `getMultipleSortedTroves(uint256 _collIndex, int256 _startIdx, uint256 _count) → CombinedTroveData[]` | external view / permissionless | Batch retrieve Trove details in interest-rate order (positive: descending from head / negative: ascending from tail) | CORE-MTG-FR-001 |
| `getDebtPerInterestRateAscending(uint256 _collIndex, uint256 _startId, uint256 _maxIterations) → (DebtPerInterestRate[], uint256 currId)` | external view / permissionless | Enumerate (batch, rate, debt) in ascending interest-rate order (cursor-based paging) | CORE-MTG-FR-002 |


### DebtInFrontHelper (Precise Debt-in-Front Calculation Helper) 🔵

A branch-common **singleton** view helper (source-header comment: "helper for the frontend to precisely calculate debt-in-front. Not part of the core Liquity system"). Since redemption consumes debt starting from the lowest-rate side of SortedTroves, **the total debt redeemed before a given Trove (debt-in-front)** is the redemption-risk metric for that Trove. This contract provides two functions that accurately calculate debt totals for specified interest-rate bands by actually scanning the sorted list. It uses `hintHelpers` (CORE-HH-FR-001) to find the scan starting point. No state writes, no asset custody, and no events. Byte-identical to base v1.11.0.

**Interface List (Non-Normative; Behavioral Norms Are in §6)**

| Function | Visibility / Permission | Summary | Spec ID |
| --- | --- | --- | --- |
| `collateralRegistry() → ICollateralRegistry` | external view (immutable) | Referenced CollateralRegistry | CORE-DFH-FR-003 |
| `hintHelpers() → IHintHelpers` | external view (immutable) | HintHelpers delegate for hint search | CORE-DFH-FR-003 |
| `getDebtBetweenInterestRates(uint256 _collIndex, uint256 _interestRateLo, uint256 _interestRateHi, uint256 _excludedTroveId, uint256 _hintId, uint256 _numTrials) → (uint256 debt, uint256 blockTimestamp)` | external view / permissionless | Total debt in interest-rate band [lo, hi), excluding the specified Trove | CORE-DFH-FR-001 |
| `getDebtBetweenInterestRateAndTrove(uint256 _collIndex, uint256 _interestRateLo, uint256 _interestRateHi, uint256 _troveIdToStopAt, uint256 _hintId, uint256 _numTrials) → (uint256 debt, uint256 blockTimestamp)` | external view / permissionless | Total debt from rate lo to immediately before a specific Trove (including position among equal rates) | CORE-DFH-FR-002 |


### RedemptionHelper (Redemption Wrapper and Redemption Simulation) 🔵/🟡

A **singleton**. It provides three functions around CollateralRegistry redemption (CR section). (1) `redeemCollateral`: an **on-chain wrapper** around `CollateralRegistry.redeemCollateral` that adds slippage protection through per-branch minimum received collateral amounts and automatic return of unredeemed JPYdf. (2) `simulateRedemption` / (3) `truncateRedemption`: **off-chain-only simulations** that trace redemption branch allocation and Trove scanning. The latter two are **nonpayable rather than view** because internal price retrieval (`PriceFeed.fetchPrice` / `fetchRedemptionPrice`; [Oracle.md](Oracle.md) PriceFeedProxy) performs state writes (code comments: "Meant to be called off-chain / Not a view because price fetching has side-effects"), and are intended for `eth_call` use. Intended users are arbitrageurs / bots / frontends performing redemption. The contract does not hold assets across transactions. No events. It is based on base v1.11.0 behavior, with only the JPYdf rename / SafeERC20 hardening (CORE-MOD-001/010) and CORE-MOD-015, which reflects the normal-redemption price consumer's failure bool in simulation / truncate.

**Interface List (Non-Normative; Behavioral Norms Are in §6)**

| Function | Visibility / Permission | Summary | Spec ID |
| --- | --- | --- | --- |
| `numBranches() → uint256` | external view (immutable) | Number of branches (= `totalCollaterals`) | CORE-RH-FR-004 |
| `collateralRegistry() → ICollateralRegistry` | external view (immutable) | Referenced CollateralRegistry | CORE-RH-FR-004 |
| `jpydfToken() → IJpydfToken` | external view (immutable) | JPYdf token | CORE-RH-FR-004 |
| `addresses(uint256) → IAddressesRegistry` | external view (storage array) | AddressesRegistry for branch i | CORE-RH-FR-004 |
| `redeemCollateral(uint256 _jpydf, uint256 _maxIterationsPerCollateral, uint256 _maxFeePct, uint256[] _minCollRedeemed)` | external nonpayable / permissionless | Redemption wrapper with min-out protection | CORE-RH-FR-001 |
| `simulateRedemption(uint256 _jpydf, uint256 _maxIterationsPerCollateral) → (SimulationContext[] branch, uint256 totalProportions)` | public nonpayable / permissionless (off-chain only) | Estimate branch allocation and redeemable amount | CORE-RH-FR-002 |
| `truncateRedemption(uint256 _jpydf, uint256 _maxIterationsPerCollateral) → (uint256 truncatedJpydf, uint256 feePct, Redeemed[] redeemed)` | external nonpayable / permissionless (off-chain only) | Calculate the proportional request amount within the iteration limit, fee rate, and expected fill; unavailable branch shares may remain unspent | CORE-RH-FR-003 |


### LiquidationCandidateGetter (Liquidation Candidate Scanner, DF Original) 🟢

A **DF-added view helper that does not exist in base (liquity/bold v1.11.0)** (🟢 Original). It is a read-only paging scanner for liquidation bots and monitoring systems to enumerate "currently liquidatable Troves" and **only reads core state, never writes it** (all functions are view. The core does not reference this contract, so the dependency is one-way and whether it is deployed does not affect core behavior). It scans SortedTroves in interest-rate order and returns Troves whose ICR is below the caller-supplied price and MCR. When needed, it can also retrieve `lastZombieTroveId`, which is removed from SortedTroves, in the same candidate format. It is a branch-common **singleton**. No asset custody and no events. Source-header comment: "Helper contract for liquidation bots and monitoring. Not part of the core Liquity system."

**Interface List (Non-Normative; Behavioral Norms Are in §6)**

| Function | Visibility / Permission | Summary | Spec ID |
| --- | --- | --- | --- |
| `collateralRegistry() → ICollateralRegistry` | external view (immutable) | Referenced CollateralRegistry | CORE-LCG-FR-002 |
| `getLiquidationCandidates(uint256 _collIndex, uint256 _startId, uint256 _maxIterations, uint256 _price, uint256 _mcr) → (LiquidationCandidate[] candidates, uint256 currId)` | external view / permissionless | Enumerate Troves with ICR < `_mcr` by paging scan | CORE-LCG-FR-001 |
| `getLiquidationCandidatesWithLastZombie(uint256 _collIndex, uint256 _startId, uint256 _maxIterations, uint256 _price, uint256 _mcr, bool _includeLastZombie) → (LiquidationCandidate[] candidates, uint256 currId, bool includedLastZombie)` | external view / permissionless | Optionally append a liquidatable `lastZombieTroveId` to the SortedTroves scan result | CORE-LCG-FR-003 |
| `getLastZombieLiquidationCandidate(uint256 _collIndex, uint256 _price, uint256 _mcr) → (bool found, LiquidationCandidate candidate)` | external view / permissionless | Liquidation-candidate evaluation for `lastZombieTroveId` alone | CORE-LCG-FR-003 |


### Constants.sol (System Constants) 🔵/🟡

A set of file-level constants shared across compilation units. It is the declaration location for core-wide economic parameters such as collateral ratios, liquidation penalties, interest-rate ranges, redemption parameters, and yield split. These are not a contract; they are Solidity file-level `constant`s and are inlined into referencing contracts' bytecode at compile time (no storage and no getters. Changing a value means recompiling and redeploying referencing contracts).

DF deltas are concentrated in this file in three forms: `MIN_DEBT` change (🟡 CORE-MOD-002), `COLL_GAS_COMPENSATION_CAP` change (🟡 CORE-MOD-003), and **addition** of branch-specific constant groups (CORE-MOD-005. Upstream constants are unchanged). The canonical source for final values is [Parameters.md](../../../Parameters.md).

**Interface List (Non-Normative; Behavioral Norms Are in §6)**

File-level constants have no ABI.


### LiquityBase (Branch-Common Accounting Base) 🔵

The common base contract inherited by TroveManager, BorrowerOperations, StabilityPool, and 🟡 DFStabilityPool. In its constructor it resolves and holds references to the branch's ActivePool / DefaultPool / PriceFeed from AddressesRegistry, and provides aggregation of branch-wide collateral and debt, TCR calculation, Critical Threshold checks, and simple-interest calculation primitives. The specified interface is `ILiquityBase` (only 3 functions: `activePool()` / `getEntireBranchDebt()` / `getEntireBranchColl()`. No NatSpec).

**Interface List (Non-Normative; Behavioral Norms Are in §6)**

| Function | Visibility / Permission | Summary | Spec ID |
| --- | --- | --- | --- |
| `activePool() → IActivePool` | public view (automatic getter) | Branch ActivePool reference | CORE-LIB-FR-005 |
| `getEntireBranchColl() → uint256` | public view | Total branch collateral (Active + Default) | CORE-LIB-FR-006 |
| `getEntireBranchDebt() → uint256` | public view | Total branch liabilities (Active + Default) | CORE-LIB-FR-006 |

(internal: `_getTCR` / `_checkBelowCriticalThreshold` = CORE-LIB-FR-007, `_calcInterest` = CORE-LIB-FR-008. They do not appear in the ABI but are the behavioral base for inheriting contracts, so they are specified as FRs.)


### LiquityMath (Math Library) 🔵

A math library consisting only of internal pure functions (no deployment unit; inlined into referencing contracts). It provides min/max, difference, collateral ratio (CR) calculation, and 18-decimal fixed-point exponentiation (for time decay of redemption baseRate).

**Interface List (Non-Normative; Behavioral Norms Are in §6)**

No ABI (all functions are internal). Provided functions: `_min` / `_max` / `_sub_min_0` / `decMul` / `_decPow` / `_getAbsoluteDifference` / `_computeCR` (spec IDs: CORE-LIB-FR-009 / 010).


### Ownable (Custom Ownable for One-Shot Wiring) 🔵

A lightweight upstream custom Ownable based on OpenZeppelin Ownable. **Unlike OZ, it has no `transferOwnership` (cannot transfer) and no public `renounceOwnership`**. Ownership can be abandoned only through internal `_renounceOwnership()`, intended for a "disposable owner" pattern in which an inheriting contract calls it at the end of a one-time wiring function immediately after deployment. The two inheritors are JpydfToken (renounces at the end of `setCollateralRegistry`; CORE-BT) and AddressesRegistry (renounces at the end of `setAddresses`; CORE-AR).

**Interface List (Non-Normative; Behavioral Norms Are in §6)**

| Function | Visibility / Permission | Summary | Spec ID |
| --- | --- | --- | --- |
| `owner() → address` | public view | Current owner (`address(0)` after renounce) | CORE-LIB-FR-011 |
| `isOwner() → bool` | public view | `msg.sender == _owner` | CORE-LIB-FR-011 |

(modifier `onlyOwner` = CORE-LIB-FR-011, internal `_renounceOwnership()` = CORE-LIB-FR-012)


### Types (Shared Type Definitions) 🔵

Five files under `contracts/src/Types/`: two user-defined value types (TroveId / BatchId) and three structs used to pass interest-accounting deltas and snapshots (TroveChange / LatestTroveData / LatestBatchData). All are type definitions without logic (value-type operators and predicates are pure free functions) and have no deployment unit.

**Interface List (Non-Normative; Behavioral Norms Are in §6)**

Not applicable (type definitions only; no ABI. Value-type operators `==` / `!=` and predicates `isEndOfList` / `isNotEndOfList` / `isZero` / `isNotZero` are compile-time-resolved free functions).

**AggregatorV3Interface**

Minimal reprint of the Chainlink AggregatorV3 interface (only `decimals()` / `latestRoundData()`). It is a dependency of the PriceFeed series, and its norm is in [Oracle.md](Oracle.md) scope (not specified in this document).


---

## 6. Functional Requirements (FR)

> The normative body. Every external/public function is specified as an FR by contract (self-evident view getters are grouped into "view function group" FRs). Each FR's **Verification** uses the verification vocabulary in §13 (`parity` / `unit` / `fuzz` / `invariant` / `fork` / `manual`). See §2.4 for the normative stance of 🔵 requirements (the base implementation is correct).


### BorrowerOperations Functional Requirements (`CORE-BO-FR-*`)

#### CORE-BO-FR-001: `openTrove` (Open New Trove) 🔵/🟡
- **Type**: Functional / **Source**: base implementation (BorrowerOperations.sol) + CORE-MOD-013
- **Signature**: `openTrove(address _owner, uint256 _ownerIndex, uint256 _collAmount, uint256 _jpydfAmount, uint256 _upperHint, uint256 _lowerHint, uint256 _annualInterestRate, uint256 _maxUpfrontFee, address _addManager, address _removeManager, address _receiver) → uint256`
- **Purpose**: Deposit collateral `_collAmount`, borrow `_jpydfAmount` JPYdf, and open a new Trove with self-selected interest rate `_annualInterestRate`. Returns the Trove ID.
- **Authorization**: permissionless (caller bears collateral and WETH gas compensation. NFT is issued to `_owner`).
- **Preconditions (Checks)** (code check order):
  1. `_annualInterestRate` is within `[MIN_ANNUAL_INTEREST_RATE, MAX_ANNUAL_INTEREST_RATE]` (values in §7).
  2. `addressesRegistry.riskParamsFinalized() == true` (an unfinalized reserved branch cannot open a Trove; both open entry points check this in their shared `_openTrove` path).
  3. Not shut down (`hasBeenShutDown == false`).
  4. `priceFeed.fetchPrice()` does not detect oracle failure (PriceFeedProxy; [Oracle.md](Oracle.md)).
  5. `troveId = keccak256(abi.encode(msg.sender, _owner, _ownerIndex))` is unused (status == `nonExistent`).
  6. upfront fee = `_calcUpfrontFee(_jpydfAmount, avgInterestRate)` (7 days at branch average interest rate, `UPFRONT_INTEREST_PERIOD`. The average interest rate is an approximation from ActivePool and at this point excludes the fee) is at most `_maxUpfrontFee`.
  7. `entireDebt = _jpydfAmount + upfrontFee ≥ MIN_DEBT` (🟡 DF value (CORE-MOD-002 / [Parameters.md](../../../Parameters.md))).
  8. `ICR = computeCR(_collAmount, entireDebt, price) ≥ MCR` (checked using debt including fee).
  9. Branch TCR after opening (including fee) ≥ CCR.
- **Behavior (Effects)** (execution order):
  1. Set `addManagerOf[troveId] = _addManager` and `removeManagerReceiverOf[troveId] = (_removeManager, _receiver)` (emit `AddManagerUpdated` / `RemoveManagerAndReceiverUpdated`. `_removeManager == 0` with `_receiver != 0` is not allowed).
  2. `activePool.mintAggInterestAndAccountForTroveChange(change, address(0))` (update branch aggregation; CORE-AP series).
  3. Move collateral with `collToken.safeTransferFrom(msg.sender → ActivePool)` and call `accountForReceivedColl` (collateral = dToken; [dToken.md](dToken.md)).
  4. `jpydfToken.mint(msg.sender, _jpydfAmount)` (**mint recipient is msg.sender**, not `_owner`).
  5. `WETH.transferFrom(msg.sender, gasPool, ETH_GAS_COMPENSATION)` (lock liquidation gas compensation. Value in §7. Requires prior WETH approval).
  6. `troveManager.onOpenTrove(_owner, troveId, change, _annualInterestRate)` (create Trove record and mint TroveNFT to `_owner`; CORE-TM series).
  7. `sortedTroves.insert(troveId, _annualInterestRate, _upperHint, _lowerHint)` (CORE-ST series).
  8. Return `troveId`.
- **Revert / early return**: interest rate out of range → `InterestRateTooLow` / `InterestRateTooHigh`; risk parameters unfinalized → `RiskParamsNotFinalized`; already shut down → `IsShutDown`; oracle failure detected → `NewOracleFailureDetected`; duplicate ID → `TroveExists`; fee exceeds max → `UpfrontFeeTooHigh`; below `MIN_DEBT` → `DebtBelowMin`; ICR < MCR → `ICRBelowMCR`; TCR < CCR → `TCRBelowCCR`; `_removeManager == 0` with `_receiver != 0` → `EmptyManager`; collateral or WETH `transferFrom` failure → respective token revert.
- **Emitted events**: `AddManagerUpdated` (CORE-BO-EVT-008), `RemoveManagerAndReceiverUpdated` (CORE-BO-EVT-009). Trove-state events are on the TroveManager side (CORE-TM series).
- **Design notes**: Trove ID is deterministically derived from `(msg.sender, _owner, _ownerIndex)`, and reopening with the same tuple fails with `TroveExists` (status remains even after close). The upfront fee is 7 days of the branch **average** interest rate, not the selected rate of this Trove (design to prevent immediately diluting total system interest by entering/exiting rate choices). ICR and TCR checks both use debt including the fee.
- **Verification**: parity / invariant=CORE-BO-INV-002, CORE-BO-INV-005

#### CORE-BO-FR-002: `openTroveAndJoinInterestBatchManager` (Open and Join Batch at the Same Time) 🔵/🟡
- **Type**: Functional / **Source**: base implementation (BorrowerOperations.sol) + CORE-MOD-013
- **Signature**: `openTroveAndJoinInterestBatchManager(OpenTroveAndJoinInterestBatchManagerParams calldata _params) → uint256` (params: `owner, ownerIndex, collAmount, jpydfAmount, upperHint, lowerHint, interestBatchManager, maxUpfrontFee, addManager, removeManager, receiver`)
- **Purpose**: Open a new Trove and join an existing interest batch at the same time. The current batch rate is applied as the interest rate.
- **Authorization**: permissionless (same burden structure as FR-001).
- **Preconditions (Checks)**:
  1. `_params.interestBatchManager` is a registered batch manager (`maxInterestRate > 0`).
  2. Then same as Checks 2-7 and 9 in FR-001 (the batch `annualInterestRate` is used as the rate. The average-interest approximation for upfront fee accounts for existing batch debt plus the new borrow).
  3. ICR is at least **`MCR + BCR`** (batch-member Troves have a stronger requirement with BCR added to MCR).
- **Behavior (Effects)**: Same as Effects 1-5 in FR-001, then:
  6. `interestBatchManagerOf[troveId] = _params.interestBatchManager`.
  7. `troveManager.onOpenTroveAndJoinBatch(...)` (Trove record, NFT mint, and entry into batch shares; CORE-TM series).
  8. `sortedTroves.insertIntoBatch(troveId, batchId, batch.annualInterestRate, hints)`.
  9. Return `troveId`.
- **Revert / early return**: unregistered manager → `InvalidInterestBatchManager`; ICR < MCR+BCR → `ICRBelowMCRPlusBCR`; otherwise same as FR-001.
- **Emitted events**: Same as FR-001 (CORE-BO-EVT-008 / 009).
- **Design notes**: The BCR add-on is a buffer for "state updates on batch join/adjust performed near the liquidation boundary, interacting with redemption/liquidation calculations." Batch management fee is reflected in aggregation at the same time as weighted values in TroveChange (`newWeightedRecordedBatchManagementFee`).
- **Verification**: parity / invariant=CORE-BO-INV-002, CORE-BO-INV-003

#### CORE-BO-FR-003: `adjustTrove` (Combined Collateral/Debt Adjustment and Common Adjustment Path) 🔵/🟡
- **Type**: Functional / **Source**: base implementation (BorrowerOperations.sol `_adjustTrove`) + CORE-MOD-014
- **Signature**: `adjustTrove(uint256 _troveId, uint256 _collChange, bool _isCollIncrease, uint256 _jpydfChange, bool _isDebtIncrease, uint256 _maxUpfrontFee)`
- **Purpose**: Adjust collateral and debt of an active Trove in one transaction. The Checks/Effects in this FR specify the internal common path `_adjustTrove`; FR-004-FR-008 are specializations of this path.
- **Authorization**: branches by the change contents (AddRemoveManagers inherited surface).
  - **Withdrawal-side** (`collDecrease > 0` or `debtIncrease > 0`): owner or RemoveManager only. Only when the RemoveManager itself calls, the registered receiver (if nonzero) becomes the recipient; otherwise the owner is the recipient.
  - **Deposit-side only** (collateral addition and repayment only): owner / AddManager / RemoveManager. **If `addManagerOf` is zero, anyone may call** (deposit-side operations are open by default).
- **Preconditions (Checks)** (code check order):
  1. (external wrapper) Trove is active (zombie not allowed).
  2. `hasBeenShutDown == false`. If `isOracleFailureShutdown == true`, require `collDecrease == 0 && debtIncrease == 0` (collateral additions and debt repayments only).
  3. Only an adjustment containing collateral withdrawal or debt increase calls `fetchPrice()`, requiring a healthy quote and JPY provenance younger than 30h. Pure additions and repayments skip the oracle read.
  4. Trove is open (active or zombie. Combined with the wrapper check, the effective condition is active; zombies only through FR-008).
  5. Authorization check above.
  6. On repayment (`debtDecrease > 0`): **silently cap** repayment amount to `entireDebt - MIN_DEBT` (do not revert; if `entireDebt ≤ MIN_DEBT`, cap to 0. `MIN_DEBT` is the 🟡 DF value (CORE-MOD-002 / [Parameters.md](../../../Parameters.md))), then for the capped amount require `jpydfToken.balanceOf(msg.sender) ≥ debtDecrease`.
  7. After applying the cap, not all four components (collIncrease/collDecrease/debtIncrease/debtDecrease) are 0.
  8. Collateral withdrawal requires `collDecrease ≤ entireColl`.
  9. On borrowing (`debtIncrease > 0`): upfront fee (7 days at branch average rate, based on `debtIncrease`) is at most `_maxUpfrontFee`. The fee is added to the new debt.
  10. After adjustment, `newDebt ≥ MIN_DEBT` (always true for active Troves due to the repayment cap. In practice, this is the zombie-return requirement in FR-008).
  11. **Conditions only for adjustments containing withdrawal or debt increase** (`_requireValidAdjustmentInCurrentMode`). Pure additions and repayments skip ICR/TCR checks and may improve a Trove that remains below MCR or MCR+BCR:
      - Common to both modes: post-adjustment ICR ≥ MCR (or ≥ MCR + BCR if in a batch).
      - Normal mode (pre-adjustment TCR ≥ CCR): post-adjustment TCR ≥ CCR.
      - Critical mode (pre-adjustment TCR < CCR): borrowing is allowed only if post-adjustment TCR is restored to ≥ CCR. Collateral withdrawal is allowed only if accompanied by repayment of at least the same value (`debtDecrease × 1e18 ≥ collDecrease × price`). Restoring TCR to at least CCR is not required.
- **Behavior (Effects)** (execution order):
  1. If in a batch, `troveManager.onAdjustTroveInsideBatch(...)`; otherwise `troveManager.onAdjustTrove(...)` (updates recorded coll/debt. Recalculates shares for batches. CORE-TM series).
  2. `activePool.mintAggInterestAndAccountForTroveChange(change, batchManager)` (aggregate update including applied redistribution and batch fee).
  3. Token movement (`_moveTokensFromAdjustment`): `debtIncrease` → mint JPYdf to receiver / `debtDecrease` → burn from msg.sender / `collIncrease` → transfer from msg.sender to ActivePool / `collDecrease` → send from ActivePool to receiver.
- **Revert / early return**: irreversible shutdown, or an oracle-pause adjustment containing collateral withdrawal or debt increase → `IsShutDown`; current oracle failure → `NewOracleFailureDetected`; not open → `TroveNotOpen` (wrapper uses `TroveNotActive`); unauthorized → `NotOwnerNorRemoveManager` / `NotOwnerNorAddManager`; insufficient JPYdf balance → `NotEnoughJpydfBalance`; all components zero (including after cap to 0) → `ZeroAdjustment`; excessive withdrawal → `CollWithdrawalTooHigh`; fee exceeds max → `UpfrontFeeTooHigh`; below `MIN_DEBT` → `DebtBelowMin`; insufficient ICR → `ICRBelowMCR` / `ICRBelowMCRPlusBCR`; TCR violation → `TCRBelowCCR`; collateral-withdrawal condition violation in critical mode → `RepaymentNotMatchingCollWithdrawal`.
- **Emitted events**: none (BO itself emits none. Trove-state events are in the CORE-TM series).
- **Design notes**: The repayment silent cap means "full repayment" cannot be done with `adjustTrove`; only `closeTrove` can do it (prevents a live Trove below MIN_DEBT). For batch-member Troves, TroveChange weighted values are constructed from the whole batch (debt + management fee). Upfront fee applies only when borrowing, not to collateral operations or repayment. The oracle-pause carve-out is implemented only in this shared path; wrappers, managers, and Zappers do not carry separate exceptions.
- **Verification**: parity / invariant=CORE-BO-INV-002

#### CORE-BO-FR-004: `addColl` (Add Collateral) 🔵
- **Type**: Functional / **Source**: base implementation (BorrowerOperations.sol)
- **Signature**: `addColl(uint256 _troveId, uint256 _collAmount)`
- **Purpose**: Add collateral to an active Trove.
- **Authorization**: deposit-side (see FR-003. Anyone may call if `addManagerOf` is unset).
- **Preconditions (Checks) / Behavior (Effects)**: After checking that the Trove is active, execute the FR-003 common path with `collIncrease = _collAmount` and `_maxUpfrontFee = 0` (no fee is charged).
- **Revert / early return**: not active → `TroveNotActive`; otherwise same as FR-003.
- **Emitted events**: none.
- **Verification**: parity

#### CORE-BO-FR-005: `withdrawColl` (Withdraw Collateral) 🔵
- **Type**: Functional / **Source**: base implementation (BorrowerOperations.sol)
- **Signature**: `withdrawColl(uint256 _troveId, uint256 _collWithdrawal)`
- **Purpose**: Withdraw collateral from an active Trove.
- **Authorization**: withdrawal-side (owner / RemoveManager. Recipient follows the receiver rules in FR-003).
- **Preconditions (Checks) / Behavior (Effects)**: After checking that the Trove is active, execute FR-003 with `collDecrease = _collWithdrawal` and `_maxUpfrontFee = 0` (no fee is charged. ICR/TCR and mode-specific conditions are as in FR-003).
- **Revert / early return**: not active → `TroveNotActive`; otherwise same as FR-003.
- **Emitted events**: none.
- **Verification**: parity

#### CORE-BO-FR-006: `withdrawJpydf` (Additional Borrowing) 🟡
- **Type**: Functional / **Source**: base implementation (BorrowerOperations.sol) + DF rename (CORE-MOD-006)
- **Signature**: `withdrawJpydf(uint256 _troveId, uint256 _jpydfAmount, uint256 _maxUpfrontFee)`
- **Purpose**: Increase debt of an active Trove and mint new JPYdf.
- **Authorization**: withdrawal-side (owner / RemoveManager. Mint recipient follows the receiver rules in FR-003).
- **Preconditions (Checks) / Behavior (Effects)**: After checking that the Trove is active, execute FR-003 with `debtIncrease = _jpydfAmount`. The upfront fee (7 days at average interest) is added to debt, and `_maxUpfrontFee` specifies the cap.
- **Revert / early return**: not active → `TroveNotActive`; fee exceeds max → `UpfrontFeeTooHigh`; otherwise same as FR-003 (in critical mode, only borrowing that restores TCR is allowed).
- **Emitted events**: none.
- **Verification**: parity

#### CORE-BO-FR-007: `repayJpydf` (Repayment) 🟡
- **Type**: Functional / **Source**: base implementation (BorrowerOperations.sol) + DF rename (CORE-MOD-006)
- **Signature**: `repayJpydf(uint256 _troveId, uint256 _jpydfAmount)`
- **Purpose**: Reduce debt of an active Trove by burning JPYdf.
- **Authorization**: deposit-side (see FR-003. If `addManagerOf` is unset, third parties may repay).
- **Preconditions (Checks) / Behavior (Effects)**: After checking that the Trove is active, execute FR-003 with `debtDecrease = _jpydfAmount` and `_maxUpfrontFee = 0`. Repayment amount is silently capped to `entireDebt - MIN_DEBT` (`MIN_DEBT` is the 🟡 DF value (CORE-MOD-002 / [Parameters.md](../../../Parameters.md))). The burn source is always msg.sender.
- **Revert / early return**: not active → `TroveNotActive`; 0 after cap → `ZeroAdjustment`; insufficient balance → `NotEnoughJpydfBalance`; otherwise same as FR-003.
- **Emitted events**: none.
- **Verification**: parity

#### CORE-BO-FR-008: `adjustZombieTrove` (Adjust Zombie Trove and Return to Active) 🔵/🟡
- **Type**: Functional / **Source**: base implementation (BorrowerOperations.sol) + CORE-MOD-014
- **Signature**: `adjustZombieTrove(uint256 _troveId, uint256 _collChange, bool _isCollIncrease, uint256 _jpydfChange, bool _isDebtIncrease, uint256 _upperHint, uint256 _lowerHint, uint256 _maxUpfrontFee)`
- **Purpose**: Adjust a Trove that became zombie because redemption reduced it below `MIN_DEBT`, return it to active, and reinsert it into the sorted list.
- **Authorization**: same direction-based authorization as FR-003.
- **Preconditions (Checks)**: Trove must be zombie (active not allowed). Then all common-path checks in FR-003. In particular, post-adjustment `newDebt ≥ MIN_DEBT` is mandatory (🟡 DF value (CORE-MOD-002 / [Parameters.md](../../../Parameters.md))). While a zombie has `entireDebt < MIN_DEBT`, reactivation requires a debt increase, which CORE-MOD-014 blocks during an oracle pause. If interest or redistribution has already restored `entireDebt >= MIN_DEBT`, however, a risk-reducing collateral addition—or, while `entireDebt > MIN_DEBT`, a repayment—may reactivate it during the pause.
- **Behavior (Effects)**: After FR-003 Effects:
  1. `troveManager.setTroveStatusToActive(_troveId)` (CORE-TM series).
  2. If in a batch, `sortedTroves.insertIntoBatch` with the current batch rate; otherwise `sortedTroves.insert` with the Trove's rate (using `_upperHint`/`_lowerHint`).
- **Revert / early return**: not zombie → `TroveNotZombie`; post-adjustment below `MIN_DEBT` → `DebtBelowMin`; otherwise same as FR-003.
- **Emitted events**: none (state-transition events are in the CORE-TM series).
- **Design notes**: Zombies are outside the sorted list, so normal `adjustTrove` is rejected. This dedicated entry point forces reinsertion into the list with hints when returning to active.
- **Price-free reactivation**: A zombie whose debt has recovered to MIN_DEBT through interest or redistribution may return to active via a pure addition/repayment without an ICR check, including below MCR; it remains liquidatable.
- **Verification**: parity

#### CORE-BO-FR-009: `closeTrove` (Close Trove) 🔵
- **Type**: Functional / **Source**: base implementation (BorrowerOperations.sol)
- **Signature**: `closeTrove(uint256 _troveId)`
- **Purpose**: Repay the full debt (including interest, batch fee, and redistribution) to close the Trove and recover collateral and WETH gas compensation.
- **Authorization**: owner or RemoveManager (receiver rules same as FR-003. Collateral and gas compensation go to receiver; JPYdf is burned from msg.sender).
- **Preconditions (Checks)** (code check order):
  1. Get owner via `troveNFT.ownerOf(_troveId)` (nonexistent Trove reverts on ERC-721 side) and determine authorization/receiver.
  2. Trove is open (active or zombie).
  3. `jpydfToken.balanceOf(msg.sender) ≥ trove.entireDebt`.
  4. If not economically shut down, call `priceFeed.fetchPrice()`. A currently unhealthy source reverts `NewOracleFailureDetected`; a recovered live normal price is accepted even before Owner resume.
  5. If not economically shut down: post-close branch TCR ≥ CCR. Economic shutdown skips price and TCR checks.
- **Behavior (Effects)** (execution order):
  1. `troveManager.onCloseTrove(...)` (status → `closedByOwner`, NFT burn, exit from batch. CORE-TM series).
  2. If the Trove belonged to a batch, clear `interestBatchManagerOf[_troveId]`.
  3. `activePool.mintAggInterestAndAccountForTroveChange(change, batchManager)`.
  4. `WETH.transferFrom(gasPool, receiver, ETH_GAS_COMPENSATION)` (return gas compensation).
  5. `jpydfToken.burn(msg.sender, trove.entireDebt)`.
  6. `activePool.sendColl(receiver, trove.entireColl)` (return collateral = dToken; [dToken.md](dToken.md)).
  7. `_wipeTroveMappings`: clear individual delegate, batch link, AddManager/RemoveManager (emit `AddManagerUpdated(0)` / `RemoveManagerAndReceiverUpdated(0,0)`).
- **Revert / early return**: unauthorized → `NotOwnerNorRemoveManager`; not open → `TroveNotOpen`; insufficient balance → `NotEnoughJpydfBalance`; TCR < CCR (when not shut down) → `TCRBelowCCR`.
- **Emitted events**: `AddManagerUpdated` (CORE-BO-EVT-008), `RemoveManagerAndReceiverUpdated` (CORE-BO-EVT-009).
- **Design notes**: Closing remains possible after irreversible economic shutdown. During an oracle pause it waits for current normal-price recovery and then remains CCR-checked, but does not wait for Owner resume. Before economic shutdown the last Trove cannot be closed (`OnlyOneTroveLeft`); after economic shutdown the guard and price/TCR checks are bypassed.
- **Verification**: parity / invariant=CORE-BO-INV-002

#### CORE-BO-FR-010: `applyPendingDebt` (Finalize Interest and Redistribution into Recorded Values) 🔵
- **Type**: Functional / **Source**: base implementation (BorrowerOperations.sol)
- **Signature**: `applyPendingDebt(uint256 _troveId, uint256 _lowerHint, uint256 _upperHint)` (public)
- **Purpose**: Compound any pending amounts for an arbitrary Trove (accrued interest, batch management fee, and redistribution gains) into recorded coll/debt. If a zombie has recovered to at least `MIN_DEBT`, return it to active.
- **Authorization**: permissionless (anyone can execute for any Trove).
- **Preconditions (Checks)**: not shut down; Trove is open (active or zombie); `entireDebt != 0`.
- **Behavior (Effects)**:
  1. `troveManager.onApplyTroveInterest(...)` (update recorded coll/debt and batch aggregation. CORE-TM series).
  2. `activePool.mintAggInterestAndAccountForTroveChange(change, batchManager)`.
  3. If zombie and `entireDebt ≥ MIN_DEBT` (🟡 DF value (CORE-MOD-002 / [Parameters.md](../../../Parameters.md))), call `setTroveStatusToActive` and reinsert into the sorted list (as a batch if it belongs to one).
- **Revert / early return**: already shut down → `IsShutDown`; not open → `TroveNotOpen`; zero debt → `TroveWithZeroDebt`.
- **Emitted events**: none (BO side).
- **Design notes**: This lets third parties eliminate divergence between recorded debt and actual debt for Troves that have not been operated for a long time (keeping redemption order and liquidation assumptions correct). There is only one signature and it includes hints (needed when reinserting a zombie into SortedTroves).
- **Verification**: parity

#### CORE-BO-FR-011: `adjustTroveInterestRate` (Change Individual Trove Interest Rate) 🔵
- **Type**: Functional / **Source**: base implementation (BorrowerOperations.sol)
- **Signature**: `adjustTroveInterestRate(uint256 _troveId, uint256 _newAnnualInterestRate, uint256 _upperHint, uint256 _lowerHint, uint256 _maxUpfrontFee)`
- **Purpose**: Change the annual interest rate of an active Trove that is not in a batch and update its position in the sorted list.
- **Authorization**: owner or `interestIndividualDelegateOf[_troveId].account` (individual interest delegate). **Only delegate calls** are subject to additional constraints (rate range and change interval); owner calls are not.
- **Preconditions (Checks)** (code check order):
  1. Not shut down.
  2. `_newAnnualInterestRate` is within `[MIN_ANNUAL_INTEREST_RATE, MAX_ANNUAL_INTEREST_RATE]`.
  3. Not in a batch.
  4. Caller is owner or delegate.
  5. Trove is active.
  6. If caller is delegate: rate is within delegate-configured `[minInterestRate, maxInterestRate]`, and `lastInterestRateAdjTime + minInterestRateChangePeriod` has elapsed.
  7. New rate ≠ current rate.
  8. Only for a **premature change** (`block.timestamp < lastInterestRateAdjTime + INTEREST_RATE_ADJ_COOLDOWN`; cooldown is 7 days): oracle live, upfront fee (based on `entireDebt`, 7 days at average interest) ≤ `_maxUpfrontFee`, ICR after fee addition ≥ MCR, and TCR after fee addition ≥ CCR. **After cooldown has elapsed, the change is free and performs no ICR/TCR/oracle checks**.
- **Behavior (Effects)**:
  1. `activePool.mintAggInterestAndAccountForTroveChange(change, address(0))` (including application of redistribution gains).
  2. `sortedTroves.reInsert(_troveId, _newAnnualInterestRate, hints)`.
  3. `troveManager.onAdjustTroveInterestRate(...)` (update recorded values and `lastInterestRateAdjTime`. CORE-TM series).
- **Revert / early return**: `IsShutDown`; `InterestRateTooLow` / `InterestRateTooHigh`; `TroveInBatch`; `NotOwnerNorInterestManager`; `TroveNotActive`; `InterestNotInRange` (delegate range); `DelegateInterestRateChangePeriodNotPassed`; `InterestRateNotNew`; premature path: `NewOracleFailureDetected` / `UpfrontFeeTooHigh` / `ICRBelowMCR` / `TCRBelowCCR`.
- **Emitted events**: none (BO side).
- **Design notes**: The premature fee makes last-minute interest-rate increases to avoid redemption costly. The fee compounds into debt (it is minted as interest in AP aggregation; the borrower does not receive JPYdf).
- **Verification**: parity / invariant=CORE-BO-INV-002

#### CORE-BO-FR-012: `setInterestIndividualDelegate` (Set Individual Interest Delegate) 🔵
- **Type**: Functional / **Source**: base implementation (BorrowerOperations.sol)
- **Signature**: `setInterestIndividualDelegate(uint256 _troveId, address _delegate, uint128 _minInterestRate, uint128 _maxInterestRate, uint256 _newAnnualInterestRate, uint256 _upperHint, uint256 _lowerHint, uint256 _maxUpfrontFee, uint256 _minInterestRateChangePeriod)`
- **Purpose**: Delegate Trove interest-rate change authority to a third party (cold/hot wallet setup or automated operations bot) with an allowed rate range and minimum change interval. The delegate can change only interest, not debt or collateral.
- **Authorization**: owner only (managers not allowed).
- **Preconditions (Checks)**: not shut down; Trove is active; caller is owner; `_minInterestRate`/`_maxInterestRate` are each within the global range; `_minInterestRate < _maxInterestRate`. There is no lower bound on `_minInterestRateChangePeriod` (unlike batch managers, `MIN_INTEREST_RATE_CHANGE_PERIOD` is not enforced. 0 may be set).
- **Behavior (Effects)**:
  1. `interestIndividualDelegateOf[_troveId] = (_delegate, _minInterestRate, _maxInterestRate, _minInterestRateChangePeriod)`.
  2. If currently in a batch, internally call `removeFromBatch(_troveId, _newAnnualInterestRate, hints, _maxUpfrontFee)` (individual delegation and batch membership are mutually exclusive. Exit conditions and fee are as in FR-018).
- **Revert / early return**: `IsShutDown`; `TroveNotActive`; `NotBorrower`; `InterestRateTooLow` / `InterestRateTooHigh`; `MinGeMax`; batch-exit reverts are as in FR-018.
- **Emitted events**: none.
- **Verification**: parity / invariant=CORE-BO-INV-002

#### CORE-BO-FR-013: `removeInterestIndividualDelegate` (Remove Individual Interest Delegate) 🔵
- **Type**: Functional / **Source**: base implementation (BorrowerOperations.sol)
- **Signature**: `removeInterestIndividualDelegate(uint256 _troveId)`
- **Purpose**: Remove the individual interest delegate.
- **Authorization**: owner only.
- **Preconditions (Checks)**: caller is owner only (**executable after shutdown and for zombies**).
- **Behavior (Effects)**: `delete interestIndividualDelegateOf[_troveId]`.
- **Revert / early return**: `NotBorrower`.
- **Emitted events**: none.
- **Verification**: parity

#### CORE-BO-FR-014: `registerBatchManager` (Register Batch Manager) 🔵
- **Type**: Functional / **Source**: base implementation (BorrowerOperations.sol)
- **Signature**: `registerBatchManager(uint128 _minInterestRate, uint128 _maxInterestRate, uint128 _currentInterestRate, uint128 _annualManagementFee, uint128 _minInterestRateChangePeriod)`
- **Purpose**: Register msg.sender as an interest batch manager. On registration, the manager commits to its operating range (min/max rate), initial interest rate, annual management fee, and minimum interest-rate change interval.
- **Authorization**: permissionless (self-registration. One time per address).
- **Preconditions (Checks)** (code check order):
  1. Not shut down.
  2. msg.sender is not registered (`interestBatchManagers[msg.sender].maxInterestRate == 0`).
  3. `_minInterestRate`/`_maxInterestRate` are within the global range and `_minInterestRate < _maxInterestRate`.
  4. `_currentInterestRate` is within `[_minInterestRate, _maxInterestRate]`.
  5. `_annualManagementFee ≤ MAX_ANNUAL_BATCH_MANAGEMENT_FEE` (10%; value in Constants.sol).
  6. `_minInterestRateChangePeriod ≥ MIN_INTEREST_RATE_CHANGE_PERIOD` (1 hour; value in Constants.sol).
- **Behavior (Effects)**:
  1. `interestBatchManagers[msg.sender] = (min, max, period)` (**no method exists to change or delete this afterward**).
  2. `troveManager.onRegisterBatchManager(msg.sender, _currentInterestRate, _annualManagementFee)` (create batch record. CORE-TM series).
- **Revert / early return**: `IsShutDown`; `BatchManagerExists`; `InterestRateTooLow` / `InterestRateTooHigh`; `MinGeMax`; `InterestNotInRange`; `AnnualManagementFeeTooHigh`; `MinInterestRateChangePeriodTooLow`.
- **Emitted events**: none (BO side. Batch-record events are in CORE-TM series).
- **Design notes**: Immutability of min/max/period structurally prevents a rug in which the manager widens the range after Troves join and sets unexpected rates. The management fee can only be **lowered** from the committed value (FR-016). `maxInterestRate > 0` is the registered sentinel (the global minimum interest rate is > 0, so registered managers always have positive max).
- **Verification**: parity / invariant=CORE-BO-INV-004

#### CORE-BO-FR-015: `setBatchManagerAnnualInterestRate` (Bulk Batch Interest-Rate Change) 🔵
- **Type**: Functional / **Source**: base implementation (BorrowerOperations.sol)
- **Signature**: `setBatchManagerAnnualInterestRate(uint128 _newAnnualInterestRate, uint256 _upperHint, uint256 _lowerHint, uint256 _maxUpfrontFee)`
- **Purpose**: Let a batch manager change the annual interest rate for its entire batch in bulk.
- **Authorization**: registered batch manager (only msg.sender's own batch).
- **Preconditions (Checks)** (code check order):
  1. Not shut down.
  2. msg.sender is registered.
  3. New rate is within **the manager's own `[minInterestRate, maxInterestRate]` committed at registration**.
  4. `batch.lastInterestRateAdjTime + minInterestRateChangePeriod` (value committed at registration) has elapsed.
  5. Only for a **premature change** (rate actually changes and `block.timestamp < batch.lastInterestRateAdjTime + INTEREST_RATE_ADJ_COOLDOWN`): oracle live, upfront fee (based on **entire batch debt** `entireDebtWithoutRedistribution`) ≤ `_maxUpfrontFee`, and TCR including fee ≥ CCR (individual ICR is not checked).
- **Behavior (Effects)**:
  1. `activePool.mintAggInterestAndAccountForTroveChange(batchChange, msg.sender)`.
  2. If the batch is non-empty, `sortedTroves.reInsertBatch(batchId, _newAnnualInterestRate, hints)`.
  3. `troveManager.onSetBatchManagerAnnualInterestRate(...)` (update batch record; fee compounds into batch debt. CORE-TM series).
- **Revert / early return**: `IsShutDown`; `InvalidInterestBatchManager`; `InterestNotInRange`; `BatchInterestRateChangePeriodNotPassed`; premature path: `NewOracleFailureDetected` / `UpfrontFeeTooHigh` / `TCRBelowCCR`.
- **Emitted events**: none (BO side).
- **Design notes**: Re-setting to the same rate is allowed because there is **no** check equivalent to `InterestRateNotNew` (in that case the premature condition is also false and there is no fee. `lastInterestRateAdjTime` is updated according to the TM-side specification). Since premature fees apply to the whole batch debt, frequent changes become a cost for all batch participants (the committed `minInterestRateChangePeriod` protects delegators).
- **Verification**: parity / invariant=CORE-BO-INV-004

#### CORE-BO-FR-016: `lowerBatchManagementFee` (Lower Batch Management Fee) 🔵
- **Type**: Functional / **Source**: base implementation (BorrowerOperations.sol)
- **Signature**: `lowerBatchManagementFee(uint256 _newAnnualManagementFee)`
- **Purpose**: Let a batch manager lower its annual management fee (increases are impossible).
- **Authorization**: registered batch manager.
- **Preconditions (Checks)**: not permanently shut down (a recoverable oracle pause permits fee reductions); msg.sender is registered; `_newAnnualManagementFee < batch.annualManagementFee` (strictly lower).
- **Behavior (Effects)**:
  1. `troveManager.onLowerBatchManagerAnnualFee(...)` (finalize accumulation under old fee, then record new fee. CORE-TM series).
  2. `activePool.mintAggInterestAndAccountForTroveChange(batchChange, msg.sender)` (mint accumulated management fee and replace weighted values).
- **Revert / early return**: `IsShutDown`; `InvalidInterestBatchManager`; `NewFeeNotLower`.
- **Emitted events**: none (BO side).
- **Design notes**: Monotonic fee decrease guarantees that the fee seen at join time cannot become worse afterward (registration requires `MAX_ANNUAL_BATCH_MANAGEMENT_FEE` or lower, so it always remains within the cap).
- **Verification**: parity / invariant=CORE-BO-INV-004

#### CORE-BO-FR-017: `setInterestBatchManager` (Join Existing Trove to Batch) 🔵
- **Type**: Functional / **Source**: base implementation (BorrowerOperations.sol)
- **Signature**: `setInterestBatchManager(uint256 _troveId, address _newBatchManager, uint256 _upperHint, uint256 _lowerHint, uint256 _maxUpfrontFee)` (public)
- **Purpose**: Join an active Trove that is not in a batch to a registered batch, switching its interest rate to the current batch value.
- **Authorization**: owner only.
- **Preconditions (Checks)** (code check order):
  1. Not shut down.
  2. Trove is active.
  3. Caller is owner.
  4. `_newBatchManager` is registered.
  5. Trove is not in a batch.
  6. **Upfront fee is always charged** (regardless of cooldown; based on the Trove's `entireDebt`, 7 days at average interest): oracle live, fee ≤ `_maxUpfrontFee`, ICR after fee addition ≥ **MCR + BCR**, and TCR after fee addition ≥ CCR.
- **Behavior (Effects)**:
  1. `interestBatchManagerOf[_troveId] = _newBatchManager`.
  2. If an individual interest delegate is set, delete it (mutually exclusive).
  3. `activePool.mintAggInterestAndAccountForTroveChange(newBatchTroveChange, _newBatchManager)` (incorporate Trove debt into the batch weighted aggregation).
  4. `troveManager.onSetInterestBatchManager(...)` (zero Trove record fields and join batch shares. CORE-TM series).
  5. `sortedTroves.remove(_troveId)` → `sortedTroves.insertIntoBatch(...)` (move from individual node to batch node).
- **Revert / early return**: `IsShutDown`; `TroveNotActive`; `NotBorrower`; `InvalidInterestBatchManager`; `TroveInBatch`; `NewOracleFailureDetected`; `UpfrontFeeTooHigh`; `ICRBelowMCRPlusBCR`; `TCRBelowCCR`.
- **Emitted events**: none (BO side).
- **Design notes**: The fee is charged **unconditionally** to prevent gaming in which a borrower repeatedly joins and leaves a batch they control to bypass premature-fee checks and obtain effectively free interest-rate changes (design intent from code comments). After joining, the Trove's ICR requirement is strengthened to MCR+BCR.
- **Verification**: parity / invariant=CORE-BO-INV-002, CORE-BO-INV-003

#### CORE-BO-FR-018: `removeFromBatch` (Leave Batch) 🔵
- **Type**: Functional / **Source**: base implementation (BorrowerOperations.sol `_removeFromBatch(_kick=false)`)
- **Signature**: `removeFromBatch(uint256 _troveId, uint256 _newAnnualInterestRate, uint256 _upperHint, uint256 _lowerHint, uint256 _maxUpfrontFee)` (public)
- **Purpose**: Remove a batch-member Trove and return it to an individual Trove with self-selected interest rate `_newAnnualInterestRate`.
- **Authorization**: owner only.
- **Preconditions (Checks)** (code check order):
  1. Not shut down.
  2. Trove is active (zombies not allowed. Zombies must first return through FR-008).
  3. Caller is owner.
  4. `_newAnnualInterestRate` is within the global range.
  5. Trove belongs to a batch.
  6. Only for a **premature change** (`_newAnnualInterestRate ≠ batch.annualInterestRate` and `block.timestamp < trove.lastInterestRateAdjTime + INTEREST_RATE_ADJ_COOLDOWN`): oracle live, upfront fee (based on Trove `entireDebt`) ≤ `_maxUpfrontFee`, ICR after fee addition ≥ **MCR** (no BCR after leaving because the Trove is individual), and TCR after fee addition ≥ CCR.
- **Behavior (Effects)**:
  1. `delete interestBatchManagerOf[_troveId]`.
  2. If not zombie, `sortedTroves.removeFromBatch(_troveId)` → `sortedTroves.insert(_troveId, _newAnnualInterestRate, hints)`.
  3. `activePool.mintAggInterestAndAccountForTroveChange(batchChange, batchManager)` (separate the Trove portion from batch weighted values and account individual weighted values at the new rate).
  4. `troveManager.onRemoveFromBatch(...)` (settle shares, independent Trove record, and new interest rate. CORE-TM series).
- **Revert / early return**: `IsShutDown`; `TroveNotActive`; `NotBorrower`; `InterestRateTooLow` / `InterestRateTooHigh`; `TroveNotInBatch`; premature path: `NewOracleFailureDetected` / `UpfrontFeeTooHigh` / `ICRBelowMCR` / `TCRBelowCCR`.
- **Emitted events**: none (BO side).
- **Design notes**: No fee if leaving at the current batch rate (or after cooldown). Premature determination uses the **Trove-side** `lastInterestRateAdjTime` (different from the batch-side basis in FR-015).
- **Verification**: parity / invariant=CORE-BO-INV-002

#### CORE-BO-FR-019: `kickFromBatch` (Force Removal from Batch with Deteriorated Shares Ratio) 🔵
- **Type**: Functional / **Source**: base implementation (BorrowerOperations.sol `_removeFromBatch(_kick=true)`)
- **Signature**: `kickFromBatch(uint256 _troveId, uint256 _upperHint, uint256 _lowerHint)`
- **Purpose**: Allow a third party to remove a Trove from a batch when the batch's "debt/shares ratio" has deteriorated above `MAX_BATCH_SHARES_RATIO` (1e9; value in Constants.sol).
- **Authorization**: permissionless.
- **Preconditions (Checks)**:
  1. Not shut down.
  2. Trove is open (**zombies are also targets**. Unlike FR-018, there is no owner check or interest-rate argument).
  3. Trove belongs to a batch.
  4. `batch.totalDebtShares × MAX_BATCH_SHARES_RATIO < batch.entireDebtWithoutRedistribution` (revert if not deteriorated).
- **Behavior (Effects)**: Same as FR-018 Effects. However, the new interest rate **inherits the current batch rate**, so the premature condition is false and there is no upfront fee, ICR/TCR check, or oracle fetch. For zombies, sorted-list operations are skipped (only batch link removal and accounting separation).
- **Revert / early return**: `IsShutDown`; `TroveNotOpen`; `TroveNotInBatch`; `BatchSharesRatioTooLow` (ratio has not deteriorated).
- **Emitted events**: none (BO side).
- **Design notes**: A batch whose debt/shares ratio reaches the cap may become unable to accept new members or adjustments due to TM-side checks, so this permissionless removal path rescues Troves from a "stuck batch." Since interest rate and debt do not change, it does not harm the owner.
- **Verification**: parity

#### CORE-BO-FR-020: `switchBatchManager` (Switch Batch) 🔵
- **Type**: Functional / **Source**: base implementation (BorrowerOperations.sol)
- **Signature**: `switchBatchManager(uint256 _troveId, uint256 _removeUpperHint, uint256 _removeLowerHint, address _newBatchManager, uint256 _addUpperHint, uint256 _addLowerHint, uint256 _maxUpfrontFee)`
- **Purpose**: Move a batch-member Trove to a different batch in one transaction.
- **Authorization**: owner only (follows the internal checks of FR-018 / FR-017).
- **Preconditions (Checks)**: Trove is in a batch; `_newBatchManager ≠ old batch manager`; then all checks from internal calls to FR-018 (leave old batch at the **current old-batch rate** → premature false, no fee) and FR-017 (join new batch → **fee always charged**, ICR ≥ MCR+BCR, TCR ≥ CCR).
- **Behavior (Effects)**: Execute `removeFromBatch(_troveId, oldBatch.annualInterestRate, removeHints, 0)` → `setInterestBatchManager(_troveId, _newBatchManager, addHints, _maxUpfrontFee)` in that order.
- **Revert / early return**: `TroveNotInBatch`; `BatchManagerNotNew`; otherwise the revert groups from FR-018 / FR-017 (shutdown checks also take effect through internal calls).
- **Emitted events**: none (BO side).
- **Design notes**: Upfront fee is charged exactly once on the join side (leaving is free because it uses the same rate).
- **Verification**: parity

#### CORE-BO-FR-021: `shutdown` (Branch Shutdown When TCR < SCR) 🔵
- **Type**: Functional / **Source**: base implementation (BorrowerOperations.sol)
- **Signature**: `shutdown()`
- **Purpose**: Allow anyone to permanently shut down a branch when branch TCR falls below SCR. After shutdown, borrowing operations except closeTrove, claimCollateral, and similar exit paths stop, and urgent redemption becomes available on TroveManager.
- **Authorization**: permissionless (gated by state condition TCR < SCR).
- **Preconditions (Checks)**:
  1. Not already shut down (`hasBeenShutDown == false`; **one-shot**).
  2. If `priceFeed.fetchPrice()` returns failure, **return early**. JPY provenance aged 30h or more also returns failure, without latching pause merely for age. Debt accrual continues and urgent redemption remains unavailable until actual permanent shutdown. Reassess TCR including accrued debt once a fresh JPY update is observed, even before Owner resume.
  3. `TCR = computeCR(total branch coll, total debt, price) < SCR`.
- **Behavior (Effects)** (`_applyShutdown`):
  1. `activePool.mintAggInterest()` (finalize aggregate interest up to shutdown time. Branch interest stops thereafter. CORE-AP series).
  2. Clear `isOracleFailureShutdown`.
  3. `hasBeenShutDown = true`.
  4. `troveManager.shutdown()` (record `shutdownTime` and set ActivePool shutdown flag. CORE-TM series).
  5. Emit `ShutDown(TCR)`.
- **Revert / early return**: already shut down → `IsShutDown`; TCR ≥ SCR → `TCRNotBelowSCR`; oracle failure detected → return without revert (no event).
- **Emitted events**: `ShutDown` (CORE-BO-EVT-006).
- **Design notes**: This TCR-based shutdown is irreversible. Oracle failure pause (FR-022) does not set `hasBeenShutDown`, TroveManager `shutdownTime`, or ActivePool shutdown state.
- **Verification**: parity / invariant=CORE-BO-INV-001

#### CORE-BO-FR-022: Recoverable Oracle-Failure Pause and Validated Resume 🔵/🟡
- **Type**: Functional / **Source**: base implementation (BorrowerOperations.sol) + CORE-MOD-014
- **Signature**: `shutdownFromOracleFailure()` / `resumeFromOracleFailure()`
- **Purpose**: Let PriceFeed pause the branch without triggering irreversible economic shutdown, then resume after PriceFeedProxy validates current normal and redemption paths in one transaction.
- **Authorization**: `priceFeed` only (PriceFeedProxy in the DF configuration; [Oracle.md](Oracle.md)).
- **Preconditions (Checks)**: both functions require caller == priceFeed. `shutdownFromOracleFailure` is a no-op if already temporarily or economically shut down.
- **Behavior (Effects)**:
  - `shutdownFromOracleFailure`: set `isOracleFailureShutdown = true`; do not change `hasBeenShutDown`, TM/AP shutdown state, or interest accrual.
  - `resumeFromOracleFailure`: set `isOracleFailureShutdown = false`. Source health and Owner authorization are enforced by the registered PriceFeedProxy.
  - During the pause, pure collateral additions and repayments require no oracle quote. Liquidation requires a source-policy-valid price; `closeTrove` and new permanent-shutdown decisions additionally require JPY provenance younger than 30h. Those price-dependent paths may resume before Owner resume once their inputs qualify. Normal redemption, collateral withdrawal, and debt increase wait for resume (CORE-MOD-014).
- **Revert / early return**: non-priceFeed → `CallerNotPriceFeed`; duplicate stop → no-op.
- **Emitted events**: none on BO; monitor PriceFeedProxy `SourceFailureHandled` / `OracleFailureShutdownResumed`.
- **Verification**: unit / integration / invariant=CORE-BO-INV-001

#### CORE-BO-FR-023: `onLiquidateTrove` (Clear BO-Side State on Liquidation) 🔵
- **Type**: Functional / **Source**: base implementation (BorrowerOperations.sol)
- **Signature**: `onLiquidateTrove(uint256 _troveId)`
- **Purpose**: When TroveManager liquidates a Trove, clear per-Trove permission/delegation state remaining on the BO side.
- **Authorization**: `troveManager` only.
- **Preconditions (Checks)**: caller is troveManager.
- **Behavior (Effects)**: `_wipeTroveMappings(_troveId)` — delete `interestIndividualDelegateOf`, `interestBatchManagerOf`, `addManagerOf`, and `removeManagerReceiverOf`, and emit `AddManagerUpdated(_troveId, 0)` and `RemoveManagerAndReceiverUpdated(_troveId, 0, 0)`.
- **Revert / early return**: non-troveManager → `CallerNotTroveManager`.
- **Emitted events**: `AddManagerUpdated` (CORE-BO-EVT-008), `RemoveManagerAndReceiverUpdated` (CORE-BO-EVT-009).
- **Design notes**: Trove IDs are deterministic from `(msg.sender, _owner, _ownerIndex)` and are normally not reused, but leaving old manager settings on a liquidated Trove could be misused in queries or future extensions, so they are explicitly cleared.
- **Verification**: parity

#### CORE-BO-FR-024: `claimCollateral` (Withdraw Surplus Collateral from Liquidation) 🔵
- **Type**: Functional / **Source**: base implementation (BorrowerOperations.sol)
- **Signature**: `claimCollateral()`
- **Purpose**: Withdraw surplus collateral credited to msg.sender in CollSurplusPool as collateral remaining beyond liquidation penalty.
- **Authorization**: permissionless (only own surplus. Recipient is msg.sender).
- **Preconditions (Checks) / Behavior (Effects)**: BO performs no checks and only delegates to `collSurplusPool.claimColl(msg.sender)`. Balance checks, zero-balance reverts, and transfer are specified by CollSurplusPool (CORE-CSP series). **Executable after shutdown**.
- **Revert / early return**: follows CollSurplusPool specification.
- **Emitted events**: none (BO side).
- **Verification**: parity

#### CORE-BO-FR-025: `setAddManager` (Set AddManager) 🔵
- **Type**: Functional / **Source**: base implementation (Dependencies/AddRemoveManagers.sol)
- **Signature**: `setAddManager(uint256 _troveId, address _manager)`
- **Purpose**: Set the permitted address for deposit-side operations on a Trove (collateral addition and repayment).
- **Authorization**: owner only.
- **Preconditions (Checks)**: caller is owner (`troveNFT.ownerOf(_troveId)`) (**executable after shutdown, but only for Troves whose NFT exists = active / zombie**. For closed / liquidated Troves, NFT has been burned and `ownerOf` reverts. Zero address may also be set).
- **Behavior (Effects)**: `addManagerOf[_troveId] = _manager`; emit `AddManagerUpdated(_troveId, _manager)`.
- **Revert / early return**: non-owner → `NotBorrower`; NFT missing (closed / liquidated / unopened) → ERC721 `"ERC721: invalid token ID"` (inside `ownerOf`).
- **Design notes**: Semantics are special: **zero = anyone may perform deposit-side operations (default)**; nonzero = only owner + that address (+ RemoveManager). To reject all third-party deposit-side operations, set owner itself (intended operation in code comments).
- **Emitted events**: `AddManagerUpdated` (CORE-BO-EVT-008).
- **Verification**: parity

#### CORE-BO-FR-026: `setRemoveManagerWithReceiver` (Set RemoveManager and Receiver) 🔵
- **Type**: Functional / **Source**: base implementation (Dependencies/AddRemoveManagers.sol)
- **Signature**: `setRemoveManagerWithReceiver(uint256 _troveId, address _manager, address _receiver)` (public)
- **Purpose**: Set the permitted address for withdrawal-side operations from a Trove (collateral withdrawal, borrowing, and closing) and the recipient of withdrawn funds.
- **Authorization**: owner only.
- **Preconditions (Checks)**: caller is owner; if `_manager == 0`, `_receiver == 0` (disallow a state with no manager but receiver left over).
- **Behavior (Effects)**: `removeManagerReceiverOf[_troveId] = (_manager, _receiver)`; emit `RemoveManagerAndReceiverUpdated(_troveId, _manager, _receiver)`. Setting `(0,0)` removes the configuration (returns to default "only owner can perform withdrawal-side operations").
- **Revert / early return**: `NotBorrower`; `EmptyManager`.
- **Design notes**: The receiver is actually used **only when the RemoveManager itself calls and receiver is nonzero**. Owner calls always send to owner (fixed recipient limits fund destination to the receiver designated by the owner even if manager authority leaks). RemoveManager includes AddManager authority.
- **Emitted events**: `RemoveManagerAndReceiverUpdated` (CORE-BO-EVT-009).
- **Verification**: parity / SEC=CORE-BO-SEC-002

#### CORE-BO-FR-027: `setRemoveManager` (Set RemoveManager with Receiver = Owner) 🔵
- **Type**: Functional / **Source**: base implementation (Dependencies/AddRemoveManagers.sol)
- **Signature**: `setRemoveManager(uint256 _troveId, address _manager)`
- **Purpose**: Convenience variant that sets RemoveManager with receiver fixed to the current owner.
- **Authorization**: owner only.
- **Preconditions (Checks) / Behavior (Effects)**: Delegates to `setRemoveManagerWithReceiver(_troveId, _manager, troveNFT.ownerOf(_troveId))`. The receiver stores **the owner address at call time explicitly** (it does not automatically follow later NFT transfers).
- **Revert / early return**: `NotBorrower`; `_manager == 0` leaves receiver (=owner, nonzero), so it reverts with `EmptyManager`. **This function cannot remove the manager**; removal is only through FR-026 with `(0,0)`.
- **Emitted events**: `RemoveManagerAndReceiverUpdated` (CORE-BO-EVT-009).
- **Verification**: parity

#### CORE-BO-FR-028: View Function Group 🔵/🟡
- **Type**: Functional / **Source**: base implementation (BorrowerOperations.sol / AddRemoveManagers.sol / LiquityBase.sol) + CORE-MOD-013
- **Purpose**: Query branch parameters, delegation state, and batch registration state. No state changes.
- **Authorization**: none (view).

| Function | Meaning of return value |
| --- | --- |
| `CCR()` / `SCR()` / `MCR()` / `BCR()` | Stored branch-specific thresholds from AddressesRegistry; synchronized once on reserved-branch finalization and immutable afterward. Values are in [Parameters.md](../../../Parameters.md). |
| `hasBeenShutDown()` | true if shut down (irreversible) |
| `interestBatchManagerOf(troveId)` | Batch manager to which the Trove belongs (zero = not in batch) |
| `getInterestBatchManager(account)` | Batch manager registration record `(minInterestRate, maxInterestRate, minInterestRateChangePeriod)` (all zero if unregistered) |
| `getInterestIndividualDelegateOf(troveId)` | Individual delegate record `(account, minInterestRate, maxInterestRate, minInterestRateChangePeriod)` (all zero if unset) |
| `checkBatchManagerExists(account)` | `interestBatchManagers[account].maxInterestRate > 0` (registered check. Used by external references such as Zapper) |
| `addManagerOf(troveId)` | AddManager (zero = anyone may perform deposit-side operations) |
| `removeManagerReceiverOf(troveId)` | `(RemoveManager, receiver)` (zero = no withdrawal-side operations except owner) |
| `activePool()` | Branch ActivePool address (LiquityBase inheritance. LIB governs the specification) |
| `getEntireBranchColl()` | Total collateral in ActivePool + DefaultPool (LiquityBase inheritance. Numerator for TCR calculation) |
| `getEntireBranchDebt()` | Total debt in ActivePool + DefaultPool (LiquityBase inheritance. Denominator for TCR calculation) |

- **Verification**: parity

#### CORE-BO-FR-029: Constructor (Deployment-Time Wiring and Initialization) 🔵/🟡
- **Type**: Functional / **Source**: base implementation (BorrowerOperations.sol / AddRemoveManagers.sol / LiquityBase.sol) + CORE-MOD-013
- **Signature**: `constructor(IAddressesRegistry _addressesRegistry)`
- **Purpose**: Read the branch configuration from AddressesRegistry in one step, permanently fix the wiring, and initialize the local risk-parameter copies.
- **Authorization**: deployer (part of deployment procedure. Follows CORE-AR wiring specification).
- **Preconditions (Checks)**: `assert(MIN_DEBT > 0)` (structurally prevents opening zero-debt Troves. Holds for the 🟡 DF value as well (CORE-MOD-002 / [Parameters.md](../../../Parameters.md))).
- **Behavior (Effects)** (execution order including inherited constructors):
  1. (LiquityBase) Retrieve `activePool` / `defaultPool` / `priceFeed` and emit wiring events.
  2. (AddRemoveManagers) Retrieve `troveNFT` and emit `TroveNFTAddressChanged`.
  3. Store `addressesRegistry` immutably; retrieve `collToken` / `WETH` / `CCR` / `SCR` / `MCR` / `BCR` / `troveManager` / `gasPoolAddress` / `collSurplusPool` / `sortedTroves` / `jpydfToken`, and emit each AddressChanged event.
  4. `collToken.approve(address(activePool), type(uint256).max)` (infinite allowance so AP can pull collateral moved through BO).
- **Revert / early return**: none (except Panic on assert failure).
- **Emitted events**: CORE-BO-EVT-001-005, 007, 010-012 (all wiring events).
- **Design notes**: Wiring fields such as `troveManager` use storage rather than immutables but have no setter, so they are effectively immutable after construction. Risk parameters follow the one-shot lifecycle in CORE-BO-FR-030 (CORE-BO-INV-005).
- **Verification**: parity / deployment verification

#### CORE-BO-FR-030: `syncRiskParams` (One-Time Synchronization from AddressesRegistry) 🟡
- **Type**: Functional / Security / **Source**: CORE-MOD-013
- **Signature**: `syncRiskParams(uint256 _ccr, uint256 _mcr, uint256 _bcr, uint256 _scr)`
- **Purpose**: During reserved-branch finalization, synchronize the Registry-validated `CCR / MCR / BCR / SCR` into BO's stored copies.
- **Authorization**: only `msg.sender == address(addressesRegistry)`.
- **Behavior (Effects)**: Overwrite the corresponding BO storage values with the four values passed by the Registry from the same `finalizeRiskParams` calldata. Third parties cannot call this function, and the Registry has no repeatable call path.
- **Revert / early return**: caller is not the Registry → `CallerNotAddressesRegistry()`. A failure rolls back the entire Registry finalization (CORE-AR-FR-005).
- **Emitted events**: none; the Registry's `RiskParamsFinalized` event observes the complete finalized set.
- **Verification**: unit (caller restriction, four-value synchronization, and atomic rollback).


### TroveManager Functional Requirements (`CORE-TM-FR-*`)

#### CORE-TM-FR-001: `batchLiquidateTroves` (Liquidation Sequence) 🔵
- **Type**: Functional / **Source**: base implementation (TroveManager.sol)
- **Signature**: `batchLiquidateTroves(uint256[] memory _troveArray)`
- **Purpose**: Batch-liquidate the Troves in the caller-specified list that meet liquidation conditions (ICR < MCR), and finalize SP offset, redistribution, surplus collateral, and gas compensation.
- **Authorization**: permissionless (anyone may call; intended for liquidation keepers).
- **Preconditions (Checks)**:
  - `_troveArray.length > 0`.
  - Only individual Troves with `status ∈ {active, zombie}` are targets (others are skipped).
  - Only Troves satisfying `getCurrentICR(troveId, price) < MCR` are liquidated (others are skipped).
- **Behavior (Effects)**:
  1. Retrieve price with `priceFeed.fetchPrice()` (state-changing. PriceFeedProxy = [Oracle.md](Oracle.md)). If current source health returns `oracleFailure == true`, return before value-state mutation so the pause commits. Once normal pricing recovers, liquidation uses the live price even before Owner resume.
  2. Determine usable SP amount: `jpydfInSPForOffsets = totalJpydfDeposits - min(MIN_JPYDF_IN_SP, totalJpydfDeposits)`. In other words, always leave up to `MIN_JPYDF_IN_SP` (value in §7) in SP; if the SP has less than that, leave the full amount.
  3. Iterate `_troveArray` in order and execute single liquidation (CORE-TM-FR-002) for each target Trove. Decrement `remainingJpydfInSPForOffsets` by each Trove's `debtToOffset` while accumulating liquidation values and `TroveChange` (accumulated fields: `collGasCompensation`, fixed `ETH_GAS_COMPENSATION` per Trove, `debtDecrease += entireDebt`, `collDecrease += entireColl`, `appliedRedistJpydfDebtGain`, `oldWeightedRecordedDebt` / `newWeightedRecordedDebt`, `debtToOffset`, `collToSendToSP`, `debtToRedistribute`, `collToRedistribute`, `collSurplus`).
  4. Bulk-update aggregate debt and weighted debt with `activePool.mintAggInterestAndAccountForTroveChange(troveChange, address(0))` (CORE-AP section).
  5. If `totals.debtToOffset > 0 || totals.collToSendToSP > 0`, call `stabilityPool.offset(debtToOffset, collToSendToSP)`.
  6. Reflect redistribution portions with `_redistributeDebtAndColl` (CORE-TM-FR-003. no-op if 0).
  7. If `totals.collSurplus > 0`, call `activePool.sendColl(collSurplusPool, collSurplus)` to move surplus collateral to CollSurplusPool.
  8. Update system snapshots: `totalStakesSnapshot = totalStakes`, `totalCollateralSnapshot = AP balance - collGasCompensation + DP balance` (exclude gas compensation).
  9. Emit `Liquidation` event (CORE-TM-EVT-001).
  10. Pay gas compensation: transfer WETH `ETH_GAS_COMPENSATION × number of liquidated Troves` from GasPool to `msg.sender` via `transferFrom`, and send collateral gas compensation `collGasCompensation` from ActivePool to `msg.sender`.
- **Revert / early return**: empty array → `EmptyData`; current oracle failure → no-op return; no Trove liquidated → `NothingToLiquidate`.
- **Emitted events**: `Liquidation` (CORE-TM-EVT-001), `TroveUpdated` / `TroveOperation` per Trove (CORE-TM-EVT-003/004), and `BatchUpdated(exitBatch)` for batch-member Troves (CORE-TM-EVT-006).
- **Design notes**: Leaving `MIN_JPYDF_IN_SP` in SP protects SP internal precision (P value). Target selection is entirely the caller's responsibility; the contract assumes neither order nor sorting (LiquidationCandidateGetter = CORE-LCG section assists off-chain selection). Collateral gas compensation is deducted only from the portion targeted for SP offset (CORE-TM-FR-002), while WETH compensation is paid as a fixed amount per liquidation.
- **Verification**: parity / invariant=CORE-TM-INV-001, CORE-TM-INV-002

#### CORE-TM-FR-002: Single Trove Liquidation and Allocation of Liquidation Values (SP Offset / Redistribution / Gas Compensation / Surplus Collateral) 🔵
- **Type**: Functional / **Source**: base implementation (TroveManager.sol internal functions `_liquidate` / `_getOffsetAndRedistributionVals` / `_getCollPenaltyAndSurplus` / `_getCollGasCompensation`)
- **Signature**: internal (called for each Trove from `batchLiquidateTroves`)
- **Purpose**: Precisely split one Trove's entire debt and collateral (including redistribution gains and accrued interest) into SP offset, redistribution, gas compensation, and surplus collateral owed to the borrower, and close the Trove.
- **Authorization**: internal only.
- **Preconditions (Checks)**: caller (FR-001) has already checked status and ICR.
- **Behavior (Effects)**:
  1. Finalize entire values with `_getLatestTroveData`; if in a batch, also retrieve `_getLatestBatchData`.
  2. Move the Trove's pending redistribution gains (debt and collateral) from DefaultPool to ActivePool.
  3. **Allocation calculation** (`_getOffsetAndRedistributionVals(entireDebt, entireColl, jpydfInSPForOffsets, price)`). The result falls into three branches:
     - **Full SP offset** (`entireDebt ≤ jpydfInSPForOffsets`): `debtToOffset = entireDebt`, `collSPPortion = entireColl`, no redistribution.
     - **Partial offset + redistribution** (`0 < jpydfInSPForOffsets < entireDebt`): `debtToOffset = jpydfInSPForOffsets`, `collSPPortion = entireColl × debtToOffset / entireDebt` (collateral is prorated by offset debt ratio), and remaining `debtToRedistribute = entireDebt - debtToOffset` plus remaining collateral go to redistribution.
     - **Full redistribution** (`jpydfInSPForOffsets == 0`): no offset; all debt and all collateral go to redistribution. **In this case, collateral gas compensation is 0** (because compensation is deducted only from the SP-prorated portion).
  4. **Collateral gas compensation**: `collGasCompensation = min(collSPPortion / COLL_GAS_COMPENSATION_DIVISOR, COLL_GAS_COMPENSATION_CAP)`. The divisor corresponds to 0.5%. **The value of `COLL_GAS_COMPENSATION_CAP` is a DF change (🟡 CORE-MOD-003; value in [Parameters.md](../../../Parameters.md))**. The post-deduction `collToOffset = collSPPortion - collGasCompensation` goes to penalty calculation.
  5. **Penalty and surplus** (`_getCollPenaltyAndSurplus`): `maxSeizedColl = debt × (1e18 + penaltyRatio) / price`; seized collateral is `min(target collateral, maxSeizedColl)`, and the excess is `collSurplus`. Apply `LIQUIDATION_PENALTY_SP` to the SP portion and `LIQUIDATION_PENALTY_REDISTRIBUTION` to the redistribution portion (values in [Parameters.md](../../../Parameters.md)). In the redistribution stage, the input is "surplus produced by the offset stage + remaining collateral," so **surplus from offset can be consumed by the redistribution penalty**.
  6. Remove from the ledger with `_closeTrove(..., Status.closedByLiquidation)` (swap-and-pop from TroveIds, remove from SortedTroves, subtract stake from `totalStakes`, delete `Troves` / `rewardSnapshots` while leaving only status `closedByLiquidation`, burn TroveNFT. Shares internal rules with CORE-TM-FR-021).
  7. Account weighted debt deltas: for non-batch, `oldWeightedRecordedDebt = trove.weightedRecordedDebt`; for batch members, `old = batch.weightedRecordedDebt + (entireDebt - redistJpydfDebtGain) × batch.annualInterestRate`, `new = batch.entireDebtWithoutRedistribution × batch.annualInterestRate` (because the Trove portion is double-counted in batch recorded debt, one addition and two subtractions produce a net single deduction). Batch members also update weighted management-fee values and call `activePool.mintBatchManagementFeeAndAccountForChange`.
  8. If `collSurplus > 0`, record surplus for the **NFT owner** with `collSurplusPool.accountSurplus(owner, collSurplus)` (CORE-CSP section; the owner can claim later).
  9. Call `borrowerOperations.onLiquidateTrove(troveId)` to clear BO-side auxiliary state such as add/remove managers (CORE-BO section).
- **Revert / early return**: none (caller has already selected targets).
- **Emitted events**: `TroveUpdated` (all fields 0), `TroveOperation(liquidate)`, and `BatchUpdated(exitBatch)` if in a batch.
- **Design notes**: Returning penalty excess to the borrower (`collSurplus`) realizes the v2 design where liquidation is a penalty settlement rather than confiscation. `ownerOf` is retrieved before closing (after burn it would revert, so ordering is essential).
- **Verification**: parity / unit (3 branches, cap boundary, surplus consumption)

#### CORE-TM-FR-003: Redistribution Accounting (L_coll / L_jpydfDebt, Error Feedback, and Stake Rules) 🔵
- **Type**: Functional / **Source**: base implementation (TroveManager.sol internal functions `_redistributeDebtAndColl` / `_updateStakeAndTotalStakes` / `_computeNewStake` / `_updateSystemSnapshots_excludeCollRemainder`)
- **Signature**: internal
- **Purpose**: Define delayed distribution (lazy distribution) accounting that assigns liquidation debt and collateral not absorbed by SP to all active Troves in proportion to stake.
- **Authorization**: internal only.
- **Preconditions (Checks)**: if `_debtToRedistribute == 0`, return immediately (collateral is necessarily 0 as well).
- **Behavior (Effects)**:
  1. **Per-unit calculation with error feedback**: form `collNumerator = collToRedistribute × 1e18 + lastCollError_Redistribution` and `jpydfDebtNumerator = debtToRedistribute × 1e18 + lastJpydfDebtError_Redistribution`; calculate `perUnit = numerator / totalStakes` (floor division); store `lastError = numerator - perUnit × totalStakes`. Carrying the previous floor-division error into the next numerator keeps cumulative error below 1 wei per round.
  2. `L_coll += collRewardPerUnitStaked`, `L_jpydfDebt += jpydfDebtRewardPerUnitStaked` (monotonically nondecreasing).
  3. `defaultPool.increaseJpydfDebt(debtToRedistribute)`, `activePool.sendCollToDefaultPool(collToRedistribute)` — pending amounts are isolated in DefaultPool.
  4. **Attribution to Troves** is lazy: each Trove's unapplied gain is read as `stake × (L - rewardSnapshots[troveId]) / 1e18` (CORE-TM-FR-009) and finalized by advancing `rewardSnapshots` to current values during state updates.
  5. **Stake rule**: a Trove's stake is `coll` itself if `totalCollateralSnapshot == 0`; otherwise `coll × totalStakesSnapshot / totalCollateralSnapshot`. Both snapshots are updated only immediately after liquidation (FR-001 step 8), discounting future stakes by collateral lost in liquidation.
- **Revert / early return**: only the 0 early return above.
- **Emitted events**: none (`Liquidation` event carries updated `L_coll` / `L_jpydfDebt`).
- **Design notes**: Redistribution gain allocation is stake-proportional (roughly collateral-proportional), not debt-proportional. `stake` / `totalStakes` / `L_coll` / `L_jpydfDebt` are **branch-local** state in the TroveManager for that collateral branch; they are not shared across collateral branches, price-normalized across branches, or used for cross-branch redistribution. Batch-member Troves also hold individual stakes, so redistribution is attributed to individual Troves without going through batch accounting (corresponding to the proration rule in FR-009).
- **Verification**: parity / invariant=CORE-TM-INV-002, CORE-TM-INV-006

#### CORE-TM-FR-004: `redeemCollateral` (Normal Redemption) 🔵
- **Type**: Functional / **Source**: base implementation (TroveManager.sol, internal `_redeemCollateralFromTrove` / `_applySingleRedemption` / `_updateBatchInterestPriorToRedemption`)
- **Signature**: `redeemCollateral(address _redeemer, uint256 _jpydfAmount, uint256 _price, uint256 _redemptionRate, uint256 _maxIterations) → uint256 _redeemedAmount`
- **Purpose**: Called by CollateralRegistry to redeem collateral equivalent to `_jpydfAmount` JPYdf from Troves in ascending interest-rate order. This is the arbitrage path for downward peg deviation.
- **Authorization**: CollateralRegistry only (`_requireCallerIsCollateralRegistry`). Fee rate `_redemptionRate` and cross-branch allocation have already been determined by CollateralRegistry (CORE-CR section).
- **Preconditions (Checks)**:
  - `msg.sender == collateralRegistry`.
  - Per-Trove eligibility: skip Troves where `getCurrentICR(troveId, _price) < 100%` (`_100pct`) (so redemption does not further worsen that Trove's CR). ICR uses normal price `_price`.
- **Behavior (Effects)**:
  1. Determine scan start: if `lastZombieTroveId != 0`, start **exceptionally from that zombie Trove** (prioritize consuming leftover from previous Redemption). Otherwise start at `sortedTroves.getLast()` (= lowest-interest Trove).
  2. Retrieve redemption price with `priceFeed.fetchRedemptionPrice()` (separate from normal price; [Oracle.md](Oracle.md)). If it returns `oracleFailure == true`, return 0 before value-state mutation.
  3. Treat `_maxIterations == 0` as unlimited. Loop while `troveId != 0 && remainingJpydf > 0 && _maxIterations > 0`:
     a. Save the next candidate first (when starting from zombie, `getLast()`; otherwise `getPrev(troveId)` = next in ascending interest-rate order).
     b. Skip if ICR < 100%.
     c. If the Trove is in a batch, execute `_updateBatchInterestPriorToRedemption` once per same batch (finalize batch recorded debt including interest, update `lastDebtUpdateTime`, and update ActivePool weighted debt and management fee).
     d. **Lot calculation**: `jpydfLot = min(remainingJpydf, entireDebt)`, `correspondingColl = jpydfLot × 1e18 / redemptionPrice`, `collFee = correspondingColl × _redemptionRate / 1e18`, `collLot = correspondingColl - collFee`. **The redemption fee is not sent to the redeemer; it remains as collateral in the Trove** (the fee improves that Trove's CR).
     e. **Apply single redemption** (`_applySingleRedemption`): `newDebt = entireDebt - jpydfLot`, `newColl = entireColl - collLot`. For non-batch Troves, directly update `Troves` debt/coll/`lastDebtUpdateTime` and account weighted debt delta (`old = trove.weightedRecordedDebt`, `new = newDebt × annualInterestRate`). For batch members, retrieve batch data again and account weighted debt and management fee using `newAmountForWeightedDebt = batch.entireDebtWithoutRedistribution + redistJpydfDebtGain - jpydfLot`; after `mintBatchManagementFeeAndAccountForChange`, execute `_updateBatchShares` with **`_checkBatchSharesRatio = false`** (prevents `BatchSharesRatioTooHigh` from blocking Redemption). Then update stake, move pending redistribution gains to AP, and update `rewardSnapshots`.
     f. **Zombie transition**: if `newDebt < MIN_DEBT` (value in [Parameters.md](../../../Parameters.md); raised by DF in 🟡 CORE-MOD-002), then if not already zombie, set `status = zombie` and remove from SortedTroves (if batch member, `removeFromBatch`). If `newDebt > 0`, set `lastZombieTroveId = troveId` (highest priority next time). If already zombie and `newDebt == 0`, reset pointer to 0.
     g. After updating totals, move to the next candidate (`isZombieTrove` flag only on first iteration).
  4. Emit `Redemption` event (CORE-TM-EVT-002).
  5. Update aggregation with `activePool.mintAggInterestAndAccountForTroveChange(totalsTroveChange, address(0))`.
  6. Send collateral (dToken, [dToken.md](dToken.md)) to redeemer with `activePool.sendColl(_redeemer, total collLot)`.
  7. Return actual redeemed amount `totalsTroveChange.debtDecrease`. **JPYdf is not burned here** (CollateralRegistry performs a single cross-branch burn).
- **Revert / early return**: invalid caller → `CallerNotCollateralRegistry`; current oracle failure → return 0; no revert if 0 redemptions occur.
- **Emitted events**: per Trove: `TroveUpdated` or `BatchedTroveUpdated`, `TroveOperation(redeemCollateral)`, `BatchUpdated(troveChange)` if in a batch, and `RedemptionFeePaidToTrove` (CORE-TM-EVT-005). Finally `Redemption`.
- **Design notes**: Scanning is ascending interest rate over SortedTroves (from list tail = lowest rate, then `getPrev` upward), not collateral-ratio order. This is the core of v2's rate design: lower-interest Troves bear higher redemption risk. The zombie mechanism prevents gas griefing from tiny Troves below `MIN_DEBT` left in the queue during sequential Redemption; zombies are removed from the list and do not appear in normal walks. If redistribution later restores a zombie's debt to at least `MIN_DEBT`, it is not automatically reactivated (reinsertion hints are needed). It returns through BO's `adjustZombieTrove` or permissionless `applyPendingDebt` (CORE-BO-FR-008/010) → CORE-TM-FR-016.
- **Verification**: parity / unit (zombie transition, fee left in Trove, batch path) / invariant=CORE-TM-INV-005

#### CORE-TM-FR-005: `urgentRedemption` (Emergency Redemption After Shutdown) 🔵
- **Type**: Functional / **Source**: base implementation (TroveManager.sol, internal `_urgentRedeemCollateralFromTrove`)
- **Signature**: `urgentRedemption(uint256 _jpydfAmount, uint256[] calldata _troveIds, uint256 _minCollateral)`
- **Purpose**: After branch shutdown, quickly unwind debt in that branch through bonus-bearing, order-free Redemption.
- **Authorization**: permissionless (only for a shut-down branch). Caller burns their own JPYdf and receives collateral.
- **Preconditions (Checks)**:
  - `shutdownTime != 0` (not shut down → `NotShutDown`).
  - `_jpydfAmount > 0` (→ `ZeroAmount`).
  - `jpydfToken.balanceOf(msg.sender) ≥ _jpydfAmount` (→ `NotEnoughJpydfBalance`).
  - Per Trove: only process Troves with `status ∈ {active, zombie}` and `entireDebt > 0` (skip others). **No ICR lower-bound check** (redemption is allowed even if CR < 100%).
- **Behavior (Effects)**:
  1. `priceFeed.fetchPrice()` (normal price. After shutdown, redemption price is not used because small arbitrage is allowed).
  2. Process caller-specified `_troveIds` **in specified order** (no sorting assumed). Stop when `remainingJpydf == 0`. For batch-member Troves, always run `_updateBatchInterestPriorToRedemption` each time (no per-batch deduplication because ordering is not guaranteed).
  3. **Lot calculation (with bonus)**: `jpydfLot = min(remainingJpydf, entireDebt)`, `collLot = jpydfLot × (1e18 + URGENT_REDEMPTION_BONUS) / price` (value of `URGENT_REDEMPTION_BONUS` in [Parameters.md](../../../Parameters.md)). If `collLot > entireColl`, truncate to all collateral and back-calculate `jpydfLot = entireColl × price / (1e18 + URGENT_REDEMPTION_BONUS)` (handles Troves with CR below 100% including bonus).
  4. Apply `_applySingleRedemption` (same rules and events as FR-004 step e). **Do not zombie** (order-free mode is not vulnerable to tiny-Trove griefing).
  5. Revert if total received collateral is below `_minCollateral` (slippage protection).
  6. Emit `Redemption(_jpydfAmount, debtDecrease, collDecrease, 0, price, price)` (fee is always 0, and redemptionPrice field also uses normal price).
  7. `activePool.mintAggInterestAndAccountForTroveChange(totalsTroveChange, address(0))` (after shutdown, interest mint is 0; only aggregate debt and weighted debt trackers update).
  8. Send collateral with `activePool.sendColl(msg.sender, collDecrease)` and **TroveManager itself burns JPYdf** with `jpydfToken.burn(msg.sender, debtDecrease)` (different from normal Redemption).
- **Revert / early return**: `NotShutDown` / `ZeroAmount` / `NotEnoughJpydfBalance` / `MinCollNotReached(uint256 actual received collateral)`.
- **Emitted events**: same per-Trove group as FR-004 (`TroveOperation` is `redeemCollateral`), then `Redemption`.
- **Design notes**: The bonus (premium) incentivizes early exit from a shut-down branch. The balance precheck (`NotEnoughJpydfBalance`) returns a clearer error than a burn failure. To preserve liveness after irreversible shutdown, urgent redemption does not use the dwstETH `max(stETH/USD, ETH/USD)` protection in `fetchRedemptionPrice()`. A bounded residual therefore remains if stETH/USD lags within its freshness window while ETH/USD rallies after a branch is already shut down. The BOLD-style oracle-lag protection for normal redemption remains mandatory under CORE-TM-FR-004 / ORCL-FR-015.
- **Verification**: parity / unit (collateral truncation branch, `_minCollateral` boundary)

#### CORE-TM-FR-006: `shutdown` (Record Branch Shutdown) 🔵
- **Type**: Functional / **Source**: base implementation (TroveManager.sol)
- **Signature**: `shutdown()`
- **Purpose**: Record branch shutdown timestamp and propagate the shutdown flag to ActivePool. Thereafter, interest generation is frozen at `shutdownTime` (CORE-TM-FR-007), `urgentRedemption` is enabled, and the branch is excluded from normal Redemption (CORE-TM-FR-012).
- **Authorization**: BorrowerOperations only (`_requireCallerIsBorrowerOperations`). Shutdown determination (TCR < SCR) and one-shot guarantee are BO responsibilities (CORE-BO section).
- **Preconditions (Checks)**: only `msg.sender == borrowerOperations`. **TroveManager itself does not check `shutdownTime == 0`** (multiple-call prevention relies on BO require).
- **Behavior (Effects)**:
  1. `shutdownTime = block.timestamp`.
  2. `activePool.setShutdownFlag()` (CORE-AP section. Interest aggregation stop flag).
- **Revert / early return**: invalid caller → `CallerNotBorrowerOperations`.
- **Emitted events**: none from TroveManager. Observed through BO-side event.
- **Verification**: parity / unit (onlyBO)

#### CORE-TM-FR-007: Interest Accrual Period Determination (Freeze on Shutdown) 🔵
- **Type**: Functional / **Source**: base implementation (TroveManager.sol internal function `_getInterestPeriod`)
- **Signature**: internal (used from `_getLatestTroveData` / `_getLatestBatchData`)
- **Purpose**: Define the accrual period for Trove / Batch accrued interest (and batch management fee), freezing interest after shutdown.
- **Authorization**: internal only.
- **Preconditions (Checks)**: none.
- **Behavior (Effects)**: The period has three branches:
  1. `shutdownTime == 0` (live): `block.timestamp - lastDebtUpdateTime`.
  2. `shutdownTime > 0` and `lastDebtUpdateTime < shutdownTime`: `shutdownTime - lastDebtUpdateTime` (interest only until shutdown).
  3. `shutdownTime > 0` and `lastDebtUpdateTime ≥ shutdownTime`: `0` (no interest after updates at or after shutdown).
  Interest amount is `weightedRecordedDebt × period / ONE_YEAR / 1e18` (LiquityBase `_calcInterest`; simple interest).
- **Revert / early return**: none.
- **Emitted events**: none.
- **Verification**: parity / unit (3 branches)

#### CORE-TM-FR-008: `getCurrentICR` (Calculate Current ICR) 🔵
- **Type**: Functional / **Source**: base implementation (TroveManager.sol)
- **Signature**: `getCurrentICR(uint256 _troveId, uint256 _price) → uint256` (public view)
- **Purpose**: Return a Trove's collateral ratio using entire values that include all unapplied redistribution gains, accrued interest, and batch management fee. This is the reference value for liquidation checks (FR-001) and Redemption eligibility checks (FR-004).
- **Authorization**: none (view).
- **Preconditions (Checks)**: none.
- **Behavior (Effects)**: Return `LiquityMath._computeCR(coll, debt, price)` using `entireColl` / `entireDebt` from `_getLatestTroveData` (`type(uint256).max` when `debt == 0`).
- **Revert / early return**: none.
- **Emitted events**: none.
- **Verification**: parity

#### CORE-TM-FR-009: `getLatestTroveData` (Derive Latest Trove State) 🔵
- **Type**: Functional / **Source**: base implementation (TroveManager.sol, internal `_getLatestTroveData` / `_getLatestTroveDataFromBatch`)
- **Signature**: `getLatestTroveData(uint256 _troveId) → LatestTroveData` (external view)
- **Purpose**: Return the "Trove state if settled now" by composing recorded values (`Troves`) with unapplied redistribution gains, accrued interest, and batch management fee. Baseline view for BO, HintHelpers, and peripheral layers.
- **Authorization**: none (view).
- **Preconditions (Checks)**: none (nonexistent Trove returns zero values).
- **Behavior (Effects)**:
  1. **Redistribution gain** (common to batch and non-batch): `redistJpydfDebtGain = stake × (L_jpydfDebt - rewardSnapshots.jpydfDebt) / 1e18`, `redistCollGain = stake × (L_coll - rewardSnapshots.coll) / 1e18`.
  2. **Non-batch**: `recordedDebt = Troves.debt`, `weightedRecordedDebt = recordedDebt × annualInterestRate`, `accruedInterest = _calcInterest(weighted, period)` (period from CORE-TM-FR-007). `entireDebt = recordedDebt + redistJpydfDebtGain + accruedInterest`, `entireColl = Troves.coll + redistCollGain`.
  3. **Batch member**: retrieve latest batch value (FR-010), and if `totalDebtShares > 0`, prorate `recordedDebt` / `accruedInterest` / `accruedBatchManagementFee` by **batchDebtShares ratio**. `annualInterestRate` is batch rate. `entireDebt = recordedDebt + redistJpydfDebtGain + accruedInterest + accruedBatchManagementFee`, `entireColl = Troves.coll + redistCollGain` (**redistribution gain is based on individual Trove stake, not shares proration**, because distribution is collateral-proportional). `lastInterestRateAdjTime = max(batch-side, Trove-side)`.
- **Return value (`LatestTroveData` struct)**:

  | Field | Meaning |
  | --- | --- |
  | `entireDebt` | Recorded debt + redistribution debt gain + accrued interest (+ batch management fee) |
  | `entireColl` | Recorded collateral + redistribution collateral gain |
  | `redistJpydfDebtGain` / `redistCollGain` | Unapplied redistribution gains |
  | `accruedInterest` | Accrued simple interest |
  | `recordedDebt` | Recorded debt (shares-prorated value for batch) |
  | `annualInterestRate` | Effective annual interest rate (batch rate for batch members) |
  | `weightedRecordedDebt` | `recordedDebt × annualInterestRate` (weight for aggregate interest) |
  | `accruedBatchManagementFee` | Accrued batch management fee (0 for non-batch) |
  | `lastInterestRateAdjTime` | Most recent interest-rate adjustment time (for batch, larger of Trove and batch values) |
- **Revert / early return**: none.
- **Emitted events**: none.
- **Verification**: parity / unit (batch proration and individual attribution of redistribution)

#### CORE-TM-FR-010: `getLatestBatchData` (Derive Latest Batch State) 🔵
- **Type**: Functional / **Source**: base implementation (TroveManager.sol, internal `_getLatestBatchData`)
- **Signature**: `getLatestBatchData(address _batchAddress) → LatestBatchData` (external view)
- **Purpose**: Return latest batch state by composing recorded batch values with accrued interest and accrued management fee.
- **Authorization**: none (view).
- **Preconditions (Checks)**: none (unregistered batch returns zero values).
- **Behavior (Effects)**: `recordedDebt = batches.debt`, `weightedRecordedDebt = recordedDebt × annualInterestRate`, `accruedInterest = _calcInterest(weighted, period)`, `weightedRecordedBatchManagementFee = recordedDebt × annualManagementFee`, `accruedManagementFee = _calcInterest(same, period)` (period follows CORE-TM-FR-007 from batch `lastDebtUpdateTime`). `entireDebtWithoutRedistribution = recordedDebt + accruedInterest + accruedManagementFee`, `entireCollWithoutRedistribution = batches.coll`.
- **Return value (`LatestBatchData` struct)**: `totalDebtShares` / `entireDebtWithoutRedistribution` / `entireCollWithoutRedistribution` / `accruedInterest` / `recordedDebt` / `annualInterestRate` / `weightedRecordedDebt` / `annualManagementFee` / `accruedManagementFee` / `weightedRecordedBatchManagementFee` / `lastDebtUpdateTime` / `lastInterestRateAdjTime`. **Redistribution gains are not included** (as "WithoutRedistribution" indicates. Redistribution is attributed to individual Troves and does not appear in batch aggregation).
- **Revert / early return**: none.
- **Emitted events**: none.
- **Verification**: parity

#### CORE-TM-FR-011: `getTroveAnnualInterestRate` (Resolve Effective Annual Interest Rate) 🔵
- **Type**: Functional / **Source**: base implementation (TroveManager.sol)
- **Signature**: `getTroveAnnualInterestRate(uint256 _troveId) → uint256` (external view)
- **Purpose**: Return batch rate if the Trove belongs to a batch; otherwise return the individual Trove rate (because the individual rate field is 0 while in a batch, this view is the canonical source for effective rate rather than the raw field).
- **Authorization**: none (view).
- **Behavior (Effects)**: if `interestBatchManager != address(0)`, return `batches[batch].annualInterestRate`; otherwise return `Troves[_troveId].annualInterestRate`.
- **Revert / early return**: none.
- **Emitted events**: none.
- **Verification**: parity

#### CORE-TM-FR-012: `getUnbackedPortionPriceAndRedeemability` (Unbacked Debt and Redeemability) 🔵
- **Type**: Functional / **Source**: base implementation (TroveManager.sol)
- **Signature**: `getUnbackedPortionPriceAndRedeemability() → (uint256 unbackedPortion, uint256 price, bool redeemable)`
- **Purpose**: Return the inputs used by CollateralRegistry to allocate Redemption amount across branches: debt not backed by SP, current price, and whether the branch is a redemption target.
- **Authorization**: permissionless. **Not view** (nonpayable because `priceFeed.fetchPrice()` is state-changing).
- **Preconditions (Checks)**: none.
- **Behavior (Effects)**:
  1. `unbackedPortion = max(getEntireBranchDebt() - SP.getTotalJpydfDeposits(), 0)`.
  2. `price = fetchPrice()` ([Oracle.md](Oracle.md)).
  3. `redeemable = no current oracle failure and !isOracleFailureShutdown and (TCR ≥ SCR) and (shutdownTime == 0)`. TCR uses the normal price. Branches that fail any condition are excluded from normal Redemption allocation.
- **Revert / early return**: none (fetchPrice failures propagate as-is).
- **Emitted events**: none (PriceFeed-side events are separate).
- **Design notes**: Excluding branches below SCR (or already shut down) from redemption targets confines collateral outflow from crisis branches to the urgentRedemption path (FR-005).
- **Verification**: parity / unit (redeemable boundary)

#### CORE-TM-FR-013: Self-Evident View Getter Group 🔵/🟡
- **Type**: Functional / **Source**: base implementation (TroveManager.sol / LiquityBase.sol) + CORE-MOD-013
- **Signature**: table below (all view)
- **Purpose**: Plain reads of state variables and connected addresses.
- **Authorization**: none.
- **Behavior (Effects)**:

  | Function | Meaning of return value |
  | --- | --- |
  | `CCR()` | Stored branch CCR; synchronized once during reserved-branch finalization and immutable afterward. Value is in [Parameters.md](../../../Parameters.md). |
  | `Troves(uint256)` | 10 raw fields of the Trove struct (**pending interest and redistribution not reflected**. Effective values are FR-009) |
  | `rewardSnapshots(uint256)` | `(coll, jpydfDebt)` = L-value snapshot for that Trove |
  | `batchIds(uint256)` | Registered batch manager address (registration order; no deletion) |
  | `lastZombieTroveId()` | Partially redeemed zombie pointer (0 = none) |
  | `shutdownTime()` | Shutdown timestamp (0 = live) |
  | `getTroveIdsCount()` | `TroveIds.length` (active + zombie count) |
  | `getTroveFromTroveIdsArray(uint256)` | `TroveIds[i]` (out-of-range reverts. For off-chain hint calculation) |
  | `getTroveStatus(uint256)` | `Status` (uint8. 0 nonExistent / 1 active / 2 closedByOwner / 3 closedByLiquidation / 4 zombie) |
  | `troveNFT()` / `borrowerOperations()` / `stabilityPool()` / `sortedTroves()` / `activePool()` | Connected addresses (fixed in constructor) |
  | `getEntireBranchColl()` | Sum of collateral balances in ActivePool + DefaultPool (LiquityBase inheritance) |
  | `getEntireBranchDebt()` | Sum of JPYdf debt in ActivePool + DefaultPool (LiquityBase inheritance) |
- **Revert / early return**: only out-of-range array getter access.
- **Emitted events**: none.
- **Verification**: parity

#### CORE-TM-FR-014: `onOpenTrove` (Record Trove Opening) 🔵
- **Type**: Functional / **Source**: base implementation (TroveManager.sol)
- **Signature**: `onOpenTrove(address _owner, uint256 _troveId, TroveChange memory _troveChange, uint256 _annualInterestRate)`
- **Purpose**: Record an opening that BO has already validated (validation, fund movement, and insertion into SortedTroves are on the BO side. CORE-BO section).
- **Authorization**: BorrowerOperations only.
- **Preconditions (Checks)**: only `msg.sender == borrowerOperations` (input validation is trusted to BO).
- **Behavior (Effects)**:
  1. `stake = _computeNewStake(collIncrease)` (rule in CORE-TM-FR-003).
  2. Set `Troves[_troveId]`: `debt = debtIncrease + upfrontFee`, `coll = collIncrease`, `stake`, `status = active`, `arrayIndex = TroveIds.length`, `lastDebtUpdateTime = lastInterestRateAdjTime = block.timestamp`, `annualInterestRate = _annualInterestRate`.
  3. `TroveIds.push`, `totalStakes += stake`.
  4. `troveNFT.mint(_owner, _troveId)` (CORE-TN section).
  5. Set `rewardSnapshots` to current L values.
- **Revert / early return**: `CallerNotBorrowerOperations`.
- **Emitted events**: `TroveUpdated`, `TroveOperation(openTrove)` (upfrontFee is separately reported in `_debtIncreaseFromUpfrontFee`).
- **Design notes**: BO performs insertion into SortedTroves (TM records only the ledger). Upfront fee is included in recorded debt.
- **Verification**: parity

#### CORE-TM-FR-015: `onOpenTroveAndJoinBatch` (Open with Batch Join) 🔵
- **Type**: Functional / **Source**: base implementation (TroveManager.sol)
- **Signature**: `onOpenTroveAndJoinBatch(address _owner, uint256 _troveId, TroveChange memory _troveChange, address _batchAddress, uint256 _batchColl, uint256 _batchDebt)`
- **Purpose**: Record a Trove that joins a batch at opening. Debt is not recorded directly on the Trove; it is held as batch shares.
- **Authorization**: BorrowerOperations only.
- **Preconditions (Checks)**: `msg.sender == borrowerOperations`. Internal `assert(_troveChange.debtIncrease > 0)`.
- **Behavior (Effects)**:
  1. `Troves[_troveId]`: `coll = collIncrease`, `stake`, `status = active`, `arrayIndex`, `interestBatchManager = _batchAddress`, `lastInterestRateAdjTime = block.timestamp` (**`debt` and `lastDebtUpdateTime` are not set**; managed on the batch side).
  2. Set `rewardSnapshots`, `TroveIds.push`.
  3. Issue shares and update batch debt/collateral with `_updateBatchShares(..., _checkBatchSharesRatio = true)` (CORE-TM-FR-027).
  4. `totalStakes += stake`, `troveNFT.mint`.
- **Revert / early return**: `CallerNotBorrowerOperations` / shares ratio exceeded → `BatchSharesRatioTooHigh` (FR-027).
- **Emitted events**: `BatchedTroveUpdated`, `TroveOperation(openTroveAndJoinBatch)`, `BatchUpdated(joinBatch)` (the joining Trove's upfront fee is an individual fee, so `_debtIncreaseFromUpfrontFee = 0`).
- **Verification**: parity

#### CORE-TM-FR-016: `setTroveStatusToActive` (Return from Zombie) 🔵
- **Type**: Functional / **Source**: base implementation (TroveManager.sol)
- **Signature**: `setTroveStatusToActive(uint256 _troveId)`
- **Purpose**: Called from BO's `adjustZombieTrove` (operation that restores debt to at least `MIN_DEBT` and reinserts into SortedTroves) and `applyPendingDebt` (permissionless path that returns a zombie whose `entireDebt ≥ MIN_DEBT` due to redistribution etc.; CORE-BO-FR-010) to set status back to active.
- **Authorization**: BorrowerOperations only.
- **Preconditions (Checks)**: `msg.sender == borrowerOperations` (BO verifies zombie status).
- **Behavior (Effects)**: `status = active`. If `lastZombieTroveId == _troveId`, reset the pointer to 0.
- **Revert / early return**: `CallerNotBorrowerOperations`.
- **Emitted events**: none (observed through BO-side operation event).
- **Verification**: parity

#### CORE-TM-FR-017: `onAdjustTrove` (Record Trove Adjustment) 🔵
- **Type**: Functional / **Source**: base implementation (TroveManager.sol)
- **Signature**: `onAdjustTrove(uint256 _troveId, uint256 _newColl, uint256 _newDebt, TroveChange calldata _troveChange)`
- **Purpose**: Record collateral/debt adjustment for a non-batch Trove (settled values after applying redistribution gains and interest).
- **Authorization**: BorrowerOperations only.
- **Preconditions (Checks)**: `msg.sender == borrowerOperations`.
- **Behavior (Effects)**:
  1. Update `coll = _newColl`, `debt = _newDebt`, `lastDebtUpdateTime = block.timestamp`.
  2. Move pending redistribution gains (`appliedRedist*`) from DefaultPool to ActivePool.
  3. Recalculate stake (`_updateStakeAndTotalStakes`) and update `rewardSnapshots`.
- **Revert / early return**: `CallerNotBorrowerOperations`.
- **Emitted events**: `TroveUpdated`, `TroveOperation(adjustTrove)`.
- **Verification**: parity

#### CORE-TM-FR-018: `onAdjustTroveInterestRate` (Record Individual Interest-Rate Change) 🔵
- **Type**: Functional / **Source**: base implementation (TroveManager.sol)
- **Signature**: `onAdjustTroveInterestRate(uint256 _troveId, uint256 _newColl, uint256 _newDebt, uint256 _newAnnualInterestRate, TroveChange calldata _troveChange)`
- **Purpose**: Record annual-interest change for a non-batch Trove (settled values after interest and redistribution, plus new rate).
- **Authorization**: BorrowerOperations only.
- **Preconditions (Checks)**: `msg.sender == borrowerOperations`.
- **Behavior (Effects)**:
  1. Update `coll` / `debt` / `annualInterestRate`, `lastDebtUpdateTime = lastInterestRateAdjTime = block.timestamp`.
  2. Move pending redistribution gains to AP and update `rewardSnapshots` (**do not recalculate stake** because the BO-side operation has no collateral change).
- **Revert / early return**: `CallerNotBorrowerOperations`.
- **Emitted events**: `TroveUpdated`, `TroveOperation(adjustTroveInterestRate)` (`_debtChangeFromOperation` / `_collChangeFromOperation` are 0; upfront fee is `_debtIncreaseFromUpfrontFee`).
- **Verification**: parity

#### CORE-TM-FR-019: `onAdjustTroveInsideBatch` (Record Trove Adjustment Inside Batch) 🔵
- **Type**: Functional / **Source**: base implementation (TroveManager.sol)
- **Signature**: `onAdjustTroveInsideBatch(uint256 _troveId, uint256 _newTroveColl, uint256 _newTroveDebt, TroveChange memory _troveChange, address _batchAddress, uint256 _newBatchColl, uint256 _newBatchDebt)`
- **Purpose**: Record a batch-member Trove collateral/debt adjustment on both the Trove collateral side and batch-share side. `_newBatchColl` / `_newBatchDebt` are whole-batch values before the Trove change (after applying interest and management fee).
- **Authorization**: BorrowerOperations only.
- **Preconditions (Checks)**: `msg.sender == borrowerOperations`. Internal `assert(_newTroveDebt > 0)`.
- **Behavior (Effects)**:
  1. Set `Troves.coll = _newTroveColl`, update `rewardSnapshots`, and recalculate stake.
  2. Update shares and batch debt/collateral with `_updateBatchShares(..., true)` (FR-027).
  3. Move pending redistribution gains to AP.
- **Revert / early return**: `CallerNotBorrowerOperations` / `BatchSharesRatioTooHigh`.
- **Emitted events**: `BatchedTroveUpdated`, `TroveOperation(adjustTrove)` (interest rate is batch rate), `BatchUpdated(troveChange)`.
- **Verification**: parity

#### CORE-TM-FR-020: `onApplyTroveInterest` (Record Interest and Redistribution Application) 🔵
- **Type**: Functional / **Source**: base implementation (TroveManager.sol)
- **Signature**: `onApplyTroveInterest(uint256 _troveId, uint256 _newTroveColl, uint256 _newTroveDebt, address _batchAddress, uint256 _newBatchColl, uint256 _newBatchDebt, TroveChange calldata _troveChange)`
- **Purpose**: State recording for BO's `applyPendingDebt` (permissionless operation that finalizes interest and redistribution). Also used when restoring zombie debt.
- **Authorization**: BorrowerOperations only.
- **Preconditions (Checks)**: `msg.sender == borrowerOperations`. In batch path, internal `assert(_newTroveDebt > 0)`.
- **Behavior (Effects)**:
  1. `Troves.coll = _newTroveColl`.
  2. Batch member: `_updateBatchShares(..., true)`, `BatchUpdated(applyBatchInterestAndFee)` (event debt/coll are whole-batch values from arguments). Non-batch: `Troves.debt = _newTroveDebt`, `lastDebtUpdateTime = block.timestamp`.
  3. Move pending redistribution gains to AP and update `rewardSnapshots`.
- **Revert / early return**: `CallerNotBorrowerOperations` / `BatchSharesRatioTooHigh`.
- **Emitted events**: (batch) `BatchUpdated(applyBatchInterestAndFee)`, `TroveUpdated`, `TroveOperation(applyPendingDebt)`.
- **Verification**: parity

#### CORE-TM-FR-021: `onCloseTrove` (Record Trove Close) 🔵
- **Type**: Functional / **Source**: base implementation (TroveManager.sol, internal `_closeTrove` / `_removeTroveId`)
- **Signature**: `onCloseTrove(uint256 _troveId, TroveChange memory _troveChange, address _batchAddress, uint256 _newBatchColl, uint256 _newBatchDebt)`
- **Purpose**: Remove borrower-closed Trove (debt fully repaid) from the ledger.
- **Authorization**: BorrowerOperations only.
- **Preconditions (Checks)**:
  - `msg.sender == borrowerOperations`.
  - If "branch not shut down or close by liquidation," the last remaining Trove cannot be closed (`TroveIds.length == 1` → `OnlyOneTroveLeft`). **After shutdown, owner close is allowed even for the last Trove**.
- **Behavior (Effects)** (`_closeTrove(..., Status.closedByOwner)`):
  1. Remove from `TroveIds` by swap-and-pop (reassign `arrayIndex` of the moved tail Trove).
  2. Batch member: if active, `sortedTroves.removeFromBatch`; if zombie and pointer matches, `lastZombieTroveId = 0`; subtract from batch via `_removeTroveSharesFromBatch` (`batchDebtDecrease = newTroveDebt - upfrontFee - appliedRedistJpydfDebtGain`, `batchCollDecrease = newTroveColl - appliedRedistCollGain` subtracted from the batch-wide values in arguments, fully clear Trove shares and set `interestBatchManager = 0`). Non-batch: if active, `sortedTroves.remove`; if zombie pointer matches, reset it.
  3. `totalStakes -= stake`.
  4. `delete Troves[_troveId]`, then restore only `status = closedByOwner`; `delete rewardSnapshots[_troveId]`.
  5. `troveNFT.burn(_troveId)`.
  6. Move pending redistribution gains to AP.
- **Revert / early return**: `CallerNotBorrowerOperations` / `OnlyOneTroveLeft`.
- **Emitted events**: `TroveUpdated` (all 0), `TroveOperation(closeTrove)`, and `BatchUpdated(exitBatch)` if in a batch.
- **Design notes**: The "last Trove" constraint keeps a redistribution receiver set (`totalStakes > 0`) at all times. After close, only `status` remains, used to prevent TroveNFT reminting and distinguish history.
- **Verification**: parity / invariant=CORE-TM-INV-001, CORE-TM-INV-003

#### CORE-TM-FR-022: `onRegisterBatchManager` (Register Batch Manager) 🔵
- **Type**: Functional / **Source**: base implementation (TroveManager.sol)
- **Signature**: `onRegisterBatchManager(address _account, uint256 _annualInterestRate, uint256 _annualManagementFee)`
- **Purpose**: Record a batch manager registration already validated by BO (interest rate, management fee, and rate range are checked on BO side).
- **Authorization**: BorrowerOperations only.
- **Preconditions (Checks)**: `msg.sender == borrowerOperations`.
- **Behavior (Effects)**: Set `batches[_account]` with `arrayIndex = batchIds.length`, `annualInterestRate`, `annualManagementFee`, `lastInterestRateAdjTime = block.timestamp`, then `batchIds.push(_account)`.
- **Revert / early return**: `CallerNotBorrowerOperations`.
- **Emitted events**: `BatchUpdated(registerBatchManager, debt=0, coll=0, totalDebtShares=0)`.
- **Verification**: parity

#### CORE-TM-FR-023: `onLowerBatchManagerAnnualFee` (Lower Batch Management Fee) 🔵
- **Type**: Functional / **Source**: base implementation (TroveManager.sol)
- **Signature**: `onLowerBatchManagerAnnualFee(address _batchAddress, uint256 _newColl, uint256 _newDebt, uint256 _newAnnualManagementFee)`
- **Purpose**: Record management-fee reduction (BO validates reduction-only) together with settled batch values after applying interest and fee.
- **Authorization**: BorrowerOperations only.
- **Preconditions (Checks)**: `msg.sender == borrowerOperations`.
- **Behavior (Effects)**: Update `coll` / `debt` / `annualManagementFee` in `batches[_batchAddress]`; set `lastDebtUpdateTime = block.timestamp` (`lastInterestRateAdjTime` is unchanged).
- **Revert / early return**: `CallerNotBorrowerOperations`.
- **Emitted events**: `BatchUpdated(lowerBatchManagerAnnualFee)`.
- **Verification**: parity

#### CORE-TM-FR-024: `onSetBatchManagerAnnualInterestRate` (Change Batch Interest Rate) 🔵
- **Type**: Functional / **Source**: base implementation (TroveManager.sol)
- **Signature**: `onSetBatchManagerAnnualInterestRate(address _batchAddress, uint256 _newColl, uint256 _newDebt, uint256 _newAnnualInterestRate, uint256 _upfrontFee)`
- **Purpose**: Record batch interest-rate change. `_upfrontFee` is the fee charged to batch debt during premature adjustment (accepted for event display).
- **Authorization**: BorrowerOperations only.
- **Preconditions (Checks)**: `msg.sender == borrowerOperations`.
- **Behavior (Effects)**: Update `coll` / `debt` / `annualInterestRate`; set `lastDebtUpdateTime = lastInterestRateAdjTime = block.timestamp`.
- **Revert / early return**: `CallerNotBorrowerOperations`.
- **Emitted events**: `BatchUpdated(setBatchManagerAnnualInterestRate, _debtIncreaseFromUpfrontFee = _upfrontFee)` (the only place where the upfront fee charged to the whole batch appears in a batch event).
- **Verification**: parity

#### CORE-TM-FR-025: `onSetInterestBatchManager` (Join Existing Trove to Batch) 🔵
- **Type**: Functional / **Source**: base implementation (TroveManager.sol)
- **Signature**: `onSetInterestBatchManager(OnSetInterestBatchManagerParams calldata _params)` (params: `troveId, troveColl, troveDebt, troveChange, newBatchAddress, newBatchColl, newBatchDebt`)
- **Purpose**: Join an existing non-batch Trove to a batch. Clears individual debt record and transfers it to batch shares.
- **Authorization**: BorrowerOperations only.
- **Preconditions (Checks)**: `msg.sender == borrowerOperations`. Internal `assert(_params.troveDebt > 0)`.
- **Behavior (Effects)**:
  1. Update `rewardSnapshots`.
  2. Clear individual Trove debt state: `debt = 0`, `annualInterestRate = 0`, `lastDebtUpdateTime = 0`, `coll = troveColl` (entire value).
  3. `interestBatchManager = newBatchAddress`, `lastInterestRateAdjTime = block.timestamp`.
  4. Construct `troveChange.collIncrease = troveColl - appliedRedistCollGain`, `troveChange.debtIncrease = troveDebt - appliedRedistJpydfDebtGain - upfrontFee`, and call `_updateBatchShares(..., true)` (FR-027. Shares are issued for the full entire debt of the Trove).
  5. Move pending redistribution gains to AP.
- **Revert / early return**: `CallerNotBorrowerOperations` / `BatchSharesRatioTooHigh`.
- **Emitted events**: `BatchedTroveUpdated`, `TroveOperation(setInterestBatchManager)` (`ChangeFromOperation` for debt/coll is 0), `BatchUpdated(joinBatch)`.
- **Verification**: parity

#### CORE-TM-FR-026: `onRemoveFromBatch` (Remove Trove from Batch) 🔵
- **Type**: Functional / **Source**: base implementation (TroveManager.sol, internal `_removeTroveSharesFromBatch`)
- **Signature**: `onRemoveFromBatch(uint256 _troveId, uint256 _newTroveColl, uint256 _newTroveDebt, TroveChange memory _troveChange, address _batchAddress, uint256 _newBatchColl, uint256 _newBatchDebt, uint256 _newAnnualInterestRate)`
- **Purpose**: Remove a batch-member Trove and restore its debt record as an individual-rate Trove.
- **Authorization**: BorrowerOperations only.
- **Preconditions (Checks)**: `msg.sender == borrowerOperations`.
- **Behavior (Effects)**:
  1. `_removeTroveSharesFromBatch`: subtract `trove.batchDebtShares` from `totalDebtShares`; set batch `debt = _newBatchDebt - (newTroveDebt - upfrontFee - appliedRedistJpydfDebtGain)`, `coll = _newBatchColl - (newTroveColl - appliedRedistCollGain)`, `lastDebtUpdateTime = block.timestamp`. On the Trove side, set `interestBatchManager = 0`, `batchDebtShares = 0` (redistribution amounts are share-ized then immediately subtracted, so omitted; interest and management fee are shares-proportional, so shares subtraction completes them).
  2. Restore individual Trove state: `debt = _newTroveDebt` (entire value), `coll = _newTroveColl`, `lastDebtUpdateTime = lastInterestRateAdjTime = block.timestamp`, `annualInterestRate = _newAnnualInterestRate`.
  3. Update `rewardSnapshots` and move pending redistribution gains to AP.
- **Revert / early return**: `CallerNotBorrowerOperations`.
- **Emitted events**: `TroveUpdated`, `TroveOperation(removeFromBatch)`, `BatchUpdated(exitBatch)`.
- **Verification**: parity / invariant=CORE-TM-INV-004

#### CORE-TM-FR-027: Batch Debt Shares Update Rule (`_updateBatchShares`) 🔵
- **Type**: Functional / **Source**: base implementation (TroveManager.sol internal functions `_updateBatchShares` / `_requireBelowMaxSharesRatio`)
- **Signature**: internal (used from FR-004/015/019/020/025)
- **Purpose**: Define issuance, burning, and consistency rules when managing a Trove's share of batch debt by shares.
- **Authorization**: internal only.
- **Preconditions (Checks)**: When debt is **increasing** (`_batchDebt > 0`) and `_checkBatchSharesRatio == true`, revert if `currentShares × MAX_BATCH_SHARES_RATIO < _batchDebt` (reject additions to a batch whose debt/shares ratio exceeds `MAX_BATCH_SHARES_RATIO`, value in §7).
- **Behavior (Effects)**:
  1. Calculate net debt change: normalize `debtIncrease + upfrontFee + appliedRedistJpydfDebtGain` and `debtDecrease` into one positive side.
  2. No change: `batches.debt = _batchDebt` (only refresh to latest value including interest and management fee).
  3. Increase: if `_batchDebt == 0`, `sharesDelta = increase` (initial 1:1); otherwise after ratio check, `sharesDelta = currentShares × increase / _batchDebt`. Add to Trove `batchDebtShares` and batch `totalDebtShares`, and set `debt = _batchDebt + increase`.
  4. Decrease: when `_newTroveDebt == 0` (only full redemption can produce this), **clear all Trove shares** and subtract them from `totalDebtShares` to avoid rounding dust (Trove remains in batch because removing it would harm UX). Otherwise subtract `sharesDelta = currentShares × decrease / _batchDebt`.
  5. `lastDebtUpdateTime = block.timestamp`.
  6. Calculate net collateral change similarly and add/subtract from `batches.coll` (shares are not used for collateral).
- **Revert / early return**: `BatchSharesRatioTooHigh` (only when increasing and check enabled. Redemption path disables the check = FR-004).
- **Emitted events**: none (observed through caller events).
- **Design notes**: Shares enable O(1) proration of interest and management fee. Debt/shares ratio rises monotonically with interest accumulation; after `MAX_BATCH_SHARES_RATIO` is reached, further debt additions to that batch become permanently impossible (base comment: even at 10% annual compounding, reaching the cap takes more than 200 years). Operational response is to migrate the batch to a new address.
- **Verification**: parity / unit (initial issuance, full redemption, ratio boundary) / invariant=CORE-TM-INV-004

#### CORE-TM-FR-028: `syncRiskParams` (One-Time Synchronization from AddressesRegistry) 🟡
- **Type**: Functional / Security / **Source**: CORE-MOD-013
- **Signature**: `syncRiskParams(RiskParams calldata _riskParams)`
- **Purpose**: During reserved-branch finalization, synchronize the Registry-validated `CCR / MCR / SCR / LIQUIDATION_PENALTY_SP / LIQUIDATION_PENALTY_REDISTRIBUTION / COLL_GAS_COMPENSATION_CAP` into TM's stored copies.
- **Authorization**: only `msg.sender == address(addressesRegistry)`.
- **Behavior (Effects)**: Overwrite the corresponding TM storage values with the six consumer values passed by the Registry from the same `finalizeRiskParams` calldata. Third parties cannot call this function, and the Registry has no repeatable call path.
- **Revert / early return**: caller is not the Registry → `CallerNotAddressesRegistry()`. A failure rolls back the entire finalization, including Registry and prior BO updates (CORE-AR-FR-005).
- **Emitted events**: none; the Registry's `RiskParamsFinalized` event observes the complete finalized set.
- **Verification**: unit (caller restriction, risk-value and compensation-cap synchronization, and atomic rollback).


### StabilityPool / DFStabilityPool Functional Requirements (`CORE-SP-FR-*`)

#### CORE-SP-FR-001: Constructor (Wiring from AddressesRegistry) 🔵
- **Type**: Functional / **Source**: base implementation (StabilityPool.sol / Dependencies/LiquityBase.sol)
- **Signature**: `constructor(IAddressesRegistry _addressesRegistry)`
- **Purpose**: Retrieve and fix related contract addresses once from the branch AddressesRegistry.
- **Authorization**: deployment only.
- **Preconditions (Checks)**: none (registry values are adopted without validation. Wiring correctness is ensured on the AddressesRegistry side = AR scope).
- **Behavior (Effects)**:
  1. (LiquityBase) Retrieve `activePool` / `defaultPool` / `priceFeed` from registry and store in storage. Emit `ActivePoolAddressChanged` / `DefaultPoolAddressChanged` / `PriceFeedAddressChanged`.
  2. Retrieve `addressesRegistry` / `collToken` / `troveManager` / `jpydfToken` from the registry and fix them as immutables. Emit `TroveManagerAddressChanged` / `JpydfTokenAddressChanged`.
  3. `P` starts at `P_PRECISION` (=1e36) through declaration initialization. `currentScale` and all trackers start at 0.
- **Revert / early return**: none.
- **Emitted events**: CORE-SP-EVT-009-013.
- **Design notes**: There are no setters; wiring is immutable after deployment. `collToken` is dToken ([dToken.md](dToken.md)). DFStabilityPool constructor is identical (additional state `lastDepositBlock` is a mapping and requires no initialization).
- **Verification**: parity (wiring and initial-value identity).

#### CORE-SP-FR-002: `provideToSP` (JPYdf Deposit/Top-Up and Simultaneous Gain Settlement) 🔵/🟡
- **Type**: Functional / **Source**: base implementation (StabilityPool.sol) + CORE-MOD-013
- **Signature**: `provideToSP(uint256 _topUp, bool _doClaim)`
- **Purpose**: Deposit JPYdf (new deposit and top-up share this path). At the same time, settle collateral gains and yield gains since the previous operation (claim or stash/compound) and update snapshots to latest values.
- **Authorization**: permissionless when `riskParamsFinalized == true` (anyone may execute for their own deposit. New deposit is possible with no existing deposit).
- **Preconditions (Checks)**:
  - `addressesRegistry.riskParamsFinalized() == true`; an unfinalized reserved branch cannot create user-fund or liquidation-penalty exposure.
  - `_topUp > 0` (zero deposit not allowed).
  - Caller has at least `_topUp` JPYdf balance (assumption for `jpydfToken.sendToPool` transfer. No allowance required because JpydfToken pool transfer moves balance directly. BT scope).
- **Behavior (Effects)** (code execution order):
  1. Call `activePool.mintAggInterest()`. ActivePool mints pending aggregate interest, mints the SP share (`SP_YIELD_SPLIT` = 75%) to SP, and calls back `triggerJpydfRewards` (AP scope). **As a result, subsequent gain calculations include interest yield up to immediately before this operation**.
  2. Calculate current values: `currentCollGain` (CORE-SP-FR-008), `currentYieldGain` (CORE-SP-FR-009), and `compoundedJpydfDeposit` (CORE-SP-FR-011).
  3. Determine the yield destination by `_doClaim` (`_getYieldToKeepOrSend`): `true` → send full amount (`yieldGainToSend`); `false` → compound full amount into deposit (`keptYieldGain`).
  4. New deposit amount: `newDeposit = compoundedJpydfDeposit + _topUp + keptYieldGain`.
  5. Determine collateral destination by `_doClaim` (`_getNewStashedCollAndCollToSend`): `true` → send `stashedColl[msg.sender] + currentCollGain` in full and set stash to 0; `false` → add current gain to stash and send 0.
  6. Emit `DepositOperation(msg.sender, Operation.provideToSP, initialDeposit - compoundedJpydfDeposit, int256(_topUp), currentYieldGain, yieldGainToSend, currentCollGain, collToSend)`.
  7. `_updateDepositAndSnapshots`: update `deposits` / `stashedColl`, and update snapshots to current `P` / `scaleToS[currentScale]` / `scaleToB[currentScale]` / `currentScale` (because `newDeposit > 0`, it does not enter the delete branch). Emit `DepositUpdated`.
  8. Receive JPYdf through `jpydfToken.sendToPool(msg.sender, address(this), _topUp)`.
  9. `totalJpydfDeposits += _topUp + keptYieldGain` (emit `StabilityPoolJpydfBalanceUpdated`). Kept yield is an internal SP movement, so no transfer is needed before adding it to total deposits.
  10. `yieldGainsOwed -= currentYieldGain` (clear unpaid accounting regardless of claim/stash choice).
  11. If `yieldGainToSend > 0`, send it with `jpydfToken.returnFromPool`.
  12. If `collToSend > 0`, decrement `collBalance` (emit `StabilityPoolCollBalanceUpdated`) and `collToken.safeTransfer(msg.sender, collToSend)` (dToken payout).
  13. `_updateYieldRewardsSum(0)`: if this deposit makes `totalJpydfDeposits >= MIN_JPYDF_IN_SP`, move `yieldGainsPending` to `yieldGainsOwed` and add to `scaleToB[currentScale]` (emit `B_Updated`; same logic as CORE-SP-FR-006).
- **Revert / early return**: unfinalized branch → `RiskParamsNotFinalized()`; `_topUp == 0` → `"StabilityPool: Amount must be non-zero"`; insufficient JPYdf balance → JpydfToken-side revert.
- **Emitted events**: `DepositOperation`, `DepositUpdated`, `StabilityPoolJpydfBalanceUpdated`, `StabilityPoolCollBalanceUpdated` (on claim), and `B_Updated` (on pending transfer).
- **Design notes**:
  - **Gains are always settled in full at the same time** (partial settlement is impossible). `_doClaim=false` does not mean "do not receive"; it selects fallback destinations: yield compounds into deposit and collateral is retained in `stashedColl`.
  - Only new deposits and top-ups are rejected while unfinalized. Withdrawals and claims stay open so users can recover funds even if anomalous state exists; finalization separately requires `totalJpydfDeposits == 0`.
  - Snapshot update (step 7) occurs **before** pending transfer (step 13), so the depositor whose deposit causes the threshold to be reached also participates in the pending yield distribution immediately afterward.
  - Deposits have no `MIN_JPYDF_IN_SP` constraint (the constraint applies only on withdrawal. CORE-SP-FR-003).
  - 🟡 **Delta from base** (CORE-MOD-013): both StabilityPool and DFStabilityPool require `riskParamsFinalized == true` at the beginning of `provideToSP`. An unfinalized branch reverts with `RiskParamsNotFinalized()` before any external call or state change; a finalized branch continues through the existing deposit path.
  - 🟡 **Delta from base** (CORE-MOD-004 (§2 DF delta ledger)): base has no same-block constraint in gain calculation. In DF (DFStabilityPool), when an existing depositor uses `_doClaim=true` and `currentCollGain > 0 || stashedColl[msg.sender] > 0`, the code requires `lastDepositBlock[msg.sender] < block.number` immediately after calculating the current collateral gain in step 2; otherwise it reverts with `"StabilityPool: Coll gain claim must wait after deposit"`. New deposits, same-block top-ups with no collateral gain, and `_doClaim=false` remain allowed. DF also records `lastDepositBlock[msg.sender] = block.number` immediately after step 6 and before step 7 (CORE-SP-FR-004). All other behavior, events, and arguments are identical to base. Rationale: prevent same-block flash deposit → liquidation → collateral payout through `provideToSP(nonzero, true)` (CORE-SP-SEC-004).
- **Verification**: parity / unit (`_doClaim` branches, compounding kept yield, pending transfer, new/top-up paths, unfinalized rejection, finalized pass-through) / invariant=CORE-SP-INV-003, CORE-SP-INV-005, CORE-SP-INV-006.

#### CORE-SP-FR-003: `withdrawFromSP` (JPYdf Withdrawal and Simultaneous Gain Settlement) 🔵
- **Type**: Functional / **Source**: base implementation (StabilityPool.sol)
- **Signature**: `withdrawFromSP(uint256 _amount, bool _doClaim)`
- **Purpose**: Withdraw up to `_amount` JPYdf from the compounded deposit. At the same time, settle gains and update snapshots. Calling with `_amount = 0` is valid as a "settle gains only" operation.
- **Authorization**: permissionless (but requires an existing deposit).
- **Preconditions (Checks)**:
  - `deposits[msg.sender].initialValue > 0` (caller is a depositor).
  - As a **postcondition**, `totalJpydfDeposits >= MIN_JPYDF_IN_SP` (= 1 JPYdf; value in §7) after withdrawal. Checked at function end.
- **Behavior (Effects)** (code execution order):
  1. `activePool.mintAggInterest()` (same as CORE-SP-FR-002 step 1. Finalize interest before gain calculation).
  2. Calculate `currentCollGain` / `currentYieldGain` / `compoundedJpydfDeposit`.
  3. `jpydfToWithdraw = min(_amount, compoundedJpydfDeposit)` (excess request is truncated to full withdrawal).
  4. Determine claim/stash for yield and collateral by `_doClaim` (same branches as CORE-SP-FR-002 steps 3 and 5).
  5. New deposit amount: `newDeposit = compoundedJpydfDeposit - jpydfToWithdraw + keptYieldGain`.
  6. Emit `DepositOperation(msg.sender, Operation.withdrawFromSP, initialDeposit - compoundedJpydfDeposit, -int256(jpydfToWithdraw), currentYieldGain, yieldGainToSend, currentCollGain, collToSend)`.
  7. `_updateDepositAndSnapshots`: if `newDeposit == 0`, delete `depositSnapshots` and emit `DepositUpdated(_depositor, 0, newStashedColl, 0, 0, 0, 0)`; if `> 0`, record latest snapshots.
  8. `yieldGainsOwed -= currentYieldGain`.
  9. `totalJpydfDeposits = totalJpydfDeposits + keptYieldGain - jpydfToWithdraw` (emit `StabilityPoolJpydfBalanceUpdated`; store as `newTotalJpydfDeposits`).
  10. Send `jpydfToWithdraw + yieldGainToSend` with `jpydfToken.returnFromPool`.
  11. On claim, pay collateral (decrement `collBalance`, emit `StabilityPoolCollBalanceUpdated`, and `safeTransfer`).
  12. Check `require(newTotalJpydfDeposits >= MIN_JPYDF_IN_SP, ...)`.
- **Revert / early return**: no deposit → `"StabilityPool: User must have a non-zero deposit"`; post-withdrawal total below threshold → `"Withdrawal must leave totalJpydfDeposits >= MIN_JPYDF_IN_SP"`.
- **Emitted events**: `DepositOperation`, `DepositUpdated`, `StabilityPoolJpydfBalanceUpdated`, and `StabilityPoolCollBalanceUpdated` (on claim).
- **Design notes**:
  - `MIN_JPYDF_IN_SP` is a postcondition on **pool total**, not individual deposit. Once the pool reaches at least `MIN_JPYDF_IN_SP`, the final 1 JPYdf equivalent cannot be withdrawn by anyone (and cannot be emptied by offset, together with CORE-SP-INV-002, forming the basis for `P > 0`). Conversely, in a tiny pool that has never reached the threshold, withdrawals always revert (a deposit above the threshold is required first).
  - `_amount = 0` and `_doClaim = true` is the standard "claim all gains only" operation (`jpydfToWithdraw = 0`, deposit remains).
  - Even on full withdrawal, if `_doClaim = false`, kept yield may remain as a new deposit, so deposit may not become 0.
  - 🟡 **Delta from base** (CORE-MOD-004 (§2 DF delta ledger)): base permits withdrawal in the same block as a deposit. In DF (DFStabilityPool), at the beginning (immediately after `_requireUserHasDeposit` and before `mintAggInterest`) `_requireWithdrawalAfterDeposit()` checks `lastDepositBlock[msg.sender] < block.number`; otherwise it reverts with `"StabilityPool: Withdrawal must wait after deposit"` (CORE-SP-FR-004). All other behavior is identical to base. Rationale: CORE-SP-SEC-004.
- **Verification**: parity / unit (`min` truncation, `_amount=0` settlement, `MIN_JPYDF_IN_SP` boundary, snapshot delete when `newDeposit==0`) / invariant=CORE-SP-INV-002, CORE-SP-INV-003, CORE-SP-INV-006.

#### CORE-SP-FR-004: `lastDepositBlock` (Same-Block Collateral-Claim and Withdrawal Guard) 🟡
- **Type**: Functional / **Source**: DF design (CORE-MOD-004 (§2 DF delta ledger); DFStabilityPool.sol)
- **Signature**: `lastDepositBlock(address) → uint256` (automatic getter for public mapping) + internal guards `_requireCollGainClaimAfterDeposit()` / `_requireWithdrawalAfterDeposit()`
- **Purpose**: Block liquidation-gain sniping of "flash deposit → liquidation (offset) occurs → receive and externally convert collateral gains to recover funding" within the same block by disallowing collateral-gain payouts and withdrawals in the deposit block.
- **Authorization**: getter is permissionless (view). Recording/checking are internal behavior of `provideToSP` / `withdrawFromSP`.
- **Preconditions (Checks)**: - (state variable specification).
- **Behavior (Effects)**:
  1. During `provideToSP`, record `lastDepositBlock[msg.sender] = block.number` (both new deposits and top-ups; immediately after `DepositOperation` emit and at the beginning of the state-update group).
  2. In `provideToSP`, when an existing depositor uses `_doClaim=true` and has current or stashed collateral gains, check `require(lastDepositBlock[msg.sender] < block.number, "StabilityPool: Coll gain claim must wait after deposit")`.
  3. At the beginning of `withdrawFromSP`, check `require(lastDepositBlock[msg.sender] < block.number, "StabilityPool: Withdrawal must wait after deposit")`.
  4. Addresses that have never deposited have initial value 0 and always pass the block check (but withdrawal reverts at `_requireUserHasDeposit` because they have no deposit).
- **Revert / early return**: deposit→collateral-gain claim in the same block → `"StabilityPool: Coll gain claim must wait after deposit"`; deposit→withdraw in the same block → `"StabilityPool: Withdrawal must wait after deposit"`.
- **Emitted events**: none (no dedicated event is added).
- **Design notes**:
  - The constraint releases **from the next block** only (not a timelock). A deposit persists across at least one block boundary, but a deposit in the last transaction of block N can settle in the first transaction of block N+1, so the guard does not guarantee an intervening `offset()` or a full block of liquidation-loss exposure. A flash loan requiring repayment within the same transaction cannot withdraw the deposit or receive and convert the liquidation collateral.
  - `provideToSP(..., false)` remains allowed in the same block and stashes the current collateral gain. A subsequent same-block `provideToSP(..., true)` is rejected by the stash condition. `_doClaim=true` top-ups with no collateral gain and JPYdf-yield-only settlement remain allowed.
  - `claimAllCollGains` acts only on zero-deposit users (stash remaining from past operations), so it does not create a sniping path when combined with same-block deposit.
  - StabilityPool.sol (base norm) does not have this state or guard. The deployed implementation is DFStabilityPool, and fork-source parity tests must verify that differences between the two are limited to this FR and the 4 items noted in CORE-SP-FR-002/003.
- **Verification**: unit (same-block current/stashed collateral claim reverts; no-claim stash succeeds; top-up with no collateral gain and new deposit succeed; next-block claim/withdraw succeeds; `claimAllCollGains` unaffected) / copy-parity (DFStabilityPool behavior identical to StabilityPool except for this guard).

#### CORE-SP-FR-005: `claimAllCollGains` (Claim Stashed Collateral for Zero-Deposit User) 🔵
- **Type**: Functional / **Source**: base implementation (StabilityPool.sol)
- **Signature**: `claimAllCollGains()`
- **Purpose**: Dedicated function for a user with only `stashedColl` remaining after fully withdrawing deposits to receive retained collateral.
- **Authorization**: permissionless (but **deposit must be 0**. Depositors settle through `_doClaim=true` in CORE-SP-FR-002/003).
- **Preconditions (Checks)**:
  - `deposits[msg.sender].initialValue == 0`.
  - `stashedColl[msg.sender] > 0`.
- **Behavior (Effects)**:
  1. `activePool.mintAggInterest()` (same as other depositor operations; updates ActivePool interest aggregation).
  2. Read `collToSend = stashedColl[msg.sender]`, then set `stashedColl[msg.sender] = 0`.
  3. Emit `DepositOperation(msg.sender, Operation.claimAllCollGains, 0, 0, 0, 0, 0, collToSend)` and `DepositUpdated(msg.sender, 0, 0, 0, 0, 0, 0)`.
  4. Decrement `collBalance` (emit `StabilityPoolCollBalanceUpdated`) and `collToken.safeTransfer(msg.sender, collToSend)` (dToken payout; [dToken.md](dToken.md)).
- **Revert / early return**: has deposit → `"StabilityPool: User must have no deposit"`; stash is 0 → `"StabilityPool: Amount must be non-zero"`.
- **Emitted events**: `DepositOperation`, `DepositUpdated`, `StabilityPoolCollBalanceUpdated`.
- **Design notes**: When deposit becomes 0, snapshots are already deleted (CORE-SP-FR-003 step 7), so this function does no gain calculation and only pays the stash balance. It is outside the DF guard (CORE-SP-FR-004).
- **Verification**: parity / unit (revert with deposit, revert with zero stash, payout and stash clear).

#### CORE-SP-FR-006: `triggerJpydfRewards` (Account Interest Yield Distribution) 🔵
- **Type**: Functional / **Source**: base implementation (StabilityPool.sol)
- **Signature**: `triggerJpydfRewards(uint256 _jpydfYield)`
- **Purpose**: When ActivePool mints aggregate interest, account the SP share of JPYdf yield (`SP_YIELD_SPLIT` = 75%; AP scope) as distribution to depositors.
- **Authorization**: **ActivePool only** (`require(msg.sender == address(activePool))`).
- **Preconditions (Checks)**: caller check only. `_jpydfYield = 0` is allowed (can be a trigger to move pending amounts).
- **Behavior (Effects)** (`_updateYieldRewardsSum(_jpydfYield)`):
  1. `accumulatedYieldGains = yieldGainsPending + _jpydfYield`. If 0, do nothing and return.
  2. If `totalJpydfDeposits < MIN_JPYDF_IN_SP`: set `yieldGainsPending = accumulatedYieldGains` and **defer distribution**, then return (`B` is not updated. The actual JPYdf has already been minted by ActivePool to SP and remains in SP balance).
  3. Otherwise: `yieldGainsOwed += accumulatedYieldGains`, `yieldGainsPending = 0`, add `scaleToB[currentScale] += P * accumulatedYieldGains / totalJpydfDeposits`, and emit `B_Updated(scaleToB[currentScale], currentScale)`.
- **Revert / early return**: non-ActivePool → `"StabilityPool: Caller is not ActivePool"`; `accumulatedYieldGains == 0` → early return (no event).
- **Emitted events**: `B_Updated` only when distributed.
- **Design notes**:
  - If total deposits are tiny (below threshold), distributing would let a tiny deposit monopolize yield and could make `B` addition explode, so distribution is deferred as pending until threshold recovery. Pending is distributed in bulk on the next call to this function or at the end of `provideToSP` (CORE-SP-FR-002 step 13).
  - `yieldGainsOwed` increases but `totalJpydfDeposits` does not. Yield enters deposit total only when each depositor compounds with `_doClaim=false` (kept yield).
- **Verification**: parity / unit (pending accumulation below threshold, bulk transfer above threshold, zero-yield early return) / invariant=CORE-SP-INV-003, CORE-SP-INV-005.

#### CORE-SP-FR-007: `offset` (Liquidation Offset: P/S Update, Debt Burn, Collateral Receipt) 🔵
- **Type**: Functional / **Source**: base implementation (StabilityPool.sol)
- **Signature**: `offset(uint256 _debtToOffset, uint256 _collToAdd)`
- **Purpose**: Offset liquidated Trove debt `_debtToOffset` against pool deposits (burn JPYdf), receive liquidation collateral `_collToAdd` from ActivePool, and distribute it proportionally to depositors. Distribution is represented only by updating `S` (collateral) and `P` (deposit depletion rate), in O(1).
- **Authorization**: **TroveManager only** (`require(msg.sender == address(troveManager))`).
- **Preconditions (Checks)**: local check only for `newP > 0`. **The following are guaranteed by caller TroveManager liquidation logic** (TM scope): `totalJpydfDeposits > 0` (avoid division by zero), `_debtToOffset <= totalJpydfDeposits - MIN_JPYDF_IN_SP` (do not empty pool).
- **Behavior (Effects)** (code execution order):
  1. Add `scaleToS[currentScale] += P * _collToAdd / totalJpydfDeposits` and emit `S_Updated(scaleToS[currentScale], currentScale)` (weighted by **pre-update P**. Floor-division remainder is not distributed; because full collateral is received in step 7, the error remains on `collBalance` side and never over-distributes to depositors).
  2. Calculate `numerator = P * (totalJpydfDeposits - _debtToOffset)`, `newP = numerator / totalJpydfDeposits` (floor division. Compounded deposit valuation is at or below exact value, with rounding direction adverse to depositors and residual left in pool).
  3. `require(newP > 0, "P must never decrease to 0")`. Because `MIN_JPYDF_IN_SP` keeps `totalJpydfDeposits - _debtToOffset >= 1e18` and `P >= P_PRECISION / SCALE_FACTOR = 1e27`, reaching `newP = 0` would require `totalJpydfDeposits > 1e45` (octillion-scale JPYdf), practically unreachable (code-comment analysis).
  4. **Scale processing**: while `newP < P_PRECISION / SCALE_FACTOR` (=1e27), run `numerator *= SCALE_FACTOR; newP = numerator / totalJpydfDeposits; currentScale += 1`, emitting `ScaleUpdated(currentScale)` each time. Multiplying the **original numerator** and re-dividing, rather than multiplying already divided `newP`, avoids accumulated rounding error. Multiple scale crossings in one offset are handled by this loop. Overflow is practically impossible because `numerator <= 1e36 * totalJpydfDeposits / SCALE_FACTOR` is the upper bound for each iteration (code-comment analysis).
  5. Emit `P_Updated(newP)` and set `P = newP` (post-loop P is always within `[1e27, 1e36]`).
  6. `totalJpydfDeposits -= _debtToOffset` (emit `StabilityPoolJpydfBalanceUpdated`) and burn the offset amount with `jpydfToken.burn(address(this), _debtToOffset)`.
  7. `collBalance += _collToAdd`; receive collateral (dToken) from ActivePool via `activePool.sendColl(address(this), _collToAdd)`. Emit `StabilityPoolCollBalanceUpdated`.
- **Revert / early return**: non-TroveManager → `"StabilityPool: Caller is not TroveManager"`; `newP == 0` → `"P must never decrease to 0"`; if called with `totalJpydfDeposits == 0`, division panic (precondition violation; TM side makes it unreachable).
- **Emitted events**: `S_Updated`, zero or more `ScaleUpdated` (when crossing scale), `P_Updated`, `StabilityPoolJpydfBalanceUpdated`, `StabilityPoolCollBalanceUpdated`.
- **Design notes**:
  - The order where `S` is added (step 1) before `P` update (steps 2-5) is a prerequisite of this method: gains are distributed by deposit value **before** offset, and depletion is reflected afterward.
  - `scaleToS` / `scaleToB` are P-weighted sums, so depositor gains are normalized by snapshot `P_t` as `initialDeposit * (S - S_t) / P_t` (CORE-SP-FR-008/009).
  - Collateral receipt pairs internal tracker increment `collBalance` with actual transfer through `activePool.sendColl`, avoiding confusion with direct sends (CORE-SP-SEC-003).
- **Verification**: parity / unit (single/multiple scale crossings, `newP > 0` boundary, S→P update ordering, rounding direction) / invariant=CORE-SP-INV-001-004.

#### CORE-SP-FR-008: `getDepositorCollGain` (Calculate Unsettled Collateral Gain) 🔵
- **Type**: Functional / **Source**: base implementation (StabilityPool.sol)
- **Signature**: `getDepositorCollGain(address _depositor) → uint256` (public view)
- **Purpose**: Return collateral gains earned by a depositor since their last snapshot. Also used internally to calculate settlement amount in `provideToSP` / `withdrawFromSP`.
- **Authorization**: none (view).
- **Preconditions (Checks)**: none.
- **Behavior (Effects)**:
  1. If `deposits[_depositor].initialValue == 0`, return 0.
  2. Same-scale amount: `normalizedGains = scaleToS[snapshots.scale] - snapshots.S`.
  3. Cross-scale amount: for `i = 1..SCALE_SPAN` (=2), add `normalizedGains += scaleToS[snapshots.scale + i] / SCALE_FACTOR**i` (later-scale cumulative sums are treated as entirely generated during the deposit's holding period and converted back by powers of `SCALE_FACTOR`).
  4. Return `min(initialDeposit * normalizedGains / snapshots.P, collBalance)` (upper clamp prevents payout above actual pool holdings).
- **Revert / early return**: none (0 deposit → 0).
- **Emitted events**: none (view).
- **Design notes**: Gains beyond `SCALE_SPAN` (=2) scale advances from the snapshot scale are not counted (a deposit left untouched stops receiving gains). Upstream design rationale: at 2 scale crossings, the deposit has depleted to at most 1e-9 to 1e-18 of principal, so economic impact of truncation is negligible.
- **Verification**: parity / unit (same scale, 1/2 scale crossings, truncation beyond SPAN, clamp).

#### CORE-SP-FR-009: `getDepositorYieldGain` (Calculate Unsettled Yield Gain) 🔵
- **Type**: Functional / **Source**: base implementation (StabilityPool.sol)
- **Signature**: `getDepositorYieldGain(address _depositor) → uint256` (public view)
- **Purpose**: Return JPYdf yield gain (from Trove interest) earned by a depositor since their last snapshot.
- **Authorization**: none (view).
- **Preconditions (Checks)**: none.
- **Behavior (Effects)**: Same form as CORE-SP-FR-008, replacing `scaleToS`/`snapshots.S` with `scaleToB`/`snapshots.B`, and clamp with `yieldGainsOwed`:
  `min(initialDeposit * ((scaleToB[scale] - B_t) + Σ_{i=1..2} scaleToB[scale+i] / 1e9^i) / snapshots.P, yieldGainsOwed)`.
- **Revert / early return**: none (0 deposit → 0).
- **Emitted events**: none (view).
- **Design notes**: The clamp target `yieldGainsOwed` (allocated but unpaid total yield) is the difference from collateral gains. `yieldGainsPending` is not included because it is not allocated; estimates including it are in CORE-SP-FR-010.
- **Verification**: parity / unit (scale crossings, clamp, pending excluded).

#### CORE-SP-FR-010: `getDepositorYieldGainWithPending` (Yield Estimate Including Pending Interest) 🔵
- **Type**: Functional / **Source**: base implementation (StabilityPool.sol)
- **Signature**: `getDepositorYieldGainWithPending(address _depositor) → uint256` (external view)
- **Purpose**: Frontend estimate of "what `getDepositorYieldGain` would be if interest were minted now." Not used in state-changing paths.
- **Authorization**: none (view).
- **Preconditions (Checks)**: none.
- **Behavior (Effects)**:
  1. If `totalJpydfDeposits < MIN_JPYDF_IN_SP`, return 0 (pending is not distributed).
  2. If deposit is 0, return 0.
  3. Calculate `normalizedGains` for finalized amounts as in CORE-SP-FR-009.
  4. Add `pendingSPYield = activePool.calcPendingSPYield()` (SP share of unminted aggregate interest; AP scope) to cap as `newYieldGainsOwed = yieldGainsOwed + pendingSPYield`.
  5. Only if `currentScale <= snapshots.scale + SCALE_SPAN`, add `normalizedGains += P * pendingSPYield / totalJpydfDeposits / SCALE_FACTOR**(currentScale - snapshots.scale)` (simulate pending as a `B` addition at current scale and convert down to depositor's scale).
  6. Return `min(initialDeposit * normalizedGains / snapshots.P, newYieldGainsOwed)`.
- **Revert / early return**: none.
- **Emitted events**: none (view).
- **Design notes**: Existing `yieldGainsPending` is **not included** in steps 4/5 (`calcPendingSPYield` is only ActivePool-side unminted interest). Together with the 0 result below threshold, this is strictly an estimate for "live pool at or above threshold."
- **Verification**: parity / unit (0 below threshold, SPAN in/out branches, consistency immediately after `triggerJpydfRewards`).

#### CORE-SP-FR-011: `getCompoundedJpydfDeposit` (Calculate Compounded Deposit) 🔵
- **Type**: Functional / **Source**: base implementation (StabilityPool.sol)
- **Signature**: `getCompoundedJpydfDeposit(address _depositor) → uint256` (public view)
- **Purpose**: Return the depositor's current deposit after depletion from a series of liquidations.
- **Authorization**: none (view).
- **Preconditions (Checks)**: none.
- **Behavior (Effects)**:
  1. If `deposits[_depositor].initialValue == 0`, return 0.
  2. `scaleDiff = currentScale - snapshots.scale`.
  3. If `scaleDiff <= MAX_SCALE_FACTOR_EXPONENT` (=8), return `initialDeposit * P / snapshots.P / SCALE_FACTOR**scaleDiff`.
  4. Otherwise return 0 (`SCALE_FACTOR**scaleDiff` would exceed uint256, so evaluate directly to 0 without overflow. A deposit crossing 9 scales is at most 1e-81 of principal and effectively 0).
- **Revert / early return**: none.
- **Emitted events**: none (view).
- **Design notes**: The gain tracking limit (`SCALE_SPAN`=2; CORE-SP-FR-008/009) and deposit-amount tracking limit (`MAX_SCALE_FACTOR_EXPONENT`=8) are independent constants. The former is an economic cutoff; the latter avoids overflow.
- **Verification**: parity / unit (scale difference 0-8, 9+ returns 0, floor-division direction).

#### CORE-SP-FR-012: Self-Evident View Function Group (Trackers, Constants, and Wiring Getters) 🔵
- **Type**: Functional / **Source**: base implementation (StabilityPool.sol)
- **Purpose**: Read internal trackers, public state variables, constants, and wiring addresses. All are simple returns of stored values without calculation.
- **Authorization**: none (all view).

  | Function | Meaning of return value |
  | --- | --- |
  | `getCollBalance()` | `collBalance` (internal collateral tracker; does not include direct transfers) |
  | `getTotalJpydfDeposits()` | `totalJpydfDeposits` |
  | `getYieldGainsOwed()` | `yieldGainsOwed` |
  | `getYieldGainsPending()` | `yieldGainsPending` |
  | `deposits(address)` | Depositor `initialValue` (deposit amount at last operation. Current value is CORE-SP-FR-011) |
  | `depositSnapshots(address)` | `(S, P, B, scale)` snapshot |
  | `stashedColl(address)` | Retained collateral gain |
  | `P()` / `currentScale()` | running product / current scale |
  | `scaleToS(uint256)` / `scaleToB(uint256)` | Per-scale cumulative sums |
  | `NAME()` | `"StabilityPool"` (**same string in DFStabilityPool**) |
  | `P_PRECISION()` / `SCALE_FACTOR()` / `MAX_SCALE_FACTOR_EXPONENT()` / `SCALE_SPAN()` | Constants (see state variable table) |
  | `collToken()` / `troveManager()` / `jpydfToken()` / `activePool()` | Wiring addresses (`activePool` is LiquityBase inheritance) |

- **Revert / early return**: none.
- **Verification**: parity.

#### CORE-SP-FR-013: `getEntireBranchColl` / `getEntireBranchDebt` (LiquityBase Inherited Views) 🔵
- **Type**: Functional / **Source**: base implementation (Dependencies/LiquityBase.sol)
- **Signature**: `getEntireBranchColl() → uint256` / `getEntireBranchDebt() → uint256` (public view)
- **Purpose**: Common helper returning total branch collateral (`activePool.getCollBalance() + defaultPool.getCollBalance()`) and total branch debt (`activePool.getJpydfDebt() + defaultPool.getJpydfDebt()`). Included here because it appears on the SP ABI.
- **Authorization**: none (view).
- **Behavior (Effects)**: Simple sum of the two terms above.
- **Revert / early return**: none.
- **Design notes**: Implementation is common LiquityBase (norm centralized in LIB scope = CORE-LIB). This FR only confirms existence on the SP interface.
- **Verification**: parity.


### ActivePool Functional Requirements (`CORE-AP-FR-*`)

#### CORE-AP-FR-001: Constructor (Address Wiring and Collateral Approve to DefaultPool) 🔵
- **Type**: Functional / **Source**: base implementation (ActivePool.sol)
- **Signature**: `constructor(IAddressesRegistry _addressesRegistry)`
- **Purpose**: Retrieve related contract addresses from the branch AddressesRegistry, fix them as immutables, and open the collateral transfer path to DefaultPool.
- **Authorization**: once at deployment.
- **Preconditions (Checks)**: none (trusts AddressesRegistry values without validation. Wiring correctness is deployment responsibility).
- **Behavior (Effects)**:
  1. Retrieve `collToken` / `borrowerOperationsAddress` / `troveManagerAddress` / `stabilityPool` / `defaultPoolAddress` / `interestRouter` / `jpydfToken` from AddressesRegistry and set as immutables.
  2. Emit 5 address-change events (CollToken / BorrowerOperations / TroveManager / StabilityPool / DefaultPool, in that order).
  3. `collToken.approve(defaultPoolAddress, type(uint256).max)` — infinite approve allowing DefaultPool to pull collateral with `safeTransferFrom` (counterpart of CORE-DP-FR-003).
- **Revert / early return**: none (nonstandard tokens returning false from approve are out of scope. Collateral is limited to dToken).
- **Emitted events**: CORE-AP-EVT-001-005.
- **Design notes**: All wiring is immutable, so no post-deployment address replacement or upgrade path exists. Pool-to-pool collateral movements consistently use "recipient pulls"; the approve that enables this is set in each pool's constructor (AP→DP here, DP→AP in DefaultPool constructor).
- **Verification**: parity / deployment test (wiring and approve value)

#### CORE-AP-FR-002: `calcPendingAggInterest` (Calculate Aggregate Pending Interest) 🔵
- **Type**: Functional / **Source**: base implementation (ActivePool.sol)
- **Signature**: `calcPendingAggInterest() → uint256` (public view)
- **Purpose**: Return branch-wide unfinalized (pending) aggregate interest accrued since `lastAggUpdateTime`.
- **Authorization**: none (view).
- **Preconditions (Checks)**: none.
- **Behavior (Effects)**:
  1. If `shutdownTime != 0`, return 0 (no interest accrues after shutdown).
  2. Otherwise return `ceilDiv(aggWeightedDebtSum × (block.timestamp - lastAggUpdateTime), ONE_YEAR × DECIMAL_PRECISION)` (linear simple-interest proration).
- **Revert / early return**: already shut down → early return 0.
- **Emitted events**: none (view).
- **Design notes**: **Ceiling division (`ceilDiv`)** is used so that system debt has positive error relative to individual Trove interest calculations (which floor-divide on the TroveManager side), preserving "system debt ≥ sum of Trove debts." This guarantees system debt cannot become negative even after all Trove debts are repaid. The error is a tiny amount proportional to the number of interest mint events.
- **Verification**: parity / basis for invariant=CORE-SYS-INV-001

#### CORE-AP-FR-003: `calcPendingSPYield` (SP Share of Pending Interest) 🔵
- **Type**: Functional / **Source**: base implementation (ActivePool.sol)
- **Signature**: `calcPendingSPYield() → uint256` (external view)
- **Purpose**: Return the StabilityPool share of pending aggregate interest. Referenced by SP's `getDepositorYieldGainWithPending` (depositor-gain estimate including unfinalized yield).
- **Authorization**: none (view).
- **Preconditions (Checks)**: none.
- **Behavior (Effects)**: Return `calcPendingAggInterest() × SP_YIELD_SPLIT / DECIMAL_PRECISION` (`SP_YIELD_SPLIT` = 75%; value in §7).
- **Revert / early return**: none.
- **Emitted events**: none (view).
- **Design notes**: Uses floor division, identical to the actual `spYield` calculation during mint (CORE-AP-FR-007).
- **Verification**: parity

#### CORE-AP-FR-004: `calcPendingAggBatchManagementFee` (Calculate Aggregate Pending Batch Management Fee) 🔵
- **Type**: Functional / **Source**: base implementation (ActivePool.sol)
- **Signature**: `calcPendingAggBatchManagementFee() → uint256` (public view)
- **Purpose**: Return total unfinalized management fees for all batches accrued from the previous finalization timestamp to now (or to shutdown timestamp if shut down).
- **Authorization**: none (view).
- **Preconditions (Checks)**: none.
- **Behavior (Effects)**:
  1. `periodEnd = shutdownTime != 0 ? shutdownTime : block.timestamp`.
  2. `periodStart = min(lastAggBatchManagementFeesUpdateTime, periodEnd)`.
  3. Return `ceilDiv(aggWeightedBatchManagementFeeSum × (periodEnd - periodStart), ONE_YEAR × DECIMAL_PRECISION)`.
- **Revert / early return**: none.
- **Emitted events**: none (view).
- **Design notes**: Unlike aggregate interest (CORE-AP-FR-002, immediately 0 after shutdown), batch management fees **remain calculable after shutdown for the portion accrued up to the shutdown timestamp**. Aggregate interest is fully minted in the same tx as shutdown processing (CORE-AP-FR-014), while batch fees are not automatically finalized at shutdown, so the formula preserves "up to shutdown" as the period cap. `min(...)` prevents underflow if `lastAggBatchManagementFeesUpdateTime` moves beyond `shutdownTime` in a post-shutdown batch operation (period becomes 0). The ceiling-division rationale is the same as CORE-AP-FR-002.
- **Verification**: parity / unit (before/after shutdown and `lastUpdate > shutdownTime` boundary)

#### CORE-AP-FR-005: `getNewApproxAvgInterestRateFromTroveChange` (Approximate Average Rate After Hypothetical Trove Change) 🔵
- **Type**: Functional / **Source**: base implementation (ActivePool.sol)
- **Signature**: `getNewApproxAvgInterestRateFromTroveChange(TroveChange calldata _troveChange) → uint256` (external view)
- **Purpose**: Return approximate branch average interest rate if the given Trove change (debt increase/decrease and new/old weighted debt sums) were applied. BorrowerOperations / HintHelpers use it to calculate upfront fee (average rate × 7 days).
- **Authorization**: none (view). Calling convention requires `_troveChange.upfrontFee == 0` (assert).
- **Preconditions (Checks)**: `assert(_troveChange.upfrontFee == 0)` — must be called with TroveChange **before** upfront fee is finalized.
- **Behavior (Effects)**:
  1. If `shutdownTime != 0`, return 0.
  2. `newAggRecordedDebt = aggRecordedDebt + calcPendingAggInterest() + appliedRedistJpydfDebtGain + debtIncrease + batchAccruedManagementFee - debtDecrease`.
  3. `newAggWeightedDebtSum = aggWeightedDebtSum + newWeightedRecordedDebt - oldWeightedRecordedDebt`.
  4. If `newAggRecordedDebt > 0`, return `newAggWeightedDebtSum / newAggRecordedDebt`; otherwise return 0.
- **Revert / early return**: `upfrontFee != 0` → assert failure (Panic 0x01). Already shut down → 0. Denominator 0 (reachable when the first borrower attempts 0 JPYdf; `debt ≥ MIN_DEBT` validation occurs after upfront fee calculation) → 0.
- **Emitted events**: none (view).
- **Design notes**: The upfront fee is intentionally ignored to break the circular dependency "fee depends on average rate → average rate weighted by debt → debt includes fee"; this is an **approximation** (the source of Approx in the function name). Result is annual interest rate scaled by 1e18.
- **Verification**: parity / unit (0 on shutdown, denominator 0, approximation formula)

#### CORE-AP-FR-006: `getJpydfDebt` (Total Active Debt) 🔵
- **Type**: Functional / **Source**: base implementation (ActivePool.sol)
- **Signature**: `getJpydfDebt() → uint256` (external view)
- **Purpose**: Return branch active-side entire debt (recorded debt + pending aggregate interest + finalized and pending batch management fees). Component of `LiquityBase.getEntireBranchDebt` (= AP.getJpydfDebt() + DP.getJpydfDebt()).
- **Authorization**: none (view).
- **Preconditions (Checks)**: none.
- **Behavior (Effects)**: Return `aggRecordedDebt + calcPendingAggInterest() + aggBatchManagementFees + calcPendingAggBatchManagementFee()`.
- **Revert / early return**: none.
- **Emitted events**: none (view).
- **Design notes**: Does not include pending debt awaiting redistribution (held by DefaultPool `getJpydfDebt` = CORE-DP-FR-006). The two batch management fee terms are added because each batched Trove's entire debt includes accrued management fee, so the system-level debt must account for the corresponding amount.
- **Verification**: parity / basis for invariant=CORE-SYS-INV-001

#### CORE-AP-FR-007: `mintAggInterest` (Finalize/Mint Aggregate Interest and Distribute 75/25) 🔵
- **Type**: Functional / **Source**: base implementation (ActivePool.sol)
- **Signature**: `mintAggInterest()`
- **Purpose**: During operations that do not change Trove composition (SP deposits/withdrawals, etc.), finalize pending aggregate interest, mint/distribute it as JPYdf, and fold it into `aggRecordedDebt`.
- **Authorization**: BorrowerOperations or StabilityPool only (`_requireCallerIsBOorSP`). Actual callers: SP `provideToSP` / `withdrawFromSP` / `claimAllCollGains`, and BO shutdown processing (`_applyShutdown`).
- **Preconditions (Checks)**: caller validation only.
- **Behavior (Effects)**: `aggRecordedDebt += _mintAggInterest(0)`. Internal `_mintAggInterest(_upfrontFee)`:
  1. `mintedAmount = calcPendingAggInterest() + _upfrontFee` (`_upfrontFee = 0` in this FR).
  2. If `mintedAmount > 0`:
     - `spYield = SP_YIELD_SPLIT × mintedAmount / DECIMAL_PRECISION` (75%, floor), `remainderToLPs = mintedAmount - spYield` (remaining 25%, ceiling side).
     - `jpydfToken.mint(interestRouter, remainderToLPs)`.
     - If `spYield > 0`, `jpydfToken.mint(stabilityPool, spYield)`, then `stabilityPool.triggerJpydfRewards(spYield)` to notify SP of yield accounting.
  3. Emit `AggregateInterestMinted(jpydfToken, stabilityPool, interestRouter, pendingAggInterest, upfrontFee, mintedAmount, spYield, remainderToLPs)` when `mintedAmount > 0`.
  4. `lastAggUpdateTime = block.timestamp` (updated even when mintedAmount is 0).
- **Revert / early return**: invalid caller → `"ActivePool: Caller is not BorrowerOperations nor StabilityPool"`.
- **Emitted events**: `AggregateInterestMinted` from ActivePool. JpydfToken Transfer and SP-side events may also occur.
- **Design notes**: Interest is finalized on the liability side (`aggRecordedDebt` increase) and asset side (JPYdf mint) simultaneously. Distribution uses fixed SP-priority 75/25 (`SP_YIELD_SPLIT`); with `mintedAmount > 0`, the router side is always positive and SP side may be 0 only for dust amounts (then `triggerJpydfRewards` is not called). Assumes ActivePool has JpydfToken mint authority (AP-limited minting is specified in BT scope). `AggregateInterestMinted` is the primary external fee/revenue accounting evidence for integrations such as DeFiLlama: `mintedAmount` is gross fees, `spYield` is supply-side revenue, and `remainderToLPs` is the PIL / InterestRouter allocation.
- **Verification**: parity / unit (distribution rounding, `spYield=0` boundary, `lastAggUpdateTime` update)

#### CORE-AP-FR-008: `mintAggInterestAndAccountForTroveChange` (Mint Interest + Reflect Trove Change in Aggregation) 🔵
- **Type**: Functional / **Source**: base implementation (ActivePool.sol)
- **Signature**: `mintAggInterestAndAccountForTroveChange(TroveChange calldata _troveChange, address _batchAddress)`
- **Purpose**: Called at the end of every operation that changes Trove state (open, adjust, close, liquidation, redemption, batch operations, pending application), and centralizes both final aggregate-interest minting and reflection of the operation's net debt/weighted-debt changes into aggregate trackers.
- **Authorization**: BorrowerOperations or TroveManager only (`_requireCallerIsBOorTroveM`). Actual callers: all BO Trove operations (openTrove family / adjustTrove family / closeTrove / applyPendingDebt / rate adjustment / batch join/leave / interest batch management operation), and TM `batchLiquidateTroves` / `redeemCollateral` / `urgentRedemption`.
- **Preconditions (Checks)**: caller validation only (TroveChange consistency is caller BO/TM responsibility).
- **Behavior (Effects)** (code execution order):
  1. If `_batchAddress != address(0)`, first run batch management fee handling (internal `_mintBatchManagementFeeAndAccountForChange` from CORE-AP-FR-009, including `aggRecordedDebt += batchAccruedManagementFee`).
  2. Run `_mintAggInterest(_troveChange.upfrontFee)` (same internal process as CORE-AP-FR-007: mint/distribute pending aggregate interest + upfront fee 75/25, update `lastAggUpdateTime`) and start adding the returned total minted amount to aggregate debt.
  3. `aggRecordedDebt = aggRecordedDebt + mintedAmount + appliedRedistJpydfDebtGain + debtIncrease - debtDecrease` (computed as increase then decrease to avoid underflow and optimize to one SLOAD/SSTORE each).
  4. `aggWeightedDebtSum = aggWeightedDebtSum + newWeightedRecordedDebt - oldWeightedRecordedDebt`.
- **Revert / early return**: invalid caller → `"ActivePool: Caller is neither BorrowerOperations nor TroveManager"`. If decreases exceed increases, Solidity 0.8 checked arithmetic reverts (Panic 0x11; does not occur for correct TroveChange).
- **Emitted events**: `AggregateInterestMinted` may be emitted through CORE-AP-FR-007 when `mintedAmount > 0`; `BatchManagementFeeMinted` may be emitted through CORE-AP-FR-009 when `batchAccruedManagementFee > 0`. Tracker update events are also emitted.
- **Design notes**: 1. Net Trove debt change consists of "issuance/repayment (debtIncrease/debtDecrease) + applied redistribution debt gain (appliedRedistJpydfDebtGain)" and **does not include accrued interest of the individual Trove** (individual interest is handled through aggregate interest to avoid double counting). 2. Repayments can have positive or negative net effect depending on redistribution gain vs repayment amount, so the API accepts both increase and decrease rather than signed integers. 3. Upfront fee is added to borrower debt and immediately minted/distributed like interest at the 75/25 split. 4. Batch fee handling (step 1) comes first because it updates `aggRecordedDebt`, which step 3 then reads.
- **Verification**: parity / invariant=CORE-SYS-INV-001

#### CORE-AP-FR-009: `mintBatchManagementFeeAndAccountForChange` (Finalize/Mint Batch Management Fee and Reflect Aggregation) 🔵
- **Type**: Functional / **Source**: base implementation (ActivePool.sol)
- **Signature**: `mintBatchManagementFeeAndAccountForChange(TroveChange calldata _troveChange, address _batchAddress)`
- **Purpose**: Finalize accrued management fee for a batch (Troves under an interest batch manager), mint it as JPYdf to the batch manager, and update batch-fee aggregate trackers.
- **Authorization**: external entry point is TroveManager only (`_requireCallerIsTroveManager`). Call sites: TM liquidation (when liquidating a batched Trove) and redemption (when redeeming against a batched Trove). The same internal process also runs through CORE-AP-FR-008 when `_batchAddress != 0` (BO/TM).
- **Preconditions (Checks)**: caller validation only.
- **Behavior (Effects)** (internal `_mintBatchManagementFeeAndAccountForChange`):
  1. `aggRecordedDebt += _troveChange.batchAccruedManagementFee` — account the fee applied to this batch (folded into recorded debt) in aggregate debt.
  2. `aggBatchManagementFees = aggBatchManagementFees + calcPendingAggBatchManagementFee() - batchAccruedManagementFee` — finalize all-batch pending fees and remove the amount applied this time from the "unapplied" balance (increase then decrease).
  3. `aggWeightedBatchManagementFeeSum = aggWeightedBatchManagementFeeSum + newWeightedRecordedBatchManagementFee - oldWeightedRecordedBatchManagementFee`.
  4. If `batchAccruedManagementFee > 0`, `jpydfToken.mint(_batchAddress, batchAccruedManagementFee)` — immediately mint fee to batch manager.
  5. If `batchAccruedManagementFee > 0`, emit `BatchManagementFeeMinted(jpydfToken, _batchAddress, batchAccruedManagementFee)`.
  6. `lastAggBatchManagementFeesUpdateTime = block.timestamp`.
- **Revert / early return**: invalid caller → `"ActivePool: Caller is not TroveManager"`. Underflow in checked arithmetic is as in CORE-AP-FR-008.
- **Emitted events**: `BatchManagementFeeMinted` from ActivePool. JpydfToken Transfer also occurs.
- **Design notes**: Batch management fee increases borrower debt (batch recorded debt) and mints the same amount as JPYdf income to the batch manager. `aggBatchManagementFees` is the balance of fees that are finalized but not yet applied to Trove recorded debt; at application time it is moved to `aggRecordedDebt` (system debt total = CORE-AP-FR-006 remains preserved). Unlike interest (75/25 split), batch fee is minted entirely to the individual batch manager. `BatchManagementFeeMinted` is the primary evidence for including or excluding batch manager fees in external accounting without confusing them with protocol revenue.
- **Verification**: parity / unit (applied amount reclassification and mint amount)

#### CORE-AP-FR-010: `sendColl` (External Collateral Send) 🔵
- **Type**: Functional / **Source**: base implementation (ActivePool.sol)
- **Signature**: `sendColl(address _account, uint256 _amount)`
- **Purpose**: Send active collateral to a specified address and subtract it from accounting balance. This is the only generic path for collateral to leave the branch.
- **Authorization**: BorrowerOperations, TroveManager, or StabilityPool only (`_requireCallerIsBOorTroveMorSP`). Actual callers and transfer directions:
  - BO: sends collateral to borrower (configured recipient) on collateral withdrawal and closeTrove.
  - TM: sends collateral gas compensation to liquidator during liquidation, moves liquidation surplus to CollSurplusPool, and sends redemption / urgent redemption collateral to redeemer.
  - SP: receives collateral into SP itself during liquidation offset (SP calls `sendColl(address(this), ...)`).
- **Preconditions (Checks)**: caller validation. `_amount ≤ collBalance` (implicitly enforced by checked arithmetic).
- **Behavior (Effects)**:
  1. `collBalance -= _amount`, emit `ActivePoolCollBalanceUpdated(newCollBalance)` (internal `_accountForSendColl`).
  2. Send actual tokens with `collToken.safeTransfer(_account, _amount)`.
- **Revert / early return**: invalid caller → `"ActivePool: Caller is neither BorrowerOperations nor TroveManager nor StabilityPool"`. `_amount > collBalance` → Panic 0x11 (underflow). Token transfer failure → SafeERC20 revert.
- **Emitted events**: CORE-AP-EVT-007 (`ActivePoolCollBalanceUpdated`).
- **Design notes**: Follows CEI order: accounting decrement (Effects) then external send (Interactions). Collateral token is dToken ([dToken.md](dToken.md)) and treated as a standard ERC-20 without transfer hooks.
- **Verification**: parity / invariant=CORE-AP-INV-001

#### CORE-AP-FR-011: `sendCollToDefaultPool` (Move Redistribution Collateral to DefaultPool) 🔵
- **Type**: Functional / **Source**: base implementation (ActivePool.sol)
- **Signature**: `sendCollToDefaultPool(uint256 _amount)`
- **Purpose**: During liquidation redistribution, remove redistributed collateral from active accounting and move it to DefaultPool.
- **Authorization**: TroveManager only (`_requireCallerIsTroveManager`). Call site: TM `_redistributeDebtAndColl` (redistribution of liquidation portion not offset by SP). Paired with debt-side `DefaultPool.increaseJpydfDebt` = CORE-DP-FR-004.
- **Preconditions (Checks)**: caller validation. `_amount ≤ collBalance` (checked arithmetic).
- **Behavior (Effects)**:
  1. `collBalance -= _amount`, emit `ActivePoolCollBalanceUpdated` (same internal function as CORE-AP-FR-010).
  2. Call `IDefaultPool(defaultPoolAddress).receiveColl(_amount)` — DefaultPool accounts the receipt and pulls actual tokens from ActivePool with `safeTransferFrom` using the constructor approve (CORE-AP-FR-001; CORE-DP-FR-003).
- **Revert / early return**: invalid caller → `"ActivePool: Caller is not TroveManager"`. Insufficient balance → Panic 0x11.
- **Emitted events**: CORE-AP-EVT-007, followed by CORE-DP-EVT-005 on DefaultPool side.
- **Design notes**: Transfer occurs in two stages, "sender accounting decrement → receiver accounting increment + pull," keeping both Pool accounting trackers consistent in the same tx.
- **Verification**: parity / invariant=CORE-AP-INV-001 / CORE-SYS-INV-007

#### CORE-AP-FR-012: `receiveColl` (Receive Collateral: Accounting Increment + Pull) 🔵
- **Type**: Functional / **Source**: base implementation (ActivePool.sol)
- **Signature**: `receiveColl(uint256 _amount)`
- **Purpose**: Receive collateral from the caller (pull) and add it to accounting balance.
- **Authorization**: BorrowerOperations or DefaultPool only (`_requireCallerIsBorrowerOperationsOrDefaultPool`). In actual code, the only caller is DefaultPool `sendCollToActivePool` (CORE-DP-FR-002; collateral return when applying redistribution gains). BO is permitted but uses direct transfer + CORE-AP-FR-013.
- **Preconditions (Checks)**: caller validation. Caller has approved ActivePool for at least `_amount` (DefaultPool sets infinite approve in its constructor).
- **Behavior (Effects)**:
  1. `collBalance += _amount`, emit `ActivePoolCollBalanceUpdated` (internal `_accountForReceivedColl`).
  2. Pull actual tokens with `collToken.safeTransferFrom(msg.sender, address(this), _amount)`.
- **Revert / early return**: invalid caller → `"ActivePool: Caller is neither BO nor Default Pool"`. Insufficient allowance / balance → SafeERC20 revert.
- **Emitted events**: CORE-AP-EVT-007.
- **Verification**: parity / invariant=CORE-AP-INV-001

#### CORE-AP-FR-013: `accountForReceivedColl` (Account for Collateral Already Sent Directly) 🔵
- **Type**: Functional / **Source**: base implementation (ActivePool.sol)
- **Signature**: `accountForReceivedColl(uint256 _amount)` (public)
- **Purpose**: Add only accounting balance, assuming actual tokens have **already** been transferred directly to ActivePool. Accounting-only version of receiveColl with no token movement.
- **Authorization**: BorrowerOperations or DefaultPool only (same require as CORE-AP-FR-012). In actual code, caller is BO `_pullCollAndSendToActivePool` (borrower collateral deposit: BO directly sends `collToken.safeTransferFrom(borrower, activePool, amount)`, then calls this function to sync accounting).
- **Preconditions (Checks)**: caller validation. The corresponding actual tokens have already been sent in the same tx (caller responsibility. ActivePool does not verify actual balance).
- **Behavior (Effects)**: `collBalance += _amount`, emit `ActivePoolCollBalanceUpdated`.
- **Revert / early return**: invalid caller → `"ActivePool: Caller is neither BO nor Default Pool"`.
- **Emitted events**: CORE-AP-EVT-007.
- **Design notes**: Gas optimization that uses one borrower → AP transferFrom instead of borrower → BO → AP two-stage transfer or approve roundtrip. Consistency between accounting and actual balance is entrusted to the trusted caller (BO), which underpins the accounting policy that "collBalance is a tracked value, not necessarily the actual balance" (CORE-AP-INV-001).
- **Verification**: parity / invariant=CORE-AP-INV-001

#### CORE-AP-FR-014: `setShutdownFlag` (Record Shutdown Timestamp and Permanently Stop Interest Accumulation) 🔵
- **Type**: Functional / **Source**: base implementation (ActivePool.sol)
- **Signature**: `setShutdownFlag()`
- **Purpose**: Propagate branch shutdown to ActivePool interest accounting and stop future aggregate interest accrual.
- **Authorization**: TroveManager only (`_requireCallerIsTroveManager`). Only call path: `BO.shutdown()` when TCR < SCR → `BO._applyShutdown()` → `TM.shutdown()` → this function. Recoverable oracle-failure pause does not reach TM/AP shutdown.
- **Preconditions (Checks)**: caller validation only. ActivePool has no double-set guard (BO-side `hasBeenShutDown` guard ensures only one actual reach. TM.shutdown is BO-only).
- **Behavior (Effects)**: `shutdownTime = block.timestamp`.
- **Revert / early return**: invalid caller → `"ActivePool: Caller is not TroveManager"`.
- **Emitted events**: none.
- **Design notes**: After shutdown, interest accounting behaves as follows. 1. `BO._applyShutdown` calls `mintAggInterest()` (CORE-AP-FR-007) **before** setting the flag, so pending aggregate interest through shutdown is finalized and minted in the same tx with no omission. 2. After flag is set, `calcPendingAggInterest()` is permanently 0 (CORE-AP-FR-002), so no new interest is minted even if `mintAggInterest` / `mintAggInterestAndAccountForTroveChange` are called later (updating `lastAggUpdateTime` and reflecting TroveChange debt/weighted values still work). 3. Batch management fees are not automatically finalized at shutdown, and `calcPendingAggBatchManagementFee()` continues to return "amount accrued up to shutdown" with the shutdown timestamp as period cap (CORE-AP-FR-004). 4. Individual Trove interest on TroveManager side is also cut off at shutdown timestamp (TM scope).
- **Verification**: parity / unit (0 interest after shutdown and batch-fee cutoff)

#### CORE-AP-FR-015: Self-Evident View Function Group 🔵
- **Type**: Functional / **Source**: base implementation (ActivePool.sol)
- **Signature**: table below (all view, no arguments, no permission)
- **Purpose**: Provide automatic getters for public state variables and simple read functions.

| Function | Meaning of return value |
| --- | --- |
| `NAME()` | Fixed string `"ActivePool"` |
| `collToken()` / `borrowerOperationsAddress()` / `troveManagerAddress()` / `defaultPoolAddress()` / `jpydfToken()` / `interestRouter()` / `stabilityPool()` | Wiring addresses fixed in constructor (CORE-AP-FR-001) |
| `getCollBalance()` | Accounting collateral balance `collBalance`. May differ from actual token balance (direct transfers are not reflected) |
| `aggRecordedDebt()` / `aggWeightedDebtSum()` / `lastAggUpdateTime()` | Aggregate interest accounting trackers (see state variable table) |
| `aggBatchManagementFees()` / `aggWeightedBatchManagementFeeSum()` / `lastAggBatchManagementFeesUpdateTime()` | Batch management fee accounting trackers |
| `shutdownTime()` | Shutdown timestamp (0 = not shut down) |
| `hasBeenShutDown()` | `shutdownTime != 0` |

- **Verification**: parity


### DefaultPool Functional Requirements (`CORE-DP-FR-*`)

#### CORE-DP-FR-001: Constructor (Address Wiring and Collateral Approve to ActivePool) 🔵
- **Type**: Functional / **Source**: base implementation (DefaultPool.sol)
- **Signature**: `constructor(IAddressesRegistry _addressesRegistry)`
- **Purpose**: Fix wiring addresses as immutables and open the collateral transfer path to ActivePool.
- **Authorization**: once at deployment.
- **Preconditions (Checks)**: none (trusts AddressesRegistry).
- **Behavior (Effects)**:
  1. Retrieve and fix `collToken` / `troveManagerAddress` / `activePoolAddress`.
  2. Emit 3 address-change events (CollToken / TroveManager / ActivePool, in that order).
  3. `collToken.approve(activePoolAddress, type(uint256).max)` — infinite approve allowing ActivePool to pull collateral from DefaultPool with `receiveColl` (CORE-AP-FR-012).
- **Revert / early return**: none.
- **Emitted events**: CORE-DP-EVT-001-003.
- **Verification**: parity / deployment test

#### CORE-DP-FR-002: `sendCollToActivePool` (Return Pending Collateral to ActivePool) 🔵
- **Type**: Functional / **Source**: base implementation (DefaultPool.sol)
- **Signature**: `sendCollToActivePool(uint256 _amount)`
- **Purpose**: When a Trove's pending redistribution collateral gain is applied, remove that amount from DefaultPool accounting and move it to ActivePool.
- **Authorization**: TroveManager only (`_requireCallerIsTroveManager`). Call site: TM `_movePendingTroveRewardsToActivePool` (all paths involving pending application: liquidation, redemption, all BO-mediated Trove operations, applyPendingDebt, etc. Paired with debt-side CORE-DP-FR-005).
- **Preconditions (Checks)**: caller validation. `_amount ≤ collBalance` (checked arithmetic).
- **Behavior (Effects)**:
  1. `collBalance -= _amount`, emit `DefaultPoolCollBalanceUpdated(newCollBalance)`.
  2. Call `IActivePool(activePoolAddress).receiveColl(_amount)` — ActivePool accounts the increment and pulls actual tokens using this contract's approve (CORE-DP-FR-001; CORE-AP-FR-012).
- **Revert / early return**: invalid caller → `"DefaultPool: Caller is not the TroveManager"`. Insufficient balance → Panic 0x11.
- **Emitted events**: CORE-DP-EVT-005, followed by CORE-AP-EVT-007 on ActivePool side.
- **Design notes**: Symmetric with CORE-AP-FR-011 (AP→DP) as a two-stage "sender accounting decrement → receiver accounting increment + pull" structure.
- **Verification**: parity / invariant=CORE-DP-INV-001

#### CORE-DP-FR-003: `receiveColl` (Receive Redistribution Collateral) 🔵
- **Type**: Functional / **Source**: base implementation (DefaultPool.sol)
- **Signature**: `receiveColl(uint256 _amount)`
- **Purpose**: Receive collateral moved from ActivePool during liquidation redistribution and add it to accounting balance.
- **Authorization**: ActivePool only (`_requireCallerIsActivePool`). Only call site: `ActivePool.sendCollToDefaultPool` (CORE-AP-FR-011).
- **Preconditions (Checks)**: caller validation. ActivePool has approved DefaultPool for at least `_amount` (infinite approve set in CORE-AP-FR-001).
- **Behavior (Effects)**:
  1. `collBalance += _amount`.
  2. Pull actual tokens from ActivePool with `collToken.safeTransferFrom(msg.sender, address(this), _amount)`.
  3. Emit `DefaultPoolCollBalanceUpdated(newCollBalance)`.
- **Revert / early return**: invalid caller → `"DefaultPool: Caller is not the ActivePool"`. Allowance/balance shortage → SafeERC20 revert.
- **Emitted events**: CORE-DP-EVT-005.
- **Verification**: parity / invariant=CORE-DP-INV-001

#### CORE-DP-FR-004: `increaseJpydfDebt` (Account Redistribution Debt) 🔵
- **Type**: Functional / **Source**: base implementation (DefaultPool.sol)
- **Signature**: `increaseJpydfDebt(uint256 _amount)`
- **Purpose**: Account the debt portion of liquidation redistribution as "unapplied pending debt."
- **Authorization**: TroveManager only. Call site: TM `_redistributeDebtAndColl` (paired with collateral-side CORE-AP-FR-011. TM simultaneously updates per-unit-staked accumulators such as L_jpydfDebt).
- **Preconditions (Checks)**: caller validation only.
- **Behavior (Effects)**: `JpydfDebt += _amount`, emit `DefaultPoolJpydfDebtUpdated(JpydfDebt)`.
- **Revert / early return**: invalid caller → `"DefaultPool: Caller is not the TroveManager"`.
- **Emitted events**: CORE-DP-EVT-004.
- **Design notes**: JpydfDebt is a pure accounting value; there are no corresponding JPYdf tokens (book value of debt redistributed after liquidation/burn/SP offset). The amount removed from ActivePool `aggRecordedDebt` is accounted here and written back when applied (CORE-AP-FR-008 `appliedRedistJpydfDebtGain`).
- **Verification**: parity / invariant=CORE-SYS-INV-001

#### CORE-DP-FR-005: `decreaseJpydfDebt` (Draw Down Applied Debt) 🔵
- **Type**: Functional / **Source**: base implementation (DefaultPool.sol)
- **Signature**: `decreaseJpydfDebt(uint256 _amount)`
- **Purpose**: When a Trove applies pending redistribution debt gain (folds it into its recorded debt), draw down that amount from the unapplied balance.
- **Authorization**: TroveManager only. Call site: TM `_movePendingTroveRewardsToActivePool` (paired with collateral-side CORE-DP-FR-002).
- **Preconditions (Checks)**: caller validation. `_amount ≤ JpydfDebt` (checked arithmetic).
- **Behavior (Effects)**: `JpydfDebt -= _amount`, emit `DefaultPoolJpydfDebtUpdated(JpydfDebt)`.
- **Revert / early return**: invalid caller → `"DefaultPool: Caller is not the TroveManager"`. Excess drawdown → Panic 0x11.
- **Emitted events**: CORE-DP-EVT-004.
- **Verification**: parity

#### CORE-DP-FR-006: Self-Evident View Function Group 🔵
- **Type**: Functional / **Source**: base implementation (DefaultPool.sol)
- **Signature**: table below (all view, no permission)

| Function | Meaning of return value |
| --- | --- |
| `NAME()` | Fixed string `"DefaultPool"` |
| `collToken()` / `troveManagerAddress()` / `activePoolAddress()` | Wiring addresses fixed in constructor |
| `getCollBalance()` | Accounting pending collateral balance `collBalance` (may differ from actual token balance) |
| `getJpydfDebt()` | JPYdf debt awaiting redistribution, `JpydfDebt`. Second term in `LiquityBase.getEntireBranchDebt` |

- **Verification**: parity


### CollSurplusPool Functional Requirements (`CORE-CSP-FR-*`)

#### CORE-CSP-FR-001: Constructor (Address Wiring) 🔵
- **Type**: Functional / **Source**: base implementation (CollSurplusPool.sol)
- **Signature**: `constructor(IAddressesRegistry _addressesRegistry)`
- **Purpose**: Fix wiring addresses as immutables.
- **Authorization**: once at deployment.
- **Preconditions (Checks)**: none (trusts AddressesRegistry).
- **Behavior (Effects)**: Retrieve and fix `collToken` / `borrowerOperationsAddress` / `troveManagerAddress`. Emit 2 address-change events (BO / TM). **No approve is performed** (payouts are push transfers, so approve is unnecessary).
- **Revert / early return**: none.
- **Emitted events**: CORE-CSP-EVT-001-002.
- **Verification**: parity / deployment test

#### CORE-CSP-FR-002: `accountSurplus` (Record Liquidation Surplus) 🔵
- **Type**: Functional / **Source**: base implementation (CollSurplusPool.sol)
- **Signature**: `accountSurplus(address _account, uint256 _amount)`
- **Purpose**: Record surplus collateral from liquidation as claimable balance for `_account` (the Trove owner at liquidation time).
- **Authorization**: TroveManager only (`_requireCallerIsTroveManager`). Call site: TM liquidation (`_liquidate`; surplus amount is determined by TM offset/redistribution calculation).
- **Preconditions (Checks)**: caller validation only (`_amount > 0` is guaranteed by TM-side branch).
- **Behavior (Effects)**:
  1. `balances[_account] += _amount`.
  2. `collBalance += _amount`.
  3. Emit `CollBalanceUpdated(_account, newAmount)`.
- **Revert / early return**: invalid caller → `"CollSurplusPool: Caller is not TroveManager"`.
- **Emitted events**: CORE-CSP-EVT-003.
- **Design notes**: This function only records accounting; it does **not** receive actual tokens. Corresponding actual tokens are batch-sent by TM within the same liquidation tx using `ActivePool.sendColl(collSurplusPool, totalCollSurplus)` (CORE-AP-FR-010), so accounting and actual balance match by tx completion (accounting precedes token receipt during the tx). Balances accumulate; if the same owner is liquidated multiple times, amounts are added.
- **Verification**: parity / invariant=CORE-CSP-INV-001

#### CORE-CSP-FR-003: `claimColl` (Claim and Pay Out Surplus Collateral) 🔵
- **Type**: Functional / **Source**: base implementation (CollSurplusPool.sol)
- **Signature**: `claimColl(address _account)`
- **Purpose**: Pay out the full claimable balance of `_account` to that account.
- **Authorization**: BorrowerOperations only (`_requireCallerIsBorrowerOperations`). The only call path is `BO.claimCollateral()`, and BO passes `msg.sender` as `_account`; therefore **only the beneficiary can claim their own balance, and only to their own address** (no recipient override is provided).
- **Preconditions (Checks)**:
  - Caller is BO.
  - `claimableColl = balances[_account] > 0`.
- **Behavior (Effects)**:
  1. `balances[_account] = 0`, emit `CollBalanceUpdated(_account, 0)` (full claim only; partial claim not possible).
  2. `collBalance -= claimableColl`, emit `CollSent(_account, claimableColl)`.
  3. Send actual tokens with `collToken.safeTransfer(_account, claimableColl)`.
- **Revert / early return**: invalid caller → `"CollSurplusPool: Caller is not Borrower Operations"`. Zero balance → `"CollSurplusPool: No collateral available to claim"`. Transfer failure → SafeERC20 revert.
- **Emitted events**: CORE-CSP-EVT-003 / CORE-CSP-EVT-004.
- **Design notes**: CEI order (zero balance before transfer) prevents double claim via reentrancy. Collateral dToken is an ERC-20 without transfer hooks, but the ordering is also safe. There is no claim deadline; funds are held indefinitely.
- **Verification**: parity / unit (zero-balance revert, full payout, second claim revert)

#### CORE-CSP-FR-004: Self-Evident View Function Group 🔵
- **Type**: Functional / **Source**: base implementation (CollSurplusPool.sol)
- **Signature**: table below (all view, no permission)

| Function | Meaning of return value |
| --- | --- |
| `NAME()` | Fixed string `"CollSurplusPool"` |
| `collToken()` / `borrowerOperationsAddress()` / `troveManagerAddress()` | Wiring addresses fixed in constructor |
| `getCollBalance()` | Accounting total surplus collateral `collBalance` (may differ from actual token balance) |
| `getCollateral(_account)` | Claimable balance `balances[_account]` for `_account`. Used by frontends for "claimable amount" display |

- **Verification**: parity


### GasPool Functional Requirements (`CORE-GP-FR-*`)

#### CORE-GP-FR-001: Constructor (Infinite WETH Approve to BO and TM) 🔵
- **Type**: Functional / **Source**: base implementation (GasPool.sol)
- **Signature**: `constructor(IAddressesRegistry _addressesRegistry)`
- **Purpose**: Permanently establish WETH gas compensation payout paths using only approval setup at deployment.
- **Authorization**: once at deployment.
- **Preconditions (Checks)**: none (trusts AddressesRegistry).
- **Behavior (Effects)**:
  1. Retrieve `WETH = _addressesRegistry.WETH()` and BorrowerOperations / TroveManager addresses (all local variables; stores nothing).
  2. `WETH.approve(borrowerOperations, type(uint256).max)` — lets BO refund gas compensation to borrower (recipient) when closing a Trove.
  3. `WETH.approve(troveManager, type(uint256).max)` — lets TM pay gas compensation to liquidator during liquidation.
- **Revert / early return**: none.
- **Emitted events**: none from GasPool itself (only WETH-side Approval).
- **Design notes**: Because it has no functions and no state, post-deployment attack surface is zero. Only BO / TM approved by the contract can move WETH, and their transferFrom conditions (refund on close, payment on liquidation) serve as practical access control. No way exists to revoke or reset approve (consistent with immutable core wiring). WETH or other tokens mistakenly sent directly cannot be recovered. Balance flow rules (open +`ETH_GAS_COMPENSATION` / close and liquidation -`ETH_GAS_COMPENSATION`) are specified in BO / TM scopes.
- **Verification**: parity / deployment test (approve value = type(uint256).max for both BO and TM)


### SortedTroves Functional Requirements (`CORE-ST-FR-*`)

#### CORE-ST-FR-001: Constructor (Address Binding and Sentinel Node Initialization) 🔵
- **Type**: Functional / **Source**: base implementation (SortedTroves.sol)
- **Signature**: `constructor(IAddressesRegistry _addressesRegistry)`
- **Purpose**: Bind write-authorized parties (BO/TM) as immutables from AddressesRegistry and initialize the sentinel node.
- **Authorization**: part of deployment procedure.
- **Preconditions (Checks)**: none (no input validation. AddressesRegistry wiring correctness depends on deployment procedure).
- **Behavior (Effects)**:
  1. `nodes[ROOT_NODE_ID].nextId = nodes[ROOT_NODE_ID].prevId = ROOT_NODE_ID` (sentinel self-loop = empty list. Technically redundant as long as ROOT_NODE_ID is 0, but set explicitly).
  2. Read `troveManager` / `borrowerOperationsAddress` from AddressesRegistry and fix as immutables.
  3. Emit `TroveManagerAddressChanged` / `BorrowerOperationsAddressChanged`.
- **Revert / early return**: none.
- **Emitted events**: CORE-ST-EVT-001 / CORE-ST-EVT-002.
- **Verification**: parity / deployment test.

#### CORE-ST-FR-002: `insert` (Insert Non-Batch Node) 🔵
- **Type**: Functional / **Source**: base implementation (SortedTroves.sol)
- **Signature**: `insert(uint256 _id, uint256 _annualInterestRate, uint256 _prevId, uint256 _nextId)`
- **Purpose**: Add a new Trove (non-batch) at the correct interest-rate-ordered position in the list. Uses: BO `openTrove`, batch leave (`_removeFromBatch`), and normal return of zombie Trove (`_reInsertIntoSortedTroves`).
- **Authorization**: **BorrowerOperations only** (`_requireCallerIsBorrowerOperations`).
- **Preconditions (Checks)**:
  - `!contains(_id)` (not an existing node).
  - `_id != ROOT_NODE_ID` (0 is sentinel ID and cannot be used).
  - Does not verify that `_id` is an existing Trove (trusts caller BO).
- **Behavior (Effects)**:
  1. Validate hint `(_prevId, _nextId)` with `_validInsertPosition` (CORE-ST-FR-008). If invalid, re-search from the hint using `_findInsertPosition` (CORE-ST-FR-009) (**invalid hints do not revert**; hints only save gas).
  2. Relink and insert at the determined position as a one-node slice (head=tail=`_id`) (`_insertSliceIntoVerifiedPosition`: update 4 links prev.next→id, id.prev→prev, id.next→next, next.prev→id).
  3. `nodes[_id].exists = true`, `++size` (`batchId` remains 0 = non-batch).
- **Revert / early return**: non-BO → `"SortedTroves: Caller is not BorrowerOperations"`; existing node → `"SortedTroves: List already contains the node"`; `_id == 0` → `"SortedTroves: _id cannot be the root node's ID"`.
- **Emitted events**: none.
- **Design notes**: **Insertion among equal interest rates** — validity is asymmetric: prev side allows `rate(prev) >= newRate` (equal allowed), while next side requires `newRate > rate(next)` (strict). Therefore a new node cannot be inserted **before** existing equal-rate nodes (head side); it is always inserted immediately after the equal-rate node group (tail side). Redemption processes from tail (lowest interest), so **among equal rates, later entrants are redeemed first** (last-in, first-redeemed). This ordering discipline prevents later entrants from jumping behind existing same-rate Troves into a safer redemption position.
- **Verification**: parity, invariant=CORE-ST-INV-001 / CORE-ST-INV-002 / CORE-ST-INV-004.

#### CORE-ST-FR-003: `remove` (Remove Non-Batch Node) 🔵
- **Type**: Functional / **Source**: base implementation (SortedTroves.sol)
- **Signature**: `remove(uint256 _id)`
- **Purpose**: Remove a non-batch node from the list. Uses: BO only when switching to batch (`setInterestBatchManager`). TM for zombie transition due to redemption (remaining debt below `MIN_DEBT`; value in [Parameters.md](../../../Parameters.md)) and liquidation/close (`_closeTrove`; owner `closeTrove` also follows this path).
- **Authorization**: **BorrowerOperations or TroveManager** (`_requireCallerIsBOorTM`).
- **Preconditions (Checks)**:
  - `contains(_id)` (exists in list).
  - `!isBatchedNode(_id)` (batch nodes must use `removeFromBatch()`).
- **Behavior (Effects)**:
  1. Connect previous and next nodes directly and remove the one-node slice from the list (`_removeSlice`).
  2. `delete nodes[_id]` (clears all fields including exists), `--size`.
- **Revert / early return**: non-BO/TM → `"SortedTroves: Caller is not BorrowerOperations nor TroveManager"`; nonexistent → `"SortedTroves: List does not contain the id"`; batch node → `"SortedTroves: Must use removeFromBatch() to remove batched node"`.
- **Emitted events**: none.
- **Verification**: parity, invariant=CORE-ST-INV-002 / CORE-ST-INV-004.

#### CORE-ST-FR-004: `reInsert` (Reinsert Non-Batch Node After Interest-Rate Change) 🔵
- **Type**: Functional / **Source**: base implementation (SortedTroves.sol)
- **Signature**: `reInsert(uint256 _id, uint256 _newAnnualInterestRate, uint256 _prevId, uint256 _nextId)`
- **Purpose**: Move a Trove after an interest-rate change to the position matching the new rate. Use: BO `adjustTroveInterestRate`.
- **Authorization**: **BorrowerOperations only**.
- **Preconditions (Checks)**:
  - `contains(_id)`.
  - `!isBatchedNode(_id)` (individual reInsert of a batch node is impossible. Whole batch is CORE-ST-FR-007).
- **Behavior (Effects)**:
  1. Validate hint and re-search if invalid (same rules as CORE-ST-FR-002, based on new rate `_newAnnualInterestRate`).
  2. If the determined position is the current position (determined `nextId` is the node itself, or determined `prevId` is the node itself = immediately before/after the slice), perform **no link changes** (no-op).
  3. Only if position changes, remove the slice (`_removeSlice`; internal links in the removed slice are preserved) and insert at the new position.
- **Revert / early return**: non-BO → `"SortedTroves: Caller is not BorrowerOperations"`; nonexistent → `"SortedTroves: List does not contain the id"`; batch node → `"SortedTroves: Must not reInsert() batched node"`.
- **Emitted events**: none.
- **Design notes**: Equal-rate positioning is the same as CORE-ST-FR-002, so a Trove changed into an equal-rate band is also placed on the tail side of the existing equal-rate node group (first in redemption order). At call time, the rate on the TM side may still be the old rate. Search is performed **before** removing the slice, so the old rate of the self node may be referenced during scanning; if the resulting position is adjacent to self, the no-op check absorbs it, and final ordering is consistent with argument `_newAnnualInterestRate`.
- **Verification**: parity, invariant=CORE-ST-INV-001 / CORE-ST-INV-002.

#### CORE-ST-FR-005: `insertIntoBatch` (Add Node to Batch) 🔵
- **Type**: Functional / **Source**: base implementation (SortedTroves.sol)
- **Signature**: `insertIntoBatch(uint256 _troveId, BatchId _batchId, uint256 _annualInterestRate, uint256 _prevId, uint256 _nextId)`
- **Purpose**: Add a Trove to a batch slice. Uses: BO `openTroveAndJoinInterestBatchManager` / `setInterestBatchManager` / batch return of zombie Trove (`_reInsertIntoSortedTroves`).
- **Authorization**: **BorrowerOperations only**.
- **Preconditions (Checks)**:
  - `!contains(_troveId)`.
  - `_troveId != ROOT_NODE_ID`.
  - `_batchId.isNotZero()` (BatchId=0 is reserved to mean "non-batch").
- **Behavior (Effects)**:
  1. **If the batch is empty (`batches[_batchId].tail == UNINITIALIZED_ID`)**: use hints and `_annualInterestRate` (batch rate) to perform normal position search and insert as a one-node slice; set `batches[_batchId].head = _troveId` (initialize batch).
  2. **If the batch is non-empty**: directly link immediately after current batch tail (between `batchTail` and `nodes[batchTail].nextId`) **without validation** (in this path `_annualInterestRate` and hints are not used. All batch members share the batch rate, so appending after tail preserves ordering).
  3. In both cases, set `batches[_batchId].tail = _troveId` (**new member is always at the batch slice tail**).
  4. `nodes[_troveId].batchId = _batchId`, `exists = true`, `++size`.
- **Revert / early return**: non-BO → `"SortedTroves: Caller is not BorrowerOperations"`; existing node → `"SortedTroves: List already contains the node"`; `_troveId == 0` → `"SortedTroves: _troveId cannot be the root node's ID"`; `_batchId == 0` → `"SortedTroves: _batchId cannot be zero"`.
- **Emitted events**: none.
- **Design notes**: Within a batch, "new participant goes to tail side," matching the equal-rate rule for the whole list (CORE-ST-FR-002). The batch slice tail is closer to the list tail (lowest-rate end), so **within the same batch, later joiners are redeemed first**.
- **Verification**: parity, invariant=CORE-ST-INV-001 / CORE-ST-INV-003 / CORE-ST-INV-004.

#### CORE-ST-FR-006: `removeFromBatch` (Remove Batch Node) 🔵
- **Type**: Functional / **Source**: base implementation (SortedTroves.sol)
- **Signature**: `removeFromBatch(uint256 _id)`
- **Purpose**: Remove a node belonging to a batch from both the list and the batch. Uses: BO batch leave (`_removeFromBatch`), TM zombie transition due to redemption, liquidation, and close (`_closeTrove`).
- **Authorization**: **BorrowerOperations or TroveManager**.
- **Preconditions (Checks)**:
  - `nodes[_id].batchId.isNotZero()` (nonzero batchId doubles as existence check. Non-batch and nonexistent nodes both fail here).
- **Behavior (Effects)**:
  1. If it is the only member (`batch.head == _id && batch.tail == _id`), `delete batches[batchId]` (batch becomes empty and can be reinitialized later by `insertIntoBatch` with the same BatchId).
  2. If `_id` is batch head, set `batches[batchId].head = nodes[_id].nextId`; if batch tail, set `batches[batchId].tail = nodes[_id].prevId` (move slice endpoints inward).
  3. Remove the node from the slice (`_removeSlice`), `delete nodes[_id]`, `--size`.
- **Revert / early return**: non-BO/TM → `"SortedTroves: Caller is not BorrowerOperations nor TroveManager"`; non-batch node (including nonexistent) → `"SortedTroves: Must use remove() to remove non-batched node"`.
- **Emitted events**: none.
- **Verification**: parity, invariant=CORE-ST-INV-002 / CORE-ST-INV-003 / CORE-ST-INV-004.

#### CORE-ST-FR-007: `reInsertBatch` (Reinsert Entire Batch Slice) 🔵
- **Type**: Functional / **Source**: base implementation (SortedTroves.sol)
- **Signature**: `reInsertBatch(BatchId _id, uint256 _newAnnualInterestRate, uint256 _prevId, uint256 _nextId)`
- **Purpose**: On batch manager interest-rate change, move all batch members (slice `[head..tail]`) **in bulk while preserving internal adjacency and order** to the position matching the new rate. Use: BO `setBatchManagerAnnualInterestRate` (called only when batch is non-empty).
- **Authorization**: **BorrowerOperations only**.
- **Preconditions (Checks)**:
  - `batches[_id].head != UNINITIALIZED_ID` (batch exists = non-empty).
- **Behavior (Effects)**:
  1. Validate hints at the new rate, and re-search if invalid (CORE-ST-FR-008/009).
  2. If determined position is current (`nextId == slice head` or `prevId == slice tail`), no-op.
  3. If position changes, remove the whole slice `[batch.head .. batch.tail]` (member links are preserved) and insert it in one step at the new position. `batches[_id]` head/tail are unchanged (slice internals do not change).
- **Revert / early return**: non-BO → `"SortedTroves: Caller is not BorrowerOperations"`; batch nonexistent (empty) → `"SortedTroves: List does not contain the batch"`.
- **Emitted events**: none.
- **Design notes**: Slice movement completes by changing 4 endpoint links and is **O(1), independent of batch member count**. This is the gas-design core of cheap batch-wide interest-rate changes. Equal-rate discipline is also the same as CORE-ST-FR-002 (insert on the tail side of existing equal-rate nodes/batches).
- **Verification**: parity, invariant=CORE-ST-INV-001 / CORE-ST-INV-003.

#### CORE-ST-FR-008: `validInsertPosition` (Validate Hint Position) 🔵
- **Type**: Functional / **Source**: base implementation (SortedTroves.sol)
- **Signature**: `validInsertPosition(uint256 _annualInterestRate, uint256 _prevId, uint256 _nextId) → bool` (external view wrapper around internal `_validInsertPosition`)
- **Purpose**: Determine whether the gap between `(_prevId, _nextId)` is valid for inserting a node with interest rate `_annualInterestRate`. Norm for hint validation in insertion/reinsertion paths (CORE-ST-FR-002/004/005/007).
- **Authorization**: none (view).
- **Behavior (decision rule)**: true only if **all** of the following hold:
  1. **Adjacent**: `nodes[_prevId].nextId == _nextId` and `nodes[_nextId].prevId == _prevId`.
  2. **Not inside a batch**: `_prevId` and `_nextId` do not belong to the same nonzero batch (`prevBatchId != nextBatchId || prevBatchId == 0`). Inserting another node in the middle of a batch slice would break contiguity (CORE-ST-INV-003).
  3. **Interest-rate order**: `_prevId == ROOT_NODE_ID` (insert at head) or `rate(_prevId) >= _annualInterestRate`, **and** `_nextId == ROOT_NODE_ID` (insert at tail) or `_annualInterestRate > rate(_nextId)` (`rate` = `troveManager.getTroveAnnualInterestRate`).
- **Revert / early return**: none (returns bool only).
- **Design notes**: The **asymmetry** of rate conditions (prev side `>=`, next side `>`) uniquely determines equal-rate placement: a new node can have an equal-rate existing node as `prev`, but not as `next`, so **only the position immediately after the equal-rate group (tail side) is valid**. In an empty list, sentinel self-loop makes `(0, 0)` valid. Because sentinel (ROOT) is exempt from rate comparison, head and tail insertions are handled by the same rule.
- **Verification**: parity, unit (empty list, head, tail, equal rate, batch boundary).

#### CORE-ST-FR-009: `findInsertPosition` (Find Insertion Position and Hint Fallback) 🔵
- **Type**: Functional / **Source**: base implementation (SortedTroves.sol)
- **Signature**: `findInsertPosition(uint256 _annualInterestRate, uint256 _prevId, uint256 _nextId) → (uint256 prevId, uint256 nextId)` (external view wrapper around internal `_findInsertPosition`)
- **Purpose**: Starting from hints, return a valid insertion position for interest rate `_annualInterestRate`. Optimized for the assumption that at most one original adjacent hint node has moved/deleted, but **always returns the correct position regardless of hint quality or intervening transactions**. The external wrapper is mainly for off-chain use (frontend: refine approximate hint from `HintHelpers.getApproxHint`).
- **Authorization**: none (view).
- **Behavior (search procedure)**:
  1. `_prevId == ROOT_NODE_ID` ("before head" hint) → immediately **descend** from head (ignore `_nextId`).
  2. Otherwise, if `_prevId` is nonexistent or `rate(_prevId) < _annualInterestRate`, invalidate `_prevId` (`BAD_HINT`).
  3. `_nextId == ROOT_NODE_ID` ("after tail" hint) → immediately **ascend** from tail (regardless of `_prevId` validity).
  4. Otherwise, if `_nextId` is nonexistent or `_annualInterestRate <= rate(_nextId)`, invalidate `_nextId`.
  5. Both hints invalid → descend from head (**full-scan fallback**, worst-case O(n)).
  6. Only `_prevId` invalid → ascend from the head of `_nextId`'s batch.
  7. Only `_nextId` invalid → descend from the tail of `_prevId`'s batch.
  8. Both hints valid → advance descending (from `_prevId` batch tail) and ascending (from `_nextId` batch head) **one step alternately**, returning whichever side determines a position first (betting that at least one hint is near the answer).
- **Stop condition**: descending = "next is ROOT, or `_annualInterestRate > rate(next)`"; ascending = "prev is ROOT, or `rate(prev) >= _annualInterestRate`" (equivalent to the rate condition in CORE-ST-FR-008). Therefore the returned position is always valid and, for equal rates, resolves immediately after the equal-rate group.
- **Scan unit**: one step skips an entire batch as a unit (`_skipToBatchTail`/`_skipToBatchHead`). Because batch members share the same rate, intra-batch comparison is unnecessary; search cost is proportional to "number of non-batch nodes + number of batches," not total node count. Each step performs one external staticcall to TM for rate lookup.
- **Revert / early return**: none (`assert(false)` at end of `_descendAndAscendList` is unreachable defense).
- **Verification**: parity, unit (4 hint invalidation branches and bidirectional convergence), fuzz (result is always valid for arbitrary hints).

#### CORE-ST-FR-010: Listing View Functions and Automatic Getter Group 🔵
- **Type**: Functional / **Source**: base implementation (SortedTroves.sol)
- **Signature**: table below (all view; no state change; no revert)
- **Purpose**: Provide list traversal, existence checks, and structural references to external consumers (TM redemption loop, BO, HintHelpers / MultiTroveGetter / DebtInFrontHelper / RedemptionHelper, frontend).

| Function | Meaning of return value |
| --- | --- |
| `contains(_id)` | `nodes[_id].exists`. List-membership check (zombie Trove is false) |
| `isBatchedNode(_id)` | `nodes[_id].batchId != 0`. Batch-membership check |
| `isEmptyBatch(_id)` | `batches[_id].head == 0`. Whether the batch is empty (including uninitialized) |
| `isEmpty()` | `size == 0` |
| `getSize()` | `size` (same as public variable `size()` getter) |
| `getFirst()` | `nodes[0].nextId` = head (**highest interest rate**). 0 when empty |
| `getLast()` | `nodes[0].prevId` = tail (**lowest interest rate**). 0 when empty |
| `getNext(_id)` | `nodes[_id].nextId` = next (toward lower rates). 0 (ROOT) at tail |
| `getPrev(_id)` | `nodes[_id].prevId` = previous (toward higher rates). 0 (ROOT) at head |
| `NAME()` | constant `"SortedTroves"` |
| `size()` / `nodes(uint256)` / `batches(BatchId)` / `borrowerOperationsAddress()` / `troveManager()` | Automatic getters for public state variables (see §7 table) |

- **Design notes**: Traversal terminates when `getNext`/`getPrev` returns `ROOT_NODE_ID` (=0). `getFirst`/`getLast` also return 0 for an empty list, so callers must treat 0 as "no node."
- **Verification**: parity.


### TroveNFT Functional Requirements (`CORE-TN-FR-*`)

#### CORE-TN-FR-001: Constructor (Derive name/symbol and Bind Addresses) 🔵/🟡
- **Type**: Functional / **Source**: OZ ERC721 + DF deployed surface (JPYdfTroveNFT.sol; CORE-MOD-007)
- **Signature**: `constructor(IAddressesRegistry _addressesRegistry)`
- **Purpose**: Bind TM, collateral token, MetadataNFT, and JpydfToken from AddressesRegistry as immutables, and determine collection name from collateral token.
- **Authorization**: part of deployment procedure.
- **Behavior (Effects)**:
  1. Deployed DF surface passes `name = "JPYdf - " + collToken.name()` and `symbol = "JPYdf_" + collToken.symbol()` to the ERC721 constructor (**read collateral token name()/symbol() at deployment and fix thereafter**).
  2. Fix `troveManager` / `collToken` / `metadataNFT` / `jpydfToken` as immutables.
- **Revert / early return**: none (deployment fails if collToken name()/symbol() calls fail).
- **Emitted events**: none.
- **Design notes**: In jpydf, collToken = dToken ([dToken.md](dToken.md)), so collection name follows dToken name/symbol. dToken names are finalized by delayed initialization with `setTokenInfo` after deployment, so **TroveNFT deployment order affects the final name** (CORE-TN-TBD-001). The DF deployed surface changes only collection metadata and not ownership semantics.
- **Verification**: deployment test / 🟡 delta test (name/symbol are `JPYdf - ...` / `JPYdf_...`).

#### CORE-TN-FR-002: `mint` (Issue NFT on Trove Open) 🔵/🟡
- **Type**: Functional / **Source**: OZ v4.9 ERC721 + DF deployed surface (JPYdfTroveNFT.sol; CORE-MOD-007)
- **Signature**: `mint(address _owner, uint256 _troveId)`
- **Purpose**: Issue NFT with tokenId = troveId to owner when a Trove is opened. Call sites: TM `onOpenTrove` / `onOpenTroveAndJoinBatch` (both BO-originated).
- **Authorization**: **TroveManager only** (`_requireCallerIsTroveManager`).
- **Preconditions (Checks)** (from OZ `_mint`):
  - `_owner != address(0)`.
  - tokenId `_troveId` has not been issued.
- **Behavior (Effects)**:
  1. `_mint(_owner, _troveId)`: `_balances[_owner] += 1`, `_owners[_troveId] = _owner`.
  2. Emit `Transfer(address(0), _owner, _troveId)`.
- **Revert / early return**: non-TM → `JPYdfTroveNFT__CallerIsNotTroveManager()`; `_owner == 0` → `"ERC721: mint to the zero address"`; already issued → `"ERC721: token already minted"`.
- **Emitted events**: CORE-TN-EVT-001 (Transfer, from=0).
- **Design notes**: Uses **`_mint`**, not `_safeMint`; recipient `onERC721Received` is not called during mint. This avoids introducing recipient callbacks (reentrancy or opening DoS by receiver refusal) into the openTrove flow, and contracts that do not implement ERC721Receiver can own Troves.
- **Verification**: parity for ownership behavior, unit (TM-only and no double mint), 🟡 delta test for custom error.

#### CORE-TN-FR-003: `burn` (Burn NFT on Trove Close or Liquidation) 🔵/🟡
- **Type**: Functional / **Source**: OZ v4.9 ERC721 + DF deployed surface (JPYdfTroveNFT.sol; CORE-MOD-007)
- **Signature**: `burn(uint256 _troveId)`
- **Purpose**: Burn NFT at Trove terminal states (owner close / liquidation). Call site: TM `_closeTrove` (paths where status becomes `closedByOwner` / `closedByLiquidation`). Zombie transition does not burn.
- **Authorization**: **TroveManager only**.
- **Preconditions (Checks)** (from OZ `_burn`): tokenId `_troveId` exists (`ownerOf` resolvable).
- **Behavior (Effects)**:
  1. `_burn(_troveId)`: clear per-token approval, `_balances[owner] -= 1`, `delete _owners[_troveId]`.
  2. Emit `Transfer(owner, address(0), _troveId)`.
- **Revert / early return**: non-TM → `JPYdfTroveNFT__CallerIsNotTroveManager()`; nonexistent token → `"ERC721: invalid token ID"`.
- **Emitted events**: CORE-TN-EVT-001 (Transfer, to=0).
- **Verification**: parity for ownership behavior, unit (TM-only and nonexistent burn revert), 🟡 delta test for custom error.

#### CORE-TN-FR-004: `tokenURI` (On-Chain Metadata via MetadataNFT Delegation) 🔵
- **Type**: Functional / **Source**: DF deployed surface (JPYdfTroveNFT.sol)
- **Signature**: `tokenURI(uint256 _tokenId) → string` (public view, override of `ERC721`/`IERC721Metadata`)
- **Purpose**: Return metadata URI reflecting current Trove status with **no external dependency (fully on-chain)**.
- **Authorization**: none (view).
- **Preconditions (Checks)**: NFT `_tokenId` exists (`ownerOf` does not revert).
- **Behavior (Effects)**:
  1. Retrieve latest Trove state (including interest and redistribution in `entireColl` / `entireDebt` / `annualInterestRate`) with `troveManager.getLatestTroveData(_tokenId)`.
  2. Build `IMetadataNFT.TroveData`: `_tokenId`, `_owner = ownerOf(_tokenId)`, `_collToken` (dToken address), `_jpydfToken`, `_collAmount = entireColl`, `_debtAmount = entireDebt`, `_interestRate = annualInterestRate`, `_status = troveManager.getTroveStatus(_tokenId)`.
  3. Return `metadataNFT.uri(troveData)` as-is (`data:application/json;base64,...`; CORE-TN-FR-006).
- **Revert / early return**: nonexistent token → `"ERC721: invalid token ID"` (from `ownerOf`).
- **Emitted events**: none (view).
- **Design notes**: Values are computed dynamically at call time, so the same token follows changes in debt/coll/rate/status (zombie NFT remains alive and status displays "Below Min Debt"). Collateral amount displays the raw dToken-denominated 18-decimal value ([dToken.md](dToken.md)).
- **Verification**: parity, unit (by status, zombie, nonexistent revert).

#### CORE-TN-FR-005: ERC-721 Standard Surface (Transfer, Approval, Query, ERC-165) 🔵
- **Type**: Functional / **Source**: base implementation (inherits OZ v4.9 ERC721)
- **Signature**: `transferFrom` / `safeTransferFrom` (2 overloads) / `approve` / `setApprovalForAll` / `getApproved` / `isApprovedForAll` / `balanceOf` / `ownerOf` / `name` / `symbol` / `supportsInterface`
- **Purpose**: Provide fully ERC-721-compliant ownership, approval, and transfer. **NFT transfer = Trove ownership transfer itself** (after transfer, only the new holder can operate the Trove through BO. See BO section for ownership checks and add/remove manager handling).
- **Authorization**: ERC-721 standard (owner / approved / operator).
- **Behavior (Effects)**: OZ v4.9 `ERC721` standard implementation unchanged. There are **no** behavior-changing overrides, transfer hooks, or pause mechanism. `supportsInterface` returns true for `IERC721` / `IERC721Metadata` / `IERC165`.
- **Revert / early return**: OZ v4.9 standard require strings (`"ERC721: caller is not token owner or approved"`, `"ERC721: invalid token ID"`, `"ERC721: transfer to non ERC721Receiver implementer"` for safe variants, etc.).
- **Design notes**: No nonstandard behavior. Trove-specific constraints (closed Troves have burned NFTs and therefore cannot transfer, etc.) are all derived from lifecycle synchronization of mint/burn (CORE-TN-FR-002/003); no custom checks are added on transfer paths.
- **Verification**: parity (ERC-721 standard behavior).

#### CORE-TN-FR-006: JPYdfMetadataNFT — On-Chain Metadata Rendering (Catalog) 🔵/🟡
- **Type**: Functional / **Source**: DF deployed metadata surface (`Interfaces/IMetadataNFT.sol` / `NFTMetadata/JPYdfMetadataNFT.sol` / `JPYdfBaseSVG.sol`; CORE-MOD-007)
- **Signature**: `uri(TroveData memory _troveData) → string` (public view)
- **Purpose**: Given TroveData, generate ERC-721 metadata JSON (including SVG image) fully on-chain. Rendering-only contract called by TroveNFT for each `tokenURI` (no state changes).
- **Input**: `IMetadataNFT.TroveData { uint256 _tokenId; address _owner; address _collToken; address _jpydfToken; uint256 _collAmount; uint256 _debtAmount; uint256 _interestRate; ITroveManager.Status _status }`
- **Output**: `data:application/json;base64,<base64(JSON)>`. JSON contents:
  - `name`: `"JPYdf - " + collToken.name()` (retrieved dynamically at call time).
  - `description`: fixed JPYdf text ("JPYdf is a collateralized debt protocol. Users can lock up <symbol> to mint JPYdf...").
  - `image`: `data:image/svg+xml;base64,<base64(SVG)>` — 300×484 card SVG. Fixed elements (background, Geist font read from SSTORE2, labels "Collateral"/"Debt"/"Interest Rate"/"Owner", JPYdf debt mark in the deployed variant) + deterministic bauhaus geometric pattern generated from the collateral symbol hash and tokenId + dynamic text (abbreviated troveId `0x1234...abcd`, owner address, collateral logo only when a fixed asset is registered, status display, and numeric debt/coll/rate values)
  - `attributes`: 6 items — `Collateral Token` (address hex) / `Collateral Amount` (raw decimal value) / `Debt Token` (address hex) / `Debt Amount` (raw decimal value) / `Interest Rate` (raw 1e18-scaled value) / `Status` (string)
- **Status string map** (`_status2Str`): `active` → `"Active"`, `closedByOwner` → `"Closed"`, `closedByLiquidation` → `"Liquidated"`, `zombie` → `"Below Min Debt"`, other (`nonExistent`) → `""` (effectively unreachable through tokenURI because burned tokens revert first).
- **Revert / early return**: none (view, except collToken name()/symbol() failure).
- **Composition (catalog)**: `utils/` contains rendering libraries and is not individually specified — `JSON.sol` (json: metadata JSON assembly and base64 encode) / `SVG.sol` (svg: SVG element DSL) / `JPYdfBaseSVG.sol` (deployed JPYdf fixed card layout and debt mark) / `bauhaus.sol` (geometric pattern generation) / `Utils.sol` (utils/numUtils: string and numeric formatting using Solady `LibString`) / `FixedAssets.sol` (`FixedAssetReader`: reads fixed assets such as the Geist font, JPYdf logo, and registered collateral logos from SSTORE2 pointer ranges registered in constructor by `bytes4 → {start, end}` through `readAsset(bytes4)`. Unregistered collateral logos are omitted from the SVG).
- **Helper views**: `attributes(TroveData)` (public pure; attributes JSON fragment) / `dynamicTextComponents(TroveData)` (public view; SVG dynamic section) — public exposure of `uri` internal components. `assetReader()` (immutable getter).
- **Design notes**: MetadataNFT is immutably injected into TroveNFT through AddressesRegistry and cannot be replaced from TroveNFT. Rendering is entirely pure/view composition and has no path affecting core accounting. The DF variant changes product-facing JSON/SVG text only.
- **Verification**: deployment/unit tests for `JPYdfMetadataNFT` output, 🟡 delta test (JPYdf wording), parity for data sources and status/attribute shape.


### JpydfToken Functional Requirements (`CORE-BT-FR-*`)

#### CORE-BT-FR-001: Constructor (Deployment Initialization) 🔵
- **Type**: Functional / **Source**: base implementation (JpydfToken.sol)
- **Signature**: `constructor(address _owner)`
- **Purpose**: Fix ERC-20 metadata, EIP-712 domain, and initial Owner, and launch the system's only JPYdf token.
- **Authorization**: once at deployment.
- **Preconditions (Checks)**: none (no zero check for `_owner`. Validity is ensured by deployment procedure).
- **Behavior (Effects)**:
  1. `Ownable(_owner)`: set `_owner` as Owner and emit `OwnershipTransferred(address(0), _owner)`.
  2. `ERC20(_NAME, _SYMBOL)`: fix name/symbol.
  3. `ERC20Permit(_NAME)`: construct and cache EIP-712 domain (name=`_NAME`, version=`"1"`, chainId, self address) as immutable (OZ v4.9.5. Name is 31 bytes or shorter and stored as ShortString).
- **Revert / early return**: none (OZ `ShortStrings` could revert with `StringTooLong(string)` only if name/version exceed 31 bytes, but fixed values are 16 bytes / 1 byte and unreachable).
- **Emitted events**: `OwnershipTransferred` (CORE-BT-EVT-008).
- **Verification**: parity (base identity of post-deployment state. name/symbol value excluded as CORE-MOD-001 delta).

#### CORE-BT-FR-002: `setBranchAddresses` (Register Branch Contract Permissions) 🔵/🟡
- **Type**: Functional / Governance / **Source**: base implementation + CORE-MOD-009 hardening (JpydfToken.sol)
- **Signature**: `setBranchAddresses(address _troveManagerAddress, address _stabilityPoolAddress, address _borrowerOperationsAddress, address _activePoolAddress)`
- **Purpose**: Register one branch's TM / SP / BO / AP into permission sets for mint, burn, and related functions. Called once per branch.
- **Authorization**: `onlyOwner`.
- **Preconditions (Checks)**: caller is Owner. Each of `_troveManagerAddress`, `_stabilityPoolAddress`, `_borrowerOperationsAddress`, and `_activePoolAddress` must be nonzero and have deployed code. Duplicate addresses and semantic branch-type mismatches are not validated by the token.
- **Behavior (Effects)**:
  1. `troveManagerAddresses[_troveManagerAddress] = true` → emit `TroveManagerAddressAdded`.
  2. `stabilityPoolAddresses[_stabilityPoolAddress] = true` → emit `StabilityPoolAddressAdded`.
  3. `borrowerOperationsAddresses[_borrowerOperationsAddress] = true` → emit `BorrowerOperationsAddressAdded`.
  4. `activePoolAddresses[_activePoolAddress] = true` → emit `ActivePoolAddressAdded`.
- **Revert / early return**: non-Owner → `"Ownable: caller is not the owner"`; zero core address → `JpydfToken__ZeroCoreAddress`; codeless core address → `JpydfToken__CoreAddressMustBeContract`.
- **Emitted events**: CORE-BT-EVT-002-005.
- **Design notes**: This only adds to mappings (sets true); there is no deregistration path. Misregistration cannot be undone by code, so correctness depends on deployment scripts and verification procedures (CORE-BT-SEC-002). After `setCollateralRegistry` executes (= ownership renounce), the function becomes unreachable and new branches cannot be added to JpydfToken afterward.
- **Verification**: parity / unit (onlyOwner, contract-address checks, mapping reflection, events).

#### CORE-BT-FR-003: `setCollateralRegistry` (Set CR and Permanently Fix Permissions) 🔵/🟡
- **Type**: Functional / Governance / **Source**: base implementation + CORE-MOD-009 hardening (JpydfToken.sol)
- **Signature**: `setCollateralRegistry(address _collateralRegistryAddress)`
- **Purpose**: Set CollateralRegistry (burn caller during redemption) and renounce ownership in the same tx to complete and freeze deployment wiring.
- **Authorization**: `onlyOwner`.
- **Preconditions (Checks)**: caller is Owner. `_collateralRegistryAddress` must be nonzero and have deployed code.
- **Behavior (Effects)**:
  1. `collateralRegistryAddress = _collateralRegistryAddress` → emit `CollateralRegistryAddressChanged`.
  2. `_renounceOwnership()`: emit `OwnershipTransferred(old owner, address(0))` and set `_owner = address(0)`.
- **Revert / early return**: non-Owner → `"Ownable: caller is not the owner"`; zero core address → `JpydfToken__ZeroCoreAddress`; codeless core address → `JpydfToken__CoreAddressMustBeContract`.
- **Emitted events**: CORE-BT-EVT-001, CORE-BT-EVT-008.
- **Design notes**: "One-shot" is enforced not by a separate flag but by ownership renounce (after execution, all `onlyOwner` functions become permanently unreachable). This simultaneously closes `setBranchAddresses`, so this function must be called **after all branches are registered and at the end of deployment procedure**. Core wiring is immutable thereafter. The independent `bridgeAdmin` remains only for the dormant bridge-readiness surface and cannot change Core branch registration, `collateralRegistryAddress`, or Core `mint` / `burn` permissions.
- **Verification**: parity / unit (contract-address checks, set value, owner==0 after renounce, second call reverts).

#### CORE-BT-FR-004: `mint` (Issuance) 🔵
- **Type**: Functional / **Source**: base implementation (JpydfToken.sol)
- **Signature**: `mint(address _account, uint256 _amount)`
- **Purpose**: Issue JPYdf corresponding to debt creation or interest issuance.
- **Authorization**: registered BorrowerOperations **or** ActivePool only (`_requireCallerIsBOorAP`: `borrowerOperationsAddresses[msg.sender] || activePoolAddresses[msg.sender]`).
- **Preconditions (Checks)**: authorization above only (`_mint` internally requires `_account != address(0)`).
- **Behavior (Effects)**:
  1. `_mint(_account, _amount)`: `_account` balance +amount, `totalSupply` +amount.
  2. Emit ERC-20 `Transfer(address(0), _account, _amount)`.
- **Revert / early return**: unauthorized → `JpydfToken__CallerIsNotBorrowerOperationsOrActivePool`; `_account == address(0)` → `"ERC20: mint to the zero address"`.
- **Emitted events**: ERC-20 `Transfer` (mint, CORE-BT-EVT-006).
- **Design notes**: Implementation callers are limited to two paths: (a) BO borrowing / debt increase (issued to borrower), and (b) AP aggregate interest issuance (75% SP yield to SP, remainder to interestRouter) and batch management fee issuance. Bridge minters cannot call this Core `mint`; bridge supply is isolated to `bridgeMint` (CORE-BT-FR-015). See BO / AP sections. Confining Core supply increase to these two contract types is a prerequisite of JPYdf soundness (CORE-BT-SEC-001).
- **Verification**: parity / unit (permission revert and balance/supply reflection). Cross-contract supply/debt consistency is CORE-SYS-INV-003.

#### CORE-BT-FR-005: `burn` (Burn) 🔵
- **Type**: Functional / **Source**: base implementation (JpydfToken.sol)
- **Signature**: `burn(address _account, uint256 _amount)`
- **Purpose**: Burn JPYdf corresponding to repayment, redemption, or liquidation offset.
- **Authorization**: CollateralRegistry (`msg.sender == collateralRegistryAddress`) or registered BorrowerOperations / TroveManager / StabilityPool (`_requireCallerIsCRorBOorTMorSP`).
- **Preconditions (Checks)**: authorization above; `_account` balance ≥ `_amount` (ERC-20 internal check).
- **Behavior (Effects)**:
  1. `_burn(_account, _amount)`: `_account` balance -amount, `totalSupply` -amount.
  2. Emit ERC-20 `Transfer(_account, address(0), _amount)`.
- **Revert / early return**: unauthorized → `JpydfToken__CallerIsNotCoreBurner`; insufficient balance → `"ERC20: burn amount exceeds balance"`.
- **Emitted events**: ERC-20 `Transfer` (burn, CORE-BT-EVT-006).
- **Design notes**: It is a privileged burn independent of allowance, but implementation burn targets are limited to (a) BO: borrower repaying/closing (`msg.sender`), (b) TM: urgent-redemption executor after shutdown (`msg.sender`), (c) CR: redemption executor (`msg.sender`), and (d) SP: SP itself during liquidation offset (`address(this)`). Bridge minters cannot call this Core `burn`; bridge burn is the self-burn-only `bridgeBurn` (CORE-BT-FR-015). No core implementation path arbitrarily burns third-party balances (CORE-BT-SEC-003).
- **Verification**: parity / unit (4 permission paths and insufficient-balance revert).

#### CORE-BT-FR-006: `sendToPool` (Deposit Transfer to SP) 🔵
- **Type**: Functional / **Source**: base implementation (JpydfToken.sol)
- **Signature**: `sendToPool(address _sender, address _poolAddress, uint256 _amount)`
- **Purpose**: During SP deposit (`provideToSP`), internally transfer JPYdf from depositor to SP without allowance.
- **Authorization**: registered StabilityPool only (`_requireCallerIsStabilityPool`: `stabilityPoolAddresses[msg.sender]`).
- **Preconditions (Checks)**: authorization above; `_sender` balance ≥ `_amount`.
- **Behavior (Effects)**:
  1. `_transfer(_sender, _poolAddress, _amount)` (recipient restriction `_requireValidRecipient` is not applied = core internal transfer).
  2. Emit ERC-20 `Transfer(_sender, _poolAddress, _amount)`.
- **Revert / early return**: unauthorized → `JpydfToken__CallerIsNotStabilityPool`; insufficient balance → `"ERC20: transfer amount exceeds balance"`.
- **Emitted events**: ERC-20 `Transfer` (CORE-BT-EVT-006).
- **Design notes**: In implementation, SP calls only in the form `sendToPool(msg.sender, address(this), _topUp)` (depositor is the SP caller). Fixing `_poolAddress` to SP itself is caller-side discipline; this function does not validate the argument.
- **Verification**: parity / unit (SP-only and transfer reflection).

#### CORE-BT-FR-007: `returnFromPool` (Refund Transfer from SP) 🔵
- **Type**: Functional / **Source**: base implementation (JpydfToken.sol)
- **Signature**: `returnFromPool(address _poolAddress, address _receiver, uint256 _amount)`
- **Purpose**: During SP withdrawal (`withdrawFromSP`), internally transfer JPYdf from SP to depositor.
- **Authorization**: registered StabilityPool only (`_requireCallerIsStabilityPool`).
- **Preconditions (Checks)**: authorization above; `_poolAddress` balance ≥ `_amount`.
- **Behavior (Effects)**:
  1. `_transfer(_poolAddress, _receiver, _amount)`.
  2. Emit ERC-20 `Transfer(_poolAddress, _receiver, _amount)`.
- **Revert / early return**: unauthorized → `JpydfToken__CallerIsNotStabilityPool`; insufficient balance → ERC-20 revert.
- **Emitted events**: ERC-20 `Transfer` (CORE-BT-EVT-006).
- **Verification**: parity / unit (SP-only and transfer reflection).

#### CORE-BT-FR-008: `transfer` / `transferFrom` (ERC-20 Transfer with Recipient Restriction) 🔵
- **Type**: Functional / **Source**: base implementation (JpydfToken.sol)
- **Signature**: `transfer(address recipient, uint256 amount) → bool` / `transferFrom(address sender, address recipient, uint256 amount) → bool`
- **Purpose**: Add recipient validation to ERC-20 standard transfer, preventing permanent lockup from accidental sends.
- **Authorization**: permissionless (`transferFrom` requires allowance).
- **Preconditions (Checks)**: `_requireValidRecipient(recipient)`: `recipient != address(0) && recipient != address(this) && recipient != collateralRegistryAddress && !troveManagerAddresses[recipient] && !stabilityPoolAddresses[recipient] && !borrowerOperationsAddresses[recipient] && !activePoolAddresses[recipient]`. Then OZ ERC20 standard checks (balance and allowance).
- **Behavior (Effects)**:
  1. After recipient validation, delegate to `super.transfer` / `super.transferFrom` (balance transfer; `transferFrom` decreases allowance. `type(uint256).max` allowance is not decreased = OZ v4.9.5 standard).
  2. Emit ERC-20 `Transfer` (`Approval` may also be emitted if allowance changes in `transferFrom`).
- **Revert / early return**: recipient is zero, JpydfToken itself, CollateralRegistry, or a registered TroveManager / StabilityPool / BorrowerOperations / ActivePool → `JpydfToken__CannotTransferToProtocolContract`; insufficient balance / allowance → OZ ERC20 standard revert.
- **Emitted events**: ERC-20 `Transfer` / `Approval` (CORE-BT-EVT-006/007).
- **Design notes**: The recipient blacklist is user-protection only and applies to external `transfer` / `transferFrom` plus `bridgeMint`. Core internal `sendToPool` / `returnFromPool` intentionally bypass it because SP accounting transfers must move tokens to or from the StabilityPool itself.
- **Verification**: parity / unit (restriction revert and standard transfer).

#### CORE-BT-FR-009: ERC-20 Standard Compliance (approve / allowance / Balance and Supply Views) 🔵
- **Type**: Functional / **Source**: base implementation (inherits OZ v4.9.5 ERC20)
- **Signature**: `approve(address,uint256) → bool` / `increaseAllowance(address,uint256) → bool` / `decreaseAllowance(address,uint256) → bool` / `allowance(address,address) → uint256` / `balanceOf(address) → uint256` / `totalSupply() → uint256` / `decimals() → uint8`
- **Purpose**: Provide ERC-20 standard semantics. No JpydfToken-specific override.
- **Authorization**: permissionless.
- **Behavior (Effects)**: Fully follows OZ v4.9.5 `ERC20` standard implementation. `decimals()` is fixed 18. `decreaseAllowance` below current allowance reverts with `"ERC20: decreased allowance below zero"`; approving zero-address spender reverts with `"ERC20: approve to the zero address"`.
- **Revert / early return**: OZ standard.
- **Emitted events**: `Approval` (CORE-BT-EVT-007).
- **Design notes**: OZ v4.9 series exposes `increaseAllowance` / `decreaseAllowance` in the ABI (extensions removed in v5).
- **Verification**: parity (base identity of standard behavior).

#### CORE-BT-FR-010: `name` / `symbol` (Token Name and Symbol) 🟡
- **Type**: Functional / **Source**: DF modification (JpydfToken.sol `_NAME` / `_SYMBOL`) + OZ ERC20 metadata
- **Signature**: `name() → string` / `symbol() → string`
- **Purpose**: Return token metadata. Values are fixed by compile-time constants `_NAME` / `_SYMBOL`.
- **Authorization**: permissionless (view).
- **Behavior (Effects)**: `name()` returns `"JPYdf Stablecoin"` and `symbol()` returns `"JPYdf"` (no change mechanism).
- **Revert / early return**: none.
- **Emitted events**: none.
- **Delta from base**: base uses `_NAME = "BOLD Stablecoin"` / `_SYMBOL = "BOLD"`. DF uses `_NAME = "JPYdf Stablecoin"` / `_SYMBOL = "JPYdf"`. Rationale: CORE-MOD-001 (§2.2) (rename to the JPYdf token name. No effect on logic, storage, or permissions; impact is ERC-20 metadata and the EIP-712 domain name only = CORE-BT-FR-011).
- **Verification**: unit (fixed values). Excluded from parity as a value delta and traced as CORE-MOD-001.
- **Design notes**: `_NAME` is also passed to `ERC20Permit(_NAME)`, so the EIP-2612 signature domain name is `"JPYdf Stablecoin"` (not signature-compatible with a base deployment, but that is not an issue for an independent deployment).

#### CORE-BT-FR-011: `permit` (EIP-2612) and EIP-712 Domain View Group 🔵
- **Type**: Functional / **Source**: base implementation (inherits OZ v4.9.5 ERC20Permit / EIP712)
- **Signature**: `permit(address owner, address spender, uint256 value, uint256 deadline, uint8 v, bytes32 r, bytes32 s)` / `nonces(address owner) → uint256` / `DOMAIN_SEPARATOR() → bytes32` / `eip712Domain() → (bytes1, string, string, uint256, address, bytes32, uint256[])`
- **Purpose**: Provide signature-based allowance setting without prior approve (EIP-2612) and domain information required for signature generation (ERC-5267).
- **Authorization**: permissionless (signature validation only).
- **Preconditions (Checks)**: `block.timestamp <= deadline`; recovered signer from `ECDSA.recover` equals `owner` (consumes current nonce for `owner`).
- **Behavior (Effects)**:
  1. `_useNonce(owner)`: increment `nonces(owner)` by 1 (sequence enforcement and replay protection).
  2. `_approve(owner, spender, value)` → emit `Approval`.
- **Revert / early return**: expired deadline → `"ERC20Permit: expired deadline"`; signer mismatch (including nonce mismatch) → `"ERC20Permit: invalid signature"`.
- **Emitted events**: ERC-20 `Approval` (CORE-BT-EVT-007).
- **Design notes**: Domain is constructed in constructor from `(name=_NAME, version="1", chainId, address(this))` and cached as immutable (OZ v4.9.5; if chainId changes due to fork, it is rederived each time). `eip712Domain()` reports fields=`0x0f` (name/version/chainId/verifyingContract), with salt/extensions unused. `EIP712DomainChanged` appears in the ABI as an ERC-5267 interface event, but because the domain is immutable it is **never emitted**. The name value differs from base as a consequence of CORE-MOD-001; permit logic itself is identical to base.
- **Verification**: parity (signature validation, nonce, revert behavior), unit (`DOMAIN_SEPARATOR` derived from name=`_NAME`).

#### CORE-BT-FR-012: Self-Evident View Function Group (owner / isOwner / collateralRegistryAddress) 🔵
- **Type**: Functional / **Source**: base implementation (Ownable.sol / automatic getter)
- **Signatures and return values**:

  | Function | Meaning of return value |
  | --- | --- |
  | `owner() → address` | Current Owner. `address(0)` after `setCollateralRegistry` |
  | `isOwner() → bool` | `msg.sender == _owner` check (public view specific to Liquity Ownable) |
  | `collateralRegistryAddress() → address` | Configured CR (`address(0)` if unset) |
- **Authorization**: permissionless (view).
- **Verification**: parity.


#### CORE-BT-FR-013: `bridgeAdmin` and Bridge-Readiness Views 🟡
- **Type**: Functional / Governance / **Source**: CORE-MOD-008
- **Signatures**: `bridgeAdmin()`, `pendingBridgeAdmin()`, `proposedBridgeMinter()`, `bridgeMinterProposedAt()`, `bridgeMinterCount()`, `isBridgeMinter(address)`
- **Purpose**: Hold bridge-governance state independently from the Core owner and provide on-chain / manifest evidence that Day-1 is dormant (zero minters and no pending proposal).
- **Authorization**: view functions are permissionless. State changes are covered by CORE-BT-FR-014 and CORE-BT-FR-016.
- **Behavior (Effects)**: none for views. At construction, `bridgeAdmin = _bridgeAdmin`; all other bridge-readiness state is zero-initialized.
- **Design notes**: `bridgeAdmin` survives owner renounce because it is separate storage from Core owner. `bridgeAdmin` must be a contract address. Mainnet should use a Safe / Timelock holder and must not use the deployer address.
- **Verification**: unit (bridgeAdmin survives owner renounce, initial view values, contract-only admin).

#### CORE-BT-FR-014: Bridge Minter Registry (`propose` / `confirm` / `cancel` / `remove`) 🟡
- **Type**: Functional / Governance / **Source**: CORE-MOD-008
- **Signatures**: `proposeBridgeMinter(address)`, `confirmBridgeMinter()`, `cancelBridgeMinterProposal()`, `removeBridgeMinter(address)`
- **Purpose**: Add bridge adapters / minters behind a 48h timelock, while allowing immediate removal after compromise or misconfiguration.
- **Authorization**: `bridgeAdmin` only.
- **Preconditions (Checks)**:
  - `proposeBridgeMinter`: minter is nonzero, not the token itself, not current or pending `bridgeAdmin`, not already registered, no existing proposal, and a contract address.
  - `confirmBridgeMinter`: proposal exists, proposed minter is still not current or pending `bridgeAdmin`, proposed minter is still a contract address, and `block.timestamp >= bridgeMinterProposedAt + 48 hours`.
  - `cancelBridgeMinterProposal`: proposal exists.
  - `removeBridgeMinter`: minter is registered.
- **Behavior (Effects)**:
  - propose: set `proposedBridgeMinter` and `bridgeMinterProposedAt`.
  - confirm: set `bridgeMinterAddresses[minter] = true`, increment `bridgeMinterCount`, and clear proposal state.
  - cancel: clear proposal state.
  - remove: set `bridgeMinterAddresses[minter] = false` and decrement `bridgeMinterCount`.
- **Revert / early return**: non-admin → `JpydfToken__CallerIsNotBridgeAdmin`; timelock not elapsed → `JpydfToken__BridgeMinterTimelockNotElapsed`; other custom errors are cataloged in CORE-BT-ERR-001.
- **Emitted events**: CORE-BT-EVT-010.
- **Design notes**: `JpydfToken` does not introspect whether the proposed adapter has cap / rate / accounting / pause controls. Before `proposeBridgeMinter`, `bridgeAdmin` must approve the Stage A activation package in [Bridge-Minter-Activation-Gate](../../operations/runbooks/Bridge-Minter-Activation-Gate.md), then re-check the same evidence before `confirmBridgeMinter`. If adapter code, remote admin, endpoint config, chain status, or verification evidence drifts during the timelock, the proposal is cancelled and revalidated. Minter registration by itself does not enable operator-only canary, frontend / public routes, third-party access, or cap ramp; those remain Stage B / C gates, and operator-only canary requires an adapter / endpoint-enforced envelope rather than a UI / ops flag alone.
- **Verification**: unit (timelock boundary, cancel, remove, count/view, admin/minter separation).

#### CORE-BT-FR-015: `bridgeMint` / `bridgeBurn` (Bridge Supply Path) 🟡
- **Type**: Functional / **Source**: CORE-MOD-008
- **Signatures**: `bridgeMint(address _account, uint256 _amount)` / `bridgeBurn(uint256 _amount)`
- **Purpose**: Allow a future token-only canonical bridge to adjust source/destination supply through a registered bridge minter.
- **Authorization**: registered bridge minter only (`bridgeMinterAddresses[msg.sender]`).
- **Behavior (Effects)**:
  - `bridgeMint`: apply the same protocol-recipient blacklist used by external transfers, then `_mint(_account, _amount)`.
  - `bridgeBurn`: `_burn(msg.sender, _amount)`; the minter can only burn its own balance.
- **Revert / early return**: non-minter → `JpydfToken__CallerIsNotBridgeMinter`; mint to protocol recipient → `JpydfToken__CannotTransferToProtocolContract`; zero-address mint or insufficient burn balance uses OZ ERC-20 revert strings.
- **Emitted events**: `BridgeMint` / `BridgeBurn` and ERC-20 `Transfer`.
- **Design notes**: Bridge minters are not added to Core `mint` / `burn`. There is no arbitrary-address `bridgeBurn(address from, uint256 amount)`, which limits a compromised minter to minting and self-burning only. Bridge minters must be contract addresses and cannot also be `bridgeAdmin`.
- **Verification**: unit (non-minter revert, mint, self-burn, remove-after-confirm blocks further bridge calls, protocol-recipient reject).

#### CORE-BT-FR-016: Bridge Admin Transfer / Renounce 🟡
- **Type**: Functional / Governance / **Source**: CORE-MOD-008
- **Signatures**: `transferBridgeAdmin(address)`, `acceptBridgeAdmin()`, `renounceBridgeAdmin()`
- **Purpose**: Transfer `bridgeAdmin` with a two-step flow, and allow bridge readiness to be abandoned only when no live or pending bridge minter exists.
- **Authorization**: `transferBridgeAdmin` and `renounceBridgeAdmin` require current `bridgeAdmin`; `acceptBridgeAdmin` requires `pendingBridgeAdmin`.
- **Preconditions (Checks)**:
  - transfer: new admin is nonzero, not the token itself, not current owner, not a registered/proposed bridge minter, and a contract address.
  - accept: caller is pending admin, not a registered/proposed bridge minter, and a contract address.
  - renounce: `bridgeMinterCount == 0` and `proposedBridgeMinter == address(0)`.
- **Behavior (Effects)**: transfer sets `pendingBridgeAdmin`; accept moves pending into `bridgeAdmin` and clears pending; renounce clears `bridgeAdmin` and pending.
- **Revert / early return**: non-admin / non-pending / live minter / pending proposal revert with cataloged require strings.
- **Emitted events**: CORE-BT-EVT-010.
- **Verification**: unit (two-step transfer, non-pending reject, live-minter renounce reject, minter-zero renounce, admin/minter separation).


### CollateralRegistry Functional Requirements (`CORE-CR-FR-*`)

#### CORE-CR-FR-001: Constructor (Fix Branch Composition and Bootstrap `baseRate`) 🔵
- **Type**: Functional / **Source**: base implementation (CollateralRegistry.sol)
- **Signature**: `constructor(IJpydfToken _jpydfToken, IERC20Metadata[] memory _tokens, ITroveManager[] memory _troveManagers)`
- **Purpose**: Fix branch composition (collateral token × TroveManager pairs, max 10) and JPYdf reference as immutable, and initialize baseRate with bootstrap value.
- **Authorization**: once at deployment.
- **Preconditions (Checks)**:
  - `_tokens.length > 0` (empty list not allowed).
  - `_tokens.length <= 10` (max 10 branches).
  - `_troveManagers` length is not explicitly validated (if shorter than `_tokens`, array out-of-bounds panic reverts; if longer, excess entries are ignored).
- **Behavior (Effects)**:
  1. `totalCollaterals = _tokens.length`.
  2. `jpydfToken = _jpydfToken`.
  3. Fix each index value into `token0..token9` / `troveManager0..troveManager9` (slots beyond `numTokens` are `address(0)`).
  4. `baseRate = INITIAL_BASE_RATE` (=100%; value in §7) → emit `BaseRateUpdated`.
  5. `lastFeeOperationTime` is initialized to deployment timestamp by declaration initializer.
- **Revert / early return**: empty list → `"Collateral list cannot be empty"`; 11 or more → `"Collateral list too long"`.
- **Emitted events**: `BaseRateUpdated` (CORE-CR-EVT-001).
- **Design notes**: `INITIAL_BASE_RATE = 100%` is a bootstrap mechanism. Immediately after deployment, effective redemption rate is ≈100% (fee almost consumes the redeemed amount), making redemption economically infeasible. baseRate decays exponentially with 6h half-life (`REDEMPTION_MINUTE_DECAY_FACTOR`) and converges over days toward the floor (`REDEMPTION_FEE_FLOOR` = 0.5%), blocking peg pressure until the system stabilizes (Constants.sol comment: "prevent redemption until BOLD falls below 0.95").
- **Verification**: parity / unit (boundaries 1, 10, 11; initial baseRate; unused slots zero).

#### CORE-CR-FR-002: `redeemCollateral` (Cross-Branch Redemption) 🔵
- **Type**: Functional / **Source**: base implementation (CollateralRegistry.sol)
- **Signature**: `redeemCollateral(uint256 _jpydfAmount, uint256 _maxIterationsPerCollateral, uint256 _maxFeePercentage)`
- **Purpose**: Single entry point for the peg-maintenance mechanism that exchanges JPYdf for collateral at face value (1 JPYdf = 1 unit of target currency value). Routes requested amount to branches in proportion to unbacked portion, updates baseRate, and burns the actually redeemed JPYdf.
- **Authorization**: permissionless (executor must hold JPYdf to be burned).
- **Preconditions (Checks)**:
  - `REDEMPTION_FEE_FLOOR <= _maxFeePercentage <= DECIMAL_PRECISION` (`_requireValidMaxFeePercentage`).
  - `_jpydfAmount > 0` (`_requireAmountGreaterThanZero`).
  - Precomputed effective rate is at most `_maxFeePercentage`.
- **Behavior (Effects)** (code execution order):
  1. Loop all branches and call each TM's `getUnbackedPortionPriceAndRedeemability()` (**non-view** because it calls PriceFeed `fetchPrice` → [Oracle.md](Oracle.md)). Return values are (unbacked portion = positive part of branch total debt - SP deposits, price, redeemable = TCR ≥ SCR and not shut down). Only redeemable branches contribute `unbackedPortions[index]` and total `unbacked`; prices are stored for all branches.
  2. **Fallback**: if total unbacked is 0 (all redeemable branches are fully backed by SP), recompute weights from redeemable branches' `getEntireBranchDebt()` (switch to branch-size-proportional allocation).
  3. **Truncation**: if total unbacked is positive and `_jpydfAmount > unbacked`, truncate `_jpydfAmount = unbacked` (prevents imbalanced allocation from one-shot redemption above unbacked amount. Certora issue CS-BOLD-013 response. Remainder can be redeemed by another call).
  4. Store `jpydfSupplyAtStart = jpydfToken.totalSupply()` (before redemption burn).
  5. **Rate precomputation**: `redemptionRate = _calcRedemptionRate(_getUpdatedBaseRateFromRedemption(_jpydfAmount, jpydfSupplyAtStart))` = decay-applied baseRate plus "requested amount (post-truncation) / total supply / REDEMPTION_BETA" (capped at 100%), plus `REDEMPTION_FEE_FLOOR` (capped at 100%). Revert if `redemptionRate > _maxFeePercentage`.
  6. **Execute allocation**: for each branch, compute `redeemAmount = _jpydfAmount × unbackedPortions[index] / unbacked`; if positive, call `troveManager.redeemCollateral(msg.sender, redeemAmount, prices[index], redemptionRate, _maxIterationsPerCollateral)` and sum actual redeemed amount (`redeemedAmount` ≤ `redeemAmount`). After each loop, update residuals `_jpydfAmount -= redeemAmount` and `unbacked -= unbackedPortions[index]` so allocation total exactly matches requested amount including rounding residuals (fee collateral deduction and per-Trove redemption are TM scope).
  7. **Finalize baseRate**: `_updateBaseRateAndGetRedemptionRate(actual redeemed total, jpydfSupplyAtStart)` recomputes/saves baseRate based on the **actual redeemed amount** and emits `BaseRateUpdated`. Then `_updateLastFeeOpTime` advances `lastFeeOperationTime` by elapsed full minutes (does not update for <1 minute), emitting `LastFeeOpTimeUpdated` when updated.
  8. If actual redeemed total is positive, `jpydfToken.burn(msg.sender, actual redeemed total)` (CORE-BT-FR-005).
- **Revert / early return**:
  - `_maxFeePercentage` out of range → `"Max fee percentage must be between 0.5% and 100%"`.
  - `_jpydfAmount == 0` → `"CollateralRegistry: Amount must be greater than zero"`.
  - effective rate exceeded → `"CR: Fee exceeded provided maximum"`.
  - insufficient balance (burn) → `"ERC20: burn amount exceeds balance"`.
  - If there are no redeemable branches, the function still **does not early return**. Truncation (step 3) does not apply, so precomputed rate (step 5) is based on the **entire requested amount**; if `_maxFeePercentage` is low, it can revert with `"CR: Fee exceeded provided maximum"` **even with 0 actual redemption**. If fee check passes, it succeeds with zero allocation, baseRate updated by decay only (`BaseRateUpdated` emitted), and burn skipped.
- **Emitted events**: `BaseRateUpdated` (CORE-CR-EVT-001), `LastFeeOpTimeUpdated` (CORE-CR-EVT-002). Each TM emits Trove-level redemption events.
- **Design notes**:
  - **Unbacked-proportional allocation**: Branches with more debt not backed by SP receive more redemption. This directs redemption toward debt compression in riskier branches and is the core v2 design for smoothing branch health.
  - **Two-stage rate calculation**: fee-check rate is precomputed from requested amount and compared with `_maxFeePercentage`; state baseRate is finalized from actual redeemed amount. If actual redemption is smaller than requested, the redeemer pays the precomputed rate (code comments state that estimating optimal amount is the redeemer's responsibility).
  - `_maxIterationsPerCollateral = 0` is treated by TM as unlimited (see TM section). Used to cap Trove scans per branch for gas control.
  - This function is the only operation that updates baseRate (`lastFeeOperationTime` declaration comment mentioning "redemption or new Bold issuance" is a v1 remnant; v2 borrowing does not affect baseRate).
  - Minute-granularity decay rounding (`_updateLastFeeOpTime`) prevents baseRate griefing that would gain tiny decay increments through repeated redemptions less than a minute apart.
- **Verification**: parity (allocation, truncation, fallback, rate calculation, burn amount), invariant=CORE-CR-INV-001-003.

#### CORE-CR-FR-003: `getRedemptionRate` (Effective Rate at Current `baseRate`) 🔵
- **Type**: Functional / **Source**: base implementation (CollateralRegistry.sol)
- **Signature**: `getRedemptionRate() → uint256` (external view)
- **Purpose**: Return effective redemption rate based on the "baseRate at last update" without applying decay.
- **Behavior (Effects)**: Return `min(REDEMPTION_FEE_FLOOR + baseRate, DECIMAL_PRECISION)`.
- **Revert / early return**: none.
- **Verification**: parity.

#### CORE-CR-FR-004: `getRedemptionRateWithDecay` (Effective Rate After Applying Decay) 🔵
- **Type**: Functional / **Source**: base implementation (CollateralRegistry.sol)
- **Signature**: `getRedemptionRateWithDecay() → uint256` (public view)
- **Purpose**: Estimate time component of rate if redemption were performed now (does not include amount-based increment).
- **Behavior (Effects)**: Calculate `decayedBaseRate = baseRate × REDEMPTION_MINUTE_DECAY_FACTOR^(elapsed minutes) / 1e18` (elapsed minutes are floor minutes since `lastFeeOperationTime`), and return `min(REDEMPTION_FEE_FLOOR + decayedBaseRate, DECIMAL_PRECISION)`.
- **Revert / early return**: none.
- **Design notes**: `REDEMPTION_MINUTE_DECAY_FACTOR` is per-minute decay coefficient corresponding to 6h (=360 minutes) half-life (value in §7).
- **Verification**: parity.

#### CORE-CR-FR-005: `getRedemptionRateForRedeemedAmount` (Rate Estimate for Specified Redeem Amount) 🔵
- **Type**: Functional / **Source**: base implementation (CollateralRegistry.sol)
- **Signature**: `getRedemptionRateForRedeemedAmount(uint256 _redeemAmount) → uint256` (external view)
- **Purpose**: Estimate the effective rate (decay + amount-based increment) that would apply if `_redeemAmount` were redeemed now.
- **Behavior (Effects)**: Using current `jpydfToken.totalSupply()` as denominator, calculate `_getUpdatedBaseRateFromRedemption(_redeemAmount, totalSupply)` (= decayed baseRate + `_redeemAmount × 1e18 / totalSupply / REDEMPTION_BETA`, capped at 100%), then apply `_calcRedemptionRate` and return.
- **Revert / early return**: if `totalSupply == 0`, division-by-zero panic (not expected in operation).
- **Design notes**: During execution (CORE-CR-FR-002), calculation uses post-truncation requested amount and pre-execution supply, so estimate may not match exactly. Off-chain estimate view (no core caller).
- **Verification**: parity.

#### CORE-CR-FR-006: `getRedemptionFeeWithDecay` (Fee Calculation for Quantity) 🔵
- **Type**: Functional / **Source**: base implementation (CollateralRegistry.sol)
- **Signature**: `getRedemptionFeeWithDecay(uint256 _ETHDrawn) → uint256` (external view)
- **Purpose**: Return fee for a given quantity under decay-applied rate (`rate × _ETHDrawn / 1e18`).
- **Behavior (Effects)**: Return `_calcRedemptionFee(getRedemptionRateWithDecay(), _ETHDrawn)`.
- **Revert / early return**: none.
- **Design notes**: Argument name `_ETHDrawn` is inherited from v1; unit follows the quantity supplied by caller (if collateral quantity is passed, fee is collateral-denominated). Off-chain estimate view (no core caller).
- **Verification**: parity.

#### CORE-CR-FR-007: `getEffectiveRedemptionFeeInJpydf` (Effective Fee in JPYdf) 🔵
- **Type**: Functional / **Source**: base implementation (CollateralRegistry.sol)
- **Signature**: `getEffectiveRedemptionFeeInJpydf(uint256 _redeemAmount) → uint256` (external view)
- **Purpose**: Estimate fee denominated in JPYdf if `_redeemAmount` were redeemed now.
- **Behavior (Effects)**: Estimate updated baseRate using current supply (same calculation as CORE-CR-FR-005), then return `_calcRedemptionFee(_calcRedemptionRate(newBaseRate), _redeemAmount)`.
- **Revert / early return**: division-by-zero panic if `totalSupply == 0` (same as above).
- **Verification**: parity.

#### CORE-CR-FR-008: `getToken` / `getTroveManager` (index → branch reference) 🔵
- **Type**: Functional / **Source**: base implementation (CollateralRegistry.sol)
- **Signature**: `getToken(uint256 _index) → IERC20Metadata` (external view) / `getTroveManager(uint256 _index) → ITroveManager` (public view)
- **Purpose**: Return immutable collateral token / TroveManager reference for a branch index.
- **Behavior (Effects)**: Return the corresponding `tokenN` / `troveManagerN` for `_index` 0-9.
- **Revert / early return**: `_index >= 10` → `"Invalid index"` (literal `revert("Invalid index")`, not a require string). Note that unused slots where `totalCollaterals <= _index <= 9` return `address(0)` rather than reverting (callers are expected to bound by `totalCollaterals`).
- **Emitted events**: none.
- **Verification**: parity / unit (10+ revert and unused-slot zero return).

#### CORE-CR-FR-009: Self-Evident View Function Group (`baseRate` / `lastFeeOperationTime` / `totalCollaterals` / `jpydfToken`) 🔵
- **Type**: Functional / **Source**: base implementation (automatic getters for public variables)
- **Signatures and return values**:

  | Function | Meaning of return value |
  | --- | --- |
  | `baseRate() → uint256` | baseRate at last update (raw value without decay) |
  | `lastFeeOperationTime() → uint256` | Decay reference timestamp (advances only at minute granularity) |
  | `totalCollaterals() → uint256` | Number of branches (immutable after deployment) |
  | `jpydfToken() → IJpydfToken` | JPYdf token address |
- **Authorization**: permissionless (view).
- **Verification**: parity.


### AddressesRegistry Functional Requirements (`CORE-AR-FR-*`)

#### CORE-AR-FR-001: Constructor (Set Initial Risk Values and Lifecycle) 🔵/🟡
- **Type**: Functional / Governance / **Source**: base implementation (AddressesRegistry.sol) + CORE-MOD-013
- **Signature**: `constructor(address _owner, uint256 _ccr, uint256 _mcr, uint256 _bcr, uint256 _scr, uint256 _liquidationPenaltySP, uint256 _liquidationPenaltyRedistribution, address _riskParamsFinalizer)`
- **Purpose**: Range-check and store initial branch risk values, initializing active branches as finalized at deployment and reserved branches as awaiting one-shot finalization.
- **Authorization**: once at deployment.
- **Preconditions (Checks)** (custom errors; code order):
  1. `1e18 < _ccr < 2e18` (exclusive) or `InvalidCCR()`.
  2. `1e18 < _mcr < 2e18` or `InvalidMCR()`.
  3. `5e16 <= _bcr < 50e16` or `InvalidBCR()`.
  4. `1e18 < _scr < 2e18` or `InvalidSCR()`.
  5. `_liquidationPenaltySP >= MIN_LIQUIDATION_PENALTY_SP` (5%) or `SPPenaltyTooLow()`.
  6. `_liquidationPenaltySP <= _liquidationPenaltyRedistribution` or `SPPenaltyGtRedist()`.
  7. `_liquidationPenaltyRedistribution <= MAX_LIQUIDATION_PENALTY_REDISTRIBUTION` (20%) or `RedistPenaltyTooHigh()`.
- **Behavior (Effects)**:
  1. `Ownable(_owner)`: set Owner and emit `OwnershipTransferred(address(0), _owner)`.
  2. Store `CCR / SCR / MCR / BCR / LIQUIDATION_PENALTY_SP / LIQUIDATION_PENALTY_REDISTRIBUTION` in storage.
  3. Fix `riskParamsFinalizer = _riskParamsFinalizer` immutably and set `riskParamsFinalized = (_riskParamsFinalizer == address(0))`.
- **Revert / early return**: custom errors above.
- **Emitted events**: `OwnershipTransferred` (CORE-AR-EVT-019).
- **Design notes**: `_riskParamsFinalizer == 0` denotes a deploy-time-finalized branch; nonzero denotes a reserved branch. Constructor validation retains base's individual ranges and penalty ordering. The deployment gate enforces cross-parameter invariants for active branches, while CORE-AR-FR-005 revalidates them on-chain for reserved branches. Canonical values are in [Parameters.md](../../../Parameters.md).
- **Verification**: parity / unit (each boundary and zero/nonzero-finalizer lifecycle initialization).

#### CORE-AR-FR-002: `setAddresses` (Bulk Address Wiring and Ownership Renounce) 🔵
- **Type**: Functional / Governance / **Source**: base implementation (AddressesRegistry.sol)
- **Signature**: `setAddresses(AddressVars memory _vars)` (`AddressVars` is an 18-field struct from collToken through WETH; defined in `IAddressesRegistry`)
- **Purpose**: Configure all contracts that make up the branch plus shared contracts exactly once, and renounce ownership in the same tx to freeze wiring.
- **Authorization**: `onlyOwner`.
- **Preconditions (Checks)**: only caller is Owner (**no zero-address or cross-consistency validation**).
- **Behavior (Effects)**:
  1. Assign the struct's 18 fields to corresponding storage variables (collToken, borrowerOperations, troveManager, troveNFT, metadataNFT, stabilityPool, priceFeed, activePool, defaultPool, gasPoolAddress, collSurplusPool, sortedTroves, interestRouter, hintHelpers, multiTroveGetter, collateralRegistry, jpydfToken, WETH).
  2. Emit 18 corresponding `...AddressChanged` events.
  3. `_renounceOwnership()`: emit `OwnershipTransferred(old owner, address(0))` and clear Owner.
- **Revert / early return**: non-Owner → `"Ownable: caller is not the owner"`.
- **Emitted events**: all CORE-AR-EVT-001-018 plus CORE-AR-EVT-019.
- **Design notes**: "One-shot" is enforced by ownership renounce (second call permanently impossible). In deployment procedure, this must be called **before** each core contract constructor reads this registry to fix its own immutables (typical order: deploy AR → `setAddresses` with precomputed addresses → deploy each contract). The counterfactual CREATE2 targets do not have runtime code at this point, so a `code.length` check inside `setAddresses` is incompatible with the canonical procedure. The contract does not validate configured values, so wiring verification is deployment-script and post-deployment verification responsibility (CORE-AR-SEC-001).
- **Verification**: parity / unit (onlyOwner, 18 values reflected, 18+1 events, second call reverts after renounce).

#### CORE-AR-FR-003: Branch Risk Parameter Getter Group (CCR / SCR / MCR / BCR / Liquidation Penalties) 🔵/🟡
- **Type**: Functional / **Source**: base implementation + CORE-MOD-013 (automatic getters for public storage)
- **Signatures and return values**:

  | Function | Meaning of return value (use site) |
  | --- | --- |
  | `CCR() → uint256` | Borrowing operations restricted when TCR is below this (BO) |
  | `SCR() → uint256` | Shutdown possible and redemption allocation excluded when TCR is below this (BO/TM/CR) |
  | `MCR() → uint256` | Individual Trove liquidation threshold and minimum ICR during adjustment (BO/TM) |
  | `BCR() → uint256` | Buffer added to MCR for batch join / in-batch adjustment (BO) |
  | `LIQUIDATION_PENALTY_SP() → uint256` | Penalty rate for SP offset liquidation (TM) |
  | `LIQUIDATION_PENALTY_REDISTRIBUTION() → uint256` | Penalty rate for redistribution liquidation (TM) |
- **Authorization**: permissionless (view).
- **Design notes**: BO/TM copy initial values in their constructors and synchronize once from the Registry during reserved-branch finalization. At the end of the finalization transaction, all relevant Registry, BO, and TM copies match and have no later change path (CORE-AR-FR-005).
- **Verification**: parity / unit (initial values and child-copy equality after finalization).

#### CORE-AR-FR-004: Address Getter Group (All 18 Addresses + owner / isOwner) 🔵
- **Type**: Functional / **Source**: base implementation (automatic getters for public variables / Ownable.sol)
- **Signature**: `collToken` / `borrowerOperations` / `troveManager` / `troveNFT` / `metadataNFT` / `stabilityPool` / `priceFeed` / `activePool` / `defaultPool` / `gasPoolAddress` / `collSurplusPool` / `sortedTroves` / `interestRouter` / `hintHelpers` / `multiTroveGetter` / `collateralRegistry` / `jpydfToken` / `WETH` (each `→ corresponding interface type`, public view), plus `owner() → address` / `isOwner() → bool`
- **Purpose**: Reference configured wiring (all `address(0)` before `setAddresses`). Each core contract constructor reads these at deployment; off-chain tools and peripheral contracts also use them for reference resolution.
- **Authorization**: permissionless (view).
- **Revert / early return**: none.
- **Verification**: parity (values before/after `setAddresses`).

#### CORE-AR-FR-005: `finalizeRiskParams` (One-Shot Finalization for a Reserved Branch) 🟡
- **Type**: Functional / Governance / Security / **Source**: CORE-MOD-013
- **Signature**: `finalizeRiskParams(address _expectedUnderlying, RiskParams calldata _riskParams)`, where `RiskParams` contains `CCR / MCR / BCR / SCR / LIQUIDATION_PENALTY_SP / LIQUIDATION_PENALTY_REDISTRIBUTION / COLL_GAS_COMPENSATION_CAP` (shared `Types/RiskParams.sol`).
- **Purpose**: After selecting the exact Underlying, finalize six risk values and the compensation cap once for a reserved branch that has not begun economic activity and atomically synchronize Registry, BO, and TM.
- **Authorization / lifecycle**:
  1. `riskParamsFinalized == false`; otherwise `RiskParamsAlreadyFinalized()`.
  2. `msg.sender == riskParamsFinalizer`; otherwise `CallerNotRiskParamsFinalizer()`.
- **Parameter checks**: Re-run all seven CORE-AR-FR-001 range and penalty checks, then require `SCR < MCR < CCR`, `MCR * (COLL_GAS_COMPENSATION_DIVISOR - 1) >= (1e18 + LIQUIDATION_PENALTY_SP) * COLL_GAS_COMPENSATION_DIVISOR`, `1e18 + LIQUIDATION_PENALTY_REDISTRIBUTION <= MCR`, and `1e18 + URGENT_REDEMPTION_BONUS <= SCR`. Violations use the existing errors, then `InvalidCollateralRatioOrder()`, `MCRBelowSPPenalty()`, `MCRBelowRedistributionPenalty()`, and `SCRBelowUrgentRedemptionBonus()` respectively.
- **Compensation cap check**: Require `0 < COLL_GAS_COMPENSATION_CAP <= 1_000 ether`; otherwise `InvalidCollGasCompensationCap()`.
- **Collateral-binding checks**:
  1. `_expectedUnderlying`, `collToken` (dToken), and `dToken.vault()` all have runtime code.
  2. `dToken.underlying() == _expectedUnderlying`.
  3. `vault.dToken() == collToken` and `vault.underlying() == _expectedUnderlying`.
- **Inert / lifecycle checks**: `dToken.cap() == 0`, `dToken.totalSupply() == 0`, `troveManager.getTroveIdsCount() == 0`, branch debt and collateral (AP+DP) are both zero, `stabilityPool.getTotalJpydfDeposits() == 0`, `borrowerOperations.isOracleFailureShutdown() == false`, and irreversible shutdown has not occurred in BO, TM, or AP.
- **Behavior (Effects)** (execution order):
  1. Overwrite the Registry's six values and set `riskParamsFinalized = true`.
  2. Call `borrowerOperations.syncRiskParams(CCR, MCR, BCR, SCR)` and `troveManager.syncRiskParams(_riskParams)` in order.
  3. Emit `RiskParamsFinalized(_expectedUnderlying, six risk values, compensation cap)`.
- **Atomicity**: Failure of any check, getter, or child sync rolls back the Registry values, flag, and any prior child sync, preserving a retryable unfinalized state.
- **Design notes**: This function validates, but does not perform, dToken/Vault binding. The constructor does not verify that the finalizer itself is a Timelock, so the canonical deployment gate enforces equality with the common Timelock. An oracle pause permits retry after resume; any irreversible shutdown permanently prevents finalization.
- **Verification**: unit (all bounds, binding mismatch, nonzero state / SP deposit, shutdown states, one-shot authorization, risk-value and compensation-cap synchronization, and rollback) / deployment verification.


### HintHelpers Functional Requirements (`CORE-HH-FR-*`)

**Common specification for the 8 fee estimators** (common to CORE-HH-FR-002-009; referenced by each FR):

- **Fee formula**: `upfrontFee = debt × avgInterestRate × UPFRONT_INTEREST_PERIOD / ONE_YEAR / DECIMAL_PRECISION`. This is interest equivalent for `UPFRONT_INTEREST_PERIOD` (7 days; value in [Parameters.md](../../../Parameters.md)) at the average rate, same formula as `BorrowerOperations._calcUpfrontFee`.
- **Average-rate retrieval**: `avgInterestRate = ActivePool.getNewApproxAvgInterestRateFromTroveChange(c)` (AP section). It returns the **post-operation** branch weighted-average interest-rate approximation `Σ(debt×rate) / Σdebt` by hypothetically applying the `TroveChange c` that mirrors the target operation to aggregate values (`aggRecordedDebt` + unminted interest, `aggWeightedDebtSum`). After branch shutdown it is 0. To avoid the cycle fee → average rate → fee, upfront fee itself is not included in the average calculation (`c.upfrontFee == 0` asserted by AP). Differences among predict functions reduce to "which debt/rate is placed in which field of `c`" and "fee base."
- **Consistency**: Each predict constructs the same `TroveChange` as the BO implementation, so **for the same chain state, it matches the upfront fee actually charged** (CORE-HH-INV-001). Only state changes between estimate and execution (interest accrual over time and other operations) can create differences.
- **Non-responsibility**: Estimates fee amount only; it does not check whether the operation itself will succeed (ICR / TCR / `MIN_DEBT` / permission / cooldown checks, etc.). An operation may still revert even if predict returns a value.

| Function | Target operation (BO section) | Fee base | Condition returning 0 |
| --- | --- | --- | --- |
| `predictOpenTroveUpfrontFee` | `openTrove` | `_borrowedAmount` | none (opening is always charged) |
| `predictAdjustInterestRateUpfrontFee` | `adjustTroveInterestRate` | Trove full debt `entireDebt` | same rate, or cooldown elapsed |
| `forcePredictAdjustInterestRateUpfrontFee` | same (unconditional variant) | Trove full debt `entireDebt` | none |
| `predictAdjustTroveUpfrontFee` | debt-increasing `adjustTrove` family | `_debtIncrease` | `_debtIncrease == 0` |
| `predictAdjustBatchInterestRateUpfrontFee` | `setBatchManagerAnnualInterestRate` | whole batch debt `entireDebtWithoutRedistribution` | same rate, or batch cooldown elapsed |
| `predictOpenTroveAndJoinBatchUpfrontFee` | `openTroveAndJoinInterestBatchManager` | `_borrowedAmount` | none (opening is always charged) |
| `predictJoinBatchInterestRateUpfrontFee` | `setInterestBatchManager` | Trove full debt `entireDebt` | none (joining batch is always charged) |
| `predictRemoveFromBatchUpfrontFee` | `removeFromBatch` | Trove full debt `entireDebt` | same as current batch rate, or Trove cooldown elapsed |

#### CORE-HH-FR-001: `getApproxHint` (Approximate Hint Search by Random Sampling) 🔵

- **Type**: Functional / **Source**: base implementation (HintHelpers.sol)
- **Signature**: `getApproxHint(uint256 _collIndex, uint256 _interestRate, uint256 _numTrials, uint256 _inputRandomSeed) → (uint256 hintId, uint256 diff, uint256 latestRandomSeed)` (external view)
- **Purpose**: Find an approximate Trove whose annual rate is closest to target rate `_interestRate` by pseudorandom sampling from the Trove ID array, to use as starting point for insertion position search in SortedTroves (descending-rate list).
- **Authorization**: permissionless (view).
- **Preconditions (Checks)**: no explicit validation. Invalid `_collIndex` reverts on CollateralRegistry / zero-address call side (CORE-HH-ERR-001).
- **Behavior (Effects)**:
  1. Resolve TroveManager through `collateralRegistry.getTroveManager(_collIndex)`, then resolve SortedTroves through its `sortedTroves()`.
  2. `arrayLength = getTroveIdsCount()`. If 0, return `(0, 0, _inputRandomSeed)` (early return).
  3. Initial candidate: `hintId = sortedTroves.getLast()` (lowest-rate Trove), `diff = |_interestRate - getTroveAnnualInterestRate(hintId)|` (`LiquityMath._getAbsoluteDifference`).
  4. Iterate from `i = 1` to `_numTrials - 1`: `latestRandomSeed = keccak256(latestRandomSeed)` → `arrayIndex = seed % arrayLength` → `currentId = getTroveFromTroveIdsArray(arrayIndex)`.
  5. Skip IDs where `sortedTroves.contains(currentId)` is false (zombie or otherwise outside sorted list).
  6. If `|current rate - _interestRate| < diff`, update candidate.
  7. Return best `hintId`, its `diff`, and final `latestRandomSeed`.
- **Revert / early return**: Trove count 0 → `(0, 0, _inputRandomSeed)`. If `_numTrials <= 1`, no sampling occurs and list tail remains candidate.
- **Emitted events**: none.
- **Design notes**: Probabilistic search; output is on average `list length / _numTrials` positions away and worst-case O(n) positions away (NatSpec). Recommended `_numTrials = 15 × sqrt(list length)` yields high-confidence distance within `sqrt(list length)` (NatSpec). Passing `latestRandomSeed` as the next call's `_inputRandomSeed` allows trials to be split across multiple eth_calls. Return `diff` can compare hint quality (used by DebtInFrontHelper, CORE-DFH-FR-001). Intended off-chain, combined with `SortedTroves.findInsertPosition`.
- **Verification**: parity (base-identical behavior. Deterministic for fixed seed) / unit.

#### CORE-HH-FR-002: `predictOpenTroveUpfrontFee` (Estimate Fee for `openTrove`) 🔵

- **Type**: Functional / **Source**: base implementation (HintHelpers.sol)
- **Signature**: `predictOpenTroveUpfrontFee(uint256 _collIndex, uint256 _borrowedAmount, uint256 _interestRate) → uint256` (external view)
- **Purpose**: Estimate upfront fee when opening a non-batch Trove that borrows `_borrowedAmount` at interest rate `_interestRate`.
- **Authorization**: permissionless (view).
- **Preconditions (Checks)**: none (see common non-responsibility).
- **Behavior (Effects)**:
  1. Construct `TroveChange{ debtIncrease = _borrowedAmount, newWeightedRecordedDebt = _borrowedAmount × _interestRate }` (opening has no old side).
  2. Retrieve average rate from common specification and apply fee formula using `_borrowedAmount` as fee base.
- **Revert / early return**: none (opening is always charged. For a shut-down branch, average rate is 0 and it returns 0).
- **Emitted events**: none.
- **Verification**: parity / unit.

#### CORE-HH-FR-003: `predictAdjustInterestRateUpfrontFee` (Estimate Fee for Interest Adjustment) 🔵

- **Type**: Functional / **Source**: base implementation (HintHelpers.sol)
- **Signature**: `predictAdjustInterestRateUpfrontFee(uint256 _collIndex, uint256 _troveId, uint256 _newInterestRate) → uint256` (external view)
- **Purpose**: Estimate upfront fee charged by `adjustTroveInterestRate` for a non-batch Trove when the change is premature (before `INTEREST_RATE_ADJ_COOLDOWN` elapsed since last adjustment).
- **Authorization**: permissionless (view).
- **Preconditions (Checks)**: none.
- **Behavior (Effects)**:
  1. Retrieve current state (including interest and redistribution) with `getLatestTroveData(_troveId)`.
  2. If `_newInterestRate == current annual rate`, or `block.timestamp >= lastInterestRateAdjTime + INTEREST_RATE_ADJ_COOLDOWN` (cooldown elapsed = free adjustment), **return 0**.
  3. Otherwise construct `TroveChange{ appliedRedistJpydfDebtGain = redistribution gain, newWeightedRecordedDebt = entireDebt × _newInterestRate, oldWeightedRecordedDebt = trove.weightedRecordedDebt }` and apply fee formula using `entireDebt` (full debt) as base.
- **Revert / early return**: returns 0 under the two conditions above.
- **Emitted events**: none.
- **Design notes**: Mirrors BO charging condition exactly (`_applyUpfrontFee` only when `block.timestamp < lastInterestRateAdjTime + INTEREST_RATE_ADJ_COOLDOWN`). Fee base is **full debt**, unlike openTrove family.
- **Verification**: parity / unit.

#### CORE-HH-FR-004: `forcePredictAdjustInterestRateUpfrontFee` (Unconditional Interest Adjustment Fee Estimate) 🔵

- **Type**: Functional / **Source**: base implementation (HintHelpers.sol)
- **Signature**: `forcePredictAdjustInterestRateUpfrontFee(uint256 _collIndex, uint256 _troveId, uint256 _newInterestRate) → uint256` (external view)
- **Purpose**: Variant of CORE-HH-FR-003 without the 0 short-circuit (same-rate / cooldown elapsed). Always calculates and returns "fee if a premature adjustment were performed now."
- **Authorization**: permissionless (view).
- **Behavior (Effects)**: Unconditionally execute the same internal calculation as CORE-HH-FR-003 step 3 (`_predictAdjustInterestRateUpfrontFee`).
- **Revert / early return**: none.
- **Emitted events**: none.
- **Design notes**: Useful for conservative UI estimates or showing "cost if adjusted before cooldown ends," even when actual operation would charge 0. Actual charge determination is CORE-HH-FR-003.
- **Verification**: parity / unit.

#### CORE-HH-FR-005: `predictAdjustTroveUpfrontFee` (Estimate Fee for Debt-Increasing Adjustment) 🔵

- **Type**: Functional / **Source**: base implementation (HintHelpers.sol)
- **Signature**: `predictAdjustTroveUpfrontFee(uint256 _collIndex, uint256 _troveId, uint256 _debtIncrease) → uint256` (external view)
- **Purpose**: Estimate upfront fee when `adjustTrove` family operations (`withdrawJpydf`, etc.) increase debt by `_debtIncrease`. Adjustments without debt increase (repayment or collateral-only increase/decrease) are not fee targets.
- **Authorization**: permissionless (view).
- **Behavior (Effects)**:
  1. If `_debtIncrease == 0`, **return 0**.
  2. Retrieve `getLatestTroveData(_troveId)` and `interestBatchManager` from `Troves(_troveId)`.
  3. Non-batch: `TroveChange{ appliedRedistJpydfDebtGain, debtIncrease = _debtIncrease, newWeightedRecordedDebt = (entireDebt + _debtIncrease) × trove.annualInterestRate, oldWeightedRecordedDebt = trove.weightedRecordedDebt }`.
  4. Batch member: retrieve `getLatestBatchData(batchManager)` and construct `TroveChange{ appliedRedistJpydfDebtGain, debtIncrease, batchAccruedManagementFee = batch.accruedManagementFee, newWeightedRecordedDebt = (batch.entireDebtWithoutRedistribution + trove.redistJpydfDebtGain + _debtIncrease) × batch.annualInterestRate, oldWeightedRecordedDebt = batch.weightedRecordedDebt }` (reweight whole batch at batch rate).
  5. Apply fee formula using **only `_debtIncrease`** as fee base.
- **Revert / early return**: `_debtIncrease == 0` → 0.
- **Emitted events**: none.
- **Design notes**: Fee base is the increment only (not full debt). For batch-member Troves, the rate is batch rate and average-rate calculation also reproduces BO `_adjustTrove` by reweighting whole batch debt.
- **Verification**: parity / unit.

#### CORE-HH-FR-006: `predictAdjustBatchInterestRateUpfrontFee` (Estimate Fee for Batch Rate Change) 🔵

- **Type**: Functional / **Source**: base implementation (HintHelpers.sol)
- **Signature**: `predictAdjustBatchInterestRateUpfrontFee(uint256 _collIndex, address _batchAddress, uint256 _newInterestRate) → uint256` (external view)
- **Purpose**: Estimate upfront fee charged to the whole batch when a batch manager's `setBatchManagerAnnualInterestRate` is premature.
- **Authorization**: permissionless (view).
- **Behavior (Effects)**:
  1. Retrieve `getLatestBatchData(_batchAddress)`.
  2. If `_newInterestRate == batch.annualInterestRate`, or `block.timestamp >= batch.lastInterestRateAdjTime + INTEREST_RATE_ADJ_COOLDOWN`, **return 0**.
  3. Otherwise construct `TroveChange{ batchAccruedManagementFee, newWeightedRecordedDebt = batch.entireDebtWithoutRedistribution × _newInterestRate, oldWeightedRecordedDebt = batch.weightedRecordedDebt }`, and apply fee formula using `batch.entireDebtWithoutRedistribution` (whole batch debt excluding redistribution gains, including accrued interest and management fee) as fee base.
- **Revert / early return**: returns 0 under the two conditions above.
- **Emitted events**: none.
- **Design notes**: Differs from CORE-HH-FR-003 in that cooldown basis is **batch** `lastInterestRateAdjTime`, not Trove. Matches BO-side charge condition (rate change and within cooldown).
- **Verification**: parity / unit.

#### CORE-HH-FR-007: `predictOpenTroveAndJoinBatchUpfrontFee` (Estimate Fee for Opening into Batch) 🔵

- **Type**: Functional / **Source**: base implementation (HintHelpers.sol)
- **Signature**: `predictOpenTroveAndJoinBatchUpfrontFee(uint256 _collIndex, uint256 _borrowedAmount, address _batchAddress) → uint256` (external view; not declared in `IHintHelpers`)
- **Purpose**: Estimate upfront fee for `openTroveAndJoinInterestBatchManager` (open Trove while joining batch).
- **Authorization**: permissionless (view).
- **Behavior (Effects)**:
  1. Retrieve `getLatestBatchData(_batchAddress)`.
  2. Construct `TroveChange{ debtIncrease = _borrowedAmount, batchAccruedManagementFee, oldWeightedRecordedDebt = batch.weightedRecordedDebt, newWeightedRecordedDebt = (batch.entireDebtWithoutRedistribution + _borrowedAmount) × batch.annualInterestRate }`.
  3. Apply fee formula using `_borrowedAmount` as fee base.
- **Revert / early return**: none (opening is always charged).
- **Emitted events**: none.
- **Design notes**: Difference from CORE-HH-FR-002 is that borrowed amount is weighted by **batch rate**, not individual rate.
- **Verification**: parity / unit.

#### CORE-HH-FR-008: `predictJoinBatchInterestRateUpfrontFee` (Estimate Fee for Joining Batch) 🔵

- **Type**: Functional / **Source**: base implementation (HintHelpers.sol)
- **Signature**: `predictJoinBatchInterestRateUpfrontFee(uint256 _collIndex, uint256 _troveId, address _batchAddress) → uint256` (external view)
- **Purpose**: Estimate upfront fee when an existing Trove joins a batch through `setInterestBatchManager`. Joining is **always charged** regardless of cooldown (base comment: prevents a borrower running their own batch from avoiding fees to obtain free interest updates), so there is no 0 short-circuit.
- **Authorization**: permissionless (view).
- **Behavior (Effects)**:
  1. Retrieve `getLatestTroveData(_troveId)` and `getLatestBatchData(_batchAddress)`.
  2. Construct `TroveChange{ appliedRedistJpydfDebtGain = trove.redistJpydfDebtGain, batchAccruedManagementFee, oldWeightedRecordedDebt = batch.weightedRecordedDebt + trove.weightedRecordedDebt, newWeightedRecordedDebt = (batch.entireDebtWithoutRedistribution + trove.entireDebt) × batch.annualInterestRate }` (remove Trove old weight and batch old weight, then reweight combined debt at batch rate).
  3. Apply fee formula using `trove.entireDebt` as fee base.
- **Revert / early return**: none.
- **Emitted events**: none.
- **Verification**: parity / unit.

#### CORE-HH-FR-009: `predictRemoveFromBatchUpfrontFee` (Estimate Fee for Leaving Batch) 🔵

- **Type**: Functional / **Source**: base implementation (HintHelpers.sol)
- **Signature**: `predictRemoveFromBatchUpfrontFee(uint256 _collIndex, uint256 _troveId, uint256 _newInterestRate) → uint256` (external view; not declared in `IHintHelpers`)
- **Purpose**: Estimate upfront fee when a batch-member Trove leaves via `removeFromBatch` and sets individual interest rate `_newInterestRate`.
- **Authorization**: permissionless (view).
- **Behavior (Effects)**:
  1. Retrieve `getLatestTroveData(_troveId)`, batch membership from `Troves(_troveId)`, and `getLatestBatchData(batchManager)`.
  2. If `_newInterestRate == batch.annualInterestRate` (same rate after leaving), or `block.timestamp >= trove.lastInterestRateAdjTime + INTEREST_RATE_ADJ_COOLDOWN` (Trove-based cooldown elapsed), **return 0**.
  3. Otherwise construct `TroveChange{ appliedRedistJpydfDebtGain, batchAccruedManagementFee, oldWeightedRecordedDebt = batch.weightedRecordedDebt, newWeightedRecordedDebt = (batch.entireDebtWithoutRedistribution - (trove.entireDebt - trove.redistJpydfDebtGain)) × batch.annualInterestRate + trove.entireDebt × _newInterestRate }` (remaining batch debt after exit is weighted at batch rate; exiting Trove is weighted at new rate. Same shape as BO `_removeFromBatch` `batchFutureDebt` calculation).
  4. Apply fee formula using `trove.entireDebt` as fee base.
- **Revert / early return**: returns 0 under the two conditions above.
- **Emitted events**: none.
- **Design notes**: The 0 short-circuit compares against "current batch rate" (leaving but choosing same rate = no effective rate change) while cooldown basis is "Trove side," a deliberately asymmetric combination. Matches BO charge condition (`batch.annualInterestRate != _newAnnualInterestRate && block.timestamp < trove.lastInterestRateAdjTime + INTEREST_RATE_ADJ_COOLDOWN`).
- **Verification**: parity / unit.

#### CORE-HH-FR-010: Constant and Reference View Function Group 🔵

- **Type**: Functional / **Source**: base implementation (HintHelpers.sol)
- **Purpose**: Self-evident public getters.

| Function | Meaning of return value |
| --- | --- |
| `NAME()` | Constant `"HintHelpers"` |
| `collateralRegistry()` | CollateralRegistry address fixed in constructor |

- **Verification**: parity.


### MultiTroveGetter Functional Requirements (`CORE-MTG-FR-*`)

#### CORE-MTG-FR-001: `getMultipleSortedTroves` (Batch Retrieve Troves in Interest-Rate Order) 🔵

- **Type**: Functional / **Source**: base implementation (MultiTroveGetter.sol)
- **Signature**: `getMultipleSortedTroves(uint256 _collIndex, int256 _startIdx, uint256 _count) → CombinedTroveData[] _troves` (external view)
- **Purpose**: Retrieve `_count` Trove details (`CombinedTroveData`) in SortedTroves order. Traversal direction depends on the sign of `_startIdx`.
- **Authorization**: permissionless (view).
- **Preconditions (Checks)**: `getTroveManager(_collIndex) != address(0)` (require `"Invalid collateral index"`). `sortedTroves != address(0)` (assert).
- **Behavior (Effects)**:
  1. **`_startIdx >= 0`**: scan from head (`getFirst()` = highest interest rate) in **descending** interest-rate order, returning `_count` items from index `_startIdx`.
  2. **`_startIdx < 0`**: interpret `startIdx = uint256(-(_startIdx + 1))` (`-1` → 0th from tail, `-2` → 1st from tail, ...), scan from tail (`getLast()` = lowest interest rate) in **ascending** interest-rate order (redemption order), and return `_count` items.
  3. If `startIdx >= list size`, return empty array. `_count` is truncated to `list size - startIdx`.
  4. Construct `CombinedTroveData` for each Trove. Field sources:
     - `entireDebt` / `entireColl` / `redistJpydfDebtGain` / `redistCollGain` / `accruedInterest` / `recordedDebt` / `annualInterestRate` / `accruedBatchManagementFee` / `lastInterestRateAdjTime` ← `TroveManager.getLatestTroveData` (latest values including interest and redistribution; TM section).
     - `stake` / `lastDebtUpdateTime` / `interestBatchManager` / `batchDebtShares` ← `Troves` storage (recorded values).
     - `snapshotETH` / `snapshotJpydfDebt` ← `rewardSnapshots` (redistribution snapshots. `snapshotETH` is a historical base name; actual meaning is collateral snapshot).
- **Revert / early return**: invalid index → `"Invalid collateral index"`. Out-of-range `startIdx` → empty array.
- **Emitted events**: none.
- **Design notes**: Zombie Troves are outside the sorted list and do not appear in output. Negative `_startIdx` scanning (ascending) corresponds to viewing "from the side consumed first by redemption." Traversal cost includes linear skip by `startIdx` from list head/tail.
- **Verification**: parity / unit.

#### CORE-MTG-FR-002: `getDebtPerInterestRateAscending` (Retrieve Debt Distribution by Ascending Interest Rate) 🔵

- **Type**: Functional / **Source**: base implementation (MultiTroveGetter.sol)
- **Signature**: `getDebtPerInterestRateAscending(uint256 _collIndex, uint256 _startId, uint256 _maxIterations) → (DebtPerInterestRate[] data, uint256 currId)` (external view)
- **Purpose**: Enumerate each Trove's (batch membership, current annual rate, full debt) in **ascending** interest-rate order (redemption order). Used to construct debt distribution by rate band (redemption-risk visualization and delegate strategy UI).
- **Authorization**: permissionless (view).
- **Preconditions (Checks)**: same as CORE-MTG-FR-001 (require `"Invalid collateral index"` / assert).
- **Behavior (Effects)**:
  1. Start point: if `_startId == 0`, use `getLast()` (lowest interest); otherwise start from specified Trove ID.
  2. For at most `_maxIterations` items and while `currId != 0`: read `prevId` (next node toward higher interest) and `batchId` from `sortedTroves.nodes(currId)`; record `data[i] = { interestBatchManager = batchId (0 for non-batch), interestRate = getLatestTroveData(currId).annualInterestRate, debt = entireDebt }`, then `currId = prevId`.
  3. Return `data` with **fixed length `_maxIterations`** (if list ends early, remaining elements stay zero).
  4. Return `currId` as the next unprocessed node ID (cursor). `0` means scan reached the head (highest interest) and is complete.
- **Revert / early return**: invalid index → `"Invalid collateral index"`.
- **Emitted events**: none.
- **Design notes**: Cursor-based paging: pass returned `currId` as next `_startId` (same shape as CORE-LCG-FR-001). `_maxIterations` is also memory allocation size, so excessive values increase cost. Batch-member Troves still appear individually as one Trove = one node, and `interestRate` reflects current batch rate.
- **Verification**: parity / unit.

#### CORE-MTG-FR-003: Reference View Function Group 🔵

- **Type**: Functional / **Source**: base implementation (MultiTroveGetter.sol)

| Function | Meaning of return value |
| --- | --- |
| `collateralRegistry()` | CollateralRegistry address fixed in constructor |

- **Verification**: parity.


### DebtInFrontHelper Functional Requirements (`CORE-DFH-FR-*`)

#### CORE-DFH-FR-001: `getDebtBetweenInterestRates` (Total Debt in Interest-Rate Band) 🔵

- **Type**: Functional / **Source**: base implementation (DebtInFrontHelper.sol)
- **Signature**: `getDebtBetweenInterestRates(uint256 _collIndex, uint256 _interestRateLo, uint256 _interestRateHi, uint256 _excludedTroveId, uint256 _hintId, uint256 _numTrials) → (uint256 debt, uint256 blockTimestamp)` (external view)
- **Purpose**: Return total `entireDebt` for all Troves whose annual rate is in `[_interestRateLo, _interestRateHi)` (**lo inclusive, hi exclusive**, as interface note states). `_excludedTroveId` is excluded from the sum (scan continues). Typical use: debt staying in an interest band excluding own Trove = redemption buffer.
- **Authorization**: permissionless (view).
- **Preconditions (Checks)**: `getTroveManager(_collIndex) != address(0)` (require `"Invalid collateral index"`). `sortedTroves != address(0)` (assert).
- **Behavior (Effects)**:
  1. **Hint improvement (when `_numTrials > 0`)**: use `keccak256(abi.encode(block.timestamp, all arguments))` as pseudorandom seed and call `hintHelpers.getApproxHint(_collIndex, _interestRateLo, _numTrials, seed)`. If new hint's `diff` (distance from target rate) is smaller than the diff of caller-provided `_hintId`, adopt it (`_hintId == 0` is treated as diff `type(uint256).max`, so new hint is always adopted). If `_numTrials == 0`, use `_hintId` as-is.
  2. **Determine start point**: call `sortedTroves.findInsertPosition(_interestRateLo, hint, hint)` and use the first return value (prev side) = "lowest-rate node satisfying annual rate ≥ lo" as `currId` (ST section. Because insertion position resolves to the tail side of equal-rate group, **all Troves with exactly lo rate are included in the scan**).
  3. **Scan**: while `currId != 0`, retrieve `getLatestTroveData(currId)`. (a) If `annualInterestRate >= _interestRateHi`, break. (b) If `currId == _excludedTroveId`, skip. (c) Otherwise add `entireDebt` to `debt`. Advance `currId = sortedTroves.getPrev(currId)` (ascending interest order toward head).
  4. Return with `blockTimestamp = block.timestamp` (timestamp identifying the state point for off-chain users).
- **Revert / early return**: invalid index → `"Invalid collateral index"`. If no node satisfies lo, scan 0 items and returns `debt = 0`.
- **Emitted events**: none.
- **Design notes**: Debt is summed as `entireDebt` (including interest and redistribution), matching the amount redemption actually consumes. Hints optimize away full descent from head in `findInsertPosition`; they do not affect result correctness. Setting `_interestRateLo = 0` gives a full scan from list tail = complete debt-in-front up to the chosen rate. Zombie Troves are outside the list and are not included (redemption prioritizes `lastZombieTroveId`; TM section). Loop is unbounded and intended for off-chain `eth_call`.
- **Verification**: parity / unit.

#### CORE-DFH-FR-002: `getDebtBetweenInterestRateAndTrove` (Total Debt Until Just Before Specific Trove) 🔵

- **Type**: Functional / **Source**: base implementation (DebtInFrontHelper.sol)
- **Signature**: `getDebtBetweenInterestRateAndTrove(uint256 _collIndex, uint256 _interestRateLo, uint256 _interestRateHi, uint256 _troveIdToStopAt, uint256 _hintId, uint256 _numTrials) → (uint256 debt, uint256 blockTimestamp)` (external view)
- **Purpose**: Perform the same scan as CORE-DFH-FR-001, but **stop when `_troveIdToStopAt` is reached** (that Trove's debt is not included). This calculates the true debt-in-front of a specific Trove, **including list order among many same-rate Troves** (redemption consumes in list order, so same-rate Troves on the tail side are redeemed earlier).
- **Authorization**: permissionless (view).
- **Preconditions (Checks)**: same as CORE-DFH-FR-001.
- **Behavior (Effects)**: Call internal `_getDebtBetween` with `_stopAfterExludedTrove = true`. When scan reaches `currId == _troveIdToStopAt`, break (FR-001 skips and continues; this function stops).
- **Revert / early return**: same as CORE-DFH-FR-001. If `_troveIdToStopAt` never appears in range, equivalent to FR-001 (sum until hi or list head).
- **Emitted events**: none.
- **Design notes**: For own Trove redemption-order evaluation, use for example `_interestRateLo = 0` (or lower-bound rate), `_interestRateHi = own Trove rate + ε`, `_troveIdToStopAt = own Trove`. Hint selection based on seed including `block.timestamp` does not affect the result (only start-point optimization).
- **Verification**: parity / unit.

#### CORE-DFH-FR-003: Reference View Function Group 🔵

- **Type**: Functional / **Source**: base implementation (DebtInFrontHelper.sol)

| Function | Meaning of return value |
| --- | --- |
| `collateralRegistry()` | CollateralRegistry address fixed in constructor |
| `hintHelpers()` | HintHelpers address fixed in constructor |

- **Verification**: parity.


### RedemptionHelper Functional Requirements (`CORE-RH-FR-*`)

#### CORE-RH-FR-001: `redeemCollateral` (Redemption Wrapper with Min-Out) 🔵

- **Type**: Functional / **Source**: base implementation (RedemptionHelper.sol)
- **Signature**: `redeemCollateral(uint256 _jpydf, uint256 _maxIterationsPerCollateral, uint256 _maxFeePct, uint256[] _minCollRedeemed)` (external, nonpayable)
- **Purpose**: Wrapper around `CollateralRegistry.redeemCollateral(_jpydf, _maxIterationsPerCollateral, _maxFeePct)` (CR section). Additions over direct CR call are **(a) slippage protection through per-branch minimum received collateral `_minCollRedeemed`** and **(b) automatic return of unredeemed JPYdf remainder**. `_maxIterationsPerCollateral` (Trove scan limit per branch) and `_maxFeePct` (allowed fee rate cap) are pass-through CR parameters, not introduced by this wrapper.
- **Authorization**: permissionless. Caller must approve this contract for at least `_jpydf` JPYdf beforehand (`transferFrom` pulls it).
- **Preconditions (Checks)**:
  - `_jpydf > 0` (require `"Redeemed amount must be non-zero"`).
  - `_minCollRedeemed.length == numBranches` (require `"Wrong _minCollRedeemed length"`).
- **Behavior (Effects)**:
  1. Record each branch collateral token (`collateralRegistry.getToken(i)`, dToken implementation; [dToken.md](dToken.md)) and this contract's before balance.
  2. Record this contract's before JPYdf balance.
  3. `jpydfToken.transferFrom(msg.sender → this contract, _jpydf)`.
  4. Call `collateralRegistry.redeemCollateral(_jpydf, _maxIterationsPerCollateral, _maxFeePct)` (**this contract is the redeemer**: burn happens from this contract's balance and branch redemption collateral arrives here. Fee-rate excess reverts on CR side with `"CR: Fee exceeded provided maximum"`).
  5. For each branch: compute `collRedeemed = balance(after) - balance(before)` and require `collRedeemed >= _minCollRedeemed[i]` (`"Insufficient collateral redeemed"`). If `collRedeemed > 0`, `safeTransfer` it to `msg.sender`.
  6. `jpydfRemaining = JPYdf balance(after) - balance(before)` (unredeemed amount that was not burned). If `> 0`, return it to `msg.sender`.
- **Revert / early return**: the two requires above plus min-out violation in step 5. Also propagates `transferFrom` failure (approve/balance shortage) and CR/branch-side reverts.
- **Emitted events**: none (JPYdf / collToken `Transfer` and CR/TM events in their sections).
- **Design notes**: CR redemption can complete below requested amount because of (a) truncation to unbacked total, (b) `_maxIterationsPerCollateral` scan limit, and (c) skipping Troves with ICR < 100% (CR and TM sections). Direct CR calls cannot constrain received collateral amount up front, so this wrapper provides per-branch min-out. Base values for `_minCollRedeemed` are expected from CORE-RH-FR-003 `truncateRedemption` `redeemed[i].coll` (interface NatSpec). Returning residual JPYdf prevents caller funds from remaining in this contract after partial fill.
- **Verification**: parity / unit (min-out violation revert, residual return) / invariant=CORE-RH-INV-001.

#### CORE-RH-FR-002: `simulateRedemption` (Redemption Simulation) 🔵/🟡

- **Type**: Functional / **Source**: base implementation (RedemptionHelper.sol) + CORE-MOD-015
- **Signature**: `simulateRedemption(uint256 _jpydf, uint256 _maxIterationsPerCollateral) → (SimulationContext[] branch, uint256 totalProportions)` (public, **nonpayable**, off-chain only)
- **Purpose**: Estimate CR branch allocation (unbacked-proportional) and actual redeemable amount `redeemedJpydf` within `_maxIterationsPerCollateral` for each branch when `_jpydf` is requested. A branch whose normal-redemption price consumer returns `failure == true` is excluded from scanning but remains in CR's allocation denominator, preventing its share from being over-allocated to available branches.
- **Authorization**: permissionless. **Not view** because each branch `TroveManager.getUnbackedPortionPriceAndRedeemability` (TM section) internally calls `PriceFeed.fetchPrice`, and this function itself calls `PriceFeed.fetchRedemptionPrice` ([Oracle.md](Oracle.md)). Price fetching writes state; calling on-chain actually updates oracle state. Intended for eth_call.
- **Behavior (Effects)**:
  1. For each branch, retrieve `troveManager` / `sortedTroves` and `(proportion = unbacked debt (branch total debt - SP deposits, lower bounded at 0), price = normal price, redeemable = TCR ≥ SCR and not shut down)` from `getUnbackedPortionPriceAndRedeemability()`.
  2. Probe `fetchRedemptionPrice()` for every branch that TM marked redeemable and record `failure == false` as redemption-price availability. Add the `proportion` of **every TM-redeemable branch**, including failure branches, to `totalProportions`; separately add only available branches to `availableProportions`.
  3. If `0 < totalProportions < _jpydf`, truncate `_jpydf` to `totalProportions` (same rule as CR implementation to avoid allocation imbalance above unbacked amount; code comment: CS-JPYDF-013).
  4. If `totalProportions == 0`, fallback: replace each branch `proportion` with `getEntireBranchDebt()` (total branch debt), then recompute `totalProportions` across all TM-redeemable branches and `availableProportions` using the previously recorded availability (same allocation denominator as CR fallback).
  5. Set each failure branch's `redeemable` to false. If `totalProportions == 0` or `availableProportions == 0`, return `(branch, 0)` early.
  6. For each remaining available / redeemable branch: `attemptedJpydf = _jpydf × proportion / totalProportions` (skip if 0), while **keeping failure-branch proportions in `totalProportions`**. Trove scan follows actual redemption order: if `lastZombieTroveId` is nonzero, inspect it first (then `sortedTroves.getLast()`), otherwise start at `getLast()` (lowest rate) and advance by `getPrev` in ascending interest order. Stop when `redeemedJpydf == attemptedJpydf` or `troveId == 0`. Only Troves satisfying `entireColl × price / entireDebt >= _100pct` (ICR ≥ 100%, normal-price check) add `min(attemptedJpydf - redeemedJpydf, entireDebt)` to `redeemedJpydf`; Troves with ICR < 100% are skipped but still consume an iteration. Iteration cap is `_maxIterationsPerCollateral` (**0 = unlimited**).
  7. Return per-branch `SimulationContext{ troveManager, sortedTroves, redeemable, price, proportion, attemptedJpydf, redeemedJpydf, iterations }` and `totalProportions`.
- **Revert / early return**: if the allocation denominator is zero or no available branch has a positive allocation, return `(branch, 0)`. Failure branches have `redeemable == false` and zero scan results.
- **Emitted events**: none (Oracle-side events are in [Oracle.md](Oracle.md)).
- **Design notes**: Allocation, truncation, scan order (zombie first then lowest-rate upward), and ICR 100% check (normal price) follow CR/TM implementation rules, so `redeemedJpydf` is consistent with actual fill amount under the same state. Removing a failure branch from the denominator would overestimate the remaining branches by redistributing a share that CR does not reallocate; therefore it is removed only from scanning and retained in the denominator. This function does not calculate face-value JPYdf/collateral conversion (fee or redemption price); that is CORE-RH-FR-003. In fallback, branches that TM did not mark redeemable may also have `proportion` overwritten, but they remain skipped during allocation.
- **Verification**: parity / unit / integration.

#### CORE-RH-FR-003: `truncateRedemption` (Truncate to Optimal Redemption Amount and Estimate Receipts) 🔵/🟡

- **Type**: Functional / **Source**: base implementation (RedemptionHelper.sol) + CORE-MOD-015
- **Signature**: `truncateRedemption(uint256 _jpydf, uint256 _maxIterationsPerCollateral) → (uint256 truncatedJpydf, uint256 feePct, Redeemed[] redeemed)` (external, **nonpayable**, off-chain only)
- **Purpose**: Calculate the request amount associated with a proportional quote within the iteration limit. `truncatedJpydf` is not a guarantee of full redemption: unavailable branches retain allocation weights, so their shares remain unspent. Sum `redeemed[i].jpydf` for expected redeemed JPYdf; use `redeemed[i].coll` for expected collateral.
- **Authorization**: permissionless. nonpayable reason same as CORE-RH-FR-002 (also calls `fetchRedemptionPrice`).
- **Behavior (Effects)**:
  1. Run `simulateRedemption(_jpydf, _maxIterationsPerCollateral)` (CORE-RH-FR-002).
  2. If `totalProportions == 0`, return `(0, 0, empty array)`.
  3. Initialize `truncatedJpydf = _jpydf`. For each redeemable branch with `proportion > 0`, calculate `extrapolatedJpydf = redeemedJpydf × totalProportions / proportion` ("whole-system requested amount that would make proportional allocation match this branch's actual fill") and truncate `truncatedJpydf` to the **minimum** of those values (branches not hitting iteration limit have `extrapolatedJpydf ≈ _jpydf` and do not truncate).
  4. `feePct = collateralRegistry.getRedemptionRateForRedeemedAmount(truncatedJpydf)` (CR section; redemption fee rate including time-decayed baseRate and increase from this amount. Floor `REDEMPTION_FEE_FLOOR`, cap 100%; values in §7).
  5. For each redeemable branch with `proportion > 0`, read `addresses[i].priceFeed().fetchRedemptionPrice()` again (redemption price; [Oracle.md](Oracle.md)). If any read returns `failure == true`, immediately return `(0, 0, new Redeemed[](numBranches))`. Only when every read is available, set `redeemed[i].jpydf = truncatedJpydf × proportion / totalProportions` and `redeemed[i].coll = redeemed[i].jpydf × (DECIMAL_PRECISION - feePct) / redemptionPrice` (expected collateral after fee; same shape as TM `collLot = jpydfLot/price - fee`).
- **Revert / early return**: `totalProportions == 0` → `(0, 0, empty array)`. After the simulation probe, `failure == true` on the second read in step 5 → `(0, 0, redeemed)`, where `redeemed.length == numBranches` and every entry is zero.
- **Emitted events**: none.
- **Design notes**: `redeemed[i].coll` is the base value for CORE-RH-FR-001 `_minCollRedeemed` (caller is expected to discount by acceptable slippage). The same price separation as TM implementation is preserved: normal price for ICR checks, redemption price for collateral conversion. If availability is lost between the simulation probe and the conversion-time second read, the function returns no partial quote and zero-fills every branch. State differences between eth_call and execution tx (price, baseRate, list movement) are caller risk; FR-001 min-out absorbs that.
- **Verification**: parity / unit / integration.

#### CORE-RH-FR-004: Reference View Function Group 🔵

- **Type**: Functional / **Source**: base implementation (RedemptionHelper.sol)

| Function | Meaning of return value |
| --- | --- |
| `numBranches()` | Number of branches (matches deployment-time `totalCollaterals`) |
| `collateralRegistry()` | CollateralRegistry fixed in constructor |
| `jpydfToken()` | JPYdf token retrieved from CR |
| `addresses(uint256 i)` | AddressesRegistry for branch i (out-of-range index reverts on array bounds) |

- **Verification**: parity.

#### CORE-RH-FR-005: Constructor (Deployment-Time Consistency Validation) 🔵

- **Type**: Functional / **Source**: base implementation (RedemptionHelper.sol)
- **Signature**: `constructor(ICollateralRegistry _collateralRegistry, IAddressesRegistry[] _addresses)`
- **Purpose**: Snapshot branch composition and reject inconsistent deployment relative to CR.
- **Preconditions (Checks)**:
  - `_addresses.length == _collateralRegistry.totalCollaterals()` (require `"Wrong number of registries"`).
  - For each i, `_collateralRegistry.getTroveManager(i) == _addresses[i].troveManager()` (require `"TroveManager mismatch"`).
- **Behavior (Effects)**: Fix `numBranches` / `collateralRegistry` / `jpydfToken` (`= collateralRegistry.jpydfToken()`) as immutables and push entries into `addresses` array.
- **Design notes**: CR `totalCollaterals` is immutable (CR section), so branch count cannot change after deployment and create inconsistency.
- **Verification**: unit (constructor revert on mismatch).


### LiquidationCandidateGetter Functional Requirements (`CORE-LCG-FR-*`)

#### CORE-LCG-FR-001: `getLiquidationCandidates` (Paging Scan for Liquidation Candidates) 🟢

- **Type**: Functional / **Source**: DF implementation (LiquidationCandidateGetter.sol; does not exist in base)
- **Signature**: `getLiquidationCandidates(uint256 _collIndex, uint256 _startId, uint256 _maxIterations, uint256 _price, uint256 _mcr) → (LiquidationCandidate[] candidates, uint256 currId)` (external view)
- **Purpose**: Scan at most `_maxIterations` nodes in SortedTroves for branch `_collIndex` in interest-rate order and list Troves satisfying `getCurrentICR(troveId, _price) < _mcr` as `LiquidationCandidate{ id, ICR, entireDebt, entireColl }`. Used for candidate extraction and monitoring for liquidation (`TroveManager.batchLiquidateTroves`; TM section).
- **Authorization**: permissionless (view).
- **Preconditions (Checks)**: `getTroveManager(_collIndex) != address(0)` (`LiquidationCandidateGetter__InvalidCollateralIndex`). `sortedTroves != address(0)` (assert).
- **Behavior (Effects)**:
  1. Allocate working buffer `LiquidationCandidate[_maxIterations]`.
  2. Start point: if `_startId == 0`, use `sortedTroves.getFirst()` (head = highest interest rate); otherwise start from `_startId`.
  3. Iterate at most `_maxIterations` times while `currId != 0`: set `troveId = currId`, then **first** advance `currId = sortedTroves.getNext(troveId)` (descending interest direction) → returned `currId` is always "next unscanned node."
  4. Calculate `icr = troveManager.getCurrentICR(troveId, _price)` (`entireColl × _price / entireDebt`, including interest and redistribution; TM section); if `icr >= _mcr`, continue.
  5. For matching Troves, retrieve `entireDebt` / `entireColl` from `getLatestTroveData` and add to buffer.
  6. Copy into an array sized exactly to hit count and return.
- **Revert / early return**: invalid index → `LiquidationCandidateGetter__InvalidCollateralIndex`. Loop ends at list tail (`currId == 0`).
- **Emitted events**: none.
- **Design notes**:
  - **Paging**: cursor pattern where returned `currId` is passed as next `_startId` (same as CORE-MTG-FR-002). `currId == 0` signals full scan complete. SortedTroves order is interest-rate order and **uncorrelated with ICR**, so complete candidate discovery requires scanning the whole list; this function provides paging for that. `_maxIterations` also determines buffer memory allocation, so excessive values increase cost.
  - **Why `_price` / `_mcr` are arguments**: `PriceFeed.fetchPrice` writes state and cannot be used in a view, so caller obtains price off-chain and passes it ([Oracle.md](Oracle.md) PriceFeedProxy). MCR is also passed by caller from branch constants (AddressesRegistry / [Parameters.md](../../../Parameters.md)). It is caller responsibility to pass values matching actual liquidation condition (`ICR < MCR`; TM section), and the function can also be used for stress scans with hypothetical price ("how many Troves fall if price is X").
  - **Zombie Troves are excluded from this function**: scan target is only sorted list. Zombie Troves (removed from the list after redemption below `MIN_DEBT`; TM section) are **liquidatable by `_isActiveOrZombie` but do not appear in this function's candidates**. For monitoring `lastZombieTroveId`, use CORE-LCG-FR-003.
  - **Assumption for `_startId`**: expected to be an existing Trove ID in the list. If an ID removed between pages (redemption/liquidation/adjustment) is supplied, `getNext == 0` and scan ends immediately (no revert). Caller should tolerate or rescan for skips/duplicates caused by list movement between pages.
- **Verification**: unit (🟢 DF original, outside parity. ICR boundary, paging, empty list, zombie exclusion).

#### CORE-LCG-FR-003: Treating lastZombieTroveId as a Liquidation Candidate 🟢

- **Type**: Functional | **Source**: DF implementation (LiquidationCandidateGetter.sol; does not exist in base)
- **Signature**: `getLastZombieLiquidationCandidate(uint256 _collIndex, uint256 _price, uint256 _mcr) → (bool found, LiquidationCandidate candidate)` (external view) / `getLiquidationCandidatesWithLastZombie(..., bool _includeLastZombie) → (LiquidationCandidate[] candidates, uint256 currId, bool includedLastZombie)` (external view)
- **Purpose**: Among the zombie Troves removed from SortedTroves, include `lastZombieTroveId`—which TroveManager retains as its most recent pointer—in the liquidation bot's candidates. This removes the need for the bot to read TroveManager through a separate ABI to build a provisional candidate with debt/coll = 0.
- **Permissions**: permissionless (view).
- **Preconditions (Checks)**: `getTroveManager(_collIndex) != address(0)` (`LiquidationCandidateGetter__InvalidCollateralIndex`).
- **Behavior (Effects)**:
  1. If `lastZombieTroveId == 0`, then `found=false`.
  2. If `getTroveStatus(lastZombieTroveId) != zombie`, treat it as a stale pointer and set `found=false`.
  3. If `getCurrentICR(lastZombieTroveId, _price) >= _mcr`, treat it as not liquidatable and set `found=false`.
  4. If the conditions are met, obtain `entireDebt` / `entireColl` from `getLatestTroveData` and return `LiquidationCandidate{ id, ICR, entireDebt, entireColl }` with `found=true`.
  5. `getLiquidationCandidatesWithLastZombie` appends exactly one candidate to the end of the CORE-LCG-FR-001 SortedTroves paging result when `_includeLastZombie == true` and step 4 holds, and returns `includedLastZombie=true`. `currId` remains the next cursor of the SortedTroves paging.
- **revert / early return**: invalid index → `LiquidationCandidateGetter__InvalidCollateralIndex`. If there is no liquidatable last zombie, returns empty / `found=false` (no revert).
- **Design notes**: Liquity v2 core retains only a single `lastZombieTroveId` as the next redemption-priority target, so this helper also handles that one entry. Full coverage of multiple zombies is a follow-up task on the event/indexer side; this function is a minimal extension to "not miss the zombie pointer that core explicitly retains" in liquidation monitoring.
- **Verification**: unit (last zombie present/absent, stale-pointer equivalent, ICR boundary, debt/coll retrieval, tail append of the combined API).

#### CORE-LCG-FR-002: Reference View Function Group 🟢

- **Type**: Functional / **Source**: DF implementation (LiquidationCandidateGetter.sol)
- **Preconditions (Checks)**: constructor `_collateralRegistry != address(0)`. A zero registry reverts with `LiquidationCandidateGetter__InvalidCollateralRegistry`.

| Function | Meaning of return value |
| --- | --- |
| `collateralRegistry()` | CollateralRegistry address fixed in constructor |

- **Verification**: unit.


### Constants.sol Functional Requirements (`CORE-LIB-FR-*`)

#### CORE-LIB-FR-001: Provide File-Level System Constants 🔵
- **Type**: Functional / **Source**: base implementation (Constants.sol)
- **Signature**: none (file-level `constant` declarations)
- **Purpose**: Centralize economic and time parameters shared across core, and embed them into referencing contracts at compile time as constants.
- **Authorization**: none (no on-chain setting operation exists).
- **Preconditions (Checks)**: none.
- **Behavior (Effects)**: no state changes. Each constant is inlined into referencing contract bytecode.
- **Revert / early return**: none.
- **Emitted events**: none.
- **Design notes**: Constants have no storage, so changing a value means redeploying referencing contracts. Branch-specific CR/penalties are stored by AddressesRegistry and copied into BO/TM: active branches use deployment inputs, while reserved branches replace bootstrap values exactly once through CORE-AR-FR-005 before activation.
- **Verification**: parity (base equality for all constants except 2 🟡 items = CORE-LIB-INV-001)

#### CORE-LIB-FR-002: `MIN_DEBT` (Minimum Debt Change) 🟡
- **Type**: Functional / **Source**: CORE-MOD-002 / [Parameters.md](../../../Parameters.md)
- **Signature**: `uint256 constant MIN_DEBT = 100_000e18`
- **Purpose**: Define minimum debt a Trove must maintain (JPYdf-denominated, entire debt basis). Prevents economic infeasibility of liquidation/redemption due to many tiny Troves (gas cost > expected gain) and griefing of sequential redemption.
- **Authorization**: none (constant).
- **Preconditions (Checks)**: BorrowerOperations constructor checks `assert(MIN_DEBT > 0)` (structurally prevents opening with zero debt).
- **Behavior (Effects)**: Main enforcement (norms are in each scope's FR):
  1. Opening/adjustment: entire debt below `MIN_DEBT` reverts (BorrowerOperations `_requireAtLeastMinDebt` → `DebtBelowMin`; see CORE-BO).
  2. Repayment: repayment cap is `entireDebt - MIN_DEBT` (CORE-BO).
  3. After redemption: Troves whose remaining debt is below `MIN_DEBT` become zombies and are removed from sorted list (TroveManager; CORE-TM).
  4. Zombie return: adjustment to entire debt ≥ `MIN_DEBT` reactivates (CORE-BO).
- **Revert / early return**: `DebtBelowMin` (BorrowerOperations side).
- **Emitted events**: none.
- **Delta from base**: base is `2000e18` (2,000 BOLD, USD-denominated); DF is `100_000e18` (100,000 JPYdf). Rationale: rescale to the production minimum debt for JPY-denominated JPYdf (canonical: CORE-MOD-002 and [Parameters.md](../../../Parameters.md)).
- **Verification**: unit (boundary: exactly `MIN_DEBT` / below), 🟡 delta test (value is 100_000e18)

#### CORE-LIB-FR-003: `COLL_GAS_COMPENSATION_CAP` (Collateral Gas Compensation Cap Change) 🟡
- **Type**: Functional / **Source**: CORE-MOD-003 / [Parameters.md](../../../Parameters.md)
- **Input**: TroveManager constructor `_collGasCompensationCap`, in 18-decimal dToken units; greater than zero and no more than `COLL_GAS_COMPENSATION_CAP` (1,000 ether).
- **Behavior**: Cap the 0.5% compensation on the SP-offset portion at the branch's configured amount. Redistribution-only collateral earns no collateral gas compensation. The fixed WETH payment is unchanged.
- **Lifetime**: Active-branch caps are fixed at deployment. A reserved branch replaces its bootstrap cap exactly once through `finalizeRiskParams`, alongside its other risk values, while cap/supply and all Core balances remain zero. The Registry validates `0 < cap <= 1,000 ether` and synchronizes the cap into TM atomically; after finalization no change path remains. Storage keeps runtime within the size limit.
- **Deployment**: Use the same cap in CREATE2 prediction and deployment. Reserved branches start with a 1,000-unit bootstrap cap and must finalize a collateral-specific cap before activation.
- **Verification**: cap boundaries, zero/partial/full SP offset, collateral conservation, deployment wiring, storage layout and runtime size.

#### CORE-LIB-FR-004: DF Branch-Specific Constant Group 🟢
- **Type**: Functional / **Source**: CORE-MOD-005 / [Parameters.md](../../../Parameters.md) / the Japanese [Collateral Parameter Policy](../../../../jp/protocol/product/policies/Collateral-Parameter-Policy.md) §2.4
- **Signature**: `MCR_<BR>` / `CCR_<BR>` / `SCR_<BR>` / `BCR_<BR>` / `LIQUIDATION_PENALTY_SP_<BR>` / `LIQUIDATION_PENALTY_REDISTRIBUTION_<BR>` (8 branches × 6 types = 48 `uint256 constant`s. See state variable table (b) for suffixes)
- **Purpose**: Declare deployment inputs for all eight DF Day-1 branch slots (`NUM_DF_ACTIVE_BRANCHES = 2`; only dwstETH / dUSDC are active and Branches 2–7 are reserved and inert) as constants named by dToken name (core collateral = dToken).
- **Authorization**: none (constant).
- **Preconditions (Checks)**: none.
- **Behavior (Effects)**: declarations only. Normative points from code comments:
  1. **Limited production constant surface**: `contracts/src` contains only generic precision / liquidation bound / gas compensation / debt cap / interest cap constants plus DF dToken branch constants. Production-unreferenced upstream `*_WETH` / `*_SETH` / `BCR_ALL` and helper aliases `ZERO_ADDRESS` / `MAX_UINT256` are not declared. Inherited multicollateral tests keep local `TEST_*` fixture constants and use `address(0)` / `type(uint256).max` directly for test-only aliases.
  2. **Consumed by DF dToken wiring**: current `DeployLiquity2` injects this constant group into `TroveManagerParams` via `_dfBranchParams()` and passes it to each `AddressesRegistry` constructor in the DF 8-branch deployment. Non-mainnet uses DF dToken wiring by default, while mainnet uses this path only when `DF_ENABLE_MAINNET_DTOKEN_WIRING=true` is explicit. The legacy / upstream 3-branch deploy path was removed because it is outside the Day-1 policy and the manifest consumer assumptions.
  3. **Exact representation**: decimal percentages use `<pct*100> * _1pct / 100`; since `_1pct` (= 1e16) is divisible by 100, values are exact with no error (§2-A values have at most 2 decimal places. CORE-LIB-INV-002).
  4. **Reserved values are bootstrap inputs, not approvals**: Values for Br2–7 keep Core deployment valid while the exact Underlying is still TBD. Before activation, derive the six final risk values and compensation cap from that Underlying and finalize them once under CORE-AR-FR-005; otherwise keep the branch reserved.
- **Revert / early return**: none.
- **Emitted events**: none.
- **Design notes**: [Parameters.md](../../../Parameters.md) is canonical for active values and reserved bootstrap inputs. The displayed dJPY / dJGB 5% BCR and redistribution penalty are bootstrap values only, not approval of a future collateral.
- **Verification**: unit (DF constants match comment values and Parameters.md), absence review (`*_WETH` / `*_SETH` / `BCR_ALL` / `ZERO_ADDRESS` / `MAX_UINT256` do not remain in production `src`), deploy / integration (DF dToken wiring injects the branch params; mainnet `complete` fails closed without `DF_ENABLE_MAINNET_DTOKEN_WIRING=true`)


### LiquityBase Functional Requirements (`CORE-LIB-FR-*`)

#### CORE-LIB-FR-005: Constructor (Resolve References from AddressesRegistry) 🔵
- **Type**: Functional / **Source**: base implementation (LiquityBase.sol)
- **Signature**: `constructor(IAddressesRegistry _addressesRegistry)`
- **Purpose**: Resolve and hold references to the branch ActivePool / DefaultPool / PriceFeed exactly once from AddressesRegistry.
- **Authorization**: deployment only (through inheriting contract constructors).
- **Preconditions (Checks)**: none (no zero-address validation. Wiring correctness depends on deployment procedure).
- **Behavior (Effects)**:
  1. `activePool = _addressesRegistry.activePool()`.
  2. `defaultPool = _addressesRegistry.defaultPool()`.
  3. `priceFeed = _addressesRegistry.priceFeed()`.
  4. Emit `ActivePoolAddressChanged` / `DefaultPoolAddressChanged` / `PriceFeedAddressChanged`.
- **Revert / early return**: none.
- **Emitted events**: CORE-LIB-EVT-001 / 002 / 003 (once at deployment).
- **Design notes**: The three variables have no setters and cannot be changed after construction (storage but effectively immutable). Inheritors (BO / TM / SP / DFStabilityPool) are deployed per branch, so references point to that branch's Pool set and PriceFeedProxy.
- **Verification**: parity / deployment verification (wiring match)

#### CORE-LIB-FR-006: `getEntireBranchColl` / `getEntireBranchDebt` (Branch-Wide Aggregation) 🔵
- **Type**: Functional / **Source**: base implementation (LiquityBase.sol) / ILiquityBase
- **Signature**: `getEntireBranchColl() → uint256 entireSystemColl` / `getEntireBranchDebt() → uint256 entireSystemDebt` (both public view)
- **Purpose**: Return total branch collateral and debt as "ActivePool + DefaultPool." Base values for TCR calculation, shutdown checks, and redemption allocation.
- **Authorization**: none (permissionless view).
- **Preconditions (Checks)**: none.
- **Behavior (Effects)**:
  1. Coll: `activePool.getCollBalance() + defaultPool.getCollBalance()`.
  2. Debt: `activePool.getJpydfDebt() + defaultPool.getJpydfDebt()`. `activePool.getJpydfDebt()` includes aggregate recorded debt plus pending aggregate interest and batch management rewards (composition norm in CORE-AP). `defaultPool.getJpydfDebt()` holds unapplied redistribution debt (norm in CORE-DP).
- **Revert / early return**: none.
- **Emitted events**: none (view).
- **Design notes**: Aggregation is per "branch," not across all branches (system-wide branch iteration is through CollateralRegistry).
- **Verification**: parity / invariant=CORE-SYS-INV-001

#### CORE-LIB-FR-007: `_getTCR` / `_checkBelowCriticalThreshold` (TCR and CT Checks) 🔵
- **Type**: Functional / **Source**: base implementation (LiquityBase.sol)
- **Signature**: `_getTCR(uint256 _price) → uint256 TCR` / `_checkBelowCriticalThreshold(uint256 _price, uint256 _CCR) → bool` (both internal view)
- **Purpose**: Calculate branch Total Collateral Ratio (TCR) and provide Critical Threshold check (TCR < CCR). Basis for borrowing restrictions (new borrowing and collateral withdrawal restrictions below CT; CORE-BO) and shutdown check (TCR < SCR; CORE-BO).
- **Authorization**: internal (inheriting contracts only).
- **Preconditions (Checks)**: none. Caller supplies `_price` from PriceFeed (PriceFeedProxy in DF; [Oracle.md](Oracle.md)).
- **Behavior (Effects)**:
  1. `_getTCR`: `LiquityMath._computeCR(getEntireBranchColl(), getEntireBranchDebt(), _price)` (if debt is 0, returns type(uint256).max = "infinite CR").
  2. `_checkBelowCriticalThreshold`: return `_getTCR(_price) < _CCR` (caller supplies the stored CCR sourced from AddressesRegistry).
- **Revert / early return**: none.
- **Emitted events**: none.
- **Verification**: parity / unit (debt-0 branch returns false)

#### CORE-LIB-FR-008: `_calcInterest` (Simple-Interest Primitive) 🔵
- **Type**: Functional / **Source**: base implementation (LiquityBase.sol)
- **Signature**: `_calcInterest(uint256 _weightedDebt, uint256 _period) → uint256` (internal pure)
- **Purpose**: Minimal primitive for interest accounting, returning simple (non-compounded) interest for "weighted debt (debt × annual rate, 1e36 scale) × elapsed seconds ÷ 1 year." Basis for Trove/Batch accrued interest, management fee, and upfront fee (7 days of prepaid interest).
- **Authorization**: internal pure.
- **Preconditions (Checks)**: none.
- **Behavior (Effects)**: Return `_weightedDebt * _period / ONE_YEAR / DECIMAL_PRECISION` (**floor division**).
- **Revert / early return**: none (multiplication overflow causes Solidity 0.8 Panic; CORE-LIB-ERR-001).
- **Design notes**: Individual Trove interest floors while ActivePool aggregate interest ceils (`Math.ceilDiv`; CORE-AP), preserving a positive rounding error where "aggregate debt ≥ sum of individual debts" so system debt cannot go negative (CORE-SYS-INV-001).
- **Verification**: parity / unit (rounding direction)


### LiquityMath Functional Requirements (`CORE-LIB-FR-*`)

#### CORE-LIB-FR-009: Comparison, Difference, and Collateral-Ratio Helpers 🔵
- **Type**: Functional / **Source**: base implementation (LiquityMath.sol)
- **Signature**: `_min(uint256,uint256) → uint256` / `_max(uint256,uint256) → uint256` / `_sub_min_0(uint256 _a, uint256 _b) → uint256` / `_getAbsoluteDifference(uint256,uint256) → uint256` / `_computeCR(uint256 _coll, uint256 _debt, uint256 _price) → uint256` (all internal pure)
- **Purpose**: Basic numeric operations used across core. In particular, `_computeCR` is the single implementation point for ICR / TCR calculations.
- **Authorization**: internal pure.
- **Preconditions (Checks)**: none.
- **Behavior (Effects)**:
  1. `_min` / `_max`: return smaller/larger value (`_max` prefers a on `>=`).
  2. `_sub_min_0`: `a > b ? a - b : 0` (saturating subtraction lower bounded at 0). **Currently unreferenced from production code**.
  3. `_getAbsoluteDifference`: `|a - b|` (used by HintHelpers hint closeness).
  4. `_computeCR`: if `_debt > 0`, return `_coll * _price / _debt` (floor. coll is 18-dec collateral quantity, price is 1e18 scale, result is a 1e18-scale ratio). **If `_debt == 0`, return `2**256 - 1` (type(uint256).max) as "infinite CR."**
- **Revert / early return**: none (overflow in `_coll * _price` causes Panic; CORE-LIB-ERR-001).
- **Emitted events**: none.
- **Design notes**: Infinite CR convention means debt-0 cases (empty branch, fully redeemed zombie, etc.) are treated as "healthy" in all threshold comparisons (< MCR / < CCR / < SCR).
- **Verification**: parity / unit (debt=0 → max uint, rounding direction)

#### CORE-LIB-FR-010: `decMul` / `_decPow` (18-Decimal Fixed-Point Exponentiation) 🔵
- **Type**: Functional / **Source**: base implementation (LiquityMath.sol)
- **Signature**: `decMul(uint256 x, uint256 y) → uint256 decProd` / `_decPow(uint256 _base, uint256 _minutes) → uint256` (both internal pure)
- **Purpose**: Fixed-point exponentiation for redemption baseRate per-minute exponential decay `decayFactor^minutes` (CollateralRegistry `_calcDecayedBaseRate` is the only use site).
- **Authorization**: internal pure.
- **Preconditions (Checks)**: none.
- **Behavior (Effects)**:
  1. `decMul`: 1e18-scale multiplication `(x*y + 1e18/2) / 1e18`. **Rounded to nearest** (round up when the 19th digit is ≥ 5). Internal to `_decPow`.
  2. `_decPow`: cap exponent at **525,600,000 minutes (= 1,000 years)** (overflow avoidance. Code comments say values beyond cap decay effectively to 0, so difference is negligible). If `_minutes == 0`, return `DECIMAL_PRECISION` (= 1.0). Otherwise use **exponentiation by squaring** in O(log n) `decMul` operations (even exponent: `x = x², n = n/2`; odd exponent: `y = x·y, x = x², n = (n-1)/2`; final `x·y`).
- **Revert / early return**: none.
- **Emitted events**: none.
- **Design notes**: Rounding is deterministic nearest rounding, so for the same input the result under iterative multiplication vs exponentiation-by-squaring is implementation-specific and fixed. Parity tests can verify exact equality.
- **Verification**: parity / unit (n=0 / n=1 / even/odd / cap boundary 525,600,000)


### Ownable Functional Requirements (`CORE-LIB-FR-*`)

#### CORE-LIB-FR-011: Owner Model (constructor / owner / isOwner / onlyOwner) 🔵
- **Type**: Functional | **Source**: base implementation (Ownable.sol)
- **Signature**: `constructor(address initialOwner)` / `owner() → address` / `isOwner() → bool` / `modifier onlyOwner`
- **Purpose**: Minimal access control that allows only the single owner set at deployment time to call specific functions (wiring functions on inheriting contracts).
- **Permissions**: Functions with `onlyOwner` can be called only by the current owner.
- **Preconditions (Checks)**: The constructor has **no zero-address validation** (`initialOwner = address(0)` can still be deployed. In that case, onlyOwner functions are uncallable from the start).
- **Behavior (Effects)**:
  1. constructor: sets `_owner = initialOwner` and emits `OwnershipTransferred(address(0), initialOwner)`
  2. `owner()` / `isOwner()`: read-only
  3. `onlyOwner`: `require(isOwner(), "Ownable: caller is not the owner")`
- **revert / early return**: onlyOwner call by a non-owner → require string `"Ownable: caller is not the owner"`.
- **Emitted events**: CORE-LIB-EVT-004.
- **Design notes**: Because `transferOwnership` does not exist, the owner cannot be replaced (a clear difference from OZ). Ownership transition is one-way only: "initial setup → renouncement (by inheriting-side logic)".
- **Verification**: parity / unit (non-owner revert and string match)

#### CORE-LIB-FR-012: _renounceOwnership (renouncing ownership after wiring completion) 🔵
- **Type**: Functional | **Source**: base implementation (Ownable.sol)
- **Signature**: `_renounceOwnership()` (internal)
- **Purpose**: Permanently makes a contract ownerless after one-time initial wiring is complete, structurally preventing subsequent configuration changes (trust minimization).
- **Permissions**: internal. **No caller validation** (NatSpec explicitly states that it does not perform an owner check and that the caller must verify it).
- **Preconditions (Checks)**: None (responsibility of the inheriting side).
- **Behavior (Effects)**:
  1. Emits `OwnershipTransferred(_owner, address(0))`
  2. Sets `_owner = address(0)`
- **revert / early return**: None.
- **Emitted events**: CORE-LIB-EVT-004.
- **Design notes**: In both current inheritance sites, it is called at the end of `onlyOwner` functions (JpydfToken `setCollateralRegistry` / AddressesRegistry `setAddresses`), so in effect renouncement occurs only through an action by the owner itself (CORE-LIB-SEC-001). After renouncement, `owner() == address(0)` and `isOwner()` is always false, making onlyOwner functions uncallable.
- **Verification**: parity / unit (permanent onlyOwner revert after renouncement and event arguments)


### Functional Requirements for Types (CORE-LIB-FR-*)

#### CORE-LIB-FR-013: TroveId Type (Deprecated: removed from production `src`) 🔵
- **Type**: Functional (Deprecated) | **Source**: base implementation (old `Types/TroveId.sol`)
- **Signature**: Old `type TroveId is uint256` + global operator/predicates `==` / `!=` / `isEndOfList` / `isNotEndOfList`
- **Purpose**: Type-safe wrapper for Trove identifiers (uint256). Provides predicates for end-of-list checks.
- **Permissions**: None (pure).
- **Preconditions (Checks)**: None.
- **Behavior (Effects)**: Deprecated. Current production contracts pass Trove IDs around as raw `uint256` throughout and do not reference the `TroveId` helper type.
- **revert / early return**: None.
- **Emitted events**: None.
- **Design notes**:
  - Under the fresh deploy / audit-surface minimization policy, the unreferenced production helper `contracts/src/Types/TroveId.sol` has been removed from `src`. Only the `SortedTroves` fuzz test needs the typed helper, so equivalent type/predicate definitions are kept inside test source.
  - Trove ID values are derived in BorrowerOperations during opening as `uint256(keccak256(abi.encode(msg.sender, _owner, _ownerIndex)))` (the norm is CORE-BO. Note that because `msg.sender` is included, it is not determined solely by (owner, ownerIndex)). Because it is a 256-bit hash value, the collision probability with `0` (= reserved root node value) is negligible.
- **Verification**: unit (`SortedTroves` test-local helper) / static (`Types/TroveId.sol` does not exist in production `src`)

#### CORE-LIB-FR-014: BatchId Type 🔵
- **Type**: Functional | **Source**: base implementation (Types/BatchId.sol)
- **Signature**: `type BatchId is address` + global operator/predicates `==` / `!=` / `isZero` / `isNotZero`
- **Purpose**: Type-safe wrapper for batch identifiers (= batch manager addresses). Provides predicates for determining "no batch affiliation" (`BATCH_ID_ZERO`).
- **Permissions**: None (pure).
- **Preconditions (Checks)**: None.
- **Behavior (Effects)**: `==` / `!=` compare unwrapped values. `isZero(x)` is `x == BATCH_ID_ZERO`, and `isNotZero` is its negation.
- **revert / early return**: None.
- **Emitted events**: None.
- **Design notes**: Unlike TroveId, this is actually used in production: referenced by SortedTroves nodes (`nodes[*].batchId`), the batch linked list (`batches` mapping keys), ISortedTroves signatures, and MultiTroveGetter (norms are CORE-ST / CORE-MTG).
- **Verification**: parity

#### CORE-LIB-FR-015: TroveChange Struct (passing operation deltas) 🔵
- **Type**: Functional | **Source**: base implementation (Types/TroveChange.sol) / ActivePool aggregate accounting
- **Signature**: `struct TroveChange` (12 uint256 fields, passed as memory/calldata)
- **Purpose**: Core type that represents the amounts by which a single operation (open, adjust, close, liquidation, redemption, or batch operation) changes a Trove as **unsigned increase/decrease pairs**, and passes them to ActivePool aggregate accounting (`mintAggInterestAndAccountForTroveChange` / `mintBatchManagementFeeAndAccountForChange` / `getNewApproxAvgInterestRateFromTroveChange`; norm is CORE-AP). The producers are BorrowerOperations and TroveManager.
- **Permissions**: None (data type).
- **Preconditions (Checks)**: None (the type itself has no validation. See the norms for the consumers).
- **Behavior (Effects)**: Meaning of all fields and their role in aggregate accounting:

| Field | Meaning | Role in aggregate accounting (CORE-AP) |
| --- | --- | --- |
| `appliedRedistJpydfDebtGain` | Debt gain from redistribution applied (finalized) to the Trove by this operation | Added to `aggRecordedDebt` (paired with debt reassignment from DefaultPool → ActivePool) |
| `appliedRedistCollGain` | Collateral gain from redistribution, same as above | Collateral amount moved from DefaultPool → ActivePool (TroveManager `_movePendingTroveRewardsToActivePool`) |
| `collIncrease` / `collDecrease` | Collateral increase / decrease caused by the operation (two unsigned values) | Determines pull / send amounts for the collateral token (dToken. [dToken.md](dToken.md)) (CORE-BO / CORE-TM) |
| `debtIncrease` / `debtDecrease` | Debt issuance / repayment caused by the operation (two unsigned values) | Added to / subtracted from `aggRecordedDebt` |
| `newWeightedRecordedDebt` | `recordedDebt × annualInterestRate` **after** the operation (1e36 scale) | Added to `aggWeightedDebtSum` (paired with subtraction of the old value) |
| `oldWeightedRecordedDebt` | Same value **before** the operation | Subtracted from `aggWeightedDebtSum` |
| `upfrontFee` | Upfront interest charged by the operation (7 days' worth. CORE-BO) | Added to `aggRecordedDebt` and minted immediately to SP / interestRouter (same distribution as interest) |
| `batchAccruedManagementFee` | Portion of the batch's accrued management fee finalized (minted) by this operation | Added to `aggRecordedDebt`, deducted from the pending bucket `aggBatchManagementFees`, and minted to the batch manager |
| `newWeightedRecordedBatchManagementFee` | `recordedDebt × annualManagementFee` **after** the operation | Added to `aggWeightedBatchManagementFeeSum` |
| `oldWeightedRecordedBatchManagementFee` | Same value **before** the operation | Subtracted from `aggWeightedBatchManagementFeeSum` |

- **revert / early return**: None (type).
- **Emitted events**: None.
- **Design notes**:
  - Increases/decreases are held as two unsigned fields to avoid conversion to/from signed ints (the base comment notes that in repayment operations, the net amount can be either positive or negative depending on the relative sizes of the redistribution gain and repayment amount).
  - **Does not include per-Trove accrued interest**: because individual interest is accounted for separately on the aggregate side (pending aggregate interest), TroveChange carries only "issuance/repayment + applied redistribution gain". Replacing new/oldWeightedRecordedDebt updates the future interest accrual rate.
  - The average interest rate estimate (`getNewApproxAvgInterestRateFromTroveChange`) asserts `upfrontFee == 0` (simplifies the circular reference between fee ↔ average interest rate. CORE-AP).
- **Verification**: parity / invariant=CORE-SYS-INV-002

#### CORE-LIB-FR-016: LatestTroveData Struct (latest Trove state snapshot) 🔵

- **Type**: Functional | **Source**: base implementation (`Types/LatestTroveData.sol`) / TroveManager `_getLatestTroveData`
- **Signature**: `struct LatestTroveData` (uint256 × 10 fields)
- **Purpose**: A complete “current-time” view of a Trove that incorporates all unapplied redistribution gains, accrued interest, and batch prorations. The calculation norm is CORE-TM (`getLatestTroveData` / `_getLatestTroveDataFromBatch`). Common input for BO adjustment validation, liquidation, redemption, and view functions.
- **Permissions**: None (data type).
- **Behavior (Effects)**: Meaning of all fields (calculation differences for non-batch Troves / batch-member Troves):

| Field | Meaning | Calculation (non-batch) | Calculation (batch-member) |
| --- | --- | --- | --- |
| `entireDebt` | Total debt | `recordedDebt + redistJpydfDebtGain + accruedInterest` | Left side + `accruedBatchManagementFee` |
| `entireColl` | Total collateral | `Troves[id].coll + redistCollGain` | Same as left |
| `redistJpydfDebtGain` | Unapplied redistribution debt gain | `stake × (L_jpydfDebt − snapshot) / 1e18` | Same as left (per Trove) |
| `redistCollGain` | Unapplied redistribution collateral gain | `stake × (L_coll − snapshot) / 1e18` | Same as left (per Trove) |
| `accruedInterest` | Accrued interest | `_calcInterest(weightedRecordedDebt, elapsed)` | Debt-shares proration of batch accrued interest |
| `recordedDebt` | Recorded debt | `Troves[id].debt` | `batch.recordedDebt × batchDebtShares / totalDebtShares` |
| `annualInterestRate` | Annual interest rate | Trove-specific value | Batch rate |
| `weightedRecordedDebt` | `recordedDebt × annualInterestRate` | Same formula | Same formula (batch rate) |
| `accruedBatchManagementFee` | Accrued batch management fee (Trove proration) | 0 (field unset) | Shares proration of batch accrued fee |
| `lastInterestRateAdjTime` | Last interest-rate adjustment time | Trove-specific value | `max(batch, trove)` |

- **Design point**: When prorating batch entire values to Troves, only redistribution gains cannot be proportional to debt shares (redistribution is proportional to collateral stake), so they are calculated separately per Trove (base comment). For batches where `totalDebtShares == 0`, proration-related fields remain 0.
- **Verification**: parity / unit (consistency between batch and non-batch)

#### CORE-LIB-FR-017: LatestBatchData Struct (Batch Latest-State Snapshot)🔵
- **Type**: Functional | **Source**: base implementation (`Types/LatestBatchData.sol`) / TroveManager `_getLatestBatchData`
- **Signature**: `struct LatestBatchData` (uint256 × 12 fields)
- **Purpose**: A complete “current-time” view of a batch (joint interest-rate management per batch manager). Common input for Trove proration (CORE-LIB-FR-016) and batch operation validation. The calculation norm is CORE-TM (`getLatestBatchData`).
- **Permissions**: None (data type).
- **Behavior (Effects)**: Meaning of all fields:

| Field | Meaning |
| --- | --- |
| `totalDebtShares` | Total batch debt shares (denominator for proration to Troves. Ratio cap is validated with `MAX_BATCH_SHARES_RATIO` = CORE-TM/CORE-BO) |
| `entireDebtWithoutRedistribution` | Total debt **excluding** redistribution gains = `recordedDebt + accruedInterest + accruedManagementFee` (redistribution is per Trove, so it is not included in batch aggregation) |
| `entireCollWithoutRedistribution` | Total collateral excluding redistribution gains = `batch.coll` |
| `accruedInterest` | Batch accrued interest = `_calcInterest(weightedRecordedDebt, elapsed since lastDebtUpdateTime)` |
| `recordedDebt` | Batch recorded debt = `batch.debt` |
| `annualInterestRate` | Batch annual interest rate |
| `weightedRecordedDebt` | `recordedDebt × annualInterestRate` |
| `annualManagementFee` | Annual rate of batch management fee (cap `MAX_ANNUAL_BATCH_MANAGEMENT_FEE`) |
| `accruedManagementFee` | Accrued management fee = `_calcInterest(weightedRecordedBatchManagementFee, same elapsed time)` |
| `weightedRecordedBatchManagementFee` | `recordedDebt × annualManagementFee` |
| `lastDebtUpdateTime` | Last debt update time (starting point for accrual) |
| `lastInterestRateAdjTime` | Last interest-rate adjustment time (starting point for cooldown checks) |

- **Verification**: parity / unit


---

## 7. State Variables and Accounting Model

> All state variables for each contract (immutable / constant / storage, including internal) and their accounting roles. See §8.1 for the **core accounting identities** (cross-contract).
>
> **Canonical values of constants**: The canonical values of constants inherited unchanged from `base` (`ETH_GAS_COMPENSATION` / `SP_YIELD_SPLIT` / `MIN_JPYDF_IN_SP` / `REDEMPTION_FEE_FLOOR` / `INITIAL_BASE_RATE` / `REDEMPTION_MINUTE_DECAY_FACTOR` / `MAX_BATCH_SHARES_RATIO` / `MIN_ANNUAL_INTEREST_RATE`, etc.) are in `Constants.sol` and are listed in the constants table at the end of this section. [Parameters.md](../../../Parameters.md) is canonical only for values adjusted by DF (branch CR/penalty, `MIN_DEBT` [CORE-MOD-002], `COLL_GAS_COMPENSATION_CAP` [CORE-MOD-003], etc.), and does not list constants inherited from `base`. References in the text that say “value is in §7” for `base`-inherited constants point to this constants table.


### BorrowerOperations State Variables

Inheritance order (C3 linearization: LiquityBase → AddRemoveManagers → BorrowerOperations) and code declaration order.

| Variable | Type / Visibility | Initial Value / Setting Location | Meaning / Accounting Role |
| --- | --- | --- | --- |
| `activePool` | `IActivePool` public (inherited from LiquityBase) | constructor (AddressesRegistry) | Branch ActivePool. Aggregation and collateral custody destination. The specification is handled by LIB |
| `defaultPool` | `IDefaultPool` internal (inherited from LiquityBase) | constructor (same as above) | Stores redistributed coll/debt. The specification is handled by LIB |
| `priceFeed` | `IPriceFeed` internal (inherited from LiquityBase) | constructor (same as above) | Price source (PriceFeedProxy in the DF configuration. [Oracle.md](Oracle.md)) |
| `troveNFT` | `ITroveNFT` internal immutable (inherited from AddRemoveManagers) | constructor (same as above) | Basis for determining the Trove owner. `ownerOf(troveId)` |
| `addManagerOf` | `mapping(uint256 => address)` public (inherited from AddRemoveManagers) | Set by openTrove / setAddManager | Delegate for “deposit-side” operations on a Trove (adding collateral and repayment). **When zero, anyone can perform deposit-side operations** (default). Setting the owner itself restricts them to the owner |
| `removeManagerReceiverOf` | `mapping(uint256 => RemoveManagerReceiver{manager,receiver})` public (inherited from AddRemoveManagers) | Set by openTrove / setRemoveManager(WithReceiver) | Delegate for “withdrawal-side” operations from a Trove (withdrawing collateral, borrowing, and closing), and recipient of withdrawn funds. **When zero, no one other than the owner can perform withdrawal-side operations** (default). If receiver is zero, the owner is the recipient |
| `addressesRegistry` | `IAddressesRegistry` internal immutable | constructor | Canonical risk-lifecycle source; used for the Trove-open gate and Registry-only sync caller check |
| `collToken` | `IERC20` internal immutable | constructor (AddressesRegistry) | Collateral token for this branch (= dToken. [dToken.md](dToken.md)) |
| `troveManager` | `ITroveManager` internal | Set in constructor (no subsequent modification path) | Destination for state update hooks and caller verification (`onLiquidateTrove`) |
| `gasPoolAddress` | `address` internal | constructor (same as above) | Custody destination for WETH gas compensation (`ETH_GAS_COMPENSATION`) |
| `collSurplusPool` | `ICollSurplusPool` internal | constructor (same as above) | Custody destination for liquidation surplus collateral (delegate target of `claimCollateral`) |
| `jpydfToken` | `IJpydfToken` internal | constructor (same as above) | Mint/burn target for JPYdf |
| `sortedTroves` | `ISortedTroves` internal | constructor (same as above) | Insertion, deletion, and reinsertion into the interest-rate-ordered list |
| `WETH` | `IWETH` internal immutable | constructor (same as above) | WETH locked as liquidation gas compensation |
| `CCR` | `uint256` public | constructor / `syncRiskParams` (AddressesRegistry. Branch-specific values are in [Parameters.md](../../../Parameters.md)) | Critical threshold. Borrowing and similar operations are restricted when TCR < CCR; synchronized once when a reserved branch is finalized |
| `SCR` | `uint256` public | constructor / `syncRiskParams` (same as above) | Shutdown threshold. `shutdown()` is possible when TCR < SCR |
| `hasBeenShutDown` | `bool` public | `false` → `true` in `_applyShutdown()` | Shutdown-completed flag. Once it becomes true, there is no path to revert it |
| `MCR` | `uint256` public | constructor / `syncRiskParams` (same as above) | Minimum collateral ratio for individual Troves |
| `BCR` | `uint256` public | constructor / `syncRiskParams` (same as above) | Additional MCR buffer imposed on batch-member Troves |

| `interestIndividualDelegateOf` | `mapping(uint256 => InterestIndividualDelegate{account,minInterestRate,maxInterestRate,minInterestRateChangePeriod})` private | Set by setInterestIndividualDelegate | Interest rate change delegation per Trove (does not touch debt or collateral). Query via `getInterestIndividualDelegateOf` |
| `interestBatchManagerOf` | `mapping(uint256 => address)` public | Set by openTroveAndJoin… / setInterestBatchManager; cleared on close/remove/kick/liquidation | The batch manager to which the Trove belongs (zero = not affiliated) |
| `interestBatchManagers` | `mapping(address => InterestBatchManager{minInterestRate,maxInterestRate,minInterestRateChangePeriod})` private | Set by registerBatchManager (immutable thereafter and cannot be deleted) | Registration record for a batch manager. `maxInterestRate > 0` is used to determine "registered". Query via `getInterestBatchManager` / `checkBatchManagerExists` |


### TroveManager State Variables

Declaration order (inherited LiquityBase fields are listed first. LiquityBase itself is specified in the CORE-LIB section).

| Variable | Type / Visibility | Initial Value / Set In | Meaning / Accounting Role |
| --- | --- | --- | --- |
| `activePool` | `IActivePool` public (inherited) | constructor (from AddressesRegistry) | Interface for interest aggregation and collateral transfers |
| `defaultPool` | `IDefaultPool` internal (inherited) | constructor | Storage destination for redistributed pending debt and collateral |
| `priceFeed` | `IPriceFeed` internal (inherited) | constructor | Price source (PriceFeedProxy, [Oracle.md](Oracle.md)) |
| `addressesRegistry` | `IAddressesRegistry` internal immutable | constructor | Used to enforce that only the Registry can synchronize risk parameters |
| `troveNFT` | `ITroveNFT` public | constructor | Trove ownership NFT. Minted on opening and burned on closure/liquidation |
| `borrowerOperations` | `IBorrowerOperations` public | constructor | The sole caller of `on*`. Calls `onLiquidateTrove` in reverse during liquidation |
| `stabilityPool` | `IStabilityPool` public | constructor | Liquidation offset destination |
| `gasPoolAddress` | `address` internal | constructor | Source holding WETH gas compensation (CORE-GP section) |
| `collSurplusPool` | `ICollSurplusPool` internal | constructor | Storage destination for surplus collateral from liquidation |
| `jpydfToken` | `IJpydfToken` internal | constructor | Used for burn and balance checks in `urgentRedemption` |
| `sortedTroves` | `ISortedTroves` public | constructor | Doubly linked list ordered by annual interest rate. Used for Redemption traversal and removal on closure |
| `collateralRegistry` | `ICollateralRegistry` internal | constructor | The sole caller of `redeemCollateral` |
| `WETH` | `IWETH` internal immutable | constructor | Payment token for gas compensation (`ETH_GAS_COMPENSATION`) |
| `CCR` | `uint256` public | constructor / `syncRiskParams` (from AddressesRegistry) | Branch Critical ratio; synchronized once when a reserved branch is finalized. Value is in [Parameters.md](../../../Parameters.md) |
| `MCR` | `uint256` internal | constructor / `syncRiskParams` | Liquidation threshold for an individual Trove. Value is in [Parameters.md](../../../Parameters.md) |
| `SCR` | `uint256` internal | constructor / `syncRiskParams` | shutdown threshold (also used for redeemability checks). Value is in [Parameters.md](../../../Parameters.md) |
| `LIQUIDATION_PENALTY_SP` | `uint256` internal | constructor / `syncRiskParams` | Liquidation penalty rate for the SP offset portion. Value is in [Parameters.md](../../../Parameters.md) |
| `LIQUIDATION_PENALTY_REDISTRIBUTION` | `uint256` internal | constructor / `syncRiskParams` | Liquidation penalty rate for the redistribution portion. Value is in [Parameters.md](../../../Parameters.md) |
| `Troves` | `mapping(uint256 => Trove)` public | Each `on*` / liquidation / Redemption | Trove ledger (table below) |
| `batches` | `mapping(address => Batch)` internal | batch-related `on*` / liquidation / Redemption | Batch ledger (table below). External reads only via `getLatestBatchData` |
| `totalStakes` | `uint256` internal | Increased/decreased on opening/adjustment/closure/liquidation/Redemption | Total stake of all active and zombie Troves. Denominator for redistribution |
| `totalStakesSnapshot` | `uint256` internal | Updated immediately after liquidation | `totalStakes` immediately after the latest liquidation. Numerator coefficient for calculating new stakes |
| `totalCollateralSnapshot` | `uint256` internal | Updated immediately after liquidation | Total collateral immediately after the latest liquidation (AP + DP, excluding gas compensation). Denominator for calculating new stakes |
| `L_coll` | `uint256` internal | Monotonically increases in `_redistributeDebtAndColl` | Cumulative redistributed collateral per 1 unit of stake. A Trove's share is `stake × (L_coll − snapshot.coll) / 1e18` |
| `L_jpydfDebt` | `uint256` internal | Same as above | Cumulative redistributed debt per 1 unit of stake. Share is `stake × (L_jpydfDebt − snapshot.jpydfDebt) / 1e18` |
| `rewardSnapshots` | `mapping(uint256 => RewardSnapshot)` public | On each Trove state update | Reference point for each Trove's `L_coll` / `L_jpydfDebt`. The difference is unapplied redistribution gain |
| `TroveIds` | `uint256[]` internal | Pushed on opening; swap-and-pop on closure/liquidation | Array of all active and zombie Trove IDs (for off-chain hint calculation) |
| `batchIds` | `address[]` public | Pushed by `onRegisterBatchManager` (no deletion) | Array for enumerating all batch managers |
| `lastZombieTroveId` | `uint256` public | Updated by Redemption / return to active / closure | Pointer to the Trove made zombie by a partial redeem. The next Redemption consumes it with highest priority (0 = none) |
| `lastCollError_Redistribution` | `uint256` internal | `_redistributeDebtAndColl` | Carry-over of floor-division error for redistributed collateral (error feedback) |
| `lastJpydfDebtError_Redistribution` | `uint256` internal | Same as above | Carry-over of floor-division error for redistributed debt |
| `shutdownTime` | `uint256` public | `block.timestamp` in `shutdown()` | Branch shutdown time. 0 = not shutdown. Basis for interest freeze and enabling urgentRedemption |
| `collGasCompensationCap` | `uint256` internal | constructor / one-shot `syncRiskParams` | Collateral compensation cap; fixed once the branch is finalized (CORE-LIB-FR-003) |

**Trove Struct** (`Troves[troveId]`)

| Field | Type | Meaning |
| --- | --- | --- |
| `debt` | `uint256` | Recorded debt (principal including interest as of the latest update). **0 for batch-affiliated Troves** (debt is managed by batch shares) |
| `coll` | `uint256` | Recorded collateral (does not include unapplied redistribution gain) |
| `stake` | `uint256` | Stake for redistribution allocation (derived from collateral under the rules of CORE-TM-FR-003) |
| `status` | `Status` (uint8) | `0 nonExistent / 1 active / 2 closedByOwner / 3 closedByLiquidation / 4 zombie` |
| `arrayIndex` | `uint64` | Its own position in the `TroveIds` array |
| `lastDebtUpdateTime` | `uint64` | Time when `debt` was last finalized (starting point for interest accrual). Unused for batch affiliation (managed on the batch side) |
| `lastInterestRateAdjTime` | `uint64` | Time when the interest rate was last changed (used by BO to determine premature adjustment fee) |
| `annualInterestRate` | `uint256` | Individual annual interest rate. **0 for batch-affiliated Troves** (batch rate applies) |
| `interestBatchManager` | `address` | Affiliated batch manager (`address(0)` = not affiliated) |
| `batchDebtShares` | `uint256` | Shares in the batch debt |

**Batch Struct** (`batches[batchManager]`) — a batch is treated as "one large Trove"; debt is prorated by shares, while collateral is held per Trove and the aggregate value is also recorded.

| Field | Type | Meaning |
| --- | --- | --- |
| `debt` | `uint256` | Recorded batch debt (principal after interest and management fee are applied) |
| `coll` | `uint256` | Total collateral of Troves in the batch |
| `arrayIndex` | `uint64` | Position in the `batchIds` array |
| `lastDebtUpdateTime` | `uint64` | Time when batch debt was last finalized (starting point for interest and management fee) |
| `lastInterestRateAdjTime` | `uint64` | Time when the batch interest rate was last changed |
| `annualInterestRate` | `uint256` | Batch annual interest rate (applies to all affiliated Troves) |
| `annualManagementFee` | `uint256` | Annual management fee rate of the batch manager |
| `totalDebtShares` | `uint256` | Total amount of issued debt shares |

**RewardSnapshot Struct** (`rewardSnapshots[troveId]`): `coll` (`L_coll` at acquisition time) / `jpydfDebt` (`L_jpydfDebt` at acquisition time).

### State Variables of StabilityPool / DFStabilityPool

Structs: `Deposit { uint256 initialValue }` (deposit amount at the depositor's last operation) / `Snapshots { uint256 S; uint256 P; uint256 B; uint256 scale }` (snapshot of cumulative values at the time of deposit).

| Variable | Type / Visibility | Initial Value / Set In | Meaning / Accounting Role |
| --- | --- | --- | --- |
| `activePool` | `IActivePool` public (LiquityBase inherited / storage) | constructor (from AddressesRegistry) | Destination for interest mint requests (`mintAggInterest`), source of liquidation collateral, and the only authorized caller of `triggerJpydfRewards` |
| `defaultPool` | `IDefaultPool` internal (LiquityBase inherited / storage) | constructor | Used only for aggregating `getEntireBranchColl/Debt` |
| `priceFeed` | `IPriceFeed` internal (LiquityBase inherited / storage) | constructor | **Unused in SP** (LiquityBase TCR-related internal functions are also not called from SP). The PriceFeed implementation is PriceFeedProxy ([Oracle.md](Oracle.md)) |
| `NAME` | `string` public constant | `"StabilityPool"` (**same value in DFStabilityPool**) | Identification name |
| `collToken` | `IERC20` public immutable | constructor (`collToken()` from registry) | Branch collateral token = dToken ([dToken.md](dToken.md)). Token used as the transfer target for gain payouts |
| `troveManager` | `ITroveManager` public immutable | constructor | The only authorized caller of `offset` |
| `jpydfToken` | `IJpydfToken` public immutable | constructor | Deposit receipt (`sendToPool`), payout (`returnFromPool`), and offset burning (`burn`) |
| `collBalance` | `uint256` internal | 0 / increases in `offset`, decreases when gains are sent | Internal tracker for collateral that SP should hold. Excludes direct transfers and self-destruct receipts from accounting |
| `totalJpydfDeposits` | `uint256` internal | 0 / increases via deposits and compounding of kept yield, decreases via withdrawals and offsets | Total pool deposits. Denominator for `P`/`S`/`B` updates |
| `yieldGainsOwed` | `uint256` internal | 0 / increases in `_updateYieldRewardsSum`, decreases when gains are settled | Total yield already allocated to `B` but unpaid. Used as the upper-bound clamp for `getDepositorYieldGain` |
| `yieldGainsPending` | `uint256` internal | 0 / increases when received below the threshold, resets to 0 when the threshold is restored | Yield received while `totalJpydfDeposits < MIN_JPYDF_IN_SP` and not yet allocated to `B`. The actual JPYdf remains in the SP balance |
| `deposits` | `mapping(address => Deposit)` public | `_updateDepositAndSnapshots` | Deposit amount per depositor (value at the last operation. Current value is derived by CORE-SP-FR-011) |
| `depositSnapshots` | `mapping(address => Snapshots)` public | `_updateDepositAndSnapshots` (deleted when deposit becomes 0) | Depositor snapshots of `P`/`S`/`B`/`scale` |
| `stashedColl` | `mapping(address => uint256)` public | `_updateDepositAndSnapshots` / `claimAllCollGains` | Accumulated collateral gains retained instead of received when `_doClaim=false` |
| `P` | `uint256` public | `P_PRECISION` (at declaration) / updated in `offset` | Running product. Represents the deposit depletion rate relative to the time of deposit (36-digit precision) |
| `P_PRECISION` | `uint256` public constant | `1e36` | Representation of "1.0" for `P` |
| `SCALE_FACTOR` | `uint256` public constant | `1e9` | Multiplier applied to `P` when advancing the scale. 1 scale = depletion to 1 / 1e9 |
| `MAX_SCALE_FACTOR_EXPONENT` | `uint256` public constant | `8` | Maximum exponent by which `SCALE_FACTOR` can be raised without overflow (`1e9^8 = 1e72 < 2^256`; the 9th power is not possible). Deposits with a scale difference greater than this are evaluated as 0 |
| `SCALE_SPAN` | `uint256` public constant | `2` | Upper limit on the number of scale crossings over which an untouched deposit can continue receiving gains |
| `currentScale` | `uint256` public | 0 / +1 in the `offset` scale loop | Cumulative number of times `P` has been multiplied by `SCALE_FACTOR` |
| `scaleToS` | `mapping(uint256 => uint256)` public | Added in `offset` | Cumulative collateral gain sum by scale (P-weighted: `+= P * coll / totalJpydfDeposits`) |
| `scaleToB` | `mapping(uint256 => uint256)` public | Added in `_updateYieldRewardsSum` | Cumulative JPYdf yield gain sum by scale (same as above) |
| `lastDepositBlock` 🟡 | `mapping(address => uint256)` public (**DFStabilityPool only**) | 0 / `block.number` in `provideToSP` | Last deposit block number for the same-block collateral-claim and withdrawal guard (CORE-SP-FR-004, CORE-MOD-004 (§2 DF Difference Ledger)) |


### State Variables of ActivePool

| Variable | Type / Visibility | Initial Value / Set In | Meaning / Accounting Role |
| --- | --- | --- | --- |
| `NAME` | `string public constant` | `"ActivePool"` | Contract identifier |
| `collToken` | `IERC20 public immutable` | Constructor (`AddressesRegistry.collToken()`) | Branch collateral token. In jpydf, this is dToken ([dToken.md](dToken.md)) |
| `borrowerOperationsAddress` | `address public immutable` | Constructor (AddressesRegistry) | For caller restrictions and wiring |
| `troveManagerAddress` | `address public immutable` | Constructor (AddressesRegistry) | For caller restrictions and wiring |
| `defaultPoolAddress` | `address public immutable` | Constructor (AddressesRegistry) | Destination for redistribution collateral. Infinite approval is granted in the constructor |
| `jpydfToken` | `IJpydfToken public immutable` | Constructor (AddressesRegistry) | Token to mint interest and batch fees to (JPYdf) |
| `interestRouter` | `IInterestRouter public immutable` | Constructor (AddressesRegistry) | Mint destination for the remaining 25% of aggregate interest. `IInterestRouter` is an empty interface with no functions (the receiving endpoint may be any address). In DF dToken wiring, this is bound to `InterestRouterForwarder`, and the recipient / owner are managed via env and handover/verify (CORE-AP-TBD-001 is resolved) |
| `stabilityPool` | `IJpydfRewardsReceiver public immutable` | Constructor (AddressesRegistry) | Mint destination for the SP's 75% share and notification target for `triggerJpydfRewards`. Held as type `IJpydfRewardsReceiver` rather than `IStabilityPool` to avoid dependency cycles |
| `collBalance` | `uint256 internal` | 0 | **Accounting** collateral balance. Increases/decreases are recorded independently from the actual token balance (directly transferred collateral is not reflected). Exposed by `getCollBalance()` |
| `aggRecordedDebt` | `uint256 public` | 0 | Aggregate recorded debt ("D" in the spec). Sum of the recorded debt of all active Troves, finalized aggregate interest, finalized upfront fees, and applied batch management fees. Updated whenever a Trove's debt is touched and whenever aggregate interest is minted. Does not include debt awaiting redistribution (on the DefaultPool side) |
| `aggWeightedDebtSum` | `uint256 public` | 0 | Sum of each Trove's recorded debt × its selected annual interest rate ("S" in the spec, 1e18-scale product). Updated by the delta between new/old weighted debt during individual Trove operations. Basis for linear calculation of pending interest |
| `lastAggUpdateTime` | `uint256 public` | 0 | Time when aggregate interest was last finalized (minted). Updated to `block.timestamp` each time `_mintAggInterest` runs |
| `shutdownTime` | `uint256 public` | 0 | Branch shutdown time. If 0, not shut down. Once set, there is no reset path (in the core wiring). After it is set, `calcPendingAggInterest()` is permanently 0 |
| `aggBatchManagementFees` | `uint256 public` | 0 | Aggregate batch management fees that have been finalized (recorded) but not yet applied to any batch's recorded debt. Moved to `aggRecordedDebt` when applied |
| `aggWeightedBatchManagementFeeSum` | `uint256 public` | 0 | Sum of each batched Trove's recorded debt × its batch's annual management fee. Updated by the new/old delta during batched Trove operations |
| `lastAggBatchManagementFeesUpdateTime` | `uint256 public` | 0 | Time when batch management fee aggregation was last finalized |


### State Variables of DefaultPool

| Variable | Type / Visibility | Initial Value / Set In | Meaning / Accounting Role |
| --- | --- | --- | --- |
| `NAME` | `string public constant` | `"DefaultPool"` | Contract identifier |
| `collToken` | `IERC20 public immutable` | Constructor (`AddressesRegistry.collToken()`) | Branch collateral token (dToken, [dToken.md](dToken.md)) |
| `troveManagerAddress` | `address public immutable` | Constructor (AddressesRegistry) | For caller restrictions |
| `activePoolAddress` | `address public immutable` | Constructor (AddressesRegistry) | Counterparty for caller restrictions and collateral transfer. Infinite approval is granted in the constructor |

| `collBalance` | `uint256 internal` | 0 | Accounting pending collateral balance (sum of redistributed but unapplied amounts). Exposed via `getCollBalance()` |
| `JpydfDebt` | `uint256 internal` | 0 | Sum of redistributed but unapplied JPYdf debt (the uppercase B in the variable name comes from the base notation). Exposed via `getJpydfDebt()` |


### CollSurplusPool State Variables

| Variable | Type / Visibility | Initial Value / Set In | Meaning / Accounting Role |
| --- | --- | --- | --- |
| `NAME` | `string public constant` | `"CollSurplusPool"` | Contract identifier name |
| `collToken` | `IERC20 public immutable` | Constructor (`AddressesRegistry.collToken()`) | Branch collateral token (dToken, [dToken.md](dToken.md)) |
| `borrowerOperationsAddress` | `address public immutable` | Constructor (AddressesRegistry) | Used to restrict the caller of claimColl |
| `troveManagerAddress` | `address public immutable` | Constructor (AddressesRegistry) | Used to restrict the caller of accountSurplus |
| `collBalance` | `uint256 internal` | 0 | Total accounting surplus collateral (= sum of balances for all accounts). Exposed via `getCollBalance()` |
| `balances` | `mapping(address => uint256) internal` | Empty | Claimable collateral balance by account (Trove owner at the time of liquidation). Exposed via `getCollateral()` |


### GasPool State Variables

| Variable | Type / Visibility | Initial Value / Set In | Meaning / Accounting Role |
| --- | --- | --- | --- |
| (None. Storage is unused. WETH / BorrowerOperations / TroveManager are local variables in the constructor) | — | — | — |


### SortedTroves State Variables

| Variable | Type / Visibility | Initial Value / Set In | Meaning / Accounting Role |
| --- | --- | --- | --- |
| `ROOT_NODE_ID` | `uint256 constant` (file level) | `0` | ID of the sentinel (root) node that holds head/tail. `getNext()`/`getPrev()` traversal terminates at this ID |
| `NAME` | `string public constant` | `"SortedTroves"` | Contract name |
| `UNINITIALIZED_ID` | `uint256 constant` (internal) | `0` | Documentation constant representing an "uninitialized ID" (value is the same as ROOT_NODE_ID, 0) |
| `BAD_HINT` | `uint256 constant` (internal) | `0` | Documentation constant representing an "invalid hint" (same as above) |
| `borrowerOperationsAddress` | `address public immutable` | constructor (`AddressesRegistry.borrowerOperations()`) | Sole caller for insertion and reinsertion operations. For removal operations, one of the callers alongside TM |
| `troveManager` | `ITroveManager public immutable` | constructor (`AddressesRegistry.troveManager()`) | Interest-rate reference used for ordering decisions (`getTroveAnnualInterestRate`). Caller for removal operations |
| `size` | `uint256 public` | `0` | Current number of nodes (matches the number of active non-zombie Troves) |
| `nodes` | `mapping(uint256 => Node) public` | `nodes[0]` is initialized as a self-loop in the constructor | Forward/back links, batchId, and existence flag for each node. `nodes[ROOT_NODE_ID]` is the sentinel that holds the head (`nextId`) and tail (`prevId`), eliminating the need for special handling of empty lists, first/last elements, and single-element lists |
| `batches` | `mapping(BatchId => Batch) public` | — | batch manager address → slice `head`/`tail` |

Structs (defined in the implementation, not specified by ISortedTroves):

- `Node { uint256 nextId (next = lower-interest-rate side), uint256 prevId (previous = higher-interest-rate side), BatchId batchId (0 for non-batch nodes), bool exists }`
- `Batch { uint256 head, uint256 tail }`
- `Position { uint256 prevId, uint256 nextId }` (in-memory struct that carries the current position during search)


### TroveNFT State Variables

| Variable | Type / Visibility | Initial Value / Set In | Meaning / Accounting Role |
| --- | --- | --- | --- |
| `troveManager` | `ITroveManager public immutable` | constructor (`AddressesRegistry.troveManager()`) | Sole caller for mint/burn. Reference source for Trove data in tokenURI |
| `collToken` | `IERC20Metadata internal immutable` | constructor (`AddressesRegistry.collToken()`) | Branch collateral token (dToken in jpydf). Used for name/symbol derivation and metadata display. **No getter (internal)** |
| `jpydfToken` | `IJpydfToken internal immutable` | constructor (`AddressesRegistry.jpydfToken()`) | Address displayed in the Debt Token field of metadata. **No getter (internal)** |
| `metadataNFT` | `IMetadataNFT public immutable` | constructor (`AddressesRegistry.metadataNFT()`) | Delegate target for tokenURI rendering (not replaceable) |
| (Inherited: OZ v4.9 `ERC721`) | `string private _name` / `string private _symbol` / `mapping _owners` / `mapping _balances` / `mapping _tokenApprovals` / `mapping _operatorApprovals` | constructor / each ERC-721 operation | ERC-721 standard ownership and approval ledger |

MetadataNFT (separate contract, rendering-only, shareable across branches):

| Variable | Type / Visibility | Initial Value / Set In | Meaning |
| --- | --- | --- | --- |
| `assetReader` | `FixedAssetReader public immutable` | constructor | Reader for fixed assets stored in SSTORE2 (Geist font, JPYdf logo, registered collateral logos, etc.) |


### JpydfToken State Variables

| Variable | Type / Visibility | Initial Value / Set In | Meaning / Accounting Role |
| --- | --- | --- | --- |
| `_NAME` | `string internal constant` | `"JPYdf Stablecoin"` 🟡 (CORE-MOD-001 (§2.2)) | Used for both the ERC-20 name and the EIP-712 domain name |
| `_SYMBOL` | `string internal constant` | `"JPYdf"` 🟡 (CORE-MOD-001 (§2.2)) | ERC-20 symbol |
| `collateralRegistryAddress` | `address public` | Set once by `setCollateralRegistry` | Single CR address with burn authority |
| `troveManagerAddresses` | `mapping(address => bool)` (internal) | Only true entries are added by `setBranchAddresses` | Burn authority set (TM for each branch) |
| `stabilityPoolAddresses` | `mapping(address => bool)` (internal) | Only true entries are added by `setBranchAddresses` | Burn / sendToPool / returnFromPool authority set |
| `borrowerOperationsAddresses` | `mapping(address => bool)` (internal) | Only true entries are added by `setBranchAddresses` | Mint / burn authority set |
| `activePoolAddresses` | `mapping(address => bool)` (internal) | Only true entries are added by `setBranchAddresses` | Mint authority set (issuer of interest and management fees) |
| (Inherited: Ownable) `_owner` | `address private` | `_owner` argument in the constructor, then `address(0)` via `_renounceOwnership()` inside `setCollateralRegistry` | Administrator valid only during deployment wiring |
| (Inherited: ERC20) `_balances` / `_allowances` / `_totalSupply` / `_name` / `_symbol` | OZ v4.9.5 standard storage | constructor (`_name`/`_symbol` are `_NAME`/`_SYMBOL`) | Source of truth for ERC-20 accounting |
| (Inherited: ERC20Permit) `_nonces` (storage) / `_PERMIT_TYPEHASH_DEPRECATED_SLOT` (storage, OZ compatibility placeholder, unused) | OZ v4.9.5 standard | — | EIP-2612 replay prevention |
| (Inherited: EIP712) `_nameFallback` / `_versionFallback` (storage, used only when name/version exceed 31 bytes = always empty in this configuration) / `_cachedDomainSeparator` / `_cachedChainId` / `_cachedThis` / `_hashedName` / `_hashedVersion` / `_name` / `_version` (immutable) | OZ v4.9.5 standard | Fixed in the constructor as `EIP712(_NAME, "1")` | EIP-712 domain (name is the 🟡 CORE-MOD-001 value) |


### CollateralRegistry State Variables

| Variable | Type / Visibility | Initial Value / Set In | Meaning / Accounting Role |
| --- | --- | --- | --- |
| `totalCollaterals` | `uint256 public immutable` | constructor (`_tokens.length`, 1 to 10) | Number of branches. Loop upper bound |
| `token0` to `token9` | `IERC20Metadata internal immutable` × 10 | constructor (unused slots are `address(0)`) | Collateral token for each branch (dToken in DF). Represented as 10 separate variables because Solidity cannot have immutable arrays |

| `troveManager0` to `troveManager9` | `ITroveManager internal immutable` × 10 | constructor (unused slots are `address(0)`) | TroveManager for each branch. Execution target for redemptions |
| `jpydfToken` | `IJpydfToken public immutable` | constructor | JPYdf burned during redemptions |
| `baseRate` | `uint256 public` | `INITIAL_BASE_RATE` in constructor (value in §7), thereafter updated only by `redeemCollateral` | System-wide base redemption rate (common to all branches) |
| `lastFeeOperationTime` | `uint256 public` | Declaration initializer `block.timestamp` (= deployment time) | Reference time for baseRate decay. Advances only in rounded minute units |


### AddressesRegistry State Variables

| Variable | Type / Visibility | Initial Value / Set Location | Meaning / Accounting Role |
| --- | --- | --- | --- |
| `collToken` | `IERC20Metadata public` | Once in `setAddresses` | Branch collateral token (dToken in DF) |
| `borrowerOperations` | `IBorrowerOperations public` | Same as above | Branch BO |
| `troveManager` | `ITroveManager public` | Same as above | Branch TM |
| `troveNFT` | `ITroveNFT public` | Same as above | Branch TroveNFT |
| `metadataNFT` | `IMetadataNFT public` | Same as above | TroveNFT metadata |
| `stabilityPool` | `IStabilityPool public` | Same as above | Branch SP |
| `priceFeed` | `IPriceFeed public` | Same as above | Branch PriceFeed ([Oracle.md](Oracle.md)) |
| `activePool` | `IActivePool public` | Same as above | Branch AP |
| `defaultPool` | `IDefaultPool public` | Same as above | Branch DP |
| `gasPoolAddress` | `address public` | Same as above | Branch GasPool |
| `collSurplusPool` | `ICollSurplusPool public` | Same as above | Branch CollSurplusPool |
| `sortedTroves` | `ISortedTroves public` | Same as above | Branch SortedTroves |
| `interestRouter` | `IInterestRouter public` | Same as above | Recipient of residual interest (non-SP portion) |
| `hintHelpers` | `IHintHelpers public` | Same as above | Shared helper |
| `multiTroveGetter` | `IMultiTroveGetter public` | Same as above | Shared helper |
| `collateralRegistry` | `ICollateralRegistry public` | Same as above | Shared CR |
| `jpydfToken` | `IJpydfToken public` | Same as above | Shared JPYdf |
| `WETH` | `IWETH public` | Same as above | WETH for gas compensation |
| `CCR` | `uint256 public` | constructor / `finalizeRiskParams` (with validation) | Borrowing operations are restricted when TCR falls below this (value in [Parameters.md](../../../Parameters.md)) |
| `SCR` | `uint256 public` | constructor / `finalizeRiskParams` (with validation) | Branch shutdown becomes possible when TCR falls below this |
| `MCR` | `uint256 public` | constructor / `finalizeRiskParams` (with validation) | Minimum collateral ratio for individual Troves |
| `BCR` | `uint256 public` | constructor / `finalizeRiskParams` (with validation) | Buffer added on top of MCR when joining a batch or adjusting within a batch |
| `LIQUIDATION_PENALTY_SP` | `uint256 public` | constructor / `finalizeRiskParams` (with validation) | Penalty rate for SP offset liquidation |
| `LIQUIDATION_PENALTY_REDISTRIBUTION` | `uint256 public` | constructor / `finalizeRiskParams` (with validation) | Penalty rate for redistribution liquidation |
| `riskParamsFinalizer` | `address public immutable` | constructor | One-shot finalizer for a reserved branch; `address(0)` identifies a deploy-time-finalized branch |
| `riskParamsFinalized` | `bool public` | constructor sets true for a zero finalizer and false otherwise; `finalizeRiskParams` sets true | Canonical risk-lifecycle flag; there is no true-to-false transition |
| (Inherited: Ownable) `_owner` | `address private` | `_owner` argument in constructor, then `address(0)` via `_renounceOwnership()` inside `setAddresses` | Administrator valid only during the deployment wiring period |


### HintHelpers State Variables

| Variable | Type / Visibility | Initial Value / Set Location | Meaning / Accounting Role |
| --- | --- | --- | --- |
| `NAME` | `string public constant` | `"HintHelpers"` | Contract identifier |
| `collateralRegistry` | `ICollateralRegistry public immutable` | constructor | Entry point for all branches. Resolves branches via `getTroveManager(_collIndex)` |


### MultiTroveGetter State Variables

| Variable | Type / Visibility | Initial Value / Set Location | Meaning / Accounting Role |
| --- | --- | --- | --- |
| `collateralRegistry` | `ICollateralRegistry public immutable` | constructor | Entry point for branch resolution |


### DebtInFrontHelper State Variables

| Variable | Type / Visibility | Initial Value / Set Location | Meaning / Accounting Role |
| --- | --- | --- | --- |
| `collateralRegistry` | `ICollateralRegistry public immutable` | constructor | Entry point for branch resolution |
| `hintHelpers` | `IHintHelpers public immutable` | constructor | Delegation target for `getApproxHint` (speeds up the scan starting point) |


### RedemptionHelper State Variables

| Variable | Type / Visibility | Initial Value / Set Location | Meaning / Accounting Role |
| --- | --- | --- | --- |
| `numBranches` | `uint256 public immutable` | constructor (`_addresses.length`) | Number of branches. Constructor validates that it matches CR's `totalCollaterals()` |
| `collateralRegistry` | `ICollateralRegistry public immutable` | constructor | Redemption execution target and entry point for branch resolution |
| `jpydfToken` | `IJpydfToken public immutable` | constructor (`collateralRegistry.jpydfToken()`) | JPYdf burned during redemptions |
| `addresses` | `IAddressesRegistry[] public` (storage) | Pushed in constructor | AddressesRegistry for each branch. Used to resolve `troveManager` / `sortedTroves` / `priceFeed`. Storage cost is accepted because simulations are off-chain only (comment in code) |


### LiquidationCandidateGetter State Variables

| Variable | Type / Visibility | Initial Value / Set Location | Meaning / Accounting Role |
| --- | --- | --- | --- |
| `collateralRegistry` | `ICollateralRegistry public immutable` | constructor | Entry point for branch resolution |


### Constants.sol State Variables

All are `constant` (declaration order). "References" indicates references in production code (under `contracts/src/`, excluding tests and scripts).

**(a) Upstream-derived constants (same values as base except for 🟡 2 items)**

| Constant | Type | Value | Meaning / Accounting Role | References |
| --- | --- | --- | --- | --- |
| `DECIMAL_PRECISION` | uint256 | `1e18` | Scale basis for 18-decimal fixed point. Denominator for all ratio calculations such as CRs, interest rates, and distribution rates | LiquityBase / LiquityMath / TroveManager / BorrowerOperations / ActivePool / CollateralRegistry / HintHelpers / RedemptionHelper / Zappers / PriceFeeds |
| `_100pct` | uint256 | `DECIMAL_PRECISION` | 100% (= 1e18) | TroveManager / RedemptionHelper |
| `_1pct` | uint256 | `DECIMAL_PRECISION / 100` | 1% (= 1e16). Derivation base for percentage-denominated constants | Only derived constants within Constants.sol |
| `ETH_GAS_COMPENSATION` | uint256 | `0.0375 ether` | Amount of WETH locked in GasPool when a Trove is opened (fixed gas compensation paid to the liquidator during liquidation). **Denominated in WETH regardless of collateral branch** (even when collateral = dToken, compensation is WETH. Outside the scope of [dToken.md](dToken.md)) | BorrowerOperations / TroveManager / Zappers |
| `MIN_LIQUIDATION_PENALTY_SP` | uint256 | `5e16` (5%) | Lower bound for per-branch `LIQUIDATION_PENALTY_SP`. Validated by AddressesRegistry constructor (`SPPenaltyTooLow`) | AddressesRegistry |
| `MAX_LIQUIDATION_PENALTY_REDISTRIBUTION` | uint256 | `20e16` (20%) | Upper bound for per-branch `LIQUIDATION_PENALTY_REDISTRIBUTION`. Validated by AddressesRegistry constructor (`RedistPenaltyTooHigh`) | AddressesRegistry |
| `COLL_GAS_COMPENSATION_DIVISOR` | uint256 | `200` | Collateral gas compensation rate for liquidators (1/200 of collateral = 0.5%) | TroveManager |
| `COLL_GAS_COMPENSATION_CAP` / `COLL_GAS_COMPENSATION_CAP_DWSTETH` 🟡 | uint256 | `1_000 ether` / `2 ether` | CORE-LIB-FR-003 / CORE-MOD-003 | TroveManager constructor / DeployLiquity2 |
| `MIN_DEBT` 🟡 | uint256 | base: `2000e18` → **DF: `100_000e18`** | Minimum debt a Trove must maintain (entire debt denominated in JPYdf). CORE-LIB-FR-002 / CORE-MOD-002 | BorrowerOperations / TroveManager |
| `MIN_ANNUAL_INTEREST_RATE` | uint256 | `_1pct / 2` (0.5%) | Lower bound on Trove annual interest rate | BorrowerOperations |
| `MAX_ANNUAL_INTEREST_RATE` | uint256 | 250% | Upper bound on Trove annual interest rate | BorrowerOperations |
| `MAX_ANNUAL_BATCH_MANAGEMENT_FEE` | **uint128** | 10% | Upper bound on batch management fee (annualized; validated when registering a batch manager) | BorrowerOperations |
| `MIN_INTEREST_RATE_CHANGE_PERIOD` | **uint128** | `1 hours` | Lower bound on the interest rate change interval declared by a batch manager (applies only to batch Troves) | BorrowerOperations |
| `REDEMPTION_FEE_FLOOR` | uint256 | `_1pct / 2` (0.5%) | Lower bound on the redemption fee rate | CollateralRegistry |
| `MAX_BATCH_SHARES_RATIO` | uint256 | `1e9` | Upper bound on a batch's debt/shares ratio. Blocks attacks that inflate the ratio through share inflation and impair subsequent participants' allocations (code comment says reaching the upper bound would take over 217 years even with 10% annual compound interest) | TroveManager / BorrowerOperations |
| `REDEMPTION_MINUTE_DECAY_FACTOR` | uint256 | `998076443575628800` | Per-minute decay factor for baseRate (half-life 6 hours = 360 minutes, `(1/2)^(1/360)`) | CollateralRegistry |
| `REDEMPTION_BETA` | uint256 | `1` | Divisor for baseRate increase caused by redemption (1/ALPHA in the whitepaper) | CollateralRegistry |
| `INITIAL_BASE_RATE` | uint256 | `_100pct` (100%) | Initial baseRate immediately after deployment. Effectively suppresses redemptions during launch (makes them unprofitable except during a deep depeg) | CollateralRegistry |
| `URGENT_REDEMPTION_BONUS` | uint256 | `2e16` (2%) | Collateral bonus attached to urgent redemption after branch shutdown | TroveManager |
| `ONE_MINUTE` | uint256 | `1 minutes` | Time unit (minute conversion for baseRate decay) | CollateralRegistry |
| `ONE_YEAR` | uint256 | `365 days` | Denominator for prorating annual interest over elapsed time | LiquityBase / ActivePool / HintHelpers |
| `UPFRONT_INTEREST_PERIOD` | uint256 | `7 days` | Period covered by interest prepaid on borrowing or early interest-rate changes (average rate × 7 days) | BorrowerOperations / HintHelpers |
| `INTEREST_RATE_ADJ_COOLDOWN` | uint256 | `7 days` | Cooldown for interest rate adjustment. Readjustment within the period is subject to the upfront fee | BorrowerOperations / HintHelpers |
| `SP_YIELD_SPLIT` | uint256 | 75% | Allocation rate to the Stability Pool when minting aggregate interest (the remainder goes to LPs via interestRouter) | ActivePool |
| `MIN_JPYDF_IN_SP` | uint256 | `1e18` | Lower bound on total SP deposits (1 JPYdf). Withdrawals below this are prohibited, avoiding empty-pool boundary and initialization attack endpoints | StabilityPool / DFStabilityPool / TroveManager |
**(b) DF additions: branch-specific constant groups (CORE-MOD-005. upstream constants are unchanged)**

For each branch, there are six kinds of constants: `MCR_<BR>` / `CCR_<BR>` / `SCR_<BR>` / `BCR_<BR>` / `LIQUIDATION_PENALTY_SP_<BR>` / `LIQUIDATION_PENALTY_REDISTRIBUTION_<BR>` (`<BR>` is the suffix in the table below; 8 branches × 6 kinds = 48 constants, all uint256 constant). [Parameters.md](../../../Parameters.md) §1 / §2-A is authoritative for finalized active-branch values and reserved-branch deployment bootstrap inputs. Final reserved values come from the parameter Manifest approved for the exact Underlying and are verified through the `RiskParamsFinalized` receipt/event, Registry/BO getters, and TM atomic-sync evidence or block-pinned storage attestation. See CORE-LIB-FR-004 / CORE-AR-FR-005.

| Branch | suffix `<BR>` | dToken (Underlying) | Status |
| --- | --- | --- | --- |
| 0 | `DWSTETH` | dwstETH (wstETH) | confirmed; Day-1 active and preferred ETH branch |
| 1 | `DUSDC` | dUSDC (USDC) | confirmed |
| 2 | `DETH` | dETH (TBD) | bootstrap; unfinalized; inert (rederive before activation for the exact Underlying) |
| 3 | `DUSD_A` | dUSD-A (TBD) | bootstrap; unfinalized; inert |
| 4 | `DBTC` | dBTC (TBD) | bootstrap; unfinalized; inert |
| 5 | `DUSD_B` | dUSD-B (TBD) | bootstrap; unfinalized; inert |
| 6 | `DJPY` | dJPY (TBD) | bootstrap; unfinalized; inert |
| 7 | `DJGB` | dJGB (TBD) | bootstrap; unfinalized; inert (displayed BCR and redistribution penalty = 5%) |


### LiquityBase State Variables

| Variable | Type / Visibility | Initial Value / Set In | Meaning / Accounting Role |
| --- | --- | --- | --- |
| `activePool` | `IActivePool` public | constructor (resolved from AddressesRegistry) | Branch ActivePool. Storage destination for collateral and aggregate debt of active Troves |
| `defaultPool` | `IDefaultPool` internal | Same as above | Branch DefaultPool. Storage destination for unapplied (pending) liquidation redistributions. No getter |
| `priceFeed` | `IPriceFeed` internal | Same as above | Branch price feed. In DF, PriceFeedProxy is injected ([Oracle.md](Oracle.md)). No getter |


### LiquityMath State Variables

Not applicable (library; has no state).


### Ownable State Variables

| Variable | Type / Visibility | Initial Value / Set In | Meaning / Accounting Role |
| --- | --- | --- | --- |
| `_owner` | `address` private | `initialOwner` in constructor / `address(0)` in `_renounceOwnership` | Holder of onlyOwner authority. After wiring is complete, it is zeroed and privileged functions are permanently disabled |


### Types State Variables

Only file-level constants associated with type definitions.

| Constant | Type | Value | Meaning |
| --- | --- | --- | --- |
| `TROVE_ID_ZERO` | `TroveId` | `TroveId.wrap(0)` | Zero value (unset) |
| `TROVE_ID_END_OF_LIST` | `TroveId` | `TroveId.wrap(ROOT_NODE_ID)`=`wrap(0)` | End of the SortedTroves linked list (root node). Same value as `TROVE_ID_ZERO` (CORE-LIB-INV-003) |
| `BATCH_ID_ZERO` | `BatchId` | `BatchId.wrap(address(0))` | Zero value representing "not affiliated with a batch" |


---

## 8. Invariants (INV)

> Invariants are the criteria for invariant tests and audits. First, **8.1 Cross-Contract (CORE-SYS-INV-*)**, followed by scoped invariants that are contained within individual contracts. 🔵 Invariants describe properties satisfied by the base implementation and are also targets of parity verification.

### 8.1 Cross-Contract Invariants (CORE-SYS-INV-*)

#### CORE-SYS-INV-001: Branch Debt Decomposition Identity 🔵
- The branch's total debt is always decomposed as follows (this is the definition of `LiquityBase.getEntireBranchDebt` itself):
  `entireBranchDebt == AP.aggRecordedDebt + AP.calcPendingAggInterest() + AP.aggBatchManagementFees + AP.calcPendingAggBatchManagementFee() + DP.getJpydfDebt()`
- In addition, its relationship to individual Troves is `entireBranchDebt ≥ Σ_troves getLatestTroveData(i).entireDebt`. Any deviation from equality is limited to positive dust caused by asymmetric rounding (individual Trove interest is floor=CORE-LIB-FR-008, aggregate interest is ceil=CORE-AP-FR-002); system debt never falls below the sum of individual debts.
- **Verification**: invariant / parity
#### CORE-SYS-INV-002: Consistency of Weighted Debt Sums 🔵
- `AP.aggWeightedDebtSum == Σ(recordedDebt × annualInterestRate for Troves not affiliated with a batch) + Σ(batch recordedDebt × batch annualInterestRate)`. The batch management fee side has the same form (`aggWeightedBatchManagementFeeSum == Σ batch recordedDebt × managementFee`).
- This is maintained because every debt-changing operation (via BO, liquidation, redemption) updates the AP sums using old/new TroveChange (CORE-LIB-FR-015) pairs.
- **Verification**: invariant / parity
#### CORE-SYS-INV-003: Closure of JPYdf Supply Paths 🔵

- Existing Core debt-accounting paths that change `JpydfToken.totalSupply` are limited to the following. **Increase**: BO borrowing principal mint (CORE-BO-FR-001/002/003, etc.) / AP finalized mint of aggregate interest and upfront fees (CORE-AP-FR-007/008. Upfront fees are added to debt and supplied through AP aggregate minting) / batch management fee mint (CORE-AP-FR-009). **Decrease**: burn on BO repayment/close (CORE-BO-FR-003/007/009, etc.) / CR redemption burn (CORE-CR-FR-002) / TM urgent redemption burn (CORE-TM-FR-005) / SP offset burn (CORE-SP-FR-007).
- The bridge supply path is separated from Core `mint` / `burn` into `bridgeMint` / `bridgeBurn`, and only registered bridge minters can call it. On Day-1, `bridgeMinterCount == 0` and there is no pending proposal, so effective supply changes are closed to the Core debt-accounting paths (core-side basis for SYS-INV-003 in [Product-Overview](../Product-Overview.md)).
- **Verification**: parity / audit (complete confirmation of Core mint/burn call sites) + unit (dormant bridge state / bridge minter lifecycle)
#### CORE-SYS-INV-004: Accounting Consistency of Redemption 🔵
- In a single `CollateralRegistry.redeemCollateral`, the total amount of JPYdf that CR burns from the redeemer matches the sum of the debt decreases performed by each branch TM (`redeemedAmount == Σ_branches troveChange.debtDecrease`). Fees are realized not in JPYdf but as a **collateral deduction** (the collateral received by the redeemer decreases, and that amount remains in the Trove).
- **Verification**: parity / unit
#### CORE-SYS-INV-005: Collateral Conservation in Liquidation 🔵
- In the liquidation of each Trove, `collToSendToSP + collToRedistribute + collSurplus + collGasCompensation == entireColl` (decomposition in TM `_liquidate`; dust does not arise mathematically). Across the entire branch as well, the total collateral amount of "AP + DP + SP + CSP + liquidator receipt" is conserved before and after liquidation.
- **Verification**: invariant / parity / unit
#### CORE-SYS-INV-006: Accounting Consistency of Redistribution 🔵
- `DP.getJpydfDebt() == Σ (unapplied redistribution debt gains of all active/zombie Troves) ± rounding error`, with the same structure on the collateral side. Errors are corrected in the next liquidation by TM error feedback trackers (`lastJpydfDebtError_Redistribution` / `lastCollError_Redistribution`) and do not diverge cumulatively.
- **Verification**: invariant / parity
#### CORE-SYS-INV-007: Conservation of AP/DP Collateral Accounting 🔵
- The collateral held by a branch (the total collateral of open Troves) is always equal to `AP.getCollBalance() + DP.getCollBalance()` (`LiquityBase.getEntireBranchColl`). Collateral held by SP (liquidation gains) and collateral held by CSP (surplus) are not collateral of open Troves, and are separate accounts outside this identity.
- The internal tracker (`collBalance`) of each Pool is less than or equal to the actual balance `collToken.balanceOf` (the actual balance can exceed it by the amount of out-of-accounting tokens sent directly. This does not affect accounting = donation resistance, each SEC).
- **Verification**: invariant / parity
#### CORE-SYS-INV-008: WETH Consistency of GasPool 🔵
- `WETH.balanceOf(gasPool) ≥ number of open (active + zombie) Troves × ETH_GAS_COMPENSATION`. Equality holds when there are no direct sends (donations). Inflows are only open (CORE-BO-FR-001/002), and outflows are only close (return) and liquidation (payment to executor).
- **Verification**: invariant / parity
#### CORE-SYS-INV-009: Consistency Between SortedTroves and the Trove Set 🔵
- The node set of SortedTroves = the set of Troves in the corresponding branch with `status == active` (zombie / closed / liquidated are absent). The list is in descending order of interest rate (for the same rate, later entries go toward the tail = receive redemption first), and nodes belonging to a batch maintain a contiguous slice.
- Interest-rate and batch-membership changes and list reinsertion are performed **atomically in the same tx** within each BO operation (there is no observable state where the list position and the effective interest rate diverge).
- **Verification**: invariant / parity
#### CORE-SYS-INV-010: Consistency Between TroveNFT and Trove State 🔵
- `∀ troveId`: a TroveNFT exists (`ownerOf` can be resolved) ⇔ `TM.getTroveStatus(troveId) ∈ {active, zombie}`. Minting occurs only when a Trove is opened, and burning occurs only on close / liquidation (limited to the TM path = CORE-TN-SEC-001).
- **Verification**: invariant / parity
#### CORE-SYS-INV-011: Cross-Contract Maintenance of MIN_JPYDF_IN_SP 🔵
- Once an SP reaches `totalJpydfDeposits ≥ MIN_JPYDF_IN_SP`, it never falls below this after any subsequent operation. This holds through the combined discipline of both contracts: withdrawals use the SP postcondition require (CORE-SP-FR-003), and liquidations have TM limit the offsettable amount to `totalJpydfDeposits − MIN_JPYDF_IN_SP` (CORE-TM-FR-001).
- **Verification**: invariant / parity
#### CORE-SYS-INV-012: Discipline of MIN_DEBT and Zombies 🔵
- A Trove with `status == active` always has `entireDebt ≥ MIN_DEBT` (🟡 value is CORE-MOD-002 / [Parameters.md](../../../Parameters.md)). The only path that creates `entireDebt < MIN_DEBT` is partial repayment through redemption (→ becoming zombie). BO operations require the adjusted debt to satisfy MIN_DEBT, and zombie restoration (`adjustZombieTrove`) also requires recovery to at least MIN_DEBT.
- **Verification**: invariant / parity
#### CORE-SYS-INV-013: One-Time Shutdown (BO-TM Trust Boundary) 🔵
- Economic branch shutdown occurs only once. `TM.shutdown()` itself does not defend against overwriting `shutdownTime`; the one-time property is ensured by BO `hasBeenShutDown` in CORE-BO-FR-021 and BO-only TM authorization. Oracle-failure pause never calls `TM.shutdown()`. After `AP.setShutdownFlag`, `calcPendingAggInterest() == 0`.
- **Verification**: parity / unit (double shutdown impossible)
#### CORE-SYS-INV-014: No Sentinel Collision for troveId 🔵
- No Trove with `troveId == 0` exists (0 is the ROOT / list-end sentinel of SortedTroves). Collision or a zero value for `troveId = uint256(keccak256(abi.encode(msg.sender, owner, ownerIndex)))` is practically impossible, and duplication with an existing Trove is rejected by BO with `TroveExists` (status check).
- **Verification**: parity / unit

#### CORE-SYS-INV-015: Atomic Risk Finalization and Consumer Consistency 🟡
- On a finalized reserved branch, all six AddressesRegistry values match the four BO consumer copies and five TM risk copies, respectively; TM also stores the finalized compensation cap from the same calldata. No externally observable state can contain a partial update: if either child sync fails, the flag and all values roll back to their pre-transaction state.
- An unfinalized branch cannot open a Trove or accept an SP deposit, and the finalization inert-state checks prevent values from changing around existing supply, Troves, branch debt, branch collateral, or SP deposits.
- **Verification**: unit / invariant / deployment and activation evidence


### BorrowerOperations Invariants (CORE-BO-INV-*)

#### CORE-BO-INV-001: Monotonicity of hasBeenShutDown 🔵
`hasBeenShutDown` is monotonic (false → true only through `shutdown()`, never back to false). `isOracleFailureShutdown` is recoverable (false → true → false) and is cleared by economic shutdown. Verification: invariant.

#### CORE-BO-INV-002: Mutual Exclusion Between Delegate and Batch Membership 🔵
For any Trove, `interestIndividualDelegateOf[t].account != 0` and `interestBatchManagerOf[t] != 0` cannot both hold at the same time (the delegate is removed when joining a batch, and the Trove leaves the batch when a delegate is set). Verification: invariant.

#### CORE-BO-INV-003: Registered Guarantee for Batch Membership Destination 🔵
If `interestBatchManagerOf[t] != 0`, that address is a registered batch manager (`interestBatchManagers[m].maxInterestRate > 0`). Verification: invariant.

#### CORE-BO-INV-004: Immutability of Batch Manager Records 🔵
The record `(minInterestRate, maxInterestRate, minInterestRateChangePeriod)` of a registered batch manager is immutable after registration and cannot be deleted. The batch management fee is monotonically non-increasing from its value at registration (there is no function to increase it). Verification: invariant.

#### CORE-BO-INV-005: Wiring Immutability and Branch-Parameter Lifecycle 🔵/🟡
Wiring (addressesRegistry / troveManager / gasPoolAddress / collSurplusPool / jpydfToken / sortedTroves / collToken / WETH / troveNFT / activePool / defaultPool / priceFeed) and the infinite allowance from collToken → ActivePool do not change after construction. CCR / SCR / MCR / BCR are immutable after construction for an active branch, and after the single Registry-only synchronization transition for a reserved branch. Verification: invariant / deploy verification.

> Cross-contract: for "active Trove `entireDebt ≥ MIN_DEBT`", see CORE-SYS-INV-012; for "WETH consistency of GasPool", see CORE-SYS-INV-008; for "operation restrictions when TCR < CCR", see CORE-SYS-ERR-002 (the normative requirement is CORE-BO-ERR-001).


### TroveManager Invariants (CORE-TM-INV-*)

#### CORE-TM-INV-001: Consistency of totalStakes 🔵
`totalStakes` is always equal to the sum of the `stake` values of all active and zombie Troves (opening +, adjustments by delta, closure/liquidation −). Since it is the denominator for redistribution, allocation does not hold if this is broken. Verification: invariant / parity.

#### CORE-TM-INV-002: Monotonicity of L Values 🔵
`L_coll` / `L_jpydfDebt` are monotonically non-decreasing. Each Trove's `rewardSnapshots` are always less than or equal to the current L values, and the differences (unapplied gains) are non-negative. Verification: invariant.

#### CORE-TM-INV-003: Consistency of TroveIds / arrayIndex 🔵
`status ∈ {active, zombie}` ⇔ included in `TroveIds`. `TroveIds[Troves[id].arrayIndex] == id`. This is maintained after swap-and-pop (`_removeTroveId`). Verification: invariant.

#### CORE-TM-INV-004: Accounting Consistency of Batch Shares 🔵

For each batch, `batches[b].totalDebtShares == Σ (batchDebtShares of member Troves)`. For member Troves, `Troves.debt == 0` and `annualInterestRate == 0` (debt is represented only by shares). When decreasing to `_newTroveDebt == 0`, shares become exactly 0 and no fractional shares remain. Verification: invariant.

#### CORE-TM-INV-005: Consistency of lastZombieTroveId 🔵
If `lastZombieTroveId != 0`, the relevant Trove has `status == zombie` and, under normal operation, `entireDebt > 0` (at the time it was set, `0 < newDebt < MIN_DEBT`). Reset paths are full redemption through normal redemption, closure (`_closeTrove`), and return to active (`setTroveStatusToActive`). **Exception**: after shutdown, `urgentRedemption` does not process the zombie pointer, so if the pointed-to zombie is fully redeemed, the pointer may remain while `entireDebt == 0` (no practical impact because normal redemption will not occur after shutdown). Verification: invariant (normal operation) / unit (post-shutdown exception).

#### CORE-TM-INV-006: Boundedness of redistribution error 🔵
`lastCollError_Redistribution` / `lastJpydfDebtError_Redistribution` are less than `totalStakes` **at the time of the most recent redistribution execution** (because they are division remainders. If totalStakes later shrinks due to Trove closure, etc., they may exceed the current value). Error feedback prevents cumulative divergence between the total allocation and the `L` increment × `totalStakes`. Verification: invariant / unit.


### StabilityPool / DFStabilityPool Invariants (CORE-SP-INV-*)

#### CORE-SP-INV-001: Range and Non-Zero Property of P 🔵
- At any time, `P ∈ [P_PRECISION / SCALE_FACTOR, P_PRECISION]` (=[1e27, 1e36]) and `P > 0`. The effective depletion rate `P / SCALE_FACTOR^currentScale` is monotonically non-increasing. `currentScale` is monotonically non-decreasing.
- Rationale: the initial value is `P = P_PRECISION`, `offset` has `require(newP > 0)`, and the scale loop (CORE-SP-FR-007 steps 3-5).
- Verification: invariant / parity.

#### CORE-SP-INV-002: Monotonic Maintenance of MIN_JPYDF_IN_SP 🔵
- Once `totalJpydfDeposits >= MIN_JPYDF_IN_SP` holds, it is maintained after every subsequent operation.
- SP-side collateral basis: postcondition require in `withdrawFromSP` (CORE-SP-FR-003 step 12). On the `offset` side, TroveManager is assumed to guarantee `_debtToOffset <= totalJpydfDeposits - MIN_JPYDF_IN_SP` (TM scope), so the complete invariant holds across contracts (CORE-SYS-INV-011).
- Verification: invariant (SYS).

#### CORE-SP-INV-003: JPYdf Accounting Identity 🔵
- `jpydfToken.balanceOf(SP) == totalJpydfDeposits + yieldGainsOwed + yieldGainsPending`. The left-hand side becomes larger only when JPYdf is transferred directly to SP from outside (it remains outside accounting and is never paid out through any path).
- Rationale: all tracker increases/decreases (deposit, withdrawal, compounding, offset burn, yield mint) are paired with an equal transfer/mint/burn (CORE-SP-FR-002/003/006/007). The sum of individual depositors' shares is less than or equal to each tracker due to floor division, and fractional dust remains in the pool (overpayment is also blocked by the clamps in CORE-SP-FR-008/009).
- Verification: invariant / parity.

#### CORE-SP-INV-004: Consistency of Collateral Accounting 🔵
- `collToken.balanceOf(SP) >= collBalance >= Σ stashedColl + Σ unsettled collateral gains`. The left inequality is due to direct transfers (outside accounting), and the right inequality is due to floor-division dust.
- Rationale: `collBalance` changes only through receipt by `offset` and settlement payouts (CORE-SP-FR-005/007, `_sendCollGainToDepositor`).
- Verification: invariant.

#### CORE-SP-INV-005: Mutual Exclusivity of Pending and Threshold 🔵
- If `yieldGainsPending > 0`, then `totalJpydfDeposits < MIN_JPYDF_IN_SP`. Pending always returns to 0 (transferred to owed) on the first `provideToSP` / `triggerJpydfRewards` that restores the threshold.
- Rationale: CORE-SP-FR-002 step 13, CORE-SP-FR-006 steps 2-3, and INV-002 (it does not fall back below the threshold once it is at or above the threshold).
- Verification: invariant / unit.

#### CORE-SP-INV-006: Lifecycle Consistency of Deposits and Snapshots 🔵
- `deposits[d].initialValue > 0` ⇔ `depositSnapshots[d]` has been set (`P_t ∈ [1e27, 1e36]`). Any operation that makes a deposit 0 always deletes the snapshot.
- Rationale: branching in `_updateDepositAndSnapshots` (CORE-SP-FR-003 step 7).
- Verification: invariant / unit.


### ActivePool Invariants (CORE-AP-INV-*)

#### CORE-AP-INV-001: Accounting Balance Does Not Exceed Actual Balance 🔵
`collBalance ≤ collToken.balanceOf(activePool)` always holds at transaction boundaries. Accounting additions are always paired with actual token receipt (pull or direct transfer) in the same tx, and subtractions precede transfers. Donations by direct transfer are not reflected in collBalance, and the excess does not exist in accounting terms (nor is there any path to withdraw it).
- **Verification**: invariant / parity

#### CORE-AP-INV-002: Interest Freeze After Shutdown 🔵
After `shutdownTime != 0`, `calcPendingAggInterest() == 0` holds permanently, and `aggRecordedDebt` never increases due to aggregate interest (excluding increases/decreases caused by TroveChange and batch fee incorporation).
- **Verification**: unit / invariant

- **Cross-contract**: For debt decomposition and positive error, see CORE-SYS-INV-001; for collateral preservation, see CORE-SYS-INV-007; for weighted-sum consistency, see CORE-SYS-INV-002.


### DefaultPool Invariants (CORE-DP-INV-*)

#### CORE-DP-INV-001: Accounting Balance Does Not Exceed Actual Balance 🔵
`collBalance ≤ collToken.balanceOf(defaultPool)` always holds at transaction boundaries (receipt occurs simultaneously with pull, and sending out is preceded by subtraction). Donations by direct transfer are not reflected in accounting and have no withdrawal path.
- **Verification**: invariant / parity

- **Cross-contract (CORE-SYS-INV-006)**: `DP.JpydfDebt == Σ (unapplied redistribution debt gains of all active Troves) ± redistribution rounding error (corrected by TM's lastJpydfDebtError_Redistribution)`, and similarly for the correspondence between `DP.collBalance` and unapplied collateral gains. For debt decomposition (AP + DP), see CORE-SYS-INV-001.


### CollSurplusPool Invariants (CORE-CSP-INV-*)

#### CORE-CSP-INV-001: Accounting Consistency 🔵
At transaction boundaries, `collBalance == Σ balances[a]` (book entries and total amount are always updated together) and `collBalance ≤ collToken.balanceOf(collSurplusPool)` (actual tokens are transferred in from AP within the same liquidation tx. Donations by direct transfer are outside accounting and have no withdrawal path).
- **Verification**: invariant / parity


### SortedTroves Invariants (CORE-ST-INV-*)

#### CORE-ST-INV-001: Sorted by Descending Interest Rate 🔵
Following `nextId` from head to tail, each node's `troveManager.getTroveAnnualInterestRate(id)` is **non-increasing** (descending order; equal rates are allowed). The relative order among nodes with the same rate is insertion order (later insertions are closer to the tail). However, this invariant holds only under the premise that “reInsert / reInsertBatch is always called when the interest rate changes” (BO-side discipline), and atomicity is required between the interest-rate update on TM and the list-position update (the cross-contract rule is CORE-SYS-INV-009).

#### CORE-ST-INV-002: Consistency of Bidirectional Links, Sentinel, and size 🔵
For any node i (including the sentinel), `nodes[nodes[i].nextId].prevId == i` and `nodes[nodes[i].prevId].nextId == i` (a single circular list including sentinel ROOT). The set of nodes with `exists == true` equals the set of nodes reachable from the sentinel (excluding the sentinel), and its element count equals `size`. In an empty list, `nodes[0].nextId == nodes[0].prevId == 0`.

#### CORE-ST-INV-003: Continuity of batch slices 🔵
For any non-empty batch B: following `nextId` from `batches[B].head` yields only members of batch B consecutively and ends at `batches[B].tail`. That is, members of the same batch form a contiguous interval (slice) on the list, and every node in the interval has `batchId == B`. This is maintained because `validInsertPosition` treats “inside the same batch” as invalid as an insertion position (CORE-ST-FR-008), and additions to a batch are always immediately after the tail (CORE-ST-FR-005).

#### CORE-ST-INV-004: Consistency of exists and Node State 🔵
`contains(id) == true` ⇔ the node exists on the list. On removal, `delete nodes[id]` clears the batchId and links as well. Changes to `size` correspond 1:1 to insertion (+1) and removal (-1). For cross-contract consistency between the node set and TM state, see CORE-SYS-INV-009.


### TroveNFT Invariants (CORE-TN-INV-*)

#### CORE-TN-INV-001: 1:1 Correspondence Between NFT and Trove 🔵
tokenId = troveId, and the NFT exists (`ownerOf` can be resolved) ⇔ the corresponding Trove's status is `active` or `zombie`. Minting occurs only when TM opens a Trove (`onOpenTrove` / `onOpenTroveAndJoinBatch`), and burning occurs only through TM's `_closeTrove`; TroveNFT has no standalone path that can break the correspondence. `ownerOf(troveId)` is the sole source of truth for the Trove owner. (The cross-contract rule is CORE-SYS-INV-010)


### JpydfToken Invariants (CORE-BT-INV-*)

#### CORE-BT-INV-001: Permanently Fixed Permission Structure 🔵

After `setCollateralRegistry` is executed, `owner() == address(0)`, and `collateralRegistryAddress` and the four permission mappings can no longer be changed by any means thereafter (there are no add/remove functions, and the contract is non-upgradeable). The permission sets for Core mint/burn/sendToPool/returnFromPool are permanently immutable at the values present when deployment wiring is completed.

#### CORE-BT-INV-002: ERC-20 Accounting Consistency 🔵
`totalSupply() == Σ balanceOf(a)`. Supply increases and decreases occur only through Core mint (CORE-BT-FR-004), Core burn (CORE-BT-FR-005), `bridgeMint`, and `bridgeBurn` (CORE-BT-FR-015).
For cross-contract consistency between supply and total branch debt, see CORE-SYS-INV-003.

#### CORE-BT-INV-003: Dormant Bridge Readiness 🟡
At Day-1 launch, `bridgeMinterCount == 0`, `proposedBridgeMinter == address(0)`, and `bridgeMinterProposedAt == 0`. `bridgeAdmin` survives Core owner renounce, but while there are zero minters, no address can execute `bridgeMint` or `bridgeBurn`.
- **Verification**: unit / deploy manifest evidence.


### CollateralRegistry Invariants (CORE-CR-INV-*)

#### CORE-CR-INV-001: baseRate Upper Bound 🔵
Always `baseRate <= DECIMAL_PRECISION` (`_getUpdatedBaseRateFromRedemption` caps at 100%. The constructor initial value is also 100%).

#### CORE-CR-INV-002: Effective Rate Range 🔵
The rate applied to redemption is always within `[REDEMPTION_FEE_FLOOR, DECIMAL_PRECISION]` (`_calcRedemptionRate` guarantees floor addition and a 100% cap).

#### CORE-CR-INV-003: Monotonicity of lastFeeOperationTime 🔵
`lastFeeOperationTime` is monotonically non-decreasing; increments are always integer multiples of `ONE_MINUTE`, and `lastFeeOperationTime <= block.timestamp`. It is not updated when less than one minute has elapsed (to prevent griefing that captures decay ticks).

#### CORE-CR-INV-004: Immutability of Branch Configuration 🔵
`totalCollaterals`, `token0..9`, `troveManager0..9`, and `jpydfToken` are all immutable. Adding, removing, or replacing branches is impossible without redeploying CollateralRegistry (and rewiring burn permissions on the JpydfToken side, effectively redeploying the system).


### AddressesRegistry Invariants (CORE-AR-INV-*)

#### CORE-AR-INV-001: Risk-Parameter Ranges and Post-Finalization Immutability 🔵/🟡
At all times, `1e18 < CCR, MCR, SCR < 2e18`, `5e16 <= BCR < 50e16`, and `MIN_LIQUIDATION_PENALTY_SP <= LIQUIDATION_PENALTY_SP <= LIQUIDATION_PENALTY_REDISTRIBUTION <= MAX_LIQUIDATION_PENALTY_REDISTRIBUTION`. Final reserved values additionally satisfy `SCR < MCR < CCR`, `MCR * (COLL_GAS_COMPENSATION_DIVISOR - 1) >= (1e18 + LIQUIDATION_PENALTY_SP) * COLL_GAS_COMPENSATION_DIVISOR`, `1e18 + LIQUIDATION_PENALTY_REDISTRIBUTION <= MCR`, and `1e18 + URGENT_REDEMPTION_BONUS <= SCR`. The only value transition is the unfinalized branch's one-shot `finalizeRiskParams`; changing values after finalization requires redeploying the branch.

#### CORE-AR-INV-002: One-Time Wiring 🔵
After `setAddresses` is executed, `owner() == address(0)`, and all 18 addresses are immutable thereafter. Before `setAddresses` is executed, each address is `address(0)`.

#### CORE-AR-INV-003: Monotonic Risk Lifecycle 🟡
`riskParamsFinalized` transitions from false to true at most once and has no true-to-false path. `riskParamsFinalizer` is immutable after construction: a zero-finalizer branch starts finalized, while a nonzero-finalizer branch becomes finalized only through a successful CORE-AR-FR-005 call. Verification: unit / invariant.


### HintHelpers Invariants (CORE-HH-INV-*)

#### CORE-HH-INV-001: Consistency Between Fee Estimation and Actual Charging 🔵
Under the same chain state (same block and no intervening operations), the return values of each `predict*` function match the `upfrontFee` actually charged by the corresponding BorrowerOperations operation. The zero short-circuit conditions (same rate, cooldown elapsed, zero increment) are also equivalent to BO's charging conditions.
- **Verification**: parity (comparison against BO execution result).


### RedemptionHelper Invariants (CORE-RH-INV-*)

#### CORE-RH-INV-001: Fund Pass-Through (Balance Invariance)🔵
Before and after executing `redeemCollateral`, this contract's JPYdf balance and all branch collToken balances do not change (withdrawn JPYdf is burned or returned, and received collateral is sent in full to `msg.sender`).
- **Verification**: invariant / unit.


### LiquidationCandidateGetter Invariants (CORE-LCG-INV-*)

#### CORE-LCG-INV-001: Non-Interference with Core 🟢
All functions are view functions and have no path that modifies core state. Core-side contracts do not reference this contract (one-way dependency). Adding, removing, or breaking this contract does not affect core behavior or safety (a prerequisite for making DF-specific additions compatible with the policy of not modifying core).
- **Verification**: unit / code review (mutability and dependency direction).


### Constants.sol Invariants (CORE-LIB-INV-*)

#### CORE-LIB-INV-001: Base Equivalence of Upstream Constants 🔵
Except for `MIN_DEBT` (CORE-MOD-002) and `COLL_GAS_COMPENSATION_CAP` (CORE-MOD-003), remaining upstream-derived constants in Constants.sol are equivalent to base (liquity/bold v1.11.0). Production-unreferenced upstream fixture constants (`*_WETH` / `*_SETH` / `BCR_ALL`) and helper aliases (`ZERO_ADDRESS` / `MAX_UINT256`) have been removed from production `src` to reduce audit surface; inherited tests use local fixture values or Solidity built-ins instead.
- **Verification**: parity (remaining constant-value comparison against base) / absence review

#### CORE-LIB-INV-002: Exactness of Derived Constants 🔵
Because `_1pct = 1e16` is divisible by 100, all branch-specific constants in the form `<pct*100> * _1pct / 100` (percentages with at most two decimal places) are fixed as exact integers with zero rounding error. Also, `_100pct == DECIMAL_PRECISION` and `_1pct == DECIMAL_PRECISION / 100` hold identically.
- **Verification**: unit (checking evaluated values of constant expressions)

Note: The ordering relationship `MIN_LIQUIDATION_PENALTY_SP ≤ LIQUIDATION_PENALTY_SP_<BR> ≤ LIQUIDATION_PENALTY_REDISTRIBUTION_<BR> ≤ MAX_LIQUIDATION_PENALTY_REDISTRIBUTION` is enforced by the AddressesRegistry constructor (`SPPenaltyTooLow` / `SPPenaltyGtRedist` / `RedistPenaltyTooHigh`) (CORE-AR-FR-001). CORE-SYS-GOV-003 requires pre-deployment verification that the added values for all 8 DF branches satisfy these bounds.


### LiquityMath Invariants (CORE-LIB-INV-*)

N/A (failure modes are covered by CORE-LIB-ERR-001).


### Types Invariants (CORE-LIB-INV-*)

#### CORE-LIB-INV-003: Equivalence of List-Termination Convention 🔵
`TROVE_ID_END_OF_LIST` is the wrapped value of SortedTroves' `ROOT_NODE_ID` (= 0), and is equivalent to `TROVE_ID_ZERO`. troveId = 0 is reserved as the root node of the sorted list and is not used as the ID of a valid Trove (IDs are pseudo-random 256-bit values derived from keccak256. The collision probability is negligible).
- **Verification**: unit (constant equivalence) / for cross-contract rules, see CORE-SYS-INV-014


---

## 9. Security Requirements (SEC)

> Core security properties. This section defines caller restrictions (see §4 for the trust-boundary summary table), the permission model, and exclusion of harmful operations (griefing / MEV / donation). Core inherits audited and battle-tested code with base parity, plus only the explicit JPYdf canonical surface and ledgered `CORE-MOD-*` deltas ([Product-Overview](../Product-Overview.md) SYS-NFR-001). This section fixes "what is protected" in a form that tests and audits can verify.


### BorrowerOperations Security Requirements (CORE-BO-SEC-*)

#### CORE-BO-SEC-001: Closure of Trove Operation Permission Model 🔵

- Type: Security
- Statement: Withdrawal-type operations (collateral withdrawal, borrowing, and closure) must not be executable by anyone other than the owner and RemoveManager (`NotOwnerNorRemoveManager`). Deposit-type operations (collateral addition and repayment), when `addManagerOf` is set, are limited to owner / AddManager / RemoveManager; when unset, the specified **default openness** is that anyone may execute them (deposit-type operations only improve Trove health, and repayment cannot be used for zombie-creation attacks due to the MIN_DEBT cap). RemoveManager includes AddManager privileges.
- Verification: parity / unit (permission matrix)

#### CORE-BO-SEC-002: Receiver Redirection Constraints 🔵

- Type: Security
- Statement: A registered receiver is used as the recipient for withdrawal-type funds only when "the caller is the RemoveManager itself and the receiver is non-zero"; when the owner calls, the recipient must always be the owner. As a result, even if the RemoveManager key is compromised, the destination of funds is limited to the receiver pre-fixed by the owner.
- Verification: parity / unit

#### CORE-BO-SEC-003: Caller Restrictions on Internal Hooks 🔵

- Type: Security
- Statement: `onLiquidateTrove` must be callable only by troveManager (`CallerNotTroveManager`), and `shutdownFromOracleFailure` only by priceFeed (`CallerNotPriceFeed`). If this is broken, a third party could erase delegation state for arbitrary Troves or perform arbitrary shutdowns.
- Verification: parity / unit

#### CORE-BO-SEC-004: Upfront Fee Slippage Protection 🔵

- Type: Security
- Statement: On all paths that collect an upfront fee (opening, borrowing, premature interest-rate change, batch joining, premature batch leaving, and batch-wide interest-rate change), any fee exceeding the user-specified `_maxUpfrontFee` must be rejected with `UpfrontFeeTooHigh` (because the fee depends on the branch average interest rate and can fluctuate due to third-party operations before or after the tx).
- Verification: parity / unit

#### CORE-BO-SEC-005: State-Condition Gates for Permissionless Operations 🔵

- Type: Security
- Statement: Permissionless `shutdown` is constrained to TCR < SCR, `kickFromBatch` to debt/shares ratio > `MAX_BATCH_SHARES_RATIO`, and `applyPendingDebt` only to "finalization of recorded values" (it does not change interest or debt conditions), so that third parties cannot use these operations to cause economic harm to borrowers.
- Verification: parity / unit

#### CORE-BO-SEC-006: Registry-Only Risk Sync and Unfinalized-Branch Open Gate 🟡

- Type: Security
- Statement: Only the immutable AddressesRegistry may call `syncRiskParams`, and it must pass the same calldata values validated by `finalizeRiskParams` in the same transaction. The shared internal path used by `openTrove` and `openTroveAndJoinInterestBatchManager` checks `riskParamsFinalized` before state changes or oracle fetches and rejects economic activation of an unfinalized branch.
- Verification: unit / adversarial review


### TroveManager Security Requirements (CORE-TM-SEC-*)

#### CORE-TM-SEC-001: on* Callbacks Limited to BorrowerOperations 🔵
All `on*`, `setTroveStatusToActive`, and `shutdown` require `msg.sender == borrowerOperations` (`CallerNotBorrowerOperations`). These are "trusted write entry points" without input validation, and if callable from anywhere other than BO, the ledger could be modified arbitrarily. Verification: unit (caller checks for all functions) / parity.

#### CORE-TM-SEC-002: redeemCollateral Limited to CollateralRegistry 🔵

fee-rate and branch-allocation calculations are enforced through CollateralRegistry, so direct calls are prohibited (`CallerNotCollateralRegistry`). If this is broken, redemptions with zero fees become possible. Verification: unit / parity.

#### CORE-TM-SEC-003: Restricting Liquidation Conditions 🔵
Liquidations are permissionless, but only Troves with `status ∈ {active, zombie}` and `getCurrentICR < MCR` (based on entire values) are eligible. Healthy Troves are silently skipped even if included in the array. Verification: parity / unit.

#### CORE-TM-SEC-004: Preventing CR Deterioration Through Redemption 🔵
Normal Redemption skips Troves with `ICR < 100%` (because redemption removes collateral of equivalent value to the debt, which further worsens the CR for Troves with ICR < 100%). urgentRedemption does not have this protection, and instead handles it with a full-collateral cap. Verification: parity / unit.

#### CORE-TM-SEC-005: Redemption Griefing Resistance Through the zombie Mechanism 🔵
Troves redeemed below `MIN_DEBT` become zombies and are removed from SortedTroves, so an attack that lines up tiny Troves to exhaust gas through sequential Redemption is not viable. Leftovers from partial redemption are prioritized for consumption on the next run via `lastZombieTroveId`. Verification: parity / unit.

#### CORE-TM-SEC-006: batch shares Dilution / Rebase Attack Resistance and Non-Blocking Redemption 🔵
The upper-bound check on the debt/shares ratio (`BatchSharesRatioTooHigh`) prevents extreme dilution of shares, while the check is disabled on the Redemption path, ensuring redemption cannot be stopped because of batch state. Verification: unit.

#### CORE-TM-SEC-007: shutdown One-Time Execution Depends on BorrowerOperations 🔵
`shutdown()` itself does not prohibit overwriting `shutdownTime`. One-time execution (no repeated calls) is assumed to be guaranteed by the require on the BO side (the cross-contract rule is CORE-SYS-INV-013). Verification: parity (double shutdown impossible via BO).

#### CORE-TM-SEC-008: Registry-Only Risk Sync 🟡
Only the immutable AddressesRegistry may call `syncRiskParams`, and it must pass the same calldata values validated by `finalizeRiskParams` in the same transaction. This prevents third parties from changing liquidation, redemption, or shutdown thresholds and penalties. Verification: unit.

- **Cross-contract**: ① For branch debt consistency, see CORE-SYS-INV-001; ② for the collateral conservation rule in liquidation, see CORE-SYS-INV-005; ③ for membership consistency with SortedTroves, see CORE-SYS-INV-009; ④ for ensuring normal redemption does not occur after shutdown (respecting redeemable=false), see CORE-CR-FR-001 / CORE-SYS-ERR-003.


### StabilityPool / DFStabilityPool Security Requirements (CORE-SP-SEC-*)

#### CORE-SP-SEC-001: Restricting the Caller of offset 🔵
- `offset` is only for TroveManager. This blocks paths where an arbitrary caller manipulates `P`/`S`/`totalJpydfDeposits` and destroys accounting for all depositors (`"StabilityPool: Caller is not TroveManager"`).
- Verification: unit (revert on non-TM caller) / parity.

#### CORE-SP-SEC-002: Restricting the Caller of triggerJpydfRewards 🔵
- `triggerJpydfRewards` is only for ActivePool. This blocks unauthorized inflation of `yieldGainsOwed` / `scaleToB` (an attack that inflates yield claims without backing by actual JPYdf and steals others' owed amounts) (`"StabilityPool: Caller is not ActivePool"`).
- Verification: unit / parity.

#### CORE-SP-SEC-003: donation Resistance Through Internal Trackers 🔵
- Balance accounting is based on internal trackers such as `collBalance` / `totalJpydfDeposits`, and does not reference `balanceOf`. Direct transfers of collToken or JPYdf (or forced transfers via self-destruct) do not affect accounting and cannot distort allocation calculations (a consequence of internal-tracker accounting; same pattern as donation resistance in AP/DP/CSP [CORE-AP-INV-001, etc.]).
- Verification: unit (each view remains unchanged after direct transfer).

#### CORE-SP-SEC-004: Preventing Liquidation-Gain Capture Through Same-Block Flash Deposits 🟡
- Attack scenario (possible in base): An attacker who anticipates that liquidation will occur in the same block obtains a large amount of JPYdf via a flash loan or similar, calls `provideToSP` → `offset` to receive most of the collateral gain through proportional distribution (liquidation collateral is normally distributed at a discount, yielding immediate profit) → calls `withdrawFromSP` within the same block to recover principal + gains. This imposes almost no pool-residency risk and dilutes the share of existing depositors.
- DF mitigation (CORE-MOD-004 (§2 DF Difference Ledger)): DFStabilityPool restricts both `withdrawFromSP` and current/stashed collateral-gain payout through `provideToSP(..., true)` to `lastDepositBlock[msg.sender] < block.number` (CORE-SP-FR-004). A flash loan requiring repayment in the same transaction cannot withdraw the deposit or receive and convert the liquidation collateral, and a self-funded deposit must persist across at least one block boundary.
- Residual risk: Transaction ordering can place a deposit in the last transaction of block N and its withdrawal in the first transaction of block N+1, with no intervening `offset()` and therefore no liquidation-loss exposure. Next-block withdrawal and multi-block MEV remain possible; this guard is intended only to eliminate "risk-free atomic capture."
- Verification: unit (same-block revert, success in next block, flash-loan path infeasible).

#### CORE-SP-SEC-005: External Call Surface and Reentrancy Considerations 🔵
- SP's external call targets are only `activePool` / `jpydfToken` / `collToken`. The first two are in-system contracts, and `collToken` is dToken ([dToken.md](dToken.md)); all are assumed not to have transfer hooks (ERC-777 style). Depositor operations perform state updates (snapshots and trackers) before transfers (procedure order in CORE-SP-FR-002/003), so even if hooks existed, the structure makes reentrancy against old state difficult. The in-system reentry during `provideToSP`, `mintAggInterest` → `triggerJpydfRewards` (callback to SP itself), is a regular designed path and completes before gain calculation.
- Verification: parity / design review (dependency on dToken-side specification explicitly noted).


### ActivePool Security Requirements (CORE-AP-SEC-*)

#### CORE-AP-SEC-001: Restricting Callers of State-Changing Surfaces 🔵
All 8 state-changing entry points (mintAggInterest / mintAggInterestAndAccountForTroveChange / mintBatchManagementFeeAndAccountForChange / sendColl / sendCollToDefaultPool / receiveColl / accountForReceivedColl / setShutdownFlag) are restricted by require to core contracts (BO / TM / SP / DP), so there is no path for a third party to directly drive accounting trackers, collateral transfers, or JPYdf minting. JPYdf minting itself is also protected by JpydfToken-side minter restrictions (BT scope), forming a second barrier.
- **Verification**: unit (revert on unauthorized caller for all functions) / parity


### DefaultPool Security Requirements (CORE-DP-SEC-*)

#### CORE-DP-SEC-001: Restricting Callers of Write Surfaces 🔵
All 4 state-changing functions are restricted to TroveManager / ActivePool, so there is no path for a third party to manipulate pending accounting. The only path by which actual collateral tokens leave DefaultPool is a pull toward ActivePool via `sendCollToActivePool`; there is no function for sending to arbitrary addresses.
- **Verification**: unit (revert on unauthorized caller) / parity


### CollSurplusPool Security Requirements (CORE-CSP-SEC-*)

#### CORE-CSP-SEC-001: Claims Restricted to the Rightful Account 🔵
Recording is restricted to TM and payout to BO. Because the only path through BO (`claimCollateral`) passes `msg.sender`, there is no code path by which a third party can claim or steal someone else's surplus collateral. The recipient is also fixed to `_account` itself, and there is no concept of approval or delegation.
- **Verification**: unit (revert on unauthorized caller) / parity


### GasPool Security Requirements (CORE-GP-SEC-*)

#### CORE-GP-SEC-001: Zero Attack Surface and Validity of approve 🔵
GasPool has no external / public functions, and no operation can be called directly after deployment. Infinite WETH approvals are limited to the 2 immutably wired addresses BO / TM, so there is no path for a third party to transfer WETH held by GasPool.
- **Verification**: unit (ABI is empty; approval targets verified) / parity

- **Cross-contract (CORE-SYS-INV-008)**: `WETH.balanceOf(gasPool) == number of open Troves (including zombie) × ETH_GAS_COMPENSATION` (deposited on open; withdrawn on close/liquidation. If there are donations through direct transfers, this relaxes to ≥).


### SortedTroves Security Requirements (CORE-ST-SEC-*)

#### CORE-ST-SEC-001: Restricting Write Permissions and Delegating Trust for Node Existence 🔵
The callers of the 6 state-changing functions are restricted to BO (insert / reInsert / insertIntoBatch / reInsertBatch / remove / removeFromBatch) and TM (remove / removeFromBatch only) (require implementations: `_requireCallerIsBorrowerOperations` / `_requireCallerIsBOorTM`). SortedTroves itself does not verify whether `_id` is an existing Trove, and fully delegates the validity of IDs and correctness of interest-rate arguments to the callers (BO/TM) (trust boundary). There is no path for a third party to directly rewrite list ordering.

#### CORE-ST-SEC-002: Health Independent of Hints (hint griefing Resistance) 🔵
Hints only affect gas savings and **do not affect result correctness**: invalid hints are rejected by validation and search is always retried (CORE-ST-FR-009). Malicious hints or front-running (insertions/deletions by others between hint acquisition and tx execution) cannot cause insertion at an incorrect position; the only possible effect is increased gas from extra search steps (worst case: full list scan O(n), with an external view call to TM at each step). The sender of that tx bears the increased gas cost themselves.


### TroveNFT Security Requirements (CORE-TN-SEC-*)

#### CORE-TN-SEC-001: mint/burn Restricted to TroveManager 🔵
`mint` / `burn` require `msg.sender == address(troveManager)` (`_requireCallerIsTroveManager`). Since NFT issuance/burning is the creation/destruction of Trove ownership, it is fully synchronized with TM's Trove lifecycle management and is not permitted for any other address (including the owner itself).

#### CORE-TN-SEC-002: Eliminating Recipient Callbacks During mint 🔵

mint uses `_mint` rather than `_safeMint`, so no recipient callback (`onERC721Received`) occurs. This eliminates reentrancy and recipient-rejection DoS vectors in the openTrove flow (CORE-TN-FR-002). Note that transfers via `safeTransferFrom` trigger callbacks as specified by the ERC-721 standard (this is standard behavior, and core state has already changed by that point).


### JpydfToken Security Requirements (CORE-BT-SEC-*)

#### CORE-BT-SEC-001: Trust Boundary for mint Authority 🔵
Increases in Core JPYdf supply can be performed only by registered BO (borrowing) and AP (interest and batch management fee issuance). There is no Core `mint` path for any other party (including Owner, `bridgeAdmin`, and bridge minters). If an incorrect (or malicious) contract address is passed to `setBranchAddresses` during deployment wiring, unlimited Core minting becomes possible, so validation of registered address legitimacy is a mandatory deployment procedure item.

#### CORE-BT-SEC-002: Irreversibility of Registration (Deployment-Procedure Dependent) 🔵
`setBranchAddresses` / `setCollateralRegistry` reject zero and codeless addresses under CORE-MOD-009. They still do not validate duplicates, branch-role mixups, wrong-branch contracts, or semantic consistency with the deployment registry. There is no means to revoke registration, and after `setCollateralRegistry` renounces owner, incorrect registrations remain permanently. Mitigations are deployment-script validation, reconciliation before renounce, and manifest evidence.

#### CORE-BT-SEC-003: allowance-Independent burn / Internal Transfers 🔵
`burn` / `sendToPool` / `returnFromPool` can move balances without approval from the holder. In the core implementation, their usage is limited to holder-initiated flows (repayment, redemption, SP deposit/withdrawal, SP offset), but as a trust boundary, auditing and monitoring must assume that "registered core contracts can burn or transfer JPYdf from any account."

#### CORE-BT-SEC-004: Bridge Minter Trust Boundary 🟡
Registered bridge minters can mint JPYdf to arbitrary non-protocol recipients through `bridgeMint`. `bridgeBurn` is self-burn only, so a minter cannot directly burn arbitrary user balances. Minter addition is gated by a 48h timelock, removal is immediate, and rate limits / message verification / bridge-specific pause controls belong to the minter or adapter specification rather than `JpydfToken`.


### CollateralRegistry Security Requirements (CORE-CR-SEC-*)

#### CORE-CR-SEC-001: Allocation Strictness and truncation 🔵
On the normal path where total unbacked is positive, the sum of per-branch allocation amounts strictly equals `min(requested amount, total unbacked)` (due to residual updates inside the loop). Requests exceeding total unbacked are truncated, preventing imbalanced proportional allocation (upstream code comment: CS-BOLD-013). In the fallback where all redeemable branches have unbacked of 0 (proportional to total debt), truncation is not applied, and the full requested amount is allocated (CORE-CR-FR-002).
See CORE-SYS-INV-004 for cross-contract consistency between total burn amount and total debt reduction.

#### CORE-CR-SEC-002: External Dependency on Price and redeemability 🔵
Allocation weights (unbacked portion), applied prices, and redeemable determinations depend on return values from each TM / PriceFeed ([Oracle.md](Oracle.md)). Branches that have been shut down or have TCR < SCR are excluded from allocation. Behavior during oracle failures follows the TM / PriceFeed specifications (this contract trusts the results).


### AddressesRegistry Security Requirements (CORE-AR-SEC-*)

#### CORE-AR-SEC-001: Unvalidated Wiring Values (Deployment-Procedure Dependent) 🔵
`setAddresses` does not validate zero addresses, contract existence, or mutual consistency (e.g., whether troveManager belongs to the relevant branch) at all. Incorrect wiring propagates into each core contract's constructor references and becomes permanent, so precomputation in deployment scripts (CREATE2 address prediction) and post-deployment reconciliation checks are mandatory. After deploying each CREATE2 target, the canonical `DeployLiquity2` procedure replaces branch-local expected values with the actual deployed instances, reads back all 18 `AddressesRegistry` getters, and verifies exact expected identity, nonzero addresses, and runtime code before proceeding to the next registration. Field-specific identity checks detect swaps, zero addresses, and EOAs without breaking the constructor dependency cycle; a generic uniqueness rule is not used. The constructor also does not enforce the active branch's CCR/MCR/SCR ordering or that a nonzero finalizer is the canonical Timelock, so the deployment gate must do so (CORE-AR-FR-001/005).

#### CORE-AR-SEC-002: Finalization Binding, Empty-State, and Shutdown Boundaries 🟡
Before updating values, `finalizeRiskParams` must match the expected Underlying against both dToken and Vault, verify their mutual binding, and require zero cap/supply, Troves, branch debt, branch collateral, and SP deposits, no oracle-failure pause, and no terminal BO/TM/AP shutdown. The unfinalized-branch SP guard prevents a third party from leaving the minimum deposit to grief finalization and prevents penalty changes after user funds enter. Although `riskParamsFinalized` is set before child synchronization, any failure in the same transaction rolls back the flag, Registry values, and BO/TM copies. Irreversible shutdown has no rescue or reinitialization path. Verification: unit / adversarial review.


### HintHelpers Security Requirements (CORE-HH-SEC-*)

#### CORE-HH-SEC-001: Non-Custodial and Non-Interfering 🔵
All functions are view functions, and there is no path for modifying core state or holding assets. Failures or misconfiguration of HintHelpers do not affect core safety (even if hints degrade, `findInsertPosition` reaches the correct position. ST section).


### MultiTroveGetter Security Requirements (CORE-MTG-SEC-*)

#### CORE-MTG-SEC-001: Non-Custodial and Non-Interfering 🔵
All functions are view functions. There is no write path to core state and no asset custody. Display-layer failures do not propagate to core.


### DebtInFrontHelper Security Requirements (CORE-DFH-SEC-*)

#### CORE-DFH-SEC-001: Non-Custodial and Non-Interfering 🔵
All functions are view functions. There is no write path to core state and no asset custody.


### RedemptionHelper Security Requirements (CORE-RH-SEC-*)

#### CORE-RH-SEC-001: No Fund Custody and No rescue 🔵
This contract is not intended to custody funds and has no withdrawal or rescue mechanism. **Tokens sent directly by transfer are permanently locked** (because balance-difference accounting is used, balances that existed before a call are not included in later payouts). User funds are touched only within a single tx from `transferFrom` through return. Since `transferFrom` pulls only from `msg.sender`'s balance, even if a JPYdf approval to this contract remains, a third party cannot redeem using someone else's funds (redemption proceeds are also sent only to `msg.sender`). Both collateral (dToken) and JPYdf are ERC-20 tokens without transfer hooks, so there is no reentrancy surface ([dToken.md](dToken.md), BT section).


### Ownable Security Requirements (CORE-LIB-SEC-*)

#### CORE-LIB-SEC-001: No Caller Validation in _renounceOwnership 🔵
`_renounceOwnership()` is internal, but it has no caller check (as warned in NatSpec). If an inheriting contract adds an implementation that calls it from an unauthorized path, a third party could force the owner to be renounced before wiring and permanently make initialization impossible (bricking). The two call sites in the current codebase (JpydfToken / AddressesRegistry) both satisfy the requirement by being inside onlyOwner functions. Keep this as a review point when adding new inheritance.
- **Verification**: Static inspection (all call sites are in an onlyOwner context)


---

## 10. Governance, Operations, and Upgrade Requirements (GOV)


The core governance boundary leaves no upgrade authority, repeatable parameter setter, or fund-withdrawal authority. Active branches lose administrative authority at deployment; reserved branches lose the remaining Timelock authority after one-shot finalization (core-side basis for [Product-Overview](../Product-Overview.md) SYS-NFR-002/003).

#### CORE-SYS-GOV-001: Deployment-Time Wiring and Self-Renouncement of Authority 🔵
- **Type**: Governance | **Source**: base implementation (AddressesRegistry / JpydfToken / Ownable)
- Owner authority for wiring exists in only two places: `AddressesRegistry.setAddresses` (branch wiring, CORE-AR-FR-002; **executes `_renounceOwnership()` at the same time**) and `JpydfToken.setBranchAddresses` / `setCollateralRegistry` (registration of mint/burn authority, CORE-BT-FR-002/003. `setBranchAddresses` can be repeated for the number of branches, and **renounce occurs simultaneously with execution of `setCollateralRegistry`**, permanently fixing all registrations). After renounce, re-execution and additional registrations are permanently impossible (including later addition of branches).
- **The only privileged call relationships remaining after deployment are inter-contract only-X restrictions (§4)**, and EOAs or multisigs have zero administrative authority.
- **Exception**: while a reserved branch is unfinalized, its immutable `riskParamsFinalizer` retains only the one-shot operation in CORE-AR-FR-005. Canonical deployment assigns the common Timelock; after success, even that caller cannot execute it again.
- **Verification**: parity / deploy verification (`owner() == address(0)` equivalent after wiring; each setter reverts)
#### CORE-SYS-GOV-002: Non-Upgradeability and Parameter Immutability 🔵
- All core contracts and JpydfToken are non-upgradeable (direct deployment without proxies), and inter-contract wiring is immutable / set once. Branch risk parameters (MCR/CCR/SCR/BCR/liquidation penalties) are finalized at deployment for active branches and exactly once before activation of a reserved branch. No change path remains after finalization.
- Consequence: Correcting finalized parameters or replacing contracts requires **redeploying a new branch**. Complete the freeze review before broadcast for active Day-1 values and before Timelock scheduling for final reserved-branch values.
- **Verification**: manual (code review: no repeatable setter; one-shot flag) / deploy verification
#### CORE-SYS-GOV-003: Deployment Gate (Mechanical Validation of Values) 🔵/🟡
- In addition to AddressesRegistry constructor validation (`InvalidCCR/MCR/SCR/BCR` and penalty ordering, CORE-AR-FR-001), mechanically verify: (a) `MIN_DEBT` matches CORE-LIB-FR-002 and `COLL_GAS_COMPENSATION_CAP` plus DF branch deployment inputs (CORE-MOD-003/005) match [Parameters.md](../../../Parameters.md), (b) the `PRM-INV-*` relations in the Japanese [Parameter Catalog](../../../../jp/protocol/product/parameters/Parameter-Catalog.md#4-parameter-invariants), (c) every AddressesRegistry getter matches intended wiring, and (d) active branches have `riskParamsFinalizer == 0 && riskParamsFinalized == true`, while reserved branches have the common Timelock as finalizer and `riskParamsFinalized == false`. Reserved activation must verify every CORE-AR-FR-005 precondition, the six final risk values and compensation cap, the `RiskParamsFinalized` receipt/event, Registry/BO getters, TM's CCR getter plus block-pinned `eth_getStorageAt` for the five internal values including the compensation cap (with compiler storage-layout and runtime-bytecode attestation) or equivalent atomic-sync evidence, and that the cap opens last.
- **Verification**: deploy verification (script) / manual
#### CORE-SYS-GOV-004: Active Operational Actions Are Only Incentive-Driven permissionless Actions 🔵
- After finalization, core maintenance operations (liquidation, redemption, interest minting, shutdown) are all permissionless and do not assume operator intervention. Except for the reserved-branch activation ceremony, DF's operational responsibilities are limited to **monitoring and responses at external layers** (LCG scan by liquidation bots = CORE-LCG-FR-001, oracle monitoring and source replacement = [Oracle.md](Oracle.md), securing SP liquidity).
- **Verification**: manual (consistency with operational runbook)

---

## 11. Event and Monitoring Requirements (EVT)

> All events by contract. off-chain (subgraph / monitoring / frontend) systems use this as the canonical source for constructing indexes. In addition to base-derived events, Core includes the 🟡 CORE-MOD-011 ActivePool observability events and the CORE-MOD-013 risk-finalization event. DFStabilityPool's event surface remains identical to StabilityPool.


### BorrowerOperations Events (CORE-BO-EVT-*)

| ID | Event | Emission Location | indexed | off-chain Purpose |
| --- | --- | --- | --- | --- |
| CORE-BO-EVT-001 | `TroveManagerAddressChanged(address)` | constructor | none | Audit deployment wiring |
| CORE-BO-EVT-002 | `GasPoolAddressChanged(address)` | constructor | none | Same as above |
| CORE-BO-EVT-003 | `CollSurplusPoolAddressChanged(address)` | constructor | none | Same as above |
| CORE-BO-EVT-004 | `SortedTrovesAddressChanged(address)` | constructor | none | Same as above |
| CORE-BO-EVT-005 | `JpydfTokenAddressChanged(address)` | constructor | none | Same as above |
| CORE-BO-EVT-006 | `ShutDown(uint256 _tcr)` | `shutdown()` (only on the TCR < SCR path. Not emitted on the oracle failure path) | none | Immediate alert for branch shutdown and record of TCR at shutdown |

| CORE-BO-EVT-007 | `TroveNFTAddressChanged(address)` | constructor (AddRemoveManagers) | none | Audit deployment wiring |
| CORE-BO-EVT-008 | `AddManagerUpdated(uint256 indexed _troveId, address _newAddManager)` | `setAddManager` / `openTrove` family (always emitted) / `closeTrove` and `onLiquidateTrove` (zeroed) | `_troveId` | Track Trove delegation state (frontend display and delegation audit) |
| CORE-BO-EVT-009 | `RemoveManagerAndReceiverUpdated(uint256 indexed _troveId, address _newRemoveManager, address _newReceiver)` | `setRemoveManager(WithReceiver)` / `openTrove` family (always emitted) / `closeTrove` and `onLiquidateTrove` (zeroed) | `_troveId` | Same as above (monitoring receiver changes is important for auditing fund outflow destinations) |
| CORE-BO-EVT-010 | `ActivePoolAddressChanged(address)` | constructor (LiquityBase) | none | Audit deployment wiring |
| CORE-BO-EVT-011 | `DefaultPoolAddressChanged(address)` | constructor (LiquityBase) | none | Same as above |
| CORE-BO-EVT-012 | `PriceFeedAddressChanged(address)` | constructor (LiquityBase) | none | Same as above |

Trove lifecycle events (opening, adjustment, closure, interest changes, and batch operations) are not emitted from BO; they are observed on the TroveManager side (`TroveOperation` / `TroveUpdated` / `BatchUpdated`, etc. in the CORE-TM family).


### TroveManager Events (CORE-TM-EVT-*)

| ID | Event | Emission site | indexed | off-chain use |
| --- | --- | --- | --- | --- |
| CORE-TM-EVT-001 | `Liquidation(uint256 _debtOffsetBySP, uint256 _debtRedistributed, uint256 _jpydfGasCompensation, uint256 _collGasCompensation, uint256 _collSentToSP, uint256 _collRedistributed, uint256 _collSurplus, uint256 _L_ETH, uint256 _L_jpydfDebt, uint256 _price)` | `batchLiquidateTroves` (once per call) | none | Monitor liquidation scale and allocation; track cumulative redistribution values |
| CORE-TM-EVT-002 | `Redemption(uint256 _attemptedJpydfAmount, uint256 _actualJpydfAmount, uint256 _ETHSent, uint256 _ETHFee, uint256 _price, uint256 _redemptionPrice)` | `redeemCollateral` / `urgentRedemption` (once per call) | none | Monitor redemption amount, fee, and prices used |
| CORE-TM-EVT-003 | `TroveUpdated(uint256 indexed _troveId, uint256 _debt, uint256 _coll, uint256 _stake, uint256 _annualInterestRate, uint256 _snapshotOfTotalCollRedist, uint256 _snapshotOfTotalDebtRedist)` | All Trove state changes (non-batch adjustments, interest changes, etc. **Even for batch-member Troves**, it is emitted in `onApplyTroveInterest` [at this time `_annualInterestRate` is the Trove's individually stored value, i.e. 0 for batch members]; for closure and liquidation, it is emitted with all-zero values for all Troves) | `_troveId` | Index Trove state (source of truth for subgraphs) |
| CORE-TM-EVT-004 | `TroveOperation(uint256 indexed _troveId, Operation _operation, uint256 _annualInterestRate, uint256 _debtIncreaseFromRedist, uint256 _debtIncreaseFromUpfrontFee, int256 _debtChangeFromOperation, uint256 _collIncreaseFromRedist, int256 _collChangeFromOperation)` | All operations on a Trove | `_troveId` | Operation history and breakdown of change factors (operation / redistribution / upfront fee) |
| CORE-TM-EVT-005 | `RedemptionFeePaidToTrove(uint256 indexed _troveId, uint256 _ETHFee)` | `_applySingleRedemption` (per Trove) | `_troveId` | Track redemption fees left in Troves |
| CORE-TM-EVT-006 | `BatchUpdated(address indexed _interestBatchManager, BatchOperation _operation, uint256 _debt, uint256 _coll, uint256 _annualInterestRate, uint256 _annualManagementFee, uint256 _totalDebtShares, uint256 _debtIncreaseFromUpfrontFee)` | All operations involving a batch | `_interestBatchManager` | Index batch state |
| CORE-TM-EVT-007 | `BatchedTroveUpdated(uint256 indexed _troveId, address _interestBatchManager, uint256 _batchDebtShares, uint256 _coll, uint256 _stake, uint256 _snapshotOfTotalCollRedist, uint256 _snapshotOfTotalDebtRedist)` | State changes of batch-member Troves | `_troveId` | State of batch-member Troves (debt is derived from shares) |
| CORE-TM-EVT-008 | Address wiring event group: `TroveNFTAddressChanged` / `BorrowerOperationsAddressChanged` / `StabilityPoolAddressChanged` / `GasPoolAddressChanged` / `CollSurplusPoolAddressChanged` / `JpydfTokenAddressChanged` / `SortedTrovesAddressChanged` / `CollateralRegistryAddressChanged` (TroveManager) + `ActivePoolAddressChanged` / `DefaultPoolAddressChanged` / `PriceFeedAddressChanged` (LiquityBase inheritance) — each `(address)` | constructor only (one-time) | none | Verify wiring at deployment |

**Field meanings for CORE-TM-EVT-001 `Liquidation`** (cumulative values from `batchLiquidateTroves`)

| Field | Meaning |
| --- | --- |
| `_debtOffsetBySP` | Total debt extinguished by SP offset (`totals.debtToOffset`) |
| `_debtRedistributed` | Total debt redistributed |
| `_jpydfGasCompensation` | Total **WETH** gas compensation paid to liquidators (`ETH_GAS_COMPENSATION × number of liquidations`; the field name comes from v1 and is not BOLD) |
| `_collGasCompensation` | Total collateral gas compensation paid to liquidators |
| `_collSentToSP` | Total collateral sent to the SP (after gas compensation deduction and penalty application) |
| `_collRedistributed` | Total collateral redistributed |
| `_collSurplus` | Total borrower-return portion recorded in CollSurplusPool |
| `_L_ETH` / `_L_jpydfDebt` | `L_coll` / `L_jpydfDebt` **after** update (field name `_L_ETH` comes from v1; the actual substance is collateral) |
| `_price` | Price used for the liquidation determination (return value of `fetchPrice`) |

**Field meanings for CORE-TM-EVT-002 `Redemption`**

| Field | Meaning |
| --- | --- |
| `_attemptedJpydfAmount` | Requested redemption amount (`_jpydfAmount` / `_jpydfAmount`) |
| `_actualJpydfAmount` | Total debt actually redeemed (may be less than requested) |
| `_ETHSent` | Total collateral sent to the redeemer (after fee deduction) |
| `_ETHFee` | Total redemption fee left in the Trove set (always 0 for `urgentRedemption`) |
| `_price` | Normal price (value passed for ICR determination; for urgent, the `fetchPrice` value) |
| `_redemptionPrice` | Redemption price used for collateral conversion (same as the normal price for urgent) |

**Notes on CORE-TM-EVT-003/004/005/006/007**

- `TroveUpdated`: Absolute-value snapshot after the operation. `_snapshotOfTotal*Redist` is the new `rewardSnapshots` value for that Trove (= `L_coll` / `L_jpydfDebt` at emission time). On closure and liquidation, all fields are 0.
- `TroveOperation._operation` (enum `Operation`, uint8): `0 openTrove / 1 closeTrove / 2 adjustTrove / 3 adjustTroveInterestRate / 4 applyPendingDebt / 5 liquidate / 6 redeemCollateral / 7 openTroveAndJoinBatch / 8 setInterestBatchManager / 9 removeFromBatch`. `_debtChangeFromOperation` / `_collChangeFromOperation` are int256 (negative entire values for liquidation; negative lot values for redemption). Increases from redistribution and increases from upfront fees are broken out into separate fields.
- `RedemptionFeePaidToTrove._ETHFee`: Fee left in the collateral of that Trove (the portion deducted from `collLot`; improves the Trove's CR).
- `BatchUpdated._operation` (enum `BatchOperation`, uint8): `0 registerBatchManager / 1 lowerBatchManagerAnnualFee / 2 setBatchManagerAnnualInterestRate / 3 applyBatchInterestAndFee / 4 joinBatch / 5 exitBatch / 6 troveChange`. `_debtIncreaseFromUpfrontFee` is nonzero only for upfront fees charged to the entire batch (during `setBatchManagerAnnualInterestRate`; it does not include fees for individual Troves). `_debt` / `_coll` are, in principle, the raw post-update values from `batches` (`applyBatchInterestAndFee` only uses finalized argument values).

- `BatchedTroveUpdated`: because Troves belonging to a batch do not have recorded debt, it carries `_batchDebtShares` instead of `_debt`.


### StabilityPool / DFStabilityPool Events (CORE-SP-EVT-*)

The `Operation` enum in `DepositOperation` is `provideToSP = 0` / `withdrawFromSP = 1` / `claimAllCollGains = 2` (IStabilityPoolEvents.sol).

| ID | Event | Emission point | indexed | Off-chain use |
| --- | --- | --- | --- | --- |
| CORE-SP-EVT-001 | `DepositOperation(address _depositor, Operation _operation, uint256 _depositLossSinceLastOperation, int256 _topUpOrWithdrawal, uint256 _yieldGainSinceLastOperation, uint256 _yieldGainClaimed, uint256 _ethGainSinceLastOperation, uint256 _ethGainClaimed)` | provideToSP / withdrawFromSP / claimAllCollGains | `_depositor` | History and PnL aggregation for depositor operations (breakdown of liquidation losses, deposits/withdrawals, yield, and collateral gains). The collateral field name uses the legacy `ethGain` notation, but its contents are the collToken (dToken) amount |
| CORE-SP-EVT-002 | `DepositUpdated(address _depositor, uint256 _newDeposit, uint256 _stashedColl, uint256 _snapshotP, uint256 _snapshotS, uint256 _snapshotB, uint256 _snapshotScale)` | _updateDepositAndSnapshots (provideToSP / withdrawFromSP)/ claimAllCollGains | `_depositor` | Tracks the depositor's current deposit, stash, and snapshots (subgraph account-state reconstruction) |
| CORE-SP-EVT-003 | `StabilityPoolJpydfBalanceUpdated(uint256 _newBalance)` | _updateTotalJpydfDeposits (provideToSP / withdrawFromSP / offset) | — | Time-series monitoring of `totalJpydfDeposits` |
| CORE-SP-EVT-004 | `StabilityPoolCollBalanceUpdated(uint256 _newBalance)` | _moveOffsetCollAndDebt (offset)/ _sendCollGainToDepositor (each settlement) | — | Time-series monitoring of `collBalance` |
| CORE-SP-EVT-005 | `P_Updated(uint256 _P)` | offset | — | Tracking the depletion rate and recalculating gains off-chain |
| CORE-SP-EVT-006 | `S_Updated(uint256 _S, uint256 _scale)` | offset | — | Tracking the accumulated collateral-gain sum by scale |
| CORE-SP-EVT-007 | `B_Updated(uint256 _B, uint256 _scale)` | _updateYieldRewardsSum (triggerJpydfRewards / end of provideToSP) | — | Tracking the accumulated yield-gain sum by scale |
| CORE-SP-EVT-008 | `ScaleUpdated(uint256 _currentScale)` | offset (inside the scale loop, on each carry-over) | — | Detecting scale changes (determining scale crossings in gain calculations) |
| CORE-SP-EVT-009 | `TroveManagerAddressChanged(address)` | constructor | — | Confirming deployment-time wiring |
| CORE-SP-EVT-010 | `JpydfTokenAddressChanged(address)` | constructor | — | Same as above |
| CORE-SP-EVT-011 | `ActivePoolAddressChanged(address)` | constructor (LiquityBase) | — | Same as above |
| CORE-SP-EVT-012 | `DefaultPoolAddressChanged(address)` | constructor (LiquityBase) | — | Same as above |
| CORE-SP-EVT-013 | `PriceFeedAddressChanged(address)` | constructor (LiquityBase) | — | Same as above |

(The event set for DFStabilityPool is exactly identical to StabilityPool. There are no additional events derived from guards)


### ActivePool Events (CORE-AP-EVT-*)

| ID | Event | Emission point | indexed | Off-chain use |
| --- | --- | --- | --- | --- |
| CORE-AP-EVT-001 | `CollTokenAddressChanged(address _newCollTokenAddress)` | constructor only | none | Auditing deployment wiring |
| CORE-AP-EVT-002 | `BorrowerOperationsAddressChanged(address _newBorrowerOperationsAddress)` | constructor only | none | Same as above |
| CORE-AP-EVT-003 | `TroveManagerAddressChanged(address _newTroveManagerAddress)` | constructor only | none | Same as above |
| CORE-AP-EVT-004 | `DefaultPoolAddressChanged(address _newDefaultPoolAddress)` | constructor only | none | Same as above |
| CORE-AP-EVT-005 | `StabilityPoolAddressChanged(address _newStabilityPoolAddress)` | constructor only | none | Same as above |
| CORE-AP-EVT-007 | `ActivePoolCollBalanceUpdated(uint256 _collBalance)` | `_accountForSendColl` / `_accountForReceivedColl` (all collateral-accounting changes in sendColl / sendCollToDefaultPool / receiveColl / accountForReceivedColl) | none | Tracking and monitoring branch collateral balances |
| CORE-AP-EVT-008 | `ActivePoolAggRecordedDebtUpdated(uint256 _aggRecordedDebt)` | `mintAggInterestAndAccountForTroveChange` / `mintAggInterest` / `_mintBatchManagementFeeAndAccountForChange` | none | Tracking and monitoring aggregate recorded debt |
| CORE-AP-EVT-009 | `ActivePoolAggWeightedDebtSumUpdated(uint256 _aggWeightedDebtSum)` | `mintAggInterestAndAccountForTroveChange` | none | Tracking and monitoring aggregate weighted debt |
| CORE-AP-EVT-010 | `ActivePoolAggBatchManagementFeesUpdated(uint256 _aggBatchManagementFees)` | `_mintBatchManagementFeeAndAccountForChange` | none | Tracking and monitoring aggregate batch management fee accounting |
| CORE-AP-EVT-011 | `ActivePoolAggWeightedBatchManagementFeeSumUpdated(uint256 _aggWeightedBatchManagementFeeSum)` | `_mintBatchManagementFeeAndAccountForChange` | none | Tracking and monitoring aggregate weighted batch management fees |
| CORE-AP-EVT-012 | `AggregateInterestMinted(address indexed _jpydfToken, address indexed _stabilityPool, address indexed _interestRouter, uint256 _pendingAggInterest, uint256 _upfrontFee, uint256 _mintedAmount, uint256 _spYield, uint256 _interestRouterYield)` | `_mintAggInterest` (`mintedAmount > 0`) | `_jpydfToken`, `_stabilityPool`, `_interestRouter` | External fee/revenue accounting such as DeFiLlama. `_mintedAmount = gross fees`, `_spYield = supply-side`, `_interestRouterYield = PIL / InterestRouter side` |
| CORE-AP-EVT-013 | `BatchManagementFeeMinted(address indexed _jpydfToken, address indexed _batchManager, uint256 _batchManagementFee)` | `_mintBatchManagementFeeAndAccountForChange` (`batchAccruedManagementFee > 0`) | `_jpydfToken`, `_batchManager` | External accounting/classification of batch manager fees; do not confuse with protocol revenue |


### DefaultPool Events (CORE-DP-EVT-*)

| ID | Event | Emission point | indexed | Off-chain use |
| --- | --- | --- | --- | --- |
| CORE-DP-EVT-001 | `CollTokenAddressChanged(address _newCollTokenAddress)` | constructor only | none | Auditing deployment wiring |
| CORE-DP-EVT-002 | `ActivePoolAddressChanged(address _newActivePoolAddress)` | constructor only | none | Same as above |
| CORE-DP-EVT-003 | `TroveManagerAddressChanged(address _newTroveManagerAddress)` | constructor only | none | Same as above |
| CORE-DP-EVT-004 | `DefaultPoolJpydfDebtUpdated(uint256 _jpydfDebt)` | increaseJpydfDebt / decreaseJpydfDebt | none | Tracking debt awaiting redistribution |
| CORE-DP-EVT-005 | `DefaultPoolCollBalanceUpdated(uint256 _collBalance)` | sendCollToActivePool / receiveColl | none | Tracking collateral awaiting redistribution |


### CollSurplusPool Events (CORE-CSP-EVT-*)

| ID | Event | Emission point | indexed | Off-chain use |
| --- | --- | --- | --- | --- |
| CORE-CSP-EVT-001 | `BorrowerOperationsAddressChanged(address _newBorrowerOperationsAddress)` | constructor only | none | Auditing deployment wiring |
| CORE-CSP-EVT-002 | `TroveManagerAddressChanged(address _newTroveManagerAddress)` | constructor only | none | Same as above |
| CORE-CSP-EVT-003 | `CollBalanceUpdated(address indexed _account, uint256 _newBalance)` | accountSurplus (when recorded)/ claimColl (when zeroed) | `_account` | Tracking claimable balances by account and notifying claim availability |
| CORE-CSP-EVT-004 | `CollSent(address indexed _to, uint256 _amount)` | claimColl | `_to` | Recording payouts |


### GasPool Events (CORE-GP-EVT-*)

| ID | Event | Emission point | indexed | Off-chain use |
| --- | --- | --- | --- | --- |
| (none defined) | — | — | — | — |


### SortedTroves Events (CORE-ST-EVT-*)

| ID | Event | Emission point | indexed | Off-chain use |
| --- | --- | --- | --- | --- |
| CORE-ST-EVT-001 | `TroveManagerAddressChanged(address _troveManagerAddress)` | constructor only (once) | none | Confirm deployment-time wiring (TM address) |
| CORE-ST-EVT-002 | `BorrowerOperationsAddressChanged(address _borrowerOperationsAddress)` | constructor only (once) | none | Confirm deployment-time wiring (BO address) |

- Note: **list operations (insert/remove/reInsert variants) do not emit events**. Off-chain reconstruction of list state is performed from BO / TM-side events (such as TroveOperation).


### TroveNFT Events (CORE-TN-EVT-*)

| ID | Event | Emission point | indexed | Off-chain use |
| --- | --- | --- | --- | --- |
| CORE-TN-EVT-001 | `Transfer(address indexed from, address indexed to, uint256 indexed tokenId)` | mint (from=0)/ burn (to=0)/ transfer | from / to / tokenId | Indexing Trove ownership (subgraph and frontend list of held Troves) |

| CORE-TN-EVT-002 | `Approval(address indexed owner, address indexed approved, uint256 indexed tokenId)` | `approve` | all 3 arguments | Track approval state |
| CORE-TN-EVT-003 | `ApprovalForAll(address indexed owner, address indexed operator, bool approved)` | `setApprovalForAll` | owner / operator | Track operator approvals |

(All are OZ v4.9 ERC721 standard events. There are no TroveNFT- or MetadataNFT-specific events.)


### JpydfToken Events (CORE-BT-EVT-*)

| ID | Event | Emission point | indexed | off-chain use |
| --- | --- | --- | --- | --- |
| CORE-BT-EVT-001 | `CollateralRegistryAddressChanged(address _newCollateralRegistryAddress)` | `setCollateralRegistry` | none | Detect completion of deployment wiring (= permission freeze) |
| CORE-BT-EVT-002 | `TroveManagerAddressAdded(address _newTroveManagerAddress)` | `setBranchAddresses` | none | Audit trail for branch registration |
| CORE-BT-EVT-003 | `StabilityPoolAddressAdded(address _newStabilityPoolAddress)` | `setBranchAddresses` | none | Same as above |
| CORE-BT-EVT-004 | `BorrowerOperationsAddressAdded(address _newBorrowerOperationsAddress)` | `setBranchAddresses` | none | Same as above |
| CORE-BT-EVT-005 | `ActivePoolAddressAdded(address _newActivePoolAddress)` | `setBranchAddresses` | none | Same as above |
| CORE-BT-EVT-006 | ERC-20 `Transfer(address from, address to, uint256 value)` | mint (from=0) / burn (to=0) / each transfer | from, to | Track supply and fund flows (primary subgraph source) |
| CORE-BT-EVT-007 | ERC-20 `Approval(address owner, address spender, uint256 value)` | `approve` / `permit` / allowance changes | owner, spender | Monitor allowance |
| CORE-BT-EVT-008 | `OwnershipTransferred(address previousOwner, address newOwner)` | constructor / `_renounceOwnership` | previousOwner, newOwner | Detect owner setting and renounce (newOwner=0) |
| CORE-BT-EVT-009 | `EIP712DomainChanged()` | **Never emitted** (ERC-5267 declaration only; domain is immutable) | none | No monitoring required (listed for ABI reconciliation) |
| CORE-BT-EVT-010 | `BridgeAdminTransferStarted(address indexed currentBridgeAdmin, address indexed pendingBridgeAdmin)` / `BridgeAdminTransferred(address indexed previousBridgeAdmin, address indexed newBridgeAdmin)` / `BridgeMinterProposed(address indexed bridgeMinter, uint256 proposedAt, uint256 confirmableAt)` / `BridgeMinterProposalCancelled(address indexed bridgeMinter)` / `BridgeMinterConfirmed(address indexed bridgeMinter)` / `BridgeMinterRemoved(address indexed bridgeMinter)` / `BridgeMint(address indexed bridgeMinter, address indexed account, uint256 amount)` / `BridgeBurn(address indexed bridgeMinter, uint256 amount)` | constructor / bridgeAdmin functions / bridge supply path | target address | Bridge-readiness governance, activation, and supply monitoring |


### CollateralRegistry Events (CORE-CR-EVT-*)

| ID | Event | Emission point | indexed | off-chain use |
| --- | --- | --- | --- | --- |
| CORE-CR-EVT-001 | `BaseRateUpdated(uint256 _baseRate)` | constructor (initial value) / `redeemCollateral` | none | Monitor redemption rate transitions and provide a basis for fee estimation |
| CORE-CR-EVT-002 | `LastFeeOpTimeUpdated(uint256 _lastFeeOpTime)` | `redeemCollateral` (only if at least 1 minute has elapsed) | none | Track the decay reference timestamp (for rate reproduction calculations) |


### AddressesRegistry Events (CORE-AR-EVT-*)

| ID | Event | Emission point | indexed | off-chain use |
| --- | --- | --- | --- | --- |
| CORE-AR-EVT-001 | `CollTokenAddressChanged(address)` | `setAddresses` | none | Audit branch wiring and initialize subgraphs (same below) |
| CORE-AR-EVT-002 | `BorrowerOperationsAddressChanged(address)` | `setAddresses` | none | Same as above |
| CORE-AR-EVT-003 | `TroveManagerAddressChanged(address)` | `setAddresses` | none | Same as above |
| CORE-AR-EVT-004 | `TroveNFTAddressChanged(address)` | `setAddresses` | none | Same as above |
| CORE-AR-EVT-005 | `MetadataNFTAddressChanged(address)` | `setAddresses` | none | Same as above |
| CORE-AR-EVT-006 | `StabilityPoolAddressChanged(address)` | `setAddresses` | none | Same as above |
| CORE-AR-EVT-007 | `PriceFeedAddressChanged(address)` | `setAddresses` | none | Same as above |
| CORE-AR-EVT-008 | `ActivePoolAddressChanged(address)` | `setAddresses` | none | Same as above |
| CORE-AR-EVT-009 | `DefaultPoolAddressChanged(address)` | `setAddresses` | none | Same as above |
| CORE-AR-EVT-010 | `GasPoolAddressChanged(address)` | `setAddresses` | none | Same as above |
| CORE-AR-EVT-011 | `CollSurplusPoolAddressChanged(address)` | `setAddresses` | none | Same as above |
| CORE-AR-EVT-012 | `SortedTrovesAddressChanged(address)` | `setAddresses` | none | Same as above |
| CORE-AR-EVT-013 | `InterestRouterAddressChanged(address)` | `setAddresses` | none | Same as above |
| CORE-AR-EVT-014 | `HintHelpersAddressChanged(address)` | `setAddresses` | none | Same as above |
| CORE-AR-EVT-015 | `MultiTroveGetterAddressChanged(address)` | `setAddresses` | none | Same as above |
| CORE-AR-EVT-016 | `CollateralRegistryAddressChanged(address)` | `setAddresses` | none | Same as above |
| CORE-AR-EVT-017 | `JpydfTokenAddressChanged(address)` | `setAddresses` | none | Same as above |
| CORE-AR-EVT-018 | `WETHAddressChanged(address)` | `setAddresses` | none | Same as above |
| CORE-AR-EVT-019 | `OwnershipTransferred(address previousOwner, address newOwner)` | constructor / `_renounceOwnership` | previousOwner, newOwner | Detect owner setting and renounce (newOwner=0, indicator of wiring completion) |
| CORE-AR-EVT-020 | `RiskParamsFinalized(address indexed underlying, uint256 CCR, uint256 MCR, uint256 BCR, uint256 SCR, uint256 liquidationPenaltySP, uint256 liquidationPenaltyRedistribution, uint256 collGasCompensationCap)` | Once on successful `finalizeRiskParams` | underlying | Audit the exact Underlying, six final risk values and compensation cap; trigger pinned readback |


### HintHelpers Events (CORE-HH-EVT-*)

Not applicable (this contract does not define or emit events).


### MultiTroveGetter Events (CORE-MTG-EVT-*)

Not applicable (this contract does not define or emit events).


### DebtInFrontHelper Events (CORE-DFH-EVT-*)

Not applicable (this contract does not define or emit events).


### RedemptionHelper Events (CORE-RH-EVT-*)

Not applicable (this contract does not define or emit events. Redemptions are observed via CR / TM / JpydfToken events).


### LiquidationCandidateGetter Events (CORE-LCG-EVT-*)

Not applicable (this contract does not define or emit events).


### Constants.sol Events (CORE-LIB-EVT-*)

Not applicable (file-level constants do not define or emit events).


### LiquityBase Events (CORE-LIB-EVT-*)

| ID | Event | Emission point | indexed | off-chain use |
| --- | --- | --- | --- | --- |
| CORE-LIB-EVT-001 | `ActivePoolAddressChanged(address _newActivePoolAddress)` | constructor (CORE-LIB-FR-005) | none | Record wiring at deployment (emitted once from each inheriting contract = BO/TM/SP/DFStabilityPool) |
| CORE-LIB-EVT-002 | `DefaultPoolAddressChanged(address _newDefaultPoolAddress)` | Same as above | none | Same as above |
| CORE-LIB-EVT-003 | `PriceFeedAddressChanged(address _newPriceFeedAddress)` | Same as above | none | Same as above (AddressesRegistry also has an event of the same name, but it is a separate declaration. CORE-AR) |


### LiquityMath Events (CORE-LIB-EVT-*)

Not applicable.


### Ownable Events (CORE-LIB-EVT-*)

| ID | Event | Emission point | indexed | off-chain use |
| --- | --- | --- | --- | --- |
| CORE-LIB-EVT-004 | `OwnershipTransferred(address indexed previousOwner, address indexed newOwner)` | constructor (0 → initialOwner) / `_renounceOwnership` (owner → 0) | previousOwner, newOwner | Monitor deployment and completion of wiring (ownerless transition). Observing `newOwner == address(0)` = signal that wiring is finalized |


### Types Events (CORE-LIB-EVT-*)

Not applicable (type definitions only).


---

## 12. Failure and Exceptional Behavior (ERR)

> First, system-level exceptional scenarios (CORE-SYS-ERR-*) are specified, followed by contract-specific exceptional behavior (revert lists and degraded behavior).

### 12.1 System-Level Exceptional Behavior (CORE-SYS-ERR-*)

#### CORE-SYS-ERR-001: Oracle Failure Cascade 🔵
- When PriceFeedProxy detects a new failure it calls `BO.shutdownFromOracleFailure()` and enters a recoverable pause (CORE-BO-FR-022). A borrowing transaction that then reverts with `NewOracleFailureDetected` may roll back that nested pause; liquidation/redemption scans or permissionless fetch keepers use no-op/normal returns so the pause commits.
- Pure additions and repayments need no oracle quote (CORE-MOD-014). Liquidation requires a source-policy-valid quote; closeTrove and economic shutdown additionally require JPY provenance younger than 30h. Normal redemption and risk increases remain blocked during oracle pause until validated resume. Interest continues throughout the pause.
- **Verification**: integration (combined with Oracle layer) / parity
#### CORE-SYS-ERR-002: Critical Mode (TCR < CCR) 🔵
- When branch TCR falls below CCR, BO enters a restricted mode that rejects "adjustments that worsen TCR" (the normative behavior is CORE-BO-ERR-001: borrowing only when TCR recovers to ≥ CCR; collateral withdrawal only when combined with repayment of equal or greater value; upfront fee checks continue to apply). Liquidations, redemption, and SP operations proceed normally. Interest rate adjustments proceed normally only for free changes after the cooldown has elapsed; paths involving an upfront fee (premature changes, joining a batch, etc.) are effectively unavailable because they require fee-inclusive TCR ≥ CCR (CORE-BO-FR-011/017).
- The mode is automatically lifted if price recovery, debt repayment, or liquidation returns TCR to ≥ CCR (it is evaluated each time, not via a flag).
- **Verification**: parity / unit (mode matrix)
#### CORE-SYS-ERR-003: Branch Shutdown (Irreversible Degradation) 🔵
- The only trigger is permissionless `BO.shutdown()` when `TCR < SCR` (CORE-BO-FR-021). It permanently stops interest, freezes borrowing operations, excludes normal redemption, and enables urgent redemption. Oracle failure uses the recoverable state in CORE-SYS-ERR-001 and does not directly enter this mode.
- There is no recovery mechanism (irreversible). Remaining debt is wound down through urgent redemption, repayment, and liquidation, and borrowers exit via `closeTrove` / `claimCollateral`.
- **Verification**: parity / unit (post-shutdown matrix)
#### CORE-SYS-ERR-004: Liquidation Degradation When SP Is Depleted 🔵
- If the SP available balance (`totalJpydfDeposits − MIN_JPYDF_IN_SP`) is insufficient during liquidation, the shortfall falls back to redistribution (with a higher penalty) (branch in CORE-TM-FR-002). Liquidation does not stop even if the SP is completely empty (pure redistribution). On a finalized branch where liquidation candidates can exist, the liquidator may still call `provideToSP` immediately before liquidation (🟡 DFStabilityPool allows "deposit → liquidation" within the same tx; only **collateral-gain payout and withdrawal** in the same block are prohibited by CORE-MOD-004). An unfinalized branch rejects `provideToSP` under CORE-MOD-013.
- **Verification**: parity / unit (3 branches)
#### CORE-SYS-ERR-005: Lifecycle of Zombie Troves 🔵
- A Trove whose `debt < MIN_DEBT` (🟡 CORE-MOD-002) after partial redemption becomes a zombie and is excluded from SortedTroves (outside normal redemption targets. Only the most recent occurrence is stored as `lastZombieTroveId` and processed preferentially in the next redemption). Zombies continue to accrue interest, receive redistribution, and remain liquidation targets. They return to active if restored to at least MIN_DEBT via `adjustZombieTrove` (or permissionless `applyPendingDebt` after redistribution recovery), and can be closed by full repayment (CORE-BO-FR-008/009/010, CORE-TM-FR-016/021).
- Monitoring note: zombies do not appear from a SortedTroves scan alone. Liquidation monitoring should also check `lastZombieTroveId` via LCG's `getLiquidationCandidatesWithLastZombie` or `getLastZombieLiquidationCandidate` (CORE-LCG-FR-003).
- **Verification**: parity / unit


### BorrowerOperations Error Cases (CORE-BO-ERR-*)

#### CORE-BO-ERR-001: Adjustment Restrictions When TCR < CCR (Below Critical Threshold) 🔵

- Type: Error-handling
- Statement: When pre-adjustment TCR < CCR, `_requireValidAdjustmentInCurrentMode` applies the following restrictions.
  - Borrowing (`debtIncrease > 0`) is allowed only if post-adjustment TCR recovers to ≥ CCR (violation: `TCRBelowCCR`)
  - Collateral withdrawal is allowed only when accompanied by debt repayment of equal or greater value (`debtDecrease × 1e18 ≥ collDecrease × price`; violation: `RepaymentNotMatchingCollWithdrawal`)
  - ICR requirements (MCR / MCR+BCR) apply the same as in normal mode
  - The "post-adjustment TCR ≥ CCR" requirement that applies in normal mode is not imposed in critical mode (allowing operations such as adding collateral or repaying debt that improve TCR while it remains below CCR)
- Verification: parity / unit (per-mode matrix)

#### CORE-BO-ERR-002: Silent Cap on Repayment Amount 🔵

- Type: Error-handling
- Statement: Repayment (`debtDecrease`) does not revert even if the specified amount exceeds `entireDebt − MIN_DEBT`; it is automatically reduced (MIN_DEBT is the 🟡 DF value (CORE-MOD-002 / [Parameters.md](../../../Parameters.md))). If `entireDebt ≤ MIN_DEBT` (zombie, etc.), it is reduced to 0, and if the other components are also zero, the result is `ZeroAdjustment`. Full repayment is possible only through `closeTrove`. Frontends and Zappers must assume cases where "less than the specified amount is repaid."
- Verification: parity / unit

#### CORE-BO-ERR-003: Function Availability After Shutdown 🔵

- Type: Error-handling
- Statement: While `hasBeenShutDown == true`, behavior is as follows.
  - **Allowed**: `closeTrove` (TCR check exempted) / `claimCollateral` / `setAddManager` / `setRemoveManager(WithReceiver)` / `removeInterestIndividualDelegate` / `onLiquidateTrove` / all views
  - **revert with `IsShutDown`**: `openTrove` / `openTroveAndJoinInterestBatchManager` / `adjustTrove`, `addColl`, `withdrawColl`, `withdrawJpydf`, `repayJpydf` / `adjustZombieTrove` / `adjustTroveInterestRate` / `applyPendingDebt` / `setInterestIndividualDelegate` / `registerBatchManager` / `lowerBatchManagementFee` / `setBatchManagerAnnualInterestRate` / `setInterestBatchManager` / `removeFromBatch` / `kickFromBatch` / `switchBatchManager` (via internal call) / `shutdown` (re-execution)
  - **no-op return**: `shutdownFromOracleFailure`
- Verification: parity / unit (post-shutdown matrix)

#### CORE-BO-ERR-004: Behavior on Oracle Failure 🔵/🟡

- Type: Error-handling
- Statement: Price-dependent operations reject failed quotes. Pure additions and repayments bypass oracle reads before permanent shutdown. Liquidation can recover with a source-policy-valid quote; economic shutdown and close additionally require JPY provenance younger than 30h. Normal redemption and risk increases also require the BO oracle-pause latch to be cleared (CORE-MOD-014). A reverting outer call rolls back nested pause state and events.
- Verification: parity / unit

#### CORE-BO-ERR-005: Reserved Risk-Lifecycle Rejections 🟡
Calling either Trove-open entrypoint while `riskParamsFinalized == false` reverts with `RiskParamsNotFinalized()`. Calling `syncRiskParams(...)` from any address other than AddressesRegistry reverts with `CallerNotAddressesRegistry()`. Verification: unit.


### TroveManager Error Cases (CORE-TM-ERR-*)

#### CORE-TM-ERR-001: Failure Behavior of batchLiquidateTroves 🔵
Empty array → `EmptyData`. Current oracle failure → no-op return so the pause and `SourceFailureHandled` event can commit. A successful receipt alone does not prove that liquidation executed, so keepers must inspect the event and Trove state. If traversal results in zero liquidatable Troves → `NothingToLiquidate` (partial success is allowed). Verification: unit.

#### CORE-TM-ERR-002: redeemCollateral Succeeds Even with Zero Redemption 🔵
Returns 0 before value-state mutation on current oracle failure. It also does not revert if all candidates otherwise yield zero redemption. This prevents one branch miss or pause from stopping cross-branch processing. Verification: parity / unit.

#### CORE-TM-ERR-003: Failure Behavior of urgentRedemption 🔵
Not shut down → `NotShutDown`, `_jpydfAmount == 0` → `ZeroAmount`, caller has insufficient JPYdf balance → `NotEnoughJpydfBalance`, received collateral is less than `_minCollateral` → `MinCollNotReached(actual received amount)`. Ineligible Troves (non-active/zombie or `entireDebt` 0) are skipped and do not revert. Verification: unit.

#### CORE-TM-ERR-004: Closing the Last Remaining Trove Is Prohibited 🔵
Owner closure in a non-shutdown branch, and closure by liquidation (regardless of shutdown state), fail with `OnlyOneTroveLeft` when `TroveIds.length == 1`. Only owner closure after shutdown allows the last remaining Trove. Verification: parity / unit.

#### CORE-TM-ERR-005: BatchSharesRatioTooHigh 🔵
Adding debt to a batch whose debt/shares ratio exceeds the upper limit (joining on open, adjustment, applying interest, joining a batch) fails with `BatchSharesRatioTooHigh`. Redemption is out of scope (CORE-TM-SEC-006). Verification: unit.

#### CORE-TM-ERR-006: Unauthorized Risk Sync 🟡
Calling `syncRiskParams(...)` from any address other than AddressesRegistry reverts with `CallerNotAddressesRegistry()`, matching BorrowerOperations. Verification: unit.


### StabilityPool / DFStabilityPool Error Cases (CORE-SP-ERR-*)

#### CORE-SP-ERR-001: List of Reverts for Depositor Operations 🔵/🟡
| Function | Condition | revert |
| --- | --- | --- |
| provideToSP | `riskParamsFinalized == false` | `RiskParamsNotFinalized()` |
| provideToSP | `_topUp == 0` | `"StabilityPool: Amount must be non-zero"` |
| withdrawFromSP | no deposit | `"StabilityPool: User must have a non-zero deposit"` |
| withdrawFromSP | post-withdrawal `totalJpydfDeposits < MIN_JPYDF_IN_SP` | `"Withdrawal must leave totalJpydfDeposits >= MIN_JPYDF_IN_SP"` |
| claimAllCollGains | has deposit | `"StabilityPool: User must have no deposit"` |

| claimAllCollGains | stash is 0 | `"StabilityPool: Amount must be non-zero"` |
- Verification: unit / parity.

#### CORE-SP-ERR-002: same-block collateral-gain claim and withdrawal reverts 🟡
- DFStabilityPool's `provideToSP(..., true)` reverts with `"StabilityPool: Coll gain claim must wait after deposit"` for an existing depositor that has already called `provideToSP` in the same block and has current or stashed collateral gains. `withdrawFromSP` reverts for the same caller with `"StabilityPool: Withdrawal must wait after deposit"` (CORE-SP-FR-004, CORE-MOD-004 (§2 DF delta ledger)). StabilityPool (base normative implementation) has neither revert.
- Verification: unit.

#### CORE-SP-ERR-003: behavior when privileged function preconditions are violated 🔵
- Unauthorized calls to `offset` / `triggerJpydfRewards` revert with `"StabilityPool: Caller is not TroveManager"` / `"StabilityPool: Caller is not ActivePool"`, respectively.
- Calling `offset` when `totalJpydfDeposits == 0` causes a division panic (Panic 0x12), and calling it when `_debtToOffset == totalJpydfDeposits` reverts with `"P must never decrease to 0"`. Both are precondition violations that TroveManager's liquidation logic is assumed not to reach, and SP alone does not perform input validation (cross-contract consistency is CORE-SYS-INV-011).
- Verification: unit (boundary calls) / parity.


### ActivePool error cases (CORE-AP-ERR-*)

#### CORE-AP-ERR-001: failure behavior (require strings / arithmetic reverts)🔵
| Path | Condition | revert |
| --- | --- | --- |
| receiveColl / accountForReceivedColl | Caller is neither BO nor DP | `"ActivePool: Caller is neither BO nor Default Pool"` |
| sendColl | Caller is neither BO/TM/SP | `"ActivePool: Caller is neither BorrowerOperations nor TroveManager nor StabilityPool"` |
| mintAggInterest | Caller is neither BO nor SP | `"ActivePool: Caller is not BorrowerOperations nor StabilityPool"` |
| mintAggInterestAndAccountForTroveChange | Caller is neither BO nor TM | `"ActivePool: Caller is neither BorrowerOperations nor TroveManager"` |
| sendCollToDefaultPool / mintBatchManagementFeeAndAccountForChange / setShutdownFlag | Caller is not TM | `"ActivePool: Caller is not TroveManager"` |
| getNewApproxAvgInterestRateFromTroveChange | `upfrontFee != 0` | assert failure (Panic 0x01) |
| Accounting operations in general | Subtraction exceeds balance or tracker | Panic 0x11 (Solidity 0.8 checked) |

- **Verification**: unit / parity


### DefaultPool error cases (CORE-DP-ERR-*)

#### CORE-DP-ERR-001: failure behavior 🔵
| Path | Condition | revert |
| --- | --- | --- |
| receiveColl | Caller is not AP | `"DefaultPool: Caller is not the ActivePool"` |
| sendCollToActivePool / increaseJpydfDebt / decreaseJpydfDebt | Caller is not TM | `"DefaultPool: Caller is not the TroveManager"` |
| sendCollToActivePool / decreaseJpydfDebt | Excessive subtraction | Panic 0x11 (checked operation) |

- **Verification**: unit / parity


### CollSurplusPool error cases (CORE-CSP-ERR-*)

#### CORE-CSP-ERR-001: failure behavior 🔵
| Path | Condition | revert |
| --- | --- | --- |
| accountSurplus | Caller is not TM | `"CollSurplusPool: Caller is not TroveManager"` |
| claimColl | Caller is not BO | `"CollSurplusPool: Caller is not Borrower Operations"` |
| claimColl | `balances[_account] == 0` | `"CollSurplusPool: No collateral available to claim"` |

- **Verification**: unit / parity


### SortedTroves error cases (CORE-ST-ERR-*)

#### CORE-ST-ERR-001: revert string list 🔵
Custom errors are not used. All are require strings:

| String | Occurrence |
| --- | --- |
| `"SortedTroves: Caller is not BorrowerOperations"` | insert / reInsert / insertIntoBatch / reInsertBatch |
| `"SortedTroves: Caller is not BorrowerOperations nor TroveManager"` | remove / removeFromBatch |
| `"SortedTroves: List already contains the node"` | insert / insertIntoBatch |
| `"SortedTroves: _id cannot be the root node's ID"` | insert |
| `"SortedTroves: _troveId cannot be the root node's ID"` | insertIntoBatch |
| `"SortedTroves: _batchId cannot be zero"` | insertIntoBatch |
| `"SortedTroves: List does not contain the id"` | remove / reInsert |
| `"SortedTroves: Must use removeFromBatch() to remove batched node"` | remove |
| `"SortedTroves: Must not reInsert() batched node"` | reInsert |
| `"SortedTroves: Must use remove() to remove non-batched node"` | removeFromBatch |
| `"SortedTroves: List does not contain the batch"` | reInsertBatch |


### TroveNFT error cases (CORE-TN-ERR-*)

#### CORE-TN-ERR-001: revert string / custom error list 🔵/🟡
The deployed DF surface uses one custom error for non-TM mint/burn; inherited OZ v4.9 ERC-721 failures remain require strings.

| String / error | Occurrence |
| --- | --- |
| `JPYdfTroveNFT__CallerIsNotTroveManager()` | mint / burn (non-TM call) |
| `"ERC721: mint to the zero address"` | mint (owner=0) |
| `"ERC721: token already minted"` | mint (duplicate troveId) |
| `"ERC721: invalid token ID"` | burn / ownerOf / tokenURI / getApproved, etc. (nonexistent token) |
| `"ERC721: caller is not token owner or approved"` and other OZ v4.9 standard strings | transfer / approve operations |


### JpydfToken error cases (CORE-BT-ERR-*)

#### CORE-BT-ERR-001: failure behavior (custom errors / standard reverts)🔵
| Condition | revert |
| --- | --- |
| Unauthorized mint | `JpydfToken__CallerIsNotBorrowerOperationsOrActivePool` |
| Unauthorized burn | `JpydfToken__CallerIsNotCoreBurner` |
| Unauthorized sendToPool / returnFromPool | `JpydfToken__CallerIsNotStabilityPool` |
| transfer/transferFrom/bridgeMint recipient is zero, token itself, or a registered protocol contract | `JpydfToken__CannotTransferToProtocolContract` |
| `setBranchAddresses` / `setCollateralRegistry` core address is zero | `JpydfToken__ZeroCoreAddress` |
| `setBranchAddresses` / `setCollateralRegistry` core address is not a contract | `JpydfToken__CoreAddressMustBeContract` |
| Constructor owner is zero | `JpydfToken__ZeroOwner` |
| Constructor bridge admin is zero | `JpydfToken__ZeroBridgeAdmin` |
| Constructor / transferBridgeAdmin bridge admin equals owner | `JpydfToken__BridgeAdminCannotBeOwner` |
| Constructor / transferBridgeAdmin / acceptBridgeAdmin bridge admin is not a contract | `JpydfToken__BridgeAdminMustBeContract` |
| transferBridgeAdmin bridge admin is token itself | `JpydfToken__BridgeAdminCannotBeToken` |
| transferBridgeAdmin / acceptBridgeAdmin bridge admin is a registered/proposed bridge minter | `JpydfToken__BridgeAdminCannotBeMinter` |
| Non-admin calls an admin function | `JpydfToken__CallerIsNotBridgeAdmin` |
| Proposed bridge minter is zero | `JpydfToken__ZeroBridgeMinter` |
| Proposed bridge minter is token itself | `JpydfToken__BridgeMinterCannotBeToken` |
| Proposed/confirmed bridge minter is current or pending bridge admin | `JpydfToken__BridgeMinterCannotBeAdmin` |
| Proposed/confirmed bridge minter is not a contract | `JpydfToken__BridgeMinterMustBeContract` |
| Proposed bridge minter is already registered | `JpydfToken__BridgeMinterAlreadySet` |
| Bridge minter proposal already exists | `JpydfToken__BridgeMinterAlreadyProposed` |
| confirm/cancel without a bridge minter proposal | `JpydfToken__NoBridgeMinterProposed` |
| Bridge minter timelock has not elapsed | `JpydfToken__BridgeMinterTimelockNotElapsed` |
| Removed address is not a bridge minter | `JpydfToken__NotBridgeMinter` |
| Non-pending address accepts bridge admin | `JpydfToken__CallerIsNotPendingBridgeAdmin` |
| Renounce while bridge minters remain | `JpydfToken__BridgeMintersStillSet` |
| Renounce while bridge minter proposal exists | `JpydfToken__CannotRenounceWithPendingBridgeMinter` |
| Unauthorized bridge mint/burn | `JpydfToken__CallerIsNotBridgeMinter` |
| onlyOwner violation | `"Ownable: caller is not the owner"` |
| ERC-20 / EIP-2612 standard violations | OZ v4.9.5 standard strings (insufficient balance, insufficient allowance, expired deadline, signature mismatch, etc.) |

(The custom errors `InvalidShortString()` / `StringTooLong(string)` in the ABI originate from OZ `ShortStrings` and can only be reached during constructor name/version processing, so they do not occur during operation.)


### CollateralRegistry error cases (CORE-CR-ERR-*)

#### CORE-CR-ERR-001: failure behavior (require strings)🔵
| Condition | revert |
| --- | --- |
| `_maxFeePercentage` out of range | `"Max fee percentage must be between 0.5% and 100%"` |
| `_jpydfAmount == 0` | `"CollateralRegistry: Amount must be greater than zero"` |
| Effective rate > `_maxFeePercentage` | `"CR: Fee exceeded provided maximum"` |
| `getToken` / `getTroveManager` index ≥ 10 | `"Invalid index"` |
| constructor: empty list / 11 or more | `"Collateral list cannot be empty"` / `"Collateral list too long"` |
| Insufficient balance on burn | `"ERC20: burn amount exceeds balance"` (JpydfToken side) |


### AddressesRegistry error cases (CORE-AR-ERR-*)

#### CORE-AR-ERR-001: failure behavior (custom errors)🔵/🟡
| Condition | revert |
| --- | --- |
| `_ccr <= 1e18 || _ccr >= 2e18` | `InvalidCCR()` |
| `_mcr <= 1e18 || _mcr >= 2e18` | `InvalidMCR()` |
| `_bcr < 5e16 || _bcr >= 50e16` | `InvalidBCR()` |
| `_scr <= 1e18 || _scr >= 2e18` | `InvalidSCR()` |
| `_liquidationPenaltySP < MIN_LIQUIDATION_PENALTY_SP` | `SPPenaltyTooLow()` |
| `_liquidationPenaltySP > _liquidationPenaltyRedistribution` | `SPPenaltyGtRedist()` |

| `_liquidationPenaltyRedistribution > MAX_LIQUIDATION_PENALTY_REDISTRIBUTION` | `RedistPenaltyTooHigh()` |
| Non-Owner `setAddresses` | `"Ownable: caller is not the owner"` |
| finalization with `SCR >= MCR || MCR >= CCR` | `InvalidCollateralRatioOrder()` |
| finalization with `MCR * (COLL_GAS_COMPENSATION_DIVISOR - 1) < (1e18 + LIQUIDATION_PENALTY_SP) * COLL_GAS_COMPENSATION_DIVISOR` | `MCRBelowSPPenalty()` |
| finalization with `1e18 + LIQUIDATION_PENALTY_REDISTRIBUTION > MCR` | `MCRBelowRedistributionPenalty()` |
| finalization with `1e18 + URGENT_REDEMPTION_BONUS > SCR` | `SCRBelowUrgentRedemptionBonus()` |
| compensation cap is zero or above `1_000 ether` | `InvalidCollGasCompensationCap()` |
| `finalizeRiskParams` on an already-finalized branch | `RiskParamsAlreadyFinalized()` |
| caller is not the immutable finalizer | `CallerNotRiskParamsFinalizer()` |
| `_expectedUnderlying` has no runtime code (zero / EOA) | `InvalidExpectedUnderlying()` |
| `collToken` has no runtime code | `InvalidDToken()` |
| `dToken.underlying() != _expectedUnderlying` | `DTokenUnderlyingMismatch(expected, actual)` |
| `dToken.vault()` has no runtime code | `InvalidVault()` |
| `vault.dToken() != collToken` | `VaultDTokenMismatch(expected, actual)` |
| `vault.underlying() != _expectedUnderlying` | `VaultUnderlyingMismatch(expected, actual)` |
| `dToken.cap() != 0` | `DTokenCapNotZero(cap)` |
| `dToken.totalSupply() != 0` | `DTokenSupplyNotZero(supply)` |
| `troveManager.getTroveIdsCount() != 0` | `TrovesExist(count)` |
| branch debt != 0 | `BranchDebtNotZero(debt)` |
| branch collateral != 0 | `BranchCollNotZero(coll)` |
| Stability Pool deposits != 0 | `StabilityPoolNotEmpty(deposits)` |
| oracle-failure pause is active | `OracleFailureShutdownActive()` |
| any of BO / TM / AP is terminally shut down | `BranchAlreadyShutDown()` |


### HintHelpers Error Cases (CORE-HH-ERR-*)

#### CORE-HH-ERR-001: Invalid _collIndex 🔵
If `_collIndex` is outside the registered branch range of CollateralRegistry: values at or above the slot upper bound revert in `CollateralRegistry.getTroveManager` (`"Invalid index"`), while an unregistered index within the slot range reverts as a failed view call to `address(0)` (no explicit error).


### MultiTroveGetter Error Cases (CORE-MTG-ERR-*)

#### CORE-MTG-ERR-001: Invalid _collIndex 🔵
A slot where `getTroveManager(_collIndex)` returns `address(0)` → reverts with require `"Invalid collateral index"`. Values at or above the slot upper bound revert on the CollateralRegistry side (`"Invalid index"`). An unset `sortedTroves` is an assert (Panic) and is normally unreachable.


### DebtInFrontHelper Error Cases (CORE-DFH-ERR-*)

#### CORE-DFH-ERR-001: Invalid _collIndex 🔵
`getTroveManager(_collIndex)` returns `address(0)` → require `"Invalid collateral index"`. Values at or above the slot upper bound revert on the CollateralRegistry side (`"Invalid index"`).


### RedemptionHelper Error Cases (CORE-RH-ERR-*)

#### CORE-RH-ERR-001: Failure Behavior 🔵/🟡
- **Type**: Error / Failsafe / **Source**: base implementation (RedemptionHelper.sol) + CORE-MOD-015

| Condition | Behavior |
| --- | --- |
| `_jpydf == 0` | require `"Redeemed amount must be non-zero"` |
| `_minCollRedeemed.length != numBranches` | require `"Wrong _minCollRedeemed length"` |
| Branch collateral received < `_minCollRedeemed[i]` | require `"Insufficient collateral redeemed"` (entire revert = all-or-nothing) |
| fee rate > `_maxFeePct` | CR-side require `"CR: Fee exceeded provided maximum"` propagates |
| approve / insufficient JPYdf balance | `transferFrom` revert propagates |
| constructor inconsistency | `"Wrong number of registries"` / `"TroveManager mismatch"` |
| `simulateRedemption`: `fetchRedemptionPrice()` returns `failure == true` for a branch that TM marked redeemable | Set that branch's `redeemable` to false and exclude it from scanning, while retaining its proportion in CR's allocation denominator if another available branch exists. If no available branch has a positive allocation, return `(branch, 0)` |
| `truncateRedemption`: any post-simulation redemption-price reread returns `failure == true` | Return `(0, 0, redeemed)`, where `redeemed.length == numBranches` and every entry is zero; do not return a partial estimate |
| Every allocated branch returns `failure == true` during on-chain normal redemption | Each TM returns zero before state mutation and CR burns zero. The Helper wrapper sends no collateral and refunds all unburned JPYdf (a positive min-out still causes the existing all-or-nothing revert) |

- **Verification**: parity / unit / integration.


### LiquidationCandidateGetter Error Cases (CORE-LCG-ERR-*)

#### CORE-LCG-ERR-001: Invalid _collIndex 🟢
Constructor registry zero → `LiquidationCandidateGetter__InvalidCollateralRegistry`. `getTroveManager(_collIndex)` returns `address(0)` → `LiquidationCandidateGetter__InvalidCollateralIndex`. Values at or above the slot upper bound revert on the CollateralRegistry side (`"Invalid index"`).


### LiquityBase Error Cases (CORE-LIB-ERR-*)

#### CORE-LIB-ERR-001: Arithmetic Panic Only (No Custom Errors) 🔵
LiquityBase (and LiquityMath) have no custom errors or require statements; failure modes are limited to Solidity 0.8 checked arithmetic Panics (such as multiplication overflow). `_calcInterest` reverts in parameter ranges where `_weightedDebt * _period` exceeds uint256, but this is unreachable under the upstream interest-rate cap (`MAX_ANNUAL_INTEREST_RATE` = 250%) and realistic elapsed-time ranges.
- **Verification**: fuzz (Panic confirmation in boundary ranges)

“Branch aggregate debt ≥ Σ Trove entireDebt” (which holds due to the combination of `_calcInterest` floor and ActivePool ceilDiv) is specified by CORE-SYS-INV-001.


### Ownable Error Cases (CORE-LIB-ERR-*)

#### CORE-LIB-ERR-002: onlyOwner Violation Revert 🔵
An `onlyOwner` violation reverts with the require string `"Ownable: caller is not the owner"` rather than a custom error (note that this differs from the custom-error policy of other contracts in core).
- **Verification**: unit (string match)


---

## 13. Acceptance Criteria and Verification Plan


The acceptance criteria for this specification are summarized in two points: “**core functions identically to the fork source (base)**” and “**DF differences are limited exactly as recorded in the ledger**.” Verification is performed in the following four layers.

### 13.1 Verification Method Vocabulary (Used by Each FR Verification Line)

| Method | Meaning |
| --- | --- |
| `parity` | **Fork-source identity verification**. (a) Static: diff review / scripted reconciliation confirms that deltas from base match the §2.2 ledger and §5.1 catalog, (b) Dynamic: tests confirm that the behavior of the relevant function or state variable (state changes, reverts, events, return values) matches the base implementation or a ledgered delta. Default for 🔵 requirements |
| `unit` | Function-level happy-path, boundary, and revert tests |
| `fuzz` | Property tests with randomized inputs |
| `invariant` | Invariant tests targeting the invariants in §8 (randomly execute operation sequences and check identities) |
| `fork` | Real-contract integration tests on a mainnet fork |
| `integration` | 🟢 Path tests integrated with proprietary layers (dToken / Oracle, etc.) |
| `deploy verification` | Machine verification in deployment scripts and post-deployment checks (CORE-SYS-GOV-003) |
| `manual` | Code review and comparison against operational procedures |

### 13.2 Four-Layer Assurance Structure

1. **Static parity (diff review / scripted reconciliation)** — the current CI Core JPYDF surface guard mechanically detects reintroduction of old BOLD public/API names. Deltas from base are checked against the §2.2 `CORE-MOD-*` ledger, §5.1 catalog, and source diffs; review / helper scripts must confirm that every non-rename delta is enumerated in that ledger.
2. **Behavioral parity (tests)** — For all FRs in this document, 🔵 verifies identity with base behavior, while 🟡 verifies “base behavior + only the ledgered differences.” In particular, DFStabilityPool requires: (a) behavior identical to StabilityPool (all FRs and all INVs outside the guard hold equivalently), (b) the four CORE-MOD-004 differences function as intended (same-block collateral-gain claim and withdrawal revert; no-claim stash succeeds; top-up with no collateral gain and new deposit succeed; next-block settlement succeeds; no viable flash-loan path), and (c) differences are limited to these four points (machine confirmation of source diff).
3. **Invariants (invariant tests)** — Continuously check §8 CORE-SYS-INV-* and contract-specific INVs in the invariant suite.
4. **Deployment and activation gates** — Machine verification for CORE-SYS-GOV-003 (Constants ⇔ Parameters.md consistency, relational formulas, wiring, and renounced permissions), plus the CORE-MOD-013 lifecycle, empty state, exact Underlying, six values, and atomic synchronization before reserved-branch activation.

### 13.3 Acceptance Criteria

- [ ] CI: Core JPYDF surface guard is green (zero old BOLD public/API names reintroduced)
- [ ] All FR / INV / SEC / ERR entries in this document are covered by the corresponding Verification-method tests or review records (trace by ID reference. Test names are not written in this document = [standard](../../../README.md#requirements-spec-standard) guardrail)
- [ ] For all contracts in the §5.1 catalog, every external/public function in the ABI corresponds to one of the FRs in §6 (machine coverage check)
- [ ] The DFStabilityPool ⇔ StabilityPool source diff contains no differences other than the four functional differences stated in CORE-MOD-004 (+ contract name replacement and helper definitions)
- [ ] Values in `Constants.sol` match [Parameters.md](../../../Parameters.md) (CORE-MOD-002/003/005)
- [ ] Deployment and reserved-activation verification: wiring, immutable values, renounced permissions, risk lifecycle, empty state, exact Underlying, six values, and atomic synchronization (CORE-SYS-GOV-001/002/003, CORE-MOD-013)

> The mapping ledger between individual FRs ⇔ tests is not placed in this document (to exclude volatile information). The authoritative form is a one-way link where the test side references IDs with `@custom:requirement CORE-…`, etc.

---

## 14. Open Items (TBD)

> Since core is base-frozen, “open items in the specification itself” should not occur in principle. TBDs in this section are limited to items where **adoption or operational decisions as DF** remain.

#### CORE-AP-TBD-001: interestRouter Destination (Destination of the Remaining 25% of Interest)
Resolved in `CORE-AP-FR-007`, `CORE-AP-FR-008`, and `IRTR-FR-001`: DF dToken wiring binds the immutable destination to `InterestRouterForwarder`; its recipient and owner are frozen and handed over through the deployment package.

Resolved (2026-06-14): In jpydf's DF dToken wiring, `interestRouter` is bound to `InterestRouterForwarder`. The remaining 25% minted by ActivePool accumulates in the Forwarder, and anyone can forward the full amount to the current `recipient` via `route()`. The Forwarder's initial `recipient` is specified by the mandatory deploy env `DF_INTEREST_ROUTER_RECIPIENT` and its initial `owner` by the mandatory deploy env `DF_INTEREST_ROUTER_OWNER`; if unspecified, the deploy fails fast. The `owner` uses 2-step transfer with renounce disabled, and Day-1 `PrepareDFGovernanceHandover` / `VerifyDFGovernanceHandover` move it to common Timelock management. This keeps ActivePool's immutable fixed to the Forwarder address while letting the final delivery destination for PIL / Treasury / future governance be changeable on the receiving side.
- **Status**: Resolved (complete deploys: `InterestRouterForwarder`. The V2-gov / direct Governance-address fallback is removed from the Day-1 deploy path)

---

#### CORE-TN-TBD-001: Deployment-Order Dependency of Collection name/symbol
Resolved (2026-06-17): Active deployment uses `JPYdfTroveNFT`, but collection `name`/`symbol` are still fixed from `collToken.name()` / `collToken.symbol()` at constructor execution time. Active branches MUST finalize dToken metadata with `setTokenInfo` before branch deployment, so the collection fixes the final product name. Reserved placeholder branches may permanently retain placeholder collection names if they are deployed before metadata finalization. `JPYdfMetadataNFT` reads `collToken.name()` / `symbol()` dynamically during `tokenURI`, so JSON/SVG metadata follows later dToken finalization; only the ERC-721 collection `name()` / `symbol()` are fixed.

#### CORE-TN-TBD-002: NFT Metadata Deployment Wording

Resolved (2026-06-17, updated 2026-06-20): Active deployment wires `JPYdfTroveNFT` / `JPYdfMetadataNFT`, so collection `name()` / `symbol()` and tokenURI JSON/SVG wording are JPYdf-branded on-chain. Under the fresh-deploy policy, undeployed upstream `TroveNFT` / `MetadataNFT` / `baseSVG` have been removed from production `src`. No frontend/indexer alias is required for active deployment, and there is no production path that emits old Liquity/BOLD NFT wording.

#### CORE-LCG-TBD-001: Responsibility split for liquidation monitoring of zombie Troves 🟢
Resolved (2026-06-14): Extend LCG to treat `lastZombieTroveId` as a candidate. `getLastZombieLiquidationCandidate` evaluates the zombie pointer alone, and `getLiquidationCandidatesWithLastZombie` optionally appends a liquidatable last zombie to the end of the SortedTroves paging result. The Rust bot uses this combined API with `include_last_zombie=true`. Because core holds only a single pointer, full coverage of multiple zombies remains in the operations plan as a follow-up task handled by events/indexer.

#### CORE-LIB-TBD-001: Bootstrap Values and Activation Finalization for Reserved Branches (Br2–7)
The dETH / dUSD-A / dBTC / dUSD-B / dJPY / dJGB constants are bootstrap values used to deploy an unbound reserved branch safely, not collateral-specific final approvals. Before activation, derive the six risk values and collateral compensation cap from the exact Underlying's stress, confirm compliance with the Japanese [Collateral Parameter Policy](../../../../jp/protocol/product/policies/Collateral-Parameter-Policy.md) §2.4, and finalize once through CORE-AR-FR-005. If the collateral does not qualify, leave the cap closed and the branch reserved. Changing values after finalization requires redeployment and migration.

---


---

## 15. References


- [Liquity v2 Bold GitHub](https://github.com/liquity/bold) — fork source (`base` = v1.11.0 frozen)
- [Liquity Docs](https://docs.liquity.org/) — upstream conceptual documentation
- [Liquity Friendly Forks Program](https://www.liquity.org/forks)
- Scalable Reward Distribution with Compounding Stakes (mathematical basis for Stability Pool P-S-B accounting; included in the liquity/dev repository)

### DeltaForesight Related Pages

- [Product Overview](../Product-Overview.md) — system requirements, architecture, ARCH, and SYS-INV (higher-level basis for the Core parity / delta boundary)
- [Architecture Decision Records](../architecture/Architecture-Decision-Records.md) — rationale for Core parity and related decisions
- [Parameters](../../../Parameters.md) — canonical source for branch-specific parameters and `Constants.sol` values
- [dToken Requirements Definition](dToken.md) — core collateral token (DTKN-*)
- [CollateralVault Requirements Definition](CollateralVault.md) — Underlying custody, mint/redeem, backing ratio (VAULT-*)
- [Strategy Requirements Definition](strategies/Strategy.md) / [AaveV3Strategy](strategies/AaveV3Strategy.md) — collateral operations (STGY-* / AAVE-*)
- [Oracle Requirements Definition](Oracle.md) — PriceFeedProxy, JPY-denominated synthesis, failsafe on failure (ORCL-*)
- [Zapper Requirements Definition](Zapper.md) — UX Router (ZAP-*)
- [Frontend Requirements Definition](Frontend.md) — 3 off-chain surfaces (FRNT-*)
