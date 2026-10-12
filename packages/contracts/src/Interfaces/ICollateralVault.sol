// SPDX-License-Identifier: MIT

pragma solidity ^0.8.0;

import "openzeppelin-contracts/contracts/token/ERC20/IERC20.sol";
import "./IDToken.sol";
import "./IStrategy.sol";

/**
 * @title ICollateralVault - Collateral custody, redemption & yield-allocation interface (push model)
 * @notice Full push-model surface: the dToken入出金 core (deposit / redeem /
 *         redeemWithPermit / claim, buffer + withdraw config, pause) PLUS the
 *         Strategy / yield layer added in Phase 3b (allocate /
 *         receiveFromStrategy / transferYieldToTreasury / strategy whitelist +
 *         CRUD / writeoff / allocation pause / strategy views). The
 *         deferred-underlying binding for placeholder branches
 *         (`setUnderlying` + `UnderlyingSet`) is part of this interface.
 * @dev    `StrategyConfig` carries no `isAsyncWithdraw`: synchronous vs.
 *         asynchronous handling is encapsulated inside each Strategy
 *         implementation (push model). The Vault reserves the push-model
 *         storage layout from Phase 3a, so the Phase 3b surface below is
 *         purely additive.
 */
interface ICollateralVault {
    // --- Structs ---

    /// @notice Per-Strategy configuration (push model).
    struct StrategyConfig {
        bool enabled;
        uint256 weightBps;
        uint256 cap;
    }

    /// @notice Fail-soft per-Strategy monitoring snapshot.
    struct StrategyStatus {
        IStrategy strategy;
        StrategyConfig config;
        uint256 estimatedUnderlying;
        uint256 principal;
        uint256 conservativeValue;
        uint256 cachedConservativeValue;
        uint256 cacheUpdatedAt;
        uint256 estimatedGain;
        uint256 estimatedLoss;
        uint256 capRemaining;
        bool estimateAvailable;
        bool principalAvailable;
        bool usingCachedConservativeValue;
        bool cacheAvailable;
        bool cacheStale;
    }

    /// @notice Last successful per-Strategy conservative valuation snapshot.
    struct StrategyValuationCache {
        uint256 conservativeValue;
        uint256 updatedAt;
        bool initialized;
    }

    struct WithdrawRequest {
        address owner;
        uint256 underlyingAmount;
        uint256 claimableAt;
        bool claimed;
    }

    // --- Events (dToken portion) ---

    event Deposited(address indexed user, uint256 underlyingAmount, uint256 dTokenAmount);
    event Redeemed(
        address indexed user,
        address indexed receiver,
        uint256 dTokenAmount,
        uint256 underlyingPaidNow,
        uint256 requestId
    );
    event WithdrawRequested(
        address indexed user, address indexed receiver, uint256 requestId, uint256 amount, uint256 claimableAt
    );
    event WithdrawClaimed(address indexed user, uint256 requestId, uint256 amount);

    event DepositPaused();
    event DepositUnpaused();
    event RedeemPaused();
    event RedeemUnpaused();
    event ClaimPaused();
    event ClaimUnpaused();

    /// @notice Emitted once when a placeholder Vault's underlying is bound via `setUnderlying`.
    event UnderlyingSet(address indexed underlying);

    // --- Events (Strategy / yield layer) ---

    event StrategyWhitelisted(address indexed strategy);
    event StrategyRemovedFromWhitelist(address indexed strategy);
    event StrategyAdded(address indexed strategy, uint256 weightBps, uint256 cap);
    event StrategyUpdated(address indexed strategy, uint256 weightBps, uint256 cap, bool enabled);
    event StrategyEmergencyDisabled(address indexed strategy, uint256 oldWeightBps);
    event StrategyRemoved(address indexed strategy);
    event StrategyPrincipalWrittenOff(address indexed strategy, uint256 amount);
    event MorphoV2ForceDeallocated(
        address indexed strategy,
        address indexed adapter,
        uint256 assets,
        uint256 penaltyShares,
        uint256 penaltyAssets,
        uint256 valuationLossAssets,
        uint256 backingRatioAfter
    );
    event StrategyValuationMaxAgeUpdated(uint256 oldMaxAge, uint256 newMaxAge);
    event StrategyValuationRefreshed(
        address indexed strategy, uint256 estimatedUnderlying, uint256 principal, uint256 conservativeValue
    );
    event StrategyValuationRefreshFailed(address indexed strategy, bool estimateAvailable, bool principalAvailable);
    event StrategyValuationCacheReduced(address indexed strategy, uint256 oldValue, uint256 newValue, uint256 amount);
    event StrategyValuationCacheInvalidated(address indexed strategy, uint256 oldValue, uint256 oldUpdatedAt);

    event Allocated(uint256 bufferBefore, uint256 targetBuffer, uint256 bufferAfter);
    event StrategyAllocated(address indexed strategy, uint256 amount);
    event StrategyAllocationSkipped(address indexed strategy);
    event ReceivedFromStrategy(address indexed strategy, uint256 declaredAmount, uint256 received);
    event YieldTransferredToTreasury(uint256 amount, address indexed treasury);
    event BackstopDeposited(address indexed backstop, uint256 declaredAmount, uint256 received);
    event BackstopReleased(address indexed caller, uint256 amount);

    event AllocationPaused();
    event AllocationUnpaused();
    event BufferConfigUpdated(uint256 oldTargetBps, uint256 newTargetBps, uint256 oldFloor, uint256 newFloor);
    event AllocatorConfigUpdated(uint256 oldMaxMove, uint256 newMaxMove, uint256 oldCooldown, uint256 newCooldown);
    event WithdrawDelayUpdated(uint256 oldDelay, uint256 newDelay);
    event TreasuryUpdated(address indexed oldTreasury, address indexed newTreasury);

    // --- View Functions ---

    function underlying() external view returns (IERC20);
    function dToken() external view returns (IDToken);
    function treasury() external view returns (address);
    function bufferBalance() external view returns (uint256);
    function backstopBalance() external view returns (uint256);
    function totalUnderlying() external view returns (uint256);
    function bufferTargetBps() external view returns (uint256);
    function bufferFloor() external view returns (uint256);
    function pausedDeposit() external view returns (bool);
    function pausedRedeem() external view returns (bool);
    function pausedClaim() external view returns (bool);
    function pausedAllocation() external view returns (bool);
    function pendingWithdrawals() external view returns (uint256);
    function strategyValuationMaxAge() external view returns (uint256);
    function strategyValuationCaches(IStrategy _strategy)
        external
        view
        returns (uint256 conservativeValue, uint256 updatedAt, bool initialized);
    function actualLiabilities() external view returns (uint256);
    function backingRatio() external view returns (uint256);
    /// @notice Backing ratio for price-feed consumption, with valuation availability.
    /// @dev `available == false` means at least one registered Strategy had
    ///      neither a live valuation nor a fresh cache. Feeds must treat this as
    ///      oracle failure, not as a measured total loss.
    function backingRatioForPricing() external view returns (uint256 ratio, bool available);

    // --- User Functions ---

    function deposit(uint256 _underlyingAmount) external returns (uint256 dTokenAmount);

    /// @notice Burn dToken and pay Underlying to `_receiver` immediately or by
    ///         delayed request. `underlyingReceived` is the receiver's measured
    ///         immediate balance increase, not the nominal transfer argument.
    function redeem(uint256 _dTokenAmount, address _receiver)
        external
        returns (uint256 underlyingReceived, uint256 requestId);

    function redeemWithPermit(
        uint256 _dTokenAmount,
        uint256 _deadline,
        uint8 _v,
        bytes32 _r,
        bytes32 _s,
        address _receiver
    ) external returns (uint256 underlyingReceived, uint256 requestId);

    /// @notice Settle a matured withdrawal request to its recorded owner.
    /// @dev Anyone may trigger settlement, but the caller cannot redirect the payment.
    ///      Returns zero without another transfer when the request is already settled.
    function claim(uint256 _requestId) external returns (uint256 underlyingClaimed);

    /// @notice Add underlying to the Vault's protected backstop reserve without minting dToken.
    /// @dev Intended for Treasury / insurance / backstop repair. The credited
    ///      amount is measured by balance diff, matching `receiveFromStrategy`,
    ///      and is reserved from `bufferBalance()` until GOV releases it.
    function backstopDeposit(uint256 _underlyingAmount) external returns (uint256 received);

    /// @notice Release reserved backstop underlying into the liquid redemption buffer. GOV_ROLE.
    /// @dev No asset transfer occurs; this only moves accounting from
    ///      `backstopBalance()` to `bufferBalance()` after an explicit repair
    ///      decision.
    function releaseBackstopToBuffer(uint256 _amount) external returns (uint256 released);

    // --- Deferred-binding Activation ---

    /// @notice Bind a placeholder Vault's underlying once. GOV_ROLE.
    /// @dev Requires `dToken.underlying() == _underlying` (dToken-first ordering).
    function setUnderlying(IERC20 _underlying) external;

    // --- Allocator Functions ---

    /// @notice Allocate buffer excess to strategies. ALLOCATOR_ROLE.
    /// @dev    Deallocation (the "amount-specified push") lives on the Strategy
    ///         side as `Strategy.sendToVault(uint256)`; the ALLOCATOR calls that
    ///         directly. There is no `deallocate` here.
    function allocate() external;

    // --- Strategy → Vault Push (called by a registered Strategy) ---

    /// @notice Receive underlying pushed from a registered Strategy. Pulls
    ///         `_declaredAmount` from the caller via `safeTransferFrom` and
    ///         credits the Vault buffer; the actual amount is measured by the
    ///         Vault balance diff (so fee-on-transfer underlyings are accounted
    ///         by real receipt). The Vault does not distinguish principal from
    ///         yield here — use `transferYieldToTreasury` for the surplus. A
    ///         declared/received mismatch invalidates the Strategy valuation
    ///         cache instead of preserving an ambiguous fallback value.
    function receiveFromStrategy(uint256 _declaredAmount) external returns (uint256 received);

    // --- Yield / Treasury Functions ---

    /// @notice Send the managed-asset surplus over current liabilities to the treasury.
    ///         ALLOCATOR_ROLE. Computes
    ///         `managedUnderlying - (dToken backing + pendingWithdrawals)` using the
    ///         liquid buffer plus conservative per-Strategy view
    ///         `min(estimatedTotalUnderlying, principal)`, explicitly excluding
    ///         protected backstop reserve and capping at the current buffer above
    ///         the same liquidity reserve kept by `allocate`
    ///         (`max(managedUnderlying * bufferTargetBps / 10000, bufferFloor) +
    ///         pendingWithdrawals`).
    function transferYieldToTreasury() external returns (uint256 transferred);

    // --- Governance Functions (Strategy layer) ---

    function addToWhitelist(address _strategy) external;
    /// @notice Remove a strategy from the allowlist. If the strategy is already
    ///         registered, this also disables future allocation to it.
    function removeFromWhitelist(address _strategy) external;
    function addStrategy(IStrategy _strategy, uint256 _weightBps, uint256 _cap) external;
    function updateStrategy(IStrategy _strategy, uint256 _weightBps, uint256 _cap, bool _enabled) external;
    function emergencyDisableStrategy(IStrategy _strategy) external;

    /// @notice Remove a Strategy from registration. Requires the Strategy's
    ///         `principal()` and live `estimatedTotalUnderlying()` to both be
    ///         readable and zero (drain via `Strategy.sendToVault` first, or
    ///         `writeoffStrategyPrincipal` for a permanent loss).
    function removeStrategy(IStrategy _strategy) external;

    /// @notice Acknowledge a permanent loss of principal on a Strategy so that
    ///         `removeStrategy` can later succeed.
    /// @dev Requires the Strategy to be disabled, or allocation to be paused,
    ///      before live principal can be written off. Reverts if the post-writeoff
    ///      `backingRatio()` would be below `_minBackingRatioAfter`; callers should
    ///      set this from an incident dry-run to prevent over-markdown / state drift.
    function writeoffStrategyPrincipal(IStrategy _strategy, uint256 _amount, uint256 _minBackingRatioAfter) external;

    /// @notice Realize a bounded Morpho V2 force-deallocation penalty through
    ///         the Vault incident rails. WRITEOFF_ROLE only.
    /// @dev Atomically pauses allocation and user Vault flows, calls the
    ///      registered Strategy, refreshes/reduces its valuation cache, and
    ///      reverts the whole transaction if post-loss backing is below the
    ///      caller-provided floor.
    function forceDeallocateMorphoV2(
        IStrategy _strategy,
        address _adapter,
        bytes calldata _data,
        uint256 _assets,
        uint256 _minBackingRatioAfter
    ) external returns (uint256 penaltyShares, uint256 penaltyAssets, uint256 valuationLossAssets);

    function setAllocatorConfig(uint256 _maxMove, uint256 _cooldown) external;
    function setStrategyValuationMaxAge(uint256 _maxAge) external;
    function refreshStrategyValuation(IStrategy _strategy) external returns (bool refreshed);
    /// @notice Drop a Strategy's fallback valuation cache. GOV_ROLE, or WRITEOFF_ROLE after allocation is paused
    ///         or the Strategy is disabled.
    /// @dev Incident response path for stale cache removal when live Strategy
    ///      valuation is unavailable. This can only make solvency views more
    ///      conservative until a fresh live valuation succeeds.
    function invalidateStrategyValuationCache(IStrategy _strategy) external;

    // --- Governance Functions (dToken portion) ---

    function setBufferConfig(uint256 _targetBps, uint256 _floor) external;
    function setWithdrawDelay(uint256 _delay) external;
    function setTreasury(address _treasury) external;
    function pauseDeposit() external;
    function unpauseDeposit() external;
    function pauseRedeem() external;
    function unpauseRedeem() external;
    function pauseClaim() external;
    function unpauseClaim() external;
    function pauseAllocation() external;
    function unpauseAllocation() external;

    // --- Strategy Management View Functions ---

    function MAX_STRATEGIES() external view returns (uint256);
    function getStrategiesCount() external view returns (uint256);
    function strategies(uint256 index) external view returns (IStrategy);
    function strategyConfigs(IStrategy strategy) external view returns (bool enabled, uint256 weightBps, uint256 cap);
}
