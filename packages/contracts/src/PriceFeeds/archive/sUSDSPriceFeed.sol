// SPDX-License-Identifier: MIT

pragma solidity 0.8.24;

import "openzeppelin-contracts/contracts/utils/math/Math.sol";

import "../../Interfaces/IJpyUsdRateProvider.sol";
import "../CompositePriceFeed.sol";
import "../JpyFreezeLib.sol";

// Minimal ERC-4626 view used as the sUSDS rate provider. convertToAssets(1e18)
// returns the USDS amount (18-dec) backing 1 sUSDS -- the canonical rate.
interface ISUSDS {
    function asset() external view returns (address);
    function decimals() external view returns (uint8);
    function convertToAssets(uint256 shares) external view returns (uint256 assets);
}

interface ISUSDSAsset {
    function decimals() external view returns (uint8);
}

/**
 * @title sUSDSPriceFeed
 * @notice Composite-rate JPY price feed for sUSDS (Savings USDS) collateral.
 * @dev Inherits the pruned `CompositePriceFeed` canonical-rate base used by
 *      the current sUSDS composite feed and computes:
 *          sUSDS/USD = (USDS/USD, Chainlink) × (USDS per sUSDS, canonical rate)
 *          sUSDS/JPY = sUSDS/USD / (JPY/USD)
 *          dToken/JPY = sUSDS/JPY × min(1, Vault backing)
 *      The canonical rate is read from the sUSDS ERC-4626 contract
 *      (convertToAssets(1e18)), not Chainlink — so it has no staleness (Oracle.md §6.3.3).
 *      Because the math treats both shares and assets as 18-decimal values, deployment
 *      rejects a rate provider unless the ERC-4626 token and its asset both report 18
 *      decimals.
 *
 *      The JPY rate and freeze state come from the same shared provider as every
 *      standard DF feed. This avoids branch-local rate and timer divergence. The
 *      JPY-conversion / freeze / backing logic is the shared `JpyFreezeLib`; only
 *      its state lives here, because sUSDS inherits CompositePriceFeed rather
 *      than DFPriceFeedBase.
 *      `CompositePriceFeed` is intentionally limited to the primary ->
 *      lastGoodPrice path required by sUSDS; the unused upstream LST
 *      ETHUSDxCanonical fallback was removed with the WSTETH/RETH feeds. The
 *      `MainnetPriceFeedBase` diff is limited to Chainlink response-validation
 *      hardening, and the extra JPY/backing logic lives only in DF files.
 *
 *      Mainnet: USDS/USD `0xfF30586cD0F29eD462364C7e81375FC0C71219b1`,
 *      sUSDS (rate provider) `0xa3931d71877C0E7a3148CB7Eb4463524FEc27fbD`.
 */
contract sUSDSPriceFeed is CompositePriceFeed {
    using JpyFreezeLib for JpyFreezeLib.JpyConversionState;

    error InvalidCollateralVault();
    error InvalidRateProvider();
    error InvalidRateProviderDecimals();
    error InvalidJpyUsdRateProvider();

    IJpyUsdRateProvider public immutable jpyUsdRateProvider;

    address public immutable collateralVault;
    // Backing-ratio state operated on by JpyFreezeLib (see its field docs).
    JpyFreezeLib.JpyConversionState internal jpyConversionState;

    constructor(
        address _usdsUsdOracleAddress,
        address _susdsAddress,
        uint256 _usdsUsdStalenessThreshold,
        address _jpyUsdRateProviderAddress,
        address _collateralVaultAddress,
        address _borrowerOperationsAddress
    ) CompositePriceFeed(_usdsUsdOracleAddress, _susdsAddress, _usdsUsdStalenessThreshold, _borrowerOperationsAddress) {
        _validateRateProvider(_susdsAddress);

        if (_collateralVaultAddress.code.length == 0) revert InvalidCollateralVault();
        collateralVault = _collateralVaultAddress;
        jpyConversionState.initialize();

        if (_jpyUsdRateProviderAddress.code.length == 0) revert InvalidJpyUsdRateProvider();
        jpyUsdRateProvider = IJpyUsdRateProvider(_jpyUsdRateProviderAddress);

        // Fetch an initial price and confirm the oracle setup is live at deploy time.
        _fetchPricePrimary(false);
        assert(priceSource == PriceSource.primary);
    }

    function _validateRateProvider(address _susdsAddress) private view {
        if (_susdsAddress.code.length == 0) revert InvalidRateProvider();

        address asset = ISUSDS(_susdsAddress).asset();
        if (asset.code.length == 0) revert InvalidRateProvider();

        if (ISUSDS(_susdsAddress).decimals() != 18 || ISUSDSAsset(asset).decimals() != 18) {
            revert InvalidRateProviderDecimals();
        }
    }

    /**
     * @dev Primary path (Oracle.md §6.3.3). `ethUsdOracle` is the upstream slot
     *      reused as USDS/USD. sUSDS has only this single USD source (no separate
     *      market feed), so any failure switches straight to lastGoodPrice.
     *      Redemption uses the same price as all other ops because there is no
     *      market-vs-canonical divergence to arbitrage.
     */
    function _fetchPricePrimary(bool) internal override returns (uint256, bool) {
        assert(priceSource == PriceSource.primary);

        // USDS/USD (18-dec normalized).
        (uint256 usdsUsdPrice, bool usdsUsdOracleDown) = _getOracleAnswer(ethUsdOracle);
        if (usdsUsdOracleDown) {
            return (_shutDownAndSwitchToLastGoodPrice(address(ethUsdOracle.aggregator)), true);
        }

        // USDS per sUSDS (canonical rate, 18-dec).
        (uint256 usdsPerSusds, bool rateIsDown) = _getCanonicalRate();
        if (rateIsDown) {
            return (_shutDownAndSwitchToLastGoodPrice(rateProviderAddress), true);
        }

        // sUSDS/USD = USDS/USD × (USDS per sUSDS); both 18-dec, so divide by 1e18.
        uint256 susdsUsdPrice = Math.mulDiv(usdsUsdPrice, usdsPerSusds, 1e18);

        // SHARED JPY/USD leg: a JPY-leg failure must NOT terminally shut the branch down
        // (that would make the shared FX dependency a single point of total failure across
        // all branches). Substitute the last good JPY rate and keep operating; the USDS/USD
        // and canonical legs above are still live, so the price tracks them and only the
        // (low-vol) FX leg is frozen. Auto-resumes when JPY/USD is fresh again; a prolonged
        // freeze escalates to normal branch shutdown so the feed never serves arbitrarily
        // stale FX (ORCL-SEC-005).
        (uint256 susdsJpyPrice, bool jpyFreezeExpired) = _convertUsdPriceToJpyWithFreeze(susdsUsdPrice);
        if (jpyFreezeExpired) {
            return (_shutDownFromSharedJpyFailure(), true);
        }

        (uint256 dTokenJpyPrice, bool backingUnavailable) = _applyBackingRatio(susdsJpyPrice);
        if (backingUnavailable) {
            return (_shutDownAndSwitchToLastGoodPrice(collateralVault), true);
        }

        lastGoodPrice = dTokenJpyPrice;
        return (dTokenJpyPrice, false);
    }

    /**
     * @dev Canonical rate = USDS per sUSDS via the sUSDS ERC-4626 contract.
     *      Mirrors the upstream canonical-rate gas-griefing guard: on OOG, revert
     *      `InsufficientGasForExternalCall` instead of triggering a false shutdown.
     */
    function _getCanonicalRate() internal view override returns (uint256, bool) {
        uint256 gasBefore = gasleft();

        try ISUSDS(rateProviderAddress).convertToAssets(1e18) returns (uint256 usdsPerSusds) {
            if (usdsPerSusds == 0) return (0, true);
            return (usdsPerSusds, false);
        } catch {
            if (gasleft() <= gasBefore / 64) revert InsufficientGasForExternalCall();
            return (0, true);
        }
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
    ///      Latch the terminal source state only when the branch was actually shut down, so a
    ///      direct (non-proxy) caller cannot consume the one-shot failure signal.
    function _shutDownFromSharedJpyFailure() internal returns (uint256) {
        if (JpyFreezeLib.shutDownFromSharedJpyFailure(borrowerOperations, jpyUsdRateProvider)) {
            priceSource = PriceSource.lastGoodPrice;
        }
        return lastGoodPrice;
    }

    /// @dev Vault backing-ratio adjustment; see `JpyFreezeLib.applyBackingRatio`.
    function _applyBackingRatio(uint256 _jpyPrice) internal returns (uint256, bool) {
        return jpyConversionState.applyBackingRatio(collateralVault, _jpyPrice);
    }
}
