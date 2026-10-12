// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.24;

uint256 constant DECIMAL_PRECISION = 1e18;
uint256 constant _100pct = DECIMAL_PRECISION;
uint256 constant _1pct = DECIMAL_PRECISION / 100;

// Amount of ETH to be locked in gas pool on opening troves
uint256 constant ETH_GAS_COMPENSATION = 0.0375 ether;

// Liquidation
uint256 constant MIN_LIQUIDATION_PENALTY_SP = 5e16; // 5%
uint256 constant MAX_LIQUIDATION_PENALTY_REDISTRIBUTION = 20e16; // 20%

// --- DeltaForesight Day-1 collateral branches (Parameters.md §1 / §3-A) ---
// Per-branch CR / penalty values, named by dToken (the core's collateral == dToken).
// These constants are consumed by DeployLiquity2.s.sol and DF branch-param tests.
// Fractional percents are written as <pct*100> * _1pct / 100, which is exact because
// _1pct (= 1e16) is divisible by 100 and every §3-A value has at most 2 decimal places.

// Branch 0: dwstETH (wstETH) — re-derived per #1325: WETH high-vol pipeline
// (ETH 2h 99.9th 9.07%, slip 0.98%x2, JPY FX 1.17%, SP 5%) plus a stETH/ETH
// depeg leg of 3.25% (2h max DD, hourly stETH/ETH 2022-01..2026-08).
uint256 constant MCR_DWSTETH = 12318 * _1pct / 100; // 123.18%
uint256 constant CCR_DWSTETH = 14167 * _1pct / 100; // 141.67%
uint256 constant SCR_DWSTETH = 110 * _1pct; // 110%
uint256 constant BCR_DWSTETH = 10 * _1pct; // 10%
uint256 constant LIQUIDATION_PENALTY_SP_DWSTETH = 5 * _1pct; // 5%
uint256 constant LIQUIDATION_PENALTY_REDISTRIBUTION_DWSTETH = 10 * _1pct; // 10%

// Branch 1: dUSDC (USDC) — confirmed
uint256 constant MCR_DUSDC = 11158 * _1pct / 100; // 111.58%
uint256 constant CCR_DUSDC = 12450 * _1pct / 100; // 124.50%
uint256 constant SCR_DUSDC = 105 * _1pct; // 105%
uint256 constant BCR_DUSDC = 10 * _1pct; // 10%
uint256 constant LIQUIDATION_PENALTY_SP_DUSDC = 5 * _1pct; // 5%
uint256 constant LIQUIDATION_PENALTY_REDISTRIBUTION_DUSDC = 10 * _1pct; // 10%

// Branch 2: dETH (Underlying TBD) — inert, using the same conservative LST
// envelope as Branch 0 per the #1454 Owner Decision amendment.
uint256 constant MCR_DETH = 12318 * _1pct / 100; // 123.18%
uint256 constant CCR_DETH = 14167 * _1pct / 100; // 141.67%
uint256 constant SCR_DETH = 110 * _1pct; // 110%
uint256 constant BCR_DETH = 10 * _1pct; // 10%
uint256 constant LIQUIDATION_PENALTY_SP_DETH = 5 * _1pct; // 5%
uint256 constant LIQUIDATION_PENALTY_REDISTRIBUTION_DETH = 10 * _1pct; // 10%

// Branch 3: dUSD-A (Underlying TBD) — inert, structured-stable 120% floor
uint256 constant MCR_DUSD_A = 120 * _1pct; // 120.00%
uint256 constant CCR_DUSD_A = 13765 * _1pct / 100; // 137.65%
uint256 constant SCR_DUSD_A = 105 * _1pct; // 105%
uint256 constant BCR_DUSD_A = 10 * _1pct; // 10%
uint256 constant LIQUIDATION_PENALTY_SP_DUSD_A = 5 * _1pct; // 5%
uint256 constant LIQUIDATION_PENALTY_REDISTRIBUTION_DUSD_A = 10 * _1pct; // 10%

// Branch 4: dBTC (Underlying TBD) — inert, BTC + wrapper/depeg model
uint256 constant MCR_DBTC = 11955 * _1pct / 100; // 119.55%
uint256 constant CCR_DBTC = 13082 * _1pct / 100; // 130.82%
uint256 constant SCR_DBTC = 110 * _1pct; // 110%
uint256 constant BCR_DBTC = 10 * _1pct; // 10%
uint256 constant LIQUIDATION_PENALTY_SP_DBTC = 5 * _1pct; // 5%
uint256 constant LIQUIDATION_PENALTY_REDISTRIBUTION_DBTC = 10 * _1pct; // 10%

// Branch 5: dUSD-B (Underlying TBD) — inert, structured-stable 120% floor
uint256 constant MCR_DUSD_B = 120 * _1pct; // 120.00%
uint256 constant CCR_DUSD_B = 13765 * _1pct / 100; // 137.65%
uint256 constant SCR_DUSD_B = 105 * _1pct; // 105%
uint256 constant BCR_DUSD_B = 10 * _1pct; // 10%
uint256 constant LIQUIDATION_PENALTY_SP_DUSD_B = 5 * _1pct; // 5%
uint256 constant LIQUIDATION_PENALTY_REDISTRIBUTION_DUSD_B = 10 * _1pct; // 10%

// Branch 6: dJPY (Underlying TBD) — inert, JPY/JGB low-volatility model
uint256 constant MCR_DJPY = 10530 * _1pct / 100; // 105.30%
uint256 constant CCR_DJPY = 10730 * _1pct / 100; // 107.30%
uint256 constant SCR_DJPY = 10330 * _1pct / 100; // 103.30%
uint256 constant BCR_DJPY = 5 * _1pct; // 5%
uint256 constant LIQUIDATION_PENALTY_SP_DJPY = 5 * _1pct; // 5%
uint256 constant LIQUIDATION_PENALTY_REDISTRIBUTION_DJPY = 5 * _1pct; // 5%

// Branch 7: dJGB (Underlying TBD) — inert, JPY/JGB low-volatility model
uint256 constant MCR_DJGB = 10530 * _1pct / 100; // 105.30%
uint256 constant CCR_DJGB = 10730 * _1pct / 100; // 107.30%
uint256 constant SCR_DJGB = 10330 * _1pct / 100; // 103.30%
uint256 constant BCR_DJGB = 5 * _1pct; // 5%
uint256 constant LIQUIDATION_PENALTY_SP_DJGB = 5 * _1pct; // 5%
uint256 constant LIQUIDATION_PENALTY_REDISTRIBUTION_DJGB = 5 * _1pct; // 5%

// Fraction of collateral awarded to liquidator
uint256 constant COLL_GAS_COMPENSATION_DIVISOR = 200; // dividing by 200 yields 0.5%
uint256 constant COLL_GAS_COMPENSATION_CAP = 1_000 ether; // Max coll gas compensation capped at 1,000 coll units

// Minimum entire JPYdf debt a Trove must have, including its upfront fee.
uint256 constant MIN_DEBT = 100_000e18;

uint256 constant MIN_ANNUAL_INTEREST_RATE = _1pct / 2; // 0.5%
uint256 constant MAX_ANNUAL_INTEREST_RATE = 250 * _1pct;

// Batch management params
uint128 constant MAX_ANNUAL_BATCH_MANAGEMENT_FEE = uint128(_100pct / 10); // 10%
uint128 constant MIN_INTEREST_RATE_CHANGE_PERIOD = 1 hours; // only applies to batch managers / batched Troves

uint256 constant REDEMPTION_FEE_FLOOR = _1pct / 2; // 0.5%

// For the debt / shares ratio to increase by a factor 1e9
// at a average annual debt increase (compounded interest + fees) of 10%, it would take more than 217 years (log(1e9)/log(1.1))
// at a average annual debt increase (compounded interest + fees) of 50%, it would take more than 51 years (log(1e9)/log(1.5))
// The increase pace could be forced to be higher through an inflation attack,
// but precisely the fact that we have this max value now prevents the attack
uint256 constant MAX_BATCH_SHARES_RATIO = 1e9;

// Half-life of 6h. 6h = 360 min
// (1/2) = d^360 => d = (1/2)^(1/360)
uint256 constant REDEMPTION_MINUTE_DECAY_FACTOR = 998076443575628800;

// BETA: 18 digit decimal. Parameter by which to divide the redeemed fraction, in order to calc the new base rate from a redemption.
// Corresponds to (1 / ALPHA) in the white paper.
uint256 constant REDEMPTION_BETA = 1;

// To prevent redemptions unless JPYDF depegs below 0.95 and allow the system to take off
uint256 constant INITIAL_BASE_RATE = _100pct; // 100% initial redemption rate

// Discount to be used once the shutdown thas been triggered
uint256 constant URGENT_REDEMPTION_BONUS = 2e16; // 2%

uint256 constant ONE_MINUTE = 1 minutes;
uint256 constant ONE_YEAR = 365 days;
uint256 constant UPFRONT_INTEREST_PERIOD = 7 days;
uint256 constant INTEREST_RATE_ADJ_COOLDOWN = 7 days;

uint256 constant SP_YIELD_SPLIT = 75 * _1pct; // 75%

uint256 constant MIN_JPYDF_IN_SP = 1e18;
