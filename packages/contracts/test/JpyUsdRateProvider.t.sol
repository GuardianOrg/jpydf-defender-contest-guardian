// SPDX-License-Identifier: MIT

pragma solidity 0.8.24;

import "forge-std/Test.sol";
import "src/PriceFeeds/JpyUsdRateProvider.sol";
import "./TestContracts/ChainlinkOracleMock.sol";

contract JpyUsdRateProviderTest is Test {
    ChainlinkOracleMock oracle;
    JpyUsdRateProvider provider;

    uint256 constant STALENESS = 72 hours;
    int256 constant INITIAL_RATE = 666_700;

    function setUp() public {
        vm.warp(1_700_000_000);
        oracle = new ChainlinkOracleMock();
        oracle.setDecimals(8);
        oracle.setPrice(INITIAL_RATE);
        oracle.setUpdatedAt(block.timestamp);
        provider = new JpyUsdRateProvider(address(oracle), STALENESS);
    }

    function test_permissionlessHealthyFetchRefreshesOneSharedCache() public {
        vm.warp(block.timestamp + 1 hours);
        oracle.setPrice(500_000);
        oracle.setUpdatedAt(block.timestamp);

        vm.prank(makeAddr("keeper"));
        (uint256 rate, bool expired) = provider.fetchJpyUsdRate();

        assertFalse(expired);
        assertEq(rate, 500_000 * 1e10);
        assertEq(provider.lastGoodJpyRate(), rate);
        assertEq(provider.lastGoodJpyUpdatedAt(), block.timestamp);
    }

    function test_runtimeDecimalsMismatchDoesNotAdoptFreshRoundAndRecoveryRemainsPossible() public {
        uint256 cachedRate = provider.lastGoodJpyRate();
        uint256 cachedAt = provider.lastGoodJpyUpdatedAt();

        vm.warp(block.timestamp + 1 hours);
        oracle.setDecimals(18);
        oracle.setPrice(500_000e10);
        oracle.setUpdatedAt(block.timestamp);

        (uint256 frozenRate, bool expired) = provider.fetchJpyUsdRate();

        assertFalse(expired);
        assertEq(frozenRate, cachedRate);
        assertEq(provider.lastGoodJpyRate(), cachedRate);
        assertEq(provider.lastGoodJpyUpdatedAt(), cachedAt);
        assertEq(provider.jpyFrozenSince(), block.timestamp);

        oracle.setDecimals(8);
        oracle.setPrice(500_000);
        oracle.setUpdatedAt(block.timestamp);

        (uint256 recoveredRate, bool recoveredExpired) = provider.fetchJpyUsdRate();

        assertFalse(recoveredExpired);
        assertEq(recoveredRate, 500_000 * 1e10);
        assertEq(provider.lastGoodJpyRate(), recoveredRate);
        assertEq(provider.lastGoodJpyUpdatedAt(), block.timestamp);
        assertEq(provider.jpyFrozenSince(), 0);
    }

    function test_runtimeDecimalsMismatchDoesNotAdoptStaleButNewerRound() public {
        uint256 cachedRate = provider.lastGoodJpyRate();
        uint256 cachedAt = provider.lastGoodJpyUpdatedAt();

        vm.warp(block.timestamp + 1 hours);
        oracle.setDecimals(18);
        oracle.setPrice(500_000e10);
        oracle.setUpdatedAt(block.timestamp);
        uint256 newerRoundAt = block.timestamp;

        vm.warp(newerRoundAt + STALENESS + 1);
        (uint256 frozenRate, bool expired) = provider.fetchJpyUsdRate();

        assertFalse(expired);
        assertEq(frozenRate, cachedRate);
        assertEq(provider.lastGoodJpyRate(), cachedRate);
        assertEq(provider.lastGoodJpyUpdatedAt(), cachedAt);
        assertEq(provider.jpyFrozenSince(), cachedAt + STALENESS);
    }

    function test_runtimeDecimalsRevertDoesNotAdoptFreshRound() public {
        uint256 cachedRate = provider.lastGoodJpyRate();
        uint256 cachedAt = provider.lastGoodJpyUpdatedAt();

        vm.warp(block.timestamp + 1 hours);
        oracle.setPrice(500_000);
        oracle.setUpdatedAt(block.timestamp);
        vm.mockCallRevert(
            address(oracle), abi.encodeCall(AggregatorV3Interface.decimals, ()), bytes("decimals unavailable")
        );

        (uint256 frozenRate, bool expired) = provider.fetchJpyUsdRate();

        assertFalse(expired);
        assertEq(frozenRate, cachedRate);
        assertEq(provider.lastGoodJpyRate(), cachedRate);
        assertEq(provider.lastGoodJpyUpdatedAt(), cachedAt);
        assertEq(provider.jpyFrozenSince(), block.timestamp);
    }

    function test_runtimeDecimalsGasGriefingBubblesInsufficientGas() public {
        uint256 cachedRate = provider.lastGoodJpyRate();
        uint256 cachedAt = provider.lastGoodJpyUpdatedAt();
        oracle.setGasGriefDecimals(true);

        vm.expectRevert(JpyUsdRateProvider.InsufficientGasForExternalCall.selector);
        provider.fetchJpyUsdRate{gas: 500_000}();

        assertEq(provider.lastGoodJpyRate(), cachedRate);
        assertEq(provider.lastGoodJpyUpdatedAt(), cachedAt);
        assertEq(provider.jpyFrozenSince(), 0);
    }

    // A round that is decodable but past the staleness threshold still carries better
    // information than a much older cached one. Adopting it keeps the served rate as fresh as
    // the chain allows AND anchors the freeze onset to real data age rather than call recency.
    function test_staleButNewerRoundIsAdoptedAndAnchorsTheFreeze() public {
        // t0: cached rate observed fresh.
        (, bool expired0) = provider.fetchJpyUsdRate();
        assertFalse(expired0);
        uint256 cachedAt = provider.lastGoodJpyUpdatedAt();

        // The oracle keeps publishing while nothing calls this contract.
        vm.warp(block.timestamp + 24 hours);
        oracle.setPrice(500_000);
        oracle.setUpdatedAt(block.timestamp);
        uint256 newerRoundAt = block.timestamp;

        // First call lands long after that round went stale.
        vm.warp(newerRoundAt + STALENESS + 1);
        (uint256 rate, bool expired) = provider.fetchJpyUsdRate();

        // The newer round is adopted even though it is not fresh.
        assertFalse(expired, "one stale read must not reach terminal expiry");
        assertEq(rate, 500_000 * 1e10, "serves the newest readable round, not the older cache");
        assertEq(provider.lastGoodJpyUpdatedAt(), newerRoundAt, "anchor follows the newest round");
        assertGt(provider.lastGoodJpyUpdatedAt(), cachedAt);

        // The freeze onset is derived from that anchor, so the full grace window remains.
        assertEq(provider.jpyFrozenSince(), newerRoundAt + STALENESS, "grace measured from real data age");
        vm.warp(provider.jpyFrozenSince() + provider.MAX_JPY_FREEZE_DURATION() - 1);
        (, bool stillLive) = provider.fetchJpyUsdRate();
        assertFalse(stillLive, "grace window is honoured in full");
    }

    // An invalid round must not move the anchor forward, however recent its timestamp is.
    function test_invalidRoundDoesNotAdvanceTheAnchor() public {
        (, bool expired0) = provider.fetchJpyUsdRate();
        assertFalse(expired0);
        uint256 anchorBefore = provider.lastGoodJpyUpdatedAt();

        vm.warp(block.timestamp + STALENESS + 1);
        // Fresh timestamp, but the round never completed: answeredInRound < roundId.
        oracle.setUpdatedAt(block.timestamp);
        oracle.setRoundData(9, 8);
        provider.fetchJpyUsdRate();

        assertEq(provider.lastGoodJpyUpdatedAt(), anchorBefore, "an incomplete round carries no anchor");
    }

    function test_staleRoundAnchorsFreezeToSharedCachedBoundary() public {
        uint256 expectedStart = block.timestamp + STALENESS;
        vm.warp(expectedStart + 1);

        (uint256 rate, bool expired) = provider.fetchJpyUsdRate();

        assertFalse(expired);
        assertEq(rate, uint256(INITIAL_RATE) * 1e10);
        assertEq(provider.jpyFrozenSince(), expectedStart);
    }

    function test_invalidRoundWhileCacheFreshStartsAtObservationAndRecovers() public {
        vm.warp(block.timestamp + 1 hours);
        oracle.setRoundData(0, 0);

        provider.fetchJpyUsdRate();
        assertEq(provider.jpyFrozenSince(), block.timestamp);

        vm.warp(block.timestamp + 1 hours);
        oracle.setRoundData(2, 2);
        oracle.setPrice(500_000);
        oracle.setUpdatedAt(block.timestamp);
        (uint256 rate, bool expired) = provider.fetchJpyUsdRate();

        assertFalse(expired);
        assertEq(rate, 500_000 * 1e10);
        assertEq(provider.jpyFrozenSince(), 0);
    }

    function test_freshRecoveryAfterExpirationClearsLatch() public {
        uint256 expectedStart = block.timestamp + STALENESS;
        vm.warp(expectedStart + provider.MAX_JPY_FREEZE_DURATION());

        (uint256 expiredRate, bool expired) = provider.fetchJpyUsdRate();
        assertTrue(expired);
        assertTrue(provider.jpyFreezeExpired());

        oracle.setPrice(500_000);
        oracle.setUpdatedAt(block.timestamp);
        vm.expectEmit(true, true, true, true);
        emit JpyUsdRateProvider.JpyRateUnfrozen(block.timestamp, 500_000 * 1e10);
        (uint256 laterRate, bool laterExpired) = provider.fetchJpyUsdRate();

        assertFalse(laterExpired, "fresh recovery clears the expired freeze episode");
        assertEq(laterRate, 500_000 * 1e10, "provider adopts the recovered live rate");
        assertNotEq(laterRate, expiredRate);
        assertEq(provider.lastGoodJpyRate(), laterRate);
        assertEq(provider.lastGoodJpyUpdatedAt(), block.timestamp);
        assertEq(provider.jpyFrozenSince(), 0);
        assertFalse(provider.jpyFreezeExpired());
    }

    function test_expirationRemainsLatchedUntilOracleIsFresh() public {
        uint256 expectedStart = block.timestamp + STALENESS;
        vm.warp(expectedStart + provider.MAX_JPY_FREEZE_DURATION());

        (uint256 expiredRate, bool expired) = provider.fetchJpyUsdRate();
        assertTrue(expired);

        vm.warp(block.timestamp + STALENESS + 1);
        oracle.setPrice(500_000);
        oracle.setUpdatedAt(block.timestamp - STALENESS);
        (uint256 laterRate, bool laterExpired) = provider.fetchJpyUsdRate();

        assertTrue(laterExpired, "a merely readable stale round cannot clear expiry");
        assertEq(laterRate, expiredRate);
        assertEq(provider.jpyFrozenSince(), expectedStart);
        assertTrue(provider.jpyFreezeExpired());
    }

    function test_recoveredProviderCanExpireAgainDuringALaterOutage() public {
        vm.warp(block.timestamp + STALENESS + provider.MAX_JPY_FREEZE_DURATION());
        (, bool firstExpired) = provider.fetchJpyUsdRate();
        assertTrue(firstExpired);

        oracle.setPrice(500_000);
        oracle.setUpdatedAt(block.timestamp);
        (, bool recovered) = provider.fetchJpyUsdRate();
        assertFalse(recovered);

        uint256 secondExpectedStart = block.timestamp + STALENESS;
        vm.warp(secondExpectedStart + provider.MAX_JPY_FREEZE_DURATION());
        (, bool secondExpired) = provider.fetchJpyUsdRate();

        assertTrue(secondExpired);
        assertEq(provider.jpyFrozenSince(), secondExpectedStart);
        assertTrue(provider.jpyFreezeExpired());
    }

    function test_constructorRejectsNoCodeOracle() public {
        vm.expectRevert(JpyUsdRateProvider.InvalidOracle.selector);
        new JpyUsdRateProvider(makeAddr("oracle"), STALENESS);
    }

    function test_constructorRejectsZeroStaleness() public {
        vm.expectRevert(JpyUsdRateProvider.InvalidStalenessThreshold.selector);
        new JpyUsdRateProvider(address(oracle), 0);
    }

    function test_constructorRejectsUnexpectedDecimals() public {
        oracle.setDecimals(18);
        vm.expectRevert(JpyUsdRateProvider.UnexpectedOracleDecimals.selector);
        new JpyUsdRateProvider(address(oracle), STALENESS);
    }

    function test_constructorRejectsStaleInitialResponse() public {
        vm.warp(block.timestamp + STALENESS);
        vm.expectRevert(JpyUsdRateProvider.InvalidInitialOracleResponse.selector);
        new JpyUsdRateProvider(address(oracle), STALENESS);
    }
}
