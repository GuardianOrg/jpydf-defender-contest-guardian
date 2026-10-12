// SPDX-License-Identifier: MIT

pragma solidity 0.8.24;

import "../../Dependencies/AggregatorV3Interface.sol";
import "../../Dependencies/LiquityMath.sol";
import "openzeppelin-contracts/contracts/utils/math/Math.sol";

import "../DFPriceFeedBase.sol";

/**
 * @title DFWBTCPriceFeed
 * @notice Peg-monitored JPY price feed for WBTC collateral:
 *         WBTC/BTC (Chainlink) × BTC/USD (Chainlink) → JPY.
 * @dev New DF file. It reuses the upstream-derived price-feed base; the base
 *      diff is limited to the documented Chainlink response-validation hardening.
 *      This feed only inserts the WBTC/BTC peg monitor before the shared DF
 *      JPY/backing layers.
 *      Mainnet WBTC/BTC: 0xfdFD9C85aD200c506Cf9e21F1FD8dd01932FBB23.
 *      Mainnet BTC/USD: 0xF4030086522a5bEEa4988F8cA5B36dbC97BeE88c.
 */
contract DFWBTCPriceFeed is DFPriceFeedBase {
    Oracle public wbtcBtcOracle;
    uint256 public constant WBTC_BTC_DEVIATION_THRESHOLD = 2e16; // 2%

    constructor(
        address _wbtcBtcOracleAddress,
        uint256 _wbtcBtcStalenessThreshold,
        address _btcUsdOracleAddress,
        uint256 _btcUsdStalenessThreshold,
        address _jpyUsdRateProviderAddress,
        address _collateralVaultAddress,
        address _borrowerOperationsAddress
    )
        DFPriceFeedBase(
            _btcUsdOracleAddress,
            _btcUsdStalenessThreshold,
            _jpyUsdRateProviderAddress,
            _collateralVaultAddress,
            _borrowerOperationsAddress
        )
    {
        wbtcBtcOracle.aggregator = AggregatorV3Interface(_wbtcBtcOracleAddress);
        wbtcBtcOracle.stalenessThreshold = _wbtcBtcStalenessThreshold;
        wbtcBtcOracle.decimals = wbtcBtcOracle.aggregator.decimals();

        assert(wbtcBtcOracle.decimals == 8);

        _fetchPricePrimary();
        assert(priceSource == PriceSource.primary);
    }

    function fetchRedemptionPrice() external override returns (uint256, bool) {
        if (priceSource == PriceSource.primary) return _fetchWbtcPricePrimary(true);

        assert(priceSource == PriceSource.lastGoodPrice);
        return (lastGoodPrice, false);
    }

    function _fetchPricePrimary() internal override returns (uint256, bool) {
        return _fetchWbtcPricePrimary(false);
    }

    function _fetchWbtcPricePrimary(bool _isRedemption) internal returns (uint256, bool) {
        assert(priceSource == PriceSource.primary);

        (uint256 wbtcBtcPrice, bool wbtcBtcOracleDown) = _getOracleAnswer(wbtcBtcOracle);
        if (wbtcBtcOracleDown) {
            return (_shutDownAndSwitchToLastGoodPrice(address(wbtcBtcOracle.aggregator)), true);
        }

        (uint256 btcUsdPrice, bool btcUsdOracleDown) = _getOracleAnswer(ethUsdOracle);
        if (btcUsdOracleDown) {
            return (_shutDownAndSwitchToLastGoodPrice(address(ethUsdOracle.aggregator)), true);
        }

        uint256 wbtcUsdMarketPrice = Math.mulDiv(wbtcBtcPrice, btcUsdPrice, 1e18);
        uint256 wbtcUsdCanonicalPrice = btcUsdPrice;

        uint256 wbtcUsdPrice;
        if (
            _isRedemption
                && _withinDeviationThreshold(wbtcUsdMarketPrice, wbtcUsdCanonicalPrice, WBTC_BTC_DEVIATION_THRESHOLD)
        ) {
            // For redemptions, use the worse price for redeemers when the wrapper
            // peg monitor and canonical BTC price are close enough to be oracle lag
            // rather than a real WBTC depeg.
            wbtcUsdPrice = LiquityMath._max(wbtcUsdMarketPrice, wbtcUsdCanonicalPrice);
        } else {
            // For normal borrowing/liquidation pricing, cap WBTC at canonical BTC
            // and immediately reflect real depegs through the WBTC/BTC market leg.
            wbtcUsdPrice = LiquityMath._min(wbtcUsdMarketPrice, wbtcUsdCanonicalPrice);
        }

        (uint256 wbtcJpyPrice, bool jpyFreezeExpired) = _convertUsdPriceToJpyWithFreeze(wbtcUsdPrice);
        if (jpyFreezeExpired) {
            return (_shutDownFromSharedJpyFailure(), true);
        }

        (uint256 dTokenJpyPrice, bool backingUnavailable) = _applyBackingRatio(wbtcJpyPrice);
        if (backingUnavailable) {
            return (_shutDownAndSwitchToLastGoodPrice(collateralVault), true);
        }

        lastGoodPrice = dTokenJpyPrice;
        return (dTokenJpyPrice, false);
    }

    function _withinDeviationThreshold(uint256 _priceToCheck, uint256 _referencePrice, uint256 _deviationThreshold)
        internal
        pure
        returns (bool)
    {
        uint256 max = Math.mulDiv(_referencePrice, DECIMAL_PRECISION + _deviationThreshold, 1e18);
        uint256 min = Math.mulDiv(_referencePrice, DECIMAL_PRECISION - _deviationThreshold, 1e18);
        return _priceToCheck >= min && _priceToCheck <= max;
    }
}
