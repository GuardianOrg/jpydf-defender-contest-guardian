# Guardian Additional Production Solidity Audit Handoff

> **Status: PRE-AUDIT — candidate frozen, auditor acceptance pending.** The
> production Solidity endpoint and the matching source, test, build, deployment
> context, provenance, and artifact bundle are fixed below. Kickoff still
> requires Guardian to accept the exact base, head, the full scope or a committed
> reduced SOW, and to acknowledge the known-risk register as an engagement
> input. Guardian may independently assess and report any listed item; work in
> the quoted engagement remains limited to the included hunks and required
> integration context in `SCOPE.md`. Formal risk treatment remains with the
> project's designated risk owner. Known-risk
> disclosure does not restrict Guardian from reporting the same item as a
> vulnerability with an independent severity.

If any scope figure in this handoff differs from [`SCOPE.md`](../../SCOPE.md),
`SCOPE.md` controls.

“Guardian audit” means this external audit engagement. It does not
refer to the protocol's `GUARDIAN_ROLE`.

## Audit Question

Determine whether the 171 changed hunks made to production Solidity after the
second Chain Defenders review introduce vulnerabilities or break the invariants
they touch in code that will be deployed. This is a differential audit between
two immutable `contracts/src` trees, not a two-file Zapper review and not a
whole inherited-Liquity re-audit. The conclusion limits are controlled by
[`SCOPE.md`](../../SCOPE.md#commercial-scope-decision).

## Auditor Access Boundary

Auditor access to `deltaforesight/jpydf-v2` is neither assumed nor required.
Everything project-specific required for review is committed here in English:
both source endpoints, prior reports, the final tests and fixtures, build inputs,
selected deployment code for reproduction only, specifications, provenance,
dependency graph, and artifact identities. Reproduction fetches only the
hash-pinned public dependencies in `BUILD_AND_TEST.md`. No conclusion depends on
opening an issue or pull request in the implementation repository.

## Immutable Identity Chain

| Boundary | Commit or artifact | `contracts/src` tree | Meaning |
| --- | --- | --- | --- |
| First Chain Defenders report | [`jpydf-aug-2026.pdf`](../../evidence/external-audit/jpydf-aug-2026.pdf), SHA-256 `a488541d3204c149adc9d0d7b80f4fa340f71a80f42d5e357899b74112e1b18a` | Not applicable; see `evidence/external-audit/` | Historical first engagement |
| Second Chain Defenders final report | [`jpydf-enhancement-aug-2026-final.pdf`](../../evidence/external-audit/final-2026-08/jpydf-enhancement-aug-2026-final.pdf), SHA-256 `601834e87b3238e5305ec48209e0eef989144c272de9b37118876232e07733c5` | Report names source `469b12652c799085e386151445949f1b1da4eb32` | Four findings `Fixed`, one `Acknowledged` |
| Additional-audit base | `d4122704d08b521d832438c31c0ddccf202fea81` | `417fe3b995f3dec84fd611fcc2f5c3ebd62d5c7a` | Repository endpoint containing the second-review remediation set |
| Final production candidate | `1b453c10e3378390109cf42037a97b7f6de57b9e` | `84476d9086e89580c58918b203f4142ecd839765` | Deployed-code candidate; complete source diff is 25 files, 171 hunks, `+745/-185` |
| Final test tree | same candidate | `65edf44aaad8ee395fa9456151fed25f40a3dfde` | Complete test/fixture tree copied into this repository |

The source-only audit PR contains the complete 25-file, 171-hunk changed-source
differential so the endpoint remains identical to production. The complete
differential is the requested security review; legacy, archive, inheritance,
and cosmetic hunks remain included. The supporting-materials PR is not a
separate review target. Use
[`PRODUCTION_COMPANION_MAPPING.tsv`](../../PRODUCTION_COMPANION_MAPPING.tsv) and
[`scripts/verify-production-companion.sh`](../../scripts/verify-production-companion.sh)
to verify every copied tree/blob against the final source commit.

For SOW sizing, the requested differential is 535 final-side changed code nSLOC,
171 hunks, and `+745/-185` physical lines. The 6,656 final whole-file nSLOC in
the 25 touched paths is surrounding context only: it is not a line-by-line
re-audit request. The exact table, non-scope treatment,
and measurement method are in [`SCOPE.md`](../../SCOPE.md).

The project plans an Ethereum mainnet release during September 2026. It requests
the earliest possible kickoff and, where feasible without reducing scope or
depth, completion of the code review and delivery of the findings report by
**18 September 2026**. Guardian should state the earliest defensible alternative
if that date is not achievable.

The current 25-path, 171-hunk differential is the quotation baseline. If
Guardian's quoted price cannot be approved, the project may request
a narrower scope before kickoff. No reduction takes effect except through the
committed process in [`SCOPE.md`](../../SCOPE.md#commercial-scope-decision), which
also controls required dependency context, residual-risk treatment, and report
wording.

## Chain Defenders Baseline Acceptance

The final enhancement report records M-01, M-02, L-01, and L-02 as `Fixed` and
L-03 as `Acknowledged`. Local findings, patches, reviews, and the final report
are indexed under
[`evidence/external-audit/final-2026-08/`](../../evidence/external-audit/final-2026-08).

The final PDF names source identity `469b1265`; it does not print `d4122704` or
tree `417fe3b9`. The project attests that Chain Defenders checked the second
remediation cycle through repository endpoint `d4122704`, and the local patch
chain makes that relationship reviewable. The PDF alone is not cryptographic
proof of the complete `d4122704` tree, so Guardian must explicitly accept
`d4122704` / `417fe3b9` as the additional-audit base. `Acknowledged` must not be
reported as `Fixed`.

## Current Consolidated Production Remediation Summary

This is the self-contained English rationale for the complete baseline-to-final
differential, including runtime-decimals, oracle-recovery, and 30-hour
normal-redemption changes. Auditors do not need access to `jpydf-v2`.
Known stale phrases in exact copied support translations are superseded by
[`FINAL_PRODUCTION_ENGLISH_AUTHORITY.md`](./FINAL_PRODUCTION_ENGLISH_AUTHORITY.md).
Use [`KNOWN_RISKS_AND_CURRENT_POSITION.md`](./KNOWN_RISKS_AND_CURRENT_POSITION.md)
for final-candidate risks, the current project position, resolved items,
future-change constraints, and the requested Guardian assessment.

### Complete change summary

| Review topic | Final production behavior | Retained boundary / required evidence |
| --- | --- | --- |
| Oracle, JPY/USD, and urgent wind-down | The wstETH branch's normal pricing uses direct stETH/USD. Normal and urgent redemption use `max(stETH/USD, ETH/USD × stETH/ETH)`, then wstETH conversion, shared JPY/USD, and the pricing-available backing ratio. Vault pricing may use live Strategy valuation or a still-fresh bounded cache; unavailable/stale cache fails closed. Urgent redemption exists only after irreversible shutdown and has no oracle-price cache or direct-only fallback. Runtime JPY/USD decimals must match the constructor-pinned value before a fresh or stale-newer round is adopted. | The intended deployment parameter for stETH/ETH is 90,000 seconds and must be read back; the constructor does not hard-code it. A stale-high direct or derived input can underpay redeemers before the threshold. The shared JPY freeze policy is not an absolute 96-hour outage cap. |
| Recoverable oracle pause | Oracle failure is distinct from terminal shutdown. A live recovered normal source permits liquidation, `TCR < SCR` shutdown evaluation, close, collateral addition, and debt repayment before Owner resume. Collateral withdrawal and debt increase remain gated. Owner resume requires valid non-failure returns from the source's normal, redemption, and urgent quote methods in one transaction. Normal redemption has a separate gate over the JPY/USD round and status returned by the current source and may remain unavailable after resume. A price returned with `failure=true` never drives terminal shutdown. | Resume proves neither price continuity nor fresh JPY provenance. Emergency source confirmation retains the 12-hour lifecycle and three proposed-source quote-method calls while bypassing all three deviation guards. |
| Normal-redemption 30-hour gate | For an otherwise successful source quote, normal redemption requires the JPY/USD round used by the current source to have age `< 108,000`. At or above the boundary, or with invalid provenance, this check returns failure without itself latching the BorrowerOperations pause. A concurrent source revert, invalid price, or failure flag still enters normal Proxy failure handling and can latch pause. RedemptionHelper preserves a failed branch's denominator share and refunds unused input. | The age gate does not change borrowing, liquidation, urgent redemption, the provider's 72-hour staleness threshold, or its 24-hour freeze episode. A same-value heartbeat can refresh `updatedAt` while the Forex market is closed, so round age is not proof of fresh price discovery. |
| PriceFeedProxy lifecycle | Construction requires fresh provenance and a valid urgent path. Confirmation rejects invalid provenance but may accept aged provenance without updating the redemption cache. The direct `source()` marker is a one-level proxy-shaped screen only. | Semantic forwarding and cycles can be excluded only by an independently reviewed dependency graph. The source-level graph is included; exact deployment addresses/code hashes/routing remain launch evidence. No callback latch was added. Source replacement has a separate 12-hour delay from the production governance Timelock. |
| Vault solvency | Deposit, redeem, and claim require pre-state full backing. Raw underlying may cover liabilities without Strategy reads; otherwise only successfully read live Strategy values count and unavailable Strategies count zero. A nonzero Strategy allocation must leave the Vault fully backed or revert atomically. | No-op allocation and recovery functions remain open; backstop and registered-Strategy recovery remain available. Chain Defenders `L-03` (partial recovery does not renew the full-valuation cache timestamp) is a separate `Acknowledged` boundary. |
| Reserved-branch activation | `finalizeRiskParams` is dedicated-role, one-shot, and atomic across AddressesRegistry, BorrowerOperations, and TroveManager. Child synchronization failure rolls back the transaction, reserved parameters are validated at finalization, and DFStabilityPool rejects deposits before finalization. | A finalized mistake is permanent. Deployment scripts and initial active-branch inputs are outside this review; the project owns their launch validation. The runbook must validate the real source, backing, Strategy state, exact parameters, and wiring before reserved finalization; the cap opens last. |
| Production parameters and identity | `MIN_DEBT = 100_000e18` is the open/adjust entire-debt floor including the upfront fee and is also used by repayment clamping, normal-redemption zombification, and zombie reactivation. `SP_YIELD_SPLIT = 75%`. JPYdf name, symbol, Permit, and EIP-712 identity are production readback properties. | MIN_DEBT is not a universal post-operation floor: urgent residuals and full close retain distinct behavior. The lower threshold also needs economic/list/gas capacity evidence; exact-boundary tests alone are insufficient. `JpydfToken.sol` is base/head byte-identical. |
| Zapper | Only the immutable referral manager may update Lido attribution; zero disables it. Under canonical Lido stETH/wstETH identity and `submit(address)` semantics, referral changes cannot affect funds, receiver, collateral, debt, Vault accounting, minimum output, refund, or atomicity. | The active CollateralYieldZapper change and archived Sky constructor forwarding are reviewed. Deployment must prove the canonical addresses, runtime identity, and immutable binding. |

### Deliberately retained boundaries

- stETH/ETH stays at `90_000` seconds. Increasing it to 48 hours enlarges the
  stale-high redemption window; an absolute cap combined with fail-closed logic
  merely moves the pause boundary. Direct-only continuation would be a policy
  change to fail-open and is not accepted.
- The 30-hour check protects only normal redemption. During a JPY/USD failure, a
  still-policy-valid stale rate can contribute to `TCR < SCR`; after irreversible
  shutdown, urgent redemption can continue against that result. A readable round
  that simply ages gives a conditional `[30h, 96h)` interval. An invalid response
  observed earlier can start a 24-hour freeze and expire sooner. Before expiry,
  a valid monotonically newer but already-stale round resets and re-anchors the
  episode, so repetition can extend urgent-path stale-FX exposure beyond 96 hours
  from the original fresh observation. After expiry only a fresh response clears
  the latch. Separately, a same-value heartbeat can keep `updatedAt` younger than
  30 hours while the Forex market is closed; round age does not prove fresh price
  discovery. The project has not formally accepted either residual condition.
  See [`KNOWN_RISKS_AND_CURRENT_POSITION.md`](./KNOWN_RISKS_AND_CURRENT_POSITION.md)
  and the [reproducible data and model appendix](./JPYUSD_MARKET_HOURS_RISK_ANALYSIS.md).
- `PriceFeedProxy.source()` inspection is not proof of acyclicity. An address or
  codehash in isolation, the lifecycle delay, and validation calls also do not prove
  it. The bound graph and trace procedure in
  [`FINAL_PRODUCTION_DEPENDENCY_GRAPH.md`](./FINAL_PRODUCTION_DEPENDENCY_GRAPH.md)
  are the sole circularity evidence. This package records the source topology;
  production addresses, code hashes, bindings, mutable routing, and owners must
  be attached at deployment before the proof is complete.
- No transient callback latch was added to the permanent proxy. Engineering
  recommends retaining this Low-severity boundary under the 12-hour lifecycle
  and human review; Guardian assessment and formal risk-owner treatment remain
  pending.
- Active-branch risk validation lives in the out-of-scope `DeployLiquity2`;
  reserved-branch validation lives in the included
  `AddressesRegistry.finalizeRiskParams`. The project accepts validation of
  initial active parameters and wiring as a launch responsibility. Guardian is
  not asked to review the deployment script or certify those launch inputs.

### Deployment and script context outside review

Deployment scripts, parameter selection, production wiring, role handover,
on-chain readbacks, and alert delivery are not review targets. Where a source
conclusion depends on a production binding—such as PriceFeedProxy wiring, Lido
identity, or the 90,000-second stETH/ETH threshold—the project must prove that
binding separately. [`EVIDENCE_CHECKLIST.md`](./EVIDENCE_CHECKLIST.md) records
those project-owned checks.

## Scope And Reproduction References

- [`SCOPE.md`](../../SCOPE.md) controls the included changes,
  required unchanged context, non-scope, size, and schedule.
- [`FINAL_PRODUCTION_HUNK_PROVENANCE.tsv`](../../FINAL_PRODUCTION_HUNK_PROVENANCE.tsv)
  identifies every changed source hunk and its rationale.
- [`SOURCE_MANIFEST.md`](./SOURCE_MANIFEST.md) identifies copied source, tests,
  build inputs, and public dependencies.
- [`FINAL_PRODUCTION_ARTIFACTS.tsv`](../../FINAL_PRODUCTION_ARTIFACTS.tsv) and
  [`FINAL_PRODUCTION_STORAGE_LAYOUTS.tsv`](../../FINAL_PRODUCTION_STORAGE_LAYOUTS.tsv)
  record bytecode, ABI, and storage-layout identities.
- [`BUILD_AND_TEST.md`](./BUILD_AND_TEST.md) contains the public reproduction and
  verification commands.

## Kickoff Checklist

- [x] Final production commit and `contracts/src` tree are immutable.
- [x] Source-only audit snapshot exactly matches the final production tree.
- [x] Supporting tests, build inputs, and documents use the same final identity.
- [x] Every changed file/hunk has a review classification and
      recorded rationale.
- [x] ABI, storage, compiler/dependencies, and bytecode identities are recorded.
- [x] Current 25-path / 171-hunk review boundary, 535 changed-code nSLOC,
      and 18 September 2026 requested report date are recorded.
- [ ] Both coordinated audit-repository PRs are merged.
- [ ] Guardian accepts the exact base and head and either the 171-hunk scope
      or a mutually accepted reduced written SOW, and acknowledges the known-risk
      register as review input. Guardian remains free to report any listed risk
      as a vulnerability. The project separately records formal risk treatment.
- [ ] Guardian confirms the earliest kickoff and achievable report date.
