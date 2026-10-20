# Historical rationale for the normal-redemption-only 30-hour gate

This note preserves the pre-remediation design for the Guardian technical discussion.
It supplements [KR-01](./KNOWN_RISKS_AND_CURRENT_POSITION.md#kr-01--jpyusd-round-age-is-not-the-same-as-market-price-freshness)
and the [market-hours risk analysis](./JPYUSD_MARKET_HOURS_RISK_ANALYSIS.md).
It does not change the [audit scope](../../SCOPE.md), frozen source, or risk
acceptance status.

## Remediation policy under test

The September 10 client/Guardian exchange supersedes the previous preference
for retaining the 72-hour borrowing policy. The proposed 30-hour restrictions,
price-independent safe adjustments, and conditional 24-hour liquidation grace
are recorded in [Guardian remediation tracking](./GUARDIAN_REMEDIATION.md#oracle-correspondence-implemented-candidate-policy).
PR #127 implements the candidate and its behavioral tests; final economic-risk acceptance remains separate. The
remaining analysis describes the frozen baseline and its historical rationale,
not approval to retain that policy for launch.

## Incident and decision history

The [BOLD incident and remediation record](./BOLD_INCIDENT_AND_ORACLE_REMEDIATION_HISTORY.md)
reproduces the observed transaction, implementation sequence, and decision to
retain borrowing and liquidation. Its explanation and supporting source/test
links are available entirely within this audit package or public Ethereum and
Liquity sources. The BOLD collateral/USD event motivates redemption protection;
it does not establish the correct threshold for JPY/USD staleness.

## Purpose and affected paths

The gate limits normal redemptions that could pay out excess collateral using
a stale JPY exchange rate, while preserving liquidations, collateral-health
checks, and the final exit path after an irreversible branch shutdown.

The frozen [PriceFeedProxy](../../source-snapshot/contracts/src/PriceFeeds/PriceFeedProxy.sol)
sets `MAX_NORMAL_REDEMPTION_JPY_AGE = 30 hours` (108,000 seconds).
On a successful source read, normal redemption checks the current source's
shared JPY provider `lastGoodJpyUpdatedAt`. At an age of 30 hours or more, or
with invalid provenance, it returns `failure=true`; each active branch sharing
that provider fills zero normal redemption when it reaches this check.
The gate does not reallocate the unfilled share to other branches or burn the
unfilled JPYdf. This age gate does not latch a BorrowerOperations
oracle pause or update the redemption cache. A fresh accepted round allows
normal redemption to resume automatically, subject to the other checks.
Actual source failures retain their separate failure handling.

## A blanket 30-hour gate also stops protective operations

Applying the gate to every path would prevent stale-price settlements and
collateral assessments. However, making the shared normal-price `fetchPrice()`
fail at 30 hours would also stop the following operations in the current
callers. This follows from `BorrowerOperations._adjustTrove`,
`_requireOraclesLive`, and `shutdown`, and from
`TroveManager.batchLiquidateTroves`.

| Path | Benefit of stopping at 30 hours | Cost while stopped |
| --- | --- | --- |
| New borrowing, debt increases, collateral withdrawals | Prevent risk increases based on overstated collateral headroom. | Reduces availability for new positions and adjustments. Keeping liquidation available does not itself justify keeping this path open. |
| Liquidation | Prevent liquidation based on an incorrect stale price. | Genuinely unsafe Troves also remain unliquidated. Further collateral declines or JPY strengthening can increase debt beyond recoverable collateral. |
| Collateral additions and partial repayments | Stop operations that depend on the shared price check. | These currently pass through `_requireOraclesLive()` too, so a blanket failure prevents borrowers from improving collateral coverage. |
| TCR<SCR shutdown assessment | Prevent an erroneous stale-price shutdown. | A genuinely unsafe branch cannot transition to irreversible shutdown through this assessment either. |
| Urgent redemption | Prevent stale-price collateral transfers after shutdown. | The final redemption path stops until pricing recovers; loss of the recovery path can make this indefinite. |

Normal redemption itself supports JPYdf peg recovery, so stopping it also has
a cost. The current design is a partial mitigation: first restrict the path
that exchanges JPYdf for existing borrowers' collateral at stale FX prices,
while retaining the shared provider policy for liquidation, collateral
improvement, shutdown assessment, and final redemption. This does not establish
that it is always safer than stopping every path.

## Borrowing protections and retained stale-FX exposure

### Prior analysis already includes FX stress in MCR

The [2026-07-27 parameter rationale included in this package](../en/engineering/historical-reviews/2026-07-27-Collateral-Parameter-Rationale.md)
provides the historical data summary and formula used below.
The records use 360,781 five-minute JPY/USD observations from 2021-01-18 to
2026-01-16, excluding 270 outliers, and select a two-hour 99.9th-percentile FX
stress of 1.17%; the historical table also reports a two-hour maximum downside
of 2.29%. For dUSDC, the selected formula is
`MCR = 1 / ((1 - 0.0932) * (1 - 0.0117))`, combining a 9.32% USDC downside
with FX stress. Rounded inputs reproduce approximately 111.5834%, consistent
with the 111.58% candidate. dwstETH also incorporates FX stress. It would be
incorrect to say the design ignored FX or had no borrowing-risk analysis.

The assumed liquidation-completion horizon in that analysis is two hours.
The reviewed records did not supply 30/48/72/96-hour outage distributions or
loss estimates with new borrowing admitted throughout. Applying the selected
USDC and FX haircuts jointly leaves approximately 99.9969% collateral coverage
using rounded values: approximately principal coverage, not an unused 11.58-point
FX-only reserve. Raw observations were not re-fetched to verify quantiles or
currency-pair direction; the historical table's downside statistic must not be
silently equated with this note's increase in USD per JPY.

We also reviewed the [72-hour threshold decision](../en/protocol/launch/decisions/jpyusd-staleness-threshold-determination.md)
and [2026-06-10 boundary-test review](../en/engineering/historical-reviews/2026-06-10-fx-stale-handling-review.md).
The former supports an availability margin over observed roughly daily updates,
not a quantified long-outage borrowing-loss limit. The latter primarily verifies
60-hour acceptance and the 72-hour boundary, not economic safety approval.

### Verified admission checks and their limits

A new solo Trove must satisfy MCR using debt including the upfront fee, and its
post-transaction branch TCR must satisfy CCR. Batches require MCR+BCR, but the
solo route is available, so BCR is not universal protection. Debt increases on
existing Troves also check ICR and the applicable normal/critical-mode TCR
constraints. All of these use the same oracle price.

The normal path continues to evaluate collateral/USD and dToken backing; a
stale JPY rate does not freeze every price input. Together with the MCR buffer,
this supports some tolerance for FX lag. However, the normal-redemption gate,
Vault `pauseDeposit()`, and caps limiting new dToken minting do not block direct
Core borrowing with already-held dToken or debt increases on existing collateral.

### FX-only margin calculation

Let `q` be USD per JPY and `r = current q / saved q`. JPY strengthening means
`r > 1`. With accurate, unchanged collateral/USD and backing inputs and JPYdf
valued at one yen, `true ICR = oracle ICR / r`. For a solo Trove opened exactly
at the intended Day1 MCR:

| Branch | MCR | True ICR at q +5% | True ICR at q +12% | q increase reaching 100% principal coverage |
| --- | ---: | ---: | ---: | ---: |
| dwstETH | 123.18% | 117.3143% | 109.9821% | 23.18% |
| dUSDC | 111.58% | 106.2667% | 99.6250% | 11.58% |

These percentages refer to USD per JPY, not the inverse USD/JPY quotation:
dUSDC's 11.58% threshold corresponds to a roughly 10.3782% USD/JPY fall. The 5%
case retains gross principal coverage, but true ICR is below MCR, so liquidation
may follow price recovery. The 100% boundary does not provide room for liquidation
costs, penalties, or slippage. JPYdf market price, accrued interest, and unreflected
collateral moves or losses also matter. This is an FX-only stress calculation,
not an estimate of a 12% move's likelihood or executable attacker profit.

### Counterexample despite healthy aggregate CCR

Take a dUSDC branch with existing debt of JPY 1,000,000 and saved-price collateral
value of JPY 2,000,000. Add a solo Trove with total debt of JPY 1,000,000 and
saved-price collateral of JPY 1,115,800. Its ICR is 111.58% and post-transaction
TCR is 155.79%, passing MCR and CCR (124.50%). Total debt includes the upfront
fee, so the borrower receives less than the total debt amount.

At `r = 1.12`, the new collateral is actually worth JPY 996,250, leaving a
JPY 3,750 gross principal shortfall. Even true aggregate TCR remains above CCR;
healthy aggregate collateralization does not prevent this individual shortfall.
With other feeds healthy, no pause, and already-held dToken available, a saved
round age of 48 hours closes the normal-redemption gate while remaining valid
for normal pricing under the intended 72-hour provider threshold. Same-value
heartbeats can preserve analogous price discrepancies below 30 hours too.

The [reproducible model](./stale_jpy_borrowing_model.py) was run with
`python3 docs/audit/stale_jpy_borrowing_model.py`.
Its exact fraction assertions verify the arithmetic and MCR/CCR conditions.
The included [age-gate suite](../../source-snapshot/contracts/test/PriceFeedProxyJpyRedemptionAge.t.sol)
was run successfully against the matching implementation source. Auditors can
reproduce it from `source-snapshot/contracts` with
`forge test --match-path test/PriceFeedProxyJpyRedemptionAge.t.sol -q` after the
[documented dependency setup](./BUILD_AND_TEST.md). It checks gate boundaries
and path separation, not EVM execution of this borrowing scenario.

### Historical position: 72-hour shared policy and 30-hour redemption gate

The frozen design retains the shared JPY provider's intended 72-hour staleness
threshold for borrowing, debt increases, collateral withdrawals, liquidation,
TCR/SCR assessment, and urgent redemption, subject to each path's other checks.
Normal redemption alone has the additional 30-hour age gate. The provider also
has a 24-hour soft-freeze mechanism; 72 hours is not an unconditional execution
window or an absolute maximum age of every usable quote.

We prioritize earlier protection against redemption transferring existing
borrowers' collateral at stale FX prices. For the other paths, we retain the
existing availability policy to avoid false stops of a dependency shared across
branches. Borrowing continues to require MCR and branch-level collateral checks,
with FX stress included in the parameter design, while collateral/USD and
dToken backing remain evaluated. Liquidation, collateral improvements, and
shutdown assessment can therefore remain available when their other conditions
pass. These were the reasons for the frozen design’s asymmetry.

The stress calculations above document the limits of those protections:
large FX discrepancies can exhaust the collateral buffer, and the earlier
two-hour analysis does not quantify losses over a prolonged outage with new
borrowing. We present this retained exposure to Guardian for assessment of the
current design, including discrepancy size, reachable borrowing volume, and
recovery and response times. The design position does not replace the separate
risk-acceptance conditions or establish safety throughout the stale window.

The project reports that its operator bot rejects stale JPY rounds or an active
soft-freeze. This operational observation is outside this Solidity package;
Core liquidation availability alone does not establish keeper availability.

## Oracle failure pauses can be recovered

The 30-hour age gate clears automatically when a fresh round is accepted.
A latched, recoverable oracle-failure pause is cleared separately: after the
source's normal, normal-redemption, and urgent price paths are healthy, the
Proxy Owner calls `resumeFromOracleFailure()` to validate all three paths and
resume. If the source itself is defective or retired, the Owner can replace it
through the prescribed timelock and validation process. Normal redemption must
also pass its independent 30-hour gate before it can execute.

An irreversible branch shutdown, such as one caused by TCR<SCR, cannot be
reversed by this operation. A recovered live source can make urgent redemption
available again, but exits are not guaranteed if the required feeds and the
Owner recovery path both become permanently unavailable.

## Illustrative collateral overpayment

Assume JPYdf trades at one yen, the collateral's USD value is unchanged, and
ignore redemption fees and execution costs:

- The oracle still implies JPY 150 per USD, while the current rate is JPY 160
  per USD after the yen weakens.
- Redeeming 15,000 JPYdf at the stale rate pays out USD 100 of collateral.
- At the current rate, USD 93.75 of collateral would cover the same yen amount.

The USD 6.25 difference is excess collateral transferred from the redeemed
borrower's Trove. This can occur with a fully backed vault: the vault can burn
dToken and release matching underlying without recording an accounting loss.
The example illustrates the transfer mechanism, not executable attacker profit;
actual fees, funding, routing, and exit liquidity matter. The linked risk
analysis models those economic conditions in more detail.

## Limits and questions for Guardian

Thirty hours is not a guarantee of safe pricing before the boundary. Sharp FX
moves within that period remain possible. A same-value heartbeat can also
refresh `updatedAt` without new FX price discovery, so this is a feed-silence
gate, not a market-hours gate.

Other consumers retain the shared provider's configured staleness threshold
(intended deployment value: 72 hours) and its 24-hour freeze constant. The
threshold is a constructor parameter in
[JpyUsdRateProvider](../../source-snapshot/contracts/src/PriceFeeds/JpyUsdRateProvider.sol),
so its deployed value requires readback. Under that intended configuration,
96 hours is not an absolute bound from the original observation: stale-but-newer
rounds can re-anchor an unexpired freeze, as described in KR-01.

The retained exposure includes three distinct cases:

- New borrowing increases risk. Keeping liquidation available does not by
  itself justify allowing new debt at the same stale price. Collateralization
  buffers provide some protection, but their adequacy against JPY strengthening
  during the stale window requires a separate assessment.
- A stale-high USD-per-JPY rate undervalues collateral in JPY and can cause
  liquidation of an otherwise healthy Trove or an erroneous TCR<SCR shutdown.
- After irreversible shutdown, urgent redemption uses the shared JPY rate
  without the additional 30-hour gate and includes a 2% collateral bonus
  ([constant](../../source-snapshot/contracts/src/Dependencies/Constants.sol),
  [settlement](../../source-snapshot/contracts/src/TroveManager.sol)). The same
  stale-FX overpayment mechanism remains possible, subject to available
  collateral and other checks; the normal gate does not bound this transfer.

The 30-hour normal-redemption gate follows the proposal for a 24-hour
heartbeat plus grace (26–30 hours).
The reviewed material still does not quantify why 30 hours was selected over
26 hours, or establish safety throughout that window.

For the technical discussion, we request Guardian's assessment of:

- Whether limiting the extra gate to normal redemption leaves unacceptable
  borrowing, wrongful-liquidation, false-shutdown, or urgent-redemption exposure.
- Whether the 30-hour threshold is justified by feed behavior and the economic
  impact of both stale settlement and interrupted redemption availability.
- Whether same-value heartbeats and freeze re-anchoring require further
  mitigation. Guardian may report a vulnerability and assign severity
  independently of the project's current design position.

## Independent model review

Claude `fable` (reported model: `claude-fable-5-1`) reviewed the note against
frozen source and tests on 2026-09-07. It confirmed the stated gate behavior and
arithmetic, found no gate-code defect within its review, and judged the
asymmetry a plausible trade-off whose retained exposure is not established as
acceptable. Its corrections on deployment configuration, shared-provider scope,
and remaining consumer risks are reflected above. It found no quantitative
30-hour derivation in the reviewed repository. This model review is not an
external audit or risk-owner approval.

A follow-up Fable review confirmed the borrowing model arithmetic and MCR/CCR
conditions. Its statement
that roughly 6.27% FX movement causes SP principal loss was not adopted:
full receipt of the 5% liquidation bonus is different from principal recovery,
and keeper compensation also matters. The historical-parameter reconciliation
was performed after that follow-up. Neither model review re-measures FX
probabilities or executes the borrowing scenario in the EVM.
