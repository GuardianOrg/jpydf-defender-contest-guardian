# Source Of Truth

## Current Audit Authority

The current additional-audit authority is the English package rooted at:

- [`GUARDIAN_ADDITIONAL_AUDIT_HANDOFF.md`](./GUARDIAN_ADDITIONAL_AUDIT_HANDOFF.md)
  for the complete audit question and retained boundaries;
- [`SCOPE.md`](../../SCOPE.md) for included hunks and their containing paths, current
  nSLOC, integration-review depth, explicit non-scope treatment, and requested
  schedule;
- [`KNOWN_RISKS_AND_CURRENT_POSITION.md`](./KNOWN_RISKS_AND_CURRENT_POSITION.md)
  for final-candidate known risks, current project positions, previously
  remediated items, and future-change constraints;
- [`JPYUSD_MARKET_HOURS_RISK_ANALYSIS.md`](./JPYUSD_MARKET_HOURS_RISK_ANALYSIS.md)
  for the reproducible observations, model, assumptions, and pending treatment
  behind the JPY/USD market-hours risk;
- [`SOURCE_MANIFEST.md`](./SOURCE_MANIFEST.md) for immutable source/test identity;
- [`FINAL_PRODUCTION_ENGLISH_AUTHORITY.md`](./FINAL_PRODUCTION_ENGLISH_AUTHORITY.md)
  for audit-local English precedence and corrections to retained support text;
- [`FINAL_PRODUCTION_HUNK_PROVENANCE.tsv`](../../FINAL_PRODUCTION_HUNK_PROVENANCE.tsv)
  for every changed production-source file; and
- the selected current specifications and launch policies under `docs/en`.

| Boundary | Commit | `contracts/src` tree |
| --- | --- | --- |
| Chain Defenders remediation base | `d4122704d08b521d832438c31c0ddccf202fea81` | `417fe3b995f3dec84fd611fcc2f5c3ebd62d5c7a` |
| Final production candidate | `1b453c10e3378390109cf42037a97b7f6de57b9e` | `84476d9086e89580c58918b203f4142ecd839765` |

This boundary includes all surviving runtime-decimals validation,
recovery/resume, and 30-hour normal-redemption changes. The package separately
includes the later cleanup delta and evidence that removed endpoints are absent;
base/head-identical `ActivePool.sol` correctly has no surviving source hunk.
Earlier audit narratives do not override it.

The retained
`docs/en/engineering/guides/Contract-Audit-Scope-And-nSLOC.md` is historical for
this engagement. Its 5,225 / 13,272 counts and future-tense finalization language
predate the frozen final candidate and must not be used for the current SOW.
`SCOPE.md` is the sole current sizing authority.

## Language Boundary

Guardian reviewers are expected to use English only. Exact candidate-derived
English context is independently mapped in `PRODUCTION_COMPANION_MAPPING.tsv`.
The audit-root authority and the explicit current-scope pointers described below
are audit-local and take precedence.

English files listed in that mapping are exact candidate-derived context. The
audit-root authority documents above expressly correct the known stale phrases
that remain in those exact support translations. Other English files retained
from earlier handoffs are historical/contextual and do not override either set.
The superseded banner in the historical nSLOC guide and the current-scope pointer
in `docs/en/protocol/product/Product-Overview.md` are deliberate audit-local
edits, so those two files are not represented as exact candidate blobs in the
mapping.
In particular, the requirements-ledger phrase “maximum 96h window” and the
deployment-runbook phrase “accept shutdown near age 96h” are retained only to
preserve their mapped source blobs. The corrected `jpyFrozenSince` episode rules
and exact phrase-level errata are in
[`FINAL_PRODUCTION_ENGLISH_AUTHORITY.md`](./FINAL_PRODUCTION_ENGLISH_AUTHORITY.md#exact-retained-text-errata).

Japanese documents retained in this repository are historical provenance from
earlier handoffs. They were not all refreshed for this final candidate and must
not override the current English package. If a relevant English statement is
missing or conflicts with the final Solidity, treat that as a handoff defect and
ask the maintainers to correct the English package before relying on it.

## Current English Entry Points

| Topic | Document |
| --- | --- |
| Product/risk parameters | [`docs/en/Parameters.md`](../en/Parameters.md) |
| Product overview | [`docs/en/protocol/product/Product-Overview.md`](../en/protocol/product/Product-Overview.md) |
| Oracle and proxy behavior | [`docs/en/protocol/product/spec/Oracle.md`](../en/protocol/product/spec/Oracle.md) |
| Liquity core behavior | [`docs/en/protocol/product/spec/Liquity-v2-Core-Spec.md`](../en/protocol/product/spec/Liquity-v2-Core-Spec.md) |
| Vault | [`docs/en/protocol/product/spec/CollateralVault.md`](../en/protocol/product/spec/CollateralVault.md) |
| dToken | [`docs/en/protocol/product/spec/dToken.md`](../en/protocol/product/spec/dToken.md) |
| Interest routing | [`docs/en/protocol/product/spec/InterestRouter.md`](../en/protocol/product/spec/InterestRouter.md) |
| Strategies | [`docs/en/protocol/product/spec/strategies/Strategy.md`](../en/protocol/product/spec/strategies/Strategy.md) |
| Zappers | [`docs/en/protocol/product/spec/Zapper.md`](../en/protocol/product/spec/Zapper.md) |
| Requirements evidence | [`docs/en/engineering/verification-ledgers/Requirements-Verification-Ledger.md`](../en/engineering/verification-ledgers/Requirements-Verification-Ledger.md) and [`Core-Requirements-Verification-Ledger.md`](../en/engineering/verification-ledgers/Core-Requirements-Verification-Ledger.md) |
| Frontend/ops data and alerts | [`docs/en/engineering/verification-ledgers/Frontend-Data-Source-Ledger.md`](../en/engineering/verification-ledgers/Frontend-Data-Source-Ledger.md) and [`Incident-Notification-Policy.md`](../en/contributors/deltaforesight/operations/Incident-Notification-Policy.md) |
| Deployment configuration | [`docs/en/engineering/guides/Deployment-Configuration-Spec.md`](../en/engineering/guides/Deployment-Configuration-Spec.md) |
| Production Timelock | [`docs/en/protocol/launch/gates/Mainnet-Timelock-Deploy-Policy.md`](../en/protocol/launch/gates/Mainnet-Timelock-Deploy-Policy.md) and [`Mainnet-Timelock-Deploy-Runbook.md`](../en/protocol/launch/gates/Mainnet-Timelock-Deploy-Runbook.md) |
| Safe and role gate | [`docs/en/protocol/launch/gates/Mainnet-Safe-Role-Assignment-Gate.md`](../en/protocol/launch/gates/Mainnet-Safe-Role-Assignment-Gate.md) |
| Launch readiness | [`docs/en/protocol/launch/gates/Mainnet-Initial-Configuration-Checklist.md`](../en/protocol/launch/gates/Mainnet-Initial-Configuration-Checklist.md), [`Mainnet-Launch-Risk-Gate.md`](../en/protocol/launch/gates/Mainnet-Launch-Risk-Gate.md), and [`Mainnet-Launch-Operation-Gate.md`](../en/protocol/launch/gates/Mainnet-Launch-Operation-Gate.md) |

## Evidence Interpretation

- `source-snapshot/contracts/src` and `source-snapshot/contracts/test` are exact
  complete final trees, not curated subsets.
- Scripts, tools, configuration, and documents are selected reproduction/context
  material and are not part of the changed production Solidity review merely
  because they are present.
- Prior PDFs, scope deltas, findings, patches, and dated reviews under `evidence`
  remain valid historical evidence for their pinned identities.
- `audit-report.md` is a maintainer-authored adversarial pre-audit input. It
  exposes challenge cases and retained risks but is not an external-auditor
  finding or disposition.
- The imported 2026-08-29 business summary ends at `c9206af5`; it is historical
  and omits the later decimals, recovery, 30-hour, and cleanup changes.
- Generated manifests, runtime hashes, fork evidence, Safe signatures, roles,
  and verified alert delivery are launch evidence and remain pending unless a
  separate record explicitly proves them.
