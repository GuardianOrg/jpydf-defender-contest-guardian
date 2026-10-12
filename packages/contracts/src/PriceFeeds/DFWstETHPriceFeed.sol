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
 *      Redemptions additionally derive a market-sensitive stETH/USD reference as
 *      ETH/USD x stETH/ETH, then use max(direct stETH/USD, derived stETH/USD).
 *      This closes the direct-feed update lag without pricing a genuine stETH depeg
 *      at par with ETH. Normal redemption fails closed if either reference feed is
 *      unavailable. Urgent redemption after irreversible shutdown also fails closed:
 *      wind-down never settles against a direct-only or cached quote.
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

    event RedemptionReferenceUnavailable(address indexed oracle, uint256 stEthUsdPrice);
    event UrgentRedemptionReferenceUnavailable(address indexed oracle, uint256 stEthUsdPrice);

    enum PriceUse {
        Normal,
        Redemption,
        UrgentRedemption
    }

    IJpyUsdRateProvider public immutable jpyUsdRateProvider;

    Oracle public redemptionEthUsdOracle;
    Oracle public redemptionStEthEthOracle;

    address public immutable collateralVault;
    // Backing-ratio state operated on by JpyFreezeLib (see its field docs).
    JpyFreezeLib.JpyConversionState internal jpyConversionState;

    constructor(
        address _stEthUsdOracleAddress,
        address _redemptionEthUsdOracleAddress,
        address _redemptionStEthEthOracleAddress,
        address _wstEthAddress,
        uint256 _stEthUsdStalenessThreshold,
        uint256 _redemptionEthUsdStalenessThreshold,
        uint256 _redemptionStEthEthStalenessThreshold,
        address _jpyUsdRateProviderAddress,
        address _collateralVaultAddress,
        address _borrowerOperationsAddress
    )
        CompositePriceFeed(
            _stEthUsdOracleAddress, _wstEthAddress, _stEthUsdStalenessThreshold, _borrowerOperationsAddress
        )
    {
        redemptionEthUsdOracle.aggregator = AggregatorV3Interface(_redemptionEthUsdOracleAddress);
        redemptionEthUsdOracle.stalenessThreshold = _redemptionEthUsdStalenessThreshold;
        redemptionEthUsdOracle.decimals = redemptionEthUsdOracle.aggregator.decimals();
        assert(redemptionEthUsdOracle.decimals == 8);

        redemptionStEthEthOracle.aggregator = AggregatorV3Interface(_redemptionStEthEthOracleAddress);
        redemptionStEthEthOracle.stalenessThreshold = _redemptionStEthEthStalenessThreshold;
        redemptionStEthEthOracle.decimals = redemptionStEthEthOracle.aggregator.decimals();
        assert(redemptionStEthEthOracle.decimals == 18);

        _validateRateProvider(_wstEthAddress);

        if (_collateralVaultAddress.code.length == 0) revert InvalidCollateralVault();
        collateralVault = _collateralVaultAddress;
        jpyConversionState.initialize();

        if (_jpyUsdRateProviderAddress.code.length == 0) revert InvalidJpyUsdRateProvider();
        jpyUsdRateProvider = IJpyUsdRateProvider(_jpyUsdRateProviderAddress);

        // Fetch an initial price and confirm the oracle setup is live at deploy time.
        _fetchPricePrimary(false);
        if (priceSource != PriceSource.primary || lastGoodPrice == 0) revert InvalidInitialPrice();

        (, bool redemptionEthUsdOracleDown) = _getOracleAnswer(redemptionEthUsdOracle);
        if (redemptionEthUsdOracleDown) revert InvalidInitialPrice();
        (, bool redemptionStEthEthOracleDown) = _getOracleAnswer(redemptionStEthEthOracle);
        if (redemptionStEthEthOracleDown) revert InvalidInitialPrice();
    }

    function _validateRateProvider(address _wstEthAddress) private view {
        if (_wstEthAddress.code.length == 0) revert InvalidRateProvider();
        if (IWstETHRate(_wstEthAddress).decimals() != 18) revert InvalidRateProviderDecimals();
        if (IWstETHRate(_wstEthAddress).stEthPerToken() == 0) revert InvalidRateProviderRate();
    }

    /**
     * @dev Primary path. `ethUsdOracle` is the upstream slot reused as stETH/USD.
     *      Normal pricing uses stETH/USD. Redemption uses the higher of direct
     *      stETH/USD and ETH/USD x stETH/ETH. An unavailable reference
     *      fails the redemption quote closed so the normal stETH/USD quote can never
     *      silently reopen the oracle-lag arbitrage.
     */
    function _fetchPricePrimary(bool _isRedemption) internal override returns (uint256, bool) {
        return _fetchPricePrimaryFor(_isRedemption ? PriceUse.Redemption : PriceUse.Normal);
    }

    function fetchUrgentRedemptionPrice() public override returns (uint256, bool) {
        if (priceSource == PriceSource.primary) return _fetchPricePrimaryFor(PriceUse.UrgentRedemption);

        assert(priceSource == PriceSource.lastGoodPrice);
        return (lastGoodPrice, true);
    }

    function _fetchPricePrimaryFor(PriceUse _priceUse) internal returns (uint256, bool) {
        assert(priceSource == PriceSource.primary);

        // stETH/USD (18-dec normalized).
        (uint256 stEthUsdPrice, bool stEthUsdOracleDown) = _getOracleAnswer(ethUsdOracle);
        if (stEthUsdOracleDown) {
            return (_shutDownAndReturnLastGoodPrice(address(ethUsdOracle.aggregator)), true);
        }

        // stETH per wstETH (canonical rate, 18-dec).
        (uint256 stEthPerWstEth, bool rateIsDown) = _getCanonicalRate();
        if (rateIsDown) {
            return (_shutDownAndReturnLastGoodPrice(rateProviderAddress), true);
        }

        uint256 usdPrice = stEthUsdPrice;
        if (_priceUse != PriceUse.Normal) {
            (uint256 redemptionReference, bool referenceDown, address failedOracle) = _getRedemptionReference();
            if (referenceDown && _priceUse == PriceUse.Redemption) {
                emit RedemptionReferenceUnavailable(failedOracle, stEthUsdPrice);
                // The production caller is PriceFeedProxy, so a direct source -> BO pause call
                // fails BO's caller check. Absorb that expected topology mismatch so this
                // dedicated alert survives and return failure=true for the registered Proxy to
                // latch the pause. A directly registered test/source still signals BO here.
                try borrowerOperations.shutdownFromOracleFailure() {} catch {}
                return (lastGoodPrice, true);
            } else if (referenceDown) {
                emit UrgentRedemptionReferenceUnavailable(failedOracle, stEthUsdPrice);
                return (lastGoodPrice, true);
            } else if (redemptionReference > usdPrice) {
                usdPrice = redemptionReference;
            }
        }

        // wstETH/USD = selected USD price × (stETH per wstETH); both 18-dec.
        uint256 wstEthUsdPrice = Math.mulDiv(usdPrice, stEthPerWstEth, 1e18);

        // SHARED JPY/USD leg: a JPY-leg failure must not synchronously stop every branch.
        // Substitute the last good JPY rate and keep operating; the stETH/USD
        // and canonical legs above are still live, so the price tracks them and only the
        // (low-vol) FX leg is frozen. Auto-resumes when JPY/USD is fresh again; a prolonged
        // freeze escalates to recoverable oracle shutdown so the feed never serves arbitrarily
        // stale FX (ORCL-SEC-005).
        (uint256 wstEthJpyPrice, bool jpyFreezeExpired) =
            JpyFreezeLib.convertUsdPriceToJpyWithFreeze(jpyUsdRateProvider, wstEthUsdPrice);
        if (jpyFreezeExpired) {
            return (_shutDownFromSharedJpyFailure(), true);
        }

        (uint256 dTokenJpyPrice, bool backingUnavailable) =
            jpyConversionState.applyBackingRatio(collateralVault, wstEthJpyPrice);
        if (backingUnavailable) {
            return (_shutDownAndReturnLastGoodPrice(collateralVault), true);
        }

        // `lastGoodPrice` belongs to the normal borrow/liquidation path. The
        // enclosing PriceFeedProxy maintains a distinct redemption cache, so a
        // borrower-protective redemption quote must never contaminate this source
        // cache and later overvalue collateral during a normal-source failure.
        if (_priceUse == PriceUse.Normal) lastGoodPrice = dTokenJpyPrice;
        return (dTokenJpyPrice, false);
    }

    function _getRedemptionReference() internal view returns (uint256, bool, address) {
        (uint256 ethUsdPrice, bool ethUsdOracleDown) = _getOracleAnswer(redemptionEthUsdOracle);
        if (ethUsdOracleDown) return (0, true, address(redemptionEthUsdOracle.aggregator));

        (uint256 stEthEthPrice, bool stEthEthOracleDown) = _getOracleAnswer(redemptionStEthEthOracle);
        if (stEthEthOracleDown) return (0, true, address(redemptionStEthEthOracle.aggregator));

        return (Math.mulDiv(ethUsdPrice, stEthEthPrice, 1e18), false, address(0));
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
        JpyFreezeLib.shutDownFromSharedJpyFailure(borrowerOperations, jpyUsdRateProvider);
        return lastGoodPrice;
    }
}
