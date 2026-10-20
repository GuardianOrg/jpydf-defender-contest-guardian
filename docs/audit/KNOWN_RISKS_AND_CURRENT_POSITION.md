# Known Risks And Current Project Position

**Status:** preserved pre-remediation risk handoff for the candidate below. Current Guardian treatments, changed source identity and residual risks are recorded in [Guardian remediation](./GUARDIAN_REMEDIATION.md); they supersede this baseline register where changed. In particular, the 30h gate now also covers BorrowerOperations, safe repayments/additions are price-free, and liquidation uses a 30h threshold plus 24h grace.

**Candidate:** `1b453c10e3378390109cf42037a97b7f6de57b9e`

**`contracts/src` tree:** `84476d9086e89580c58918b203f4142ecd839765`

This document tells Guardian what the project already knows, what the current
engineering position is, and what still needs an independent auditor or risk
owner decision. It is not an external audit result, a formal Governance
acceptance record, a launch approval, or a substitute for
[`SCOPE.md`](../../SCOPE.md). `SCOPE.md` remains authoritative for review scope.

The private implementation repository is not required to use this register. The
relevant source, tests, prior reports, and English context are included here.

Known does not mean accepted, harmless, or excluded. Guardian may report any
item in this document as a vulnerability or finding, with its own severity and
recommended treatment. The project's current position must not suppress or
downgrade independent reporting.

## Status vocabulary

| Status | Meaning |
| --- | --- |
| **Open** | The project has not selected a final risk treatment. Guardian should independently assess the code facts, severity, and mitigation; the project's designated risk owner decides whether to retain, remediate, or otherwise treat the risk. |
| **Retain; formal disposition pending** | Engineering currently recommends keeping the behavior because the obvious alternative creates a different safety failure. This does not claim Governance acceptance. |
| **Prior auditor acknowledged** | Chain Defenders recorded the item as `Acknowledged`, not `Fixed`. Guardian should not silently relabel it. |
| **Launch-blocking evidence** | The source-level assumption is known, but deployment or operational proof must still be produced. It is not completed by a source-audit result. |
| **Launch/integration risk** | The code boundary is understood, but safe activation also depends on external integration limits and production controls. |
| **Known architecture boundary** | The limitation is intentional in the current design; changing it would be a separate design and audit target. |
| **Implementation constraint** | The fact constrains how a finding can be fixed, but never whether the finding is valid. |
| **Future-change constraint** | The present topology makes the condition non-material or unreachable. The specified topology change reopens review. |

Severity descriptions below are the project's risk characterization, not a
requested audit rating. Guardian should correct them where its analysis differs.
Quantitative datasets and models supplied here are severity context, not an
implicit request to reproduce them in full; that work requires a written SOW
change.

## At-a-glance register

| ID | Risk | Current project position | Current status |
| --- | --- | --- | --- |
| `KR-01` | A recent JPY/USD `updatedAt` does not prove recent FX price discovery; stale-but-newer rounds can also re-anchor a freeze episode | Retain the 30-hour normal-redemption gate as a partial mitigation, but do not treat it as a market-hours check or an absolute urgent-path cap. No further Solidity change is currently selected. | **Open** |
| `KR-02` | Live-price recovery can restore permissionless `TCR < SCR` shutdown before Owner resume; resume is a health check, not continuity/provenance proof | Retain Liquity's permissionless economic wind-down and the Owner approval boundary for re-enabling risk-increasing operations. Normal redemption remains independently provenance-gated. | **Retain; formal disposition pending** |
| `KR-03` | Fail-closed urgent redemption and a joint oracle/governance outage can delay exits | Retain fail-closed settlement. Cache or direct-only fallback would reopen stale-price value transfer. | **Retain; formal disposition pending** |
| `KR-04` | `max(direct, derived)` can underpay a redeemer when one policy-valid leg is stale-high | Retain the solvency-protective polarity. The intended deployment must be read back with the 90,000-second stETH/ETH threshold; disclose the fairness trade-off. | **Retain; formal disposition pending** |
| `KR-05` | Emergency source confirmation bypasses all three deviation guards together | Retain the recovery path with the 12-hour delay and three proposed-source quote-method calls; they are not a post-switch price guarantee. | **Retain; formal disposition pending** |
| `KR-06` | A semantic forwarding cycle can pass the Proxy's one-level marker and validation calls | Do not add a callback latch to the permanent contract at present; require a recursively reviewed, deployment-bound graph. | **Retain; formal disposition pending** |
| `KR-07A` | Vault backing checks can stop user flows when live Strategy valuation is unavailable | Retain fail-closed valuation and keep recovery and recapitalization functions open. | **Retain; formal disposition pending** |
| `KR-07B` | A partial Strategy recovery does not renew the full-valuation cache timestamp | Do not make a partial receipt renew confidence in an unobserved residual position. | **Prior auditor acknowledged** |
| `KR-08` | A Strategy loss that is not visible in live valuation cannot be prevented by the backing guard | Bound exposure with approved Strategy caps, same-Underlying backstop capacity, monitoring, and incident procedures. | **Launch/integration risk** |
| `KR-09` | Reserved-risk finalization is permanent and cannot prove every activation prerequisite | Keep the one-shot contract boundary; verify prerequisites and read back exact values before raising the mint cap. | **Launch-blocking evidence** |
| `KR-10` | Urgent redemption assumes every TroveManager is wired to PriceFeedProxy, not directly to a source | Direct source registration is unacceptable for production. Prove every deployed binding and runtime hash. | **Launch-blocking evidence** |
| `KR-11` | dToken `mintCap` is not a hard JPYdf branch debt ceiling | Do not describe cap headroom as borrow capacity. A hard branch debt ceiling would be a separate design and audit. | **Known architecture boundary** |
| `KR-12` | TroveManager has 6 bytes and BorrowerOperations 45 bytes of current EIP-170 runtime headroom | Never reject a valid finding because of size; any fix may require deletion/refactoring and must rerun the production size gate. | **Implementation constraint** |
| `KR-13` | Referral safety depends on the configured contracts being canonical Lido stETH/wstETH with the reviewed `submit(address)` semantics | Prove deployed addresses, code identity, and immutable bindings; otherwise the source-level referral conclusion does not hold. | **Launch-blocking evidence** |
| `KR-14` | Two generic price-feed defaults are safe only under the current source formulas and topology | Reopen review before activating another default Composite source or divergent normal/redemption/urgent formulas. | **Future-change constraint** |
| `KR-15` | Lowering `MIN_DEBT` from 300,000 to 100,000 JPYdf lowers several anti-dust and zombie-state boundaries, not only the entry floor | Retain the product parameter, but review every reachable use and the resulting fragmentation/keeper assumptions. | **Retain; formal disposition pending** |

## Risks for explicit Guardian disposition

### `KR-01` — JPY/USD round age is not the same as market-price freshness

- **Current behavior:** normal redemption requires the JPY/USD round used by the
  current source to be younger than 108,000 seconds. Other consumers retain the
  shared provider's 72-hour staleness policy and 24-hour freeze episode. The code
  has no Forex market-hours or holiday calendar.
- **Market-hours condition:** Chainlink recommends using standard Forex feeds
  only during their stated market hours. A same-value heartbeat can refresh
  `updatedAt` while the underlying market is closed, so the 30-hour check can
  remain open without new price discovery. See the
  [Chainlink market-hours guidance](https://docs.chain.link/data-feeds/selecting-data-feeds#market-hours).
- **Project observations:** a phase-aware review of 7,214 active Ethereum JPY/USD
  feed events and 114
  Sunday market opens found no open where round age had reached 30 hours. The
  largest JPY weakening at the first changed round after those opens was 0.2168%.
  A separate sub-30-hour candidate showed a 0.6934% step after a same-value
  heartbeat and a 1.4038% two-step cumulative move. These observations show that
  the age gate is not a market-hours gate; they do not prove exploitable profit.
  The dataset, extraction rule, candidate events, and reproduction command are
  in [the supporting analysis](./JPYUSD_MARKET_HOURS_RISK_ANALYSIS.md).
- **Freeze re-anchoring condition:** before an episode expires, a valid
  monotonically newer round can be adopted even when already stale. That updates
  `lastGoodJpyUpdatedAt` and re-anchors `jpyFrozenSince`. Repetition can extend
  urgent-path stale-FX exposure beyond 96 hours from the original fresh
  observation. After expiry, only a fresh response clears the latch.
- **Impact conditions:** stale JPY data must overlap with a favorable FX move,
  reachable debt and collateral, executable redemption, and exit liquidity.
  Oracle users cannot force Chainlink to publish the required sequence.
- **Project scenario, not a security bound:** using the intended initial branch
  caps and collateral ratios, the project's static normal-redemption exposure
  estimate is approximately 127.06 million JPYdf. Its cost-free model estimates
  attacker profit of approximately JPY 119,000 for a 5% gap and JPY 501,000 for
  a 10% gap; gas, slippage, funding, and exit costs are excluded. Guardian should
  treat both the model and its assumptions as project-supplied context rather
  than a security bound. The linked supporting analysis gives the equations,
  attacker-favorable assumptions, persistent-gap case, JPYdf depeg sensitivity,
  and exit constraints.
- **Current view:** the 30-hour check remains a partial feed-silence mitigation.
  A weekly market-hours stop would remove normal redemption for roughly 49 hours
  each week and add calendar logic. Exact-answer-change and small basis-point
  clocks were also considered but are not selected for launch because they
  regularly remove redemption availability and the available history does not
  establish a defensible threshold. Adding a second clock later is not treated
  as a parameter-only change. Engineering currently proposes a time-limited
  conditional retention, but it is not approved: project risk-owner approval, a
  loss budget, independent-FX monitoring, verified alert delivery, and a named
  re-evaluation owner remain pending. No further Solidity change is selected at
  present.
- **Guardian request:** validate the market-hours, same-value heartbeat, and
  stale-but-newer sequences; assess impact and likelihood independently; and
  report this as a vulnerability if warranted. Also state whether the current
  design requires a market-hours gate, a 24/7 reference, dynamic fees, a smaller
  exposure cap, or another control.

The often-used “up to 96 hours” description is accurate only for one readable
round that simply ages without an earlier invalid response, same-value market
closure issue, or pre-expiry re-anchoring.

### `KR-02` — recoverable oracle pause does not veto a live economic shutdown

- **Current behavior:** `failure=true` enters a recoverable oracle pause and is
  not used for `TCR < SCR`. Risk-increasing BorrowerOperations remain stopped
  until Owner resume obtains valid non-failure returns from the source's normal,
  redemption, and urgent quote methods in one transaction. Normal redemption
  also has an independent gate over the JPY/USD round and status returned by
  the current source and may remain
  unavailable after resume. Once the normal live price recovers, liquidation,
  risk-reducing borrower actions, and permissionless `TCR < SCR` evaluation can
  resume before Owner action.
- **Residual condition:** resume is a three-method health check. It does not
  enforce price-continuity/deviation bounds, and aged or invalid JPY provenance
  may still produce `healthy=true` while withholding the redemption-cache update
  and leaving Proxy normal redemption independently unavailable.
- **Current view:** this preserves Liquity's permissionless wind-down for a
  genuinely unsafe branch without allowing a failed price to create an
  irreversible false shutdown. Making the live-price transition Owner-dependent
  would give Governance a veto over legitimate wind-down. Separately, Owner
  resume is the explicit human approval boundary for re-enabling risk-increasing
  operations. The project instead plans an Owner pre-execution check of all
  three quote paths and the JPY/USD round status against independent references;
  that evidence remains a project-owned launch check.
- **Guardian request:** verify the ordering and every call path that can reach
  terminal shutdown, especially that no failure-bearing price is used and that
  risk-increasing operations remain latched. Assess the impact of a discontinuous
  quote or aged/invalid provenance at resume and whether the Owner-controlled
  treatment is proportionate.

### `KR-03` — urgent settlement deliberately fails closed

- **Current behavior:** urgent redemption has no cache or direct-only fallback.
  Every policy-required oracle leg, canonical-rate read, JPY conversion, and
  pricing-available backing-ratio read must succeed. Vault pricing may use a live
  Strategy valuation or a still-fresh bounded cache; an unavailable read with no
  valid cache fails closed. A failure reverts the transaction without partial
  state change.
- **Joint-failure risk:** permanent source failure plus an unavailable
  PriceFeed Owner / Safe can prevent source replacement, Trove closure,
  progression to irreversible shutdown, and urgent redemption for an extended
  period. If Governance is available, a new source can be proposed and confirmed
  after the Proxy's 12-hour delay.
- **Current view:** stale/cache settlement can transfer value at an invalid
  price, while a timeout cannot manufacture a valid quote. The current design
  chooses price integrity over guaranteed exit availability.
- **Guardian request:** assess the dependency conjunction and recovery model.
  A degraded-settlement mechanism would be a new policy and audit target, not a
  small patch to this SOW.

### `KR-04` — the redemption formula protects solvency, not best execution

- **Current behavior:** wstETH normal and urgent redemption use
  `max(stETH/USD, ETH/USD × stETH/ETH)`, then the canonical wstETH rate, JPY/USD,
  and the pricing-available dToken backing ratio (live Strategy valuation or a
  still-fresh bounded cache). Both reference legs fail closed. The constructor
  does not hard-code stETH/ETH age; the intended deployment parameter is 90,000
  seconds and must be proven by candidate-bound readback.
- **Residual effect:** a policy-valid stale-high leg can make collateral appear
  more valuable and underpay a redeemer. Using `min`, a simple freshest-only
  rule, or direct-only continuation can instead make stale-low data permit
  collateral extraction from remaining borrowers.
- **Current view:** retain the borrower/solvency-protective `max` polarity and
  fail-closed threshold. Raising the threshold to 172,800 seconds only enlarges
  the stale-high window; an absolute cap with the same fail-closed behavior only
  moves the pause boundary.
- **Guardian request:** confirm the formula, polarity, staleness semantics, and
  failure behavior, and explicitly characterize the redeemer-fairness trade-off.

### `KR-05` — emergency source confirmation trades continuity guards for recovery

- **Current behavior:** normal confirmation compares normal, redemption, and
  urgent prices with their continuity references. Emergency confirmation keeps
  the same 12-hour delay and calls the proposed source's normal, redemption, and
  urgent quote methods, requiring valid non-failure returns. It deliberately
  does not call the broken old source and bypasses all three deviation guards
  together. Aged-but-valid JPY provenance can still be accepted while the
  redemption cache update is withheld.
- **Residual condition:** operator error or a compromised owner could confirm a
  large discontinuity. The validation calls prove current ABI/value availability,
  not price correctness after the switch.
- **Current view:** a per-leg emergency bypass requires another state machine and
  test/audit surface. Keep the present recovery path with role-controlled
  execution. Before Owner execution, the project plans to compare all three
  proposed-source quotes and the JPY/USD round status with independent
  references; role and monitoring evidence remain project-owned launch checks.
- **Guardian request:** verify that the bypass cannot skip the delay or the three
  proposed-source quote-method calls, account separately for the provenance
  gate, and assess whether the all-leg bypass is proportionate.

### `KR-06` — Proxy acceptance does not prove semantic acyclicity

- **Current behavior:** `_isPriceFeedProxy` is a one-level marker. During source
  confirmation the proposed source's three paths execute before
  `source = proposedSource`; an unmarked forwarding adapter can call back through
  the old healthy source, pass the validation and zero-deviation checks, then form a
  cycle after assignment.
- **Current view:** exploitation requires privileged proposal and confirmation.
  The engineering position is to retain the Low-severity boundary under the
  12-hour lifecycle and human review instead of adding a callback latch to the
  permanent contract. Address/codehash records and validation calls alone are not
  accepted evidence.
- **Guardian request:** challenge the severity and current non-code treatment.
  The sole accepted proof method is the recursive procedure in
  [`FINAL_PRODUCTION_DEPENDENCY_GRAPH.md`](./FINAL_PRODUCTION_DEPENDENCY_GRAPH.md),
  bound at deployment to addresses, runtime hashes, implementations, immutable
  bindings, mutable routers, and administrators.

### `KR-07A` — Vault backing checks can stop availability

- **Current behavior:** the Vault first counts raw underlying. When that alone
  covers liabilities, a user path need not call every Strategy. If it is
  insufficient, only available live Strategy valuations count; an unavailable
  Strategy contributes zero. Deposit, redeem, claim, or nonzero allocation can
  therefore stop during valuation failure or underbacking. Backstop deposits,
  Strategy recovery, writeoff/accounting, and other specified recovery functions
  remain available.
- **Current view:** retain the backing rule above. Cached value must not
  reopen user paths without a separately designed and audited insolvency policy.
- **Guardian request:** verify that the backing checks precede token, permit, and
  queue mutations, that unavailable Strategy value cannot pass the gate, and
  that every intended recovery path remains usable.

### `KR-07B` — a partial recovery does not renew full-valuation confidence

- **Prior audit boundary:** Chain Defenders `L-03` is `Acknowledged`, not `Fixed`.
  A partial Strategy receipt reduces the cached value but does not refresh its
  timestamp. The receipt does not revalue the residual upstream position;
  refreshing the timestamp could indefinitely renew an old high cache containing
  unobserved loss.
- **Current view:** retain the original full-valuation TTL. Live-read recovery
  restores availability without Governance; a full permissionless refresh can
  then repopulate the cache. This cache rule is distinct from the new
  backing rule in `KR-07A`.
- **Guardian request:** confirm that the current delta does not accidentally
  weaken or misrepresent the acknowledged `L-03` boundary.

## Required context and launch-only risks

These facts affect the conclusions above, but they are not requests to audit
deployment scripts, operations tooling, or unchanged external protocols.

### `KR-08` — a live backing guard cannot observe an unreported external loss

The guard is only as complete as the live Strategy valuation and assets it can
read. An external venue loss that has not yet appeared in those reads remains a
systemic exposure. The project manages it with approved per-Strategy exposure,
same-Underlying backstop capacity, loss scenarios, monitoring, pause/recovery
procedures, controls, and production-topology evidence. Guardian should validate the
integration assumptions needed to assess the changed Vault code, but this SOW does
not ask for a whole-source re-audit of Aave, Morpho, or other venues.

### `KR-09` — reserved-risk finalization is intentionally one-shot

`AddressesRegistry.finalizeRiskParams` enforces authorization, empty Core state,
zero dToken cap/supply, DToken/Vault/Underlying identity, non-shutdown state,
parameter bounds and ordering, and atomic synchronization of AddressesRegistry,
BorrowerOperations, and TroveManager. It
does not prove real source/Proxy wiring, Vault liabilities and queued claims,
live backing, or Strategy readiness. A wrong finalized value is permanent.

Guardian is asked to review the on-chain one-shot boundary. The project—not the
source audit—owns signed activation preflight, exact post-call readback, and cap
opening as the final independent step.

### `KR-10` — urgent failure semantics depend on exact Proxy wiring

`TroveManager.urgentRedemption` consumes the price but discards the returned
failure boolean. This is safe under the required `PriceFeedProxy`, which reverts
on urgent source failure. A directly registered source could instead return a
fallback price with `failure=true`. Every deployed branch must therefore prove
that the registered address is the reviewed Proxy and that its source and all
dependencies match the approved graph. `AddressesRegistry.setAddresses`
renounces ownership after wiring, while BorrowerOperations and TroveManager keep
the resulting PriceFeed binding. A direct-source miswire is therefore permanent
for that branch rather than repairable by later Proxy source rotation. Direct
source registration is unacceptable for production.

### `KR-11` — mint capacity is not debt capacity

Reducing or exhausting dToken `mintCap` prevents new dToken supply; it does not
prevent additional JPYdf debt against dToken collateral already held by a
borrower. The current architecture does not add a protocol-level hard branch debt
ceiling. Exposure is managed through dToken supply/cap policy, collateral ratios,
Stability Pool coverage, branch visibility, cap-ramp approval, and monitoring.
Any hard debt ceiling would require a separate design, implementation, and
audit; no auditor report should describe `mintCap` as such a ceiling.

### `KR-12` — contract size constrains implementation, not findings

The frozen artifacts record TroveManager runtime at 24,570 bytes and
BorrowerOperations at 24,531 bytes, leaving 6 and 45 bytes respectively below
EIP-170. This is not a reason to downgrade or reject a valid finding. A required
fix may need deletion, refactoring, or a deliberately reviewed architectural
change, followed by the production size gate and a new immutable audit head.

### `KR-13` — Zapper referral safety assumes canonical Lido contracts

The active Zapper resolves stETH through the configured wstETH contract and
checks that it matches the configured stETH address. It then calls
`stETH.submit(lidoReferral)` and credits the received balance delta. The claim
that referral changes cannot redirect funds depends on those deployed contracts
having the canonical reviewed Lido stETH/wstETH identity and `submit(address)`
semantics. Guardian should review the changed Zapper integration; launch evidence
must bind the configured addresses, runtime hashes, immutable relation, and
called semantics. A look-alike contract satisfying only the getter/ABI is not
sufficient.

### `KR-14` — two generic defaults depend on the current topology

- The default Composite urgent getter can write the normal last-good cache. The
  current production graph does not use that default on an active Composite
  source, and Standard sources use equal urgent and normal formulas. Reopen this
  question before another active Composite source uses the default getter.
- Source confirmation uses the redemption cache as the old urgent continuity
  reference. Current sources have equal relevant formulas. Add a dedicated
  urgent baseline or reopen the lifecycle review before a source has divergent
  redemption and urgent formulas.

These are constraints on the exact production source graph, not claims that the
generic defaults are universally safe. The default Composite getter change is
included as inheritance context. The continuity behavior is also reviewed as
context for the included Proxy lifecycle change.

### `KR-15` — `MIN_DEBT` is a shared anti-dust and state threshold

The base-to-final change lowers `MIN_DEBT` from `300_000e18` to `100_000e18`.
It applies to open/adjust entire debt including the upfront fee, but reachable
unchanged code also uses it for normal-redemption zombification, zombie
reactivation, and repayment clamping. The current product position is to retain
100,000 JPYdf. Guardian should assess the complete use set and the lower
anti-dust/state-fragmentation threshold rather than treating it only as an entry
minimum. Full close and urgent-redemption residual behavior remain distinct.
Exact-boundary tests do not prove the economic capacity assumption: the pending
project evidence must still model list growth, redemption gas, liquidation and
keeper viability at the intended branch exposure.

## Remediated or reviewed non-residual items

The project does not currently classify the following as residual risks.
Guardian should nevertheless report any incomplete remediation, regression, or
independently identified vulnerability as a finding:

- A recovered live normal price permits only risk-reducing borrower adjustments
  before Owner resume; risk-increasing adjustments remain latched.
- Configured JPY/USD decimals are checked before fresh or stale-but-newer
  adoption. An ordinary mismatch or read failure rejects adoption and enters the
  bounded last-good soft-freeze policy; a gas-exhaustion revert still bubbles.
  No mismatched-scale value is cached or adopted.
- Active launch risk inputs are validated by the excluded deployment script;
  reserved values are independently rechecked by the included one-shot
  finalizer. This layering is intentional, while exact deployed inputs remain
  project-owned readback evidence.
- Temporary test/pilot overrides were removed from the final source. Their
  absence is a machine check, not another review objective.
- Off-chain alert deduplication and delivery are operations requirements, not
  Solidity findings. Source initialization and change controls are reviewed in
  the included lifecycle changes; their remaining boundaries are `KR-05` and
  `KR-06`.

## Pending launch evidence — not source-audit completion

The following remain pending even if Guardian reports no source-code finding:

- deployment-bound Proxy/source/dependency addresses, runtime hashes, routing,
  implementations, owners, and role readbacks at one pinned block;
- a fresh production Timelock with 43,200-second delay, complete role/event/
  pending-operation history, and separation from the 300-second canary;
- reserved-branch preflight and evidence that the mint cap is raised only after
  all other activation checks pass;
- production Strategy topology, same-Underlying backstop/headroom, recovery and
  mainnet-fork evidence;
- economic capacity evidence for the 100,000-JPYdf minimum-debt threshold;
- enabled external monitoring with end-to-end human delivery for stETH/ETH age,
  runtime decimals, JPY/USD age and independent-FX divergence, Vault valuation
  and backing, and blocked user paths. JPY monitoring must not be defeated by a
  same-value heartbeat or stale-but-newer re-anchoring; and
- formal project risk-owner approval, loss budgets, expiry/re-evaluation owner,
  and publication evidence for retained public risk disclosures.

## Future changes that reopen review

- activating the legacy StabilityPool or archived Sky Zapper excluded by the
  current SOW;
- either `KR-14` topology change: activating another Composite source that
  relies on the default urgent getter, or adding a source whose normal,
  redemption, and urgent formulas diverge;
- adding a wrapper collateral without an on-chain market/depeg leg;
- activating an asynchronous Strategy without approved pending-principal,
  withdrawal, pricing, and incident behavior;
- changing JPY/USD age/freeze policy, the wstETH polarity or staleness thresholds,
  emergency confirmation, or branch debt-cap architecture; or
- changing any production Solidity after tree `84476d90`.

## Supporting references

| Source | How to use it |
| --- | --- |
| [`GUARDIAN_ADDITIONAL_AUDIT_HANDOFF.md`](./GUARDIAN_ADDITIONAL_AUDIT_HANDOFF.md) | Current final-candidate behavior and audit narrative. |
| [`FINAL_PRODUCTION_ENGLISH_AUTHORITY.md`](./FINAL_PRODUCTION_ENGLISH_AUTHORITY.md) | Current rules and explicit corrections to stale retained text. |
| [`FINAL_PRODUCTION_DEPENDENCY_GRAPH.md`](./FINAL_PRODUCTION_DEPENDENCY_GRAPH.md) | Source topology and the deployment-binding procedure. |
| [`JPYUSD_MARKET_HOURS_RISK_ANALYSIS.md`](./JPYUSD_MARKET_HOURS_RISK_ANALYSIS.md) | Reproducible JPY/USD observations, economic model, assumptions, and unapproved treatment conditions. |
| [`evidence/external-audit/final-2026-08/README.md`](../../evidence/external-audit/final-2026-08/README.md) | Chain Defenders final statuses and immutable PDF/hash index. |
| [`evidence/external-audit/preliminary-2026-08/findings/l-03.md`](../../evidence/external-audit/preliminary-2026-08/findings/l-03.md) | Exact rationale and tests for the acknowledged Vault cache boundary. |

## Response requested from Guardian

For `KR-01` through `KR-07B` and the code-use portion of `KR-15`, please verify
the code facts, assign an independent severity where applicable, and distinguish
among a vulnerability requiring remediation, an intentional design boundary,
and an operational assumption. Guardian is expressly free to report any known
risk again as a finding. For `KR-08` through `KR-14`, identify any source
conclusion that depends on a stated deployment or future-topology assumption,
without treating pending deployment evidence as complete. `KR-15` economic,
list-growth, gas, and keeper capacity remains project-owned launch evidence.

Please do not describe a project engineering recommendation as formal risk
acceptance. Guardian supplies an independent technical assessment; the project's
designated risk owner makes the treatment decision. Do not relabel Chain
Defenders `L-03` as `Fixed`, and do not infer that an out-of-scope or
deployment-owned risk is safe.
