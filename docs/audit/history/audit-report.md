# Maintainer Pre-Audit Adversarial Review

**Date:** 2026-08-31
**Reviewer:** Codex
**Status:** maintainer pre-audit; not a Chain Defenders / Guardian audit result

## Executive Summary

The final production differential was reviewed adversarially against the pinned
Chain Defenders remediation base. No new unacknowledged, directly permissionless
loss-of-funds path was confirmed in the risk-finalization, Vault, minimum-debt,
Zapper, or cleanup changes.

One material risk-model correction and four retained design/deployment risks
must nevertheless be presented to the external auditor. Most importantly, the
shared JPY/USD state machine does **not** impose an absolute 96-hour bound from
the last observation seen fresh: a valid monotonically newer round may be
adopted after it is already stale, re-anchoring a not-yet-expired freeze episode.
The resulting urgent-redemption exposure can extend beyond the simple readable
round's `[30h, 96h)` interval. This behavior needs an explicit Product / Protocol Risk
decision and independent auditor disposition before launch.

## Scope And Identity

| Boundary | Identity |
| --- | --- |
| Chain Defenders remediation base | `d4122704d08b521d832438c31c0ddccf202fea81` |
| Base `contracts/src` tree | `417fe3b995f3dec84fd611fcc2f5c3ebd62d5c7a` |
| Final production candidate | `1b453c10e3378390109cf42037a97b7f6de57b9e` |
| Final `contracts/src` tree | `84476d9086e89580c58918b203f4142ecd839765` |
| Complete source differential reviewed here | 25 files, 171 hunks, `+745/-185` |
| Current external-review subset | 22 paths, 164 hunks; authoritative in `SCOPE.md` |

The maintainer review covered every source-diff hunk plus unchanged callers, interfaces,
inheritance, deployment wiring, roles, and external integrations needed to
reason about those hunks. The exact file and hunk inventories are in
`FINAL_PRODUCTION_HUNK_PROVENANCE.tsv`.

The compiled surface inventory contains 606 ABI function entries across the 35
concrete priced/context artifacts represented in the committed artifact
manifest. Security-sensitive entry points traced end-to-end include:

- `PriceFeedProxy.fetchPrice`, `fetchRedemptionPrice`,
  `fetchUrgentRedemptionPrice`, `proposeSource`, `confirmSource`,
  `confirmSourceEmergency`, and `resumeFromOracleFailure`;
- `JpyUsdRateProvider.fetchJpyUsdRate`;
- BorrowerOperations open/adjust/close, pause/resume, and economic shutdown;
- `TroveManager.urgentRedemption` and RedemptionHelper branch aggregation;
- `AddressesRegistry.finalizeRiskParams`;
- CollateralVault deposit, redeem, claim, Strategy allocation, and repair paths;
  and
- changed Zapper custody/referral paths.

External assumptions include Chainlink-compatible USD and JPY/USD feeds, Lido
stETH/wstETH rates, Vault Strategy valuation/withdrawal behavior, deployment
wiring, and OpenZeppelin v4.9.5 Timelock role configuration. CollateralVault is a
UUPS surface whose upgrades require `GOV_ROLE`; its unchanged semantic layout is
verified separately. PriceFeedProxy source routing and the other scoped
constructor-deployed contracts are not implementation-upgrade proxies.

## Findings

[`KNOWN_RISKS_AND_CURRENT_POSITION.md`](../KNOWN_RISKS_AND_CURRENT_POSITION.md)
is the consolidated final-candidate register. It adds historical aliases,
current project positions, resolved items, and launch/future constraints without
turning this maintainer review into an external result or formal risk acceptance.

| ID | Assessment | Status |
| --- | --- | --- |
| A-01 | High impact / low likelihood: stale-but-newer JPY rounds can extend urgent-path stale-FX operation beyond the simple readable-round age-96 expiry | Open: Guardian assessment and Product / Protocol Risk treatment pending |
| A-02 | Low: semantic forwarding cycles can pass PriceFeedProxy confirmation | Engineering recommends retention; formal treatment pending |
| A-03 | Medium deployment invariant: urgent redemption is safe only when TroveManager is wired to PriceFeedProxy | Launch-blocking readback |
| A-04 | Low operational/permanence: finalization does not prove full activation readiness | Launch-blocking ceremony |
| A-05 | Medium availability: confirmed-conservative Vault backing checks can halt user flows during valuation failure | Engineering recommends retention; formal treatment pending |

### A-01 — stale-but-newer rounds can extend urgent stale-FX operation

**Checklist anchors:** `SOL-Defi-Oracle-3`, `SOL-Defi-Oracle-7`,
`SOL-Heuristics-12`, `SOL-Heuristics-13`, `SOL-Heuristics-16`.

`JpyUsdRateProvider.fetchJpyUsdRate()` first returns terminal failure when an
episode is already expired. Before expiry, however, lines 84–103 accept any
otherwise valid response whose `updatedAt` is newer than the cached timestamp,
even when that response is already older than the 72-hour staleness threshold.
It updates the cached rate/timestamp and sets `jpyFrozenSince = 0`; lines 105–115
then derive a new freeze onset from the newer round. If the configured feed can
surface progressively newer but already-stale timestamps before each current
episode expires, repeating this sequence can keep the provider policy-live
beyond 96 hours from the original fresh observation.

The age-96 endpoint is specific to a readable round that merely becomes stale:
it enters freeze at `updatedAt + 72h` and expires at `updatedAt + 96h`, so the
normal-to-urgent interval is `[30h, 96h)`. If an invalid, reverting, or
decimals-mismatched response is first observed while the cached round is still
younger than 72 hours, freeze starts at observation and expires 24 hours later,
potentially much earlier. Stale-but-newer re-anchoring is possible only before
the expiry latch is set; after expiry, the function returns terminally before
that adoption block and only a fresh response clears the latch.

The 30-hour provenance check in PriceFeedProxy affects normal redemption only.
Borrowing, liquidation, the permissionless `TCR < SCR` shutdown evaluation, and
urgent redemption continue under the shared provider policy. An adverse sequence
is therefore:

1. JPY provenance reaches 30 hours and normal redemption stops.
2. A stale-high JPY/USD denominator remains provider-valid, or a stale-but-newer
   round re-anchors the active freeze episode.
3. The stale-high denominator depresses collateral value in JPY terms and may
   make the branch appear to have `TCR < SCR`.
4. Any caller can trigger irreversible economic shutdown through
   BorrowerOperations.
5. Urgent redemption then uses the stale denominator and can deliver more
   collateral per JPYdf than a current rate would.
6. Further stale-but-newer rounds can extend the policy-live urgent path beyond
   the original observation's 96-hour point.

This does not give an attacker control over Chainlink publication, and it does
not guarantee favorable FX direction, shutdown, available Troves, or profit.
Those constraints lower likelihood but do not restore the claimed time bound or
reduce the conditional loss impact.

**Reproducible timestamp sequence:** deploy with a fresh round at hour 1 and do
not call the provider again. At wall-clock hour 200, make the immutable feed's
latest valid response carry `updatedAt = 120h`. The provider adopts it because
`120h > 1h`, anchors `jpyFrozenSince = 192h`, and returns
`freezeExpired = false` until hour 216—well beyond hour 97, the original
round's simple expiry. For the repeated adversarial variant, before hour 216
return a valid newer response with `updatedAt = 130h` at wall-clock hour 210;
the contract re-anchors expiry to hour 226. The same `+10h` sequence can repeat.
That repeated variant requires an oracle/proxy which exposes a newly visible
round with an already-old timestamp; a healthy Chainlink feed normally timestamps
updates near publication, and no permissionless protocol user can force this
precondition. The one-time no-polling re-anchor needs only a newer round that was
never observed while fresh.

**Minimal code option if an absolute episode cap is required:** preserve an
already nonzero `jpyFrozenSince` when adopting a stale-but-newer value. In the
current function, this is conceptually the deletion of the reset below; the
existing unset-state block will still anchor the first stale observation.

```solidity
if (validStaleButNewerRound) {
    lastGoodJpyRate = scaledAnswer;
    lastGoodJpyUpdatedAt = response.updatedAt;
    // Do not clear an already-active jpyFrozenSince episode.
}
```

An alternative is a separately approved maximum-age gate on urgent redemption,
but that can prevent the intended post-shutdown wind-down and is a policy change,
not mere plumbing. If current behavior is retained, the external auditor should
add an unpriced two-round adversarial case that demonstrates re-anchoring beyond
the original 96-hour point; do not alter the exact copied production test tree.
Record explicit Product / Protocol Risk treatment and Guardian's independent
assessment.

### A-02 — a semantic forwarding cycle passes source confirmation

**Checklist anchors:** `SOL-EC-1`, `SOL-EC-5`, `SOL-Heuristics-9`,
`SOL-Heuristics-12`.

`PriceFeedProxy._isPriceFeedProxy` is intentionally a one-level type marker.
During `_confirmSource`, the proposed source's three price functions are called
before `source = proposedSource`. An adapter that does not expose `source()` but
forwards those functions back to the Proxy therefore reaches the old healthy
source during validation, returns zero-deviation values, and passes. Assignment
then forms a semantic cycle.

```solidity
contract ForwardingAdapter {
    PriceFeedProxy immutable proxy;
    function fetchPrice() external returns (uint256, bool) {
        return proxy.fetchPrice();
    }
    // Forward redemption, urgent, and provenance paths in the same way.
    // Deliberately no source() marker.
}
```

After acceptance, normal/liquidation paths can exhaust gas or enter fallback and
pause behavior, while urgent redemption reverts. A fresh proposal and the same
12-hour lifecycle can recover the source. Exploitation requires the owner to
propose/confirm the bad graph, so the impact is primarily privileged denial of
service and the retained Low assessment is reasonable.

**Code option:** place a confirmation-only callback guard around all proposed
source smoke calls and reject any Proxy price entry while that guard is active.
On Cancun this can use transient storage without persistent layout. Engineering's
current alternative is operational: recursively bind every source dependency,
implementation, mutable router, and administrator to deployed addresses and
runtime code hashes before confirmation. The source-level graph alone is not
launch evidence.

### A-03 — urgent failure handling depends on exact Proxy wiring

**Checklist anchors:** `SOL-EC-5`, `SOL-EC-12`, `SOL-CR-7`,
`SOL-Defi-Oracle-11`.

`TroveManager.urgentRedemption()` line 911 discards the boolean returned by
`fetchUrgentRedemptionPrice`. This is safe for the intended PriceFeedProxy because
the Proxy reverts instead of returning a failing urgent quote. If a source is
registered directly, it may return `(lastGoodPrice, true)` and TroveManager can
settle with that price.

```solidity
(uint256 price, bool failure) = priceFeed.fetchUrgentRedemptionPrice();
if (failure || price == 0) revert UrgentRedemptionPriceUnavailable();
```

The production deploy script wraps sources and performs three-path readback, so
no candidate-code exploit exists under intended wiring. Mainnet evidence must
still prove each AddressesRegistry price-feed address is the exact Proxy, its
source is the reviewed live source, and all three paths work. Treat any direct
source registration as No-Go.

### A-04 — one-shot risk finalization does not prove activation readiness

**Checklist anchors:** `SOL-CR-7`, `SOL-Heuristics-13`.

`AddressesRegistry.finalizeRiskParams()` correctly enforces authorization,
one-shot state, parameter invariants, atomic BO/TM synchronization, DToken/Vault
identity, zero cap/supply, empty Core debt/collateral/Troves/SP, and no shutdown.
It does not inspect Vault `actualLiabilities`, `pendingWithdrawals`, backing,
registered Strategy state, or real oracle/Proxy wiring. Governance could, for
example, previously open then re-zero a branch while leaving queued claims or
Strategy state, and still satisfy the on-chain finalizer checks. A bad parameter
set or ceremony is permanent.

Adding every launch-specific check to a permanent contract is not automatically
safer. The minimum remedy is a signed, reproducible preflight that proves zero
Vault liabilities/queued withdrawals, reviewed Strategy registrations and
allocations, live backing, exact source/Proxy wiring, the six intended risk
parameters, empty Core state, and cap zero; then finalize once, repeat readbacks,
and open cap last.

### A-05 — confirmed-conservative Vault solvency protects safety by sacrificing liveness

**Checklist anchors:** `SOL-AM-DOSA-6`, `SOL-CR-1`, `SOL-CR-2`.

CollateralVault first counts raw underlying. If that alone covers liabilities,
the check need not call every Strategy; otherwise it uses only available live
Strategy valuation and counts an unavailable Strategy as zero in
`_requireConfirmedFullyBacked`. This protects against stale-cache first-mover
extraction, but a valuation outage or actual underbacking can block deposit,
redeem, claim, and nonzero allocation flows.
Queued claimants may therefore remain unable to exit until live valuation
recovers or a repair/backstop path restores confirmed backing.

Do not weaken this with cached valuation without a separately audited insolvency
policy. Launch readiness instead requires funded repair/backstop routes,
exercised Strategy recovery ingress, and external alerts for live-valuation
failure, backing deficit, oldest queued claim, and blocked user-path synthetics.

## Confirmed Non-Issues And Positive Controls

- Active risk parameters are validated in `DeployLiquity2`; reserved parameters
  are revalidated in `AddressesRegistry.finalizeRiskParams`. Both enforce
  `SCR < MCR < CCR`, `1 + penaltySP <= MCR`, and
  `1 + urgentBonus <= SCR` at their activation layer.
- `MIN_DEBT = 100_000e18` is checked against entire debt including the upfront
  fee on open/adjust, and its repayment/zombie uses remain distinct from close
  and urgent residual behavior. This confirms code-boundary consistency, not
  the pending economic/list/gas capacity assumption in register `KR-15`.
- Failed normal-redemption branches retain their denominator allocation and
  unused JPYdf is refunded rather than reallocated to healthy branches.
- Runtime JPY/USD decimals are checked before adopting fresh or stale-but-newer
  rounds. Recovery/resume requires valid non-failure returns from the three
  current-source quote methods; normal-redemption JPY provenance is independent.
- dwstETH normal/urgent redemption uses the maximum direct/derived reference and
  fails closed at the configured stETH/ETH threshold. The intended 90,000-second
  deployment value requires readback.
- Under canonical Lido stETH/wstETH identity and `submit(address)` semantics,
  Zapper referral mutation cannot redirect funds or alter receiver, collateral,
  debt, minimum-output, refund, or atomicity semantics.
- The four pilot overlay symbols are absent. ActivePool and JpydfToken are
  base/head source-blob identical.

## Checklist Coverage

The 370-item Solidity checklist was triaged against the pinned differential and
its integration context. Hash/Merkle (5 items) and cross-chain messaging (13
items) were excluded because the scoped contracts expose neither mechanism. The
remaining 352 entries were reviewed: 221 were applicable or contextual and 131
were marked not applicable.

| Checklist section | Reviewed | Applicable/contextual | N/A |
| --- | ---: | ---: | ---: |
| Attacker's mindset | 25 | 22 | 3 |
| Solidity basics | 135 | 69 | 66 |
| Heuristics | 17 | 17 | 0 |
| DeFi | 63 | 57 | 6 |
| Token | 24 | 16 | 8 |
| Integrations | 56 | 9 | 47 |
| External calls | 14 | 14 | 0 |
| Signatures | 5 | 5 | 0 |
| Low-level / assembly | 5 | 4 | 1 |
| Centralization risk | 7 | 7 | 0 |
| Timelock | 1 | 1 | 0 |
| **Total** | **352** | **221** | **131** |

## Verification Performed

- exact production source tree and complete test-tree parity checks;
- deterministic reconstruction of 171 source-diff hunks;
- standard and metadata-stripped bytecode/ABI artifact comparison: 35 manifest
  rows, 34 standard-bytecode changes, and 18 metadata-free executable changes;
- semantic base/final storage-layout comparison;
- standalone Solc 0.8.24 build: 262 files, success;
- JpyUsdRateProvider focused suite: 16/16 pass;
- final source PR gates: 99 fast suites, 1,789 pass, 0 fail, 1 intentional
  skip; focused minimum-debt 9/9, ActivePool 7/7, pilot controller 17/17;
- full 107-suite non-mainnet selection serialized with `--threads 1`: exit 0;
- production rollback, manifest policy, native-ETH route, and contract-size
  gates: pass.

A default-parallel full run produced 1,844 passes, one failure, and one skip;
the failed Zapper test passed alone. A deterministic two-suite reproducer showed
that Foundry 1.7.1 implements `vm.setEnv` as process-global mutation, allowing
the Console handover suite's `DF_TIMELOCK` address to enter the Zapper suite's
independent EVM as a codeless address. The serialized pass is therefore recorded
alongside—not in place of—the parallel test-isolation defect. No exact production
test was edited to hide it.

These source checks do not substitute for mainnet deployment bytecode, role,
feed-address, dependency-graph, fork, or verified human alert-delivery evidence.

## Required Dispositions Before Launch

1. Product / Protocol Risk must explicitly retain, remediate, or otherwise treat
   A-01, including the repeated stale-but-newer sequence rather than only the
   single-round 96-hour case; Guardian should independently assess it.
2. Guardian should independently assess the Low characterization and operational
   graph mitigation for A-02; Product / Protocol Risk owns formal treatment.
3. Deployment evidence must close A-03 and A-04 with exact address/codehash/role
   readbacks and cap-last activation records.
4. Operations must demonstrate A-05 repair and alert liveness with an end-to-end
   incident test and intended-human receipt.
