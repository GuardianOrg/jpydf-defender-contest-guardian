# Final Production Candidate — Build And Test

These commands reproduce candidate
`1b453c10e3378390109cf42037a97b7f6de57b9e` from this audit repository plus the
pinned public dependencies below. Auditor access to the private implementation
repository is not required.

## Fixed toolchain

| Input | Version / commit |
| --- | --- |
| Solidity | 0.8.24 |
| EVM | Cancun |
| Optimizer | enabled, 200 runs |
| Forge used for recorded results | 1.7.1, commit `4072e48705af9d93e3c0f6e29e93b5e9a40caed8` |
| Node.js | 22 or later |
| pnpm | 10.4.1, pinned in the snapshot package and lockfile |
| forge-std | `726a6ee5fc8427a0013d6f624e486c9130c0e336` |
| OpenZeppelin Contracts | `bd325d56b4c62c9c5c1aff048c37c6bb18ac0290` (v4.9.5) |
| OpenZeppelin Contracts Upgradeable | `2d081f24cac1a867f6f73d512f2022e1fa987854` |
| Solady | `362b2efd20f38aea7252b391e5e016633ff79641` |
| Liquity V2 governance | `b880481d701d2b07236f2e04842c79b4fe77e5fd`, recursive submodules required |

`source-snapshot/contracts/foundry.lock`, `foundry.toml`, and `remappings.txt`
pin the same inputs. Vendored dependencies are deliberately not committed.

## Install public dependencies

Run from the audit repository root:

```sh
mkdir -p source-snapshot/contracts/lib

git clone https://github.com/foundry-rs/forge-std \
  source-snapshot/contracts/lib/forge-std
git -C source-snapshot/contracts/lib/forge-std checkout --detach \
  726a6ee5fc8427a0013d6f624e486c9130c0e336

git clone https://github.com/openzeppelin/openzeppelin-contracts \
  source-snapshot/contracts/lib/openzeppelin-contracts
git -C source-snapshot/contracts/lib/openzeppelin-contracts checkout --detach \
  bd325d56b4c62c9c5c1aff048c37c6bb18ac0290
git -C source-snapshot/contracts/lib/openzeppelin-contracts \
  submodule update --init --recursive

git clone https://github.com/Vectorized/Solady \
  source-snapshot/contracts/lib/Solady
git -C source-snapshot/contracts/lib/Solady checkout --detach \
  362b2efd20f38aea7252b391e5e016633ff79641

git clone https://github.com/liquity/V2-gov \
  source-snapshot/contracts/lib/V2-gov
git -C source-snapshot/contracts/lib/V2-gov checkout --detach \
  b880481d701d2b07236f2e04842c79b4fe77e5fd
git -C source-snapshot/contracts/lib/V2-gov submodule update --init --recursive

git clone https://github.com/OpenZeppelin/openzeppelin-contracts-upgradeable \
  source-snapshot/contracts/lib/openzeppelin-contracts-upgradeable
git -C source-snapshot/contracts/lib/openzeppelin-contracts-upgradeable checkout --detach \
  2d081f24cac1a867f6f73d512f2022e1fa987854
git -C source-snapshot/contracts/lib/openzeppelin-contracts-upgradeable \
  submodule update --init --recursive

pnpm -C source-snapshot/contracts install --frozen-lockfile --ignore-scripts
```

No RPC URL or secret is needed for the build, focused tests, standard gate,
artifact verification, or size gate.

## Verify committed identity

Auditor-local, without the private source:

```sh
./scripts/verify-production-companion.sh
node scripts/verify-final-hunk-provenance.mjs
```

Maintainers with an exact detached source checkout and initialized recursive
submodules additionally run:

```sh
./scripts/verify-solidity-snapshot.sh \
  /path/to/jpydf-v2-at-final-commit \
  1b453c10e3378390109cf42037a97b7f6de57b9e

./scripts/verify-production-companion.sh \
  /path/to/jpydf-v2-at-final-commit \
  1b453c10e3378390109cf42037a97b7f6de57b9e

./scripts/verify-final-nsloc.sh
```

The first verifier checks the exact production source tree. The second checks
the complete test tree and every curated script, tool, configuration, and
English document in `PRODUCTION_COMPANION_MAPPING.tsv`. It also verifies the
executable deploy wrapper and absence of all four pilot-overlay symbols.
Audit-local authority and scope-index corrections are intentionally not claimed
as byte-exact candidate documents by that mapping.
The local hunk verifier independently reconstructs the 171 base-to-final hunks
from the two committed source trees, checks every structural ledger field, and
asserts the exact 171-hunk / 25-path review boundary.
The nSLOC verifier extracts the exact 25 paths from those same immutable audit
commits and checks every base/final `cloc 2.06` row and total.
Maintainers can additionally reproduce the complete origin attribution from the
private history with `node scripts/verify-final-hunk-provenance.mjs --generate
/path/to/jpydf-v2-at-final-commit` and byte-compare the output to the ledger.

## Build

```sh
cd source-snapshot/contracts
forge build --skip test
```

Recorded standalone-package result: 262 files compiled successfully with Solc
0.8.24. The compiler emitted known lint/warning output but no build error. The
276-file result in the private full production checkout includes additional
unpriced script context and is not the expected count for this curated command.

## Focused remediation tests

Run from `source-snapshot/contracts`:

```sh
# Runtime JPY/USD decimals and freeze/provenance state
forge test --match-path test/JpyUsdRateProvider.t.sol -vv

# Recoverable failure, risk-reducing paths, and validated resume
forge test --match-path test/shutdown.t.sol -vv
forge test --match-path test/CollateralYieldZapper.t.sol -vv

# Proxy lifecycle, 30-hour boundary, placeholders, and redemption accounting
forge test --match-path 'test/PriceFeedProxy*.t.sol' -vv
forge test --match-path test/PriceFeedPlaceholder.t.sol -vv
forge test --match-path test/RedemptionHelperOracleFailure.t.sol -vv
forge test --match-path test/RedemptionHelper.t.sol -vv

# Reserved one-shot risk finalization
forge test --match-path test/RiskParamsFinalization.t.sol -vv

# Production deploy constants, risk validation, identity, and Timelock wiring
forge test --match-path test/DeployBranchRiskInvariants.t.sol -vv
forge test --match-path test/DeployLiquity2PriceFeedReadback.t.sol -vv
forge test --match-path test/DeployLiquity2StrategySelector.t.sol -vv
forge test --match-path test/DeployMainnetProductionTimelock.t.sol -vv

# Vault backing, wstETH direct/derived pricing, MIN_DEBT, and cleanup context
forge test --match-path 'test/CollateralVault*.t.sol' -vv
forge test --match-path test/DFWstETHPriceFeed.t.sol -vv
forge test --match-path test/DFWstETHPriceFeedProxyIntegration.t.sol -vv
forge test --match-path test/MinDebtJPYdf.t.sol -vv
forge test --match-path test/MainnetPilotController.t.sol -vv
forge test --match-path test/verification-20260815/ActivePoolVerification.t.sol -vv

pnpm test:production-rollback
```

These commands cover the later decimals, recovery, 30-hour, and cleanup work in
addition to the earlier remediation themes.

## Full local gates

Fast PR-equivalent gate:

```sh
forge test -vv \
  --no-match-contract 'Mainnet|Invariant|Anchored|Initiative|LocalParityDrill'
```

Recorded final-source result: 99 suites, 1,789 passed, 0 failed, 1 skipped.

Full local gate including invariant/anchored/initiative suites, excluding
mainnet and the stateful local deployment drill:

```sh
forge test --threads 1 -vv --no-match-contract 'Mainnet|LocalParityDrill'
```

The full gate is intentionally serialized. Foundry 1.7.1 implements `vm.setEnv`
with process-wide environment mutation, while
`ConsoleDevnetTimelockHandover.t.sol` and
`DeployLiquity2StrategySelector.t.sol` both mutate/read `DF_TIMELOCK` in
independent EVMs. A default-parallel run recorded 1,844 passed, 1 failed, and 1
skipped; the failed Zapper test passed immediately when rerun alone. A separate
two-suite reproducer confirmed that the process-global race can inject the
other suite's codeless address. This is a test-runner isolation defect, not
evidence of a Solidity failure; use the serialized command for the complete
gate and do not conceal the parallel result.

Recorded serialized result: the 107-suite non-mainnet selection completed with
exit status 0. The implementation mechanism is visible in Foundry 1.7.1
[`env.rs`](https://github.com/foundry-rs/foundry/blob/4072e48705af9d93e3c0f6e29e93b5e9a40caed8/crates/cheatcodes/src/env.rs#L12-L29).

Mainnet fork context is opt-in and needs a non-secret RPC URL. The archived Sky
converter test is the only committed suite that selects a live fork directly:

```sh
MAINNET_RPC_URL=<redacted-provider-url> \
DF_REQUIRE_MAINNET_FORK_TESTS=true \
forge test --match-contract SkyUsdcSUsdsConverterMainnetForkTest -vv
```

Fork block/hash, runtime code, roles, and deployment manifest readbacks are
launch evidence. Do not describe a source-only test run as on-chain production
verification.

## Contract size gate

```sh
./utils/check-contract-sizes.sh
```

Recorded final result: pass. Notable affected runtime sizes are
TroveManager 24,570 bytes (6-byte EIP-170 margin) and BorrowerOperations 24,531
bytes (45-byte margin). Re-run this command with the exact toolchain before any
deployment artifact is accepted.

## Artifact identity

Build final standard and metadata-free artifacts separately. Include semantic
storage output in the standard build:

```sh
forge build --skip test --extra-output storageLayout

FOUNDRY_OUT=/tmp/jpydf-final-no-metadata \
FOUNDRY_CACHE_PATH=/tmp/jpydf-final-no-metadata-cache \
forge build --skip test --no-metadata

node ../../scripts/verify-final-artifacts.mjs \
  out /tmp/jpydf-final-no-metadata
```

The verifier checks every row of
[`FINAL_PRODUCTION_ARTIFACTS.tsv`](../../FINAL_PRODUCTION_ARTIFACTS.tsv): standard
and no-metadata creation/runtime byte counts and Keccak-256 hashes, plus ABI and
method-identifier SHA-256 hashes.

To reproduce the base-to-final semantic storage comparison, make a detached
worktree at the locally preserved base, reuse the same pinned public dependency
checkouts, and build storage output there:

```sh
cd "$(git rev-parse --show-toplevel)"
git worktree add --detach /tmp/jpydf-audit-base \
  b5265f311abc524683561b79792eab2900823fa9
AUDIT_ROOT="$(pwd)"
ln -s "$AUDIT_ROOT/source-snapshot/contracts/lib" \
  /tmp/jpydf-audit-base/source-snapshot/contracts/lib

forge build \
  --root /tmp/jpydf-audit-base/source-snapshot/contracts \
  --out /tmp/jpydf-base-out \
  --cache-path /tmp/jpydf-base-cache \
  --skip test --extra-output storageLayout

forge build \
  --root /tmp/jpydf-audit-base/source-snapshot/contracts \
  --out /tmp/jpydf-base-no-metadata \
  --cache-path /tmp/jpydf-base-no-metadata-cache \
  --skip test --no-metadata

node "$AUDIT_ROOT/scripts/verify-final-artifacts.mjs" \
  source-snapshot/contracts/out /tmp/jpydf-final-no-metadata \
  --base-storage-out /tmp/jpydf-base-out \
  --base-no-metadata-out /tmp/jpydf-base-no-metadata
```

The base-aware verifier enumerates every deployable `src` artifact whose
standard creation/runtime changed and separately every metadata-free executable
change. It fails if either set is absent from the manifest or a metadata-free
change is outside the declared review, legacy-context, or archive-context
coverage classes. The
storage verifier checks every stateful artifact row in
[`FINAL_PRODUCTION_STORAGE_LAYOUTS.tsv`](../../FINAL_PRODUCTION_STORAGE_LAYOUTS.tsv)
using only `label, slot, offset, resolved type`; compiler AST IDs and contract
origin metadata are deliberately excluded.

Inspect any contract directly with:

```sh
forge inspect src/PriceFeeds/PriceFeedProxy.sol:PriceFeedProxy abi --json
forge inspect src/PriceFeeds/PriceFeedProxy.sol:PriceFeedProxy storage-layout --json
```

Storage comparison must ignore compiler AST IDs and compare the semantic tuple
`label, slot, offset, resolved type`. The review result is summarized in
`PRODUCTION_CLEANUP_DIFFERENTIAL_REVIEW.md`.

## Static analysis

The snapshot retains the exact candidate Slither configuration and pinned Python
requirements; both are object-mapped to the final source commit. The audit-root
`config/slither-audit.config.json` is older audit-local context and is not the
candidate configuration. Static-analysis output must be tied to the final tree
and triaged; raw tool output is not a finding disposition.

```sh
python3 -m venv .venv
source .venv/bin/activate
pip install -r requirements.txt
slither . \
  --compile-force-framework foundry \
  --config-file slither.config.json
```

## Secret and generated-file boundary

Do not commit dependency trees, `node_modules`, `out`, `cache`, broadcast data,
environment files, RPC credentials, private keys, generated deployment
manifests, or unredacted evidence. `SeedLocalDemo.s.sol` is deliberately not in
the companion script closure. The complete production Solidity and test trees
are committed; excluded operational tools are not needed to compile or run the
listed audit gates.
