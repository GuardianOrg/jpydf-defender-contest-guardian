# JPY/USD Market-Hours Residual Risk Analysis

**Candidate:** `1b453c10e3378390109cf42037a97b7f6de57b9e`

**`contracts/src` tree:** `84476d9086e89580c58918b203f4142ecd839765`

**Status:** project analysis; proposed treatment is not approved

This appendix gives Guardian the data provenance, calculation method, economic
model, assumptions, and pending treatment conditions behind `KR-01` in
[`KNOWN_RISKS_AND_CURRENT_POSITION.md`](./KNOWN_RISKS_AND_CURRENT_POSITION.md).
It is supporting analysis, not an external-audit result, formal risk acceptance,
or an expansion of the code-review boundary in [`SCOPE.md`](../../SCOPE.md).
Guardian should independently assess the code condition, impact, likelihood,
and proposed treatment and may report the condition as a vulnerability with its
own severity. The dataset and economic model are project-supplied severity
context. Independently re-extracting the complete dataset or reconstructing the
model is not a required deliverable unless added to the written SOW.

## 1. Condition being evaluated

Normal redemption checks that the JPY/USD round used by the current source is
younger than 108,000 seconds. This detects a long absence of published rounds,
but it is not a Forex market-hours check. A same-value heartbeat can publish a
new `updatedAt` while the underlying market is closed, so a recent round
timestamp does not prove recent market price discovery.

The adverse direction considered here is:

1. the feed retains an old, high USD-per-JPY value while JPY weakens;
2. collateral is therefore valued too low in JPY;
3. normal redemption transfers more collateral than a fresh JPY/USD rate would;
   and
4. the excess transfer is borne principally by borrowers whose Troves are
   redeemed.

The 30-hour gate still mitigates prolonged feed silence. It does not eliminate
sub-30-hour lag, market-closure lag, or the separate stale-but-newer freeze
re-anchoring condition described in `KR-01`.

Chainlink describes standard Forex feed hours as Sunday 18:00 ET through Friday
17:00 ET, with Christmas and New Year closures, and recommends using those
feeds only during their specified market hours. A 24/7 Forex feed is a separate,
crypto-derived feed class. See
[Chainlink's market-hours guidance](https://docs.chain.link/data-feeds/selecting-data-feeds#market-hours).

## 2. On-chain observations and reproduction

### 2.1 Dataset

| Field | Value |
| --- | --- |
| JPY/USD proxy | `0xBcE206caE7f0ec07b545EddE332A47C2F75bbeb3` |
| Phase 4 aggregator / active blocks | `0x01A1F73b1f4726EB6EB189FFA5CBB91AF8E14025` / `20,186,462..20,428,699` |
| Phase 5 aggregator / active blocks | `0xA0B5260BDfD1011C4bcdc7A099C75BFf6340B38C` / `20,428,700..25,876,172` |
| Phase switch | block `20,428,700`, 2024-07-31 19:43:59 UTC, transaction `0xa75ffcc7a6fc2d0df07fd8b2001396f4f9da1b444739385c844140d033a5c319` |
| Event | `AnswerUpdated(int256 indexed current,uint256 indexed roundId,uint256 updatedAt)` |
| Block range | `20,186,462..25,876,172` |
| Active-feed event time range | 2024-06-28 00:59:23 through 2026-08-31 12:54:47 UTC |
| Phase-aware active `AnswerUpdated` events | 7,214 |
| Official Sunday opens | 114 |

The active proxy phase and both event sets can be checked with any
archive-capable Ethereum mainnet RPC. Do not store the RPC URL in audit
evidence.

```sh
cast call 0xBcE206caE7f0ec07b545EddE332A47C2F75bbeb3 \
  'phaseId()(uint16)' \
  --block 20186462 \
  --rpc-url "$MAINNET_RPC_URL"

cast call 0xBcE206caE7f0ec07b545EddE332A47C2F75bbeb3 \
  'phaseId()(uint16)' \
  --block 20428700 \
  --rpc-url "$MAINNET_RPC_URL"

cast call 0xBcE206caE7f0ec07b545EddE332A47C2F75bbeb3 \
  'phaseAggregators(uint16)(address)' 4 \
  --block 20428699 \
  --rpc-url "$MAINNET_RPC_URL"

cast call 0xBcE206caE7f0ec07b545EddE332A47C2F75bbeb3 \
  'phaseAggregators(uint16)(address)' 5 \
  --block 20428700 \
  --rpc-url "$MAINNET_RPC_URL"

cast logs \
  --address 0x01A1F73b1f4726EB6EB189FFA5CBB91AF8E14025 \
  'AnswerUpdated(int256 indexed current,uint256 indexed roundId,uint256 updatedAt)' \
  --from-block 20186462 \
  --to-block 20428699 \
  --query-size 10000 \
  --rpc-url "$MAINNET_RPC_URL" \
  --json | jq 'length'

cast logs \
  --address 0xA0B5260BDfD1011C4bcdc7A099C75BFf6340B38C \
  'AnswerUpdated(int256 indexed current,uint256 indexed roundId,uint256 updatedAt)' \
  --from-block 20186462 \
  --to-block 20428699 \
  --query-size 10000 \
  --rpc-url "$MAINNET_RPC_URL" \
  --json | jq 'length'

cast logs \
  --address 0xA0B5260BDfD1011C4bcdc7A099C75BFf6340B38C \
  'AnswerUpdated(int256 indexed current,uint256 indexed roundId,uint256 updatedAt)' \
  --from-block 20428700 \
  --to-block 25876172 \
  --query-size 10000 \
  --rpc-url "$MAINNET_RPC_URL" \
  --json | jq 'length'
```

The three event queries should return:

| Query | Expected count |
| --- | ---: |
| Phase-4 aggregator while active | 397 |
| Phase-5 aggregator before activation (shadow history) | 386 |
| Phase-5 aggregator while active | 6,817 |

The original single-address phase-5 query over the complete range therefore
counted `386 + 6,817 = 7,203` events: it mixed inactive shadow history into the
sample and omitted the active phase-4 events. The phase-aware sequence replaces
those 386 events with the 397 active phase-4 events, giving
`397 + 6,817 = 7,214` active `AnswerUpdated` events. The phase switch also
exposes the already-existing phase-5 round 386 at activation; because no new
`AnswerUpdated` event is emitted for that state transition, it is not counted as
another event.

For each Sunday 18:00 ET open, using the applicable US daylight-saving offset,
the project compared:

- the latest round before the open; and
- the first round with a changed answer within 36 hours after the open.

For `q = USD per JPY`, JPY weakening was calculated as
`q_before / q_after - 1`.

### 2.2 Sunday-open results

| Observation | Result |
| --- | ---: |
| Opens where round age was at least 30 hours | 0 / 114 |
| Maximum round age at open | 21.964 hours, 2026-04-05 |
| Maximum wait for the first changed answer after open | 23.103 hours, 2026-05-24 |
| JPY weakening after that 23.103-hour wait | 0.0321% |
| Largest first-changed-round JPY weakening after an official open | 0.2168%, 2024-10-06 |
| Opens exceeding the 0.5025% modeled break-even gap | 0 / 114 |

These observations show that the 30-hour gate generally did not close during
ordinary weekends while rounds continued to be published. They do not prove
future gaps are bounded by the historical maximum.

The phase correction changes none of these headline results. The five official
opens before the phase switch had active phase-4 round ages of 7.034, 6.640,
0.847, 7.680, and 6.804 hours; their largest first-changed-round JPY weakening
was 0.1616%. All maxima and candidate events reported below occurred after the
phase-5 activation.

### 2.3 Sub-30-hour counterexamples

The Sunday-open test does not capture every intraday move or a move beginning
before the official open. For the candidate table below, the project selected a
JPY-weakening step greater than 0.5% after at least eight hours without a changed
answer, then included an immediately following changed round in the same
sequence. The table is not a list of every smaller weakening step.

The corrected active phase-4 history contains 11 weakening steps after at least
eight hours without an answer change. The largest was 0.16736%, and none crossed
the 0.5% candidate threshold, so the phase correction does not add a row below.

| Changed-answer time | Time since prior changed answer | JPY weakening | Interpretation |
| --- | ---: | ---: | --- |
| 2025-07-03 12:31 UTC | 8.85 hours | 0.7239% | Below the 30-hour gate. On-chain events do not show when the off-chain market moved, so the full 8.85 hours is not asserted as an executable window. |
| 2025-10-05 21:00 UTC | 30.76 hours | 0.6934% | A same-value heartbeat at 14:15 UTC refreshed `updatedAt`; round age immediately before the step was 6.75 hours, so the gate remained open. |
| 2025-10-05 21:01 UTC | 1 minute | 0.7056% | A second step; it is an attack candidate only if an external price was observable early enough to execute in the approximately one-minute interval. |

The two 2025-10-05 steps compound to 1.4038%. These are candidate lag events,
not proof that a profitable attack was executable. Independent off-chain quotes,
block ordering, gas, and available redemption liquidity would be needed to
establish exploitability.

### 2.4 Recent same-value heartbeat example

The last weekend in the sample provides a direct illustration of the clock
separation:

| Round | Answer (8 decimals) | `updatedAt` UTC | Block |
| ---: | ---: | --- | ---: |
| 7225 | `0.00624601` | 2026-08-29 16:20:11 | 25,862,063 |
| 7226 | `0.00624601` | 2026-08-30 16:20:35 | 25,869,244 |
| 7227 | `0.00625545` | 2026-08-31 01:23:11 | 25,871,948 |

Rounds 7225 and 7226 have identical answers, but the heartbeat advances
`updatedAt` by about 24 hours. The answer remains unchanged for about 33.05
hours through round 7227, while the age measured from round 7226 is only about
9.04 hours immediately before the change. The current 30-hour gate therefore
remains open. This proves the clock behavior, not that the later price move was
known or exploitable throughout the 33.05-hour interval.

## 3. Code path and loss bearer

The candidate processes normal redemption as follows:

1. `PriceFeedProxy.fetchRedemptionPrice()` reports failure for normal
   redemption when the source's JPY/USD round age is at least 108,000 seconds.
2. `CollateralRegistry.redeemCollateral()` calculates the transaction's
   redemption rate from the requested amount and total supply.
3. `TroveManager` calculates dToken collateral from
   `jpydfLot / redemptionPrice`, leaves the redemption fee in the Trove, and
   transfers the remainder to the redeemer.
4. `CollateralVault.redeem()` burns dToken and pays the same face amount of
   underlying from its buffer. Any shortfall enters a three-day withdrawal
   request under the intended initial configuration.

When the Vault is fully backed, burning a liability and transferring the same
face amount of assets does not itself create a Vault accounting loss. The
principal excess-value transfer caused by stale JPY/USD pricing is from the
redeemed Trove's borrower to the redeemer.

Exit timing affects realization but is not a hard loss cap:

- the intended initial wstETH Vault configuration has no Strategy allocation,
  so its assets normally remain in the Vault buffer;
- the intended initial USDC Vault buffer target is 333 basis points, so an exit
  above the available buffer may enter the three-day queue;
- normal redemption allocates across branches using unbacked debt; a redeemer
  cannot freely select the receiving branch; and
- a queue adds funding and hedge cost but does not remove price risk if the
  attacker can hedge the received asset or FX exposure.

These are intended initial handover inputs, not constructor-enforced constants.
Actual deployed values remain project-owned readback evidence.

## 4. Static exposure estimate

The dToken `mintCap` is converted from a JPY amount to token quantity when the
configuration is frozen. It does not subsequently track a JPY-denominated hard
ceiling. The following is therefore a static estimate using freeze-time prices,
100% backing, both intended initial branches active, and full cap utilization.

| Boundary | USDC branch | wstETH branch | Total |
| --- | ---: | ---: | ---: |
| New borrowing at MCR | JPY 100m / 111.58% = JPYdf 89.622m | JPY 35m / 123.18% = JPYdf 28.414m | JPYdf 118.035m |
| Normal redemption at TCR = SCR | JPY 100m / 105% = JPYdf 95.238m | JPY 35m / 110% = JPYdf 31.818m | **JPYdf 127.056m** |

The model below uses the second total as `S` because it is the more
conservative static normal-redemption envelope. It is not a hard ceiling. A
live assessment must read, at one pinned block, total supply, branch debt, TCR,
Stability Pool deposits, unbacked debt, dToken prices, backing, buffers, and
pending withdrawals.

## 5. Economic model

### 5.1 Definitions and assumptions

Let:

- `R = true collateral price in JPY / oracle collateral price in JPY`, so JPY
  weakening while the oracle lags gives `R > 1`;
- `p = market price of one JPYdf in JPY`;
- `b = 0.5% minimum redemption fee + decayed baseRate`;
- `S = 127.056m JPYdf`, the static estimate above; and
- `t` be cumulative redeemed volume divided by initial supply.

An attacker can split a large redemption into smaller transactions. Under a
continuous split-redemption approximation favorable to the attacker:

```text
r(t) = b - ln(1 - t)
h    = 1 - p / R - b
t*   = 1 - exp(-h)   if h > 0, otherwise 0

profit(t)       = S × integral[0,t] {R × (1 - r(u)) - p} du
lag transfer(t) = S × (R - 1) × integral[0,t] {1 - r(u)} du
```

This fee-growth term is tied to the candidate code. In
`Dependencies/Constants.sol`, `REDEMPTION_BETA = 1`; in
`CollateralRegistry._getUpdatedBaseRateFromRedemption`, each successful
redemption adds `redeemed fraction / REDEMPTION_BETA` to the decayed baseRate.
For arbitrarily small split redemptions against the shrinking supply, integrating
`du / (1 - u)` produces the `-ln(1 - t)` term above. A different beta or fee
update rule would invalidate this model and require recalculation.

The main table assumes:

- `p = JPY 1.00`;
- baseRate has decayed enough that `b = 0.5%`;
- the entire static exposure is redeemable;
- all relevant collateral and JPYdf liquidity is available; and
- gas, slippage, JPYdf funding, hedging, and underlying-asset exit costs are
  zero.

These are attacker-favorable simplifications, not a security bound. The intended
initial configuration sets baseRate to 100% and it decays with a six-hour
half-life, so the actual redemption fee shortly after launch is higher than this
table assumes.
At `p = 1` and `b = 0.5%`, the infinitesimal break-even weakening is about
0.5025%.

### 5.2 Modeled outputs

| JPY weakening | Optimal redemption | Attacker profit | Excess borrower transfer versus a fresh rate |
| ---: | ---: | ---: | ---: |
| 0.2168% historical Sunday-open maximum | 0 | 0 | 0 |
| 0.6934% candidate | JPYdf 0.239m | JPY 227 | JPY 1,650 |
| 0.7239% candidate | JPYdf 0.278m | JPY 306 | JPY 1,997 |
| 1% stress | JPYdf 0.621m | JPY 1,539 | JPY 6,166 |
| 2% stress | JPYdf 1.843m | JPY 13,760 | JPY 36,398 |
| 5% stress | JPYdf 5.301m | JPY 119,458 | JPY 258,129 |
| 10% stress | JPYdf 10.460m | JPY 501,290 | JPY 996,442 |

If the same gap persists and the attacker can optimize once initially and again
24 hours later after baseRate decay, the model gives:

| Persistent gap | Total attacker profit | Excess borrower transfer |
| ---: | ---: | ---: |
| 5% | approximately JPY 220,000 | approximately JPY 490,000 |
| 10% | approximately JPY 906,000 | approximately JPY 1,853,000 |

The candidate historical events yield only hundreds of JPY before costs under
these assumptions. Tail gaps grow nonlinearly and must not be dismissed using
the historical sample alone.

### 5.3 JPYdf depeg sensitivity

If JPYdf trades below JPY 1, ordinary peg-redemption profit and the incremental
oracle-lag effect overlap. At a 0.7239% lag:

| JPYdf market price `p` | Optimal redemption | Total profit | Incremental profit from lag versus a fresh oracle |
| ---: | ---: | ---: | ---: |
| JPY 1.00 | JPYdf 0.278m | JPY 306 | JPY 306 |
| JPY 0.99 | JPYdf 1.530m | JPY 9,354 | JPY 7,768 |
| JPY 0.98 | JPYdf 2.770m | JPY 30,865 | JPY 16,642 |
| JPY 0.95 | JPYdf 6.417m | JPY 168,947 | JPY 42,211 |

A fixed percentage-divergence alert is therefore insufficient. Live monitoring
must combine the independent FX rate, JPYdf market price, redemption rate,
baseRate, supply, redeemable exposure, actual redemptions, and exit conditions.

## 6. Current project position — not approved

Engineering proposes retaining the 30-hour gate as a partial feed-silence
control without adding a weekly calendar gate for the initial launch. A weekly
gate would disable normal redemption for about 49 hours, or 29.2% of each
ordinary week, and weaken a JPYdf peg-restoration path. Correct holiday and
daylight-saving handling would also add implementation and operational risk.

The project also considered clocks that advance only when the answer changes,
with either exact equality or a small cumulative basis-point threshold. No such
gate is selected for the initial launch: it would regularly close normal
redemption, the limited history does not establish a security threshold, and a
small threshold chosen from one recent weekend would be overfit. This is a
liveness trade-off, not evidence that the existing age gate is sufficient.

Adding a second freshness clock later is not treated as a parameter-only or
ordinary source-replacement change. The current normal-redemption age behavior
lives in the non-upgradeable Proxy, while a generic source `failure=true` also
triggers the broader oracle pause. A safe alternative therefore requires a new
design, tests, and security review unless it can preserve those semantics.

Monitoring is detection rather than atomic prevention. The proposed treatment
therefore also depends on approved exposure and loss limits; an alert by itself
does not bound a transfer that executes before intervention.

This is a proposed, time-limited treatment, not acceptance. It is ineffective
until all of the following are completed:

1. the Product owner, Protocol Risk owner, and Protocol Governance approve a
   per-incident borrower transfer budget, a cumulative budget, and a maximum
   live supply or redeemable exposure;
2. external monitoring creates a labeled test incident and proves delivery to
   the intended human escalation recipient and subsequent resolution;
3. monitoring correlates an independent USD/JPY price, Chainlink round and age,
   JPYdf price, baseRate, live supply, branch unbacked debt, actual redemptions,
   Vault buffers, and pending withdrawals; and
4. a user-path synthetic checks the executable normal-redemption path,
   independent-FX divergence, and redeemable amount, not only feed age.

## 7. Automatic expiry and reassessment

Any future project approval of this treatment must expire at the earliest of:

- 90 days after mainnet launch;
- an increase to a dToken cap, activation of a new branch, or a change to MCR,
  SCR, the redemption fee, or baseRate decay;
- live supply or redeemable exposure exceeding the approved limit;
- the independently priced condition
  `R × (1 - redemptionRate) > p` producing expected positive profit above the
  approved alert threshold after costs;
- an actual redemption caused by sub-30-hour lag or borrower transfer above the
  approved amount;
- a change to the Chainlink feed address, category, market hours, heartbeat, or
  deviation behavior; or
- disabling or failed delivery of the external monitor, escalation target,
  human recipient, or user-path synthetic.

At expiry, the project must reassess a market-hours gate, a 24/7 reference,
dynamic fees, a smaller exposure cap, or another control. Until the required
approvals and evidence are recorded against a specific source identity, this
appendix is not proof of risk acceptance or launch approval.
