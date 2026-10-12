// SPDX-License-Identifier: MIT

pragma solidity 0.8.24;

import "forge-std/Test.sol";
import "src/Interfaces/IPriceFeed.sol";
import "src/Interfaces/IPriceFeedProxy.sol";
import "src/PriceFeeds/PriceFeedPlaceholder.sol";
import "src/PriceFeeds/PriceFeedProxy.sol";
import "./TestContracts/FreshJpyProvenance.sol";

/// @dev Minimal BorrowerOperations stand-in that records whether the proxy triggered a branch
///      shutdown (mirrors the mock used in PriceFeedProxySourceValidation.t.sol).
contract MockBO {
    address public registeredPriceFeed;
    bool public hasBeenShutDown;
    bool public isOracleFailureShutdown;

    function setRegisteredPriceFeed(address p) external {
        registeredPriceFeed = p;
    }

    function shutdownFromOracleFailure() external {
        require(msg.sender == registeredPriceFeed, "CallerNotPriceFeed");
        hasBeenShutDown = true;
        isOracleFailureShutdown = true;
    }
}

contract MockLivePriceFeed is IPriceFeed, FreshJpyProvenance {
    uint256 public immutable price;

    constructor(uint256 _price) {
        price = _price;
    }

    function fetchPrice() external view returns (uint256, bool) {
        return (price, false);
    }

    function fetchRedemptionPrice() external view returns (uint256, bool) {
        return (price, false);
    }

    function fetchUrgentRedemptionPrice() external view returns (uint256, bool) {
        return (price, false);
    }

    function lastGoodPrice() external view returns (uint256) {
        return price;
    }
}

/// @notice PriceFeedPlaceholder is the Day-1 `source` of a placeholder branch's
///         PriceFeedProxy. CollateralRegistry.redeemCollateral reads EVERY branch's price with no
///         try/catch, so a placeholder feed is read on every redemption even before activation. It
///         must therefore return a price the proxy treats as VALID (so `_isInvalidPrice` is false
///         and `shutdownFromOracleFailure` is never called) and must never revert. These tests pin
///         that behavior — both on the stub directly and through the proxy.
contract PriceFeedPlaceholderTest is Test {
    MockBO bo;
    PriceFeedPlaceholder placeholder;
    address owner = address(this);

    function setUp() public {
        bo = new MockBO();
        placeholder = new PriceFeedPlaceholder();
    }

    // --- the stub itself ---

    function test_sentinelIsNeitherZeroNorMax() public view {
        // PriceFeedProxy._isInvalidPrice(p) == (p == 0 || p == type(uint256).max).
        // The sentinel must avoid both so the proxy does not flag it.
        assertEq(placeholder.SENTINEL_PRICE(), 1e18);
        assertTrue(placeholder.SENTINEL_PRICE() != 0);
        assertTrue(placeholder.SENTINEL_PRICE() != type(uint256).max);
    }

    function test_fetchPrice_returnsSentinelNoFailure() public view {
        (uint256 price, bool oracleFailure) = placeholder.fetchPrice();
        assertEq(price, 1e18);
        assertFalse(oracleFailure);
    }

    function test_fetchRedemptionPrice_returnsSentinelNoFailure() public view {
        (uint256 price, bool oracleFailure) = placeholder.fetchRedemptionPrice();
        assertEq(price, 1e18);
        assertFalse(oracleFailure);
    }

    function test_fetchUrgentRedemptionPrice_returnsSentinelNoFailure() public view {
        (uint256 price, bool oracleFailure) = placeholder.fetchUrgentRedemptionPrice();
        assertEq(price, 1e18);
        assertFalse(oracleFailure);
    }

    function test_lastGoodPrice_returnsSentinel() public view {
        assertEq(placeholder.lastGoodPrice(), 1e18);
    }

    // --- wrapped in a PriceFeedProxy: must not shut the branch down ---

    function _newProxy() internal returns (PriceFeedProxy proxy) {
        // PR #58: a non-contract source is rejected. PriceFeedPlaceholder is a deployed contract,
        // so the proxy accepts it — the whole reason a stub is used instead of address(0).
        proxy = new PriceFeedProxy(address(placeholder), owner, address(bo));
        bo.setRegisteredPriceFeed(address(proxy));
    }

    function test_proxyAcceptsPlaceholderAsSource() public {
        PriceFeedProxy proxy = _newProxy();
        assertEq(proxy.source(), address(placeholder));
    }

    function test_fetchPrice_throughProxy_doesNotShutDown() public {
        PriceFeedProxy proxy = _newProxy();
        (uint256 price, bool oracleFailure) = proxy.fetchPrice();
        assertEq(price, 1e18, "proxy must pass the sentinel through");
        assertFalse(oracleFailure);
        assertFalse(bo.hasBeenShutDown(), "placeholder must not trigger branch shutdown");
    }

    function test_fetchRedemptionPrice_throughProxy_doesNotShutDown() public {
        PriceFeedProxy proxy = _newProxy();
        (uint256 price, bool oracleFailure) = proxy.fetchRedemptionPrice();
        assertEq(price, 1e18);
        assertFalse(oracleFailure);
        assertFalse(bo.hasBeenShutDown(), "placeholder must not trigger branch shutdown");
    }

    function test_fetchUrgentRedemptionPrice_throughProxy_doesNotShutDown() public {
        PriceFeedProxy proxy = _newProxy();
        (uint256 price, bool oracleFailure) = proxy.fetchUrgentRedemptionPrice();
        assertEq(price, 1e18);
        assertFalse(oracleFailure);
        assertFalse(bo.hasBeenShutDown(), "placeholder must not trigger branch shutdown");
    }

    function test_repeatedRedemptionScans_neverShutDown() public {
        // Emulates CollateralRegistry scanning the placeholder branch's price across many
        // redemptions before Day-2 activation. The branch must stay live throughout.
        PriceFeedProxy proxy = _newProxy();
        for (uint256 i = 0; i < 5; i++) {
            proxy.fetchPrice();
            proxy.fetchRedemptionPrice();
        }
        assertFalse(bo.hasBeenShutDown(), "placeholder must remain non-shutdown across scans");
    }

    function test_activationToRealFeedRequiresEmergencyWhenPriceGuardExceeded() public {
        PriceFeedProxy proxy = _newProxy();
        MockLivePriceFeed realFeed = new MockLivePriceFeed(150_000e18);

        proxy.proposeSource(address(realFeed));
        vm.warp(block.timestamp + proxy.TIMELOCK_DELAY());

        vm.expectRevert(
            abi.encodeWithSelector(
                IPriceFeedProxy.SourcePriceDeviationTooLarge.selector,
                1e18,
                150_000e18,
                proxy.MAX_SOURCE_SWITCH_DEVIATION_BPS()
            )
        );
        proxy.confirmSource();

        assertEq(proxy.source(), address(placeholder), "normal confirm must leave placeholder source");

        proxy.confirmSourceEmergency();

        assertEq(proxy.source(), address(realFeed), "emergency confirm must switch to real feed");
        (uint256 price, bool oracleFailure) = proxy.fetchPrice();
        assertEq(price, 150_000e18);
        assertFalse(oracleFailure);
        assertFalse(bo.hasBeenShutDown(), "validated real feed must not trigger shutdown");
    }
}
