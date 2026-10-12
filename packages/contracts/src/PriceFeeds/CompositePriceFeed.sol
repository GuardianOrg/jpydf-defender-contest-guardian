// SPDX-License-Identifier: MIT

pragma solidity 0.8.24;

import "./MainnetPriceFeedBase.sol";

// Composite feed base for assets valued by a market quote plus a canonical
// exchange rate, e.g. a yield-bearing token's underlying-per-share rate.
// The production tree keeps only the primary -> lastGoodPrice subset required
// by sUSDS. The upstream LST secondary ETHUSDxCanonical fallback was removed
// with the WSTETH/RETH collateral feeds it supported.
abstract contract CompositePriceFeed is MainnetPriceFeedBase {
    address public immutable rateProviderAddress;

    constructor(
        address _ethUsdOracleAddress,
        address _rateProviderAddress,
        uint256 _ethUsdStalenessThreshold,
        address _borrowerOperationsAddress
    ) MainnetPriceFeedBase(_ethUsdOracleAddress, _ethUsdStalenessThreshold, _borrowerOperationsAddress) {
        // Store rate provider
        rateProviderAddress = _rateProviderAddress;
    }

    // Returns:
    // - The price, using the current price calculation
    // - A bool that is true if:
    // --- a) the system was not shut down prior to this call, and
    // --- b) an oracle or exchange rate contract failed during this call.
    function fetchPrice() public returns (uint256, bool) {
        // If branch is live and the primary oracle setup has been working, try to use it
        if (priceSource == PriceSource.primary) return _fetchPricePrimary(false);

        return _fetchPriceDuringShutdown();
    }

    function fetchRedemptionPrice() external returns (uint256, bool) {
        // If branch is live and the primary oracle setup has been working, try to use it
        if (priceSource == PriceSource.primary) return _fetchPricePrimary(true);

        return _fetchPriceDuringShutdown();
    }

    function fetchUrgentRedemptionPrice() public virtual returns (uint256, bool) {
        // Composite feeds without a dedicated wind-down quote use their live normal price,
        // but must not expose the terminal source cache as an urgent settlement quote.
        if (priceSource == PriceSource.primary) return _fetchPricePrimary(false);

        assert(priceSource == PriceSource.lastGoodPrice);
        return (lastGoodPrice, true);
    }

    function _fetchPriceDuringShutdown() internal view returns (uint256, bool) {
        assert(priceSource == PriceSource.lastGoodPrice);
        return (lastGoodPrice, false);
    }

    // An individual Pricefeed instance implements _fetchPricePrimary according to the data sources it uses. Returns:
    // - The price
    // - A bool indicating whether a new oracle failure or exchange rate failure was detected in the call
    function _fetchPricePrimary(bool _isRedemption) internal virtual returns (uint256, bool);

    // Returns the LST exchange rate and a bool indicating whether the exchange rate failed to return a valid rate.
    // Implementation depends on the specific LST.
    function _getCanonicalRate() internal view virtual returns (uint256, bool);
}
