# Scope Delta — audited identity `0c7766e0` → pre-audit freeze `0a85b374`

This is the source delta for the follow-up review. It covers everything that
changed in the audited surface after the August 2026 engagement closed at
identity `0c7766e0` (handoff tag `audit-handoff-2026-08-05`).

Every figure below was measured directly on the two commits, not carried over
from the previous edition.

The reviewable source is in this repository under
[`source-snapshot/contracts/`](../../../source-snapshot/contracts), refreshed to the
follow-up freeze. Its `src/` tree is byte-identical to the freeze commit: 109
files, verified by SHA-256 with no additions, omissions, or content differences.
Measure it directly with:

```sh
cloc --by-file --csv --quiet --include-lang=Solidity source-snapshot/contracts/src
```

`./scripts/checkout-source.sh` clones the source repository and is for our own
use; it requires access you have not been granted. Tell us if you would like a
full checkout with submodules for build / Slither reproduction and we will
provide it.

| Item | Value |
| --- | --- |
| Audited identity (previous engagement) | `0c7766e0a935b3dd99111349ef84e69c1a07da38` |
| Follow-up freeze | `0a85b374015e2553d2985b4a3f454b6aee4514a5` |
| Source repository | `https://github.com/deltaforesight/jpydf-v2` |
| `contracts/src` files changed | 23 |
| Full `contracts/src` population | 12,758 → 13,266 nSLOC |
| Active review body (A) | 5,836 → 5,219 nSLOC |
| Fast Foundry gate at the freeze | 1,536 passed / 0 failed / 0 skipped (81 suites) |
| Full local Foundry gate at the freeze | 1,589 passed / 0 failed / 0 skipped (89 suites) |

## 1. Why the branch changed collateral

The protocol is still pre-mainnet and branch parameters are immutable after
deployment, so this was the last point at which the ETH-exposure branch could be
restructured. Branch 0's Underlying moved WETH → wstETH.

The dToken indirection means Liquity core contracts are untouched: only the
branch's Underlying, its dToken identity (`dETH` → `dwstETH`) and its price feed
change. WETH remains protocol-wide as gas compensation.

## 2. Per-file nSLOC delta (measured)

| File | `0c7766e0` | `0a85b374` | Δ |
| --- | ---: | ---: | ---: |
| `Zappers/CollateralYieldZapper.sol` | 468 | 575 | **+107** |
| `PriceFeeds/DFWstETHPriceFeed.sol` | — | 89 | **+89** |
| `PriceFeeds/JpyFreezeLib.sol` | — | 55 | **+55** |
| `Strategies/MorphoV2Strategy.sol` | — | 158 | **+158** |
| `PriceFeeds/DFPriceFeedBase.sol` | 83 | 70 | **−13** |
| `PriceFeeds/sUSDSPriceFeed.sol` | 107 | 95, then archived | **−12** |
| `PriceFeeds/DFWETHPriceFeed.sol` | 19 | deleted | **−19** |
| `CollateralVault.sol` | 818 | 782 | **−36** |
| `CollateralVaultLens.sol` | — | 159 | **+159** |
| `PriceFeeds/JpyUsdRateProvider.sol` | 93 | 101 | **+8** |
| `Interfaces/ICollateralVault.sol` | 156 | 167 | **+11** |
| `Strategies/SkyUsdcSUsdsConverter.sol` | 156 | 157 | **+1** |
| **Subtotal, new or changed** | | | **+508** |
| `Strategies/LidoStrategy.sol` | 327 | moved to `archive/` | −327 |
| `Strategies/EtherfiWeETHStrategy.sol` | 261 | moved to `archive/` | −261 |
| `Strategies/AsyncRequestStrategy.sol` | 114 | moved to `archive/` | −114 |
| `Strategies/WeETHWithdrawAdapter.sol` | 108 | moved to `archive/` | −108 |
| **Subtotal, archived out of the Strategy body** | | | **−810** |
| `PriceFeeds/sUSDSPriceFeed.sol` | 95 | moved to `archive/` | −95 |
| `Zappers/SkyUsdcSUsdsYieldZapper.sol` | 187 | moved to `archive/` | −187 |
| `PriceFeeds/DFWBTCPriceFeed.sol` | 82 | moved to `archive/` | −82 |
| `PriceFeeds/DFUSDTPriceFeed.sol` | 19 | moved to `archive/` | −19 |
| `PriceFeeds/DFXAUTPriceFeed.sol` | 19 | moved to `archive/` | −19 |
| **Subtotal, archived by the branch convergence** | | | **−402** |

`Dependencies/Constants.sol` changed twice without moving nSLOC out of the
active body: first swapping the branch-0 constants (`*_DETH` → `*_DWSTETH`) and
their values, then converging the whole branch map onto the Day-1 topology
described in §2.1.

The active review body additionally carries two corrections to our own previous
scope accounting, found while regenerating it: rows already stale at
`0c7766e0` (+5) and `JpyUsdRateProvider`, which existed but was never listed
(+93). Grouped for the implementation review body: **−1,212 archived / +497
new-or-changed implementation / +98 correction**. The `+11` interface delta is
population reconciliation, not implementation pricing.

The `+508` reconciles to the population figure exactly, and it is worth stating
how, because the arithmetic has one non-obvious term. `12,758 + 508 = 13,266`,
the full population at the freeze. The archive rows do not enter it: those files
move within `contracts/src` rather than leaving it, so they change which body a
file belongs to and not how many lines exist. `JpyUsdRateProvider` appears in
both the table above (`+8`, the real change during this cycle) and the
correction bucket (`+93`, the accounting fix for a file that was always there);
those are two different things about one file and neither absorbs the other.

`Interfaces/ICollateralVault.sol` is listed above because this table measures
the population, but its `+11` does **not** reach the active review body: the
scope guide excludes interfaces from implementation nSLOC. It is the one row
here that moves the two totals differently, which is why it is called out
rather than left for you to reconcile.

### 2.1 Day-1 branch convergence

Branch parameters are immutable after deployment, so the eight-branch map had to
be settled before mainnet rather than after. Two branches are active on Day 1 —
0 (wstETH) and 1 (USDC). Branches 2–7 deploy inert: no Underlying bound, a
placeholder price feed, a mint cap of 0, and no Strategy or Zapper.

The candidate assets that had been wired in earlier — USDT, sUSDS, XAUT, WBTC —
are not adopted for Day 1. Their price feeds and the dUSDS ingress Zapper had no
remaining deploy path, so they were archived. That is the **−402 nSLOC** row
above.

Three of the five — `DFUSDTPriceFeed`, `DFWBTCPriceFeed`, `DFXAUTPriceFeed` —
meet the same standard as the Strategy archive in §4: against `0c7766e0` they
diff by the ARCHIVED banner and relocated imports only, with zero logic,
constant, modifier or storage changes.

Two do not, and were modified during the cycle before being archived. Both
changes are already itemised above, so neither is new scope, but the archive
claim does not cover them:

- `sUSDSPriceFeed` carries the `JpyFreezeLib` extraction of §3.2 — 32 changed
  lines, and the 107 → 95 nSLOC row in §2.
- `SkyUsdcSUsdsYieldZapper` carries the fourth constructor argument of §3.4 —
  one changed line, passing `address(0)`.

Branch 0 and branch 1 risk parameters are byte-identical across this change.
Inert branches carry conservative immutable values chosen for the slot rather
than for a confirmed asset; branch 2 (`dETH`) takes the same envelope as branch
0, including its stETH depeg leg, which bounds what that slot can later host.

### 2.2 What actually needs reviewing

The active review body is the whole in-scope surface, not the work. Most of the
5,219 nSLOC is the current active body; most of it was audited at `0c7766e0`
and has not changed since.

| | nSLOC |
| --- | ---: |
| New contracts, not present at `0c7766e0` | **302** |
| — `PriceFeeds/DFWstETHPriceFeed.sol` | 89 |
| — `PriceFeeds/JpyFreezeLib.sol` | 55 |
| — `Strategies/MorphoV2Strategy.sol` | 158 |
| Relocated out of a file you audited | **159** |
| — `CollateralVaultLens.sol` | 159 |
| In `contracts/src` at `0c7766e0` but never listed in scope | **101** |
| — `PriceFeeds/JpyUsdRateProvider.sol` | 101 |
| **Previously unreviewed** | **562** |
| Audited and unchanged or relocated | ~4,657 |

`CollateralVaultLens` is separated from the new contracts above because calling
all 159 nSLOC new would overstate it. `CollateralVault` lost exactly 99 lines
and gained nothing (`+0 / −99`) at the intermediate extraction commit, so most
of the Lens is code you have already read, now reached through a different
contract. The later pricing, incident-rail, and receiver-delta fixes make the
final Vault diff `+104 / −127` against the audited identity. What is genuinely
new in the Lens is the reconstruction: it takes the Vault as a parameter and
rebuilds each answer from public getters. See §3.8.

Five implementation files you audited also changed, and the diffs rather than the files are the
review surface:

| File | File nSLOC | Diff `0c7766e0..0a85b374` |
| --- | ---: | --- |
| `Zappers/CollateralYieldZapper.sol` | 575 | +152 / −19 — the native-ETH route |
| `PriceFeeds/DFPriceFeedBase.sol` | 70 | +27 / −64 — extraction into `JpyFreezeLib` |
| `Dependencies/Constants.sol` | 74 | +46 / −48 — branch map and branch-0 values |
| `CollateralVault.sol` | 782 | +104 / −127 — Lens extraction, pricing / incident rails, and receiver-delta redemption |
| `Strategies/SkyUsdcSUsdsConverter.sol` | 157 | +2 / −1 — unavailable reverse quote now reverts instead of returning measured zero |

`BaseStrategy.sol` changes only comments (+5 / −4). The interface diffs
(`ICollateralVault` +36 / −9 and `ISkyUsdcSUsdsConverter` +3 / −0) align ABI
semantics and NatSpec; they are interface-review material rather than
implementation nSLOC.

`JpyUsdRateProvider` is the one to note. It existed at the audited identity and
was reachable, but our scope accounting never listed it, so it may not have been
in front of you. We are treating it as unreviewed.

## 3. What to review

### 3.1 `DFWstETHPriceFeed` (89 nSLOC, new)

`wstETH/USD = stETH/USD (Chainlink 0xCfE54B5cD566aB89272946F602D76Ea879CAb4a8,
1h heartbeat / 1% deviation) × wstETH.stEthPerToken()`, then JPY conversion and
`min(1, backingRatio)`.

Single-feed by design. The market stETH/USD leg prices a stETH discount
directly, so no ETH/USD deviation guard is carried, and redemption uses the same
composite with no special case. Requirement `ORCL-FR-015`.

### 3.2 `JpyFreezeLib` (55 nSLOC, new)

The JPY soft-freeze and backing-ratio layer, previously duplicated across
`DFPriceFeedBase` and `sUSDSPriceFeed`, is now one internal library shared by
two active feeds and one archived one (`sUSDSPriceFeed`, §2.1). This is why those two files lose 14 and 13 nSLOC.

Behaviour-exact: the six pre-existing oracle suites pass byte-unchanged (150
tests), and the error selectors and event topics are preserved. The freeze
events are `JpyRateFrozen` / `JpyRateUnfrozen` / `JpyFreezeExpired`, emitted by
`JpyUsdRateProvider` (`ORCL-EVT-007..009`).

### 3.3 `MorphoV2Strategy` (158 nSLOC, new)

Morpho Vaults V2 cannot be served by the existing `ERC4626Strategy`: V2's
`maxDeposit` / `maxMint` / `maxWithdraw` / `maxRedeem` return 0 unconditionally,
which zeroes that adapter's recovery ceilings.

The dedicated adapter clamps valuation and withdrawal to
`convertToAssets(min(ownShares, balanceOf))` and fail-softs both deposit and
withdraw through isolated self-call frames. Deposit rejections are re-raised
typed so the audited exact-receipt-recovery path still runs. Withdrawal tries
the requested amount and then halves it after each revert, with at most eight
total attempts; it returns the first successful partial amount and returns zero
only if every bounded attempt fails.

`forceDeallocate` is no longer owner-callable: it is `onlyVault`. The Vault's
`WRITEOFF_ROLE` entry atomically pauses allocation/deposit/redeem/claim, checks
the init-frozen penalty cap (≤2%), refreshes or conservatively reduces cached
valuation, and enforces a caller-supplied post-operation backing floor. A failed
floor check rolls the penalty and all pause changes back. Donated shares absorb
the penalty before tracked own shares, so fallback cache reduction reflects
only confirmed tracked valuation loss.

Day-1 deployment is branch 1 (USDC) only; no credible wstETH-denominated V2
vault exists today. Requirements `MV2-FR-001..005`, `MV2-SEC-001..007`,
`MV2-INV-001..003`.

### 3.4 `CollateralYieldZapper` native-ETH route (+107 nSLOC)

With branch 0 holding wstETH, native-ETH users enter via
ETH → `stETH.submit` → `wstETH.wrap` → deposit.

Route enablement is an explicit constructor parameter (`_expectedStEth`), not an
interface probe: `address(0)` means the route does not exist, and a non-zero
value is checked against the Underlying's `stETH()` getter at construction so a
mismatch reverts at deployment. Lido staking being paused degrades to a typed
revert while the direct wstETH path is unaffected. Exits inherit the parent
paths, so withdrawals return wstETH. Requirement `ZAP-FR-015`.

`SkyUsdcSUsdsYieldZapper` passes `address(0)` for this parameter, which is the
whole of its 2-line change.

### 3.5 Branch-0 risk parameters (`Constants.sol`)

| Param | Previous (WETH-derived interim) | Now |
| --- | ---: | ---: |
| LLTV | 83.91% | **81.18%** |
| MCR | 119.18% | **123.18%** |
| CCR | 132.61% | **141.67%** |
| SCR / BCR / SP penalty / redistribution penalty | 110% / 10% / 5% / 10% | unchanged |

The previous values were WETH-derived and explicitly marked as interim. They now
carry a measured stETH/ETH depeg leg of 3.25% (2h max drawdown, hourly series
2022-01→2026-08, 27,694 joint points). Every other input is shared with the WETH
derivation, so `MCR_wstETH = MCR_WETH / (1 − depeg)`.

The derivation, the three judgment calls behind it, and the measurement scripts
are included in this repository:
[`evidence/wsteth-cycle/dwsteth-risk-parameter-derivation.md`](../../../evidence/wsteth-cycle/dwsteth-risk-parameter-derivation.md)
and [`evidence/wsteth-cycle/depeg-measurement/`](../../../evidence/wsteth-cycle/depeg-measurement).

### 3.6 Bug fix (issue #1371)

The one item here we would rate as launch-blocking. It is no longer the only
defect found in-house during this cycle: four more surfaced later, in a review
pass run after this section was first written, and they are in §3.7.

On any branch whose Underlying has fewer decimals than the dToken — branch 1
(USDC) on Day 1 — a Trove whose collateral had acquired dust could not be closed.
`CollateralVault.redeem` requires the dToken amount to correspond exactly to a
whole number of Underlying base units, and `closeTroveToUnderlying` passed Core's
18-decimal collateral figure through unchanged, so the round trip
`convertToDToken(convertToUnderlying(x))` did not reproduce `x` and the call
reverted with `InvalidDTokenAmount()`. `closeTroveToUnderlying` takes only a
`troveId`, so there was no amount a caller could adjust — the position could not
be closed from any front end, and the collateral could not be fully withdrawn.

This is a liveness and asset-access defect, not a path to taking funds: nothing
was mis-accounted and no third party could exploit it. Branch 0 was unaffected
because its Underlying is 18 decimals.

The fix truncates to the redeemable amount and returns the remainder to the
receiver as dToken rather than reverting. Two things are worth your attention:

- `collateralVault.redeem` has exactly one caller in `contracts/src` —
  `CollateralYieldZapper._redeemDTokenToUnderlying`, reached from all three
  redeem paths (redeem, close, adjust). That is the basis for calling the fix
  complete, and it is a claim you can check directly.
- The residual is returned as dToken, so a closing user ends with a dust dToken
  balance rather than Underlying. That is deliberate; whether it is the right
  trade-off is a fair question to raise.

### 3.7 Defects we found after freezing, and fixed

Before sending you this delta we ran an adversarial review over the new and
changed contracts. It found four defects that were live in the code you would
otherwise have received. **All four are fixed** at `0a85b374`, with focused
regression coverage. The fourth was initially recorded as open at the prior
freeze; direct comparison with the source, rather than the prior PR prose,
showed that its claimed fix had never landed. It was therefore treated as the
highest-priority pre-audit correction.

We are listing them rather than quietly shipping the fixes, for two reasons.
They tell you where our own review was weakest, which is useful for aiming
yours. And three of the four are in the shared JPY / backing-ratio path, which
is the part of this delta we would most like a second opinion on.

**(1) A direct caller could consume the shared-JPY shutdown signal.**
`fetchPrice()` is public and the shared-JPY exit latched
`priceSource = lastGoodPrice` whether or not `BorrowerOperations` accepted the
shutdown. Under the `PriceFeedProxy` topology the proxy is the registered price
feed, so the source's own call *always* reverts on the caller check. Anyone
could call the source directly, take the one-shot `failure=true`, and leave the
feed latched; every later proxy fetch then took `_fetchPriceDuringShutdown`,
which reports `(lastGoodPrice, false)` — a frozen price served as healthy with
the branch still live. The helper now reports whether the branch was actually
shut down and the feeds latch only when it was. A third copy of the helper in
the archived `sUSDSPriceFeed` had the same defect and was fixed too.

**(2) The provider discarded a newer readable round.** `lastGoodJpyRate` only
advanced on a *fresh* read and nothing polls `JpyUsdRateProvider`, so after a
quiet period the cache could lag the newest published round without bound. Two
consequences from one cause: an unnecessarily old rate was served, and the
freeze onset — derived from the same timestamp — charged the grace window for
time the feed was never stale, so a single not-fresh read could latch the
irreversible 24h expiry with no grace at all. The not-fresh branch now adopts a
decodable newer round, applying the same validity checks as `_isFresh` minus the
staleness clause. The freeze arithmetic is unchanged; it just gets an accurate
anchor.

This one is worth a note on how it was found. Most of the review agents
attributed it to the freeze arithmetic. The arithmetic is self-consistent with
the rate actually served, and their fix would have left the stale-rate half of
the defect in place. The real cause is upstream of it.

**(3) Recovering a donation consumed own-share accounting.**
`emergencyWithdrawFromMorphoV2` is the only function that sizes against the raw
share balance — deliberately, since that is the sole recovery path for donated
shares — but it then charged the full redeemed count against `_ownShares`, which
every other path defines as own-deposit shares only. The shares stayed in the
vault and stopped being counted, and because `_estimatedTotalUnderlying` and
`_doWithdraw` both clamp to `min(_ownShares, balance)` the difference was
invisible to `backingRatio()` and repriced every Trove on the branch. Reproduced
before fixing: a 100e18 position plus a 10e18 donation, recovered with the
documented partial call, left `_ownShares` at 90e18 against 100e18 of shares
actually held. Donated shares are now burned first.

#### (4) Unavailable valuation was priced as total loss — fixed before audit

A Strategy that could be valued neither live nor from a fresh cache contributed
zero to the Vault total. Because `JpyFreezeLib` multiplied that operational
ratio directly into collateral price, a view outage could make every Trove on
the branch liquidatable while the feed reported `oracleFailure = false`.

The final design separates two contracts that had been overloaded into one
number:

- `backingRatio()` remains an always-numeric operational/incident view. It may
  conservatively count an unavailable Strategy as zero; invalidate-cache and
  writeoff tooling can continue to use it.
- `backingRatioForPricing() -> (ratio, available)` is the pricing boundary. It
  returns `available=false` if any registered Strategy lacks both a live value
  and a fresh cache.
- `JpyFreezeLib` sends `available=false` through the standard oracle-failure
  path, does not update `lastGoodBacking`, and uses the existing branch-shutdown
  plus `lastGoodPrice` behavior.
- A fully measured zero remains `(0, true)` and receives the existing 1-wei
  price floor. Real measured loss is therefore not converted into stale-price
  service.

This preserves the incident semantics that made a reverting operational view
unsafe while closing the liquidation-through-view-outage path. The Lens
extraction made the code-size correction possible; after this fix the production
Vault is 23,047 / 24,576 bytes, leaving 1,529 bytes.

### 3.8 `CollateralVaultLens` (159 nSLOC, new)

`CollateralVault` was within ~50 bytes of the EIP-170 runtime limit. Five
reporting views were moved to a new
stateless contract — `backingShortfall`, `backstopRequiredForRatio`,
`getStrategyAt`, `getAllStrategies`, `getStrategyStatuses` — along with the
internal `_buildStrategyStatus` they share. At the intermediate extraction
commit the Vault diff was `+0 / −99`; against the final freeze it is
`+104 / −127` because the pricing, Morpho incident, and receiver-delta corrections then used the
released space. The Vault is now **23,047 bytes with 1,529 free**; the Lens is
5,000 bytes.

`getStrategiesCount` is the exception: it stays on the Vault and the Lens
re-exposes it by delegation, so a consumer holding only the Lens address does
not need both.

The Lens holds no funds, no roles and no storage. The Vault is a parameter on
every entry point, so one deployment serves all eight branches, and the Vault
never calls it.

Two things in it are worth your attention:

- It **mirrors** `_liveStrategyValuation` and `_cachedStrategyConservativeValue`,
  which still exist in the Vault because the Vault uses them internally. That is
  duplicated logic, not moved logic, and nothing enforces that the two copies
  stay in step. If the Vault's valuation rule changes and the mirror does not,
  the Lens keeps answering — with stale semantics — instead of failing. We think
  this is the weakest point of the extraction.
- `getStrategyAt` bounds-checks explicitly and reverts `StrategyNotFound`, to
  preserve the Vault's original error. Reading `strategies(index)` through the
  public getter would panic on the array access instead, which is a different
  error for the same condition.

### 3.9 `_minUnderlyingReceived` semantics — decided and receiver-delta hardened

The `WithMin` Zapper parameter is the minimum Underlying delivered to the
receiver immediately in that transaction. It excludes both a queued withdrawal
remainder and dToken dust returned because it cannot be converted into an
Underlying base unit. Therefore a queued claim can preserve total economic
entitlement while the `WithMin` call still reverts for insufficient immediate
liquidity. Non-`WithMin` entries use a zero floor and may return queue/dust.

This matches `ZAP-FR-006`, `ZAP-SEC-005`, the implementation, and the existing
queue/dust tests. Combining immediate Underlying, a future queued claim, and
dToken dust into one slippage number would erase the caller's ability to demand
immediate liquidity, so the public ABI and Zapper comparison target remain
unchanged. The Vault return is hardened to the receiver's actual `balanceOf`
delta, so fee-on-transfer Underlying cannot satisfy the floor with a nominal
amount the receiver did not obtain.

### 3.10 Final multi-skill variants

Trail of Bits confirmed the original four requirements and found one Low stale
recovery-map comment. QuillShield independently found two Medium conditional
fee-on-transfer variants plus the same Low. The final freeze resolves all three:

- a Strategy `declared/received` mismatch invalidates the fallback valuation
  cache instead of guessing the upstream position decrease;
- Vault redemption returns receiver delta, which the existing Zapper minimum
  compares atomically; and
- Sky halt or invalid reverse fee makes preview revert. A nonzero position uses
  only a fresh cache, becomes pricing-unavailable when stale, and restores live
  valuation automatically when the route recovers.

The Nemesis child path was blocked twice by the platform safety filter, so it is
not represented as an independent result; the parent applied its attacker-recon
and state-coupling procedure. Exact skill revisions, tests, limitations, and the
Chain Defenders PDF reconciliation are recorded in
[`evidence/wsteth-cycle/pre-audit-multi-skill-review-2026-08-08.md`](../../../evidence/wsteth-cycle/pre-audit-multi-skill-review-2026-08-08.md).

## 4. Archived, not deleted

`LidoStrategy` (327), `EtherfiWeETHStrategy` (261), `AsyncRequestStrategy` (114)
and `WeETHWithdrawAdapter` (108) — **810 nSLOC** — are unreachable after the
swap. They hard-require a WETH underlying, and the deploy surface for them was
removed, so no branch can supply one.

Because they carry your audit result, they moved to
`contracts/src/Strategies/archive/` rather than being deleted. We verified at
the freeze commit that each file diffs against `0c7766e0` with **only** the
ARCHIVED banner and relocated import paths — zero logic, constant, modifier or
storage changes. Their 84 tests moved to `contracts/test/archive/` and still run
in the default suite.

**They are out of active scope for this engagement.** Reactivation would require
re-entry into the deploy selector and a fresh activation package.

## 5. Verification carried out in-house

- Fast PR gate: **1,536 passing / 0 failed / 0 skipped** across 81 suites.
- Full local gate excluding mainnet fork and `LocalParityDrill`: **1,589
  passing / 0 failed / 0 skipped** across 89 suites, including the archived
  tests that remain in the default run.
- Focused pricing / Morpho regressions: 73 passing, plus one isolated
  force-deallocation cache-fallback regression. The five affected follow-up
  suites add a 253-test pass over Vault, Strategy, Zapper, and Sky paths.
- Production `CollateralVault` runtime: **23,047 / 24,576 bytes** (1,529 free).
  `forge build --sizes` reports existing test-only tester contracts over the
  limit; that command-level non-zero is not a production Vault size failure.
- Every change was adversarially reviewed before external audit start; the
  exact freeze was merged into `develop` by jpydf-v2 PR #1491 as merge commit
  `469b1265`.
- Frozen mainnet addresses verified against live chain state by reading
  `UNDERLYING_ASSET_ADDRESS()`, `POOL()`, `stEthPerToken()` and `description()`
  directly.
- The MorphoV2 adapter carries a 32-instance valuation-gas replay against the
  regression ceilings your Gas 01 finding established.
- Requirement coverage is tracked per ID in the verification ledger, which is in
  this repository and in English:
  [`docs/en/engineering/verification-ledgers/Requirements-Verification-Ledger.md`](../../en/engineering/verification-ledgers/Requirements-Verification-Ledger.md)
  (Core requirements are in the sibling
  [`Core-Requirements-Verification-Ledger.md`](../../en/engineering/verification-ledgers/Core-Requirements-Verification-Ledger.md)).
  Every requirement ID cited above resolves there. Two gaps found while preparing
  this delta were closed rather than carried: `ORCL-FR-015` and the JPY freeze
  events had no ledger rows, and the Zapper's native-ETH route had no requirement
  ID at all while the spec still asserted no native-ETH flow existed.

## 6. Known open items on our side

- `PILAllocator` / `UniV4MerklInitiative` (409 nSLOC, inside the A body as gated
  production code) carry 51 requirement IDs of which 5 remain unverified — the
  rows marked `Not run` in the ledger: `PILA-SEC-001` and `PILA-GOV-002..005`. All
  five are activation-package work — end-to-end forwarder → allocator → Merkl
  integration, Phase-A activation, Phase-B migration, the extension boundary, and
  the mainnet Merkl address and fee. Day-1 runs the allocator inert with a total
  weight of 0.
- `DF_COLL_USD_STALENESS_0`: we propose 86400s, matching upstream's treatment of
  the same 1h-heartbeat / 1%-deviation feed.
