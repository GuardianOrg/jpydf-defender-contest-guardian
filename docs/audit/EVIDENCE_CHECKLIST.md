# Evidence Checklist

This checklist separates the additional-audit kickoff package from evidence
that can only be produced during the mainnet deployment ceremony. A source
audit does not satisfy a launch gate by implication.

## Audit Identity And Scope

- [x] Chain Defenders remediation base fixed at
      `d4122704d08b521d832438c31c0ddccf202fea81`, source tree
      `417fe3b995f3dec84fd611fcc2f5c3ebd62d5c7a`.
- [x] Final production candidate fixed at
      `1b453c10e3378390109cf42037a97b7f6de57b9e`, source tree
      `84476d9086e89580c58918b203f4142ecd839765`.
- [x] The complete source differential and requested review scope is recorded as
      25 files, 171 hunks, and `+745/-185`.
- [x] Current `cloc 2.06` sizing records 535 final-side changed code nSLOC.
      Its 6,656 final whole-file nSLOC is context only,
      not the scope or a whole-file re-audit request.
- [x] Runtime decimals, recovery/resume, and the 30-hour normal-redemption gate
      are included in the requested review subset.
- [x] The later production-cleanup delta and evidence that the removed endpoints
      are absent are
      included. `ActivePool.sol` is base/head identical, so no ActivePool hunk
      survives in the base-to-final source differential.
- [x] Every changed source file has base/final blobs, a review
      classification, theme, and rationale in `FINAL_PRODUCTION_HUNK_PROVENANCE.tsv`.
- [x] A committed verifier recomputes all 171 source-diff hunk IDs and structural
      fields and asserts the exact 171-hunk / 25-path boundary;
      full PR/commit attribution can be regenerated from the pinned private
      history when available.
- [x] Candidate source-level price/control topology and the required circularity
      proof procedure are recorded in `docs/audit/FINAL_PRODUCTION_DEPENDENCY_GRAPH.md`.
- [x] `docs/audit/KNOWN_RISKS_AND_CURRENT_POSITION.md` maps known risks to the final
      candidate and separates open, previously remediated, launch-only, and future-change
      conditions without claiming formal acceptance.
- [ ] Guardian accepts the exact base, head, and SOW and acknowledges the
      known-risk register as an engagement input. Independent assessment is a
      requested audit deliverable; Product / Protocol Risk separately records
      treatment.
- [ ] Guardian confirms the earliest kickoff and, where feasible without
      reducing depth, the 18 September 2026 code-review/findings-report date.

## Reproduction Bundle

- [x] Complete final production source tree is committed.
- [x] Complete final test/fixture tree `65edf44aaad8ee395fa9456151fed25f40a3dfde`
      is committed.
- [x] Solc 0.8.24, Cancun, optimizer settings, dependency commits, Foundry lock,
      remappings, and standalone pnpm lock are committed.
- [x] The exact deploy-script dependencies and production-cleanup tool
      dependencies are committed as supporting context, not review targets.
- [x] Current English specifications and launch policies required for review are
      committed; private-repository access is not required.
- [x] The JPY/USD market-hours observations, reproduction method, economic model,
      assumptions, and pending treatment conditions are available in English.
- [x] Prior Chain Defenders PDFs and their local hash-pinned indexes are present.
- [x] Standard/no-metadata bytecode, ABI, method, and base/final semantic storage
      evidence is recorded for 35 artifacts / 26 stateful layouts; base-aware
      coverage detects all 34 standard-bytecode changes and all 18
      metadata-free executable changes under `src`.
- [x] Maintainer adversarial pre-audit is committed separately from prior and
      future external-auditor dispositions.
- [ ] Both coordinated audit-repository PRs are merged.

## Local Verification

- [x] Final source build passes with Solc 0.8.24.
- [x] Focused suites cover runtime decimals, recovery/resume, 30-hour provenance,
      redemption failure accounting, wstETH pricing, Vault backing, one-shot
      risk finalization, MIN_DEBT, Zapper behavior, and production cleanup.
- [x] Fast Foundry gate: 99 suites, 1,789 passed, 0 failed, 1 skipped.
- [x] Production rollback gate passes.
- [x] Contract-size gate passes; TroveManager has 6 bytes and
      BorrowerOperations has 45 bytes of EIP-170 margin.
- [x] All four removed experimental symbols are absent and `ActivePool.sol` is exactly
      base/head byte-identical.
- [x] The committed package verifier passes against both its own committed tree
      and detached final-source commit `1b453c10`.
- [x] Committed nSLOC verifier reproduces all 25 base/final rows and totals from
      the immutable audit-repository source snapshots with `cloc 2.06`.
- [x] Standard/no-metadata artifact verifier passes from the standalone audit
      checkout: 35 artifacts, complete 34 standard changes, complete 18
      metadata-free executable changes, and 26 layouts.
- [x] Full 107-suite non-mainnet local Foundry gate completes with exit status 0
      when serialized with `--threads 1`. The separately reproduced
      process-global `vm.setEnv` parallel-isolation defect is recorded in
      `BUILD_AND_TEST.md`; this is not represented as a parallel-gate pass.

## Launch-Only Deployment Evidence

- [ ] A fresh production OpenZeppelin v4.9.5 Timelock is deployed with
      `minDelay = 43,200`; it is distinct from the persistent canary Timelock at
      300 seconds.
- [ ] Production Timelock proposer/executor/canceller, self-admin status, closed
      executor, Safe thresholds, signer-control domains, and negative deployer
      authority are read back on-chain.
- [ ] Deployment source commit/tree, compiler settings, constructor arguments,
      creation/runtime hashes, and verified-source provenance match this package.
- [ ] `FORK_BLOCK` is fixed and the affected deploy/handover/manifest data path is
      exercised against an archive-capable mainnet RPC.
- [ ] Initial active/reserved branch status, external oracle/vault/Strategy
      addresses, risk parameters, and wiring match the approved manifest.
- [ ] Every TroveManager `priceFeed` readback is its branch PriceFeedProxy, not a
      direct source; every Proxy source and all three quote methods are verified,
      with normal-redemption JPY provenance checked separately.
- [ ] Reserved branches remain cap-zero until source binding, live backing and
      Strategy checks, one-shot `finalizeRiskParams`, and cap-last activation.
- [ ] JPY/USD and collateral oracle readbacks record decimals, `updatedAt`, age,
      and seconds-to-stale at the deployment block.
- [ ] The deployment-bound dependency graph pins every Proxy, source, transitive
      target, implementation, runtime code hash, immutable binding, mutable
      route, and controlling owner/admin at one hash-rechecked block; an
      independent reviewer confirms no return path to a Proxy.
- [ ] The stETH/ETH monitor emits warning `ALRT-ORCL-001` at 88,200 seconds and
      exact-threshold P0 `ALRT-ORCL-012` at 90,000 seconds, has an enabled
      escalation target, and proves labeled incident creation, intended-human
      receipt, and fresh-round same-key resolution.
- [ ] JPY monitoring detects a second `JpyRateFrozen` / episode onset moving
      forward without an intervening fresh recovery, or tracks absolute age
      since the last actually fresh observation; it is not defeated by a
      stale-but-newer re-anchor.
- [ ] Runtime-decimals monitor `ALRT-ORCL-015` reads all five initially active feed roles at
      one safe head and proves labeled incident creation, intended-human receipt,
      and same-key resolution through the production alert route.
- [ ] Normal-redemption age synthetic `ALRT-ORCL-016` reads Proxy/source price
      paths, BorrowerOperations pause, and provider provenance at one
      hash-rechecked block
      and proves labeled delivery, intended-human receipt, and same-key
      resolution through the existing SNS-to-Amazon-Q route.
- [ ] JPY/USD market-hours treatment records the approved loss budget, expiry or
      review date, and responsible owner. Monitoring compares an independent FX
      price with Chainlink rounds and also reads live JPYdf supply, base rate,
      redeemable exposure, actual redemptions, and Vault exits; a same-value
      heartbeat must not be treated as fresh market price discovery.
- [ ] Vault/Strategy production monitoring proves labeled external delivery,
      intended-human receipt, and same-key resolution for unavailable live
      Strategy valuation (`ALRT-STGY-001`), backing deficit
      (`ALRT-BACK-001/002`), oldest claimable request (`ALRT-VAULT-006`), and a
      blocked deposit/redeem/claim user-path synthetic.
- [ ] Deployed Zapper readback proves canonical Lido stETH/wstETH addresses,
      runtime identity, their immutable relation, and the reviewed
      `submit(address)` semantics.
- [ ] The 100,000-JPYdf minimum-debt capacity case covers list growth,
      redemption gas, liquidation, and keeper viability at intended branch
      exposure, rather than relying only on exact-boundary unit tests.
- [ ] Product / Protocol Risk formally approves the retained JP/EN risk text and
      production publication/activation evidence is recorded; merged text alone
      is not approval or deployment proof.
- [ ] Handover prepare/accept/verify completes without unintended deployer,
      temporary-admin, or stale owner authority.

## Activation Boundaries

- [ ] Active and reserved branches match `docs/en/Parameters.md` and the initial
      manifest.
- [ ] All six reserved branches (indices 2–7) remain cap/allocation zero until
      their activation gates pass.
- [ ] JPYdf/USDC Uniswap v4 is the only active DEX-liquidity route.
- [ ] Removed Curve/Balancer/Uniswap v3, flash-close, collateral-funded repay,
      Multiply, and active bridge paths are absent from production routing.

## Secret Hygiene

- [x] No `.env`, RPC credential, API key, signer export, seed phrase, private
      key, generated broadcast, or unredacted deployment manifest is committed.
- [x] `SeedLocalDemo.s.sol` is excluded because its public Anvil test key is not
      required by production or the audit test closure.
- [ ] Final PR diff is re-scanned for secrets and generated artifacts before
      merge.
