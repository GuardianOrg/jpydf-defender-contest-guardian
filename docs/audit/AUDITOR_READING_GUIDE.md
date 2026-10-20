# Auditor Reading Guide

Follow the five-item **Start here** order in [`README.md`](../../README.md). This
page only routes topic-specific material. If any document differs,
[`SCOPE.md`](../../SCOPE.md) is the authoritative statement of work.

## Consult when relevant

- [`GUARDIAN_ADDITIONAL_AUDIT_HANDOFF.md`](./GUARDIAN_ADDITIONAL_AUDIT_HANDOFF.md)
  explains the prior-audit base and summarizes the changed behavior.
- [`FINAL_PRODUCTION_DEPENDENCY_GRAPH.md`](./FINAL_PRODUCTION_DEPENDENCY_GRAPH.md)
  is required for PriceFeedProxy and oracle dependency analysis.
- [`FINAL_PRODUCTION_ENGLISH_AUTHORITY.md`](./FINAL_PRODUCTION_ENGLISH_AUTHORITY.md)
  corrects known stale statements in copied support documents.
- [`NORMAL_REDEMPTION_30H_GATE_RATIONALE.md`](./NORMAL_REDEMPTION_30H_GATE_RATIONALE.md)
  explains why the extra JPY age gate applies only to normal redemption, with
  a collateral-overpayment example and questions for Guardian.
- [`JPYUSD_MARKET_HOURS_RISK_ANALYSIS.md`](./JPYUSD_MARKET_HOURS_RISK_ANALYSIS.md)
  provides the data provenance, reproduction method, economic model, and
  pending treatment conditions behind `KR-01`.
- [`FINAL_PRODUCTION_ARTIFACTS.tsv`](../../FINAL_PRODUCTION_ARTIFACTS.tsv) and
  [`FINAL_PRODUCTION_STORAGE_LAYOUTS.tsv`](../../FINAL_PRODUCTION_STORAGE_LAYOUTS.tsv)
  record bytecode, ABI, and storage-layout identities.
- [`EVIDENCE_CHECKLIST.md`](./EVIDENCE_CHECKLIST.md) separates audit-package
  readiness from project-owned deployment and launch checks. Launch checks are
  not Solidity review targets unless a revised SOW says otherwise.

Maintainer pre-audit notes, cleanup reviews, old scope deltas, and workflow
documents are optional provenance. They are not external-audit results and do
not change the SOW.

## Review rule

Review all 171 changed hunks and the unchanged callers, inherited behavior,
dependencies, routing, state assumptions, and external-return semantics needed
to assess them. Do not treat unrelated functions in an unchanged file as a
whole-file review target.

`DFUSDCPriceFeed.sol` is an important example: its source blob is unchanged, but
its runtime behavior changes through the included `DFPriceFeedBase` inheritance,
so that inherited behavior must be examined.

Tests, tools, specifications, deployment scripts, and operational documents are
supporting material, not review targets. Their presence does not prove production
addresses, parameters, roles, alert delivery, or deployment correctness.
