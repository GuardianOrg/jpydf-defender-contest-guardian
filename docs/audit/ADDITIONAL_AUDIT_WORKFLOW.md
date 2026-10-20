# Additional Solidity Differential Workflow

This document defines the handoff mechanics for the final production
differential. It does not change the scope in [`SCOPE.md`](../../SCOPE.md).

## Immutable Boundaries

| Boundary | Commit | `contracts/src` tree |
| --- | --- | --- |
| Chain Defenders remediation base | `d4122704d08b521d832438c31c0ddccf202fea81` | `417fe3b995f3dec84fd611fcc2f5c3ebd62d5c7a` |
| Final production candidate | `1b453c10e3378390109cf42037a97b7f6de57b9e` | `84476d9086e89580c58918b203f4142ecd839765` |
| Final tests | same final commit | `65edf44aaad8ee395fa9456151fed25f40a3dfde` |

The complete final source differential and requested review scope is 25 files,
171 hunks, and `+745/-185`. It includes the
earlier remediation and all surviving runtime-decimals, recovery/resume, and
30-hour redemption changes. The companion also carries the later cleanup delta
and endpoint-absence evidence; base/head-identical `ActivePool.sol` correctly
has no surviving source hunk.

## Coordinated Audit PRs

The handoff uses two consecutive PRs:

1. A source-only PR replaces only `source-snapshot/contracts/src` with the exact
   final production tree. Its Files changed view shows all 25 source-diff paths;
   `SCOPE.md` includes all 171 hunk rows.
2. A companion PR on top supplies the exact complete test tree, Foundry and
   dependency inputs, selected deploy/tool closure, current English context,
   provenance, dependency graph, and artifact identities.

Splitting the PRs keeps the production Solidity differential easy to inspect. It does
not exclude companion-covered changes or later remediation from the audit.
Both PRs form one package and must be merged consecutively before kickoff.

## Materialize From Source

Maintainers create a detached source checkout and initialize recursive
submodules. Do not use bare `git archive`; gitlinks become empty directories.

```sh
git clone https://github.com/deltaforesight/jpydf-v2.git jpydf-v2-source
git -C jpydf-v2-source checkout --detach \
  1b453c10e3378390109cf42037a97b7f6de57b9e
git -C jpydf-v2-source submodule update --init --recursive
```

The candidate-derived companion mapping is recorded in
[`PRODUCTION_COMPANION_MAPPING.tsv`](../../PRODUCTION_COMPANION_MAPPING.tsv).

## Verify

Auditors can verify committed hashes without private-source access:

```sh
./scripts/verify-production-companion.sh
```

Maintainers additionally compare the package with the detached source checkout:

```sh
./scripts/verify-solidity-snapshot.sh \
  /path/to/jpydf-v2-source \
  1b453c10e3378390109cf42037a97b7f6de57b9e

./scripts/verify-production-companion.sh \
  /path/to/jpydf-v2-source \
  1b453c10e3378390109cf42037a97b7f6de57b9e
```

The checks require exact source/test trees, exact mapped blobs, initialized
non-empty dependencies in source-backed mode, the executable deploy wrapper,
and absence of all production pilot-overlay symbols. Build, test, size, rollback,
and artifact commands are in [`BUILD_AND_TEST.md`](./BUILD_AND_TEST.md).

## Kickoff Sequence

1. Commit and verify the source-only PR.
2. Commit and verify the companion PR against the same final identity.
3. Obtain Guardian acceptance of the exact base, head, and SOW, plus
   acknowledgment of the known-risk register as review input. Independent
   assessment is requested engagement work; the designated Product / Protocol
   Risk owner records formal risk treatment.
4. Merge the source PR, then the companion PR, without altering the source tree.
5. Re-run the committed hash-only verifier from the resulting audit branch.

Any source change after acceptance creates a new immutable head, regenerated
artifacts and provenance, and an explicit auditor scope decision.
