// SPDX-License-Identifier: MIT

pragma solidity 0.8.24;

import "forge-std/Test.sol";
import "src/PriceFeeds/DFWstETHPriceFeed.sol";
import "src/PriceFeeds/JpyUsdRateProvider.sol";
import "src/Interfaces/IMainnetPriceFeed.sol";
import "./TestContracts/ChainlinkOracleMock.sol";
import "openzeppelin-contracts/contracts/utils/math/Math.sol";

// Minimal BorrowerOperations stub (the feed calls shutdownFromOracleFailure directly).
contract MockBO {
    bool public shutDownCalled;

    function shutdownFromOracleFailure() external {
        shutDownCalled = true;
    }
}

// Mock wstETH. stEthPerToken() = canonical rate (stETH per wstETH).
contract MockWstETH {
    uint8 public decimals = 18;
    uint256 public rate; // stETH per wstETH, 18-dec
    bool public shouldRevert;

    function setDecimals(uint8 d) external {
        decimals = d;
    }

    function setRate(uint256 r) external {
        rate = r;
    }

    function setShouldRevert(bool b) external {
        shouldRevert = b;
    }

    function stEthPerToken() external view returns (uint256) {
        if (shouldRevert) revert("wstETH down");
        return rate;
    }
}

contract MockWstETHBackingVault {
    uint256 public ratio = 1e18;
    bool public shouldRevert;
    bool public shouldConsumeAllGas;
    bool public backingUnavailable;

    function setBackingRatio(uint256 r) external {
        ratio = r;
    }

    function setShouldRevert(bool b) external {
        shouldRevert = b;
    }

    function setShouldConsumeAllGas(bool b) external {
        shouldConsumeAllGas = b;
    }

    function setBackingUnavailable(bool b) external {
        backingUnavailable = b;
    }

    function backingRatio() external view returns (uint256) {
        if (shouldConsumeAllGas) {
            assembly {
                invalid()
            }
        }
        if (shouldRevert) revert("backing unavailable");
        return ratio;
    }

    function backingRatioForPricing() external view returns (uint256, bool) {
        if (shouldConsumeAllGas) {
            assembly {
                invalid()
            }
        }
        if (shouldRevert) revert("backing unavailable");
        if (backingUnavailable) return (0, false);
        return (ratio, true);
    }
}

contract GasGriefingChainlinkOracleMock {
    bool public shouldConsumeAllGas;
    uint256 public updatedAt;

    function decimals() external pure returns (uint8) {
        return 8;
    }

    function setUpdatedAt(uint256 _updatedAt) external {
        updatedAt = _updatedAt;
    }

    function setShouldConsumeAllGas(bool _shouldConsumeAllGas) external {
        shouldConsumeAllGas = _shouldConsumeAllGas;
    }

    function latestRoundData()
        external
        view
        returns (uint80 roundId, int256 answer, uint256 startedAt, uint256 timestamp, uint80 answeredInRound)
    {
        if (shouldConsumeAllGas) {
            assembly {
                invalid()
            }
        }
        return (1, 3000e8, 0, updatedAt, 1);
    }
}

/// @notice Forkless tests for DFWstETHPriceFeed (composite rate).
///         Mocks stETH/USD + JPY/USD (ChainlinkOracleMock) and the wstETH canonical
///         rate (MockWstETH), so the composite math + shutdown paths are verified
///         without a mainnet fork. Real-mainnet integration is a CI/Phase-6 concern.
contract DFWstETHPriceFeedTest is Test {
    using stdStorage for StdStorage;

    ChainlinkOracleMock stEthUsd;
    ChainlinkOracleMock ethUsd;
    ChainlinkOracleMock stEthEth;
    ChainlinkOracleMock jpyUsd;
    JpyUsdRateProvider jpyRateProvider;
    MockWstETH wstEth;
    MockBO bo;
    MockWstETHBackingVault backingVault;

    uint256 constant STETH_STALENESS = 24 hours;
    uint256 constant ETH_STALENESS = 2 hours;
    uint256 constant STETH_ETH_STALENESS = 25 hours;
    uint256 constant JPY_STALENESS = 72 hours;
    int256 constant JPY_USD_8DEC = 666_700; // 0.006667 USD per JPY (~¥150/$)

    function setUp() public {
        vm.warp(1_700_000_000);

        stEthUsd = new ChainlinkOracleMock();
        stEthUsd.setDecimals(8);
        stEthUsd.setPrice(3000e8); // stETH = $3,000
        stEthUsd.setUpdatedAt(block.timestamp);

        ethUsd = new ChainlinkOracleMock();
        ethUsd.setDecimals(8);
        ethUsd.setPrice(3000e8); // ETH = $3,000
        ethUsd.setUpdatedAt(block.timestamp);

        stEthEth = new ChainlinkOracleMock();
        stEthEth.setDecimals(18);
        stEthEth.setPrice(1e18); // stETH = 1 ETH
        stEthEth.setUpdatedAt(block.timestamp);

        jpyUsd = new ChainlinkOracleMock();
        jpyUsd.setDecimals(8);
        jpyUsd.setPrice(JPY_USD_8DEC);
        jpyUsd.setUpdatedAt(block.timestamp);
        jpyRateProvider = new JpyUsdRateProvider(address(jpyUsd), JPY_STALENESS);

        wstEth = new MockWstETH();
        wstEth.setRate(1.2e18); // 1 wstETH = 1.2 stETH

        bo = new MockBO();
        backingVault = new MockWstETHBackingVault();
    }

    function _deploy() internal returns (DFWstETHPriceFeed) {
        return _deployWithEthReference(address(ethUsd));
    }

    function _deployWithEthReference(address _ethUsd) internal returns (DFWstETHPriceFeed) {
        return new DFWstETHPriceFeed(
            address(stEthUsd),
            _ethUsd,
            address(stEthEth),
            address(wstEth),
            STETH_STALENESS,
            ETH_STALENESS,
            STETH_ETH_STALENESS,
            address(jpyRateProvider),
            address(backingVault),
            address(bo)
        );
    }

    // --- composite math: wstETH/JPY = stETH/USD × stEthPerToken / (JPY/USD) ---

    function test_jpyConversion() public {
        DFWstETHPriceFeed feed = _deploy();
        (uint256 price, bool failure) = feed.fetchPrice();
        assertFalse(failure);
        // 3000 × 1.2 / 0.006667 ≈ 539,973 → ~¥540,000
        assertApproxEqRel(price, 540_000e18, 0.001e18);
    }

    function test_compositeJpyConversionUsesFullPrecisionMulDiv() public {
        stEthUsd.setPrice(1e50);
        jpyUsd.setPrice(1e8); // JPY/USD = 1, normalized to 1e18
        wstEth.setRate(2e18);

        DFWstETHPriceFeed feed = _deploy();
        (uint256 price, bool failure) = feed.fetchPrice();

        assertFalse(failure);
        assertEq(price, 2e60, "final price fits even though intermediate products would overflow");
    }

    function test_rateIncreaseRaisesPrice() public {
        DFWstETHPriceFeed feed = _deploy();
        (uint256 basePrice,) = feed.fetchPrice();

        wstEth.setRate(1.3e18); // staking yield accrues → rate only goes up in practice
        (uint256 price, bool failure) = feed.fetchPrice();

        assertFalse(failure);
        // 1-wei tolerance: the feed rounds once per mulDiv, the rescaled expectation twice.
        assertApproxEqAbs(price, Math.mulDiv(basePrice, 1.3e18, 1.2e18), 1);
        assertGt(price, basePrice);
    }

    function test_rateDecreaseLowersPrice() public {
        DFWstETHPriceFeed feed = _deploy();
        (uint256 basePrice,) = feed.fetchPrice();

        wstEth.setRate(1.1e18); // slashing scenario → price must follow down immediately
        (uint256 price, bool failure) = feed.fetchPrice();

        assertFalse(failure);
        // 1-wei tolerance: the feed rounds once per mulDiv, the rescaled expectation twice.
        assertApproxEqAbs(price, Math.mulDiv(basePrice, 1.1e18, 1.2e18), 1);
        assertLt(price, basePrice);
    }

    function test_redemptionPriceEqualsPrice() public {
        DFWstETHPriceFeed feed = _deploy();
        (uint256 p,) = feed.fetchPrice();
        (uint256 rp,) = feed.fetchRedemptionPrice();
        assertEq(p, rp);
    }

    function test_redemptionUsesUnconditionalHigherEthUsdReference() public {
        DFWstETHPriceFeed feed = _deploy();
        (uint256 normalPrice,) = feed.fetchPrice();

        // Reproduce the relevant BOLD shape: stETH/USD remains stale-low while
        // the faster ETH/USD reference has moved about 4.3%, beyond upstream's
        // historical 1% comparison gate.
        ethUsd.setPrice(3129e8);
        ethUsd.setUpdatedAt(block.timestamp);

        (uint256 redemptionPrice, bool failure) = feed.fetchRedemptionPrice();

        assertFalse(failure);
        assertApproxEqRel(redemptionPrice, Math.mulDiv(normalPrice, 3129, 3000), 1e12);
        assertGt(redemptionPrice, normalPrice);
        assertEq(feed.lastGoodPrice(), normalPrice, "redemption quote must not contaminate normal cache");
    }

    function test_redemptionKeepsStEthUsdWhenEthUsdReferenceIsLower() public {
        DFWstETHPriceFeed feed = _deploy();
        (uint256 normalPrice,) = feed.fetchPrice();

        ethUsd.setPrice(2700e8);
        ethUsd.setUpdatedAt(block.timestamp);

        (uint256 redemptionPrice, bool failure) = feed.fetchRedemptionPrice();

        assertFalse(failure);
        assertEq(redemptionPrice, normalPrice);
    }

    function test_redemptionCompositeTracksEthMoveWithoutIgnoringStEthDepeg() public {
        DFWstETHPriceFeed feed = _deploy();
        (uint256 normalPrice,) = feed.fetchPrice();

        ethUsd.setPrice(3300e8);
        stEthEth.setPrice(0.9e18);

        (uint256 redemptionPrice, bool failure) = feed.fetchRedemptionPrice();

        assertFalse(failure);
        assertEq(redemptionPrice, normalPrice, "3300 USD x 0.90 stETH/ETH equals direct 3000 USD");
    }

    function test_urgentAndRedemptionPricesStayEqualForProxyContinuity() public {
        DFWstETHPriceFeed feed = _deploy();
        ethUsd.setPrice(3300e8);
        stEthEth.setPrice(0.95e18);

        (uint256 redemptionPrice, bool redemptionFailure) = feed.fetchRedemptionPrice();
        (uint256 urgentPrice, bool urgentFailure) = feed.fetchUrgentRedemptionPrice();

        assertFalse(redemptionFailure);
        assertFalse(urgentFailure);
        assertEq(urgentPrice, redemptionPrice);
    }

    function test_urgentReferenceFailureReturnsFailureWithoutUpdatingNormalCache() public {
        DFWstETHPriceFeed feed = _deploy();
        (uint256 normalPrice,) = feed.fetchPrice();
        stEthEth.setPrice(0);

        vm.expectEmit(true, true, true, true, address(feed));
        emit DFWstETHPriceFeed.UrgentRedemptionReferenceUnavailable(address(stEthEth), 3000e18);
        (uint256 urgentPrice, bool failure) = feed.fetchUrgentRedemptionPrice();

        assertTrue(failure);
        assertEq(urgentPrice, normalPrice);
        assertEq(feed.lastGoodPrice(), normalPrice);
        assertFalse(bo.shutDownCalled());
    }

    function test_urgentPriceRejectsLegacyTerminalSourceCache() public {
        DFWstETHPriceFeed feed = _deploy();
        uint256 lastGoodPrice = feed.lastGoodPrice();

        stdstore.target(address(feed)).sig(IMainnetPriceFeed.priceSource.selector)
            .checked_write(uint256(IMainnetPriceFeed.PriceSource.lastGoodPrice));

        (uint256 price, bool failure) = feed.fetchUrgentRedemptionPrice();
        assertEq(price, lastGoodPrice);
        assertTrue(failure);
    }

    function test_urgentCompositeUsesSharedLiveJpyRateExactlyOnce() public {
        DFWstETHPriceFeed feed = _deploy();
        ethUsd.setPrice(3300e8);
        jpyUsd.setPrice(500_000); // JPY/USD = 0.005

        (uint256 urgentPrice, bool failure) = feed.fetchUrgentRedemptionPrice();

        assertFalse(failure);
        assertApproxEqRel(urgentPrice, 792_000e18, 0.001e18); // 3300 x 1.2 / 0.005
    }

    function test_urgentCompositeUsesFrozenJpyRateWithinWindow() public {
        DFWstETHPriceFeed feed = _deploy();

        vm.warp(block.timestamp + 73 hours);
        stEthUsd.setUpdatedAt(block.timestamp);
        ethUsd.setPrice(3300e8);
        ethUsd.setUpdatedAt(block.timestamp);
        stEthEth.setUpdatedAt(block.timestamp);

        (uint256 urgentPrice, bool failure) = feed.fetchUrgentRedemptionPrice();

        assertFalse(failure);
        assertFalse(bo.shutDownCalled());
        assertGt(jpyRateProvider.jpyFrozenSince(), 0);
        assertApproxEqRel(urgentPrice, 594_000e18, 0.001e18); // 3300 x 1.2 / frozen 0.006667
    }

    function test_urgentCompositeJpyFreezeExpiryReturnsFailureAtLastGoodPrice() public {
        DFWstETHPriceFeed feed = _deploy();
        uint256 lastGoodPrice = feed.lastGoodPrice();

        vm.warp(block.timestamp + 73 hours);
        stEthUsd.setUpdatedAt(block.timestamp);
        ethUsd.setUpdatedAt(block.timestamp);
        stEthEth.setUpdatedAt(block.timestamp);
        feed.fetchUrgentRedemptionPrice();

        vm.warp(jpyRateProvider.jpyFrozenSince() + jpyRateProvider.MAX_JPY_FREEZE_DURATION());
        stEthUsd.setUpdatedAt(block.timestamp);
        ethUsd.setUpdatedAt(block.timestamp);
        stEthEth.setUpdatedAt(block.timestamp);

        (uint256 urgentPrice, bool failure) = feed.fetchUrgentRedemptionPrice();

        assertTrue(failure);
        assertTrue(bo.shutDownCalled());
        assertEq(urgentPrice, lastGoodPrice);
    }

    function test_redemptionReferenceStaleFailsClosedAndEmits() public {
        DFWstETHPriceFeed feed = _deploy();
        (uint256 normalPrice,) = feed.fetchPrice();

        vm.warp(block.timestamp + ETH_STALENESS);
        stEthUsd.setUpdatedAt(block.timestamp);
        jpyUsd.setUpdatedAt(block.timestamp);

        vm.expectEmit(true, true, true, true, address(feed));
        emit DFWstETHPriceFeed.RedemptionReferenceUnavailable(address(ethUsd), 3000e18);
        (uint256 redemptionPrice, bool failure) = feed.fetchRedemptionPrice();

        assertTrue(failure);
        assertEq(redemptionPrice, normalPrice);
        assertTrue(bo.shutDownCalled());
        assertEq(uint256(feed.priceSource()), uint256(IMainnetPriceFeed.PriceSource.primary));
    }

    function testFuzz_redemptionPriceNeverBelowNormal(uint96 stEthUsdRaw, uint96 ethUsdRaw) public {
        int256 stEthPrice = int256(bound(stEthUsdRaw, 100e8, 1_000_000e8));
        int256 ethPrice = int256(bound(ethUsdRaw, 100e8, 1_000_000e8));
        stEthUsd.setPrice(stEthPrice);
        ethUsd.setPrice(ethPrice);

        DFWstETHPriceFeed feed = _deploy();
        (uint256 normalPrice, bool normalFailure) = feed.fetchPrice();
        (uint256 redemptionPrice, bool redemptionFailure) = feed.fetchRedemptionPrice();

        assertFalse(normalFailure);
        assertFalse(redemptionFailure);
        assertGe(redemptionPrice, normalPrice);
    }

    function test_redemptionReferenceGasGriefingRevertsInsteadOfFallingBack() public {
        GasGriefingChainlinkOracleMock gasOracle = new GasGriefingChainlinkOracleMock();
        gasOracle.setUpdatedAt(block.timestamp);
        DFWstETHPriceFeed feed = _deployWithEthReference(address(gasOracle));

        gasOracle.setShouldConsumeAllGas(true);

        // The protection-only oracle is not consulted by normal pricing.
        (, bool normalFailure) = feed.fetchPrice{gas: 500_000}();
        assertFalse(normalFailure);

        vm.expectRevert(MainnetPriceFeedBase.InsufficientGasForExternalCall.selector);
        feed.fetchRedemptionPrice{gas: 500_000}();
        assertFalse(bo.shutDownCalled());
    }

    // --- dToken backing ratio ---

    function test_backingRatioDiscountsFetchAndRedemptionPrice() public {
        backingVault.setBackingRatio(0.8e18);
        DFWstETHPriceFeed feed = _deploy();

        (uint256 price, bool failure) = feed.fetchPrice();
        (uint256 redemptionPrice, bool redemptionFailure) = feed.fetchRedemptionPrice();

        assertFalse(failure);
        assertFalse(redemptionFailure);
        assertApproxEqRel(price, 432_000e18, 0.001e18); // 540,000 × 0.8
        assertEq(price, redemptionPrice);
        assertEq(feed.lastGoodBacking(), 0.8e18);
    }

    function test_backingRatioAboveOneIsCapped() public {
        DFWstETHPriceFeed feed = _deploy();
        (uint256 basePrice,) = feed.fetchPrice();

        backingVault.setBackingRatio(1.2e18);
        (uint256 cappedPrice, bool failure) = feed.fetchPrice();

        assertFalse(failure);
        assertEq(cappedPrice, basePrice);
        assertEq(feed.lastGoodBacking(), 1e18);
    }

    function test_backingRatioFailureShutsDownAtLastGoodPrice() public {
        backingVault.setBackingRatio(0.8e18);
        DFWstETHPriceFeed feed = _deploy();
        (uint256 discounted,) = feed.fetchPrice();

        backingVault.setBackingRatio(0.5e18);
        backingVault.setShouldRevert(true);
        (uint256 price, bool failure) = feed.fetchPrice();

        assertTrue(failure);
        assertTrue(bo.shutDownCalled());
        assertEq(uint256(feed.priceSource()), uint256(IMainnetPriceFeed.PriceSource.primary));
        assertEq(price, discounted);
        assertEq(feed.lastGoodBacking(), 0.8e18);
    }

    function test_backingValuationUnavailableShutsDownAtLastGoodPrice() public {
        backingVault.setBackingRatio(0.8e18);
        DFWstETHPriceFeed feed = _deploy();
        (uint256 discounted,) = feed.fetchPrice();

        backingVault.setBackingUnavailable(true);
        (uint256 price, bool failure) = feed.fetchPrice();

        assertTrue(failure);
        assertTrue(bo.shutDownCalled());
        assertEq(uint256(feed.priceSource()), uint256(IMainnetPriceFeed.PriceSource.primary));
        assertEq(price, discounted);
        assertEq(feed.lastGoodBacking(), 0.8e18, "unavailable valuation must not overwrite last good backing");
    }

    function test_backingRatioGasGriefing_bubblesInsufficientGas() public {
        backingVault.setBackingRatio(0.8e18);
        DFWstETHPriceFeed feed = _deploy();

        (, bool healthyFailure) = feed.fetchPrice{gas: 500_000}();
        assertFalse(healthyFailure);

        backingVault.setShouldConsumeAllGas(true);

        vm.expectRevert(MainnetPriceFeedBase.InsufficientGasForExternalCall.selector);
        feed.fetchPrice{gas: 500_000}();
        assertEq(uint256(feed.priceSource()), uint256(IMainnetPriceFeed.PriceSource.primary));
        assertFalse(bo.shutDownCalled(), "gas-starved backing read must not shut down branch");
    }

    function test_zeroBackingRatioReturnsNearZeroNonSentinelPrice() public {
        DFWstETHPriceFeed feed = _deploy();

        backingVault.setBackingRatio(0);
        (uint256 price, bool failure) = feed.fetchPrice();

        assertFalse(failure);
        assertGt(price, 0);
        assertLt(price, 1e18);
        assertEq(feed.lastGoodBacking(), 1);
    }

    // --- failure paths → shutdown ---

    function test_stEthUsdStale_shutsDown() public {
        DFWstETHPriceFeed feed = _deploy();
        vm.warp(block.timestamp + 25 hours); // past stETH staleness (24h)
        jpyUsd.setUpdatedAt(block.timestamp); // keep JPY fresh
        (, bool failure) = feed.fetchPrice();
        assertTrue(failure);
        assertTrue(bo.shutDownCalled());
        assertEq(uint256(feed.priceSource()), uint256(IMainnetPriceFeed.PriceSource.primary));
    }

    function test_stEthUsdFutureTimestamp_shutsDown() public {
        DFWstETHPriceFeed feed = _deploy();
        (uint256 goodPrice,) = feed.fetchPrice();

        stEthUsd.setUpdatedAt(block.timestamp + 1);

        (uint256 price, bool failure) = feed.fetchPrice();

        assertTrue(failure);
        assertTrue(bo.shutDownCalled());
        assertEq(uint256(feed.priceSource()), uint256(IMainnetPriceFeed.PriceSource.primary));
        assertEq(price, goodPrice);
    }

    // JPY/USD is a SHARED systemic leg across all branches; a JPY-leg failure must NOT
    // synchronously stop the branch (see JpyFreezeLib / ORCL-SEC-005). The composite
    // feed substitutes the last good JPY rate and keeps operating; the stETH/USD + canonical
    // legs stay live, so only the (low-vol) FX leg is frozen. Auto-recovers when JPY is fresh.
    function test_jpyUsdStale_substitutesLastGoodRate_noShutdown() public {
        DFWstETHPriceFeed feed = _deploy();
        (uint256 goodPrice,) = feed.fetchPrice();

        vm.warp(block.timestamp + 73 hours); // past JPY staleness (72h)
        stEthUsd.setUpdatedAt(block.timestamp); // keep stETH fresh → ONLY the shared JPY leg is stale
        (uint256 price, bool failure) = feed.fetchPrice();
        assertFalse(failure);
        assertFalse(bo.shutDownCalled());
        assertEq(uint256(feed.priceSource()), uint256(IMainnetPriceFeed.PriceSource.primary));
        assertEq(price, goodPrice);
    }

    function test_jpyUsdZeroRoundId_substitutesNoShutdown() public {
        DFWstETHPriceFeed feed = _deploy();
        (uint256 goodPrice,) = feed.fetchPrice();

        jpyUsd.setRoundData(0, 0);

        (uint256 price, bool failure) = feed.fetchPrice();

        assertFalse(failure);
        assertFalse(bo.shutDownCalled());
        assertEq(uint256(feed.priceSource()), uint256(IMainnetPriceFeed.PriceSource.primary));
        assertEq(jpyRateProvider.jpyFrozenSince(), block.timestamp);
        assertEq(price, goodPrice);
    }

    function test_jpyUsdFreeze_tracksLiveStEthAndRateLegs() public {
        DFWstETHPriceFeed feed = _deploy();
        feed.fetchPrice();

        // JPY frozen, but stETH/USD keeps updating (+10%) and the rate accrues.
        vm.warp(block.timestamp + 73 hours);
        stEthUsd.setPrice(3300e8);
        stEthUsd.setUpdatedAt(block.timestamp);
        wstEth.setRate(1.25e18);

        (uint256 price, bool failure) = feed.fetchPrice();
        assertFalse(failure);
        assertFalse(bo.shutDownCalled());
        // 3300 × 1.25 / 0.006667 ≈ 618,719: the live legs ARE reflected mid-freeze.
        assertApproxEqRel(price, 618_750e18, 0.001e18);
    }

    function test_jpyUsdFreeze_thenRecovers_repricesWithLiveRate() public {
        DFWstETHPriceFeed feed = _deploy();
        feed.fetchPrice();

        vm.warp(block.timestamp + 73 hours);
        stEthUsd.setUpdatedAt(block.timestamp);
        feed.fetchPrice();
        assertFalse(bo.shutDownCalled());

        // JPY/USD recovers at ¥200/$ (0.005). Auto-resume on the live rate.
        jpyUsd.setPrice(500_000);
        jpyUsd.setUpdatedAt(block.timestamp);
        (uint256 price, bool failure) = feed.fetchPrice();
        assertFalse(failure);
        assertEq(uint256(feed.priceSource()), uint256(IMainnetPriceFeed.PriceSource.primary));
        // 3000 × 1.2 / 0.005 = 720,000
        assertApproxEqRel(price, 720_000e18, 0.001e18);
    }

    function test_jpyUsdZeroPrice_substitutesNoShutdown() public {
        DFWstETHPriceFeed feed = _deploy();
        (uint256 goodPrice,) = feed.fetchPrice();

        jpyUsd.setPrice(0); // invalid JPY answer → JPY-leg failure
        (uint256 price, bool failure) = feed.fetchPrice();
        assertFalse(failure);
        assertFalse(bo.shutDownCalled());
        assertEq(price, goodPrice);
    }

    function test_jpyInvalidAnswerWhileCachedRateFreshStartsFreezeAtObservation() public {
        DFWstETHPriceFeed feed = _deploy();
        assertEq(jpyRateProvider.lastGoodJpyUpdatedAt(), block.timestamp, "provider stores cached rate provenance");

        vm.warp(block.timestamp + 10 hours);
        stEthUsd.setUpdatedAt(block.timestamp);
        jpyUsd.setUpdatedAt(block.timestamp);
        feed.fetchPrice();
        assertEq(
            jpyRateProvider.lastGoodJpyUpdatedAt(), block.timestamp, "healthy read refreshes cached rate provenance"
        );

        vm.warp(block.timestamp + 10 hours);
        stEthUsd.setUpdatedAt(block.timestamp);
        jpyUsd.setPrice(0);

        (, bool failure) = feed.fetchPrice();

        assertFalse(failure);
        assertFalse(bo.shutDownCalled());
        assertEq(jpyRateProvider.jpyFrozenSince(), block.timestamp);
    }

    function test_jpyInvalidAnswerAfterCachedRateExpiredShutsDownImmediately() public {
        DFWstETHPriceFeed feed = _deploy();
        uint256 expectedFreezeStart = jpyRateProvider.lastGoodJpyUpdatedAt() + JPY_STALENESS;

        vm.warp(expectedFreezeStart + jpyRateProvider.MAX_JPY_FREEZE_DURATION() + 1);
        stEthUsd.setUpdatedAt(block.timestamp);
        jpyUsd.setPrice(0);

        (uint256 price, bool failure) = feed.fetchPrice();

        assertTrue(failure);
        assertTrue(bo.shutDownCalled());
        assertEq(jpyRateProvider.jpyFrozenSince(), expectedFreezeStart);
        assertEq(price, feed.lastGoodPrice());
    }

    function test_stEthUsdStale_duringJpyStale_stillShutsDown() public {
        DFWstETHPriceFeed feed = _deploy();
        feed.fetchPrice();

        // BOTH the stETH/USD (collateral) leg and JPY leg stale: the collateral leg is
        // checked first and still shuts down terminally; the JPY freeze never masks it.
        vm.warp(block.timestamp + 73 hours);
        (, bool failure) = feed.fetchPrice();
        assertTrue(failure);
        assertTrue(bo.shutDownCalled());
        assertEq(uint256(feed.priceSource()), uint256(IMainnetPriceFeed.PriceSource.primary));
    }

    // --- JPY freeze observability ---

    function test_jpyFreeze_setsAndClearsFrozenSince() public {
        DFWstETHPriceFeed feed = _deploy();
        feed.fetchPrice();
        assertEq(jpyRateProvider.jpyFrozenSince(), 0);

        uint256 expectedFreezeStart = block.timestamp + JPY_STALENESS;
        vm.warp(block.timestamp + 73 hours);
        stEthUsd.setUpdatedAt(block.timestamp);
        feed.fetchPrice();
        assertEq(jpyRateProvider.jpyFrozenSince(), expectedFreezeStart);

        jpyUsd.setUpdatedAt(block.timestamp);
        feed.fetchPrice();
        assertEq(jpyRateProvider.jpyFrozenSince(), 0);
    }

    function test_jpyFreeze_emitsFrozenAndUnfrozenEvents() public {
        DFWstETHPriceFeed feed = _deploy();
        feed.fetchPrice();

        uint256 expectedFreezeStart = block.timestamp + JPY_STALENESS;
        vm.warp(block.timestamp + 73 hours);
        stEthUsd.setUpdatedAt(block.timestamp);
        vm.expectEmit(true, true, true, true, address(jpyRateProvider));
        emit JpyUsdRateProvider.JpyRateFrozen(expectedFreezeStart, jpyRateProvider.lastGoodJpyRate());
        feed.fetchPrice();

        jpyUsd.setUpdatedAt(block.timestamp);
        vm.expectEmit(true, true, true, true, address(jpyRateProvider));
        emit JpyUsdRateProvider.JpyRateUnfrozen(block.timestamp, uint256(JPY_USD_8DEC) * 1e10);
        feed.fetchPrice();
    }

    function test_jpyFreezeExpires_shutsDownAtLastGoodPrice() public {
        DFWstETHPriceFeed feed = _deploy();
        feed.fetchPrice();

        vm.warp(block.timestamp + 73 hours);
        stEthUsd.setUpdatedAt(block.timestamp);
        (uint256 frozenPrice, bool freezeFailure) = feed.fetchPrice();
        assertFalse(freezeFailure, "fresh freeze stays live");
        assertFalse(bo.shutDownCalled());

        uint256 freezeStartedAt = jpyRateProvider.jpyFrozenSince();
        vm.warp(freezeStartedAt + jpyRateProvider.MAX_JPY_FREEZE_DURATION());
        stEthUsd.setPrice(3300e8);
        stEthUsd.setUpdatedAt(block.timestamp);

        (uint256 price, bool failure) = feed.fetchPrice();

        assertTrue(failure);
        assertTrue(bo.shutDownCalled());
        assertEq(uint256(feed.priceSource()), uint256(IMainnetPriceFeed.PriceSource.primary));
        assertEq(price, frozenPrice, "expired freeze serves the last bounded-good price");
        assertEq(price, feed.lastGoodPrice());
    }

    function test_jpyStaleBeforeFirstCallPastFreezeWindowShutsDownImmediately() public {
        DFWstETHPriceFeed feed = _deploy();
        uint256 expectedFreezeStart = block.timestamp + JPY_STALENESS;

        vm.warp(expectedFreezeStart + jpyRateProvider.MAX_JPY_FREEZE_DURATION() + 1);
        stEthUsd.setUpdatedAt(block.timestamp);

        (uint256 price, bool failure) = feed.fetchPrice();

        assertTrue(failure);
        assertTrue(bo.shutDownCalled());
        assertEq(uint256(feed.priceSource()), uint256(IMainnetPriceFeed.PriceSource.primary));
        assertEq(jpyRateProvider.jpyFrozenSince(), expectedFreezeStart);
        assertEq(price, feed.lastGoodPrice());
    }

    function test_jpyUsdWeekendCloseWithinThreshold_keepsPrimary() public {
        DFWstETHPriceFeed feed = _deploy();

        // FX weekend behavior: JPY/USD can remain at its last healthy close while
        // the crypto collateral feed keeps updating.
        vm.warp(block.timestamp + 60 hours);
        stEthUsd.setUpdatedAt(block.timestamp);

        (uint256 price, bool failure) = feed.fetchPrice();
        assertFalse(failure);
        assertFalse(bo.shutDownCalled());
        assertEq(uint256(feed.priceSource()), uint256(IMainnetPriceFeed.PriceSource.primary));
        assertApproxEqRel(price, 540_000e18, 0.001e18);
    }

    function test_jpyUsdStalenessBoundary_substitutesNoShutdown() public {
        DFWstETHPriceFeed feed = _deploy();
        feed.fetchPrice();

        // MainnetPriceFeedBase requires age < threshold, so exactly 72h is stale.
        // JPY-only stale at the boundary → substitute, not shutdown.
        vm.warp(block.timestamp + JPY_STALENESS);
        stEthUsd.setUpdatedAt(block.timestamp);

        (, bool failure) = feed.fetchPrice();
        assertFalse(failure);
        assertFalse(bo.shutDownCalled());
    }

    function test_canonicalRateZero_shutsDown() public {
        DFWstETHPriceFeed feed = _deploy();
        wstEth.setRate(0); // stEthPerToken() == 0 → rate down
        (, bool failure) = feed.fetchPrice();
        assertTrue(failure);
        assertTrue(bo.shutDownCalled());
    }

    function test_canonicalRateRevert_shutsDown() public {
        DFWstETHPriceFeed feed = _deploy();
        wstEth.setShouldRevert(true); // stEthPerToken reverts → caught → rate down
        (, bool failure) = feed.fetchPrice();
        assertTrue(failure);
        assertTrue(bo.shutDownCalled());
    }

    function test_stEthUsdZeroPrice_shutsDown() public {
        DFWstETHPriceFeed feed = _deploy();
        stEthUsd.setPrice(0); // invalid
        (, bool failure) = feed.fetchPrice();
        assertTrue(failure);
        assertTrue(bo.shutDownCalled());
    }

    function test_afterOracleRecovery_returnsLivePrice() public {
        DFWstETHPriceFeed feed = _deploy();
        (uint256 good,) = feed.fetchPrice();

        stEthUsd.setPrice(0);
        feed.fetchPrice(); // shutdown
        assertTrue(bo.shutDownCalled());

        stEthUsd.setPrice(3300e8);
        (uint256 price, bool failure) = feed.fetchPrice();
        assertFalse(failure);
        assertGt(price, good);
        assertEq(feed.lastGoodPrice(), price);
    }

    // --- constructor asserts ---

    function test_constructorReverts_ifStEthOracleDeadAtDeploy() public {
        stEthUsd.setPrice(0);
        vm.expectRevert();
        _deploy();
    }

    function test_constructorReverts_ifRedemptionReferenceDeadAtDeploy() public {
        ethUsd.setPrice(0);
        vm.expectRevert(DFWstETHPriceFeed.InvalidInitialPrice.selector);
        _deploy();
    }

    function test_constructorReverts_ifRedemptionReferenceStaleAtDeploy() public {
        vm.warp(block.timestamp + ETH_STALENESS + 1);
        stEthUsd.setUpdatedAt(block.timestamp);
        jpyUsd.setUpdatedAt(block.timestamp);

        vm.expectRevert(DFWstETHPriceFeed.InvalidInitialPrice.selector);
        _deploy();
    }

    function test_constructorReverts_ifStEthEthReferenceDeadAtDeploy() public {
        stEthEth.setPrice(0);
        vm.expectRevert(DFWstETHPriceFeed.InvalidInitialPrice.selector);
        _deploy();
    }

    function test_constructorReverts_ifStEthEthReferenceStaleAtDeploy() public {
        vm.warp(block.timestamp + STETH_ETH_STALENESS + 1);
        stEthUsd.setUpdatedAt(block.timestamp);
        ethUsd.setUpdatedAt(block.timestamp);
        jpyUsd.setUpdatedAt(block.timestamp);

        vm.expectRevert(DFWstETHPriceFeed.InvalidInitialPrice.selector);
        _deploy();
    }

    function test_constructorReverts_ifJpyDecimalsNot8() public {
        jpyUsd.setDecimals(18);
        vm.expectRevert(JpyUsdRateProvider.UnexpectedOracleDecimals.selector);
        new JpyUsdRateProvider(address(jpyUsd), JPY_STALENESS);
    }

    function test_constructorReverts_ifWstEthHasNoCode() public {
        vm.expectRevert(DFWstETHPriceFeed.InvalidRateProvider.selector);
        new DFWstETHPriceFeed(
            address(stEthUsd),
            address(ethUsd),
            address(stEthEth),
            makeAddr("no-code-wsteth"),
            STETH_STALENESS,
            ETH_STALENESS,
            STETH_ETH_STALENESS,
            address(jpyRateProvider),
            address(backingVault),
            address(bo)
        );
    }

    function test_constructorReverts_ifWstEthDecimalsNot18() public {
        wstEth.setDecimals(8);
        vm.expectRevert(DFWstETHPriceFeed.InvalidRateProviderDecimals.selector);
        _deploy();
    }

    function test_constructorReverts_ifWstEthRateZeroAtDeploy() public {
        wstEth.setRate(0);
        vm.expectRevert(DFWstETHPriceFeed.InvalidRateProviderRate.selector);
        _deploy();
    }

    function test_constructorReverts_ifCollateralVaultHasNoCode() public {
        vm.expectRevert(DFWstETHPriceFeed.InvalidCollateralVault.selector);
        new DFWstETHPriceFeed(
            address(stEthUsd),
            address(ethUsd),
            address(stEthEth),
            address(wstEth),
            STETH_STALENESS,
            ETH_STALENESS,
            STETH_ETH_STALENESS,
            address(jpyRateProvider),
            makeAddr("no-code-vault"),
            address(bo)
        );
    }
}
