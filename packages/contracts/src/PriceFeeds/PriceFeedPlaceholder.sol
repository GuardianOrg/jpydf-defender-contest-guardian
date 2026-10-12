// SPDX-License-Identifier: MIT

pragma solidity 0.8.24;

import "../Interfaces/IPriceFeed.sol";

/**
 * @title PriceFeedPlaceholder
 * @notice Inert price feed used as the Day-1 `source` of a `PriceFeedProxy` for a placeholder
 *         (deferred-underlying) branch (placeholder branches), before the real collateral is chosen.
 *
 * @dev Why a dedicated stub instead of `address(0)` / an EOA:
 *      `CollateralRegistry.redeemCollateral` scans EVERY registered branch and reads its price
 *      via `priceFeed.fetchPrice()` / `fetchRedemptionPrice()` with NO try/catch at the registry
 *      level. So a placeholder branch's feed is read on every redemption, even before activation.
 *      It must therefore:
 *        1. be a deployed contract with code (a non-contract source makes `PriceFeedProxy`'s
 *           try/catch fail to catch and revert the whole redemption — guarded by PR #58); and
 *        2. return a price the proxy considers VALID and never revert, so that
 *           `PriceFeedProxy._handleFailedFetch()` (which calls `shutdownFromOracleFailure()`) is
 *           never reached and the branch is not oracle-paused before Day-2.
 *
 *      `PriceFeedProxy._isInvalidPrice(p)` returns true iff `p == 0 || p == type(uint256).max`.
 *      `SENTINEL_PRICE` (1e18) is neither, so the proxy passes it through cleanly.
 *
 *      At Day-2 activation the real feed replaces this stub via
 *      `PriceFeedProxy.proposeSource(realFeed)` -> (12h timelock) -> `confirmSource()` or
 *      `confirmSourceEmergency()`. A placeholder sentinel to real-price switch usually exceeds
 *      the normal price-jump guard, so the emergency path may be required; it still enforces the
 *      timelock and real-feed smoke tests.
 *      A placeholder branch holds no debt (cap = 0, no Troves), so this sentinel price is never
 *      used for any borrow/liquidation/redemption math; it only keeps the branch non-shutdown.
 */
contract PriceFeedPlaceholder is IPriceFeed {
    /// @notice Fixed sentinel price (1e18). Non-zero and != type(uint256).max, so
    ///         `PriceFeedProxy._isInvalidPrice` does not flag it and no shutdown is triggered.
    uint256 public constant SENTINEL_PRICE = 1e18;

    /// @notice Explicit synthetic JPY provenance for the inert placeholder source.
    /// @dev Placeholder branches cannot be activated by this sentinel quote. Returning self with
    ///      the current timestamp keeps system-wide redemption scans available without making a
    ///      missing provenance getter a fail-open path for real sources.
    function jpyUsdRateProvider() external view returns (address) {
        return address(this);
    }

    function lastGoodJpyUpdatedAt() external view returns (uint256) {
        return block.timestamp;
    }

    /// @inheritdoc IPriceFeed
    function fetchPrice() external pure override returns (uint256, bool) {
        return (SENTINEL_PRICE, false);
    }

    /// @inheritdoc IPriceFeed
    function fetchRedemptionPrice() external pure override returns (uint256, bool) {
        return (SENTINEL_PRICE, false);
    }

    /// @inheritdoc IPriceFeed
    function fetchUrgentRedemptionPrice() external pure override returns (uint256, bool) {
        return (SENTINEL_PRICE, false);
    }

    /// @inheritdoc IPriceFeed
    function lastGoodPrice() external pure override returns (uint256) {
        return SENTINEL_PRICE;
    }
}
