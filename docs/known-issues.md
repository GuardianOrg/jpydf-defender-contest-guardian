# Previously Reported Findings

Findings from Guardian's October 12, 2026 security review. See the attached report for full descriptions. IDs are qualified by review round.

| Round | ID | Known finding | Report category | Final status |
| --- | --- | --- | --- | --- |
| Main review | L-01 | Cap opening can block risk finalization | DoS | Resolved |
| Main review | L-02 | Written-Off Strategies Can Remain Registered Indefinitely | OOS - Business logic errors | Acknowledged |
| Main review | L-03 | Shared Compensation Cap Allows Excessive Liquidator Rewards For dwstETH | OOS - Configuration | Resolved |
| Main review | L-04 | MCR Validation Omits Gas Compensation, Reducing SP Rewards For dJPY And dJGB | Validation | Resolved |
| Main review | L-05 | Morpho Emergency Recovery Can Incur A Penalty Without Recovering Funds | OOS - MEV | Resolved |
| Main review | L-06 | Bridge Burns Increase Redemption Fees | OOS - Business logic errors | Acknowledged |
| Main review | L-07 | Sky harvest can return principal as yield | OOS - Business logic errors | Resolved |
| Main review | L-08 | Nonzero Strategy valuation failure pauses a fully backed branch | OOS - denial-of-service | Resolved |
| Main review | L-09 | Zapper-only manager cannot perform Core's incident-safe close | logic / denial of service | Resolved |
| Main review | L-10 | Stale Zero Strategy Cache Can Misprice a Solvent Branch During Sky Preview Outage | oracle accounting | Resolved |
| Main review | I-01 | Oracle pause blocks management fee reductions | Business logic errors | Resolved |
| Main review | I-02 | Source switch event mislabels cached prices | Events | Resolved |
| Main review | I-03 | Truncation docs overstate redeemable amount | Documentation | Resolved |
| Main review | I-04 | Incorrect NatSpec For emergencyDisableStrategy Function | OOS - Documentation | Resolved |
| Main review | I-05 | Incorrect NatSpec For Strategy Emergency Withdrawal Functions | OOS - Documentation | Resolved |
| Main review | I-06 | Inconsistent registry auth errors | Informational | Resolved |
| Main review | I-07 | Standard ERC4626 ceil-withdraw rounding can transfer protocol principal to external shareholders | OOS - economic exploit / accounting | Acknowledged |
| Main review | I-08 | VaultV2 fee semantics charge recovered losses if performance fees are activated | OOS - economic / integration risk | Acknowledged |
| Main review | I-09 | Risk finalization omits the documented redistribution-penalty/MCR invariant | economic | Resolved |
| Remediation review | L-01 | Nested strategy OOG can permissionlessly relatch a healthy branch's oracle-failure pause | OOS - gas griefing / denial of service | Resolved |
| Remediation review | L-02 | Merkl Campaign Collisions Can Strand Pre-Funded Incentives | OOS - denial of service | Resolved |

