// SPDX-License-Identifier: MIT

pragma solidity 0.8.24;

import "forge-std/Test.sol";
import "src/PriceFeeds/PriceFeedProxy.sol";
import "src/Interfaces/IPriceFeed.sol";
import "src/Interfaces/IPriceFeedProxy.sol";
import "./TestContracts/FreshJpyProvenance.sol";

// Conforming, deployed price feed (has code + implements IPriceFeed).
contract ValidFeed is IPriceFeed, FreshJpyProvenance {
    uint256 public lastGoodPrice;

    constructor(uint256 price_) {
        lastGoodPrice = price_;
    }

    function fetchPrice() external view returns (uint256, bool) {
        return (lastGoodPrice, false);
    }

    function fetchRedemptionPrice() external view returns (uint256, bool) {
        return (lastGoodPrice, false);
    }

    function fetchUrgentRedemptionPrice() external view returns (uint256, bool) {
        return (lastGoodPrice, false);
    }
}

// Deployed feed whose cache-backed fetches revert while its cache-free urgent path is healthy.
// The proxy may accept this source because normal/redemption can serve lastGoodPrice at runtime.
contract RevertingFeed is IPriceFeed, FreshJpyProvenance {
    uint256 public lastGoodPrice = 100_000e18;

    function fetchPrice() external pure returns (uint256, bool) {
        revert("bricked");
    }

    function fetchRedemptionPrice() external pure returns (uint256, bool) {
        revert("bricked");
    }

    function fetchUrgentRedemptionPrice() external view returns (uint256, bool) {
        return (lastGoodPrice, false);
    }
}

contract MockBO {
    address public registeredPriceFeed;
    bool public hasBeenShutDown;

    function setRegisteredPriceFeed(address p) external {
        registeredPriceFeed = p;
    }

    function shutdownFromOracleFailure() external {
        require(msg.sender == registeredPriceFeed, "CallerNotPriceFeed");
        hasBeenShutDown = true;
    }
}

/// @notice Verifies PriceFeedProxy rejects non-contract and nested Proxy sources at every set
///         point (constructor / proposeSource / confirmation). A non-contract source would make
///         fetchPrice()/fetchRedemptionPrice() revert uncatchably; nested proxies can be linked
///         into a recursive cycle. Either configuration can DoS all redemptions.
contract PriceFeedProxySourceValidationTest is Test {
    using stdStorage for StdStorage;

    MockBO bo;
    ValidFeed validFeed;
    address owner = address(this);

    function setUp() public {
        bo = new MockBO();
        validFeed = new ValidFeed(100_000e18);
    }

    // --- constructor ---

    function test_constructor_revertsOnZeroSource() public {
        vm.expectRevert(IPriceFeedProxy.InvalidSource.selector);
        new PriceFeedProxy(address(0), owner, address(bo));
    }

    function test_constructor_revertsOnEOASource() public {
        address eoa = makeAddr("eoa"); // no code
        vm.expectRevert(IPriceFeedProxy.InvalidSource.selector);
        new PriceFeedProxy(eoa, owner, address(bo));
    }

    function test_constructor_succeedsOnContractSource() public {
        PriceFeedProxy proxy = new PriceFeedProxy(address(validFeed), owner, address(bo));
        assertEq(proxy.source(), address(validFeed));
    }

    function test_constructor_revertsOnPriceFeedProxySource() public {
        PriceFeedProxy sourceProxy = new PriceFeedProxy(address(validFeed), owner, address(bo));

        vm.expectRevert(IPriceFeedProxy.InvalidSource.selector);
        new PriceFeedProxy(address(sourceProxy), owner, address(bo));
    }

    // --- proposeSource ---

    function test_proposeSource_revertsOnZeroSource() public {
        PriceFeedProxy proxy = new PriceFeedProxy(address(validFeed), owner, address(bo));
        vm.expectRevert(IPriceFeedProxy.InvalidSource.selector);
        proxy.proposeSource(address(0));
    }

    function test_proposeSource_revertsOnEOASource() public {
        PriceFeedProxy proxy = new PriceFeedProxy(address(validFeed), owner, address(bo));
        vm.expectRevert(IPriceFeedProxy.InvalidSource.selector);
        proxy.proposeSource(makeAddr("eoa2"));
    }

    function test_proposeSource_revertsOnSelf() public {
        PriceFeedProxy proxy = new PriceFeedProxy(address(validFeed), owner, address(bo));
        vm.expectRevert(IPriceFeedProxy.InvalidSource.selector);
        proxy.proposeSource(address(proxy));
    }

    function test_proposeSource_revertsOnAnotherPriceFeedProxy() public {
        PriceFeedProxy proxy = new PriceFeedProxy(address(validFeed), owner, address(bo));
        PriceFeedProxy otherProxy = new PriceFeedProxy(address(validFeed), owner, address(bo));

        vm.expectRevert(IPriceFeedProxy.InvalidSource.selector);
        proxy.proposeSource(address(otherProxy));
    }

    function test_confirmSource_rechecksAndRejectsInjectedPriceFeedProxy() public {
        PriceFeedProxy proxy = new PriceFeedProxy(address(validFeed), owner, address(bo));
        PriceFeedProxy otherProxy = new PriceFeedProxy(address(validFeed), owner, address(bo));
        ValidFeed proposedFeed = new ValidFeed(99_000e18);

        proxy.proposeSource(address(proposedFeed));
        stdstore.target(address(proxy)).sig(IPriceFeedProxy.proposedSource.selector).checked_write(address(otherProxy));
        vm.warp(block.timestamp + proxy.TIMELOCK_DELAY());

        vm.expectRevert(IPriceFeedProxy.InvalidSource.selector);
        proxy.confirmSource();
        vm.expectRevert(IPriceFeedProxy.InvalidSource.selector);
        proxy.confirmSourceEmergency();

        assertEq(proxy.source(), address(validFeed));
        assertEq(proxy.proposedSource(), address(otherProxy));
    }

    // --- proposeSource -> timelock -> confirmSource happy path ---

    function test_proposeThenConfirm_succeedsForContractSource() public {
        PriceFeedProxy proxy = new PriceFeedProxy(address(validFeed), owner, address(bo));
        ValidFeed newFeed = new ValidFeed(99_000e18);

        proxy.proposeSource(address(newFeed));
        vm.warp(block.timestamp + proxy.TIMELOCK_DELAY());
        proxy.confirmSource();

        assertEq(proxy.source(), address(newFeed));
    }

    // --- rationale: cache-backed paths may revert when the urgent path is healthy ---

    function test_revertingButDeployedSource_isAllowed_andFetchDoesNotRevert() public {
        RevertingFeed rf = new RevertingFeed();
        PriceFeedProxy proxy = new PriceFeedProxy(address(rf), owner, address(bo));
        bo.setRegisteredPriceFeed(address(proxy));

        // fetchPrice() does not revert: the proxy catches the source revert and returns
        // lastGoodPrice with failure = true. The healthy urgent path passed construction.
        (uint256 price, bool failure) = proxy.fetchPrice();
        assertEq(price, rf.lastGoodPrice());
        assertTrue(failure);
    }
}
