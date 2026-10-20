# Guardian Scope Inventory — 2026-09-03

Status: captured scope interface for the additional production Solidity audit.
The authoritative SOW remains [`SCOPE.md`](../../SCOPE.md).

## Captured inventory

Guardian supplied the following table on 2026-09-03. Paths are relative to the
audit repository root.

| File | Lines | Normalized | Diff |
| --- | ---: | ---: | ---: |
| `source-snapshot/contracts/src/AddressesRegistry.sol` | 273 | 237 | 179 |
| `source-snapshot/contracts/src/BorrowerOperations.sol` | 1,474 | 1,063 | 50 |
| `source-snapshot/contracts/src/CollateralVault.sol` | 1,117 | 705 | 53 |
| `source-snapshot/contracts/src/Dependencies/Constants.sol` | 132 | 74 | 4 |
| `source-snapshot/contracts/src/DFStabilityPool.sol` | 622 | 311 | 3 |
| `source-snapshot/contracts/src/Interfaces/IAddressesRegistry.sol` | 55 | 48 | 25 |
| `source-snapshot/contracts/src/Interfaces/IBorrowerOperations.sol` | 37 | 29 | 4 |
| `source-snapshot/contracts/src/Interfaces/IJpyUsdRateProvider.sol` | 6 | 3 | 1 |
| `source-snapshot/contracts/src/Interfaces/IPriceFeed.sol` | 6 | 3 | 1 |
| `source-snapshot/contracts/src/Interfaces/IPriceFeedProxy.sol` | 65 | 58 | 16 |
| `source-snapshot/contracts/src/Interfaces/IStabilityPool.sol` | 34 | 9 | 2 |
| `source-snapshot/contracts/src/Interfaces/ITroveManager.sol` | 33 | 26 | 8 |
| `source-snapshot/contracts/src/PriceFeeds/CompositePriceFeed.sol` | 61 | 30 | 9 |
| `source-snapshot/contracts/src/PriceFeeds/DFPriceFeedBase.sol` | 158 | 74 | 41 |
| `source-snapshot/contracts/src/PriceFeeds/DFWstETHPriceFeed.sol` | 211 | 139 | 120 |
| `source-snapshot/contracts/src/PriceFeeds/JpyFreezeLib.sol` | 107 | 44 | 21 |
| `source-snapshot/contracts/src/PriceFeeds/JpyUsdRateProvider.sol` | 162 | 110 | 21 |
| `source-snapshot/contracts/src/PriceFeeds/MainnetPriceFeedBase.sol` | 134 | 80 | 14 |
| `source-snapshot/contracts/src/PriceFeeds/PriceFeedPlaceholder.sol` | 70 | 23 | 21 |
| `source-snapshot/contracts/src/PriceFeeds/PriceFeedProxy.sol` | 512 | 276 | 217 |
| `source-snapshot/contracts/src/RedemptionHelper.sol` | 178 | 130 | 24 |
| `source-snapshot/contracts/src/StabilityPool.sol` | 603 | 299 | 3 |
| `source-snapshot/contracts/src/TroveManager.sol` | 1,866 | 1,326 | 47 |
| `source-snapshot/contracts/src/Zappers/archive/SkyUsdcSUsdsYieldZapper.sol` | 213 | 167 | 14 |
| `source-snapshot/contracts/src/Zappers/CollateralYieldZapper.sol` | 549 | 438 | 32 |
| **Total** | **8,678** | **5,702** | **930** |

## Reconciliation

The inventory was checked against the immutable audit differential
`b5265f311abc524683561b79792eab2900823fa9..2725216e0407a0ef4599e359a04094ae5f322624`.

- The 25 paths exactly equal all changed `.sol` paths under
  `source-snapshot/contracts/src/`; no documentation, scripts, tests, or other
  non-Solidity files are part of this inventory.
- Every per-file `Diff` equals Git additions plus deletions for that path.
  The total 930 equals `+745/-185`.
- The same source differential contains 171 Git hunks. All 25 paths and all 171
  hunks are included in the requested review.
- `Lines` and `Normalized` are Guardian interface-defined metrics. They are
  preserved as supplied and are not treated as `cloc` values. The separately
  reproducible `cloc 2.06` figures in `SCOPE.md` are 535 final-side changed-code
  nSLOC and 6,656 final whole-file context nSLOC.

The earlier proposal to omit seven legacy, archive, or cosmetic hunks is
superseded for scope purposes. Its point-in-time rationale remains in
[`ADDITIONAL_AUDIT_SCOPE_TRIAGE_2026-08-31.md`](./history/ADDITIONAL_AUDIT_SCOPE_TRIAGE_2026-08-31.md).
