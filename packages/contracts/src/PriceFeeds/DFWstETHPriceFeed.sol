// SPDX-License-Identifier: MIT

pragma solidity 0.8.24;

import "openzeppelin-contracts/contracts/utils/math/Math.sol";

import "../Interfaces/IJpyUsdRateProvider.sol";
import "./CompositePriceFeed.sol";
import "./JpyFreezeLib.sol";

// Minimal wstETH view used as the rate provider. stEthPerToken() returns the
// stETH amount (18-dec) backing 1 wstETH -- the canonical rate.
interface IWstETHRate {
    function stEthPerToken() external view returns (uint256);
    function decimals() external view returns (uint8);
}

/**
 * @title DFWstETHPriceFeed
 * @notice Composite-rate JPY price feed for wstETH (wrapped staked ETH) collateral.
 * @dev Inherits the pruned `CompositePriceFeed` canonical-rate base (the same base
 *      as the composite-feed family) and computes:
 *          wstETH/USD = (stETH/USD, Chainlink) × (stETH per wstETH, canonical rate)
 *          wstETH/JPY = wstETH/USD / (JPY/USD)
 *          dToken/JPY = wstETH/JPY × min(1, Vault backing)
 *      The canonical rate is read from the wstETH token itself
 *      (stEthPerToken()), not Chainlink — so it has no staleness. A canonical-rate
 *      read failure (revert or zero) at fetch time is treated as an oracle failure,
 *      the same policy as sUSDS's convertToAssets failure. Because the math treats
 *      the rate as an 18-decimal value, deployment rejects a rate provider unless
 *      the wstETH token reports 18 decimals and a nonzero rate.
 *
 *      The JPY rate and freeze state come from the same shared provider as every
 *      standard DF feed. This avoids branch-local rate and timer divergence. The
 *      JPY-conversion / freeze / backing logic is the shared `JpyFreezeLib`; only
 *      its state lives here, because this feed inherits CompositePriceFeed rather
 *      than DFPriceFeedBase.
 *      `CompositePriceFeed` is intentionally limited to the primary ->
 *      lastGoodPrice path; the unused upstream LST ETHUSDxCanonical fallback was
 *      removed with the upstream WSTETH/RETH feeds. The `MainnetPriceFeedBase`
 *      diff is limited to Chainlink response-validation hardening, and the extra
 *      JPY/backing logic lives only in DF files.
 *
 *      Mainnet: stETH/USD `0xCfE54B5cD566aB89272946F602D76Ea879CAb4a8`,
 *      wstETH (rate provider) `0x7f39C581F595B53c5cb19bD0b3f8dA6c935E2Ca0`.
 */
contract DFWstETHPriceFeed is CompositePriceFeed {
    using JpyFreezeLib for JpyFreezeLib.JpyConversionState;

    error InvalidCollateralVault();
    error InvalidInitialPrice();
    error InvalidRateProvider();
    error InvalidRateProviderDecimals();
    error InvalidRateProviderRate();
    error InvalidJpyUsdRateProvider();

    IJpyUsdRateProvider public immutable jpyUsdRateProvider;

    address public immutable collateralVault;
    // Backing-ratio state operated on by JpyFreezeLib (see its field docs).
    JpyFreezeLib.JpyConversionState internal jpyConversionState;

    constructor(
        address _stEthUsdOracleAddress,
        address _wstEthAddress,
        uint256 _stEthUsdStalenessThreshold,
        address _jpyUsdRateProviderAddress,
        address _collateralVaultAddress,
        address _borrowerOperationsAddress
    )
        CompositePriceFeed(
            _stEthUsdOracleAddress, _wstEthAddress, _stEthUsdStalenessThreshold, _borrowerOperationsAddress
        )
    {
        _validateRateProvider(_wstEthAddress);

        if (_collateralVaultAddress.code.length == 0) revert InvalidCollateralVault();
        collateralVault = _collateralVaultAddress;
        jpyConversionState.initialize();

        if (_jpyUsdRateProviderAddress.code.length == 0) revert InvalidJpyUsdRateProvider();
        jpyUsdRateProvider = IJpyUsdRateProvider(_jpyUsdRateProviderAddress);

        // Fetch an initial price and confirm the oracle setup is live at deploy time.
        _fetchPricePrimary(false);
        if (priceSource != PriceSource.primary || lastGoodPrice == 0) revert InvalidInitialPrice();
    }

    function _validateRateProvider(address _wstEthAddress) private view {
        if (_wstEthAddress.code.length == 0) revert InvalidRateProvider();
        if (IWstETHRate(_wstEthAddress).decimals() != 18) revert InvalidRateProviderDecimals();
        if (IWstETHRate(_wstEthAddress).stEthPerToken() == 0) revert InvalidRateProviderRate();
    }

    /**
     * @dev Primary path. `ethUsdOracle` is the upstream slot reused as stETH/USD.
     *      wstETH has only this single USD source (no separate market feed), so any
     *      failure switches straight to lastGoodPrice. Redemption uses the same
     *      price as all other ops because there is no market-vs-canonical
     *      divergence to arbitrage.
     */
    function _fetchPricePrimary(bool) internal override returns (uint256, bool) {
        assert(priceSource == PriceSource.primary);

        // stETH/USD (18-dec normalized).
        (uint256 stEthUsdPrice, bool stEthUsdOracleDown) = _getOracleAnswer(ethUsdOracle);
        if (stEthUsdOracleDown) {
            return (_shutDownAndSwitchToLastGoodPrice(address(ethUsdOracle.aggregator)), true);
        }

        // stETH per wstETH (canonical rate, 18-dec).
        (uint256 stEthPerWstEth, bool rateIsDown) = _getCanonicalRate();
        if (rateIsDown) {
            return (_shutDownAndSwitchToLastGoodPrice(rateProviderAddress), true);
        }

        // wstETH/USD = stETH/USD × (stETH per wstETH); both 18-dec, so divide by 1e18.
        uint256 wstEthUsdPrice = Math.mulDiv(stEthUsdPrice, stEthPerWstEth, 1e18);

        // SHARED JPY/USD leg: a JPY-leg failure must NOT terminally shut the branch down
        // (that would make the shared FX dependency a single point of total failure across
        // all branches). Substitute the last good JPY rate and keep operating; the stETH/USD
        // and canonical legs above are still live, so the price tracks them and only the
        // (low-vol) FX leg is frozen. Auto-resumes when JPY/USD is fresh again; a prolonged
        // freeze escalates to normal branch shutdown so the feed never serves arbitrarily
        // stale FX (ORCL-SEC-005).
        (uint256 wstEthJpyPrice, bool jpyFreezeExpired) =
            JpyFreezeLib.convertUsdPriceToJpyWithFreeze(jpyUsdRateProvider, wstEthUsdPrice);
        if (jpyFreezeExpired) {
            return (_shutDownFromSharedJpyFailure(), true);
        }

        (uint256 dTokenJpyPrice, bool backingUnavailable) =
            jpyConversionState.applyBackingRatio(collateralVault, wstEthJpyPrice);
        if (backingUnavailable) {
            return (_shutDownAndSwitchToLastGoodPrice(collateralVault), true);
        }

        lastGoodPrice = dTokenJpyPrice;
        return (dTokenJpyPrice, false);
    }

    /**
     * @dev Canonical rate = stETH per wstETH via the wstETH token contract.
     *      Mirrors the upstream canonical-rate gas-griefing guard: on OOG, revert
     *      `InsufficientGasForExternalCall` instead of triggering a false shutdown.
     */
    function _getCanonicalRate() internal view override returns (uint256, bool) {
        uint256 gasBefore = gasleft();

        try IWstETHRate(rateProviderAddress).stEthPerToken() returns (uint256 stEthPerWstEth) {
            if (stEthPerWstEth == 0) return (0, true);
            return (stEthPerWstEth, false);
        } catch {
            if (gasleft() <= gasBefore / 64) revert InsufficientGasForExternalCall();
            return (0, true);
        }
    }

    /// @dev Last valid backing ratio (see JpyFreezeLib.JpyConversionState.lastGoodBacking).
    function lastGoodBacking() public view returns (uint256) {
        return jpyConversionState.lastGoodBacking;
    }

    /// @dev Shared-JPY-failure shutdown; see `JpyFreezeLib.shutDownFromSharedJpyFailure`.
    function _shutDownFromSharedJpyFailure() internal returns (uint256) {
        // Latch the terminal source state only when the branch was actually shut down. Staying
        // on `primary` is safe: while the oracle remains unhealthy, the provider re-reports
        // failure=true until the registered caller acts on it. A later fresh response starts a
        // new provider episode, but cannot reactivate a branch that already latched shutdown.
        // See test/JpySharedShutdownLatch.t.sol.
        if (JpyFreezeLib.shutDownFromSharedJpyFailure(borrowerOperations, jpyUsdRateProvider)) {
            priceSource = PriceSource.lastGoodPrice;
        }
        return lastGoodPrice;
    }
}
