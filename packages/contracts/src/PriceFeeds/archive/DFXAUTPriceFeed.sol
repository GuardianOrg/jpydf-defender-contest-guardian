// SPDX-License-Identifier: MIT

pragma solidity 0.8.24;

import "../DFPriceFeedBase.sol";

/**
 * @title DFXAUTPriceFeed
 * @notice Day-1 Standard JPY price feed for XAUT (Tether Gold) collateral:
 *         XAU/USD (Chainlink) → JPY, treating 1 XAUT ≈ 1 XAU.
 * @dev New DF file. Day-1 uses the Standard pattern (XAU/USD only) because Chainlink
 *      Ethereum mainnet has no XAUT/XAU or XAUT/USD feed (Oracle.md §6.3.4, plan A).
 *      The XAUT/XAU de-peg risk is absorbed statically by conservative liquidation
 *      params (Parameters.md §5-3), not monitored live here. When an XAUT/XAU feed
 *      ships, this can be swapped — with no protocol/dToken redeploy — to a composite
 *      peg feed via `PriceFeedProxy.proposeSource()` (24h timelock).
 *      Mainnet XAU/USD: 0x214eD9Da11D2fbe465a6fc601a91E62EbEc1a0D6.
 */
contract DFXAUTPriceFeed is DFPriceFeedBase {
    constructor(
        address _xauUsdOracleAddress,
        uint256 _xauUsdStalenessThreshold,
        address _jpyUsdRateProviderAddress,
        address _collateralVaultAddress,
        address _borrowerOperationsAddress
    )
        DFPriceFeedBase(
            _xauUsdOracleAddress,
            _xauUsdStalenessThreshold,
            _jpyUsdRateProviderAddress,
            _collateralVaultAddress,
            _borrowerOperationsAddress
        )
    {}
}
