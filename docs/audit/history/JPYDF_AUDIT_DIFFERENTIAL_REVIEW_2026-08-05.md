# JPYdf Audit Remediation Differential Review

## 1. Executive Summary

| Severity | Count |
| --- | ---: |
| 🔴 Critical | 0 |
| 🟠 High | 1 |
| 🟡 Medium | 2 |
| 🟢 Low | 1 |

**Overall risk:** High for audit reproducibility; no new code-level security regression identified.

**Recommendation:** CONDITIONAL / HOLD. Do not merge `jpydf-v2` PR #1418 until the audit repository has a follow-up PR that fixes the authoritative source identity, pins the final snapshot SHA, preserves all claimed patches, and updates the final status index.

**Key metrics:**

- Audit repository range: `abad4a7..4e28441`
- Audit repository change set: 104 files, +7,203 / -521
- Solidity inventory: 236 files, including 106 under `contracts/src`
- Ledger diff hashes recomputed: 21/21 match
- Preserved candidate patch hashes recomputed: 11/11 match
- Independent focused Foundry run at PR #1418 head `10cf5efc`: 287/287 passed
- PR #1418 checks: 6 required jobs passed; 3 coverage jobs skipped as configured
- Security regressions detected in reviewed critical paths: 0

## 2. What Changed

The review covered two linked ranges:

1. `jpydf-audit`: `abad4a7..4e28441`, containing the imported report, 21 per-finding decisions, 21 snapshot application PRs, and final ledgers.
2. `jpydf-v2`: `4df6d902..10cf5efc`, PR #1418, containing the eleven previously unmerged candidates plus the Info 07 implementation-slot assertion amendment.

The ten earlier `jpydf-v2` changes (#1382–#1385, #1396–#1398, #1404–#1406) are reachable from `develop`. Their full diff SHA-256 values match the audit ledger. The eleven candidate branch diffs also match the ledger and the committed patch artifacts.

| Change group | Files / surface | Risk | Review depth |
| --- | --- | --- | --- |
| Vault and Strategy accounting | `CollateralVault.sol`, `BaseStrategy.sol`, interfaces | High | Deep code and test review |
| Shared JPY/USD oracle and source switching | `JpyUsdRateProvider.sol`, DF/sUSDS feeds, `PriceFeedProxy.sol` | High | Deep code and test/history review |
| Governance and deployment guards | `InterestRouterForwarder.sol`, deploy/handover scripts | High | Focused code and test review |
| PR #1418 candidate tests/docs | 31 files, +2,208 / -22 | Medium/Low | Full patch correspondence and focused test execution |
| Audit ledgers, evidence, status files | `evidence/external-audit/**` | High for provenance | Full structural and hash review |
| Remaining mirrored docs/tests | 104-file inventory | Low/Medium | Surface scan with focused inspection of security assertions |

## 3. Findings

### 🟠 HIGH: The documented build checkout retrieves the pre-remediation source

**Files:**

- `scripts/checkout-source.sh:L5`
- `SOURCE_MANIFEST.md:L29-L31`, `SOURCE_MANIFEST.md:L44-L52`, `SOURCE_MANIFEST.md:L71-L73`
- `BUILD_AND_TEST.md:L16-L17`, `BUILD_AND_TEST.md:L36-L70`
- `source-snapshot/README.md:L19-L22`

**Blast radius:** All 21 findings and every auditor following the documented reproduction path.

**Test coverage:** The correct PR head is tested, but the documented default path does not retrieve that head.

**Description:**

The snapshot now contains the 21 approved remediation diffs, but the checkout helper still defaults to `dab4dbe5251f980a3af347cba20351513b026e7b`, the July audit base. `SOURCE_MANIFEST.md` also records that commit as the current handoff commit, while `BUILD_AND_TEST.md` calls the helper output the authoritative build/test source. No step applies the approved patches after checkout.

The reconciliation commands are stale too: they expect equality with the old source except `SeedLocalDemo.s.sol`. The current, independently verified relationship is the PR #1418 head plus four documented non-audit drift files and nine curation exclusions. Following the documented commands therefore either tests the wrong code or produces a large unexplained mismatch.

**Historical context:**

- `dab4dbe5` was valid for the July Sky converter handoff.
- Snapshot PRs #49–#69 later changed 66 files (+2,297 / -517) after the recorded decision-closure SHA.
- PR #1418 head is `10cf5efcf787fd8b1d2f5e35ed22b0064e637258`.

**Failure scenario:**

1. An auditor runs `./scripts/checkout-source.sh` as instructed.
2. The helper checks out `dab4dbe5` without the approved Mid/Low production fixes or the candidate evidence.
3. The auditor runs Foundry or Slither successfully against the old tree.
4. Those results are attributed to the remediated snapshot, even though the tested code is different.

**Impact:** Audit approval can be attached to a source tree that does not contain the approved remediation set. This is a provenance failure affecting the entire handoff.

**Recommendation:**

- Before merging PR #1418, document and support a buildable checkout of the exact approved candidate SHA `10cf5efc`.
- After PR #1418 merges, pin its resulting immutable merge/tree identity and update the helper default.
- Update the reconciliation allowlist to the explicitly reviewed four drift files and nine curation exclusions, or eliminate the drift by refreshing the snapshot.
- Rerun and record build, focused/full tests, Slither, and nSLOC against the newly pinned identity.

### 🟡 MEDIUM: The pinned “audit content SHA” predates all snapshot application PRs

**File:** `evidence/external-audit/audit-ledger.md:L3-L10`

**Blast radius:** The immutable identity of the complete 21-finding audit result.

**Description:**

The ledger pins `3f6ba016...`, which is merge PR #47 and closes the decision notes. The approved code/test snapshot was applied later through PRs #49–#69. The diff from `3f6ba016` to snapshot closure `4ea72f51` changes 66 files (+2,297 / -517). Therefore the pinned SHA does not identify the reviewed remediation snapshot.

The distinction between “decision closure” and “snapshot closure” is useful, but only the earlier SHA is currently recorded as `Audit content SHA`.

**Impact:** A reviewer cannot select one immutable audit commit and obtain the final reviewed code, tests, decisions, and correspondence ledger.

**Recommendation:** Record separate fields for:

- decision closure SHA: `3f6ba016...`;
- snapshot closure SHA: `4ea72f51...` or a signed/tagged final `main` identity;
- final ledger/status SHA or signed tag.

The final handoff should name one authoritative tag/SHA whose tree includes all snapshot applications and final evidence.

### 🟡 MEDIUM: The ledger claims 21 preserved patches, but only 11 exist

**File:** `evidence/external-audit/audit-ledger.md:L12-L19`

**Blast radius:** Ten pre-merged changes, including the Medium oracle fixes and Low 01–06 production/deployment fixes.

**Description:**

The ledger states that every approved diff is preserved verbatim and is independently verifiable without access to `jpydf-v2`. The directory contains only eleven patch files: Low 07, Info 01–08, and Gas 01–02.

The following ten patch artifacts are absent:

- High 01
- Mid 01–03
- Low 01–06

Their ledger hashes are correct when recomputed against the local `jpydf-v2` history, and their resulting source is present in the snapshot. However, an auditor without source-repository access cannot perform the verification promised by the ledger.

**Impact:** Per-finding provenance for the ten prematurely merged changes depends on private/external repository access, contradicting the handoff claim.

**Recommendation:** Export and commit the ten missing verbatim patches, verify all 21 SHA-256 values in CI, and add a manifest check requiring exactly one patch per finding. If the ten patches are intentionally omitted, narrow the ledger claim and explain the alternative independent verification mechanism.

### 🟢 LOW: The intake index still describes every final disposition as Proposed

**File:** `evidence/external-audit/README.md:L21-L30`, `evidence/external-audit/README.md:L54-L63`

**Description:**

Every per-finding note and `audit-ledger.md` says `Closed — audit-approved (2026-08-05)`, while the intake index still says every disposition is `Proposed`, labels the table `Proposed disposition`, and repeats that state in the final Status section.

**Impact:** The repository presents two mutually exclusive current states. This does not alter contract behavior, but it makes the audit state machine ambiguous.

**Recommendation:** Preserve the initial proposal as history, then add an explicit final-disposition column/banner and update the Status section to point to the fixed audit snapshot identity.

## 4. Test Coverage Analysis

### Executed locally

At PR #1418 head `10cf5efc`, using an independent temporary checkout with the pinned Foundry dependencies:

```text
9 suites
287 tests passed
0 failed
0 skipped
```

Covered suites included:

- `ExternalAuditInfo06AddressesRegistryWiringTest`
- `ExternalAuditGas02ShutdownAssertTest`
- `ExternalAuditLow07ScaleSpanTest`
- `ExternalAuditGas01BackingRatioTest`
- `ERC4626StrategyTest`
- `DTokenTest`
- `DeployLiquity2StrategySelectorTest`
- `CollateralVaultStrategyTest`
- `CollateralVaultTest`

### GitHub checks

PR #1418 reports success for Foundry tests, local deploy wiring, Core surface guard, console imports/E2E, and bot tests. Coverage jobs are explicitly skipped/non-blocking.

### Coverage limits

- The full Foundry suite was not re-run locally in this review; the GitHub Foundry job is the evidence for that gate.
- Mainnet-fork tests were not re-run.
- Production alert delivery, escalation target, human recipient, and labeled test-incident delivery were not verified. The runbooks correctly keep those as pre-production requirements.
- Static analysis and nSLOC evidence in `SOURCE_MANIFEST.md` remain tied to the July source identity and must be refreshed for the final remediation identity.

## 5. Blast Radius Analysis

| Changed surface | Direct callers / consumers | Risk | Priority |
| --- | --- | --- | --- |
| Shared `JpyUsdRateProvider` | All active JPY-denominated branch feeds | High, cross-branch | P0 |
| `IStrategy.deposit(uint256,uint256)` | One production Vault caller; every registered Strategy implementation | High, all allocation paths | P1 |
| `_managedUnderlying()` | `allocate()` and `transferYieldToTreasury()` | High, outbound value movement | P1 |
| Permissionless `claim()` | All queued withdrawal requests and integration callers | High, user settlement | P1 |
| Recipient validation | Interest routing, deploy and handover verification | High, protocol revenue routing | P1 |
| Audit source identity | Every reproduced build/test/static-analysis result | High, all findings | P0 |

## 6. Historical Context and Regression Review

- The removed `NotRequestOwner` check was reviewed against the replacement invariant: anyone may trigger, but the recorded owner remains the only payout recipient. Blacklist failure rolls back claim state.
- The Strategy deposit selector change adds exact same-transaction recovery and retains fail-closed behavior when receipt/recovery cannot be proven.
- The shared JPY provider intentionally latches terminal expiry to prevent cross-branch recovery divergence; the failure path is covered by the source/proxy shutdown design.
- Price-source confirmation now uses separate normal/redemption last-good caches when the old source is unhealthy; the explicit emergency path retains the same timelock and smoke tests.
- No removed security check was found to be reintroduced without replacement.
- All 21 ledger diff hashes match the referenced source ranges. Snapshot content matches PR #1418 for `src/script/test`, excluding the four documented non-audit drift files and nine curation exclusions.

## 7. Recommendations

### Immediate — blocking PR #1418 merge

- [ ] Pin a buildable approved source identity, not `dab4dbe5`.
- [ ] Record a final snapshot SHA/tag that includes PRs #49–#69.
- [ ] Add the ten missing patch artifacts or correct the ledger claim.
- [ ] Update the intake index from Proposed to the final reviewed state.
- [ ] Make the documented snapshot reconciliation command match the actual reviewed exclusions/drift.

### Before production

- [ ] Refresh build, Slither, nSLOC, and source-manifest evidence at the final merged identity.
- [ ] Run the mainnet-fork evidence required by the affected oracle/strategy paths.
- [ ] Verify enabled external monitors, escalation targets, intended human recipients, and labeled end-to-end test incidents for JPY freeze and Strategy valuation/deposit failures.

### Process hardening

- [ ] Add CI validating one finding note, one snapshot PR mapping, and one patch hash per ledger row.
- [ ] Add CI that reconstructs or checks out the pinned source and runs the documented reconciliation commands.
- [ ] Keep decision-closure, snapshot-closure, implementation-sync, and production-deployment identities as separate explicit fields.

## 8. Analysis Methodology

**Strategy:** SURGICAL for the large Solidity repository, with full high-risk coverage and a structural audit of all 104 changed files.

**Techniques:**

- Base/head diff inventory and risk classification
- Git history and blame on removed authorization/accounting logic
- Per-finding SHA-256 recomputation for all 21 diffs
- Audit snapshot versus PR #1418 tree comparison
- Merge-conflict inspection for the candidate aggregation branch
- Direct review of value movement, oracle failure, access-control, and deployment-key paths
- Independent Foundry execution at the exact PR head
- GitHub PR/check-state verification

**Limitations:**

- Unrelated `jpydf-v2 develop` changes outside the approved audit diffs were excluded.
- External dependencies were not re-audited.
- Production monitoring/delivery infrastructure was not exercised.
- Mainnet-fork and full invariant suites were not independently rerun in this pass.

**Confidence:** High for provenance findings, PR #1418 correspondence, and reviewed critical paths; medium for the entire protocol beyond the approved differential scope.

## 9. Reference Identities

| Identity | SHA |
| --- | --- |
| Original audit snapshot base | `dab4dbe5251f980a3af347cba20351513b026e7b` |
| Audit decision closure | `3f6ba016e2fa7a07b89e16cb63f6051333bd243b` |
| Audit snapshot PR closure (#69) | `4ea72f51fa180247688736f7bd9372885ebd4d68` |
| Current audit `main` reviewed | `4e28441142d2bef1c2be3af61cc0c1de26b8a849` |
| `jpydf-v2 develop` / PR #1418 base | `4df6d902f270c4352ea3f80590aed89bdf4a425a` |
| PR #1418 head reviewed | `10cf5efcf787fd8b1d2f5e35ed22b0064e637258` |
