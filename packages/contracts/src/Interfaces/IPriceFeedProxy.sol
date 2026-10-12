// SPDX-License-Identifier: MIT

pragma solidity ^0.8.0;

import "./IPriceFeed.sol";
import "./IBorrowerOperations.sol";

/**
 * @title IPriceFeedProxy
 * @notice Interface for a swappable-source price feed: a fixed reference address whose
 *         underlying price source is switchable behind a 24h timelock. This is NOT a
 *         UUPS / delegatecall / storage proxy and is not upgradeable in the storage sense.
 *         Extends IPriceFeed (original Liquity interface) with proxy-specific functions.
 * @dev Ownership (2-step) is provided by inheriting OpenZeppelin Ownable2Step in the
 *      implementation. Its functions (owner, pendingOwner, transferOwnership,
 *      acceptOwnership, renounceOwnership) and events (OwnershipTransferred,
 *      OwnershipTransferStarted) appear on the ABI via inheritance. The
 *      implementation disables renounceOwnership to preserve the source-swap
 *      recovery path.
 */
interface IPriceFeedProxy is IPriceFeed {
    // --- Events ---
    event SourceUpdated(address indexed oldSource, address indexed newSource);
    /// @dev oldPrice / oldRedemptionPrice are the healthy old source's live prices, or the
    ///      proxy's path-specific last-good references when oldSourceHealthy is false.
    ///      priceGuardBypassed is true only for an explicit confirmSourceEmergency call.
    event SourceSwitchValidated(
        address indexed oldSource,
        address indexed newSource,
        bool oldSourceHealthy,
        bool priceGuardBypassed,
        uint256 oldPrice,
        uint256 newPrice,
        uint256 oldRedemptionPrice,
        uint256 newRedemptionPrice
    );
    event SourceProposed(address indexed proposedSource, uint256 executableAt);
    event SourceProposalCancelled(address indexed cancelledSource);
    /// @notice Emitted when the proxy's own fail-safe activates: the source reverted, or
    ///         returned an invalid (0/max) or failure-flagged price, so the proxy triggered
    ///         branch shutdown and served a fallback price. Lets monitors detect proxy-level
    ///         oracle-failure handling, not just BorrowerOperations' shutdown event.
    event SourceFailureHandled(address indexed source);

    /// @notice Emitted when borrowerOperations.shutdownFromOracleFailure() reverted inside the
    ///         proxy's fail-safe path. That call reverts only on caller-mismatch (this proxy is
    ///         not the branch's registered priceFeed -- a deploy miswire), since it is a no-op
    ///         when already shut down. The proxy intentionally does NOT propagate the revert
    ///         (that would let one branch DoS the system-wide redemption loop); it serves
    ///         lastGoodPrice and raises this alarm so monitoring can detect a miswired branch.
    event ShutdownCallReverted(address indexed borrowerOperations, address indexed source);

    // --- Errors ---
    error InvalidSource();
    error SameSource();
    error InvalidAddress();
    error NoProposalPending();
    error TimelockNotElapsed();
    error SourcePriceDeviationTooLarge(uint256 oldPrice, uint256 newPrice, uint256 maxDeviationBps);
    error ZeroOwnerAddress();
    error RenounceOwnershipDisabled();

    // --- Views ---
    function source() external view returns (address);
    function proposedSource() external view returns (address);
    function sourceProposedAt() external view returns (uint256);
    function TIMELOCK_DELAY() external view returns (uint256);
    function MAX_SOURCE_SWITCH_DEVIATION_BPS() external view returns (uint256);
    function borrowerOperations() external view returns (IBorrowerOperations);

    // --- Timelocked source switching ---
    function proposeSource(address _newSource) external;
    function confirmSource() external;
    function confirmSourceEmergency() external;
    function cancelSourceProposal() external;
}
