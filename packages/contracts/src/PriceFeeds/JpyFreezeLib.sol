// SPDX-License-Identifier: MIT

pragma solidity 0.8.24;

import "openzeppelin-contracts/contracts/utils/math/Math.sol";

import "../Interfaces/IBorrowerOperations.sol";
import "../Interfaces/IJpyUsdRateProvider.sol";

// CollateralVault view used by every DF feed to read the dToken backing ratio.
interface IBackingRatioSource {
    function backingRatioForPricing() external view returns (uint256 ratio, bool available);
}

/**
 * @title JpyFreezeLib
 * @notice Shared DF layer applied by every JPY-denominated feed after its USD price
 *         is acquired: USD→JPY conversion through the shared soft-freeze provider
 *         (ORCL-SEC-005), the shared-JPY-failure shutdown signalling, and the Vault
 *         backing-ratio adjustment (dToken/JPY = Coll/JPY × min(1, backing)).
 * @dev Internal library: all functions are inlined into the calling feed, so events
 *      are emitted by (and storage belongs to) the feed itself. The error and event
 *      declared here intentionally reuse the exact signatures of
 *      `MainnetPriceFeedBase.InsufficientGasForExternalCall` /
 *      `MainnetPriceFeedBase.ShutDownFromOracleFailure`, so selectors and topics are
 *      indistinguishable from the pre-library feeds.
 *
 *      The shared `JpyUsdRateProvider` remains a separate contract: it owns the
 *      last-good JPY rate, report provenance, freeze timer, recovery, and bounded
 *      expiry, so every branch receives the same rate and expiry decision. This
 *      library only holds the per-feed backing-ratio state and the per-feed glue.
 */
library JpyFreezeLib {
    struct JpyConversionState {
        // Last valid backing ratio, 1e18-scaled and in (0, 1e18]. Kept for monitoring
        // and last-good-price reconstruction only; a live Vault read failure is treated
        // as an oracle failure rather than silently reusing this value.
        uint256 lastGoodBacking;
    }

    // Same signature (selector) as MainnetPriceFeedBase.InsufficientGasForExternalCall.
    error InsufficientGasForExternalCall();

    // Same signature (topic0) as MainnetPriceFeedBase.ShutDownFromOracleFailure.
    event ShutDownFromOracleFailure(address _failedOracleAddr);

    function initialize(JpyConversionState storage self) internal {
        self.lastGoodBacking = 1e18;
    }

    /**
     * @dev USD (18-dec) → JPY (18-dec) using the JPY/USD oracle (USD per JPY), with a
     *      soft-freeze fallback for the shared JPY leg (ORCL-SEC-005). Both operands
     *      are 18-dec normalized (raw 8-dec × 1e10), so the conversion is a single
     *      full-precision multiplication/division:
     *          collJpy = mulDiv(collUsd, 1e18, jpyUsdRate)
     *      Example: ETH=$3,000, JPY/USD=0.006667 →
     *          3000e18 * 1e18 / 6.667e15 ≈ 450,000e18 (= ¥450,000).
     *
     *      The provider owns the last-good rate, report provenance, freeze timer, and
     *      per-outage expiry. Every branch therefore receives the same rate and expiry
     *      decision while that outage remains unhealthy.
     *
     *      Note: the provider preserves the gas-griefing guard. An out-of-gas Chainlink
     *      read reverts with `InsufficientGasForExternalCall` rather than being silently
     *      treated as a freeze.
     */
    function convertUsdPriceToJpyWithFreeze(IJpyUsdRateProvider _jpyUsdRateProvider, uint256 _usdPrice)
        internal
        returns (uint256, bool)
    {
        (uint256 jpyUsdRate, bool jpyFreezeExpired) = _jpyUsdRateProvider.fetchJpyUsdRate();
        if (jpyFreezeExpired) return (0, true);
        return (Math.mulDiv(_usdPrice, 1e18, jpyUsdRate), false);
    }

    /// @dev The provider latches shared expiry for the current unhealthy episode before this
    ///      call. Catch a source-level
    ///      BorrowerOperations authorization failure so the enclosing PriceFeedProxy call
    ///      does not roll that provider mutation back. The source returns failure=true and stays
    ///      on its primary path so recovery remains observable; the registered proxy performs
    ///      temporary shutdown and later validates the recovered source before resuming.
    function shutDownFromSharedJpyFailure(
        IBorrowerOperations _borrowerOperations,
        IJpyUsdRateProvider _jpyUsdRateProvider
    ) internal returns (bool signalledDirectly) {
        try _borrowerOperations.shutdownFromOracleFailure() {
            signalledDirectly = true;
        } catch {}
        emit ShutDownFromOracleFailure(address(_jpyUsdRateProvider));
    }

    /**
     * @dev Apply the Vault's dToken backing ratio. A normal read failure returns
     *      `backingUnavailable=true` so the caller can enter the standard oracle
     *      shutdown path. Gas-starved calls re-revert with the upstream gas guard
     *      selector so PriceFeedProxy will not misclassify them as oracle failures.
     *      The ratio is lower-bounded to 1 wei when a live Vault returns a measured zero,
     *      because upstream price feed consumers use zero as an invalid-price sentinel. A
     *      complete backing loss is therefore represented as a near-zero price instead of a
     *      stale fail-safe fallback.
     *
     *      The pricing-specific Vault view distinguishes a measured zero from
     *      valuation unavailability. Only the measured zero reaches the 1-wei
     *      floor; unavailability takes the standard oracle-failure path.
     */
    function applyBackingRatio(JpyConversionState storage self, address _collateralVault, uint256 _jpyPrice)
        internal
        returns (uint256, bool)
    {
        uint256 gasBefore = gasleft();

        try IBackingRatioSource(_collateralVault).backingRatioForPricing() returns (
            uint256 liveBacking, bool backingAvailable
        ) {
            if (!backingAvailable) return (0, true);

            if (liveBacking > 1e18) {
                liveBacking = 1e18;
            } else if (liveBacking == 0) {
                // Unchanged: a fully-measured zero still becomes a near-zero price rather than
                // a shutdown, per the original design note above. That is a separate policy
                // question from this fix -- serving collateral at 1e-18 of its value makes the
                // whole book liquidatable, but shutting down instead would quote lastGoodPrice
                // over collateral that is genuinely gone. Only the *unavailable* case is
                // changed here, because that one is not a measurement at all.
                liveBacking = 1;
            }

            self.lastGoodBacking = liveBacking;
            return (Math.mulDiv(_jpyPrice, liveBacking, 1e18), false);
        } catch (bytes memory err) {
            // The Vault reverts with the same gas-guard error when the caller cannot fund the
            // fixed Strategy probe budget (Guardian Remediation L-01). Bubble it unchanged so a
            // gas-starved call is never classified as an oracle failure.
            if (err.length == 4 && bytes4(err) == InsufficientGasForExternalCall.selector) {
                revert InsufficientGasForExternalCall();
            }
            if (gasleft() <= gasBefore / 64) revert InsufficientGasForExternalCall();
            return (0, true);
        }
    }
}
