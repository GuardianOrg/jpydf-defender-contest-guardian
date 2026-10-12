// SPDX-License-Identifier: MIT

pragma solidity 0.8.24;

import "../Dependencies/AggregatorV3Interface.sol";
import "../Interfaces/IJpyUsdRateProvider.sol";

/**
 * @title JpyUsdRateProvider
 * @notice Single source of JPY/USD rate and soft-freeze state for every collateral branch.
 * @dev A shared contract is required because inherited state remains local to each deployed
 *      price feed. Healthy Chainlink responses refresh one shared cache. Invalid, stale, or
 *      reverting responses reuse that cache for at most MAX_JPY_FREEZE_DURATION. Expiration
 *      remains latched while the oracle is unhealthy, but a later fresh response starts a new
 *      healthy episode. Branches that already observed expiry remain in the reversible Core
 *      oracle pause until their registered PriceFeed explicitly resumes them.
 */
contract JpyUsdRateProvider is IJpyUsdRateProvider {
    error InsufficientGasForExternalCall();
    error InvalidOracle();
    error InvalidStalenessThreshold();
    error InvalidInitialOracleResponse();
    error UnexpectedOracleDecimals();

    uint256 public constant MAX_JPY_FREEZE_DURATION = 24 hours;

    AggregatorV3Interface public immutable jpyUsdOracle;
    uint256 public immutable stalenessThreshold;
    uint8 public immutable oracleDecimals;

    uint256 public lastGoodJpyRate;
    uint256 public override lastGoodJpyUpdatedAt;
    uint256 public jpyFrozenSince;
    bool public jpyFreezeExpired;

    event JpyRateFrozen(uint256 timestamp, uint256 frozenRate);
    event JpyRateUnfrozen(uint256 timestamp, uint256 liveRate);
    event JpyFreezeExpired(uint256 timestamp, uint256 frozenRate);

    struct ChainlinkResponse {
        uint80 roundId;
        uint80 answeredInRound;
        int256 answer;
        uint256 updatedAt;
        bool success;
    }

    constructor(address _jpyUsdOracleAddress, uint256 _stalenessThreshold) {
        if (_jpyUsdOracleAddress.code.length == 0) revert InvalidOracle();
        if (_stalenessThreshold == 0) revert InvalidStalenessThreshold();

        jpyUsdOracle = AggregatorV3Interface(_jpyUsdOracleAddress);
        stalenessThreshold = _stalenessThreshold;
        oracleDecimals = jpyUsdOracle.decimals();
        if (oracleDecimals != 8) revert UnexpectedOracleDecimals();

        ChainlinkResponse memory response = _getCurrentChainlinkResponse();
        if (!_isFresh(response)) revert InvalidInitialOracleResponse();

        lastGoodJpyRate = _scaleTo18Decimals(response.answer);
        lastGoodJpyUpdatedAt = response.updatedAt;
    }

    function fetchJpyUsdRate() external returns (uint256 rate, bool freezeExpired) {
        ChainlinkResponse memory response = _getCurrentChainlinkResponse();
        if (_isFresh(response)) {
            rate = _scaleTo18Decimals(response.answer);
            lastGoodJpyRate = rate;
            lastGoodJpyUpdatedAt = response.updatedAt;
            jpyFreezeExpired = false;

            if (jpyFrozenSince != 0) {
                jpyFrozenSince = 0;
                emit JpyRateUnfrozen(block.timestamp, rate);
            }
            return (rate, false);
        }

        // Terminal for the current outage, not for the provider's lifetime. Keep returning the
        // expired signal while the oracle is unhealthy, but leave the fresh-read path above
        // reachable so a later valid round can begin a new episode.
        if (jpyFreezeExpired) return (lastGoodJpyRate, true);

        // The response is not fresh, but it may still be decodable and NEWER than what we
        // cached. `lastGoodJpyUpdatedAt` only advances on a fresh read, and nothing polls this
        // contract, so after a quiet period the cache can lag the newest published round by an
        // unbounded amount. Serving that older rate is strictly worse, and the freeze onset
        // below is derived from the same timestamp, so the lag also shortens the grace window.
        // Adopt the newer round here: same validity checks as `_isFresh` minus the staleness
        // clause, which is the one condition we already know fails.
        if (
            response.success && response.roundId != 0 && response.answeredInRound >= response.roundId
                && response.updatedAt != 0 && response.updatedAt <= block.timestamp && response.answer > 0
                && response.updatedAt > lastGoodJpyUpdatedAt
        ) {
            lastGoodJpyRate = _scaleTo18Decimals(response.answer);
            lastGoodJpyUpdatedAt = response.updatedAt;
            // A newer valid round marks a new data episode even if no caller observed it while
            // fresh. Re-anchor the stale episode below instead of inheriting the old timer. An
            // already-expired episode returned above and still requires an observed fresh
            // response to clear its latch.
            jpyFrozenSince = 0;
        }

        rate = lastGoodJpyRate;
        if (jpyFrozenSince == 0) {
            uint256 freezeStartedAt = block.timestamp;
            if (block.timestamp - lastGoodJpyUpdatedAt >= stalenessThreshold) {
                freezeStartedAt = lastGoodJpyUpdatedAt + stalenessThreshold;
            }
            jpyFrozenSince = freezeStartedAt;
            emit JpyRateFrozen(freezeStartedAt, rate);
        }

        if (block.timestamp - jpyFrozenSince >= MAX_JPY_FREEZE_DURATION) {
            jpyFreezeExpired = true;
            emit JpyFreezeExpired(block.timestamp, rate);
            return (rate, true);
        }

        return (rate, false);
    }

    function _getCurrentChainlinkResponse() internal view returns (ChainlinkResponse memory response) {
        uint256 gasBefore = gasleft();

        // Both fresh and stale-but-new adoption require `response.success`, so invalidate the
        // response here before either path can scale or cache a differently-scaled answer.
        try jpyUsdOracle.decimals() returns (uint8 liveDecimals) {
            if (liveDecimals != oracleDecimals) return response;
        } catch {
            if (gasleft() <= gasBefore / 64) revert InsufficientGasForExternalCall();
            return response;
        }

        gasBefore = gasleft();

        try jpyUsdOracle.latestRoundData() returns (
            uint80 roundId, int256 answer, uint256, /* startedAt */ uint256 updatedAt, uint80 answeredInRound
        ) {
            response.roundId = roundId;
            response.answeredInRound = answeredInRound;
            response.answer = answer;
            response.updatedAt = updatedAt;
            response.success = true;
            return response;
        } catch {
            if (gasleft() <= gasBefore / 64) revert InsufficientGasForExternalCall();
            return response;
        }
    }

    function _isFresh(ChainlinkResponse memory _response) internal view returns (bool) {
        return _response.success && _response.roundId != 0 && _response.answeredInRound >= _response.roundId
            && _response.updatedAt != 0 && _response.updatedAt <= block.timestamp
            && block.timestamp - _response.updatedAt < stalenessThreshold && _response.answer > 0;
    }

    function _scaleTo18Decimals(int256 _answer) internal pure returns (uint256) {
        return uint256(_answer) * 1e10;
    }
}
