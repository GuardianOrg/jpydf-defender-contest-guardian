// SPDX-License-Identifier: MIT

pragma solidity 0.8.24;

import "./DFPriceFeedBase.sol";

/**
 * @title DFUSDCPriceFeed
 * @notice Standard JPY price feed for USDC collateral: USDC/USD (Chainlink) → JPY.
 * @dev New DF file (no upstream equivalent). All logic is in `DFPriceFeedBase`;
 *      this contract only fixes the type and constructor wiring.
 *      Mainnet USDC/USD: 0x8fFfFfd4AfB6115b954Bd326cbe7B4BA576818f6.
 */
contract DFUSDCPriceFeed is DFPriceFeedBase {
    constructor(
        address _usdcUsdOracleAddress,
        uint256 _usdcUsdStalenessThreshold,
        address _jpyUsdRateProviderAddress,
        address _collateralVaultAddress,
        address _borrowerOperationsAddress
    )
        DFPriceFeedBase(
            _usdcUsdOracleAddress,
            _usdcUsdStalenessThreshold,
            _jpyUsdRateProviderAddress,
            _collateralVaultAddress,
            _borrowerOperationsAddress
        )
    {}
}
