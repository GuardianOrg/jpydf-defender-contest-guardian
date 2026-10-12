// SPDX-License-Identifier: MIT

pragma solidity 0.8.24;

import "../DFPriceFeedBase.sol";

/**
 * @title DFUSDTPriceFeed
 * @notice Standard JPY price feed for USDT collateral: USDT/USD (Chainlink) → JPY.
 * @dev New DF file (no upstream equivalent). All logic is in `DFPriceFeedBase`;
 *      this contract only fixes the type and constructor wiring.
 *      Mainnet USDT/USD: 0x3E7d1eAB13ad0104d2750B8863b489D65364e32D.
 */
contract DFUSDTPriceFeed is DFPriceFeedBase {
    constructor(
        address _usdtUsdOracleAddress,
        uint256 _usdtUsdStalenessThreshold,
        address _jpyUsdRateProviderAddress,
        address _collateralVaultAddress,
        address _borrowerOperationsAddress
    )
        DFPriceFeedBase(
            _usdtUsdOracleAddress,
            _usdtUsdStalenessThreshold,
            _jpyUsdRateProviderAddress,
            _collateralVaultAddress,
            _borrowerOperationsAddress
        )
    {}
}
