# Final Production Solidity Differential Review

## Result

No new security defect was identified in the final production-cleanup change or
in its interaction with the complete post-Chain-Defenders differential. The
cleanup removes the test-only yield split/dust overlay without changing the
production 75% Stability Pool yield formula. This review does not replace the
independent Guardian audit of the 164-hunk review subset defined in `SCOPE.md`.

The reviewed endpoint includes runtime JPY/USD decimals validation, recoverable
oracle shutdown/resume, the 30-hour normal-redemption provenance gate, and the
physical production cleanup. The first three survive in the priced base-to-final
diff; cleanup is included as its own delta and endpoint-absence evidence because
`ActivePool.sol` returns to the base blob.

## Fixed scope

| Item | Identity |
| --- | --- |
| Base commit | `d4122704d08b521d832438c31c0ddccf202fea81` |
| Base `contracts/src` tree | `417fe3b995f3dec84fd611fcc2f5c3ebd62d5c7a` |
| Final commit | `1b453c10e3378390109cf42037a97b7f6de57b9e` |
| Final `contracts/src` tree | `84476d9086e89580c58918b203f4142ecd839765` |
| Complete source differential | 25 files, 171 hunks, `+745/-185` |
| Current requested review | 22 paths, 164 hunks; exact exclusions in `SCOPE.md` |
| Final test tree | `65edf44aaad8ee395fa9456151fed25f40a3dfde` |

Every final changed file is listed in
[`FINAL_PRODUCTION_HUNK_PROVENANCE.tsv`](../../../FINAL_PRODUCTION_HUNK_PROVENANCE.tsv).
Unchanged callers/importers were traced as integration context.

## Cleanup review

The retired intermediate overlay exposed four symbols:

- `MAINNET_PILOT_CLEANUP_OVERLAY`
- `isMainnetPilotOverlay`
- `effectiveSPYieldSplit`
- `PILOT_MAX_JPYDF_ROUNDING_DUST`

All four are absent from final `contracts/src`. `ActivePool` now evaluates both
pending and minted Stability Pool yield with the compile-time
`SP_YIELD_SPLIT = 75 * _1pct` constant directly. The deleted helper returned
that same constant on the production chain path, so integer multiplication and
division order, rounding, state writes, and external calls are unchanged.

The canary-only rounding-dust bound remains local to
`script/MainnetPilotController.sol`; deployment/test policy is not imported into
production contracts. `ActivePool.sol` final blob
`4a97ea9f17d9c402c340863a333719e4e4c3d421` equals the base blob exactly and
therefore is not one of the 25 priced files. `Dependencies/Constants.sol` now
has only the intended base-to-final `MIN_DEBT` change; no overlay survives.

[`evidence/final-production-cleanup/`](../../../evidence/final-production-cleanup)
pins the exact two-file pre-cleanup-to-final patch, audit commits, source trees,
blobs, and patch SHA-256. It preserves the removal delta independently of Git
history while the priced base-to-final ledger remains endpoint-based.

## Security-sensitive change inventory

| Surface | Security effect reviewed |
| --- | --- |
| PriceFeedProxy and feed interfaces | Three distinct live paths, recoverable failure latch, source confirmation, cache separation, runtime provenance, and 30-hour normal-redemption gate |
| JpyUsdRateProvider / JpyFreezeLib | Runtime decimals pinning, freeze episode transitions, accepted timestamp provenance, and expiry/recovery behavior |
| DFWstETHPriceFeed | Fail-closed direct/derived redemption reference, urgent path, cache isolation, JPY conversion, and backing multiplication |
| BorrowerOperations / TroveManager / RedemptionHelper | Failure vs terminal shutdown separation, risk-reducing operations, urgent settlement, and failed-branch share/refund accounting |
| AddressesRegistry / BO / TM / SP | Dedicated one-shot, atomic reserved-risk finalization and validation |
| CollateralVault | Confirmed-conservative full-backing gates while retaining repair ingress |
| Constants | `MIN_DEBT = 100_000e18`; production `SP_YIELD_SPLIT = 75%`; no pilot overlay |
| Zappers | Authorized Lido referral management and native-ETH route; non-redirection depends on canonical Lido stETH/wstETH identity and reviewed `submit(address)` semantics |

## Blast radius

Price consumers include opening/adjusting Troves, liquidation, normal
redemption across every branch, urgent redemption after shutdown, TCR/SCR
checks, and source governance. A broken price path can therefore affect both
safety and system-wide redemption liveness. The review traced these consumers
through each branch proxy to its current source and external data/backing
dependencies; the result is recorded in
[`FINAL_PRODUCTION_DEPENDENCY_GRAPH.md`](../FINAL_PRODUCTION_DEPENDENCY_GRAPH.md).

Risk-parameter finalization mutates Registry, BorrowerOperations, and
TroveManager values atomically and cannot be repeated. CollateralVault is an
upgradeable surface, so its semantic storage layout received separate attention.
Under canonical Lido stETH/wstETH identity and reviewed `submit(address)`
semantics, Zapper changes affect user entrypoints without changing custody
destination or protocol accounting. Deployment readback must prove that
integration assumption.

## ABI, storage, and bytecode

Final creation/runtime identities, including separate no-metadata builds, are
in [`FINAL_PRODUCTION_ARTIFACTS.tsv`](../../../FINAL_PRODUCTION_ARTIFACTS.tsv).

- ABI/selectors intentionally change where new finalization, recovery, urgent,
  provenance, or referral interfaces were added. CollateralVault,
  JpyUsdRateProvider, RedemptionHelper, and the executable JpyFreeze library do
  not add external selectors.
- Semantic storage layout is unchanged for CollateralVault, DFStabilityPool,
  JpyUsdRateProvider, PriceFeedPlaceholder, PriceFeedProxy, RedemptionHelper,
  and StabilityPool.
- Semantic additions in AddressesRegistry, BorrowerOperations,
  DFWstETHPriceFeed, TroveManager, and both Zappers correspond to explicit
  source changes. These implementations are constructor-deployed in the final
  plan; the upgradeable CollateralVault layout is unchanged.
- JpyFreezeLib has identical no-metadata executable bytecode at base and head;
  its metadata-bearing hash changes because its source metadata changed.
- ActivePool ABI and semantic storage remain unchanged, and its final source is
  byte-identical to the base.

The production size gate passes. The narrowest EIP-170 margins in the affected
core are TroveManager at 24,570 bytes (6 bytes remaining) and
BorrowerOperations at 24,531 bytes (45 bytes remaining). These are deployment
constraints and should be rechecked from the exact final compiler/toolchain;
they are not current over-limit findings.

## Verification performed

At the final source identity:

- `forge build`: pass, Solc 0.8.24, Cancun, optimizer 200;
- focused MIN_DEBT: 9/9 pass;
- focused ActivePool verification: 7/7 pass;
- focused MainnetPilotController: 17/17 pass;
- fast Foundry gate excluding Mainnet/Invariant/Anchored/Initiative/LocalParityDrill:
  99 suites, 1,789 passed, 0 failed, 1 skipped;
- production rollback TypeScript gate: pass;
- contract-size gate: pass;
- Git whitespace gate and documentation link checks: pass;
- source artifact comparison: 129 `src` targets, no unintended ABI/method
  identifier change from the cleanup; only ActivePool executable bytecode
  changed during the intermediate cleanup comparison and the final source was
  restored exactly to the Chain Defenders base.

The coordinated source PR CI also passed all nine required checks; three
coverage jobs were intentionally skipped by scope policy.

## Findings and retained risks

No new cleanup-specific actionable finding was raised by this differential
review. The following complete-differential boundaries remain explicit inputs
to the external audit and launch decision:

1. stETH/ETH remains fail-closed at its configured threshold. The intended
   production value is 90,000 seconds and requires deployment readback. There is
   a stale-high window before the threshold and no direct-only fallback afterward.
2. The 30-hour JPY provenance gate applies only to normal redemption. A readable
   round that simply ages gives a `[30h, 96h)` urgent interval; an earlier invalid
   response can expire sooner. Before expiry, repeated valid stale-but-newer
   rounds can re-anchor freeze episodes and extend stale-FX urgent-path exposure
   beyond 96 hours from the original fresh observation. After expiry only a
   fresh response clears the latch. See
   [`FINAL_PRODUCTION_ENGLISH_AUTHORITY.md`](../FINAL_PRODUCTION_ENGLISH_AUTHORITY.md).
3. The proxy's `source()` marker is depth one. Acyclicity depends on the reviewed
   dependency graph and must be repeated for every replacement source.
4. No transient confirmation callback latch was added to the permanent proxy.
   The 12-hour lifecycle and human review remain the mitigation.
5. `finalizeRiskParams` permanently burns reserved-branch parameters; contract
   invariants do not replace runbook verification of real source/backing/
   Strategy wiring and cap-last ordering.
6. The stETH/ETH age warning at 88,200 seconds still requires externally
   delivered production alert evidence before launch.
7. Mainnet fork/on-chain bytecode and role readbacks remain launch evidence;
   they are not represented as completed by a source-only review.

## Conclusion

The cleanup is deletion-dominant, restores ActivePool to the audited-base source
blob, and leaves the production 75% yield split unchanged. The final package
includes the complete 25-file baseline-to-head source differential and the
separate cleanup delta/absence evidence, so decimals, recovery, 30-hour, and
cleanup work are all reviewable without pretending removed code is a surviving
hunk.
