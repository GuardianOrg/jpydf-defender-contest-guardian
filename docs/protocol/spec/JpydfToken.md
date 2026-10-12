# 🔵/🟡 JpydfToken Requirements Specification

## 0. Metadata

| Item | Value |
| --- | --- |
| Status | Draft (implementation exists; requirements are being canonicalized. `CORE-BT-*` is split out of the Core Spec and consolidated here) |
| Owner | DeltaForesight |
| Classification | 🔵/🟡 (a singleton that inherits the Liquity v2 Core debt token at base parity and records the DF diffs as a ledger. Diffs = CORE-MOD-001 naming / CORE-MOD-008 bridge-ready dormant extension / CORE-MOD-009 registration hardening) |
| Target contracts | `contracts/src/JpydfToken.sol` / `contracts/src/Interfaces/IJpydfToken.sol`. 🔵 upstream-derived bases = OpenZeppelin v4.9.5 `ERC20` / `ERC20Permit` (EIP-2612 / ERC-5267), Liquity-version `Ownable`. Wiring = `contracts/script/DeployLiquity2.s.sol` |
| Related documents | [Product-Overview](../Product-Overview.md) (SYS-FR-006 / SYS-CON-004 / SYS-INV-003) / [Architecture Decision Records](../architecture/Architecture-Decision-Records.md#adr-004) / [Liquity-v2-Core-Spec](Liquity-v2-Core-Spec.md) (Core `mint`/`burn` callers BO/AP/TM/SP/CR, §2.2 CORE-MOD ledger) / [Parameters](../../../Parameters.md) (security parameters such as `PRM-BRIDGE-MINTER-TIMELOCK`) / [Bridge-Minter-Activation-Gate](../../operations/runbooks/Bridge-Minter-Activation-Gate.md) (Day-2 pre-registration gate for bridge minters) / [dToken](dToken.md) (collateral token) |

> This document follows the [requirements specification standard](../../../README.md#requirements-spec-standard). Requirements, invariants, and security requirements are assigned persistent IDs (`CORE-BT-...`), and cross-references use those IDs. Even after moving from the Core Spec to this document, the **`CORE-BT-*` namespace is preserved**, and existing ID references (ledger, traces, reviews) still resolve unchanged.

## 1. Purpose, Scope, and Non-Responsibilities

`JpydfToken` is the body of the yen-denominated stablecoin JPYdf (ERC-20 + EIP-2612), deployed exactly once for the entire system (shared across all branches). It inherits Liquity v2's `BoldToken` at base parity and has a supply path linked only to the Core debt accounting (borrowing, interest issuance, repayment, redemption, liquidation offset).

- **Specified by this document**: the Core supply path (`mint` / `burn`) and authorization boundary, SP internal transfers (`sendToPool` / `returnFromPool`), recipient-restricted ERC-20 transfers, EIP-2612 permit, deployment wiring and the permanent fixing of Core authority via owner renounce, and the DF-specific bridge-ready dormant surface (`bridgeAdmin` / bridge minter registry / `bridgeMint` / self-burn `bridgeBurn`).
- **Non-responsibilities**: branch logic, collateral accounting, price acquisition, redemption routing (the responsibilities of the respective Core contracts / [dToken](dToken.md) / [Oracle](Oracle.md) / CollateralRegistry). The bridge adapter body, other-chain tokens, rate limits, and message verification are not implemented within the token; they are confirmed fail-closed from Day 2 onward through [Bridge-Minter-Activation-Gate](../../operations/runbooks/Bridge-Minter-Activation-Gate.md) and adapter audits.
- **Day-1 scope**: Ethereum mainnet, single chain. Launch in a dormant state with 0 bridge minters and no pending proposals (CORE-BT-INV-003).

## 2. Background and Design Policy (separating the Core supply path from the bridge-ready surface)

The stablecoin body, deployed exactly once for the entire system (shared across all branches). It inherits OZ v4.9.5 `ERC20` / `ERC20Permit` (EIP-2612 / ERC-5267) and Liquity-version `Ownable`. Existing Core issuance (`mint`) is limited to registered BorrowerOperations / ActivePool, and existing Core burning (`burn`) is limited to CollateralRegistry and registered BorrowerOperations / TroveManager / StabilityPool; this binds the Core supply path only to the protocol's debt accounting (borrowing, interest issuance, repayment, redemption, liquidation offset). Branch contracts are registered by the Owner via `setBranchAddresses`, and at the moment `setCollateralRegistry` is finally called, ownership is renounced and the Core authority configuration becomes permanently fixed (registering additional branches is impossible thereafter).

In addition, to avoid losing bridge capability after a Day-1 token freeze, DF holds a bridge-ready dormant surface (CORE-MOD-008). Bridge governance is held by `bridgeAdmin`, which continues to exist independently even after Owner renounce. `bridgeAdmin` / bridge minters are limited to contract addresses only, and serving as both admin and minter is not permitted. Adding a bridge minter has a 48h timelock; removal is immediate. The bridge supply path is limited to the separately named `bridgeMint` / self-burn-type `bridgeBurn`, and bridge minters are not OR-added to the authorization conditions of the existing Core `mint` / `burn`. Day-1 launch requires the dormant state `bridgeMinterCount == 0` / `proposedBridgeMinter == address(0)`. Minter registration from Day 2 onward is not a token-local decision; it is performed only after the adapter-side per-chain cap / hourly and daily rate limits / global bridged supply cap / remote supply accounting / pause and incident runbook are satisfied through [Bridge-Minter-Activation-Gate](../../operations/runbooks/Bridge-Minter-Activation-Gate.md). It is a non-upgradeable contract that does not go through a proxy, and the DF diffs are the token name and symbol (CORE-MOD-001) and the bridge-ready dormant extension (CORE-MOD-008).

DF diffs are managed append-only in the Core diff ledger ([Liquity-v2-Core-Spec](Liquity-v2-Core-Spec.md) §2.2): debt-token naming = `CORE-MOD-001`, bridge-ready dormant extension = `CORE-MOD-008`, core address registration hardening = `CORE-MOD-009`. The 🟡 requirements in this document reference these, and the ledger and this document are linked to each other with pointers.

## 3. Terms, External Dependencies, and Assumptions

- **Core supply path**: existing `mint` / `burn`. Only registered BorrowerOperations / ActivePool (mint) and CollateralRegistry / registered BorrowerOperations / TroveManager / StabilityPool (burn) may call them.
- **Bridge supply path**: `bridgeMint` / self-burn `bridgeBurn`. A separate path callable only by registered bridge minters. On Day 1 it is dormant with 0 minters.
- **External dependencies**: OpenZeppelin `ERC20` / `ERC20Permit` (EIP-2612 / ERC-5267), Liquity-version `Ownable` (a disposable owner pattern that has no `transferOwnership` and only an internal `_renounceOwnership`).
- **Assumptions**: non-upgradeable (no proxy). The Core authority configuration is permanently fixed by the owner renounce in `setCollateralRegistry`, and later addition or replacement of branches is impossible.

## 4. Actors, Roles, and Trust Boundaries

| Actor | Operations | Trust boundary |
| --- | --- | --- |
| **Owner (deployment wirer)** | Wires Core authority exactly once via `setBranchAddresses` / `setCollateralRegistry`, then renounces | Disposable. After renounce, `onlyOwner` functions are permanently uncallable |
| **Core callers (BO / AP / TM / SP / CR)** | Only registered addresses call `mint` / `burn` / `sendToPool` / `returnFromPool` | Trusted (registration is fixed at owner wiring time) |
| **bridgeAdmin** | Manages the bridge minter registry and admin handover (a role independent of Owner) | Trusted (contract-only; on mainnet a Safe / Timelock holder. On Day 1 a dormant holder) |
| **bridge minter** | A registered adapter that executes `bridgeMint` / self-burn `bridgeBurn` | Absent on Day 1. Fully trusted from Day 2 onward (contract-only; serving as both this and `bridgeAdmin` is prohibited). Before registration, per-chain cap / rate limit / global bridged supply cap / remote accounting / pause are enforced on the adapter side |
| **General holder / general caller** | ERC-20 transfer / permit | Adversarial by assumption. Transfers addressed to protocol contracts revert |

## 5. Interface Specification

**Interface list (non-normative; behavior is normatively defined in §6)**

| Function | Visibility / Authorization | Summary | Requirement |
| --- | --- | --- | --- |
| `constructor(address,address)` | deploy | Set Owner and bridgeAdmin | CORE-BT-FR-001 / CORE-BT-FR-013 |
| `setBranchAddresses(address,address,address,address)` | external (onlyOwner) | Register a branch's TM/SP/BO/AP into the Core mint/burn authorization sets | CORE-BT-FR-002 |
| `setCollateralRegistry(address)` | external (onlyOwner) | Set the CR address and renounce ownership (authority fixing) | CORE-BT-FR-003 |
| `mint(address,uint256)` | external (registered BO / AP only) | Issue JPYdf | CORE-BT-FR-004 |
| `burn(address,uint256)` | external (CR / registered BO / TM / SP only) | Burn JPYdf (allowance-independent) | CORE-BT-FR-005 |
| `proposeBridgeMinter(address)` / `confirmBridgeMinter()` / `cancelBridgeMinterProposal()` / `removeBridgeMinter(address)` | external (bridgeAdmin) | Manage the bridge minter registry (addition has a 48h timelock; removal is immediate) | CORE-BT-FR-014 |
| `bridgeMint(address,uint256)` | external (registered bridge minter only) | Issue JPYdf for the bridge | CORE-BT-FR-015 |
| `bridgeBurn(uint256)` | external (registered bridge minter only) | Burn only the bridge minter's own balance | CORE-BT-FR-015 |
| `transferBridgeAdmin(address)` / `acceptBridgeAdmin()` / `renounceBridgeAdmin()` | external | 2-step handover / safe renounce of bridgeAdmin | CORE-BT-FR-016 |
| `sendToPool(address,address,uint256)` | external (registered SP only) | Internal transfer from depositor to SP | CORE-BT-FR-006 |
| `returnFromPool(address,address,uint256)` | external (registered SP only) | Internal transfer from SP to depositor | CORE-BT-FR-007 |
| `transfer(address,uint256) → bool` | public | ERC-20 transfer (recipient-restricted) | CORE-BT-FR-008 |
| `transferFrom(address,address,uint256) → bool` | public | ERC-20 transfer (recipient-restricted) | CORE-BT-FR-008 |
| `isValidRecipient(address) → bool` | external view | Helper that evaluates the same recipient restriction as external transfers | CORE-BT-FR-008 |
| `requireValidRecipient(address)` | external view | Fail-fast helper for the same recipient restriction as external transfers | CORE-BT-FR-008 |
| `approve(address,uint256) → bool` | public | ERC-20 standard | CORE-BT-FR-009 |
| `increaseAllowance(address,uint256) → bool` | public | ERC-20 standard (OZ extension) | CORE-BT-FR-009 |
| `decreaseAllowance(address,uint256) → bool` | public | ERC-20 standard (OZ extension) | CORE-BT-FR-009 |
| `allowance(address,address) → uint256` | public view | ERC-20 standard | CORE-BT-FR-009 |
| `balanceOf(address) → uint256` | public view | ERC-20 standard | CORE-BT-FR-009 |
| `totalSupply() → uint256` | public view | ERC-20 standard | CORE-BT-FR-009 |
| `decimals() → uint8` | public view | Always 18 | CORE-BT-FR-009 |
| `name() → string` | public view | `"JPYdf Stablecoin"` 🟡 | CORE-BT-FR-010 |
| `symbol() → string` | public view | `"JPYdf"` 🟡 | CORE-BT-FR-010 |
| `permit(address,address,uint256,uint256,uint8,bytes32,bytes32)` | public | EIP-2612 signature approve | CORE-BT-FR-011 |
| `nonces(address) → uint256` | public view | EIP-2612 nonce | CORE-BT-FR-011 |
| `DOMAIN_SEPARATOR() → bytes32` | external view | EIP-712 domain | CORE-BT-FR-011 |
| `eip712Domain() → (bytes1,string,string,uint256,address,bytes32,uint256[])` | public view | ERC-5267 domain reporting | CORE-BT-FR-011 |
| `owner() → address` | public view | Current Owner (`address(0)` after renounce) | CORE-BT-FR-012 |
| `isOwner() → bool` | public view | Evaluates `msg.sender == owner` | CORE-BT-FR-012 |
| `collateralRegistryAddress() → address` | public view (auto-generated getter) | Configured CR address | CORE-BT-FR-012 |
| `bridgeAdmin()` / `pendingBridgeAdmin()` / `proposedBridgeMinter()` / `bridgeMinterProposedAt()` / `bridgeMinterCount()` / `isBridgeMinter(address)` | external/public view | State evidence of bridge readiness | CORE-BT-FR-013 / CORE-BT-FR-014 |

## 6. Functional Requirements (FR)

### CORE-BT-FR-001: constructor (deployment initialization) 🔵/🟡
- **Type**: Functional ｜ **Source**: base implementation (JpydfToken.sol) + CORE-MOD-008
- **Signature**: `constructor(address _owner, address _bridgeAdmin)`
- **Purpose**: Fix the ERC-20 metadata, EIP-712 domain, initial Owner, and independent bridgeAdmin to bring up the single JPYdf token of the system.
- **Authorization**: only once at deployment.
- **Preconditions (Checks)**: `_owner != address(0)`, `_bridgeAdmin != address(0)`, `_bridgeAdmin != _owner`, `_bridgeAdmin.code.length > 0`.
- **Behavior (Effects)**:
  1. `Ownable(_owner)`: set `_owner` as Owner and emit `OwnershipTransferred(address(0), _owner)`
  2. `ERC20(_NAME, _SYMBOL)`: fix name/symbol
  3. `ERC20Permit(_NAME)`: build the EIP-712 domain (name=`_NAME`, version=`"1"`, chainId, own address) and cache it immutably (OZ v4.9.5. Because the name is 31 bytes or fewer, it is held as a ShortString)
  4. Set `bridgeAdmin = _bridgeAdmin` and emit `BridgeAdminTransferred(address(0), _bridgeAdmin)`
- **Revert / early return**: owner zero → `JpydfToken__ZeroOwner`; bridge admin zero → `JpydfToken__ZeroBridgeAdmin`; owner and bridgeAdmin identical → `JpydfToken__BridgeAdminCannotBeOwner`; bridgeAdmin is not a contract → `JpydfToken__BridgeAdminMustBeContract`. OZ `ShortStrings` can revert with `StringTooLong(string)` only when name/version exceeds 31 bytes, but since the fixed values are 16 bytes / 1 byte, this is unreachable.
- **Emitted event**: `OwnershipTransferred` (CORE-BT-EVT-008), `BridgeAdminTransferred` (CORE-BT-EVT-010).
- **Verification**: parity (existing ERC-20 / Ownable initial state. The name/symbol values are excluded as CORE-MOD-001 and bridgeAdmin as CORE-MOD-008) + unit (constructor invariants).

### CORE-BT-FR-002: setBranchAddresses (authorization registration of branch contracts) 🔵/🟡
- **Type**: Functional / Governance ｜ **Source**: base implementation (JpydfToken.sol) + CORE-MOD-009
- **Signature**: `setBranchAddresses(address _troveManagerAddress, address _stabilityPoolAddress, address _borrowerOperationsAddress, address _activePoolAddress)`
- **Purpose**: Register one branch's TM / SP / BO / AP into the authorization sets for mint, burn, etc. Called repeatedly, once per branch.
- **Authorization**: `onlyOwner`.
- **Preconditions (Checks)**: caller is Owner. All 4 arguments are non-zero contract addresses with `code.length > 0` (CORE-MOD-009).
- **Behavior (Effects)**:
  1. `troveManagerAddresses[_troveManagerAddress] = true` → emit `TroveManagerAddressAdded`
  2. `stabilityPoolAddresses[_stabilityPoolAddress] = true` → emit `StabilityPoolAddressAdded`
  3. `borrowerOperationsAddresses[_borrowerOperationsAddress] = true` → emit `BorrowerOperationsAddressAdded`
  4. `activePoolAddresses[_activePoolAddress] = true` → emit `ActivePoolAddressAdded`
- **Revert / early return**: non-Owner → `"Ownable: caller is not the owner"`; zero address → `JpydfToken__ZeroCoreAddress`; codeless address → `JpydfToken__CoreAddressMustBeContract`.
- **Emitted event**: CORE-BT-EVT-002–005.
- **Design notes**: only additions to the mapping (setting true) are possible; there is no means of deregistration. After `setCollateralRegistry` executes (= ownership renounce) it can no longer be called, and a new branch cannot be added to JpydfToken later. CORE-MOD-009 rejects zero / undeployed addresses on the token side, but verification of the correct branch type and registry consistency still depends on the deployment script and verification procedures (CORE-BT-SEC-002).
- **Verification**: parity / unit (onlyOwner, mapping reflection, events).

### CORE-BT-FR-003: setCollateralRegistry (CR setting and permanent authority fixing) 🔵/🟡
- **Type**: Functional / Governance ｜ **Source**: base implementation (JpydfToken.sol) + CORE-MOD-009
- **Signature**: `setCollateralRegistry(address _collateralRegistryAddress)`
- **Purpose**: Set the CollateralRegistry (the burn caller during redemption) and, within the same tx, give up ownership to complete and freeze the deployment wiring.
- **Authorization**: `onlyOwner`.
- **Preconditions (Checks)**: caller is Owner. `_collateralRegistryAddress` is a non-zero contract address with `code.length > 0` (CORE-MOD-009).
- **Behavior (Effects)**:
  1. `collateralRegistryAddress = _collateralRegistryAddress` → emit `CollateralRegistryAddressChanged`
  2. `_renounceOwnership()`: emit `OwnershipTransferred(old owner, address(0))` and set `_owner = address(0)`
- **Revert / early return**: non-Owner → `"Ownable: caller is not the owner"`; zero address → `JpydfToken__ZeroCoreAddress`; codeless address → `JpydfToken__CoreAddressMustBeContract`.
- **Emitted event**: CORE-BT-EVT-001, CORE-BT-EVT-008.
- **Design notes**: "exactly once" is enforced not by an explicit flag but by the ownership renounce (after execution, the entire set of `onlyOwner` functions becomes permanently uncallable). Because this simultaneously seals `setBranchAddresses`, this function must be called **after all branches are registered, at the very end of the deployment procedure**. Thereafter there is no Core owner, and the Core authority set is completely fixed. bridgeAdmin continues to exist as a separate role (CORE-BT-FR-013).
- **Verification**: parity / unit (configured value, owner==0 after renounce, re-call revert).

### CORE-BT-FR-004: mint (issuance) 🔵
- **Type**: Functional ｜ **Source**: base implementation (JpydfToken.sol)
- **Signature**: `mint(address _account, uint256 _amount)`
- **Purpose**: Issue JPYdf in response to debt creation and interest issuance.
- **Authorization**: registered BorrowerOperations **or** ActivePool only (`_requireCallerIsBOorAP`: `borrowerOperationsAddresses[msg.sender] || activePoolAddresses[msg.sender]`).
- **Preconditions (Checks)**: the above authorization only (`_mint` internally requires `_account != address(0)`).
- **Behavior (Effects)**:
  1. `_mint(_account, _amount)`: `_account` balance +amount, `totalSupply` +amount
  2. Emit ERC-20 `Transfer(address(0), _account, _amount)`
- **Revert / early return**: unauthorized → `JpydfToken__CallerIsNotBorrowerOperationsOrActivePool`; `_account == address(0)` → `"ERC20: mint to the zero address"`.
- **Emitted event**: ERC-20 `Transfer` (mint, CORE-BT-EVT-006).
- **Design notes**: in the implementation, callers are two families: (a) BO borrowing / debt increase (issuance to the borrower), and (b) AP aggregated interest issuance (75% of the SP yield share to the SP, the remainder to the interestRouter) and batch management fee issuance (see the respective BO / AP sections). Bridge minters cannot call this function. The bridge supply path is separated into the differently named `bridgeMint` (CORE-BT-FR-015).
- **Verification**: parity / unit (authorization revert, balance/supply reflection). Cross-contract consistency of supply and debt is CORE-SYS-INV-003.

### CORE-BT-FR-005: burn (burning) 🔵
- **Type**: Functional ｜ **Source**: base implementation (JpydfToken.sol)
- **Signature**: `burn(address _account, uint256 _amount)`
- **Purpose**: Burn JPYdf in response to repayment, redemption, and liquidation offset.
- **Authorization**: CollateralRegistry (`msg.sender == collateralRegistryAddress`), or registered BorrowerOperations / TroveManager / StabilityPool (`_requireCallerIsCRorBOorTMorSP`).
- **Preconditions (Checks)**: the above authorization; `_account` balance ≥ `_amount` (ERC-20 internal check).
- **Behavior (Effects)**:
  1. `_burn(_account, _amount)`: `_account` balance −amount, `totalSupply` −amount
  2. Emit ERC-20 `Transfer(_account, address(0), _amount)`
- **Revert / early return**: unauthorized → `JpydfToken__CallerIsNotCoreBurner`; insufficient balance → `"ERC20: burn amount exceeds balance"`.
- **Emitted event**: ERC-20 `Transfer` (burn, CORE-BT-EVT-006).
- **Design notes**: this is a strong, allowance-independent authority, but in the implementation the burn target is limited to (a) BO: the repaying / closing borrower (`msg.sender`), (b) TM: the executor of urgent redemption after shutdown (`msg.sender`), (c) CR: the redemption executor (`msg.sender`), and (d) SP: the SP itself at liquidation offset (`address(this)`); there is no path in the core implementation to arbitrarily burn a third party's balance (CORE-BT-SEC-003). Bridge minters cannot call this function; bridge burn is separated into the self-burn-type `bridgeBurn` (CORE-BT-FR-015).
- **Verification**: parity / unit (authorization for the 4 families, insufficient-balance revert).

### CORE-BT-FR-006: sendToPool (deposit transfer to SP) 🔵
- **Type**: Functional ｜ **Source**: base implementation (JpydfToken.sol)
- **Signature**: `sendToPool(address _sender, address _poolAddress, uint256 _amount)`
- **Purpose**: At SP deposit (provideToSP), internally transfer JPYdf from the depositor to the SP without allowance.
- **Authorization**: registered StabilityPool only (`_requireCallerIsStabilityPool`: `stabilityPoolAddresses[msg.sender]`).
- **Preconditions (Checks)**: the above authorization; `_sender` balance ≥ `_amount`.
- **Behavior (Effects)**:
  1. `_transfer(_sender, _poolAddress, _amount)` (the recipient restriction `_requireValidRecipient` is not applied = core internal transfer)
  2. Emit ERC-20 `Transfer(_sender, _poolAddress, _amount)`
- **Revert / early return**: unauthorized → `JpydfToken__CallerIsNotStabilityPool`; insufficient balance → `"ERC20: transfer amount exceeds balance"`.
- **Emitted event**: ERC-20 `Transfer` (CORE-BT-EVT-006).
- **Design notes**: in the implementation the SP calls this only in the form `sendToPool(msg.sender, address(this), _topUp)` (the depositor is the same party who called the SP). Fixing `_poolAddress` to the SP itself is a discipline on the caller side; this function itself does not validate the arguments.
- **Verification**: parity / unit (SP-only, transfer reflection).

### CORE-BT-FR-007: returnFromPool (withdrawal transfer from SP) 🔵
- **Type**: Functional ｜ **Source**: base implementation (JpydfToken.sol)
- **Signature**: `returnFromPool(address _poolAddress, address _receiver, uint256 _amount)`
- **Purpose**: At withdrawal from the SP (withdrawFromSP), internally transfer JPYdf from the SP to the depositor.
- **Authorization**: registered StabilityPool only (`_requireCallerIsStabilityPool`).
- **Preconditions (Checks)**: the above authorization; `_poolAddress` balance ≥ `_amount`.
- **Behavior (Effects)**:
  1. `_transfer(_poolAddress, _receiver, _amount)`
  2. Emit ERC-20 `Transfer(_poolAddress, _receiver, _amount)`
- **Revert / early return**: unauthorized → `JpydfToken__CallerIsNotStabilityPool`; insufficient balance → ERC-20 revert.
- **Emitted event**: ERC-20 `Transfer` (CORE-BT-EVT-006).
- **Verification**: parity / unit (SP-only, transfer reflection).

### CORE-BT-FR-008: transfer / transferFrom / recipient helper (recipient-restricted ERC-20 transfer) 🔵/🟢
- **Type**: Functional ｜ **Source**: base implementation (JpydfToken.sol)
- **Signature**: `transfer(address recipient, uint256 amount) → bool` / `transferFrom(address sender, address recipient, uint256 amount) → bool` / `isValidRecipient(address recipient) → bool` / `requireValidRecipient(address recipient)`
- **Purpose**: Add recipient verification on top of standard ERC-20 transfers to prevent permanent locking from misdirected sends. The auxiliary views let external contracts preflight the same check.
- **Authorization**: permissionless (`transferFrom` requires allowance).
- **Preconditions (Checks)**: `_requireValidRecipient(recipient)`: `recipient != address(0) && recipient != address(this) && recipient != collateralRegistryAddress && !troveManagerAddresses[recipient] && !stabilityPoolAddresses[recipient] && !borrowerOperationsAddresses[recipient] && !activePoolAddresses[recipient]`. Thereafter the OZ ERC20 standard (balance / allowance) applies.
- **Behavior (Effects)**:
  1. After recipient verification, delegate to `super.transfer` / `super.transferFrom` (balance transfer; `transferFrom` decrements allowance. An allowance of `type(uint256).max` is not decremented = OZ v4.9.5 standard)
  2. Emit ERC-20 `Transfer` (and `Approval` as well if the allowance changed in `transferFrom`)
  3. `isValidRecipient` returns the same predicate as a bool. `requireValidRecipient` reverts only if the same predicate fails and does not change state
- **Revert / early return**: `recipient` is zero, JpydfToken itself, CollateralRegistry, or a registered TM/SP/BO/AP → `JpydfToken__CannotTransferToProtocolContract`; insufficient balance / insufficient allowance → OZ ERC20 standard revert.
- **Emitted event**: ERC-20 `Transfer` / `Approval` (CORE-BT-EVT-006/007).
- **Design notes**: a blacklist to prevent user misdirected sends to core contracts. `sendToPool` / `returnFromPool` are internal transfers and do not pass through this external transfer restriction. `requireValidRecipient` is a helper that lets `PILAllocator.registerInitiative` and similar fail-fast on the same restriction without the side effect of a 0-amount transfer.
- **Verification**: unit (restriction revert, standard transfer).

### CORE-BT-FR-009: ERC-20 standard conformance (approve / allowance / balance and supply views, etc.) 🔵
- **Type**: Functional ｜ **Source**: base implementation (OZ v4.9.5 ERC20 inheritance)
- **Signature**: `approve(address,uint256) → bool` / `increaseAllowance(address,uint256) → bool` / `decreaseAllowance(address,uint256) → bool` / `allowance(address,address) → uint256` / `balanceOf(address) → uint256` / `totalSupply() → uint256` / `decimals() → uint8`
- **Purpose**: Provide standard ERC-20 semantics. There are no JpydfToken-specific overrides.
- **Authorization**: permissionless.
- **Behavior (Effects)**: fully conforms to the standard implementation of OZ v4.9.5 `ERC20`. `decimals()` is fixed at 18. `decreaseAllowance` reverts with `"ERC20: decreased allowance below zero"` when reducing below the current allowance, and `approve` with a zero-address spender reverts with `"ERC20: approve to the zero address"`.
- **Revert / early return**: per the OZ standard.
- **Emitted event**: `Approval` (CORE-BT-EVT-007).
- **Design notes**: because this is OZ v4.9-series, `increaseAllowance` / `decreaseAllowance` exist in the ABI (extensions that were removed in the v5 series).
- **Verification**: parity (base identity of standard behavior).

### CORE-BT-FR-010: name / symbol (token name and symbol) 🟡
- **Type**: Functional ｜ **Source**: DF modification (JpydfToken.sol `_NAME` / `_SYMBOL`) + OZ ERC20 metadata
- **Signature**: `name() → string` / `symbol() → string`
- **Purpose**: Return token metadata. The values are fixed by the compile-time constants `_NAME` / `_SYMBOL`.
- **Authorization**: permissionless (view).
- **Behavior (Effects)**: `name()` returns `"JPYdf Stablecoin"` and `symbol()` returns `"JPYdf"` (no means of change).
- **Revert / early return**: none.
- **Emitted event**: none.
- **Diff from base**: in the base, `_NAME = "BOLD Stablecoin"` / `_SYMBOL = "BOLD"`. In DF, `_NAME = "JPYdf Stablecoin"` / `_SYMBOL = "JPYdf"`. Rationale: CORE-MOD-001 (§2.2) (renaming to the JPYdf token name. No impact on logic, storage, or authorization; the ripple is only the ERC-20 metadata and the name value of the EIP-712 domain = CORE-BT-FR-011).
- **Verification**: unit (verifying the fixed values). The values are excluded from the parity scope and traced as CORE-MOD-001.
- **Design notes**: because `_NAME` is also passed to `ERC20Permit(_NAME)`, the name of the EIP-2612 signing domain is also `"JPYdf Stablecoin"` (it is not signature-compatible with the base deployment artifact, but since it is an independent deployment this is not a problem).

### CORE-BT-FR-011: permit (EIP-2612) and the EIP-712 domain view group 🔵
- **Type**: Functional ｜ **Source**: base implementation (OZ v4.9.5 ERC20Permit / EIP712 inheritance)
- **Signature**: `permit(address owner, address spender, uint256 value, uint256 deadline, uint8 v, bytes32 r, bytes32 s)` / `nonces(address owner) → uint256` / `DOMAIN_SEPARATOR() → bytes32` / `eip712Domain() → (bytes1, string, string, uint256, address, bytes32, uint256[])`
- **Purpose**: Provide signature-based allowance setting without prior approve (EIP-2612), and the domain information needed to generate signatures (ERC-5267).
- **Authorization**: permissionless (signature verification only).
- **Preconditions (Checks)**: `block.timestamp <= deadline`; the signer recovered by `ECDSA.recover` `== owner` (the nonce consumes `owner`'s current value).
- **Behavior (Effects)**:
  1. `_useNonce(owner)`: increment `nonces(owner)` by 1 (sequential enforcement / replay protection)
  2. `_approve(owner, spender, value)` → emit `Approval`
- **Revert / early return**: expired deadline → `"ERC20Permit: expired deadline"`; signer mismatch (including nonce skew) → `"ERC20Permit: invalid signature"`.
- **Emitted event**: ERC-20 `Approval` (CORE-BT-EVT-007).
- **Design notes**: the domain is built in the constructor from `(name=_NAME, version="1", chainId, address(this))` and cached immutably (OZ v4.9.5. If chainId changes due to a chain fork, etc., it is re-derived each time). `eip712Domain()` reports fields=`0x0f` (name/version/chainId/verifyingContract), with salt and extensions unused. The `EIP712DomainChanged` event appears in the ABI as an ERC-5267 interface declaration, but because the domain is immutable it **never fires**. The fact that the name value differs from the base is a consequence of CORE-MOD-001; the permit logic itself is identical to the base.
- **Verification**: parity (signature verification, nonce, revert behavior), unit (that `DOMAIN_SEPARATOR` is derived from name=`_NAME`).

### CORE-BT-FR-012: trivial view function group (owner / isOwner / collateralRegistryAddress) 🔵
- **Type**: Functional ｜ **Source**: base implementation (Ownable.sol / auto-generated getter)
- **Signature and return values**:

  | Function | Meaning of return value |
  | --- | --- |
  | `owner() → address` | Current Owner. `address(0)` after `setCollateralRegistry` executes |
  | `isOwner() → bool` | Evaluates `msg.sender == _owner` (a public view specific to the Liquity-version Ownable) |
  | `collateralRegistryAddress() → address` | Configured CR (`address(0)` if unset) |
- **Authorization**: permissionless (view).
- **Verification**: parity.

### CORE-BT-FR-013: bridgeAdmin and the bridge readiness view group 🟡
- **Type**: Functional / Governance ｜ **Source**: CORE-MOD-008
- **Signature**: `bridgeAdmin()`, `pendingBridgeAdmin()`, `proposedBridgeMinter()`, `bridgeMinterProposedAt()`, `bridgeMinterCount()`, `isBridgeMinter(address)`
- **Purpose**: Hold bridge governance state independent of the Core owner, and provide on-chain / manifest evidence of the Day-1 dormant state (0 minters, no pending proposal).
- **Authorization**: views are permissionless. State changes are FR-014 / FR-016.
- **Behavior (Effects)**: none (view). At constructor time, `bridgeAdmin = _bridgeAdmin`; the rest are zero-initialized.
- **Design notes**: even when `setCollateralRegistry` makes the owner `address(0)`, `bridgeAdmin` continues to exist because it is in separate storage. `bridgeAdmin` is limited to contract addresses only. On Day-1 mainnet, a Safe / Timelock holder is set and is not made identical to the deployer.
- **Verification**: unit (bridgeAdmin survival after owner renounce, initial view values).

### CORE-BT-FR-014: bridge minter registry (propose / confirm / cancel / remove) 🟡
- **Type**: Functional / Governance ｜ **Source**: CORE-MOD-008
- **Signature**: `proposeBridgeMinter(address)`, `confirmBridgeMinter()`, `cancelBridgeMinterProposal()`, `removeBridgeMinter(address)`
- **Purpose**: Carefully add bridge adapters / minters with a 48h timelock, and allow immediate removal on compromise or misconfiguration.
- **Authorization**: `bridgeAdmin` only.
- **Preconditions (Checks)**:
  - `proposeBridgeMinter`: minter non-zero, not the token itself, not the current / pending `bridgeAdmin`, not already registered, no existing proposal, a contract address
  - `confirmBridgeMinter`: a proposal exists, the proposal target is not the current / pending `bridgeAdmin`, a contract address, `block.timestamp >= bridgeMinterProposedAt + 48 hours`
  - `cancelBridgeMinterProposal`: a proposal exists
  - `removeBridgeMinter`: the minter is registered
- **Behavior (Effects)**:
  - propose: set `proposedBridgeMinter` and `bridgeMinterProposedAt`
  - confirm: `bridgeMinterAddresses[minter] = true`, `bridgeMinterCount++`, clear the proposal
  - cancel: clear the proposal
  - remove: `bridgeMinterAddresses[minter] = false`, `bridgeMinterCount--`
- **Revert / early return**: non-admin → `JpydfToken__CallerIsNotBridgeAdmin`; timelock not elapsed → `JpydfToken__BridgeMinterTimelockNotElapsed`; other custom errors are in CORE-BT-ERR-001.
- **Emitted event**: CORE-BT-EVT-010.
- **Design notes**: `JpydfToken` does not introspect whether the proposal target has sufficient cap / rate / accounting / pause as an adapter. `bridgeAdmin` approves the Stage A activation package of CORE-BT-GOV-001 before `proposeBridgeMinter`, and re-confirms the same evidence before `confirmBridgeMinter`. Adapters that do not meet the conditions are not proposed, and if the conditions break during the pending period the proposal is cancelled.
- **Verification**: unit (timelock boundary, cancel, remove, count/view).

### CORE-BT-FR-015: bridgeMint / bridgeBurn (bridge supply path) 🟡
- **Type**: Functional ｜ **Source**: CORE-MOD-008
- **Signature**: `bridgeMint(address _account, uint256 _amount)` / `bridgeBurn(uint256 _amount)`
- **Purpose**: In a token-only canonical bridge from Day 2 onward, allow registered bridge minters to adjust source/destination supply.
- **Authorization**: registered bridge minter only (`bridgeMinterAddresses[msg.sender]`).
- **Behavior (Effects)**:
  - `bridgeMint`: apply the same protocol recipient blacklist as normal transfers to `_account`, then `_mint(_account, _amount)`. Increases `totalSupply` and the `_account` balance.
  - `bridgeBurn`: `_burn(msg.sender, _amount)`. Burns only the bridge minter's own balance.
- **Revert / early return**: non-minter → `JpydfToken__CallerIsNotBridgeMinter`; mint addressed to a protocol recipient → `JpydfToken__CannotTransferToProtocolContract`; mint to zero address / burn with insufficient balance are OZ ERC-20 reverts.
- **Emitted event**: `BridgeMint` / `BridgeBurn` and ERC-20 `Transfer`.
- **Design notes**: bridge minters are not added to Core `mint` / `burn`. An arbitrary-address burn such as `bridgeBurn(address from, uint256 amount)` is not provided, limiting the blast radius on minter compromise to self-burn. Bridge minters are contract addresses only, and serving as both this and `bridgeAdmin` is prohibited. There is no token-level per-chain cap / rate limit, so these are enforced on-chain by the registered adapter (CORE-BT-SEC-005). If the adapter does not have a hard cap / rolling mint limit / global bridged supply cap / pause / replay / domain binding, do not let it use `bridgeMint`.
- **Verification**: unit (non-minter revert, mint, self-burn, blocking after remove).

### CORE-BT-FR-016: bridgeAdmin transfer / renounce 🟡
- **Type**: Functional / Governance ｜ **Source**: CORE-MOD-008
- **Signature**: `transferBridgeAdmin(address)`, `acceptBridgeAdmin()`, `renounceBridgeAdmin()`
- **Purpose**: Hand over bridgeAdmin in 2 steps, and, when fully giving up bridge readiness, allow renounce only under safe conditions.
- **Authorization**: `transferBridgeAdmin` / `renounceBridgeAdmin` are current `bridgeAdmin` only. `acceptBridgeAdmin` is `pendingBridgeAdmin` only.
- **Preconditions (Checks)**:
  - transfer: new admin non-zero, not the token itself, not identical to the current owner, not a registered / in-proposal bridge minter, a contract address
  - accept: caller is pending, not a registered / in-proposal bridge minter, a contract address
  - renounce: `bridgeMinterCount == 0`, `proposedBridgeMinter == address(0)`
- **Behavior (Effects)**: transfer sets `pendingBridgeAdmin`. accept updates `bridgeAdmin` to pending and clears pending. renounce clears `bridgeAdmin` and pending.
- **Revert / early return**: non-admin / non-pending / live minter / pending proposal revert with require strings.
- **Emitted event**: CORE-BT-EVT-010.
- **Verification**: unit (2-step, non-pending reject, live-minter renounce reject, renounce with 0 minters).

## 7. State Variables and Accounting Model

| Variable | Type / Visibility | Initial value / set location | Meaning / accounting role |
| --- | --- | --- | --- |
| `_NAME` | `string internal constant` | `"JPYdf Stablecoin"` 🟡 (CORE-MOD-001 (§2.2)) | Used for both the ERC-20 name and the EIP-712 domain name |
| `_SYMBOL` | `string internal constant` | `"JPYdf"` 🟡 (CORE-MOD-001 (§2.2)) | ERC-20 symbol |
| `collateralRegistryAddress` | `address public` | Set once via `setCollateralRegistry` | The single address of the CR holding burn authority |
| `troveManagerAddresses` | `mapping(address => bool)` (internal) | Only true-additions via `setBranchAddresses` | Burn authorization set (TM per branch) |
| `stabilityPoolAddresses` | `mapping(address => bool)` (internal) | Only true-additions via `setBranchAddresses` | Authorization set for burn / sendToPool / returnFromPool |
| `borrowerOperationsAddresses` | `mapping(address => bool)` (internal) | Only true-additions via `setBranchAddresses` | mint / burn authorization set |
| `activePoolAddresses` | `mapping(address => bool)` (internal) | Only true-additions via `setBranchAddresses` | mint authorization set (issuer of interest / management fees) |
| (inherited: Ownable) `_owner` | `address private` | The `_owner` argument in the constructor; `address(0)` via `_renounceOwnership()` inside `setCollateralRegistry` | An administrator valid only during the deployment-wiring period |
| (inherited: ERC20) `_balances` / `_allowances` / `_totalSupply` / `_name` / `_symbol` | OZ v4.9.5 standard storage | constructor (`_name`/`_symbol` are `_NAME`/`_SYMBOL`) | The canonical source of ERC-20 accounting |
| (inherited: ERC20Permit) `_nonces` (storage) / `_PERMIT_TYPEHASH_DEPRECATED_SLOT` (storage; OZ compatibility placeholder, unused) | OZ v4.9.5 standard | — | EIP-2612 replay protection |
| (inherited: EIP712) `_nameFallback` / `_versionFallback` (storage; used only when name/version exceeds 31 bytes = always empty in this configuration) / `_cachedDomainSeparator` / `_cachedChainId` / `_cachedThis` / `_hashedName` / `_hashedVersion` / `_name` / `_version` (immutable) | OZ v4.9.5 standard | Fixed in the constructor as `EIP712(_NAME, "1")` | The EIP-712 domain (the name is the 🟡 CORE-MOD-001 value) |

## 8. Invariants (INV)

### CORE-BT-INV-001: permanent fixing of the authority configuration 🔵
After `setCollateralRegistry` executes, `owner() == address(0)`, and `collateralRegistryAddress` and the 4 Core authorization mappings can no longer be changed by any means thereafter (no add/remove functions exist, and the contract is non-upgradeable). The authorization sets for Core `mint` / `burn` / `sendToPool` / `returnFromPool` are permanently immutable at the values present when deployment wiring completes.

### CORE-BT-INV-002: ERC-20 accounting consistency 🔵
`totalSupply() == Σ balanceOf(a)`. Supply increases and decreases only through Core `mint` (CORE-BT-FR-004) / Core `burn` (CORE-BT-FR-005) / `bridgeMint` / `bridgeBurn` (CORE-BT-FR-015).
For cross-contract consistency of supply and the total debt across all branches, see CORE-SYS-INV-003.

### CORE-BT-INV-003: dormancy of bridge readiness 🟡
At Day-1 launch, `bridgeMinterCount == 0`, `proposedBridgeMinter == address(0)`, and `bridgeMinterProposedAt == 0`. bridgeAdmin survives even after owner renounce, but as long as there are 0 minters, no address can execute `bridgeMint` / `bridgeBurn`.
- **Verification**: unit / deploy manifest evidence.

### CORE-BT-INV-004: global canonical supply accounting after bridge activation 🟡
If bridge minters are registered from Day 2 onward, at any audit checkpoint it must be possible to reconstruct, per chain/domain, `globalCanonicalJpydfSupply = ethereumJpydfToken.totalSupply() - ethereumBridgeEscrowedCanonical + Σ remoteCanonicalJpydfSupply[chain]`. In the burn/mint model, `ethereumBridgeEscrowedCanonical = 0`; in the lock/unlock model, the source escrow is not double-counted. Source burn / lock and destination mint / unlock correspond 1:1 per finalized message, and pending / in-flight / failed messages are tracked in a separate bucket from canonical supply. Which of the remote token, wrapped representation, test token, or DEX LP token is regarded as canonical JPYdf is fixed in the activation package, and unapproved representations are excluded from supply accounting and from the user-facing canonical display.
- **Verification**: adapter invariant / off-chain accounting replay / fork / integration test / monitoring dry-run.

## 9. Security Requirements (SEC)

### CORE-BT-SEC-001: trust boundary of mint authority 🔵
Increasing JPYdf supply through Core `mint` is executable only by registered BO (borrowing) and AP (interest / batch management fee issuance). The premise of value backing is that there is no Core `mint` path other than these 2 contracts (including the Owner / bridgeAdmin / bridge minters). Because passing a wrong (or malicious) address to `setBranchAddresses` during deployment wiring enables unlimited Core mint, validating the legitimacy of the registered addresses is a mandatory item of the deployment procedure.

### CORE-BT-SEC-002: irreversibility of registration (dependent on the deployment procedure) 🔵
`setBranchAddresses` / `setCollateralRegistry` reject zero addresses and codeless addresses via CORE-MOD-009. However, the token side does not verify duplicates, branch-type mix-ups, mistaken registration of a different branch contract, or semantic consistency with the registry. There is no means of undoing a registration, and because the owner is renounced after `setCollateralRegistry`, mistaken registrations remain permanently. Mitigations are deployment-script verification, reconciliation before renounce, and manifest evidence.

### CORE-BT-SEC-003: allowance-independent burn / internal transfer 🔵
`burn` / `sendToPool` / `returnFromPool` can move balances without the holder's approve. Their use in the core implementation is limited to self-originated flows (repayment, redemption, SP deposit/withdrawal, SP offset), but as a trust boundary, audit and monitor on the premise that "registered core contracts can burn / transfer any account's JPYdf."

### CORE-BT-SEC-004: bridge minter trust boundary 🟡
A registered bridge minter can issue JPYdf to any account via `bridgeMint`. `bridgeBurn` is the self-burn type and burns only the minter's own balance, so a minter cannot directly burn arbitrary user balances. Minter addition has a 48h timelock; removal is immediate. Rate limit / message verification / bridge-specific pause are the responsibility of the minter / adapter side, and `JpydfToken` only evaluates "whether it is a registered minter."

### CORE-BT-SEC-005: bridge adapter cap / rate / pause fail-closed gate 🟡
`JpydfToken` is non-upgradeable, and per-bridge-route cap / rate limit / pause / remote accounting cannot be added to the token after the fact. A registered bridge minter must enforce, on-chain on the adapter side, per-destination cap, per-route hourly / daily rolling mint limit, global bridged supply cap, route pause, message replay protection, source chain/domain binding, remote token binding, and remote supply accounting. An adapter that lacks these must not be proposed / confirmed by `bridgeAdmin`. When an approved activation package exists, a minter may be registered while the adapter remains at runtime cap 0 / route paused, but a nonzero cap or a public route open is a separate gate. If the design must change to one requiring token-level control, treat it as a separate design / separate audit including a new token / wrapper / migration, rather than an unsafe registration against the existing `JpydfToken`.
- **Verification**: adapter unit / invariant / integration / incident dry-run. The token-side unit verifies that "unregistered / removed minters cannot mint," and the verification of adapter controls is held by the Day-2 activation package.

## 10. Governance, Operations, and Upgrade Requirements (GOV)

- **Fixing of Core authority**: the Owner is disposable via `setBranchAddresses` (repeatable per branch) → `setCollateralRegistry` (which sets the CR and simultaneously calls `_renounceOwnership`). After renounce, the Core authority set (mint/burn authority / CR reference) is permanently fixed, and later addition or replacement of branches is impossible (CORE-BT-FR-002 / CORE-BT-FR-003 / CORE-BT-INV-001).
- **Independence of bridge governance**: `bridgeAdmin` is in separate storage from the Owner and survives even after owner renounce. `bridgeAdmin` / bridge minters are contract addresses only, and serving as both admin and minter is prohibited. Bridge minter addition has a 48h timelock (`PRM-BRIDGE-MINTER-TIMELOCK`, [Parameters](../../../Parameters.md)); removal is immediate. Admin handover is 2-step, and renounce is allowed only when `bridgeMinterCount == 0` and there is no pending proposal (CORE-BT-FR-013 / CORE-BT-FR-014 / CORE-BT-FR-016).
- **Non-upgradeable**: it has no proxy. Changing token logic is at the redeploy level (the same treatment as the immutable premise of Core / CollateralRegistry).
- **Day-1 launch gate**: the dormant state `bridgeMinterCount == 0` / `proposedBridgeMinter == address(0)` is mandatory and evidenced by the deploy manifest and governance handover evidence (CORE-BT-INV-003 / CORE-MOD-008, [Product-Overview](../Product-Overview.md) SYS-INV-003).

### CORE-BT-GOV-001: bridge minter activation gate 🟡
`bridgeAdmin` must not execute `proposeBridgeMinter` until the Stage A activation package of [Bridge-Minter-Activation-Gate](../../operations/runbooks/Bridge-Minter-Activation-Gate.md) is approved. The Stage A package includes the adopted bridge protocol / chain IDs / domain IDs / endpoint addresses, remote token / adapter addresses and codehash, approved pilot cap / rate limit, global bridged supply cap, remote supply accounting / monitoring plan, pause / guardian holder, separation of admin / minter / upgrader / relayer / accounting operator, adapter test / invariant evidence, internal differential review, and incident runbook. Re-confirm the same package before `confirmBridgeMinter`, and if during the timelock there is an adapter upgrade, remote admin change, chain incident, or verification drift, cancel the proposal. If, after `confirmBridgeMinter` and before Stage B, the adapter / remote program codehash, endpoint config, remote token authority, role holders, or cap / rate config changes, invalidate the Stage A evidence and re-verify with the route kept paused / runtime cap 0. Operator-only canaries are handled only within a canary envelope of adapter / endpoint-enforced allowlisted operator / max amount / expiry / public flag closed; a route closed only by a UI / ops flag, a public open of a frontend / ops route flag, a third-party accessible route, exceeding the canary envelope, and cap ramp are separate Stage B / C gates.
- **Verification**: manual governance review / Safe / Timelock transaction evidence / adapter verification package / incident rehearsal. A public route open requires Stage B evidence, and a cap ramp requires Stage C evidence.

## 11. Events and Monitoring Requirements (EVT)

| ID | Event | Emission site | indexed | off-chain use |
| --- | --- | --- | --- | --- |
| CORE-BT-EVT-001 | `CollateralRegistryAddressChanged(address _newCollateralRegistryAddress)` | `setCollateralRegistry` | none | Detect completion of deployment wiring (= authority freeze) |
| CORE-BT-EVT-002 | `TroveManagerAddressAdded(address _newTroveManagerAddress)` | `setBranchAddresses` | none | Audit trail of branch registration |
| CORE-BT-EVT-003 | `StabilityPoolAddressAdded(address _newStabilityPoolAddress)` | `setBranchAddresses` | none | Same as above |
| CORE-BT-EVT-004 | `BorrowerOperationsAddressAdded(address _newBorrowerOperationsAddress)` | `setBranchAddresses` | none | Same as above |
| CORE-BT-EVT-005 | `ActivePoolAddressAdded(address _newActivePoolAddress)` | `setBranchAddresses` | none | Same as above |
| CORE-BT-EVT-006 | ERC-20 `Transfer(address from, address to, uint256 value)` | mint (from=0) / burn (to=0) / each transfer | from, to | Track supply and fund flow (primary subgraph source) |
| CORE-BT-EVT-007 | ERC-20 `Approval(address owner, address spender, uint256 value)` | `approve` / `permit` / allowance change | owner, spender | Allowance monitoring |
| CORE-BT-EVT-008 | `OwnershipTransferred(address previousOwner, address newOwner)` | constructor / `_renounceOwnership` | previousOwner, newOwner | Detect Owner setting / renounce (newOwner=0) |
| CORE-BT-EVT-009 | `EIP712DomainChanged()` | **does not fire** (ERC-5267 declaration only; domain immutable) | none | No monitoring needed (recorded for ABI matching) |
| CORE-BT-EVT-010 | `BridgeAdminTransferStarted(address indexed currentBridgeAdmin, address indexed pendingBridgeAdmin)` / `BridgeAdminTransferred(address indexed previousBridgeAdmin, address indexed newBridgeAdmin)` / `BridgeMinterProposed(address indexed bridgeMinter, uint256 proposedAt, uint256 confirmableAt)` / `BridgeMinterProposalCancelled(address indexed bridgeMinter)` / `BridgeMinterConfirmed(address indexed bridgeMinter)` / `BridgeMinterRemoved(address indexed bridgeMinter)` / `BridgeMint(address indexed bridgeMinter, address indexed account, uint256 amount)` / `BridgeBurn(address indexed bridgeMinter, uint256 amount)` | constructor / bridgeAdmin functions / bridge supply path | target address | Monitor bridge readiness governance / activation / supply. After Day-2 bridge activation, use together with adapter events for the supply accounting / cap alerts of CORE-BT-INV-004 |

## 12. Failure and Exception Behavior (ERR)

### CORE-BT-ERR-001: failure behavior (custom error / standard revert) 🔵
| Condition | revert |
| --- | --- |
| unauthorized mint | `JpydfToken__CallerIsNotBorrowerOperationsOrActivePool` |
| unauthorized burn | `JpydfToken__CallerIsNotCoreBurner` |
| unauthorized sendToPool / returnFromPool | `JpydfToken__CallerIsNotStabilityPool` |
| transfer/transferFrom/bridgeMint recipient is zero / itself / a registered protocol contract | `JpydfToken__CannotTransferToProtocolContract` |
| core address of setBranchAddresses / setCollateralRegistry is zero | `JpydfToken__ZeroCoreAddress` |
| core address of setBranchAddresses / setCollateralRegistry is not a contract | `JpydfToken__CoreAddressMustBeContract` |
| constructor owner zero | `JpydfToken__ZeroOwner` |
| constructor bridgeAdmin zero | `JpydfToken__ZeroBridgeAdmin` |
| bridgeAdmin and owner identical in constructor / transferBridgeAdmin | `JpydfToken__BridgeAdminCannotBeOwner` |
| bridgeAdmin is not a contract in constructor / transferBridgeAdmin / acceptBridgeAdmin | `JpydfToken__BridgeAdminMustBeContract` |
| bridgeAdmin of transferBridgeAdmin is the token itself | `JpydfToken__BridgeAdminCannotBeToken` |
| bridgeAdmin of transferBridgeAdmin / acceptBridgeAdmin is a registered or in-proposal bridge minter | `JpydfToken__BridgeAdminCannotBeMinter` |
| a non-bridgeAdmin calls an admin function | `JpydfToken__CallerIsNotBridgeAdmin` |
| zero bridge minter proposal | `JpydfToken__ZeroBridgeMinter` |
| bridge minter proposal is the token itself | `JpydfToken__BridgeMinterCannotBeToken` |
| bridge minter proposal / confirm target is the current / pending bridgeAdmin | `JpydfToken__BridgeMinterCannotBeAdmin` |
| bridge minter proposal / confirm target is not a contract | `JpydfToken__BridgeMinterMustBeContract` |
| propose an already-registered minter | `JpydfToken__BridgeMinterAlreadySet` |
| propose while a pending proposal exists | `JpydfToken__BridgeMinterAlreadyProposed` |
| confirm/cancel without a proposal | `JpydfToken__NoBridgeMinterProposed` |
| bridge minter timelock not elapsed | `JpydfToken__BridgeMinterTimelockNotElapsed` |
| remove of an unregistered minter | `JpydfToken__NotBridgeMinter` |
| a non-pendingBridgeAdmin calls accept | `JpydfToken__CallerIsNotPendingBridgeAdmin` |
| renounceBridgeAdmin while a live bridge minter exists | `JpydfToken__BridgeMintersStillSet` |
| renounceBridgeAdmin while a pending bridge minter proposal exists | `JpydfToken__CannotRenounceWithPendingBridgeMinter` |
| a non-minter calls bridgeMint / bridgeBurn | `JpydfToken__CallerIsNotBridgeMinter` |
| onlyOwner violation | `"Ownable: caller is not the owner"` |
| ERC-20 / EIP-2612 standard violation | OZ v4.9.5 standard strings (insufficient balance / insufficient allowance / expired deadline / signature mismatch, etc.) |

(The ABI custom errors `InvalidShortString()` / `StringTooLong(string)` originate from OZ `ShortStrings` and are reachable only in the constructor's name/version processing = they do not occur in operation.)

## 15. References

- 🔵 [Liquity v2 Core Spec](Liquity-v2-Core-Spec.md) — callers of Core `mint` / `burn` (BO/AP/TM/SP/CR), §2.2 DF diff ledger (CORE-MOD-001 / 008 / 009), redemption / liquidation / Stability Pool flows
- 🧭 [Product Overview](../Product-Overview.md) — SYS-FR-006 (bridge-ready dormant surface) / SYS-CON-004 / SYS-INV-003
- 🧾 [Architecture Decision Records](../architecture/Architecture-Decision-Records.md#adr-004) — rationale for separating the bridge supply path from Core
- 📊 [Parameters](../../../Parameters.md) — the canonical source of bridge security parameters such as `PRM-BRIDGE-MINTER-TIMELOCK` (48h)
- 🧯 [Bridge Minter Activation Gate](../../operations/runbooks/Bridge-Minter-Activation-Gate.md) — the cap / rate limit / remote supply accounting / incident runbook / adapter verification gate before Day-2 bridge minter registration
- 🟢 [dToken Requirements Specification](dToken.md) — the token the Core treats as collateral (the counterpart to this document's debt token)
- 🗄 [Multichain (archive)](../../../archive/Multichain.md) — past material that was de-scoped (`MCHN-*` is frozen / out of current scope). The canonical source for the bridge-ready surface is this document's `CORE-BT-*` and the SYS / ADR rows of Product-Overview
