# Source Manifest

## Additional production audit identity

| Item | Value |
| --- | --- |
| Upstream source origin | `deltaforesight/jpydf-v2` (provenance only; auditor access not required) |
| Chain Defenders remediation base | `d4122704d08b521d832438c31c0ddccf202fea81` |
| Base `contracts/src` tree | `417fe3b995f3dec84fd611fcc2f5c3ebd62d5c7a` |
| Audit-repository commit preserving the base tree | `b5265f311abc524683561b79792eab2900823fa9` |
| Final production source commit | `1b453c10e3378390109cf42037a97b7f6de57b9e` |
| Final `contracts/src` tree | `84476d9086e89580c58918b203f4142ecd839765` |
| Complete final source differential | 25 files, 171 hunks, `+745/-185` |
| Requested security review | 25 paths, 171 hunks, `+745/-185` |
| Final `contracts/test` tree | `65edf44aaad8ee395fa9456151fed25f40a3dfde` |
| Compiler / EVM | Solc 0.8.24 / Cancun, optimizer 200 |

On 2026-08-31, the latest upstream `develop` head was independently fetched at
`aac9cf2ffe53cfcf5ffdba8af33e2ac09bb199ac`. It has the same
`contracts/src` tree `84476d90`, the same `contracts/test` tree `65edf44a`, and
no change from the pinned candidate in `contracts/script`, `foundry.toml`,
`foundry.lock`, or `remappings.txt`. The pinned candidate is therefore still
the latest production Solidity and matching pinned build/test input. Later
upstream changes are limited to documentation, CI, frontend/ops, and
infrastructure. The latest JPY/USD market-hours analysis is incorporated into
the English known-risk register and its reproducible supporting appendix in this
repository.

All 25 changed source paths are committed exactly so the snapshot matches the
production tree. `SCOPE.md` includes all 171 hunks.
The repository also contains the matching test tree and supporting build and
documentation material.

The current English audit authority is
[`GUARDIAN_ADDITIONAL_AUDIT_HANDOFF.md`](./GUARDIAN_ADDITIONAL_AUDIT_HANDOFF.md).
It includes the earlier remediation themes and later runtime-decimals,
oracle-recovery, and 30-hour normal-redemption changes.

## Committed snapshot contents

The audit package contains:

- exact final production Solidity under `source-snapshot/contracts/src`;
- the complete exact final test/fixture tree under
  `source-snapshot/contracts/test`;
- exact final Foundry configuration, remappings, and dependency lock;
- exact candidate Slither configuration and Python requirement pins;
- `DeployLiquity2.s.sol` and the transitive script files required to compile the
  final tests;
- the rollback, manifest, and native-ETH tools required by the recorded commands,
  plus their standalone package lock;
- the exact initial-mainnet branch manifest at both the audit-root and snapshot-local
  paths used by specifications and Foundry filesystem permissions;
- copied English protocol documents plus clearly identified current scope and
  correction documents; and
- prior Chain Defenders reports, findings, patches, and review evidence.

The artifact manifests cover 35 concrete artifacts and 26 stateful layouts.
They include all 34 standard-bytecode changes and all 18 metadata-free
executable changes, including five byte-identical leaf PriceFeeds whose inherited
ABI/runtime changed. Sixteen additional rows expose CBOR-metadata-only changes;
JpydfToken is the sole fully unchanged artifact retained as identity context.

[`PRODUCTION_COMPANION_MAPPING.tsv`](../../PRODUCTION_COMPANION_MAPPING.tsv) records
the source path, audit path, and exact Git blob/tree for the complete source and
test trees and every selected/refreshed candidate-derived build, deploy, tool,
configuration, and English-context item. Other audit-repository material
outside that ledger is not asserted to match the final candidate.
Scope and correction documents created for this audit are intentionally outside
the candidate-blob mapping and identify themselves as such.
`scripts/verify-production-companion.sh` validates the ledger in a clean audit
checkout and optionally against a detached upstream-source checkout.
`scripts/verify-final-hunk-provenance.mjs` checks all 171 structural hunk rows
from the two committed source trees.

## Public dependency pins

| Dependency | Commit |
| --- | --- |
| forge-std | `726a6ee5fc8427a0013d6f624e486c9130c0e336` |
| OpenZeppelin Contracts | `bd325d56b4c62c9c5c1aff048c37c6bb18ac0290` |
| Solady | `362b2efd20f38aea7252b391e5e016633ff79641` |
| Liquity V2 governance | `b880481d701d2b07236f2e04842c79b4fe77e5fd` plus recursive submodules |
| OpenZeppelin Contracts Upgradeable | `2d081f24cac1a867f6f73d512f2022e1fa987854` |

Vendored dependency directories are not committed. Installation commands are
in [`BUILD_AND_TEST.md`](./BUILD_AND_TEST.md).

## Curated exclusions

The audit package intentionally excludes:

- `contracts/lib`, `node_modules`, `out`, `cache`, `broadcast`, generated ABI,
  and full private-repository snapshots;
- `.env` files, RPC credentials, signer/private-key material, and unredacted
  deployment evidence;
- generated production/canary manifests and runtime readbacks;
- unrelated operational utilities and scripts not needed by the audit commands.

The production Solidity and full test trees are not curated subsets: their
tree identities are exact. Supporting script, tool, and document selections are
curated; every copied candidate-derived item used by the recorded commands is
mapped. Other repository context is outside that exact-candidate assertion.

## Identity verification

Auditors without access to the upstream repository run:

```sh
./scripts/verify-production-companion.sh
```

Maintainers additionally run:

```sh
./scripts/verify-solidity-snapshot.sh \
  /path/to/jpydf-v2-at-final-commit \
  1b453c10e3378390109cf42037a97b7f6de57b9e

./scripts/verify-production-companion.sh \
  /path/to/jpydf-v2-at-final-commit \
  1b453c10e3378390109cf42037a97b7f6de57b9e
```

The source checkout must be detached at the exact commit with initialized,
non-empty recursive submodules. A branch name or Git archive is insufficient;
Git archives omit gitlink contents.

## Evidence policy

Deployment manifest hashes, pinned fork blocks, on-chain runtime hashes, Safe
threshold/signers, roles, and handover readbacks remain launch evidence. Record
them without secrets and do not treat configuration existence as verified alert
delivery or on-chain execution. Source-audit completion does not by itself
authorize production launch.
