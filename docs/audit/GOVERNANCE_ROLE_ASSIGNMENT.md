# Governance Role Assignment Summary

This is the English audit-facing summary for the current governance / Safe /
Timelock holder topology. Production deployment state remains a launch-time
readback; this document records the intended configuration.

## Source Documents

| Topic | Source |
| --- | --- |
| Parameter authority | [`docs/en/Parameters.md`](../en/Parameters.md) |
| Timelock deploy policy | [`docs/en/protocol/launch/gates/Mainnet-Timelock-Deploy-Policy.md`](../en/protocol/launch/gates/Mainnet-Timelock-Deploy-Policy.md) |
| Timelock deploy runbook | [`docs/en/protocol/launch/gates/Mainnet-Timelock-Deploy-Runbook.md`](../en/protocol/launch/gates/Mainnet-Timelock-Deploy-Runbook.md) |
| Safe / role assignment gate | [`docs/en/protocol/launch/gates/Mainnet-Safe-Role-Assignment-Gate.md`](../en/protocol/launch/gates/Mainnet-Safe-Role-Assignment-Gate.md) |

## Holder Topology

| Holder | Type | Main roles | Expected threshold |
| --- | --- | --- | --- |
| Admin multisig | high-quorum Safe | `DF_WRITEOFF`, `DF_PRICE_FEED_OWNER`, Timelock `PROPOSER`, Timelock `EXECUTOR`, Timelock `CANCELLER`, `DF_BRIDGE_ADMIN` | `3-of-5` |
| Timelock | Fresh production OZ v4.9.5 TimelockController | `DF_TIMELOCK`, `DF_STRATEGY_UPGRADER`, Vault `DEFAULT_ADMIN_ROLE`, Vault `GOV_ROLE`, dToken owner, InterestRouter owner, Strategy upgrader | `minDelay = 43200` |
| Guardian | emergency Safe | `DF_GUARDIAN`, `DF_STRATEGY_OWNER`, Vault emergency pause / disable roles, Strategy owner | `2-of-5` |
| Allocator | Safe/manual or hardened bot signer | `DF_ALLOCATOR` / Vault `ALLOCATOR_ROLE` | depends on operation mode |
| Treasury | Safe | `DF_TREASURY` | `3-of-5` |
| PIL recipient | Safe or accounting contract | `DF_INTEREST_ROUTER_RECIPIENT` | `3-of-5` if Safe |
| Deployment / Ops finance Safe | company-only finance Safe | bootstrap borrower owner, LP owner, SP seed source owner | `2-of-3` |

Protocol Safes share the A-E signer control-domain set described in the Safe
threshold policy. Deployment / Ops finance uses a separate F-H signer set and
must not share signer address, seed, or control domain with the protocol signer
set.

## Timelock Policy

The production GOV Timelock is deployed before the protocol deploy and passed
into `jpydf-v2` as `DF_TIMELOCK`. It must be a fresh deployment distinct from
the persistent pilot / canary Timelock, whose delay remains 300 seconds.

Required Timelock state:

- OpenZeppelin `TimelockController` v4.9.5 or reviewed equivalent.
- OpenZeppelin Contracts version is v4.9.5.
- `getMinDelay() == 43200`.
- `PROPOSER_ROLE == Admin multisig`.
- `EXECUTOR_ROLE == Admin multisig`.
- `CANCELLER_ROLE == Admin multisig`.
- `EXECUTOR_ROLE` is not granted to `address(0)`.
- Timelock itself is the only admin from construction.
- Constructor `admin == address(0)`; no deployer-admin grant or later renounce
  transaction exists.

`VerifyDFGovernanceHandover` does not prove these Timelock internals. Auditors
should require the external Timelock deploy evidence and on-chain readback.

## Accepted Risks

### No Independent Canceller

The same Admin multisig holds Timelock proposer, executor, and canceller roles.
If the Admin multisig / proposer authority is compromised, no separate holder can
cancel the malicious proposal during the 12h delay.

This is accepted through:

- `3-of-5` Admin Safe threshold;
- dedicated signing environment and host-device evidence;
- public 12h delay monitoring and evacuation path;
- no open executor.

### Admin Multisig Concentration

The Admin multisig intentionally also holds writeoff, PriceFeedProxy owner, and
bridge admin. These are not routed through the Timelock because:

- writeoff / valuation incident actions need high-quorum immediate execution;
- PriceFeedProxy already has an internal 12h source timelock, so adding the GOV
  Timelock would create double delay;
- bridge admin is dormant at deployment, with zero bridge minters in the current
  package and internal bridge minter proposal delay.

### Allocator Hardened Bot Signer

`DF_ALLOCATOR` may be a hardened bot signer only if all controls are evidenced:

- KMS / HSM / managed custody;
- no plaintext private key handling;
- minimal IAM / function scope;
- audit logs;
- gas / balance cap;
- bounded positive `allocateMaxMove`;
- positive `allocatorCooldown` unless explicitly approved;
- Guardian `pauseAllocation()` readiness;
- Timelock-based revoke / replacement procedure.

If any control is missing, operate with Safe/manual allocation or mark allocator
bot activation as No-Go.

## Evidence Required

The Safe / role assignment evidence package should include:

- `holder-address-book.csv`
- `safe-thresholds.md`
- `host-device-bindings.md`
- `allocator-signer-policy.md`
- `role-assignment-matrix.csv`
- `env-manifest-diff.md`
- `onchain-role-snapshot.json`
- `frontend-ops-operator-addresses.md`
- `bridge-dormant-evidence.md`
- `dry-run-calldata-review.md`
- `secret-hygiene.md`
- `no-go-summary.md`

Public evidence should not include raw signer lists, Safe nonce, private keys,
seed phrases, raw RPC URLs, API keys, host device raw identifiers, hardware key
serials, or personal signer details.
