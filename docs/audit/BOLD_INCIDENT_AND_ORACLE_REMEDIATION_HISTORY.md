# BOLD incident and JPYdf oracle remediation history

This audit-package record reproduces the project-supplied BOLD incident
observations and the decisions that led to the current oracle behavior.
It requires no access to the implementation repository or its PR discussions.
Current review scope remains [SCOPE.md](../../SCOPE.md).

## Observed BOLD transaction

The project reconstructed Ethereum block `24719820` (2026-03-23 11:07:47 UTC)
from receipts, events, and traces, and recorded a recheck on 2026-08-31.
This document reuses that historical reconstruction; it does not claim a new
independent on-chain reconstruction. The block hash is
`0x047b822726ab470b472a7278aaa55671ce14fff03f46f3541d3209a07a98c81e`.

The [example transaction](https://etherscan.io/tx/0xf4141b8c71d286fd593af774e7517a15889cd9d9849db9133b02c70060b7755e)
at transaction index 0 bought 106,117.60 BOLD at about 1.00492 USDC per BOLD,
then redeemed it. Paying above one dollar still allowed profitable execution
because collateral was redeemed at an outdated price and sold at the market
price. The first five redemptions preceded the ETH/USD update at index 122
(from USD 2,046.76 to 2,080.78); index 172 updated it again to USD 2,132.24.
This establishes ordering, not the actor's subjective intent.

On a one-dollar debt valuation, the example's borrower loss was approximately
USD 3,073. About USD 2,551 was gross arbitrage value before the fee-recipient
payment and gas; the searcher's final retained profit was about USD 2.40.
The distinction matters: a solvent borrower can lose value through redemption
without the protocol first becoming undercollateralized.
[Liquity's own documentation](https://github.com/liquity/bold/blob/main/README.md#mitigating-redemption-arbitrages--oracle-frontrunning)
also explains that oracle-update frontrunning can occur with BOLD at or above
one dollar.

## Decision sequence and retained risks

| Stage | Change or decision | Reason and limit |
| --- | --- | --- |
| Incident research | Preserve the transaction ordering and borrower-value transfer as design input. This stage changed no runtime code. | The observed transfer happened even with BOLD bought above par; redemption can impose losses before a borrower becomes insolvent. |
| Normal-redemption pricing | Separate the redemption quote from normal collateral valuation; use a higher protective collateral reference and fail closed when the required auxiliary feed is unavailable. Introduce a recoverable oracle-failure pause and validated Owner resume. | Prevent the demonstrated low collateral-price redemption path without applying a potentially higher redemption valuation to borrowing or solvency checks. The shared JPY denominator remained a separate risk. |
| Urgent-redemption pricing | Extend protective collateral pricing to urgent redemption after irreversible shutdown; require source-policy-valid inputs and reject failed prices instead of settling from a cached normal or redemption quote. | Shutdown must not silently reopen the collateral-price lag path. Required-feed failures can stop urgent redemption, so source/Owner recovery remains relevant. |
| JPY denominator decision | The project chose an additional normal-redemption stop while retaining borrowing and liquidation, following the 2026-08-30 request for inclusion in the additional audit. The implemented policy also retained TCR/SCR checks and urgent redemption. | Prioritize protection of existing borrowers while respecting the earlier decision to avoid false stops of the shared JPY dependency across branches. The project retained the 72-hour provider policy for borrowing and liquidation; this was not a new quantitative borrowing-risk approval. This is a historical design choice, not proof that the remaining exposure is acceptable. |
| 30-hour implementation | After a successful source read, reject normal redemption when the source-bound saved JPY round is at least 108,000 seconds old or provenance is invalid. Keep this check separate from the recoverable oracle-failure latch and cached redemption price. | A fresh accepted round reopens the gate automatically. Real source failures retain their prior pause handling. Same-value heartbeats, sub-30-hour lag, and other consumers' stale-FX exposure remain. The original proposal specified 26–30 hours as a 24-hour heartbeat plus grace. A quantitative comparison selecting 30 rather than 26 hours was not supplied in the reviewed record. |

The early normal-only implementation was subsequently extended for urgent
pricing; its historical description is not the current urgent behavior.
The current frozen dwstETH formula and consumer boundaries below control.

The BOLD observation concerns lag in collateral/USD, not a quantitative
justification for a 30-hour JPY/USD threshold. Current dwstETH redemptions use
`max(direct stETH/USD, ETH/USD * stETH/ETH)`; that collateral-price protection
and the JPY age gate are distinct mitigations. The [borrowing assessment](./NORMAL_REDEMPTION_30H_GATE_RATIONALE.md) is additional
analysis and does not overwrite the historical decision.

## Historical position and basis

The pre-remediation position was to stop normal redemption earlier while retaining the
72-hour shared-provider policy for borrowing and liquidation. The original
proposal prioritized user-asset protection and accepted more interruptions to
normal redemption, while respecting the existing decision to avoid false stops
of the shared JPY dependency across branches. The chosen 30-hour gate follows
the proposal for a 24-hour heartbeat plus grace (26–30 hours).

The [current design rationale and borrowing assessment](./NORMAL_REDEMPTION_30H_GATE_RATIONALE.md)
sets out this project position, the FX-inclusive collateral checks supporting
it, and the residual exposure from prolonged outages. Guardian is asked to
assess that design and its assumptions. The documented availability rationale
does not supply a quantitative comparison of 26 versus 30 hours or a safety
proof for all borrowing admitted during an outage.

The September 10 client/Guardian exchange proposes selective 30-hour restrictions and tests of a shorter liquidation window. See [Guardian remediation tracking](./GUARDIAN_REMEDIATION.md#oracle-correspondence-implemented-candidate-policy) for the implemented/tested candidate and the remaining economic grace-period trade-off.

## Evidence available within this package

- [DFWstETHPriceFeed](../../source-snapshot/contracts/src/PriceFeeds/DFWstETHPriceFeed.sol): current direct/derived collateral references for normal and urgent redemption.
- [PriceFeedProxy](../../source-snapshot/contracts/src/PriceFeeds/PriceFeedProxy.sol): `fetchPrice`, `fetchRedemptionPrice`, `fetchUrgentRedemptionPrice`, `resumeFromOracleFailure`, and source replacement.
- [JpyUsdRateProvider](../../source-snapshot/contracts/src/PriceFeeds/JpyUsdRateProvider.sol): shared round state, configured staleness, soft-freeze, and expiry.
- [Age-gate tests](../../source-snapshot/contracts/test/PriceFeedProxyJpyRedemptionAge.t.sol): the 30-hour boundary, unchanged normal/urgent paths, cache isolation, and automatic recovery.
- [Known risks](./KNOWN_RISKS_AND_CURRENT_POSITION.md): current project positions; the historical decision above does not replace Guardian's independent assessment.

For incident readback, the public transaction link above identifies the receipt,
logs, and internal transfers. An Ethereum execution RPC can retrieve the block
with `eth_getBlockByNumber("0x17931cc", true)` and the receipt with
`eth_getTransactionReceipt` using the full transaction hash in the link.
The ETH/USD aggregator observed in the block is
`0x7d4e742018fb52e48b08be73d041c18b21de6fb5`; its `AnswerUpdated` rounds were
27295 (saved price), 27296 (index 122), and 27297 (index 172).
Full profit attribution also requires execution traces for the fee-recipient
payment; receipt-only inspection does not establish the searcher's final profit.
