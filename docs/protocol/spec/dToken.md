# 🟢 dToken Requirements Specification

## 0. Metadata

| Item | Value |
| --- | --- |
| Status | Draft (implementation exists; requirements are being canonicalized) |
| Owner | DeltaForesight |
| Target contracts | `contracts/src/DToken.sol` (main implementation, UUPS) / `contracts/src/Interfaces/IDToken.sol` (specified interface `IDToken`) |
| Related documents | [Product-Overview](../Product-Overview.md) (architecture and responsibility separation) / [CollateralVault](CollateralVault.md) (mint/burn caller) / [Strategy](strategies/Strategy.md) (deployment destinations) / [Parameters](../../../Parameters.md) (values such as mintCap) |

> This document follows the [requirements specification standard](../../../README.md#requirements-spec-standard). Requirements, invariants, and security requirements are assigned persistent IDs (`DTKN-...`), and cross-references use those IDs.

---

## 1. Purpose, Scope, and Non-Responsibilities

dToken is a **collateral beneficiary-right token** issued and redeemed by CollateralVault (ERC-20, 18 decimals, UUPS). It represents a **1:1 claim** on Underlying (WETH / USDC, etc.) principal and is treated by the Liquity v2 core as an ordinary 18-decimal collateral ERC-20.

- **Specified by this document**: decimals and Underlying conversion / Underlying allowlist / collateral cap / `setTokenInfo` (deferred Underlying binding) / EIP-2612 Permit / mint and burn authorization / `initialize` (deferred initialization) / UUPS upgrades / 2-step Owner transfer / disabling Owner renounce.
- **Not specified by this document (non-responsibilities and other documents)**:
  - Underlying custody, **calling** dToken mint/burn, buffer accounting, allocation to Strategy, delayed redemption, and Vault-side deferred Underlying binding (`setUnderlying`) -> [CollateralVault](CollateralVault.md)
  - Strategy implementation, `IStrategy` / `BaseStrategy` -> [Strategy](strategies/Strategy.md)
  - Final collateral-specific parameter values such as mintCap -> [Parameters](../../../Parameters.md)
  - 🔵 Liquity core collateral, liquidation, and Redemption behavior, plus the debt-token `JpydfToken` core surface (`setBranchAddresses` / `setCollateralRegistry` / `sendToPool` / `returnFromPool` / `transferFrom` restrictions) -> [JpydfToken](JpydfToken.md) `CORE-BT-*`
- **Responsibility boundary (intentionally unaware)**: dToken provides quantity conversion, cap enforcement, and issuance/redemption authorization. Issuance checks that the corresponding branch has finalized its risk parameters; investment asset valuation remains outside dToken.

---

## 2. Background and Design Policy

dToken is designed consistently as a "collateral wrapper" that allows the **Liquity v2 core to be used unchanged**.

- **1:1 claim token**: dToken issues an ERC-20 representing a 1:1 claim on Underlying principal. The core treats it only as a collateral token and does not know about the real asset or management behind it.
- **Fixed `decimals = 18`**: Collateral tokens are standardized to 18 decimals to match Liquity assumptions and implementation constraints. Non-18-decimal Underlying is converted by dToken ([DTKN-FR-003](#dtkn-fr-003-underlying--dtoken-conversion)).
- **Underlying allowlist**: On mainnet, confusing canonical token addresses is an irreversible failure mode. Before `setTokenInfo`, the Owner must explicitly allowlist the intended token with `setAllowedUnderlying(token, true)`. `setTokenInfo` rejects tokens that are not allowlisted, EOAs, and undeployed addresses ([DTKN-FR-010](#dtkn-fr-010-underlying-allowlist-setallowedunderlying)).
- **No yield accrual**: dToken balances do not increase and value does not rise; it is strictly a "principal claim." Yield is aggregated to Treasury as protocol revenue. Upside (yield) does not accrue to dToken, while **if Strategy impairment creates an under-backed state, dToken may depeg downward against the Underlying**. Reflecting this downside risk in collateral prices is outside dToken's responsibility; it is handled by Vault `backingRatio()` ([CollateralVault](CollateralVault.md) `VAULT-FR-016`) and the oracle ([Oracle](Oracle.md) `ORCL-FR-014`). dToken itself has no price and only performs quantity conversion. Backing recovery is also not performed through dToken rebasing or supply updates; it is handled by Vault Strategy recovery, writeoff, `backstopDeposit` (protected reserve deposit), and `releaseBackstopToBuffer` (explicit liquidity release, [CollateralVault](CollateralVault.md) `VAULT-FR-017`).
- **Bind issuance and redemption to Vault accounting**: If dToken supply can change independently, claims diverge from custody balances and the system breaks. Therefore mint/burn authority is limited to the corresponding CollateralVault only ([DTKN-SEC-001](#dtkn-sec-001-limit-mintburn-to-the-vault)).
- **Deferred initialization (placeholder) policy**: At deployment, Underlying, name, and symbol are left undecided (placeholder), then fixed exactly once later via `setTokenInfo`. This allows placeholder collateral branches to be inertly deployed on Day 1 and activated later ([DTKN-FR-002](#dtkn-fr-002-deferred-underlying-binding-via-settokeninfo)).

> The canonical source for the overall no-core-modification policy and the background that dToken is core collateral is [Product-Overview](../Product-Overview.md) §5.

---

## 3. Terms, External Dependencies, and Assumptions

**Terms**

| Term | Meaning |
| --- | --- |
| Underlying | The real collateral asset wrapped by dToken (WETH / USDC, etc.) |
| vault | The corresponding CollateralVault that mints/burns this dToken |
| GOV_MULTISIG | Governance multisig. The **holder of the dToken Owner is the shared TimelockController (12h)**, and the GOV multisig proposes and executes Owner operations (`setCap` / `setTokenInfo` / upgrades, etc.) as the Timelock PROPOSER/EXECUTOR (the owner is not wired directly to the GOV multisig; [DTKN-GOV-004](#dtkn-gov-004-owner-timelock)) |
| placeholder phase / active phase | State before `setTokenInfo` (Underlying not fixed) / after it (fixed) |
| `_decimalMultiplier` | Conversion multiplier `10**(18 - underlyingDecimals)` |
| cap | dToken total supply upper bound (= effectively the collateral total amount upper bound) |

**External dependencies (trusted external components)**

- OpenZeppelin Contracts (upgradeable) **v4.9** — `ERC20Upgradeable` / `ERC20PermitUpgradeable` (`EIP712Upgradeable`) / `OwnableUpgradeable` / UUPS. This relies on the fact that OZ v4.9 `EIP712Upgradeable` does not cache `DOMAIN_SEPARATOR` ([DTKN-FR-007](#dtkn-fr-007-permit-eip-2612)).
- Corresponding CollateralVault — fully trusted as the only mint/burn caller ([DTKN-SEC-001](#dtkn-sec-001-limit-mintburn-to-the-vault)).

**Assumptions**

- The Liquity core treats collateral as 18-decimal ERC-20 tokens.
- `underlyingDecimals <= 18` (enforced by [DTKN-FR-002](#dtkn-fr-002-deferred-underlying-binding-via-settokeninfo)).

---

## 4. Actors, Roles, and Trust Boundaries

| Actor | Operations | Trust boundary |
| --- | --- | --- |
| **Owner (holder = shared TimelockController)** | `setAllowedUnderlying` / `setTokenInfo` / `setCap` / upgrade authorization / `transferOwnership` | Powerful authority (cap changes, Underlying allowlist, Underlying binding, logic replacement). **holder = shared TimelockController (12h) only** (GOV multisig is the Timelock PROPOSER/EXECUTOR; [DTKN-GOV-004](#dtkn-gov-004-owner-timelock)). Owner transfer is 2-step |
| **pendingOwner** | `acceptOwnership` | Transfer candidate specified by Owner. Owner authority does not move until acceptance |
| **vault (corresponding CollateralVault)** | `mint` / `burn` | Fully trusted. Can mint/burn without limit, and burn does not require holder allowance. Fixed immutably in `initialize` |
| **Anyone (permissionless)** | `convertTo*` (view) / `permit` (signature verification) | No trust required |

- **Authority separation**: Owner cannot `mint`/`burn`, and `vault` cannot `setCap`/`setTokenInfo`/upgrade.

---

## 5. Interface Specification

Specified interface `IDToken` (plus ERC-20 / ERC20Permit / UUPS standards). Behavior is defined in §6 Functional Requirements; only visibility is summarized below (non-normative).

| Function | Visibility | Summary | Requirement |
| --- | --- | --- | --- |
| `initialize(address vault, address owner)` | external (initializer) | Proxy initialization (placeholder launch) | DTKN-FR-001 |
| `setAllowedUnderlying(address underlying, bool allowed)` | external (onlyOwner) | Update the Underlying allowlist before `setTokenInfo` | DTKN-FR-010 |
| `setTokenInfo(string name, string symbol, address underlying)` | external (onlyOwner) | Fix Underlying, name, and symbol exactly once | DTKN-FR-002 |
| `convertToDToken(uint256) -> uint256` | external view | Underlying -> 18dec | DTKN-FR-003 |
| `convertToUnderlying(uint256) -> uint256` | external view | 18dec -> Underlying | DTKN-FR-003 |
| `mint(address to, uint256 amount)` | external (onlyVault) | Issue | DTKN-FR-004 |
| `burn(address from, uint256 amount)` | external (onlyVault) | Redeem/burn (allowance-independent) | DTKN-FR-005 |
| `setRiskParamsRegistry(address registry)` | external (onlyOwner) | Bind the branch issuance gate once | DTKN-FR-006 |
| `setCap(uint256 newCap)` | external (onlyOwner) | Update collateral cap | DTKN-FR-006 |
| `permit(...)` / `nonces(address)` | external | EIP-2612 | DTKN-FR-007 |
| `decimals() -> uint8` | public view | Always 18 | DTKN-INV-001 |
| `name()` / `symbol()` | public view | placeholder -> fixed value | DTKN-FR-002 |
| `eip712Domain()` | external view | ERC-5267 (reflects actual `name()`) | DTKN-FR-007 |
| `_authorizeUpgrade(address)` | internal (onlyOwner) | UUPS authorization | DTKN-FR-008 |
| `pendingOwner()` | public view | 2-step transfer candidate | DTKN-FR-009 |
| `transferOwnership(address)` | public (onlyOwner) | Start Owner transfer / cancel pending transfer | DTKN-FR-009 |
| `acceptOwnership()` | public | Owner acceptance by pendingOwner | DTKN-FR-009 |
| `renounceOwnership()` | public (onlyOwner) | Always reverts with `RenounceOwnershipDisabled` | DTKN-FR-009 |

---

## 6. Functional Requirements (FR)

### DTKN-FR-001: `initialize` (proxy initialization and placeholder launch)

- **Type**: Functional | **Source**: Product-Overview "dToken Layer" / placeholder branch operations
- **Signature**: `initialize(address vault, address owner)`
- **Purpose**: Initialize exactly once through the UUPS proxy. At deployment time, launch with Underlying, name, and symbol undecided (placeholder), then fix them later through DTKN-FR-002 `setTokenInfo` (deferred initialization flow for placeholder branches).
- **Authorization**: Part of the deployment procedure (proxy initialization). Binds `owner` (in production, holder = shared TimelockController [12h]; GOV multisig is the Timelock PROPOSER/EXECUTOR; [DTKN-GOV-004](#dtkn-gov-004-owner-timelock)).
- **Preconditions (Checks)**:
  - `vault` / `owner` are not the zero address (revert if either is zero)
  - Multiple initialization is not allowed (one time only; subsequent calls revert)
  - The logic contract (implementation) itself must be uninitializable; initialization is limited to the proxy path
- **Behavior (Effects)**:
  1. Bind `vault` (the corresponding CollateralVault that mints/burns this dToken. **Fixed at initialization and never changed**; no reset setter is provided)
  2. Set `owner` (authority for `setCap` / `setTokenInfo` / upgrade authorization. Production holder = shared TimelockController; [DTKN-GOV-004](#dtkn-gov-004-owner-timelock))
  3. Initialize `cap = 0` (issuance closed. DTKN-FR-006)
  4. Initialize with placeholder `name` / `symbol` (the fixed values are overwritten by `setTokenInfo`. The EIP-712 domain also follows the actual `name()` = DTKN-FR-007)
  5. Leave `underlying` unset (`address(0)`) (it can be fixed only by `setTokenInfo`. DTKN-FR-002)
- **Revert / early return**: zero `vault` / `owner` -> revert. Re-initialization -> revert.
- **Emitted event**: none (Underlying, name, and symbol binding is observed through DTKN-EVT-001 `TokenInfoSet`).
- **Design notes**: **`vault` immutability** — mint/burn is limited to `vault` only (DTKN-SEC-001). If `vault` could be changed later, the authority to issue and redeem collateral claims could be transferred wholesale, so `vault` is fixed at initialization. Vault-side feature changes are made through CollateralVault UUPS upgrades; dToken's `vault` reference is not changed.
- **Verification**: unit (re-initialization revert, zero-address revert, initial cap/placeholder values).

### DTKN-FR-002: Deferred Underlying binding via `setTokenInfo`

- **Type**: Functional | **Source**: Product-Overview "placeholder branches" / [CollateralVault](CollateralVault.md) deferred binding
- **Signature**: `setTokenInfo(string name, string symbol, address underlying)`
- **Purpose**: After deployment, the Owner fixes Underlying, name, and symbol **exactly once**, and also stores the conversion multiplier `_decimalMultiplier = 10**(18 - underlyingDecimals)`. No later changes are provided (only "launch undecided, then fix once later" is allowed).
- **Authorization**: dToken Owner only (holder = shared TimelockController).
- **Preconditions (Checks)** (all must hold):
  - `caller == Owner`
  - `underlying` is unset (`address(underlying) == address(0)`)
  - No tokens have been issued (`totalSupply() == 0`)
  - `underlying`/`name`/`symbol` are non-empty and non-zero
  - `underlying` is a deployed contract (EOA / undeployed address not allowed)
  - `allowedUnderlying[underlying] == true` ([DTKN-FR-010](#dtkn-fr-010-underlying-allowlist-setallowedunderlying))
  - `underlying.decimals() <= 18`
- **Behavior (Effects)**:
  1. Fix `underlying`/`name`/`symbol` (immutable thereafter)
  2. Read `underlying.decimals()` and calculate/store `_decimalMultiplier = 10**(18 - underlyingDecimals)` (conversion formulas are in DTKN-FR-003)
  3. Emit `TokenInfoSet`
- **Revert / early return**: non-Owner; repeated call after already set -> `TokenInfoAlreadySet`; `totalSupply() > 0` -> `SupplyAlreadyExists`; `underlying == address(0)` -> `ZeroAddress`; empty name -> `EmptyTokenName`; empty symbol -> `EmptyTokenSymbol`; EOA / undeployed address -> `NotContract`; not allowlisted -> `UnderlyingNotAllowed`; `decimals > 18` -> `InvalidUnderlyingDecimals`.
- **Emitted event**: `TokenInfoSet(name, symbol, underlying, underlyingDecimals)` (DTKN-EVT-001).
- **Design notes**: When combined with a placeholder Vault, the activation order is **allowlist -> dToken-first**. First pin the intended token with `setAllowedUnderlying(token, true)`, then call `setTokenInfo`, and then `CollateralVault.setUnderlying(token)` verifies `dToken.underlying() == token`. A mismatch is `UnderlyingMismatch` on the Vault side. During placeholder activation, keep cap at 0 until the real PriceFeed completes `confirmSourceEmergency()`, then release minting with `setCap` (DTKN-FR-006). Normal source replacement can use `confirmSource()` when the old/new price difference is within 1%, but replacing a placeholder sentinel with a real price exceeds that price-difference guard, so the emergency path is used.
- **Verification**: unit (one-shot behavior, each revert condition, multiplier calculation), invariant=DTKN-INV-003 / DTKN-INV-004.

### DTKN-FR-003: Underlying ↔ dToken conversion

- **Type**: Functional | **Source**: Product-Overview "18dec standardization"
- **Signature**: `convertToDToken(uint256 underlyingAmount) -> uint256` / `convertToUnderlying(uint256 dTokenAmount) -> uint256` (both external view)
- **Purpose**: dToken itself holds and exposes quantity conversion between non-18-decimal Underlying and 18-decimal dToken (called by Vault during deposit/redeem). These are the two views specified by `IDToken`.
- **Authorization**: none (external view).
- **Preconditions (Checks)**: `_decimalMultiplier != 0` (Underlying has been fixed).
- **Behavior (Effects)**:
  1. `convertToDToken`: `dTokenAmount = underlyingAmount * _decimalMultiplier` (**multiplication only, exact**. Overflow reverts under Solidity 0.8 checked arithmetic)
  2. `convertToUnderlying`: `underlyingAmount = dTokenAmount / _decimalMultiplier` (**integer division, floor**. Dust below the multiplier becomes 0)
- **Revert / early return**: not set (`_decimalMultiplier == 0`) -> `TokenInfoNotSet`.
- **Emitted event**: none (view).
- **Design notes**:
  - Rounding down happens only in the shrinking direction (`convertToUnderlying`) = a **safe-side** design that leaves dust in Vault/buffer and prevents user overpayment.
  - **Round-trip exactness**: dTokens from deposits are integer multiples of the multiplier, so same-amount redeem round-trips with dust 0. Balances not divisible by the multiplier (for example acquired by transfer) are floored by `convertToUnderlying` alone, but Vault `redeem` / `redeemWithPermit` require `convertToDToken(convertToUnderlying(amount)) == amount` before burn and reject zero-payment/dust burn ([CollateralVault](CollateralVault.md) `VAULT-FR-002` / `VAULT-FR-003`).
  - 18-decimal Underlying has multiplier 1 and is identity conversion. Example: 8-decimal WBTC multiplier 1e10 -> `convertToDToken(1e8)=1e18` / `convertToUnderlying(1e10-1)=0`. Usage locations: deposit -> `convertToDToken`; redeem/monetization -> `convertToUnderlying` ([CollateralVault](CollateralVault.md)).
- **Verification**: unit (boundary examples), fuzz=DTKN-INV-006 (round-trip dust 0).

### DTKN-FR-004: `mint` (issuance)

- **Type**: Functional | **Source**: Product-Overview "dToken Layer"
- **Signature**: `mint(address to, uint256 amount)`
- **Purpose**: Issue dToken corresponding to received Underlying. Restricted to the vault so that the total claim amount remains bound to Vault accounting.
- **Authorization**: **vault (corresponding CollateralVault) only**. Owner is also not allowed (authority separation).
- **Preconditions (Checks)**: `caller == vault`; Underlying has been fixed; `riskParamsRegistry` is bound and reports `riskParamsFinalized()==true`; `totalSupply() + amount <= cap`.
- **Behavior (Effects)**:
  1. Increase `to` balance by amount and `totalSupply` by amount
  2. Emit ERC20 `Transfer(address(0), to, amount)`
- **Revert / early return**: non-vault -> `OnlyVault`; not set -> `TokenInfoNotSet`; registry unbound or risk parameters unfinalized -> `DToken__RiskParamsNotFinalized`; `totalSupply()+amount > cap` -> `CapExceeded`.
- **Emitted event**: ERC20 `Transfer` (mint, from=0).
- **Design notes**: Minting before token info is set is prohibited to prevent `totalSupply()>0` from permanently blocking `setTokenInfo` and stranding the placeholder (DTKN-SEC-004).
- **Verification**: unit (vault-only, cap exceeded, `TokenInfoNotSet`), invariant=DTKN-INV-002 / DTKN-INV-005.

### DTKN-FR-005: `burn` (redemption/burn, allowance-independent)

- **Type**: Functional | **Source**: Product-Overview "dToken Layer" / [CollateralVault](CollateralVault.md) redemption flow
- **Signature**: `burn(address from, uint256 amount)`
- **Purpose**: Burn a holder's dToken during the redemption flow. The strong authority that **does not require allowance** is confined to the vault only.
- **Authorization**: **vault only**. Owner is also not allowed.
- **Preconditions (Checks)**: `caller == vault`; `from` balance >= amount.
- **Behavior (Effects)**:
  1. Decrease `from` balance by amount and `totalSupply` by amount
  2. Emit ERC20 `Transfer(from, address(0), amount)`
- **Revert / early return**: non-vault -> `OnlyVault`; insufficient balance -> ERC20 revert.
- **Emitted event**: ERC20 `Transfer` (burn, to=0).
- **Design notes**: Allowance is not required because Vault directly burns the holder's dToken during the redemption flow. Restricting this to the vault confines the allowance-independent burn authority to the vault only (trust boundary = DTKN-SEC-002).
- **Verification**: unit (vault-only, allowance-independent, insufficient balance revert), invariant=DTKN-INV-002.

### DTKN-FR-006: Collateral cap update via `setCap`

- **Type**: Functional | **Source**: Product-Overview "collateral cap" / [Parameters](../../../Parameters.md) mintCap
- **Signature**: `setCap(uint256 newCap)`
- **Purpose**: Update the dToken total supply upper bound (= effectively the total collateral amount upper bound). The collateral cap is held and enforced by dToken itself.
- **Authorization**: dToken Owner only (holder = shared TimelockController).
- **Preconditions (Checks)**: `caller == Owner`.
- **Behavior (Effects)**:
  1. `cap = newCap` (**may be set below current `totalSupply()`** = only new minting stops; existing issuance remains)
  2. Emit `CapUpdated(oldCap, newCap)`
- **Revert / early return**: non-Owner -> revert.
- **Emitted event**: `CapUpdated(oldCap, newCap)` (DTKN-EVT-002).
- **Design notes**: Default cap is `0` (closed). Enforcement is on the mint side (DTKN-FR-004).
- **Verification**: unit (Owner-only, `newCap < totalSupply` allowed, existing issuance preserved), invariant=DTKN-INV-005.

The Owner binds the corresponding `AddressesRegistry` exactly once with `setRiskParamsRegistry(address)`, while both cap and total supply are zero. The target must have code and return this token from `collToken()`. Binding emits `RiskParamsRegistryBound(registry)`. A positive cap and every mint require a bound registry with finalized risk parameters; otherwise they revert with `DToken__RiskParamsNotFinalized`. Closing the cap to zero and burning remain available. This preserves the zero supply needed to finalize a reserved branch. Upgrading a token with existing supply requires a separate migration design: this binding cannot preserve nonzero legacy supply.

### DTKN-FR-007: `permit` (EIP-2612)

- **Type**: Functional | **Source**: [CollateralVault](CollateralVault.md) `redeemWithPermit` / [Zapper](Zapper.md) permit path
- **Signature**: `permit(address owner, address spender, uint256 value, uint256 deadline, uint8 v, bytes32 r, bytes32 s)` / `nonces(address owner)`
- **Purpose**: Issue allowance with a single signature and no prior approve. `DOMAIN_SEPARATOR` **follows** the actual `name()` after `setTokenInfo` is fixed (it is not pinned to the placeholder name). Inherits OZ `ERC20PermitUpgradeable`. ERC-5267 `eip712Domain()` also reports current `name()` and version `"1"`.
- **Authorization**: none (permissionless; signature verification only).
- **Preconditions (Checks)**: valid signature (owner/spender/value/deadline/v/r/s).
- **Behavior (Effects)**:
  1. `allowance(owner, spender) = value`, `nonces(owner)` +1
  2. Override `_EIP712Name()` to return `name()` -> the name hash for `DOMAIN_SEPARATOR()` is derived from the actual token name (`DOMAIN_SEPARATOR() = keccak256(abi.encode(typehash, keccak256(name()), keccak256("1"), chainId, address(this)))`)
- **Revert / early return**: signature mismatch / expired deadline / nonce mismatch -> revert.
- **Emitted event**: ERC20 `Approval`.
- **Design notes**:
  - **No additional storage, gap changes, or re-initialization are required**: OZ v4.9 `EIP712Upgradeable` does not cache `DOMAIN_SEPARATOR` for proxies, and `_domainSeparatorV4()` derives it each time from `_EIP712NameHash()=keccak256(_EIP712Name())`. `_EIP712Name()` is `virtual`.
  - **Name is fixed before signing**: because `setTokenInfo` is one-shot and requires `totalSupply()==0` (DTKN-FR-002), the name is fixed before holders sign permits.
  - **Alternative comparison**: fixing the placeholder name would make signatures derived from `name()` disagree with the on-chain domain and cause `permit()` to revert (UX breakage, no fund impact). Fixing the name in `initialize` breaks the deferred initialization flow. This approach is minimal and uses the official OZ override hook (precedent: Circle USDC).
- **Verification**: unit (`DOMAIN_SEPARATOR()` after binding reflects `name()`), integration (signature constructed by a standard wallet from `name()` verifies with `permit()`).

### DTKN-FR-008: Upgrades (UUPS)

- **Type**: Functional | **Source**: Product-Overview "dToken Layer (UUPS)"
- **Signature**: `_authorizeUpgrade(address newImpl)` (internal, UUPS authorization)
- **Purpose**: Allow future changes to claim, conversion, cap, and related behavior through UUPS logic replacement.
- **Authorization**: new implementation approval is **Owner (holder = shared TimelockController) only**. Operational roles (Vault / Strategy, etc.) are not allowed.
- **Preconditions (Checks)**: `caller == Owner`.
- **Behavior (Effects)**:
  1. Replace implementation address (UUPS). Storage is append-only (no reordering or type changes for existing slots; gap reserves future slots)
  2. Emit ERC1967 `Upgraded(newImpl)`
- **Revert / early return**: non-Owner -> revert.
- **Emitted event**: ERC1967 `Upgraded(newImpl)`.
- **Design notes**: dToken has no built-in timelock. By setting Owner to the shared TimelockController (minDelay 12h), all Owner operations receive a 12h public delay (finalized 2026-06-12; [DTKN-GOV-004](#dtkn-gov-004-owner-timelock)). Oracle PriceFeedProxy separately has a built-in 12h timelock for feed source replacement.
- **Verification**: unit (Owner-only authorization, operational roles revert), manual (storage layout review, gap reserved).

### DTKN-FR-009: Owner transfer (2-step) and disabled renounce

- **Type**: Functional / Security | **Source**: mainnet authority operations; alignment with Oracle `Ownable2Step` policy
- **Signature**: `pendingOwner() -> address` / `transferOwnership(address newOwner)` / `acceptOwnership()` / `renounceOwnership()`
- **Purpose**: The dToken Owner controls powerful authority over `setTokenInfo` / `setCap` / UUPS upgrades, so operations must not become permanently impossible due to one-step transfer to a wrong address or Owner renounce. Owner transfer requires explicit acceptance by the candidate, and Owner renounce reverts in code.
- **Authorization**:
  - `transferOwnership`: current Owner only
  - `acceptOwnership`: `pendingOwner` only
  - `renounceOwnership`: callable only by current Owner but always reverts
- **Preconditions (Checks)**:
  - `transferOwnership`: `caller == owner`
  - `acceptOwnership`: `caller == pendingOwner`
  - `renounceOwnership`: `caller == owner`
- **Behavior (Effects)**:
  1. `transferOwnership(newOwner)` stores `_pendingOwner = newOwner` and emits `OwnershipTransferStarted(owner, newOwner)`. `newOwner == address(0)` is treated as cancellation of the pending transfer
  2. `acceptOwnership()` transfers `owner = pendingOwner` and clears `pendingOwner` (emits OZ `OwnershipTransferred`)
  3. `renounceOwnership()` reverts with `RenounceOwnershipDisabled` and keeps Owner unchanged
- **Revert / early return**: non-Owner `transferOwnership` / `renounceOwnership` revert under OZ Ownable. Non-`pendingOwner` `acceptOwnership` reverts with `Ownable2Step: caller is not the new owner`.
- **Emitted event**: `OwnershipTransferStarted(previousOwner, newOwner)` / OZ `OwnershipTransferred(previousOwner, newOwner)`.
- **Design notes**: `_pendingOwner` consumes one slot from dToken's own storage gap. It does not change the existing `OwnableUpgradeable` inheritance order or move existing storage slots.
- **Verification**: unit (2-step transfer, pending cancel, non-pending accept revert, renounce disabled, `setCap` by new Owner).

### DTKN-FR-010: Underlying allowlist (`setAllowedUnderlying`)

- **Type**: Functional / Security | **Source**: mainnet deployment procedure; prevention of canonical token misconfiguration
- **Signature**: `setAllowedUnderlying(address underlying, bool allowed)`
- **Purpose**: Before `setTokenInfo`, the Owner explicitly declares which Underlying contract this dToken may bind to. This prevents accidentally passing the wrong address to the one-shot setter for assets that may have multiple same-name or similar-symbol contracts, proxy tokens, or bridged tokens such as USDC.
- **Authorization**: dToken Owner only (holder = shared TimelockController).
- **Preconditions (Checks)**:
  - `caller == Owner`
  - `underlying != address(0)`
  - `underlying.code.length > 0` (EOA / undeployed address not allowed)
  - `setTokenInfo` has not been executed (`address(underlying()) == address(0)`)
- **Behavior (Effects)**:
  1. Store `allowedUnderlying[underlying] = allowed`
  2. Emit `AllowedUnderlyingUpdated(underlying, allowed)`
- **Revert / early return**: non-Owner; zero address -> `ZeroAddress`; EOA / undeployed address -> `NotContract`; after token info is fixed -> `TokenInfoAlreadySet`.
- **Emitted event**: `AllowedUnderlyingUpdated(underlying, allowed)` (DTKN-EVT-005).
- **Design notes**:
  - The allowlist is a deployment safety rail before binding and is not a token replacement mechanism after activation. It cannot be updated after `setTokenInfo`.
  - In the mainnet procedure, only the canonical mainnet USDC contract is allowlisted for USDC. USDC is blacklistable; transfer reverts caused by blacklist status are handled as reverts of the individual Vault redeem / claim transaction (no batch push). See [CollateralVault](CollateralVault.md).
  - `allowed=false` is used to revoke an accidental allowlist entry. It can be reset before `setTokenInfo` succeeds.
- **Verification**: unit (zero, EOA, non-Owner, no update after bind, event, allow/remove, unapproved `setTokenInfo` revert).

---

## 7. State Variables and Accounting Model

| Variable | Type | Description | Fixed by |
| --- | --- | --- | --- |
| `vault` | `address` | Corresponding CollateralVault that performs mint/burn | Fixed and immutable in `initialize` |
| `underlying` | `address` | Wrapped target. Unset is `address(0)` | Once via `setTokenInfo` |
| `_decimalMultiplier` | `uint256` | `10**(18 - underlyingDecimals)`. `0` while unset | Once via `setTokenInfo` |
| `riskParamsRegistry` | `address` | Branch registry controlling mint readiness | Set once via `setRiskParamsRegistry` |
| `cap` | `uint256` | Total supply upper bound. Default `0` | `initialize` default / `setCap` updates |
| `allowedUnderlying` | `mapping(address => bool)` | Intended Underlying values that can be bound before `setTokenInfo` | `setAllowedUnderlying` (cannot update after `setTokenInfo`) |
| `name` / `symbol` | `string` | placeholder -> fixed | `setTokenInfo` |
| `_pendingOwner` | `address` | 2-step Owner transfer candidate | `transferOwnership` / `acceptOwnership` |
| `nonces` | `mapping` | EIP-2612 nonce | - |

**Accounting model**: dToken is a **1:1 claim** and has no yield (balance and value do not increase). All value accounting (buffer/principal/profit/dust) belongs to the Vault side; dToken only controls supply (`totalSupply`) and conversion (`_decimalMultiplier`). The quantity relationship to Underlying is always "`totalSupply` = issued dToken amount; corresponding Underlying = `convertToUnderlying(totalSupply)` (floor, safe side)." However, Vault `actualLiabilities()` conservatively rounds up to 1 Underlying base unit when total-supply dust exists due to legacy/migration. This conversion is **nominal principal** (face value of the 1:1 claim). If actual holdings fall below it (Strategy impairment), the **actual backing ratio** is calculated by the Vault as `backingRatio()` ([CollateralVault](CollateralVault.md) `VAULT-FR-016`) and reflected in collateral prices by the oracle ([Oracle](Oracle.md) `ORCL-FR-014`). dToken itself only performs nominal conversion and has no backing-ratio accounting, price reflection, or replenishment deposit logic.

---

## 8. Invariants (INV)

| ID | Invariant | Verification |
| --- | --- | --- |
| DTKN-INV-001 | `decimals()` is always 18 before and after Underlying binding | unit |
| DTKN-INV-002 | Only `vault` can execute `mint`/`burn` (Owner cannot) | invariant |
| DTKN-INV-003 | `setTokenInfo` succeeds only when `totalSupply()==0`; after binding, `underlying`/`name`/`symbol`/`_decimalMultiplier` are immutable | invariant |
| DTKN-INV-004 | After binding, `_decimalMultiplier` is `10**(18 - underlyingDecimals)`; before binding it is `0` | unit |
| DTKN-INV-005 | `mint` succeeds only when `totalSupply()+amount <= cap` (excess is `CapExceeded`). Because `setCap` can lower cap below current `totalSupply()`, `totalSupply() <= cap` is **not a global invariant** ([DTKN-FR-006](#dtkn-fr-006-collateral-cap-update-via-setcap)) | invariant |
| DTKN-INV-006 | Conversion consistency: `convertToDToken` is exact multiplication and `convertToUnderlying` floors (safe side). Round trip for dToken amounts divisible by the multiplier has dust 0 | fuzz |
| DTKN-INV-007 | `vault` is immutable after `initialize` | invariant |
| DTKN-INV-008 | While Underlying is unset (`_decimalMultiplier==0`), `convertTo*`/`mint` revert with `TokenInfoNotSet` | unit |
| DTKN-INV-009 | Owner changes only when `acceptOwnership` succeeds and does not change through `renounceOwnership` | unit |
| DTKN-INV-010 | `setTokenInfo` succeeds only when `allowedUnderlying[underlying] == true` and `underlying.code.length > 0`; allowlist updates are impossible after `setTokenInfo` | unit |

---

## 9. Security Requirements (SEC)

### DTKN-SEC-001: Limit mint/burn to the vault

- Type: Security
- Statement: `mint`/`burn` must be callable only by `vault`; all other addresses, including Owner, must revert with `OnlyVault` (least privilege; prevents divergence between total claim amount and custody balance).
- Verification: unit (non-vault revert), invariant=DTKN-INV-002

### DTKN-SEC-002: Confinement of allowance-independent burn

- Type: Security
- Statement: The strong authority of `burn` that does not require holder allowance must be confined to the vault only through the vault-only restriction (DTKN-SEC-001).
- Verification: unit (arbitrary addresses cannot burn others' balances), manual

### DTKN-SEC-003: `permit` DOMAIN_SEPARATOR follows the actual name

- Type: Security
- Statement: `DOMAIN_SEPARATOR` must follow the actual `name()` and must not cause signature mismatches from being pinned to the placeholder name (permanent `permit()` revert).
- Verification: unit (same as [DTKN-FR-007](#dtkn-fr-007-permit-eip-2612)), integration

### DTKN-SEC-004: Prevent stranded placeholders

- Type: Security
- Statement: `mint` while Underlying is unset must be prohibited, preventing `setTokenInfo` from becoming permanently impossible due to `totalSupply()>0` (stranded placeholder).
- Verification: unit (unset mint revert), invariant=DTKN-INV-008

### DTKN-SEC-005: Limit upgrade authority

- Type: Security
- Statement: New implementation approval must be limited to Owner (holder = shared TimelockController); operational roles (vault, etc.) must not be able to upgrade.
- Verification: unit (non-Owner authorization revert), manual (storage layout review)

### DTKN-SEC-006: Prevent loss of Owner authority

- Type: Security
- Statement: Owner transfer must be 2-step so that `setCap` / `setTokenInfo` / upgrade authority cannot be lost through one-step transfer to a wrong address. `renounceOwnership` must always revert to prevent placeholder activation, cap updates, or upgrades from becoming impossible due to Owner renounce.
- Verification: unit (2-step transfer, renounce disabled)

### DTKN-SEC-007: Prevent incorrect Underlying binding

- Type: Security
- Statement: `setTokenInfo` must accept only a deployed contract that the Owner has pre-allowlisted as the Underlying, and must reject incorrect canonical token addresses, EOAs, and undeployed addresses.
- Verification: unit (DTKN-FR-010 / DTKN-INV-010)

> **Reentrancy**: dToken itself has no external call that transfers value (`mint`/`burn` are internal accounting, `convert` is view, and `permit` verifies signatures). CEI/ReentrancyGuard is the responsibility of consumers ([CollateralVault](CollateralVault.md) / [Zapper](Zapper.md)); dToken does not introduce a reentrancy surface.

---

## 10. Governance, Operations, and Upgrade Requirements (GOV)

### DTKN-GOV-001: Owner holder is the shared TimelockController

- Statement (revised 2026-06-12): The **holder** of Owner (the authority for `setCap`/`setTokenInfo`/upgrade authorization) must be only the shared TimelockController (minDelay 12h). The GOV multisig acts as the Timelock PROPOSER/EXECUTOR. Owner must not be wired directly to the GOV multisig; a single EOA is prohibited ([DTKN-GOV-004](#dtkn-gov-004-owner-timelock)).
- Verification: manual (deployment configuration review)

### DTKN-GOV-002: Owner transfer (2-step)

- Statement: Owner transfer is performed as 2-step (`transferOwnership` -> `acceptOwnership`). If a wrong address is specified, pending transfer can be cancelled with `transferOwnership(address(0))`.
- Verification: unit, manual

### DTKN-GOV-003: Owner renounce handling

- Statement: Owner renounce would permanently disable `setCap`/`setTokenInfo`/upgrades and is incompatible with deferred placeholder Underlying binding, so it is disabled in code with `RenounceOwnershipDisabled`.
- Verification: unit

### DTKN-GOV-004: Owner timelock

- Statement (finalized 2026-06-12): dToken does not have a built-in timelock. Instead, **Owner is set to the shared TimelockController (minDelay = 12h, PROPOSER/EXECUTOR = GOV multisig, CANCELLER = the same Admin multisig as PROPOSER / EXECUTOR [updated 2026-06-29; Day-1 adopts the OZ `TimelockController` default in which the proposer is also granted `CANCELLER_ROLE`])** (shared with Vault `GOV_ROLE` / Strategy `upgrader`; zero code changes on the dToken side, only Owner wiring). `setCap` / `setTokenInfo` / `setAllowedUnderlying` / UUPS upgrade all have a 12h delay. **`setCap` is a durable exposure limit (risk parameter), not an emergency lever**. In an acute depeg or similar event, immediate suspension of new minting is handled by Vault-side `pauseDeposit` (GUARDIAN, immediate, [CollateralVault requirements](CollateralVault.md) VAULT-FR-014). dToken has no immediate emergency operation; Owner timelock and pause authority are operated separately. Canonical source of this design decision: [../policies/Governance-Roles-Timelock.md](../policies/Governance-Roles-Timelock.md).
- Verification: manual (deployment configuration review and Owner = Timelock assert)

### DTKN-GOV-005: Deployment review for Underlying allowlist

- Statement: `setAllowedUnderlying` is treated as a critical operation directly connected to one-shot binding, just like `setTokenInfo`; before GOV multisig (Timelock PROPOSER/EXECUTOR) signing, chainId, contract address, decimals, token implementation / proxy, and presence of blacklist / pause authority must be reviewed.
- Verification: manual (mainnet deployment checklist)

---

## 11. Events and Monitoring Requirements (EVT)

| ID | Event | Purpose (off-chain) |
| --- | --- | --- |
| DTKN-EVT-001 | `TokenInfoSet(name, symbol, underlying, underlyingDecimals)` | Detect Underlying binding (placeholder -> active). Exactly once |
| DTKN-EVT-002 | `CapUpdated(oldCap, newCap)` | Monitor collateral cap changes |
| DTKN-EVT-003 | ERC20 `Transfer` (mint: from=0 / burn: to=0) | Track supply, issuance, and redemption/burn |
| DTKN-EVT-004 | `OwnershipTransferStarted(previousOwner, newOwner)` / OZ `OwnershipTransferred` | Start and finalization of Owner transfer |
| DTKN-EVT-005 | `AllowedUnderlyingUpdated(underlying, allowed)` | Add/revoke Underlying allowlist entries. Deployment safety operation before `TokenInfoSet` |

- No dedicated initialization event is provided (binding is observed through DTKN-EVT-001).

---

## 12. Failure and Exception Behavior (ERR)

**Placeholder phase (Underlying unset) behavior**

| Function | Placeholder phase | Active phase |
| --- | --- | --- |
| `name()` / `symbol()` | placeholder values | fixed values |
| `decimals()` | 18 (DTKN-INV-001) | 18 |
| `convertTo*` | `TokenInfoNotSet` revert | converted value |
| `mint` | `TokenInfoNotSet` revert | executable (vault only) |

**Error catalog**

| Error | Trigger |
| --- | --- |
| `OnlyVault` | mint/burn by non-vault (DTKN-SEC-001) |
| `ZeroAddress` | zero address specified in `initialize` / `setTokenInfo` / `setAllowedUnderlying` |
| `TokenInfoNotSet` | convert/mint before binding (DTKN-INV-008) |
| `CapExceeded` | mint with `totalSupply()+amount > cap` (DTKN-FR-004) |
| `InvalidUnderlyingDecimals` | `decimals > 18` in `setTokenInfo` (DTKN-FR-002) |
| `NotContract` | EOA or undeployed address specified in `setAllowedUnderlying` / `setTokenInfo` |
| `UnderlyingNotAllowed` | `setTokenInfo` specifies an Underlying not approved by the allowlist |
| `TokenInfoAlreadySet` | repeated `setTokenInfo`, or `setAllowedUnderlying` after token info is fixed |
| `EmptyTokenName` / `EmptyTokenSymbol` | empty name / symbol specified in `setTokenInfo` |
| `SupplyAlreadyExists` | `setTokenInfo` called after `totalSupply() > 0` |
| `UnderlyingMismatch` (Vault side) | `CollateralVault.setUnderlying` does not match `dToken.underlying()` (including dToken-first violation) |
| `RenounceOwnershipDisabled` | `renounceOwnership` call (DTKN-FR-009 / DTKN-SEC-006) |

---

## 13. Acceptance Criteria and Verification Plan

Pass condition for each requirement = the verification method in the table is satisfied (test names and execution results are not written in this document; only the type of method is specified).

| ID | Requirement (summary) | Verification method |
| --- | --- | --- |
| DTKN-FR-001 | initialize (placeholder launch, fixed vault/owner) | unit |
| DTKN-FR-002 | setTokenInfo (one-shot, multiplier binding, each revert) | unit, invariant=DTKN-INV-003/004 |
| DTKN-FR-003 | conversion (exact multiplication, floor safe side, boundaries) | unit, fuzz=DTKN-INV-006 |
| DTKN-FR-004 | mint (vault-only, cap/unset guard) | unit, invariant=DTKN-INV-002/005 |
| DTKN-FR-005 | burn (vault-only, allowance-independent) | unit, invariant=DTKN-INV-002 |
| DTKN-FR-006 | setCap (Owner-only, current supply may exceed new cap) | unit, invariant=DTKN-INV-005 |
| DTKN-FR-007 | permit (`DOMAIN_SEPARATOR` follows `name()`) | unit, integration |
| DTKN-FR-008 | upgrade (Owner-only, storage append-only) | unit, manual |
| DTKN-FR-009 | Owner transfer (2-step) and disabled renounce | unit, manual |
| DTKN-FR-010 | Underlying allowlist (contract-only, before binding only, event) | unit, manual |
| DTKN-INV-001..010 | Each invariant in §8 | unit / invariant / fuzz (as specified in §8) |
| DTKN-SEC-001..007 | Each security requirement in §9 | unit, manual |

---

## 14. Open Items (TBD)

### DTKN-TBD-001

Resolved: reflected in `DTKN-FR-008` and `DTKN-GOV-004`.

### DTKN-TBD-002

Resolved: reflected in `DTKN-FR-009` and `DTKN-GOV-002`.

### DTKN-TBD-003

Resolved: reflected in `DTKN-FR-009` and `DTKN-GOV-003`.

---

## 15. References

- [Product Overview](../Product-Overview.md) — overall architecture, responsibility separation, and no-core-modification policy (§5)
- [CollateralVault Requirements Specification](CollateralVault.md) — Underlying custody / Mint and Redeem / buffer accounting / delayed redemption / deferred binding
- [Strategy Requirements Specification](strategies/Strategy.md) — `IStrategy` / push model / integration with deployment destinations
- [Oracle Requirements Specification](Oracle.md) — PriceFeedProxy (comparison target for timelock)
- [Parameters.md](../../../Parameters.md) — collateral-specific finalized values for mintCap / buffer / allocator parameters
- [Requirements Specification Standard](../../../README.md#requirements-spec-standard) — the standard this document follows
