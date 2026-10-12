# SkyUsdcSUsdsStrategy Requirements

## 0. Metadata

| Item | Value |
| --- | --- |
| Status | Active |
| Implementation status | Implemented optional Strategy. A separate activation gate is required before including it in an expected launch manifest. |
| Owner | DeltaForesight |
| Target contracts | `contracts/src/Strategies/SkyUsdcSUsdsStrategy.sol` / `contracts/src/Strategies/SkyUsdcSUsdsConverter.sol` |
| Related documents | [Strategy](Strategy.md) / [CollateralVault](../CollateralVault.md) / [Zapper](../Zapper.md) / [Deployment-Configuration](../../../../engineering/guides/Deployment-Configuration-Spec.md) |

This English page is a support translation. The Japanese
[SkySUsdsStrategy.md](../../../../../jp/protocol/product/spec/strategies/SkySUsdsStrategy.md) remains
the normative source of truth.

`SkyUsdcSUsdsStrategy` keeps the dUSDC branch Vault underlying as **USDC** while
deploying allocated USDC through `USDC -> USDS -> sUSDS`. It values and recovers
the position in USDC terms.

## 1. Scope

- `underlying()`: USDC, 6 decimals
- position token: sUSDS ERC-4626 share, `asset() == USDS`, 18 decimals
- intermediate token: USDS, 18 decimals
- converter boundary: `ISkyUsdcSUsdsConverter`
- recovery asset: USDC

This Strategy is for the dUSDC branch only. Self-appreciation of a future yield-bearing
Underlying belongs to borrower collateral value and is accounted separately from
Underlying-quantity growth produced by an external Strategy.

## 2. Deployment Configuration

| Item | Env key |
| --- | --- |
| Strategy kind | `DF_STRATEGY_KIND_i=sky-susds` |
| USDS token | `DF_STRATEGY_SKY_USDS_i` |
| sUSDS vault | `DF_STRATEGY_SKY_SUSDS_VAULT_i` |
| Sky LitePSMWrapper-USDS-USDC | `DF_STRATEGY_SKY_USDC_USDS_PSM_WRAPPER_i` |
| conversion-loss cap | `DF_STRATEGY_SKY_MAX_CONVERSION_LOSS_BPS_i` |

`DF_STRATEGY_SKY_MAX_CONVERSION_LOSS_BPS_i` cannot exceed the implementation
hard cap `MAX_CONVERSION_LOSS_BPS = 1000`.
The deployment script creates `SkyUsdcSUsdsConverter` from the configured
wrapper rather than accepting an arbitrary converter address. The activation
package must re-confirm the official Ethereum wrapper
`0xA188EEC8F81263234dA3622A406892F3D630f98c` and its token bindings on a fork.

## 3. Behavior

`initialize` validates USDC / USDS / sUSDS decimals, `susdsVault.asset()`, the
converter address, converter USDC/USDS token identity, and the max conversion loss. It leaves no permanent converter
or sUSDS-vault approval; each conversion uses per-call `forceApprove(amount)` and
then resets allowance to zero.
The reverse-route preview and execution use the same route-validity boundary:
Sky halt or `tout > 1e18` invalid fee reverts instead of being converted into a
numeric zero quote.

`_doDeposit(amount)` converts USDC to USDS through the converter, deposits USDS
into the sUSDS vault, checks return values against actual balance deltas, and
tracks only shares minted by this Strategy in `_ownSUsdsShares`.

`_doWithdraw(amount)` withdraws the required USDS from sUSDS and converts it back
to USDC. If a 1:1 USDS amount is enough according to converter preview, no extra
loss buffer is redeemed; otherwise the Strategy uses `maxConversionLossBps`.
If converting a nonzero USDS amount would return 0 USDC, the Strategy reverts
and preserves `_ownIdleUsds`.
The reverse route treats its USDS input as a maximum budget because Sky
`buyGem` is denominated in desired six-decimal USDC output. The converter
refunds unused USDS, and the Strategy decreases `_ownIdleUsds` only by the
actual USDS balance delta.

While the Sky USDS-to-USDC route is active, `estimatedTotalUnderlying()` returns
the smaller of the converter preview and the 1:1 USDC conversion for:

```text
sUSDS.convertToAssets(min(_ownSUsdsShares, sUSDS.balanceOf(this))) + ownIdleUsds
```

Direct donations of sUSDS / USDS / USDC are not counted as normal Strategy AUM.
USDS (18 decimals) is valued in USDC (6 decimals) with `usdsAmount / 1e12`
floor rounding. The sUSDS `convertToAssets` path can also round down
share-accounting dust, so USDS dust does not increase `estimatedTotalUnderlying()`
or `realizedYield()` until it clears both the ERC-4626 conversion floor and the
USDC scale floor. It becomes harvestable through `sendProfitToVault` only after
both floors are cleared.

When the converter explicitly reports `isUsdsToUsdcRouteHalted() == true`,
conversion and preview continue to revert, but valuation returns
`min(oneToOneUsdc(position), principal)`. Unrealized yield that cannot be exited
is not recognized. This conservative value remains a live measurement and may
refresh the Vault cache, so a halt lasting beyond `strategyValuationMaxAge`
does not become pricing unavailability or branch shutdown.

An invalid fee, route-status read failure, or any other preview failure must
not be inferred to be a halt. `estimatedTotalUnderlying()` reverts, the Vault
uses only a fresh measured cache, and pricing becomes unavailable once that
cache is stale. This preserves fail-closed behavior for unknown quote faults
instead of assuming a potentially overstated 1:1 value. Ordinary floor rounding
below one USDC base unit on an otherwise valid route remains a distinct numeric
zero case.

## 4. Emergency

Emergency recovery may be split:

| Function | Role |
| --- | --- |
| `emergencyRedeemSUsdsToUsds(usdsAmount)` | Redeem owned sUSDS into tracked idle USDS |
| `emergencyConvertIdleUsdsToVault(usdsAmount, minUsdcOut)` | Convert tracked idle USDS to USDC and push to Vault |
| `emergencyWithdrawFromSky(maxUsdsToRedeem, minUsdcOut)` | Redeem, convert, and push in one transaction |

Only USDC successfully pushed through `CollateralVault.receiveFromStrategy`
restores Vault backing.
If USDS dust would floor to 0 USDC, emergency conversion reverts and preserves
tracked idle USDS and `principal`. The dust remains tracked until additional
recovery or accumulation makes it convertible to at least 1 USDC base unit.

## 5. Security Requirements

| ID | Requirement |
| --- | --- |
| SKY-SEC-001 | Validate USDC / USDS / sUSDS decimals and `susdsVault.asset()` at initialization |
| SKY-SEC-002 | Use per-call approve/reset for converter and sUSDS vault approvals |
| SKY-SEC-003 | sUSDS share donations must not inflate valuation or realized yield |
| SKY-SEC-004 | USDS and sUSDS are protected tokens and cannot be swept as rewards |
| SKY-SEC-005 | Converter and sUSDS-vault return values must match actual balance deltas |
| SKY-SEC-006 | USDC recovery must revert below the `maxConversionLossBps` minimum receive |
| SKY-SEC-007 | Valuation must use the smaller of converter preview and 1:1 conversion |
| SKY-SEC-008 | Nonzero USDS conversion returning 0 USDC must revert and must not silently reduce tracked idle USDS |
| SKY-SEC-009 | Converter USDC/USDS identity must match route tokens, and deployment must create the audited concrete adapter rather than inject an arbitrary converter |
| SKY-SEC-010 | Reverse conversion must enforce the `tout`-inclusive USDS budget, refund unused USDS, and decrement idle accounting only by actual spend |
| SKY-SEC-011 | An explicit reverse-route halt keeps conversion / preview reverting but continues valuation at `min(1:1 position, principal)`; invalid fee, status-read failure, and other quote failures are not inferred as halts and transition from fresh cache to pricing unavailable |

## 6. Verification

`contracts/test/SkyUsdcSUsdsStrategy.t.sol` covers:

- USDC allocation into sUSDS and USDC-denominated valuation
- `sendToVault` recovery through `sUSDS -> USDS -> USDC`
- sUSDS yield harvest through `sendProfitToVault`
- USDS/sUSDS yield dust below the `convertToAssets` / USDC scale floors does not inflate valuation / realized yield, and becomes recoverable only after both floors are cleared
- donation-resistant valuation
- emergency redeem / convert / Vault push accounting
- emergency convert rejects USDS dust that floors to 0 USDC and preserves `_ownIdleUsds` and `principal`
- USDS / sUSDS sweep protection
- USDC decimal mismatch rejection
- partial USDS budget consumption leaves the unused amount tracked
- an explicit Sky reverse-route halt continues principal-capped valuation beyond cache expiry and does not shut down the price-feed branch
- unrealized sUSDS yield is not recognized while the reverse route is halted
- invalid-fee / generic quote failure is not misclassified as a halt, uses only a fresh cache, becomes pricing unavailable after staleness, and restores live valuation automatically after quote recovery

`contracts/test/SkyUsdcSUsdsConverter.t.sol` covers LitePSMWrapper-compatible
`tin/tout` fees, halt / invalid-fee preview reverts, fee-floor rounding, min-out checks, balance
deltas, reverse-route refunds, and zero residual allowance/token balances.
When `MAINNET_RPC_URL` is set, the fork tests in the same file check the official
wrapper's `gem()==USDC`, `dai()==USDS`, `tout`/preview behavior, and an actual
USDC -> USDS -> USDC round trip.

## 7. Primary Sources

- [Sky Protocol Docs: LitePSM](https://developers.skyeco.com/guides/psm/litepsm/) — wrapper address, `sellGem` / `buyGem`, fees, halt, and liquidity limits
- [Sky `usds-wrappers`](https://github.com/sky-ecosystem/usds-wrappers/blob/dev/src/UsdsPsmWrapper.sol) — deployed wrapper API and fee calculation
- [Sky `dss-lite-psm`](https://github.com/sky-ecosystem/dss-lite-psm) — underlying LitePSM design and known constraints
