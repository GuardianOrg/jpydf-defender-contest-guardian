# Final Pre-Audit Correction Delta — 2026-08-09

This is the final correction delta after the initial wstETH / Morpho follow-up
freeze. The earlier, broader delta from the audited identity to `0a85b374` is
preserved in [`SCOPE_DELTA_2026-08-07.md`](./SCOPE_DELTA_2026-08-07.md).

## Identities

| Item | Commit |
| --- | --- |
| Initial follow-up freeze | `0a85b374015e2553d2985b4a3f454b6aee4514a5` |
| Final Solidity correction | `c1b34df3e5bf6be9d94e7f0bace224c03c859974` |
| Final handoff freeze | `fe3d3d0e182b8189202dee3a3db8103bd0df1de7` |
| Final source merge | `03fa20a3a1e6971876185c2bc7889ee47f6608c1` |

The final handoff freeze contains the Solidity correction as an ancestor. The
source-side review and landing identities are retained above for provenance;
all reviewable files and regression evidence are committed in this repository.

## Solidity Delta

Only two implementation files changed from the initial follow-up freeze:

| File | Change | Review disposition |
| --- | --- | --- |
| [`DFStabilityPool.sol`](../../../source-snapshot/contracts/src/DFStabilityPool.sol) | Prevent current or stashed collateral-gain payout through `provideToSP(..., true)` in the deposit block, while preserving first deposits, no-claim stashing, gain-free top-ups, and next-block settlement. | Medium anti-sniping bypass fixed at source identity `27192de0`; regression coverage is in [`stabilityPool.t.sol`](../../../source-snapshot/contracts/test/stabilityPool.t.sol). |
| [`ERC4626Strategy.sol`](../../../source-snapshot/contracts/src/Strategies/ERC4626Strategy.sol) | After donation-inclusive partial emergency redemption, clamp the owned-share tracker to the post-redeem raw share balance. Normal owned-position withdrawals remain unchanged. | Low persistent false-low tracker fixed at source identity `c1b34df3`; regression coverage is in [`ERC4626Strategy.t.sol`](../../../source-snapshot/contracts/test/ERC4626Strategy.t.sol). |

The implementation diff is 10 added and 1 removed lines. `cloc 2.06` measures
the two files at 397 → 403 code lines, so the recommended active full-review
body is 5,219 → 5,225 nSLOC. The whole `contracts/src` tree is 13,266 →
13,272 nSLOC across the same 109 files.

The normalized CSV-body SHA-256 is
`388738f44cd4c8c345761404aecf889c24024bfec2d123499ffe74ef4f40f7f8`;
the CSV is
[`evidence/wsteth-cycle/contracts-src-cloc-c1b34df3.csv`](../../../evidence/wsteth-cycle/contracts-src-cloc-c1b34df3.csv).

## Supporting Delta

- Five test files add the Stability Pool regression matrix, invariant-handler
  block progression, and the ERC-4626 loss + repair donation + partial
  emergency-recovery regression.
- `contracts/utils/check-contract-sizes.sh` isolates Forge output and cache in a
  temporary directory. Production-size validation therefore exits on production
  artifacts only and is not contaminated by oversized tester artifacts left by
  earlier `forge test` runs.
- Japanese source-of-truth requirements and English support translations record
  both corrected state-machine boundaries.

## Final Verification

The committed public snapshot, with only the pinned public dependencies
installed in ignored `lib/`, produced:

- source reconciliation: drift 0 / missing 0 / undecided 0 / stated 0;
- preserved audit-patch verifier: 21 / 21;
- production size gate: passed; largest production runtime is
  `BorrowerOperations` at 24,385 / 24,576 bytes (191-byte margin);
- standard Foundry gate: 1,541 passed / 0 failed / 0 skipped across 81 suites;
- source-side checks for correction identities `27192de0`, `0f889751`, and
  `c1b34df3`: passed before landing; auditor reproduction uses the public
  snapshot commands above.

The multi-skill review found one Medium and one Low source issue, and both are
fixed in this final freeze. The analogous Aave tracker hypothesis was rejected
after the final state-transition review. Pending-but-not-stale Chainlink updates
remain a launch monitoring and parameter assumption, not an open source defect.
