# Maintainer Scope Triage — 2026-08-31

> **Superseded for current scope on 2026-09-03:** Guardian's submitted inventory
> is now the quotation baseline, so all 25 paths and 171 hunks are included.
> Current [`SCOPE.md`](../../../SCOPE.md) controls; this file remains historical
> evidence of the earlier proposal.

> This is a pre-kickoff differential-scope decision, not an external audit
> result and not a claim that excluded code is safe.
> If any scope figure here differs from `SCOPE.md`, `SCOPE.md` controls.

## Outcome

The complete immutable source differential remains 25 files, 171 hunks, and
`+745/-185`. The requested security review is narrowed to **22 paths, 164
review-relevant hunks, `+713/-181` physical lines, and 510 final-side changed
code nSLOC**.

The 6,124 final whole-file nSLOC associated with those 22 paths is surrounding
context only. It is not the changed-line count, the SOW boundary, or a request
for a line-by-line re-audit of inherited Liquity files.

## Boundary and history

| Boundary | Identity |
| --- | --- |
| Chain Defenders remediation base | `d4122704d08b521d832438c31c0ddccf202fea81`, `contracts/src` tree `417fe3b995f3dec84fd611fcc2f5c3ebd62d5c7a` |
| Final production candidate | `1b453c10e3378390109cf42037a97b7f6de57b9e`, `contracts/src` tree `84476d9086e89580c58918b203f4142ecd839765` |
| Audit-repository diff | `b5265f311abc524683561b79792eab2900823fa9..2725216e0407a0ef4599e359a04094ae5f322624` |

The base is the repository endpoint through which the project states the second
Chain Defenders remediation cycle was reviewed. This engagement asks Guardian
to review the security-relevant production changes after that endpoint. Tests,
specifications, prior reports, build inputs, tools, and deployment-script import
closure are supplied as unpriced evidence; deployment scripts and launch
configuration are not review targets.

## Exclusions adopted

Every row in `FINAL_PRODUCTION_HUNK_PROVENANCE.tsv` remains in scope except the
following exact hunk IDs.

| Exclusion | Type | Evidence and rationale | Lost current-production assurance |
| --- | --- | --- | --- |
| `StabilityPool.sol`: `H-66144cfadce8c49f68c8`, `H-4ddd64b7487f7ad501a2`, `H-1edff495755bd1dca53e` | Conditional | Production creates `DFStabilityPool`; no production source or script imports or creates the legacy contract. Only `RiskParamsFinalization.t.sol` instantiates it for parity. | None. Re-activation of the legacy implementation requires review. |
| `PriceFeeds/CompositePriceFeed.sol`: `H-8080a4dda91cc5466470` | Conditional | Active `DFWstETHPriceFeed` overrides the new urgent method and never calls `super`; only archived sUSDS inherits it. | None for active feeds. Archived/future composite-feed assurance is excluded. |
| `PriceFeeds/MainnetPriceFeedBase.sol`: `H-af9389d85c876e68b4c6` | Conditional | All callers of the legacy terminal-switch wrapper are archived DFWBTC/sUSDS feeds. Active recovery hunks in the same base remain included. | None for active feeds. Archived-feed compatibility is excluded. |
| `TroveManager.sol`: `H-3f2ed8ff86c05ed44e60` | Clean | Cosmetic comment consolidation unrelated to a behavior change; zero Solidity code nSLOC and no runtime, ABI, or storage effect. | None. |
| `Zappers/archive/SkyUsdcSUsdsYieldZapper.sol`: `H-cdbd3091976837699ca1` | Conditional | Mechanical constructor forwarding required after the active parent signature changed. No production source or deployment path imports or creates it. | None. Re-activation of the archived route requires review. |

Only the comment hunk is unconditionally clean. The other six are conditional
on the frozen production topology, archive status, or override relationship and
remain mandatory reading/build context where relevant. The exclusions total
seven hunks, `+32/-4` physical lines, and 25 final-side
changed code nSLOC. Three paths leave the direct review set; MainnetPriceFeedBase
and TroveManager remain because their other hunks are production-relevant.

## Material scope retained

The triage intentionally retains:

- PriceFeedProxy lifecycle, three price paths, recovery/resume, runtime decimals,
  JPY provenance/freeze episodes, the 30-hour redemption gate, and all active
  feed consumers;
- DFWstETH direct/derived pricing and urgent wind-down;
- RedemptionHelper failure share and refund accounting;
- CollateralVault confirmed-conservative full-backing gates;
- reserved-branch one-shot risk synchronization across AddressesRegistry,
  BorrowerOperations, and TroveManager, plus the `DFStabilityPool`
  pre-finalization gate;
- `MIN_DEBT = 100_000e18` entire-debt boundaries;
- active CollateralYieldZapper referral/native-ETH behavior; and
- all changed interface declarations as mandatory ABI closure.

Small files and interfaces were not removed merely to lower nSLOC. They define
selectors, mutability, structs, errors, and economic or state-machine boundaries
consumed by the implementations. They are not separate whole-file re-audits.

## Alternatives considered but not adopted

| Possible reduction | Why not adopted |
| --- | --- |
| Remove the reserved-branch finalization lane | Only valid if every reserved branch remains inactive and receives a separate audit before activation. It would remove authorization, atomic synchronization, binding, empty-state, and invariant assurances from the production candidate. |
| Remove RedemptionHelper | A separable six-hunk carve-out, but it would prevent an end-to-end conclusion on failed-branch denominator allocation and refunds. |
| Remove `PriceFeedPlaceholder` | It is deployed for reserved branches and is reached by all-branch price/redemption traversal; tiny size does not justify the liveness gap. |
| Treat interfaces as ignored code | They have no standalone runtime, but their changed ABI is necessary to validate implementation/caller closure. They remain included without whole-file pricing. |
| Price cleanup tools or deployment scripts | The cleanup is endpoint-absence evidence, and scripts/tools are reproduction or project-owned launch inputs, not requested code-review work. |

## Blast radius and evidence

The retained changes cross price acquisition, branch pause/resume, liquidation,
normal and urgent redemption, Vault mint/outflow/allocation, reserved activation,
and native-ETH custody. Relevant unchanged callers and external-return
assumptions remain mandatory integration context. The complete source tree,
full 145-file test tree, focused remediation tests, dependency graph, artifact
identities, and prior audit reports remain in the companion package.

The source package is not pruned: all 25 changed paths remain committed so its
tree identity still equals production. `SCOPE.md` defines the exact review
subset as the complement of the seven hunk IDs above.

## Requested timing

The project plans an Ethereum mainnet release during September 2026. It asks for
the earliest possible kickoff and, where feasible without reducing scope or
depth, completion of the code review and delivery of the findings report by
**18 September 2026**. The project plans to begin remediation after receiving
the report.

## Method and confidence

This medium-sized differential was triaged by hunk provenance, production
reachability, imports/inheritance/callers, deployment selection, artifact
effects, tests, and change history. Oracle and core/value-transfer lanes were
reviewed separately and reconciled. Confidence is high for the five exclusion
rows above; broader functional carve-outs remain commercial options only with
an explicit reduced SOW and documented residual-risk acceptance.
