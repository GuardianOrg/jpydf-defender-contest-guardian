#!/usr/bin/env python3
"""Exact-arithmetic scenario checks; not an EVM exploit or FX probability model.

Pinned Day1 candidates: dwstETH MCR 123.18%, dUSDC MCR 111.58%,
dUSDC CCR 124.50%, BCR 10 percentage points. Debt includes upfront fees.
Run with python3; no dependencies. The USD collateral quote and backing ratio
are assumed accurate and constant. JPYdf is valued at one yen.
"""
from fractions import Fraction as F


def main():
    for name, mcr in [("dwstETH", F(12318, 10000)), ("dUSDC", F(11158, 10000))]:
        # q = USD per JPY; r = current q / saved q, so ICR_true = ICR_oracle / r.
        for r in [F(1), F(101, 100), F(105, 100), F(112, 100)]:
            icr = mcr / r
            assert icr * r == mcr
            print(f"{name}: USD-per-JPY change={float((r-1)*100):.2f}%, true ICR={float(icr*100):.4f}%")
        assert mcr / F(105, 100) > 1  # 5% FX-only move leaves gross backing.
        assert mcr / mcr == 1  # principal coverage boundary, not safe-liquidation margin.
        print(f"{name}: parity USD-per-JPY rise={float((mcr-1)*100):.4f}%, USDJPY fall={float((1-1/mcr)*100):.4f}%")

    mcr, ccr, r = F(11158, 10000), F(12450, 10000), F(112, 100)
    debt = F(1_000_000)  # total debt; issued amount is smaller by upfront fee.
    collateral = debt * mcr  # saved-oracle yen value of new dUSDC collateral.
    old_debt, old_collateral = F(1_000_000), F(2_000_000)
    new_tcr = (old_collateral + collateral) / (old_debt + debt)
    assert collateral / debt >= mcr
    assert new_tcr >= ccr
    assert new_tcr == F(15579, 10000)
    assert new_tcr / r >= ccr  # even the true aggregate ratio remains above CCR.
    assert collateral / r == 996_250 < debt
    assert debt - collateral / r == 3_750
    assert (mcr + F(10, 100)) / r > 1  # optional batch buffer; solo route is weaker.
    assert mcr / F(105, 100) > F(105, 100)  # 5% FX example also covers gross 5% SP uplift.
    # Historical selected haircuts use yen-value reductions, not r increases.
    joint = mcr * (1 - F(932, 10000)) * (1 - F(117, 10000))
    assert abs(joint - 1) < F(1, 10000)  # displayed inputs are rounded.
    print(f"Historical joint-stress coverage={float(joint*100):.7f}%")
    # Failure to earn the full SP bonus is not SP principal loss.
    net_collateral_at_6_3pct = mcr / F(1063, 1000) * F(995, 1000)
    assert 1 < net_collateral_at_6_3pct < F(105, 100)
    print("PASS: solo dUSDC passes saved-price MCR/CCR but has JPY 3,750 gross shortfall at r=1.12.")


if __name__ == "__main__":
    main()
