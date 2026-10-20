# Final Production English Authority And Errata

Some copied support documents are intentionally unedited so their hashes remain
verifiable. The corrections below override known stale statements for candidate
`1b453c10e3378390109cf42037a97b7f6de57b9e` / `contracts/src` tree
`84476d9086e89580c58918b203f4142ecd839765`.

Precedence for this engagement is:

1. exact final Solidity;
2. `GUARDIAN_ADDITIONAL_AUDIT_HANDOFF.md`, `SCOPE.md`,
   `KNOWN_RISKS_AND_CURRENT_POSITION.md`, and this document;
3. current English component specifications; then
4. other historical English and Japanese material.

Auditors do not need to follow a Japanese link to determine any behavior below.

## Oracle Failure And Irreversible Shutdown

- Oracle failure latches a recoverable BorrowerOperations pause. It does not set
  TroveManager `shutdownTime` and is not terminal shutdown.
- While paused, normal redemption, collateral withdrawal, and debt increase stay
  blocked. A recovered live normal price reopens liquidation, the `TCR < SCR`
  shutdown evaluation, CCR-checked close, collateral addition, and debt
  repayment before Owner resume.
- Owner resume is atomic and requires valid non-failure returns from the current
  source's normal, normal-redemption, and urgent quote methods. Fresh JPY
  provenance remains an independent Proxy normal-redemption gate, so that path
  may remain unavailable after resume. A returned quote carrying `failure=true`
  never drives terminal shutdown.
- Only the economic `TCR < SCR` path irreversibly sets `shutdownTime` and enables
  urgent redemption.

## Three Price Paths And Urgent Redemption Erratum

Final `TroveManager.urgentRedemption` calls
`priceFeed.fetchUrgentRedemptionPrice()`, not `fetchPrice()`. The returned
failure flag is ignored by TroveManager because the registered
`PriceFeedProxy` reverts unless the source returns a valid live urgent quote.
Deployment must therefore prove every branch registers its Proxy rather than a
source directly.

For the wstETH branch (`DFWstETHPriceFeed`), both normal-redemption and urgent paths use
`max(direct stETH/USD, ETH/USD × stETH/ETH)`, then apply the wstETH canonical
rate, shared JPY/USD conversion, and the pricing-available backing ratio exactly
once. Vault pricing may use live Strategy valuation or a still-fresh bounded
cache; unavailable/stale cache fails closed. Urgent has no oracle-price cache
and no direct-only fallback.

This corrects stale text in
`docs/en/protocol/product/spec/Liquity-v2-Core-Spec.md` under
`CORE-TM-FR-005` and the `Redemption` event-field table that still says urgent
uses `fetchPrice()` / the normal price and skips the wstETH-derived redemption
reference.

## JPY Age Boundary And Retained Wind-Down Risk

- For an otherwise successful source quote, a valid JPY/USD round returned by
  the current source
  with age `< 108,000` seconds passes the provenance sub-gate. A separate
  already-latched BorrowerOperations pause can still make the Proxy return
  failure. At or above
  108,000 seconds, or with invalid provenance, the provenance sub-gate reports
  normal-redemption failure without itself latching the BorrowerOperations
  pause. A concurrent source revert, invalid price, or `oracleFailure=true` is
  handled first and can latch the recoverable BorrowerOperations pause.
- This 30-hour gate does not govern borrowing, liquidation, economic shutdown,
  or urgent redemption. If a readable round merely ages, it remains fresh below
  72 hours, enters soft freeze at age 72 hours, and expires at age 96 hours.
  An invalid/reverting/decimals-mismatched response observed while the cached
  round is younger than 72 hours instead starts freeze at observation time and
  can expire 24 hours later, before the cached round reaches age 96 hours.
- Consequently, during a prolonged JPY/USD outage, a stale rate can contribute
  to `TCR < SCR` and irreversible shutdown, after which urgent redemption can
  settle with that still-policy-valid stale JPY denominator until the source
  policy fails.
- For the simple readable-round aging case, provider validity ends exactly at
  age 96 hours, so the conditional normal-to-urgent interval is `[30h, 96h)`.
  This is not an absolute bound from the last round observed fresh:
  `JpyUsdRateProvider.fetchJpyUsdRate()` adopts a valid, monotonically newer
  round even when it is already stale and resets `jpyFrozenSince` before deriving
  the new freeze onset from that round's `updatedAt`. Before the expiry latch is
  set, repeated stale-but-newer rounds can therefore re-anchor successive
  episodes and extend urgent-path stale-FX exposure beyond 96 hours from the
  original fresh observation. Once `jpyFreezeExpired` is set, stale rounds are
  returned terminally and only a fresh response clears the latch.

The simple-round `[30h, 96h)` conditional extraction interval, the potentially
shorter early-invalid episode, and the potentially longer pre-expiry
stale-but-newer sequence require explicit project risk-owner treatment and
an independent Guardian assessment. The 30-hour normal-redemption gate is not a
bound on the urgent path. Statements describing a maximum or universal 96-hour
envelope in `docs/en/Parameters.md`,
`docs/en/protocol/product/spec/Oracle.md`, the requirements ledger, and the
deployment freeze runbook are superseded by this erratum.

A recent `updatedAt` proves only that Chainlink published a recent round. It does
not prove that the Forex market was open or that new price discovery occurred;
a same-value heartbeat can therefore keep the 30-hour normal-redemption gate
open during market closure. This residual is described in
[`KNOWN_RISKS_AND_CURRENT_POSITION.md`](./KNOWN_RISKS_AND_CURRENT_POSITION.md).
The underlying data, model, assumptions, and pending treatment conditions are
in [`JPYUSD_MARKET_HOURS_RISK_ANALYSIS.md`](./JPYUSD_MARKET_HOURS_RISK_ANALYSIS.md).

### Exact retained-text errata

The copied support documents stay unedited so their hashes remain independently
verifiable. Two known phrases must not
be used as current requirements:

| Exact copied document | Stale phrase | Current rule |
| --- | --- | --- |
| `docs/en/engineering/verification-ledgers/Requirements-Verification-Ledger.md`, `SYS-RISK-001` | “maximum 96h window” | `[30h,96h)` applies only to one readable round simply aging without earlier failure or re-anchoring. A valid stale-but-newer round adopted before expiry can extend exposure beyond the original round's age 96h. |
| `docs/en/protocol/launch/gates/Mainnet-Deploy-Env-Freeze-Runbook.md`, JPY soft-freeze row | “accept shutdown near age 96h” | Key response to `jpyFrozenSince + 86,400`, recomputing after every provider/round-state change. Round age 96h is only the simple single-readable-round case. |
| `docs/en/engineering/guides/Contract-Audit-Scope-And-nSLOC.md` | 5,225 “recommended SOW body”, 13,272 whole tree, and final-count pending language | Historical sizing only. Current additional-audit sizing is the 171-hunk / 535 changed-code nSLOC boundary in root `SCOPE.md`; 6,656 final whole-file nSLOC is context, not scope. |

These corrections are explicit rather than silent edits to copied evidence.
Preserving an old document's hash never gives stale wording precedence over
the Solidity or this authority.

## Proxy Source Lifecycle And Circularity

- Source proposal/confirmation has a 12-hour contract delay and calls the
  proposed source's three quote methods. Normal confirmation enforces three
  deviation checks; emergency confirmation explicitly bypasses them while
  retaining the delay and calls.
- The direct `source()` staticcall marker rejects only a directly proxy-shaped
  candidate. A forwarding adapter can call back into the old source during
  confirmation, pass every validation and deviation check, and form a cycle after
  assignment.
- Only a recursively reviewed dependency graph bound to actual addresses,
  runtime code hashes, immutable bindings, mutable routing, implementations, and
  administrators proves acyclicity. The committed graph supplies source-level
  topology; deployment binding remains a launch gate.

## Reserved Branch Activation

The initially active mainnet branches are indices 0 and 1. All six reserved branches, indices
2–7, remain economically inert with cap and Strategy allocation zero.

`PriceFeedPlaceholder` itself returns the valid `(1e18, false)` sentinel on all
three paths and current synthetic JPY provenance. Inoperability comes from the
combined reserved-branch controls, not an oracle failure:

1. branch cap/allocation remain zero;
2. dToken metadata binds the approved exact Underlying and Vault;
3. live Vault backing, liabilities, pending withdrawals, Strategy registrations,
   and real source wiring are reviewed off-chain;
4. the dedicated finalizer calls `AddressesRegistry.finalizeRiskParams` once;
5. the contract requires an empty, non-shutdown branch with zero Core debt,
   collateral, Troves, and Stability Pool deposits, validates all six parameters plus
   `SCR < MCR < CCR`, `1 + penaltySP <= MCR`, and
   `1 + urgentBonus <= SCR`, and atomically synchronizes AddressesRegistry,
   BorrowerOperations, and TroveManager; then
6. the production mint cap is raised through the approved Timelock only after
   the other checks pass.

Finalization is permanent. Its contract checks do not prove real price-source
wiring, Vault `actualLiabilities` / queued withdrawals, backing, or Strategy
state; those readbacks remain mandatory deployment evidence.

## Governance Timelocks And Admin State

- Production uses a fresh OpenZeppelin Contracts v4.9.5 `TimelockController`
  with constructor `minDelay = 43,200`, Admin Safe as proposer/executor (and
  therefore canceller under the OZ constructor), closed executor, and
  `admin = address(0)`.
- The production Timelock is self-admin from construction. No deployer/external
  Timelock admin is granted and no later Timelock-admin renounce transaction
  exists.
- The persistent canary Timelock is a different address and stays at 300 seconds.
- `PriceFeedProxy` source replacement independently uses a 43,200-second delay.

References in `CollateralVault.md`, `Strategy.md`, or the initial-configuration
checklist to “Timelock admin already renounced”, “admin renounce”, or a Japanese
Timelock runbook mean the required terminal state—Timelock self-admin only—but
the production constructor reaches that state directly. Use the current English
Timelock policy/runbook and negative external-admin readback.

## Project-Owned Launch Evidence

Production monitoring, alert delivery, deployment-bound addresses and code
hashes, role assignments, and parameter readbacks are project-owned launch
checks, not Solidity review targets. [`EVIDENCE_CHECKLIST.md`](./EVIDENCE_CHECKLIST.md)
records the pending evidence. A source-review result does not prove those checks.
