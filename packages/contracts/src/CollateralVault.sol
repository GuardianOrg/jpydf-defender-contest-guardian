// SPDX-License-Identifier: BUSL-1.1

pragma solidity 0.8.24;

import "openzeppelin-contracts/contracts/token/ERC20/utils/SafeERC20.sol";
import "openzeppelin-contracts/contracts/token/ERC20/IERC20.sol";
import "openzeppelin-contracts/contracts/utils/math/Math.sol";
import "openzeppelin-contracts-upgradeable/security/ReentrancyGuardUpgradeable.sol";
import "openzeppelin-contracts-upgradeable/access/AccessControlUpgradeable.sol";
import "openzeppelin-contracts-upgradeable/proxy/utils/Initializable.sol";
import "openzeppelin-contracts-upgradeable/proxy/utils/UUPSUpgradeable.sol";

import "./Interfaces/IDToken.sol";
import "./Interfaces/IStrategy.sol";
import "./Interfaces/ICollateralVault.sol";

/// @dev Morpho V2 incident surface called only through this Vault. Keeping the
///      concrete interface local avoids widening the common `IStrategy` ABI.
interface IMorphoV2IncidentStrategy {
    function forceDeallocate(address _adapter, bytes calldata _data, uint256 _assets)
        external
        returns (uint256 penaltyShares, uint256 penaltyAssets, uint256 valuationLossAssets, uint256 withdrawnAssets);
}

/**
 * @title CollateralVault - Push-model collateral custody and yield Vault (Upgradeable)
 * @notice One Vault per collateral asset. Custodies the Underlying, mints/burns
 *         the corresponding dToken 1:1 (decimals-adjusted), serves redemptions
 *         from a liquid buffer with a delayed-claim fallback, allocates buffer
 *         excess to whitelisted Strategies, receives principal-return push-back
 *         through `receiveFromStrategy`, and lets Strategies push yield directly
 *         into the buffer without reducing principal valuation caches.
 *         Backstop repair funds are tracked as a separate reserve and are not
 *         spendable by redeem / claim until GOV releases them to the buffer.
 *         Accumulated yield is moved to the treasury address via
 *         `transferYieldToTreasury`.
 *
 * @dev    Built in two layers over one reserved storage layout:
 *           - dToken portion (Phase 3a): deposit / redeem / redeemWithPermit /
 *             claim, buffer accounting, pause, config setters, and the
 *             deferred-underlying binding (`setUnderlying` + `_requireUnderlyingReady`).
 *             With no Strategy registered (`strategies[]` empty) the Vault holds
 *             100% of the Underlying in its buffer and these still work alone.
 *           - Strategy / yield layer (Phase 3b): allocate /
 *             receiveFromStrategy / direct yield pushes /
 *             transferYieldToTreasury / strategy whitelist + CRUD / writeoff /
 *             allocation pause / strategy views. The push-model storage layout
 *             was reserved in full from Phase 3a (see STATE), so this layer was
 *             added without shifting any storage slot.
 *
 *         Deferred-underlying interplay: because the push model reverses the
 *         approve direction (a Strategy approves the Vault in its initializer,
 *         §2.2.5), `addStrategy` no longer touches `underlying.safeApprove`. The
 *         activation-order guard that previously fell out of that approve is
 *         restored explicitly in `addStrategy` (underlying must be set and must
 *         match the Strategy's), so a placeholder / mismatched-asset Strategy can
 *         never be registered (dToken.md §2.2.10 / §2.2.11).
 */
contract CollateralVault is
    Initializable,
    ICollateralVault,
    ReentrancyGuardUpgradeable,
    AccessControlUpgradeable,
    UUPSUpgradeable
{
    using SafeERC20 for IERC20;

    // =============================================================
    //                          CONSTANTS
    // =============================================================

    bytes32 internal constant GOV_ROLE = keccak256("GOV_ROLE");
    // ALLOCATOR is deliberately restricted to allocate; no legacy umbrella role.
    bytes32 internal constant ALLOCATOR_ROLE = keccak256("ALLOCATOR_ROLE");
    bytes32 internal constant WITHDRAWER_ROLE = keccak256("WITHDRAWER_ROLE");
    bytes32 internal constant HARVESTER_ROLE = keccak256("HARVESTER_ROLE");
    bytes32 internal constant TREASURY_TRANSFER_ROLE = keccak256("TREASURY_TRANSFER_ROLE");
    bytes32 internal constant GUARDIAN_ROLE = keccak256("GUARDIAN_ROLE");
    bytes32 internal constant WRITEOFF_ROLE = keccak256("WRITEOFF_ROLE");

    uint256 internal constant BPS_DENOMINATOR = 10000;
    uint256 internal constant DEFAULT_STRATEGY_VALUATION_MAX_AGE = 1 days;
    /// @dev Default gas budget handed to each Strategy valuation probe. A registered Strategy must
    ///      value itself within the active budget; a probe that exceeds it is a genuine valuation
    ///      failure. GOV can retune the budget within the bounds below.
    uint256 internal constant DEFAULT_STRATEGY_VALUATION_GAS = 500_000;
    uint256 internal constant MIN_STRATEGY_VALUATION_GAS = 100_000;
    uint256 internal constant MAX_STRATEGY_VALUATION_GAS = 2_000_000;
    /// @dev Headroom the Vault keeps for the probe call frames and the catch paths.
    uint256 internal constant STRATEGY_VALUATION_GAS_MARGIN = 20_000;
    uint256 public constant MAX_STRATEGIES = 32;

    // =============================================================
    //                         STATE
    // =============================================================
    // NOTE: full push-model layout was reserved from Phase 3a so that the
    //       Phase 3b Strategy upgrade was purely additive. Fields marked
    //       "[3b]" belong to the Strategy / yield layer.

    IERC20 public override underlying;
    IDToken public override dToken;
    address public override treasury;

    uint256 public override bufferTargetBps;
    uint256 public override bufferFloor;

    uint256 public allocateMaxMove; // [3b]
    uint256 public allocatorCooldown; // [3b]
    uint256 public lastAllocatorTime; // [3b]

    bool public override pausedDeposit;
    bool public override pausedRedeem;
    bool public override pausedClaim;
    bool public pausedAllocation; // [3b]

    IStrategy[] public strategies; // [3b]
    mapping(IStrategy => StrategyConfig) public strategyConfigs; // [3b]
    uint256 public totalWeightBps; // [3b]
    mapping(address => bool) public whitelistedStrategies; // [3b]

    mapping(uint256 => WithdrawRequest) public withdrawRequests;
    uint256 public nextRequestId;
    uint256 public withdrawDelay;
    uint256 public override pendingWithdrawals;
    uint256 private _backstopReserve;
    mapping(IStrategy => StrategyValuationCache) public override strategyValuationCaches; // [3b]
    uint256 public override strategyValuationMaxAge; // [3b]
    /// @dev Zero means DEFAULT_STRATEGY_VALUATION_GAS, so an upgraded proxy whose slot is still
    ///      unset keeps the default budget instead of probing with no gas.
    uint256 private _strategyValuationGasBudget; // [3b]

    /// @dev Storage gap for future upgrades. See OpenZeppelin's storage gap guidance.
    uint256[46] private __gap;

    // =============================================================
    //                          ERRORS
    // =============================================================

    error Paused();
    error ZeroAddress();
    error ZeroAmount();
    /// @dev Caller cannot fund the fixed Strategy valuation probe budget. Same signature as the
    ///      price-feed gas guard so JpyFreezeLib and PriceFeedProxy bubble it instead of shutting down.
    error InsufficientGasForExternalCall();
    error InvalidStrategyValuationGasBudget(uint256 budget);
    error InvalidBufferConfig();
    error RequestNotReady();
    error RequestNotFound();
    error InsufficientBuffer();
    error InvalidDTokenAmount();
    error PermitFailed();

    // Strategy / yield layer (push model) errors
    error StrategyAlreadyExists();
    error StrategyNotFound();
    error StrategyHasPrincipal();
    error StrategyHasAssets();
    error InvalidWeight();
    error CooldownNotMet();
    error NotWhitelisted();
    error NotContract();
    error WeightExceedsBps();
    error AlreadyWhitelisted();
    error NotRegisteredStrategy();
    error TooManyStrategies();

    // Deferred-underlying (placeholder branch) errors
    error UnderlyingNotSet();
    error UnderlyingMismatch();
    error UnderlyingAlreadySet();
    error UnderlyingNotAllowed();
    error InvalidBackingTarget();
    error InsufficientBackstop();
    error StrategyWriteoffNotReady();
    error InvalidBackingRatioGuard();
    error BackingRatioBelowMinimum(uint256 actual, uint256 minimum);
    error RecoveryBelowMinimum(uint256 actual, uint256 minimum);

    // =============================================================
    //                        CONSTRUCTOR
    // =============================================================

    /// @custom:oz-upgrades-unsafe-allow constructor
    constructor() {
        _disableInitializers();
    }

    // =============================================================
    //                        INITIALIZER
    // =============================================================

    /// @notice Initialize the Vault.
    /// @dev `_underlying == address(0)` is **allowed**: the Vault deploys as a
    ///      placeholder and is bound later via `setUnderlying` (deferred-binding
    ///      for placeholder branches). `_dToken` / `_treasury` / `_admin` must be
    ///      non-zero. While `underlying == address(0)`, the `_requireUnderlyingReady`
    ///      guard makes deposit/redeem/redeemWithPermit/backstopDeposit revert
    ///      (the Vault is inert).
    function initialize(IERC20 _underlying, IDToken _dToken, address _treasury, address _admin) external initializer {
        if (address(_dToken) == address(0)) revert ZeroAddress();
        if (_treasury == address(0)) revert ZeroAddress();
        if (_admin == address(0)) revert ZeroAddress();
        if (address(_dToken).code.length == 0) revert NotContract();
        if (_dToken.vault() != address(this)) revert UnderlyingMismatch();
        if (address(_underlying) != address(0) && !_dToken.allowedUnderlying(address(_underlying))) {
            revert UnderlyingNotAllowed();
        }

        __ReentrancyGuard_init();
        __AccessControl_init();
        __UUPSUpgradeable_init();

        underlying = _underlying; // may be address(0) for a placeholder branch
        dToken = _dToken;
        treasury = _treasury;

        bufferTargetBps = 2000; // 20%
        allocateMaxMove = type(uint256).max;
        strategyValuationMaxAge = DEFAULT_STRATEGY_VALUATION_MAX_AGE;
        _strategyValuationGasBudget = DEFAULT_STRATEGY_VALUATION_GAS;
        withdrawDelay = 1 days;
        nextRequestId = 1;

        _grantRole(DEFAULT_ADMIN_ROLE, _admin);
        _grantRole(GOV_ROLE, _admin);
        _grantRole(ALLOCATOR_ROLE, _admin);
        _grantRole(WITHDRAWER_ROLE, _admin);
        _grantRole(HARVESTER_ROLE, _admin);
        _grantRole(TREASURY_TRANSFER_ROLE, _admin);
        _grantRole(GUARDIAN_ROLE, _admin);
        _grantRole(WRITEOFF_ROLE, _admin);
    }

    // =============================================================
    //                    UUPS UPGRADE
    // =============================================================

    function _authorizeUpgrade(address) internal override onlyRole(GOV_ROLE) {}

    function _checkRole(bytes32 role, address account) internal view override {
        if (!hasRole(role, account)) revert();
    }

    // =============================================================
    //                      MODIFIERS
    // =============================================================

    modifier whenNotPausedDeposit() {
        if (pausedDeposit) revert Paused();
        _;
    }

    modifier whenNotPausedRedeem() {
        if (pausedRedeem) revert Paused();
        _;
    }

    modifier whenNotPausedClaim() {
        if (pausedClaim) revert Paused();
        _;
    }

    /// @notice Gate Vault-managed outbound operations.
    /// @dev Strategy→buffer recovery (`Strategy.sendToVault`) and yield-only
    ///      pushes (`Strategy.sendProfitToVault`) stay available while allocation
    ///      is paused because they move funds to the Vault. Outflows from the
    ///      Vault (`allocate` and `transferYieldToTreasury`) are stopped.
    modifier whenNotPausedAllocation() {
        if (pausedAllocation) revert Paused();
        _;
    }

    // =============================================================
    //                     USER FUNCTIONS
    // =============================================================

    /// @inheritdoc ICollateralVault
    function deposit(uint256 _underlyingAmount)
        external
        override
        nonReentrant
        whenNotPausedDeposit
        returns (uint256 dTokenAmount)
    {
        IERC20 u = _requireUnderlyingReady();
        if (_underlyingAmount == 0) revert ZeroAmount();
        _requireConfirmedFullyBacked();
        uint256 vaultUnderlyingBeforeDeposit = u.balanceOf(address(this));
        u.safeTransferFrom(msg.sender, address(this), _underlyingAmount);
        uint256 received = u.balanceOf(address(this)) - vaultUnderlyingBeforeDeposit;
        if (received == 0) revert ZeroAmount();
        dTokenAmount = dToken.convertToDToken(received);
        dToken.mint(msg.sender, dTokenAmount);
        emit Deposited(msg.sender, received, dTokenAmount);
    }

    /// @inheritdoc ICollateralVault
    function redeem(uint256 _dTokenAmount, address _receiver)
        external
        override
        nonReentrant
        whenNotPausedRedeem
        returns (uint256 underlyingReceived, uint256 requestId)
    {
        uint256 underlyingNeeded = _requireValidRedemption(_dTokenAmount, _receiver);
        uint256 bufferBal = bufferBalance();

        dToken.burn(msg.sender, _dTokenAmount);

        return _completeRedemption(_receiver, _dTokenAmount, underlyingNeeded, bufferBal);
    }

    /// @inheritdoc ICollateralVault
    /// @dev Identical to `redeem` except dToken is pulled in via EIP-2612 permit
    ///      and burned from the Vault. The permit signature is verified against
    ///      the dToken's EIP-712 domain, which tracks its live `name()`.
    function redeemWithPermit(
        uint256 _dTokenAmount,
        uint256 _deadline,
        uint8 _v,
        bytes32 _r,
        bytes32 _s,
        address _receiver
    ) external override nonReentrant whenNotPausedRedeem returns (uint256 underlyingReceived, uint256 requestId) {
        uint256 underlyingNeeded = _requireValidRedemption(_dTokenAmount, _receiver);

        _permitOrRequireAllowance(_dTokenAmount, _deadline, _v, _r, _s);
        IERC20(address(dToken)).safeTransferFrom(msg.sender, address(this), _dTokenAmount);

        uint256 bufferBal = bufferBalance();

        dToken.burn(address(this), _dTokenAmount);

        return _completeRedemption(_receiver, _dTokenAmount, underlyingNeeded, bufferBal);
    }

    /// @inheritdoc ICollateralVault
    function claim(uint256 _requestId)
        external
        override
        nonReentrant
        whenNotPausedClaim
        returns (uint256 underlyingClaimed)
    {
        WithdrawRequest storage req = withdrawRequests[_requestId];
        address requestOwner = req.owner;

        // Checks
        if (requestOwner == address(0)) revert RequestNotFound();
        if (req.claimed) return 0;
        if (block.timestamp < req.claimableAt) revert RequestNotReady();

        _requireConfirmedFullyBacked();
        underlyingClaimed = req.underlyingAmount;
        if (bufferBalance() < underlyingClaimed) revert InsufficientBuffer();

        // Effects
        req.claimed = true;
        pendingWithdrawals -= underlyingClaimed;

        // Interaction
        underlying.safeTransfer(requestOwner, underlyingClaimed);
        emit WithdrawClaimed(requestOwner, _requestId, underlyingClaimed);
    }

    // =============================================================
    //                  DEFERRED-BINDING ACTIVATION
    // =============================================================

    /// @inheritdoc ICollateralVault
    /// @dev One-shot. Enforces dToken-first ordering by requiring the dToken to
    ///      already be bound to the same underlying (`dToken.underlying()`), so
    ///      the custody asset and the 1:1/decimals valuation can never diverge.
    function setUnderlying(IERC20 _underlying) external override onlyRole(GOV_ROLE) {
        if (address(_underlying) == address(0)) revert ZeroAddress();
        if (address(underlying) != address(0)) revert UnderlyingAlreadySet();
        if (address(dToken.underlying()) != address(_underlying)) revert UnderlyingMismatch();
        if (!dToken.allowedUnderlying(address(_underlying))) revert UnderlyingNotAllowed();

        underlying = _underlying;
        emit UnderlyingSet(address(_underlying));
    }

    // =============================================================
    //                   ALLOCATOR FUNCTIONS
    // =============================================================

    /// @inheritdoc ICollateralVault
    /// @dev Buffer excess is split across Strategies by `weightBps` (used only
    ///      for allocation, never for harvest in the push model). Placeholder-safe:
    ///      a not-yet-bound Vault has `_managedUnderlying() == 0` (empty
    ///      `strategies[]` and a zero `bufferBalance()`), so this early-returns
    ///      before touching `underlying`. `addStrategy`'s underlying guard further
    ///      guarantees an unbound Vault has no Strategy to allocate to.
    function allocate() external override onlyRole(ALLOCATOR_ROLE) whenNotPausedAllocation nonReentrant {
        if (block.timestamp < lastAllocatorTime + allocatorCooldown) revert CooldownNotMet();

        uint256 managedAssets = _managedUnderlying();
        if (managedAssets == 0) return;

        uint256 targetBuffer = _requiredBuffer(managedAssets);

        uint256 bufferBefore = bufferBalance();

        if (bufferBefore > targetBuffer) {
            uint256 excess = bufferBefore - targetBuffer;
            if (excess > allocateMaxMove) excess = allocateMaxMove;
            _allocateToStrategies(excess);
            if (excess != 0) _requireConfirmedFullyBacked();
        }

        lastAllocatorTime = block.timestamp;
        emit Allocated(bufferBefore, targetBuffer, bufferBalance());
    }

    // =============================================================
    //                STRATEGY → VAULT PUSH ENTRY POINT
    // =============================================================

    /// @inheritdoc ICollateralVault
    /// @dev Principal/cache-reducing push-back entry point. The amount credited
    ///      is measured by the Vault's own balance diff, so fee-on-transfer /
    ///      rebasing underlyings are accounted by what actually arrived (the
    ///      caller Strategy decrements its `principal` by this returned
    ///      `received` when returning principal). A declared/received mismatch
    ///      invalidates the fallback valuation cache: the Vault cannot infer
    ///      how much upstream position value moved from the receipt alone.
    function receiveFromStrategy(uint256 _declaredAmount) external override nonReentrant returns (uint256 received) {
        IStrategy strategy = IStrategy(msg.sender);
        if (!_isRegisteredStrategy(strategy)) revert NotRegisteredStrategy();

        if (_declaredAmount == 0) {
            emit ReceivedFromStrategy(msg.sender, 0, 0);
            return 0;
        }

        uint256 vaultUnderlyingBeforeReceive = underlying.balanceOf(address(this));
        underlying.safeTransferFrom(msg.sender, address(this), _declaredAmount);
        received = underlying.balanceOf(address(this)) - vaultUnderlyingBeforeReceive;
        if (received == _declaredAmount) {
            _reduceStrategyValuationCache(strategy, received);
        } else {
            _invalidateStrategyValuationCache(strategy);
        }

        emit ReceivedFromStrategy(msg.sender, _declaredAmount, received);
    }

    // =============================================================
    //                  BACKSTOP / REPAIR ENTRY POINT
    // =============================================================

    /// @inheritdoc ICollateralVault
    /// @dev Unlike `deposit`, this does not mint dToken. It increases the
    ///      protected backstop reserve and `totalUnderlying()` without increasing
    ///      `bufferBalance()`. The reserve only becomes redeem / claim liquidity
    ///      after GOV explicitly releases it.
    function backstopDeposit(uint256 _underlyingAmount) external override nonReentrant returns (uint256 received) {
        IERC20 u = _requireUnderlyingReady();
        if (_underlyingAmount == 0) revert ZeroAmount();

        uint256 vaultUnderlyingBeforeBackstop = u.balanceOf(address(this));
        u.safeTransferFrom(msg.sender, address(this), _underlyingAmount);
        received = u.balanceOf(address(this)) - vaultUnderlyingBeforeBackstop;
        if (received == 0) revert ZeroAmount();
        _backstopReserve += received;

        emit BackstopDeposited(msg.sender, _underlyingAmount, received);
    }

    /// @inheritdoc ICollateralVault
    function releaseBackstopToBuffer(uint256 _amount) external override onlyRole(GOV_ROLE) returns (uint256 released) {
        _requireUnderlyingReady();
        if (_amount == 0) revert ZeroAmount();
        if (backstopBalance() < _amount) revert InsufficientBackstop();

        _backstopReserve -= _amount;
        released = _amount;
        emit BackstopReleased(msg.sender, released);
    }

    // =============================================================
    //                YIELD / TREASURY FUNCTIONS
    // =============================================================

    /// @inheritdoc ICollateralVault
    /// @dev Sends only managed-asset surplus over liabilities, and keeps the same
    ///      liquid buffer that `allocate` reserves (buffer target + every queued
    ///      withdrawal, see `_requiredBuffer`) on hand. It therefore never dips
    ///      into underlying that is inside a Strategy or protected as backstop
    ///      reserve, and never sweeps liquidity a pending `claim` depends on.
    ///      Strategy value uses `min(estimatedTotalUnderlying, principal)`, so
    ///      unrealized yield is not pre-counted. Unlike backing views, this path
    ///      does not spend against cached or partial Strategy valuation: one
    ///      unavailable registered Strategy makes the entire transfer zero.
    function transferYieldToTreasury()
        external
        override
        onlyRole(TREASURY_TRANSFER_ROLE)
        whenNotPausedAllocation
        nonReentrant
        returns (uint256 transferred)
    {
        uint256 managedAssets = _managedUnderlying();
        uint256 currentLiabilities = _actualLiabilities();
        if (managedAssets <= currentLiabilities) {
            emit YieldTransferredToTreasury(0, treasury);
            return 0;
        }

        uint256 managedSurplus = managedAssets - currentLiabilities;

        // Reserve the same liquid buffer that `allocate` keeps on hand (buffer
        // target + every queued withdrawal). Only buffer above that reserve is
        // sweepable, so yield extraction can never starve a pending `claim` of
        // liquidity; the genuine surplus remains the upper bound either way.
        uint256 requiredBuffer = _requiredBuffer(managedAssets);
        uint256 liquidBufferBalance = bufferBalance();
        uint256 freeBuffer = liquidBufferBalance > requiredBuffer ? liquidBufferBalance - requiredBuffer : 0;
        transferred = managedSurplus < freeBuffer ? managedSurplus : freeBuffer;

        if (transferred > 0) {
            underlying.safeTransfer(treasury, transferred);
        }
        emit YieldTransferredToTreasury(transferred, treasury);
    }

    // =============================================================
    //                  GOVERNANCE FUNCTIONS (dToken portion)
    // =============================================================

    function setBufferConfig(uint256 _targetBps, uint256 _floor) external override onlyRole(GOV_ROLE) {
        if (_targetBps > BPS_DENOMINATOR) revert InvalidBufferConfig();
        uint256 oldTargetBps = bufferTargetBps;
        uint256 oldFloor = bufferFloor;
        bufferTargetBps = _targetBps;
        bufferFloor = _floor;
        emit BufferConfigUpdated(oldTargetBps, _targetBps, oldFloor, _floor);
    }

    function setWithdrawDelay(uint256 _delay) external override onlyRole(GOV_ROLE) {
        if (_delay > 30 days) revert InvalidBufferConfig();
        uint256 oldDelay = withdrawDelay;
        withdrawDelay = _delay;
        emit WithdrawDelayUpdated(oldDelay, _delay);
    }

    function setTreasury(address _treasury) external override onlyRole(GOV_ROLE) {
        if (_treasury == address(0)) revert ZeroAddress();
        address oldTreasury = treasury;
        treasury = _treasury;
        emit TreasuryUpdated(oldTreasury, _treasury);
    }

    function pauseDeposit() external override onlyRole(GUARDIAN_ROLE) {
        pausedDeposit = true;
        emit DepositPaused();
    }

    function unpauseDeposit() external override onlyRole(GOV_ROLE) {
        pausedDeposit = false;
        emit DepositUnpaused();
    }

    function pauseRedeem() external override onlyRole(GUARDIAN_ROLE) {
        pausedRedeem = true;
        emit RedeemPaused();
    }

    function unpauseRedeem() external override onlyRole(GOV_ROLE) {
        pausedRedeem = false;
        emit RedeemUnpaused();
    }

    function pauseClaim() external override onlyRole(GUARDIAN_ROLE) {
        pausedClaim = true;
        emit ClaimPaused();
    }

    function unpauseClaim() external override onlyRole(GOV_ROLE) {
        pausedClaim = false;
        emit ClaimUnpaused();
    }

    // =============================================================
    //               GOVERNANCE FUNCTIONS (Strategy layer)
    // =============================================================

    // --- Whitelist Management ---

    function addToWhitelist(address _strategy) external override onlyRole(GOV_ROLE) {
        if (_strategy == address(0)) revert ZeroAddress();
        if (_strategy.code.length == 0) revert NotContract();
        if (whitelistedStrategies[_strategy]) revert AlreadyWhitelisted();
        whitelistedStrategies[_strategy] = true;
        emit StrategyWhitelisted(_strategy);
    }

    function removeFromWhitelist(address _strategy) external override onlyRole(GUARDIAN_ROLE) {
        if (!whitelistedStrategies[_strategy]) revert StrategyNotFound();
        whitelistedStrategies[_strategy] = false;
        emit StrategyRemovedFromWhitelist(_strategy);

        StrategyConfig storage config = strategyConfigs[IStrategy(_strategy)];
        if (config.enabled || config.weightBps != 0) {
            _disableStrategy(IStrategy(_strategy), config);
            _pauseUserFlows();
            _pauseAllocationIfNeeded();
        }
    }

    // --- Strategy CRUD ---

    /// @inheritdoc ICollateralVault
    /// @dev Restores the deferred-underlying activation-order guard that the push
    ///      model would otherwise drop. In the pull model `addStrategy` called
    ///      `underlying.safeApprove(strategy, ...)`, which reverted on a
    ///      placeholder Vault (`underlying == address(0)`). The push model
    ///      reverses the approve direction (the Strategy approves the Vault in its
    ///      initializer, §2.2.5), so that implicit guard is gone. We restore it
    ///      explicitly — and additionally pin `strategy.underlying()` to the
    ///      Vault's underlying — so a placeholder or mismatched-asset Strategy can
    ///      never be registered (which would make `allocate` ship the wrong token
    ///      and `receiveFromStrategy` pull a different one). dToken.md §2.2.10 / §2.2.11.
    function addStrategy(IStrategy _strategy, uint256 _weightBps, uint256 _cap) external override onlyRole(GOV_ROLE) {
        if (address(_strategy) == address(0)) revert ZeroAddress();
        if (address(_strategy).code.length == 0) revert NotContract();
        if (_isRegisteredStrategy(_strategy)) revert StrategyAlreadyExists();
        if (!whitelistedStrategies[address(_strategy)]) revert NotWhitelisted();

        IERC20 u = underlying;
        if (address(u) == address(0)) revert UnderlyingNotSet();
        if (_strategy.underlying() != address(u)) revert UnderlyingMismatch();

        if (strategies.length >= MAX_STRATEGIES) revert TooManyStrategies();
        if (totalWeightBps + _weightBps > BPS_DENOMINATOR) revert WeightExceedsBps();

        strategies.push(_strategy);
        strategyConfigs[_strategy] = StrategyConfig({enabled: true, weightBps: _weightBps, cap: _cap});
        totalWeightBps += _weightBps;
        _refreshStrategyValuation(_strategy);

        emit StrategyAdded(address(_strategy), _weightBps, _cap);
    }

    function updateStrategy(IStrategy _strategy, uint256 _weightBps, uint256 _cap, bool _enabled)
        external
        override
        onlyRole(GOV_ROLE)
    {
        if (!_isRegisteredStrategy(_strategy)) revert StrategyNotFound();

        StrategyConfig storage config = strategyConfigs[_strategy];
        if (!_enabled && _weightBps > 0) revert InvalidWeight();

        uint256 newTotal = totalWeightBps - config.weightBps + _weightBps;
        if (newTotal > BPS_DENOMINATOR) revert WeightExceedsBps();

        totalWeightBps = newTotal;
        config.weightBps = _weightBps;
        config.cap = _cap;
        config.enabled = _enabled;

        emit StrategyUpdated(address(_strategy), _weightBps, _cap, _enabled);
    }

    /// @inheritdoc ICollateralVault
    /// @dev Outstanding principal and assets do not prevent emergency disabling.
    function emergencyDisableStrategy(IStrategy _strategy) external override onlyRole(GUARDIAN_ROLE) {
        if (!_isRegisteredStrategy(_strategy)) revert StrategyNotFound();

        _disableStrategy(_strategy, strategyConfigs[_strategy]);
        _pauseUserFlows();
        _pauseAllocationIfNeeded();
    }

    /// @inheritdoc ICollateralVault
    /// @dev Both principal and live estimated assets must be readable and zero.
    ///      Recover assets first; a principal writeoff alone does not prove that
    ///      the Strategy has no residual assets. Enabled or disabled Strategies
    ///      may be removed once both conditions hold.
    function removeStrategy(IStrategy _strategy) external override onlyRole(GUARDIAN_ROLE) nonReentrant {
        (uint256 strategyIndex, bool registered) = _strategyIndex(_strategy);
        if (!registered) revert StrategyNotFound();
        (uint256 principal_, bool principalAvailable) = _tryPrincipal(_strategy);
        if (!principalAvailable || principal_ != 0) revert StrategyHasPrincipal();
        (uint256 estimated, bool estimateAvailable) = _tryEstimatedTotalUnderlying(_strategy);
        if (!estimateAvailable || estimated != 0) revert StrategyHasAssets();

        StrategyConfig storage config = strategyConfigs[_strategy];
        totalWeightBps -= config.weightBps;
        delete strategyConfigs[_strategy];

        uint256 length = strategies.length;
        strategies[strategyIndex] = strategies[length - 1];
        strategies.pop();

        _invalidateStrategyValuationCache(_strategy);
        emit StrategyRemoved(address(_strategy));
    }

    /// @inheritdoc ICollateralVault
    /// @dev Works on enabled and disabled-but-still-registered Strategies alike
    ///      (membership in `strategies[]` is the authoritative "registered"
    ///      status, matching `receiveFromStrategy` / `_isRegisteredStrategy`).
    ///      Book-only: no asset moves. Recover what is recoverable first
    ///      (`sendToVault` / emergency), then write off only the residual loss.
    ///      The emitted amount is the Strategy-reported actual writeoff, so
    ///      over-large requests report the clamped amount.
    ///      Live Strategies must first be disabled or allocation-paused, preventing
    ///      a standalone writeoff key from reducing backing while allocation is
    ///      still operating normally.
    function writeoffStrategyPrincipal(IStrategy _strategy, uint256 _amount, uint256 _minBackingRatioAfter)
        external
        override
        onlyRole(WRITEOFF_ROLE)
        nonReentrant
    {
        if (_minBackingRatioAfter > 1e18) revert InvalidBackingRatioGuard();
        if (!_isRegisteredStrategy(_strategy)) revert StrategyNotFound();
        _requireStrategyIncidentReady(_strategy);
        _pauseUserFlows();
        uint256 writtenOff = _strategy.writeoffPrincipal(_amount);
        if (!_refreshStrategyValuation(_strategy)) {
            _reduceStrategyValuationCache(_strategy, writtenOff);
        }
        uint256 backingAfter = _backingRatio();
        if (backingAfter < _minBackingRatioAfter) revert BackingRatioBelowMinimum(backingAfter, _minBackingRatioAfter);
        emit StrategyPrincipalWrittenOff(address(_strategy), writtenOff);
    }

    /// @inheritdoc ICollateralVault
    function forceDeallocateMorphoV2(
        IStrategy _strategy,
        address _adapter,
        bytes calldata _data,
        uint256 _assets,
        uint256 _minReceived,
        uint256 _minBackingRatioAfter
    )
        external
        override
        onlyRole(WRITEOFF_ROLE)
        nonReentrant
        returns (uint256 penaltyShares, uint256 penaltyAssets, uint256 valuationLossAssets)
    {
        if (_assets == 0 || _minReceived == 0) revert ZeroAmount();
        if (_minBackingRatioAfter > 1e18) revert InvalidBackingRatioGuard();
        if (!_isRegisteredStrategy(_strategy)) revert StrategyNotFound();

        // Any penalty attributed to tracked shares is an immediate confirmed
        // loss. Stop every outbound and user Vault flow in this same transaction
        // before realizing it.
        _pauseAllocationIfNeeded();
        _pauseUserFlows();

        uint256 balanceBefore = underlying.balanceOf(address(this));
        uint256 withdrawnAssets;
        (penaltyShares, penaltyAssets, valuationLossAssets, withdrawnAssets) =
            IMorphoV2IncidentStrategy(address(_strategy)).forceDeallocate(_adapter, _data, _assets);
        uint256 received = underlying.balanceOf(address(this)) - balanceBefore;
        if (received < _minReceived) revert RecoveryBelowMinimum(received, _minReceived);
        if (!_refreshStrategyValuation(_strategy)) {
            if (received == withdrawnAssets) {
                _reduceStrategyValuationCache(_strategy, valuationLossAssets + withdrawnAssets);
            } else {
                _invalidateStrategyValuationCache(_strategy);
            }
        }
        emit ReceivedFromStrategy(address(_strategy), withdrawnAssets, received);

        uint256 backingAfter = _backingRatio();
        if (backingAfter < _minBackingRatioAfter) {
            revert BackingRatioBelowMinimum(backingAfter, _minBackingRatioAfter);
        }

        emit MorphoV2ForceDeallocated(
            address(_strategy), _adapter, _assets, penaltyShares, penaltyAssets, valuationLossAssets, backingAfter
        );
    }

    // --- Config / Pause (Strategy layer) ---

    function setAllocatorConfig(uint256 _maxMove, uint256 _cooldown) external override onlyRole(GOV_ROLE) {
        uint256 oldMaxMove = allocateMaxMove;
        uint256 oldCooldown = allocatorCooldown;
        allocateMaxMove = _maxMove;
        allocatorCooldown = _cooldown;
        emit AllocatorConfigUpdated(oldMaxMove, _maxMove, oldCooldown, _cooldown);
    }

    function setStrategyValuationMaxAge(uint256 _maxAge) external override onlyRole(GOV_ROLE) {
        uint256 oldMaxAge = strategyValuationMaxAge;
        strategyValuationMaxAge = _maxAge;
        emit StrategyValuationMaxAgeUpdated(oldMaxAge, _maxAge);
    }

    /// @inheritdoc ICollateralVault
    function setStrategyValuationGasBudget(uint256 _budget) external override onlyRole(GOV_ROLE) {
        if (_budget < MIN_STRATEGY_VALUATION_GAS || _budget > MAX_STRATEGY_VALUATION_GAS) {
            revert InvalidStrategyValuationGasBudget(_budget);
        }
        uint256 oldBudget = strategyValuationGasBudget();
        _strategyValuationGasBudget = _budget;
        emit StrategyValuationGasBudgetUpdated(oldBudget, _budget);
    }

    /// @inheritdoc ICollateralVault
    function strategyValuationGasBudget() public view override returns (uint256 budget) {
        budget = _strategyValuationGasBudget;
        if (budget == 0) budget = DEFAULT_STRATEGY_VALUATION_GAS;
    }

    function refreshStrategyValuation(IStrategy _strategy) external override returns (bool refreshed) {
        if (!_isRegisteredStrategy(_strategy)) revert StrategyNotFound();
        refreshed = _refreshStrategyValuation(_strategy);
    }

    /// @inheritdoc ICollateralVault
    /// @dev Allows WRITEOFF_ROLE as well as GOV_ROLE because invalidating a
    ///      fallback valuation cache can only remove stale backing from solvency
    ///      views. This gives the high-threshold incident role a same-block
    ///      response when a Strategy's live valuation is unavailable, without
    ///      giving low-threshold guardians the power to reprice collateral.
    ///      The WRITEOFF_ROLE path uses the same incident-ready guard as
    ///      `writeoffStrategyPrincipal`: allocation must be paused or the
    ///      Strategy must already be disabled.
    function invalidateStrategyValuationCache(IStrategy _strategy) external override {
        bool isGov = hasRole(GOV_ROLE, msg.sender);
        if (!isGov) _checkRole(WRITEOFF_ROLE, msg.sender);
        if (!_isRegisteredStrategy(_strategy)) revert StrategyNotFound();
        if (!isGov) _requireStrategyIncidentReady(_strategy);
        _invalidateStrategyValuationCache(_strategy);
    }

    function pauseAllocation() external override onlyRole(GUARDIAN_ROLE) {
        pausedAllocation = true;
        emit AllocationPaused();
    }

    function unpauseAllocation() external override onlyRole(GOV_ROLE) {
        pausedAllocation = false;
        emit AllocationUnpaused();
    }

    // =============================================================
    //                      VIEW FUNCTIONS
    // =============================================================

    /// @notice Underlying currently held in the Vault liquid buffer.
    /// @dev Placeholder-safe: returns 0 while `underlying == address(0)` so that
    ///      monitoring/subgraph reads of an inert placeholder branch do not revert
    ///      on `address(0).balanceOf(...)`. Excludes the protected backstop
    ///      reserve, so redeem / claim / allocate / treasury cannot consume
    ///      backstop funds unless GOV first releases them.
    function bufferBalance() public view override returns (uint256) {
        uint256 rawBalance = _rawUnderlyingBalance();
        uint256 reserve = _backstopReserve;
        return rawBalance > reserve ? rawBalance - reserve : 0;
    }

    /// @notice Underlying held as protected backstop reserve, capped by live balance.
    function backstopBalance() public view override returns (uint256) {
        uint256 rawBalance = _rawUnderlyingBalance();
        uint256 reserve = _backstopReserve;
        return reserve < rawBalance ? reserve : rawBalance;
    }

    /// @notice Total underlying the Vault can account for (buffer + conservative
    ///         Strategy valuation + protected backstop reserve). With no Strategy
    ///         registered this equals the Vault's raw underlying balance.
    /// @dev Uses `min(estimatedTotalUnderlying, principal)` per Strategy to stay
    ///      conservative against unrealized yield. If a Strategy valuation view
    ///      reverts, a fresh bounded last-good conservative cache is used; stale
    ///      or missing caches fall back to zero.
    ///      Placeholder-safe via `_rawUnderlyingBalance()` (returns 0 while unbound;
    ///      `strategies[]` is empty until Phase 3b activation, which itself
    ///      requires a bound underlying).
    function totalUnderlying() public view override returns (uint256 total) {
        (total,) = _totalUnderlyingWithAvailability();
    }

    /// @dev Same conservative sum as `totalUnderlying`, plus whether every
    ///      registered Strategy was valued live or from a fresh cache.
    function _totalUnderlyingWithAvailability() internal view returns (uint256 total, bool available) {
        total = _rawUnderlyingBalance();
        available = true;
        uint256 strategyCount = strategies.length;
        for (uint256 strategyIndex; strategyIndex < strategyCount; strategyIndex++) {
            (uint256 value, bool valued) = _strategyConservativeValueWithAvailability(strategies[strategyIndex]);
            total += value;
            if (!valued) available = false;
        }
    }

    /// @inheritdoc ICollateralVault
    function backingRatio() external view override returns (uint256) {
        return _backingRatio();
    }

    /// @inheritdoc ICollateralVault
    function backingRatioForPricing() external view override returns (uint256 ratio, bool available) {
        uint256 liabilities = _actualLiabilities();
        if (liabilities == 0) return (1e18, true);

        uint256 totalAssets;
        (totalAssets, available) = _totalUnderlyingWithAvailability();
        // Unknown Strategy assets are unnecessary when the known lower bound
        // already covers every dToken and queued-claim liability.
        if (totalAssets >= liabilities) return (1e18, true);
        if (!available) return (0, false);

        ratio = Math.mulDiv(totalAssets, 1e18, liabilities);
    }

    function _backingRatio() internal view returns (uint256) {
        uint256 liabilities = _actualLiabilities();
        if (liabilities == 0) return 1e18;

        uint256 totalAssets = totalUnderlying();
        if (totalAssets >= liabilities) return 1e18;

        return Math.mulDiv(totalAssets, 1e18, liabilities);
    }

    /// @inheritdoc ICollateralVault
    function actualLiabilities() public view override returns (uint256) {
        return _actualLiabilities();
    }

    function getStrategiesCount() external view override returns (uint256) {
        return strategies.length;
    }

    // =============================================================
    //                   INTERNAL FUNCTIONS
    // =============================================================

    /// @dev User liabilities in underlying terms: dToken backing + queued claims.
    function _actualLiabilities() internal view returns (uint256) {
        uint256 supply = dToken.totalSupply();
        uint256 userLiabilities = supply == 0 ? 0 : _dTokenToUnderlyingRoundingUp(supply);
        return userLiabilities + pendingWithdrawals;
    }

    /// @dev User balance-sheet mutations require strict pre-state solvency.
    ///      Unlike pricing views, this gate never accepts cached Strategy values;
    ///      unavailable live values conservatively contribute zero.
    function _requireConfirmedFullyBacked() internal view {
        uint256 liabilities = _actualLiabilities();
        if (liabilities == 0) return;

        uint256 totalAssets = _rawUnderlyingBalance();
        if (totalAssets >= liabilities) return;

        uint256 strategyCount = strategies.length;
        for (uint256 strategyIndex; strategyIndex < strategyCount; strategyIndex++) {
            (,,,, uint256 conservativeValue, bool liveAvailable) = _liveStrategyValuation(strategies[strategyIndex]);
            if (liveAvailable) {
                if (conservativeValue >= liabilities - totalAssets) return;
                totalAssets += conservativeValue;
            }
        }

        revert BackingRatioBelowMinimum(Math.mulDiv(totalAssets, 1e18, liabilities), 1e18);
    }

    /// @dev Shared pre-state validation for both redemption entry points. Keeps
    ///      the solvency check before permit, burn, queue mutation, and transfer.
    ///      Also rejects dToken dust that cannot map to an underlying base unit.
    function _requireValidRedemption(uint256 _dTokenAmount, address _receiver)
        internal
        view
        returns (uint256 underlyingAmount)
    {
        _requireUnderlyingReady();
        if (_dTokenAmount == 0) revert ZeroAmount();
        if (_receiver == address(0)) revert ZeroAddress();
        underlyingAmount = dToken.convertToUnderlying(_dTokenAmount);
        if (underlyingAmount == 0) revert InvalidDTokenAmount();
        if (dToken.convertToDToken(underlyingAmount) != _dTokenAmount) revert InvalidDTokenAmount();
        _requireConfirmedFullyBacked();
    }

    /// @dev Liability views round up so any unexpected or force-created dToken dust
    ///      is treated as one full underlying base unit rather than understated.
    function _dTokenToUnderlyingRoundingUp(uint256 _dTokenAmount) internal view returns (uint256 underlyingAmount) {
        underlyingAmount = dToken.convertToUnderlying(_dTokenAmount);
        if (dToken.convertToDToken(underlyingAmount) < _dTokenAmount) {
            underlyingAmount += 1;
        }
    }

    function _requireUnderlyingReady() internal view returns (IERC20 u) {
        u = underlying;
        if (address(u) == address(0)) revert UnderlyingNotSet();
        if (address(dToken.underlying()) != address(u)) revert UnderlyingMismatch();
    }

    function _queueWithdrawRequest(address _receiver, uint256 _remaining) private returns (uint256 requestId) {
        requestId = nextRequestId++;
        uint256 claimableAt = block.timestamp + withdrawDelay;
        withdrawRequests[requestId] =
            WithdrawRequest({owner: _receiver, underlyingAmount: _remaining, claimableAt: claimableAt, claimed: false});
        pendingWithdrawals += _remaining;
        emit WithdrawRequested(msg.sender, _receiver, requestId, _remaining, claimableAt);
    }

    function _completeRedemption(
        address _receiver,
        uint256 _dTokenAmount,
        uint256 _underlyingNeeded,
        uint256 _bufferBal
    ) private returns (uint256 underlyingReceived, uint256 requestId) {
        uint256 underlyingSent = _bufferBal < _underlyingNeeded ? _bufferBal : _underlyingNeeded;
        uint256 remaining = _underlyingNeeded - underlyingSent;

        // Preserve CEI for the delayed branch: record the fixed claim before
        // the token interaction. A later transfer failure rolls the request
        // and burn back with the rest of the transaction.
        if (remaining != 0) {
            requestId = _queueWithdrawRequest(_receiver, remaining);
        }

        if (underlyingSent != 0) {
            uint256 receiverBalanceBefore = underlying.balanceOf(_receiver);
            underlying.safeTransfer(_receiver, underlyingSent);
            underlyingReceived = underlying.balanceOf(_receiver) - receiverBalanceBefore;
        }

        emit Redeemed(msg.sender, _receiver, _dTokenAmount, underlyingReceived, requestId);
    }

    function _permitOrRequireAllowance(uint256 _dTokenAmount, uint256 _deadline, uint8 _v, bytes32 _r, bytes32 _s)
        private
    {
        try dToken.permit(msg.sender, address(this), _dTokenAmount, _deadline, _v, _r, _s) {}
        catch {
            if (IERC20(address(dToken)).allowance(msg.sender, address(this)) < _dTokenAmount) revert PermitFailed();
        }
    }

    function _rawUnderlyingBalance() internal view returns (uint256) {
        if (address(underlying) == address(0)) return 0;
        return underlying.balanceOf(address(this));
    }

    /// @dev Assets managed for liquidity/yield operations. Excludes protected
    ///      backstop reserve so repair funds cannot create allocatable or
    ///      treasury-sweepable surplus until GOV explicitly releases them.
    ///      Returns zero unless every registered Strategy has a live valuation,
    ///      preventing outbound transfers based on a partial system view.
    function _managedUnderlying() internal view returns (uint256 total) {
        total = bufferBalance();
        uint256 strategyCount = strategies.length;
        for (uint256 strategyIndex; strategyIndex < strategyCount; strategyIndex++) {
            (,,,, uint256 conservativeValue, bool liveAvailable) = _liveStrategyValuation(strategies[strategyIndex]);
            if (!liveAvailable) return 0;
            total += conservativeValue;
        }
    }

    /// @dev Liquid buffer that must stay on hand for redemption / claim
    ///      liquidity: the configured buffer target (`bufferTargetBps` of managed
    ///      assets, floored at `bufferFloor`) plus every queued withdrawal.
    ///      Shared by `allocate` (keeps this before pushing excess to Strategies)
    ///      and `transferYieldToTreasury` (keeps this before sweeping yield), so
    ///      the two Vault outflows reserve liquidity identically and neither can
    ///      strand a pending `claim`.
    function _requiredBuffer(uint256 _managedAssets) internal view returns (uint256 requiredBuffer) {
        requiredBuffer = Math.mulDiv(_managedAssets, bufferTargetBps, BPS_DENOMINATOR);
        if (requiredBuffer < bufferFloor) requiredBuffer = bufferFloor;
        requiredBuffer += pendingWithdrawals;
    }

    /// @dev Conservative Strategy value for solvency views. Live reads always
    ///      win; the bounded cache is used only for transient valuation
    ///      unavailability so one external view failure does not reprice every
    ///      Trove to zero in the same block.
    function _strategyConservativeValue(IStrategy _strategy) internal view returns (uint256) {
        (uint256 value,) = _strategyConservativeValueWithAvailability(_strategy);
        return value;
    }

    /// @dev Distinguishes a measured zero from a value that could not be read.
    function _strategyConservativeValueWithAvailability(IStrategy _strategy)
        internal
        view
        returns (uint256 value, bool available)
    {
        (,,,, uint256 conservativeValue, bool liveAvailable) = _liveStrategyValuation(_strategy);
        if (liveAvailable) return (conservativeValue, true);

        (uint256 cachedValue, bool cacheAvailable,) = _cachedStrategyConservativeValue(_strategy);
        return cacheAvailable ? (cachedValue, true) : (0, false);
    }

    function _liveStrategyValuation(IStrategy _strategy)
        internal
        view
        returns (
            uint256 estimated,
            bool estimateAvailable,
            uint256 principal_,
            bool principalAvailable,
            uint256 conservativeValue,
            bool liveAvailable
        )
    {
        (estimated, estimateAvailable) = _tryEstimatedTotalUnderlying(_strategy);
        (principal_, principalAvailable) = _tryPrincipal(_strategy);
        if (estimateAvailable && principalAvailable) {
            conservativeValue = estimated < principal_ ? estimated : principal_;
            liveAvailable = true;
        }
    }

    function _cachedStrategyConservativeValue(IStrategy _strategy)
        internal
        view
        returns (uint256 cachedValue, bool available, bool stale)
    {
        StrategyValuationCache memory cache = strategyValuationCaches[_strategy];
        if (!cache.initialized) return (0, false, false);

        uint256 maxAge = strategyValuationMaxAge;
        if (maxAge == 0 || block.timestamp - cache.updatedAt > maxAge) {
            return (0, false, true);
        }

        return (cache.conservativeValue, true, false);
    }

    function _refreshStrategyValuation(IStrategy _strategy) internal returns (bool refreshed) {
        (
            uint256 estimated,
            bool estimateAvailable,
            uint256 principal_,
            bool principalAvailable,
            uint256 conservativeValue,
            bool liveAvailable
        ) = _liveStrategyValuation(_strategy);

        if (!liveAvailable) {
            emit StrategyValuationRefreshFailed(address(_strategy), estimateAvailable, principalAvailable);
            return false;
        }

        strategyValuationCaches[_strategy] = StrategyValuationCache({
            conservativeValue: conservativeValue, updatedAt: block.timestamp, initialized: true
        });
        emit StrategyValuationRefreshed(address(_strategy), estimated, principal_, conservativeValue);
        return true;
    }

    function _reduceStrategyValuationCache(IStrategy _strategy, uint256 _amount) internal {
        if (_amount == 0) return;

        StrategyValuationCache storage cache = strategyValuationCaches[_strategy];
        uint256 oldValue = cache.conservativeValue;
        if (!cache.initialized) return;
        // Exhausting a historical estimate does not prove the residual position
        // is worth zero. Only a live valuation may establish an available zero.
        if (_amount >= oldValue) {
            _invalidateStrategyValuationCache(_strategy);
            return;
        }

        uint256 newValue = oldValue - _amount;
        cache.conservativeValue = newValue;
        emit StrategyValuationCacheReduced(address(_strategy), oldValue, newValue, _amount);
    }

    function _setStrategyValuationCache(IStrategy _strategy, uint256 _conservativeValue) internal {
        StrategyValuationCache storage cache = strategyValuationCaches[_strategy];
        cache.conservativeValue = _conservativeValue;
        cache.updatedAt = block.timestamp;
        cache.initialized = true;
    }

    function _invalidateStrategyValuationCache(IStrategy _strategy) internal {
        StrategyValuationCache storage cache = strategyValuationCaches[_strategy];
        emit StrategyValuationCacheInvalidated(address(_strategy), cache.conservativeValue, cache.updatedAt);
        delete strategyValuationCaches[_strategy];
    }

    function _requireStrategyIncidentReady(IStrategy _strategy) internal view {
        if (strategyConfigs[_strategy].enabled && !pausedAllocation) revert StrategyWriteoffNotReady();
    }

    function _pauseUserFlows() internal {
        if (!pausedDeposit) {
            pausedDeposit = true;
            emit DepositPaused();
        }
        if (!pausedRedeem) {
            pausedRedeem = true;
            emit RedeemPaused();
        }
        if (!pausedClaim) {
            pausedClaim = true;
            emit ClaimPaused();
        }
    }

    function _pauseAllocationIfNeeded() internal {
        if (!pausedAllocation) {
            // Strategy incidents should not allow fresh outbound allocation while loss recovery or writeoff is assessed.
            pausedAllocation = true;
            emit AllocationPaused();
        }
    }

    function _disableStrategy(IStrategy _strategy, StrategyConfig storage _config) internal {
        uint256 oldWeight = _config.weightBps;
        if (oldWeight != 0) {
            totalWeightBps -= oldWeight;
        }
        _config.weightBps = 0;
        _config.enabled = false;

        emit StrategyUpdated(address(_strategy), 0, _config.cap, false);
        emit StrategyEmergencyDisabled(address(_strategy), oldWeight);
    }

    function _tryEstimatedTotalUnderlying(IStrategy _strategy)
        internal
        view
        returns (uint256 estimated, bool available)
    {
        // Check each probe at its call boundary: the previous probe may have spent its budget.
        // Bubble caller underfunding instead of treating a clipped stipend as valuation failure.
        uint256 budget = strategyValuationGasBudget();
        if (gasleft() < budget * 64 / 63 + STRATEGY_VALUATION_GAS_MARGIN) {
            revert InsufficientGasForExternalCall();
        }
        try _strategy.estimatedTotalUnderlying{gas: budget}() returns (uint256 value) {
            return (value, true);
        } catch {
            return (0, false);
        }
    }

    function _tryPrincipal(IStrategy _strategy) internal view returns (uint256 principal_, bool available) {
        uint256 budget = strategyValuationGasBudget();
        if (gasleft() < budget * 64 / 63 + STRATEGY_VALUATION_GAS_MARGIN) {
            revert InsufficientGasForExternalCall();
        }
        try _strategy.principal{gas: budget}() returns (uint256 value) {
            return (value, true);
        } catch {
            return (0, false);
        }
    }

    /// @dev A Strategy is "registered" while it sits in `strategies[]` — enabled,
    ///      or merely disabled-but-not-yet-removed (so it can still push back its
    ///      remaining principal via `receiveFromStrategy`). Bounded by
    ///      MAX_STRATEGIES.
    function _isRegisteredStrategy(IStrategy _strategy) internal view returns (bool) {
        (, bool found) = _strategyIndex(_strategy);
        return found;
    }

    function _strategyIndex(IStrategy _strategy) internal view returns (uint256 index, bool found) {
        uint256 strategyCount = strategies.length;
        for (uint256 strategyIndex; strategyIndex < strategyCount; strategyIndex++) {
            if (strategies[strategyIndex] == _strategy) return (strategyIndex, true);
        }
        return (0, false);
    }

    /// @dev Split `_amount` across enabled Strategies by `weightBps`, respecting
    ///      each Strategy's cap. Cap-trimmed remainder stays in the buffer (it is
    ///      NOT re-spread to other Strategies). Push deposit: transfer underlying
    ///      to the Strategy first, then call `deposit` with the Strategy's net
    ///      receipt so principal cannot be inflated by transfer fees. A rejected
    ///      deposit is skipped only after the Strategy returns the funds and the
    ///      Vault's exact pre-transfer balance is restored.
    function _allocateToStrategies(uint256 _amount) internal {
        if (totalWeightBps == 0) return;
        for (uint256 strategyIndex; strategyIndex < strategies.length; strategyIndex++) {
            IStrategy strategy = strategies[strategyIndex];
            StrategyConfig storage strategyConfig = strategyConfigs[strategy];
            if (!strategyConfig.enabled) continue;

            uint256 targetAllocation = Math.mulDiv(_amount, strategyConfig.weightBps, totalWeightBps);
            if (targetAllocation == 0) continue;

            // Cap check (per-Strategy upper bound). Allocation requires a full
            // live valuation because fallback cache is based on min(est, principal).
            (uint256 currentEstimatedUnderlying,,,, uint256 currentConservativeValue, bool liveAvailable) =
                _liveStrategyValuation(strategy);
            if (!liveAvailable) {
                emit StrategyAllocationSkipped(address(strategy));
                continue;
            }
            if (currentEstimatedUnderlying >= strategyConfig.cap) {
                emit StrategyAllocationSkipped(address(strategy));
                continue;
            }
            uint256 remainingStrategyCap = strategyConfig.cap - currentEstimatedUnderlying;
            if (targetAllocation > remainingStrategyCap) targetAllocation = remainingStrategyCap;

            uint256 strategyUnderlyingBeforeTransfer = underlying.balanceOf(address(strategy));
            underlying.safeTransfer(address(strategy), targetAllocation);
            uint256 strategyUnderlyingReceived =
                underlying.balanceOf(address(strategy)) - strategyUnderlyingBeforeTransfer;
            if (strategy.deposit(targetAllocation, strategyUnderlyingReceived) == 0) {
                emit StrategyAllocationSkipped(address(strategy));
                continue;
            }
            if (!_refreshStrategyValuation(strategy)) {
                _setStrategyValuationCache(strategy, currentConservativeValue + strategyUnderlyingReceived);
            }
            emit StrategyAllocated(address(strategy), strategyUnderlyingReceived);
        }
    }
}
