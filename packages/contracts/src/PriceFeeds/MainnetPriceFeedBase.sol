// SPDX-License-Identifier: MIT

pragma solidity 0.8.24;

import "../Dependencies/AggregatorV3Interface.sol";
import "../Interfaces/IMainnetPriceFeed.sol";
import "../Interfaces/IBorrowerOperations.sol";

abstract contract MainnetPriceFeedBase is IMainnetPriceFeed {
    // Determines where the PriceFeed sources data from. Possible states:
    // - primary: Uses the primary price calculation, which depends on the specific feed
    // - ETHUSDxCanonical: Uses Chainlink's ETH-USD multiplied by the LST' canonical rate
    // - lastGoodPrice: the last good price recorded by this PriceFeed.
    PriceSource public priceSource;

    // Last good price tracker for the derived USD price
    uint256 public lastGoodPrice;

    struct Oracle {
        AggregatorV3Interface aggregator;
        uint256 stalenessThreshold;
        uint8 decimals;
    }

    struct ChainlinkResponse {
        uint80 roundId;
        uint80 answeredInRound;
        int256 answer;
        uint256 timestamp;
        bool success;
    }

    error InsufficientGasForExternalCall();

    event ShutDownFromOracleFailure(address _failedOracleAddr);

    Oracle public ethUsdOracle;

    IBorrowerOperations borrowerOperations;

    constructor(address _ethUsdOracleAddress, uint256 _ethUsdStalenessThreshold, address _borrowOperationsAddress) {
        // Store ETH-USD oracle
        ethUsdOracle.aggregator = AggregatorV3Interface(_ethUsdOracleAddress);
        ethUsdOracle.stalenessThreshold = _ethUsdStalenessThreshold;
        ethUsdOracle.decimals = ethUsdOracle.aggregator.decimals();

        borrowerOperations = IBorrowerOperations(_borrowOperationsAddress);

        assert(ethUsdOracle.decimals == 8);
    }

    function _getOracleAnswer(Oracle memory _oracle) internal view returns (uint256, bool) {
        (uint256 scaledPrice, bool oracleIsDown,) = _getOracleAnswerWithTimestamp(_oracle);
        return (scaledPrice, oracleIsDown);
    }

    /// @dev Returns the response timestamp alongside the normal oracle result. Callers that
    ///      cache a healthy answer can retain the matching timestamp as its provenance.
    function _getOracleAnswerWithTimestamp(Oracle memory _oracle)
        internal
        view
        returns (uint256 scaledPrice, bool oracleIsDown, uint256 updatedAt)
    {
        ChainlinkResponse memory chainlinkResponse = _getCurrentChainlinkResponse(_oracle.aggregator);
        updatedAt = chainlinkResponse.timestamp;

        // Check oracle is serving an up-to-date and sensible price. If not, shut down this collateral branch.
        if (!_isValidChainlinkPrice(chainlinkResponse, _oracle.stalenessThreshold)) {
            oracleIsDown = true;
        } else {
            scaledPrice = _scaleChainlinkPriceTo18decimals(chainlinkResponse.answer, _oracle.decimals);
        }

        return (scaledPrice, oracleIsDown, updatedAt);
    }

    function _shutDownAndReturnLastGoodPrice(address _failedOracleAddr) internal returns (uint256) {
        // Enter the recoverable oracle-failure shutdown. Keep retrying the primary source so
        // PriceFeedProxy can prove recovery before resuming the branch.
        borrowerOperations.shutdownFromOracleFailure();

        emit ShutDownFromOracleFailure(_failedOracleAddr);
        return lastGoodPrice;
    }

    /// @dev Legacy name retained for archived feed sources that are compiled by historical tests.
    function _shutDownAndSwitchToLastGoodPrice(address _failedOracleAddr) internal returns (uint256) {
        uint256 fallbackPrice = _shutDownAndReturnLastGoodPrice(_failedOracleAddr);
        priceSource = PriceSource.lastGoodPrice;
        return fallbackPrice;
    }

    function _getCurrentChainlinkResponse(AggregatorV3Interface _aggregator)
        internal
        view
        returns (ChainlinkResponse memory chainlinkResponse)
    {
        uint256 gasBefore = gasleft();

        // Try to get latest price data:
        try _aggregator.latestRoundData() returns (
            uint80 roundId, int256 answer, uint256, /* startedAt */ uint256 updatedAt, uint80 answeredInRound
        ) {
            // If call to Chainlink succeeds, return the response and success = true
            chainlinkResponse.roundId = roundId;
            chainlinkResponse.answeredInRound = answeredInRound;
            chainlinkResponse.answer = answer;
            chainlinkResponse.timestamp = updatedAt;
            chainlinkResponse.success = true;

            return chainlinkResponse;
        } catch {
            // Require that enough gas was provided to prevent an OOG revert in the call to Chainlink
            // causing a shutdown. Instead, just revert. Slightly conservative, as it includes gas used
            // in the check itself.
            if (gasleft() <= gasBefore / 64) revert InsufficientGasForExternalCall();

            // If call to Chainlink aggregator reverts, return a zero response with success = false
            return chainlinkResponse;
        }
    }

    // False if:
    // - Call to Chainlink aggregator reverts
    // - roundId is zero
    // - answeredInRound is older than roundId
    // - updatedAt is zero or in the future
    // - price is too stale, i.e. older than the oracle's staleness threshold
    // - Price answer is 0 or negative
    function _isValidChainlinkPrice(ChainlinkResponse memory chainlinkResponse, uint256 _stalenessThreshold)
        internal
        view
        returns (bool)
    {
        return chainlinkResponse.success && chainlinkResponse.roundId != 0
            && chainlinkResponse.answeredInRound >= chainlinkResponse.roundId && chainlinkResponse.timestamp != 0
            && chainlinkResponse.timestamp <= block.timestamp
            && block.timestamp - chainlinkResponse.timestamp < _stalenessThreshold && chainlinkResponse.answer > 0;
    }

    // Trust assumption: Chainlink won't change the decimal precision on any feed used in v2 after deployment
    function _scaleChainlinkPriceTo18decimals(int256 _price, uint256 _decimals) internal pure returns (uint256) {
        // Scale an int price to a uint with 18 decimals
        return uint256(_price) * 10 ** (18 - _decimals);
    }
}
