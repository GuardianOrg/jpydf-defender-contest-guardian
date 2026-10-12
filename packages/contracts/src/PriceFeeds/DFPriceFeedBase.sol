// SPDX-License-Identifier: MIT

pragma solidity 0.8.24;

import "../Interfaces/IJpyUsdRateProvider.sol";
import "./JpyFreezeLib.sol";
import "./MainnetPriceFeedBase.sol";

/**
 * @title DFPriceFeedBase
 * @notice DeltaForesight base for "Standard" JPY-denominated price feeds.
 * @dev Inherits the upstream-derived `MainnetPriceFeedBase` (its USD price
 *      machinery — Chainlink fetch, 18-decimal scaling, gas-griefing guard,
 *      `PriceSource` state, `lastGoodPrice`, temporary shutdown — remains the shared
 *      acquisition path, with the documented Chainlink response-validation hardening)
 *      and adds, in this NEW file only:
 *        - a shared JPY/USD rate provider (`jpyUsdRateProvider`), and
 *        - a USD→JPY conversion using its global soft-freeze state
 *          (`_convertUsdPriceToJpyWithFreeze`; see ORCL-SEC-005), and
 *        - a Vault backing-ratio layer for dToken collateral valuation.
 *      The JPY-conversion / freeze / backing logic itself lives in the shared
 *      `JpyFreezeLib`; this base only holds the state and wires it in.
 *      The collateral/USD oracle is the upstream `ethUsdOracle` slot reused as
 *      "collateral/USD"; the inherited slot/API names are intentionally kept
 *      unchanged. Derivation: Collateral/JPY = (Collateral/USD) / (JPY/USD).
 *      dToken/JPY = Collateral/JPY × min(1, Vault backing).
 *
 *      Concrete Standard feeds (WETH/USDC/USDT/XAUT-Day1) inherit this base and only
 *      supply the constructor args; the `_fetchPricePrimary` logic is shared here.
 */
abstract contract DFPriceFeedBase is MainnetPriceFeedBase {
    using JpyFreezeLib for JpyFreezeLib.JpyConversionState;

    error InvalidCollateralVault();
    error InvalidInitialPrice();
    error InvalidJpyUsdRateProvider();

    // All branch feeds point to the same provider contract, so the cached JPY rate,
    // freeze onset, recovery, and bounded expiration cannot diverge per branch.
    IJpyUsdRateProvider public immutable jpyUsdRateProvider;

    // CollateralVault that accounts for dToken backing. The price feed only reads
    // this value; repair/accounting remains Vault-side.
    address public immutable collateralVault;

    // Backing-ratio state operated on by JpyFreezeLib (see its field docs).
    JpyFreezeLib.JpyConversionState internal jpyConversionState;

    constructor(
        address _collUsdOracleAddress,
        uint256 _collUsdStalenessThreshold,
        address _jpyUsdRateProviderAddress,
        address _collateralVaultAddress,
        address _borrowerOperationsAddress
    ) MainnetPriceFeedBase(_collUsdOracleAddress, _collUsdStalenessThreshold, _borrowerOperationsAddress) {
        if (_collateralVaultAddress.code.length == 0) revert InvalidCollateralVault();
        collateralVault = _collateralVaultAddress;
        jpyConversionState.initialize();

        if (_jpyUsdRateProviderAddress.code.length == 0) revert InvalidJpyUsdRateProvider();
        jpyUsdRateProvider = IJpyUsdRateProvider(_jpyUsdRateProviderAddress);

        // Fetch an initial price and confirm the oracle setup is live at deploy time.
        _fetchStandardPricePrimary();
        if (priceSource != PriceSource.primary || lastGoodPrice == 0) revert InvalidInitialPrice();
    }

    function fetchPrice() public returns (uint256, bool) {
        // Oracle shutdown is recoverable, so keep probing the primary source. Before validated
        // resume, the registered PriceFeedProxy still gates normal redemption and risk increases.
        if (priceSource == PriceSource.primary) return _fetchPricePrimary();

        // Retained for compatibility with a source deployed in the legacy terminal state.
        assert(priceSource == PriceSource.lastGoodPrice);
        return (lastGoodPrice, false);
    }

    function fetchRedemptionPrice() external virtual returns (uint256, bool) {
        // Standard feeds use the same price for redemption as for all other ops.
        return fetchPrice();
    }

    function fetchUrgentRedemptionPrice() external virtual returns (uint256, bool) {
        // Standard feeds use their live normal quote, but never the terminal source cache,
        // for urgent settlement.
        if (priceSource == PriceSource.primary) return _fetchPricePrimary();

        assert(priceSource == PriceSource.lastGoodPrice);
        return (lastGoodPrice, true);
    }

    /**
     * @dev Standard primary path: collateral/USD (upstream Chainlink machinery) →
     *      collateral/JPY (DF conversion) → backing-adjusted dToken/JPY.
     *      Returns (price, newOracleFailureDetected).
     *      Collateral/USD failure temporarily shuts down the branch and returns lastGoodPrice.
     *      JPY/USD failure soft-freezes on lastGoodJpyRate for a bounded period;
     *      if the freeze exceeds MAX_JPY_FREEZE_DURATION, the branch shuts down
     *      and signals newOracleFailureDetected.
     */
    function _fetchPricePrimary() internal virtual returns (uint256, bool) {
        return _fetchStandardPricePrimary();
    }

    function _fetchStandardPricePrimary() internal returns (uint256, bool) {
        assert(priceSource == PriceSource.primary);

        // Collateral/USD (18-dec normalized). `ethUsdOracle` is the upstream slot
        // reused as the collateral/USD aggregator.
        (uint256 collUsdPrice, bool collUsdOracleDown) = _getOracleAnswer(ethUsdOracle);
        if (collUsdOracleDown) {
            return (_shutDownAndReturnLastGoodPrice(address(ethUsdOracle.aggregator)), true);
        }

        // JPY/USD is a SHARED systemic leg used by EVERY branch's conversion. Unlike the
        // per-branch collateral/USD oracle above, a JPY-leg failure must not synchronously stop
        // every branch. Instead the feed substitutes the last good JPY rate and keeps operating.
        // The collateral/USD leg is still live here, so the price continues to track the
        // (high-volatility) collateral; only the (low-volatility) FX leg is frozen. The branch
        // auto-resumes the live rate as soon as JPY/USD is fresh again. If the outage outlives
        // the bounded freeze window, enter recoverable oracle shutdown so the feed
        // never serves an arbitrarily stale FX rate (Oracle.md ORCL-SEC-005).
        (uint256 collJpyPrice, bool jpyFreezeExpired) = _convertUsdPriceToJpyWithFreeze(collUsdPrice);
        if (jpyFreezeExpired) {
            return (_shutDownFromSharedJpyFailure(), true);
        }

        (uint256 dTokenJpyPrice, bool backingUnavailable) = _applyBackingRatio(collJpyPrice);
        if (backingUnavailable) {
            return (_shutDownAndReturnLastGoodPrice(collateralVault), true);
        }

        lastGoodPrice = dTokenJpyPrice;
        return (dTokenJpyPrice, false);
    }

    /// @dev Last valid backing ratio (see JpyFreezeLib.JpyConversionState.lastGoodBacking).
    function lastGoodBacking() public view returns (uint256) {
        return jpyConversionState.lastGoodBacking;
    }

    /// @dev USD→JPY conversion through the shared provider; see
    ///      `JpyFreezeLib.convertUsdPriceToJpyWithFreeze` for the math and freeze policy.
    function _convertUsdPriceToJpyWithFreeze(uint256 _usdPrice) internal returns (uint256, bool) {
        return JpyFreezeLib.convertUsdPriceToJpyWithFreeze(jpyUsdRateProvider, _usdPrice);
    }

    /// @dev Shared-JPY-failure shutdown; see `JpyFreezeLib.shutDownFromSharedJpyFailure`.
    function _shutDownFromSharedJpyFailure() internal returns (uint256) {
        JpyFreezeLib.shutDownFromSharedJpyFailure(borrowerOperations, jpyUsdRateProvider);
        return lastGoodPrice;
    }

    /// @dev Vault backing-ratio adjustment; see `JpyFreezeLib.applyBackingRatio`.
    function _applyBackingRatio(uint256 _jpyPrice) internal returns (uint256, bool) {
        return jpyConversionState.applyBackingRatio(collateralVault, _jpyPrice);
    }
}
