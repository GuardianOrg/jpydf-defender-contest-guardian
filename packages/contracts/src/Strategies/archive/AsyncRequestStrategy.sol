// SPDX-License-Identifier: BUSL-1.1

pragma solidity 0.8.24;

/**
 * @dev ARCHIVED — `AsyncRequestStrategy`, the shared async request accounting base.
 *
 * Status: Archived / Out of Day-1 scope.
 *
 * Reason: this base has no remaining consumer. Its only subclasses were
 * `LidoStrategy` and `EtherfiWeETHStrategy`, which are archived alongside it.
 * Every active strategy (`AaveV3Strategy`, `ERC4626Strategy`, `MorphoV2Strategy`,
 * `SkyUsdcSUsdsStrategy`) derives from `BaseStrategy` directly, and Morpho Vaults
 * V2 is fully synchronous, so no active venue needs async request accounting.
 *
 * Audit status: this source was in scope for, and covered by, the external audit
 * completed 2026-08-05 against audited identity `0c7766e0`. It is preserved here
 * unmodified so that audit result is not discarded. It is out of the ACTIVE audit
 * scope from this commit onward; see
 * `documents/en/engineering/guides/Contract-Audit-Scope-And-nSLOC.md`.
 *
 * Re-activation requires a new async venue proposal, re-entry into the
 * `DeployLiquity2` strategy selector, and a fresh activation + audit-scope package.
 */

import "openzeppelin-contracts/contracts/utils/math/Math.sol";

import "../BaseStrategy.sol";
import "../../Interfaces/ICollateralVault.sol";

/**
 * @title AsyncRequestStrategy - Shared base for async WETH Strategy adapters.
 * @notice Tracks protocol withdrawal requests and claim-settled idle underlying
 *         for strategies whose upstream position cannot be synchronously
 *         withdrawn into the Vault.
 * @dev    Derived contracts remain responsible for protocol-specific request
 *         creation, claim calls, and staked-position valuation. This base only
 *         centralizes common accounting for:
 *         - pending request IDs and their underlying-denominated value
 *         - claimed idle underlying produced by this Strategy's own requests
 */
abstract contract AsyncRequestStrategy is BaseStrategy {
    uint256 public constant MAX_ASYNC_REQUESTS_PER_CLAIM = 32;
    uint256 public constant MAX_ASYNC_PENDING_REQUESTS = 128;
    uint256 internal constant _BPS_DENOMINATOR = 10_000;
    bytes32 internal constant _WRITEOFF_ROLE = keccak256("WRITEOFF_ROLE");

    // =============================================================
    //                         STATE
    // =============================================================

    /// @notice Claimed underlying produced by this Strategy's own async claims
    ///         and not yet pushed to the Vault.
    uint256 internal _ownIdleUnderlying;

    /// @notice Total underlying-denominated value requested upstream and not
    ///         yet claimed back into this Strategy.
    uint256 public pendingWithdrawAmount;

    mapping(uint256 => uint256) public pendingWithdrawalAmountByRequestId;
    mapping(uint256 => uint256) internal _pendingRequestIndexPlusOne;
    uint256[] internal _pendingRequestIds;

    /// @dev Valuation multiplier for pending async withdrawals.
    /// @dev Defaults to 10000 bps on fresh initialization. WRITEOFF_ROLE may adjust it
    ///      during protocol incidents to discount or restore pending value before claim.
    uint256 private _pendingWithdrawalValuationBps;

    /// @notice Whether pending withdrawal valuation bps has been initialized or set.
    /// @dev Unconfigured upgraded proxies use 10000 bps as an effective default.
    bool public pendingWithdrawalValuationBpsConfigured;

    /// @dev Storage gap for future upgrades of this intermediate base.
    uint256[43] private __gapAsyncRequest;

    // =============================================================
    //                          EVENTS
    // =============================================================

    event OwnIdleUnderlyingUpdated(uint256 ownIdleUnderlying);
    event PendingWithdrawalValuationBpsUpdated(uint256 oldBps, uint256 newBps);

    // =============================================================
    //                          ERRORS
    // =============================================================

    error UnknownRequest();
    error DuplicateRequest();
    error AsyncRequestClaimTooLarge(uint256 requestCount, uint256 maxRequestCount);
    error AsyncPendingRequestLimitExceeded(uint256 pendingCount, uint256 requestCount, uint256 maxPendingCount);
    error InvalidPendingWithdrawalValuationBps(uint256 bps);
    error PendingWithdrawalValuationNotPaused();

    // =============================================================
    //                      INITIALIZER
    // =============================================================

    function __AsyncRequestStrategy_init() internal onlyInitializing {
        _pendingWithdrawalValuationBps = _BPS_DENOMINATOR;
        pendingWithdrawalValuationBpsConfigured = true;
    }

    // =============================================================
    //                         MUTATORS
    // =============================================================

    function setPendingWithdrawalValuationBps(uint256 _valuationBps) external onlyVaultRole(_WRITEOFF_ROLE) {
        if (_valuationBps > _BPS_DENOMINATOR) revert InvalidPendingWithdrawalValuationBps(_valuationBps);

        uint256 oldBps = pendingWithdrawalValuationBps();
        if (_valuationBps < oldBps && !ICollateralVault(vault).pausedAllocation()) {
            revert PendingWithdrawalValuationNotPaused();
        }

        _pendingWithdrawalValuationBps = _valuationBps;
        pendingWithdrawalValuationBpsConfigured = true;
        emit PendingWithdrawalValuationBpsUpdated(oldBps, _valuationBps);
    }

    // =============================================================
    //                           VIEWS
    // =============================================================

    function ownIdleUnderlying() external view returns (uint256) {
        return _ownIdleUnderlying;
    }

    function pendingWithdrawalValuationBps() public view returns (uint256) {
        return pendingWithdrawalValuationBpsConfigured ? _pendingWithdrawalValuationBps : _BPS_DENOMINATOR;
    }

    function pendingRequestCount() external view returns (uint256) {
        return _pendingRequestIds.length;
    }

    function getPendingRequestIds() external view returns (uint256[] memory requestIds) {
        requestIds = _pendingRequestIds;
    }

    // =============================================================
    //                       INTERNAL HELPERS
    // =============================================================

    function _addPendingRequest(uint256 _requestId, uint256 _amount) internal {
        if (_pendingRequestIndexPlusOne[_requestId] != 0) revert DuplicateRequest();
        _requireAsyncPendingRequestCapacity(1);

        _pendingRequestIds.push(_requestId);
        _pendingRequestIndexPlusOne[_requestId] = _pendingRequestIds.length;
        pendingWithdrawalAmountByRequestId[_requestId] = _amount;
        pendingWithdrawAmount += _amount;
    }

    function _removePendingRequest(uint256 _requestId) internal returns (uint256 amount) {
        uint256 indexPlusOne = _pendingRequestIndexPlusOne[_requestId];
        if (indexPlusOne == 0) revert UnknownRequest();

        amount = pendingWithdrawalAmountByRequestId[_requestId];

        uint256 index = indexPlusOne - 1;
        uint256 lastIndex = _pendingRequestIds.length - 1;
        if (index != lastIndex) {
            uint256 lastRequestId = _pendingRequestIds[lastIndex];
            _pendingRequestIds[index] = lastRequestId;
            _pendingRequestIndexPlusOne[lastRequestId] = indexPlusOne;
        }

        _pendingRequestIds.pop();
        delete _pendingRequestIndexPlusOne[_requestId];
        delete pendingWithdrawalAmountByRequestId[_requestId];

        uint256 currentPendingAmount = pendingWithdrawAmount;
        pendingWithdrawAmount = amount > currentPendingAmount ? 0 : currentPendingAmount - amount;
    }

    function _requireAsyncClaimRequestCount(uint256 _requestCount) internal pure {
        if (_requestCount > MAX_ASYNC_REQUESTS_PER_CLAIM) {
            revert AsyncRequestClaimTooLarge(_requestCount, MAX_ASYNC_REQUESTS_PER_CLAIM);
        }
    }

    function _requireAsyncPendingRequestCapacity(uint256 _requestCount) internal view {
        uint256 pendingCount = _pendingRequestIds.length;
        if (pendingCount + _requestCount > MAX_ASYNC_PENDING_REQUESTS) {
            revert AsyncPendingRequestLimitExceeded(pendingCount, _requestCount, MAX_ASYNC_PENDING_REQUESTS);
        }
    }

    function _increaseOwnIdleUnderlying(uint256 _amount) internal {
        if (_amount == 0) return;

        _ownIdleUnderlying += _amount;
        emit OwnIdleUnderlyingUpdated(_ownIdleUnderlying);
    }

    function _decreaseOwnIdleUnderlying(uint256 _amount) internal {
        if (_amount == 0) return;

        uint256 trackedOwnIdleUnderlying = _ownIdleUnderlying;
        _ownIdleUnderlying = _amount > trackedOwnIdleUnderlying ? 0 : trackedOwnIdleUnderlying - _amount;
        emit OwnIdleUnderlyingUpdated(_ownIdleUnderlying);
    }

    function _takeOwnIdleUnderlying(uint256 _amount) internal returns (uint256 actual) {
        uint256 idleUnderlying = _ownedIdleUnderlyingValue();
        actual = _amount < idleUnderlying ? _amount : idleUnderlying;
        _decreaseOwnIdleUnderlying(actual);
    }

    function _afterEmergencyUnderlyingSent(uint256 _amount, uint256) internal virtual override {
        _decreaseOwnIdleUnderlying(_amount);
    }

    function _ownedIdleUnderlyingValue() internal view returns (uint256) {
        uint256 currentUnderlyingBalance = underlyingToken.balanceOf(address(this));
        return _ownIdleUnderlying < currentUnderlyingBalance ? _ownIdleUnderlying : currentUnderlyingBalance;
    }

    function _pendingWithdrawalValuation() internal view returns (uint256) {
        return Math.mulDiv(pendingWithdrawAmount, pendingWithdrawalValuationBps(), _BPS_DENOMINATOR);
    }
}
