// SPDX-License-Identifier: BUSL-1.1

pragma solidity 0.8.24;

import "openzeppelin-contracts/contracts/interfaces/IERC4626.sol";

import "./BaseStrategy.sol";

/// @notice Minimal Morpho Vaults V2 surface used by this Strategy: the ERC-4626
///         core plus the permissionless `forceDeallocate` escape hatch that
///         pulls liquidity out of a market adapter for a share-paid penalty.
interface IMorphoVaultV2 is IERC4626 {
    function forceDeallocate(address adapter, bytes calldata data, uint256 assets, address onBehalf)
        external
        returns (uint256 penaltyShares);
}

/**
 * @title MorphoV2Strategy - Morpho Vaults V2 Strategy (push model, Upgradeable)
 * @notice Synchronous Strategy adapter for Morpho Vaults V2 whose `asset()` is
 *         the same token as this Strategy's underlying.
 * @dev    Morpho Vaults V2 keeps the ERC-4626 call surface but returns 0 from
 *         `maxDeposit`/`maxMint`/`maxWithdraw`/`maxRedeem` unconditionally, so
 *         unlike `ERC4626Strategy` this adapter never clamps against the max*
 *         views: it clamps only to the value of its own tracked shares and
 *         attempts the venue call inside an isolated self-call frame.
 *
 *         Venue behavior designed against:
 *           - Deposits are synchronous but CAN revert when the liquidity
 *             adapter's caps are hit or a receive gate is set. A rejected
 *             deposit reverts the isolated frame; `BaseStrategy.deposit`
 *             catches it and returns the exact receipt to the Vault, so no
 *             funds are stranded here (Low-01 recovery path).
 *           - Withdrawals pay from idle then deallocate from the single
 *             liquidity adapter; liquidity-short reverts bubble up as UNTYPED
 *             lower-level errors. The Strategy retries a bounded sequence of
 *             half-size requests before converting all-failed recovery into a
 *             fail-soft `0` result (ADR-006), with failed venue state rolled
 *             back per isolated attempt.
 *           - Losses reflect immediately in `convertToAssets` (maxRate caps
 *             gains only). No in-kind redemption: only underlying ever arrives
 *             from withdraw/redeem.
 *           - Rewards are Merkl-only (URD deprecated); the inherited
 *             `BaseStrategy.claimMerklRewards` / `sweepRewardToken` suffice.
 *
 *         Liquidity recovery map:
 *           - normal liquidity  -> `sendToVault` / `sendProfitToVault`
 *                                  (`_doWithdraw`);
 *           - vault idle only   -> owner `emergencyWithdrawFromMorphoV2` with a
 *                                  share cap sized to the redeemable portion;
 *           - no liquidity      -> WRITEOFF_ROLE through
 *                                  `CollateralVault.forceDeallocateMorphoV2`
 *                                  (atomic pauses/backing floor; penalty paid
 *                                  in this Strategy's shares and bounded by the
 *                                  init-frozen `maxForceDeallocatePenaltyBps`),
 *                                  with withdrawal to the Vault in the same
 *                                  transaction and a minimum actual receipt.
 *
 *         Venue freeze policy: deploy only against Morpho V2 vaults whose
 *         receive-/send-share gates are unset. A gate installed later surfaces
 *         as a recovered deposit rejection or a fail-soft withdraw, never as
 *         stranded funds.
 *
 *         Anyone can transfer vault shares directly to this contract, but
 *         donated shares must not inflate `estimatedTotalUnderlying()` or
 *         `realizedYield()`; only shares minted through this Strategy's own
 *         deposits are valued.
 */
contract MorphoV2Strategy is BaseStrategy {
    using SafeERC20 for IERC20;

    // =============================================================
    //                         CONSTANTS
    // =============================================================

    /// @notice Protocol-level ceiling for `forceDeallocatePenalty` (2%).
    uint256 public constant MAX_FORCE_DEALLOCATE_PENALTY_BPS = 200;

    /// @dev One full-size attempt plus seven bounded half-size probes. This
    ///      recovers useful liquidity without relying on Morpho V2's hard-zero
    ///      max* views or permitting an unbounded retry loop.
    uint256 internal constant _MAX_WITHDRAW_ATTEMPTS = 8;

    uint256 internal constant _BPS_DENOMINATOR = 10_000;

    // =============================================================
    //                         STATE
    // =============================================================

    /// @notice Morpho Vaults V2 vault this Strategy deposits into.
    IMorphoVaultV2 public morphoVault;

    /// @notice Maximum forceDeallocate penalty (in bps of deallocated assets)
    ///         this Strategy accepts before reverting. Frozen at initialization
    ///         (no setter); must not exceed the 2% protocol maximum.
    uint256 public maxForceDeallocatePenaltyBps;

    /// @notice Vault shares minted through this Strategy's own deposits, minus
    ///         shares burned through its own withdrawals and penalties.
    /// @dev Third-party share transfers to this contract do not affect this
    ///      value, so regular valuation ignores share-token donations.
    uint256 internal _ownShares;

    /// @dev Storage gap for future upgrades of this derived contract.
    uint256[47] private __gapMorphoV2;

    // =============================================================
    //                          EVENTS
    // =============================================================

    event OwnSharesUpdated(uint256 newOwnShares);
    event ForceDeallocated(address indexed adapter, uint256 assets, uint256 penaltyShares, uint256 penaltyAssets);

    // =============================================================
    //                          ERRORS
    // =============================================================

    error InvalidMorphoVaultAsset();
    error MorphoV2ZeroShares();
    error MorphoV2ShareBalanceMismatch();
    error MorphoV2AssetAmountMismatch(uint256 reported, uint256 actual);
    error MorphoV2DepositRejected();
    error ForceDeallocatePenaltyAboveMax(uint256 requestedBps, uint256 maxBps);
    error ForceDeallocatePenaltyExceeded(uint256 penaltyAssets, uint256 maxPenaltyAssets);

    // =============================================================
    //                        INITIALIZER
    // =============================================================

    function initialize(
        address _vault,
        IERC20 _underlying,
        address _owner,
        address _upgrader,
        IMorphoVaultV2 _morphoVault,
        uint256 _maxForceDeallocatePenaltyBps
    ) external initializer {
        __BaseStrategy_init(_vault, _underlying, _owner, _upgrader);

        if (address(_morphoVault) == address(0)) revert ZeroAddress();
        if (address(_morphoVault).code.length == 0) revert NotContract(address(_morphoVault));
        if (_morphoVault.asset() != address(_underlying)) revert InvalidMorphoVaultAsset();
        if (_maxForceDeallocatePenaltyBps > MAX_FORCE_DEALLOCATE_PENALTY_BPS) {
            revert ForceDeallocatePenaltyAboveMax(_maxForceDeallocatePenaltyBps, MAX_FORCE_DEALLOCATE_PENALTY_BPS);
        }

        morphoVault = _morphoVault;
        maxForceDeallocatePenaltyBps = _maxForceDeallocatePenaltyBps;

        _underlying.forceApprove(address(_morphoVault), type(uint256).max);
    }

    // =============================================================
    //                        VIEW FUNCTIONS
    // =============================================================

    /// @notice Vault shares currently attributed to this Strategy's own deposits.
    function ownShares() external view returns (uint256) {
        return _ownShares;
    }

    // =============================================================
    //                  BaseStrategy HOOKS
    // =============================================================

    /// @inheritdoc BaseStrategy
    /// @dev Morpho Vaults V2 deposits are synchronous but can be rejected by
    ///      the venue (liquidity-adapter caps, receive gate). The venue call
    ///      runs in an isolated self-call so a rejection rolls back cleanly and
    ///      is re-raised as a typed error: `BaseStrategy.deposit` catches it
    ///      and routes the exact receipt back to the Vault (Low-01 recovery)
    ///      instead of stranding idle underlying in this Strategy.
    function _doDeposit(uint256 _amount) internal override {
        try this.depositIntoMorphoVault(_amount) {}
        catch {
            revert MorphoV2DepositRejected();
        }
    }

    /// @notice Execute the Morpho vault deposit in an isolated call frame.
    /// @dev Self-only. Exact share-delta checks stay inside this frame so a
    ///      lying or zero-share venue response rolls back its own effects.
    function depositIntoMorphoVault(uint256 _amount) external {
        if (msg.sender != address(this)) revert Unauthorized();

        uint256 shareBalanceBefore = morphoVault.balanceOf(address(this));
        uint256 reportedMintedShares = morphoVault.deposit(_amount, address(this));
        uint256 shareBalanceAfter = morphoVault.balanceOf(address(this));
        if (shareBalanceAfter < shareBalanceBefore) revert MorphoV2ShareBalanceMismatch();

        uint256 actualMintedShares = shareBalanceAfter - shareBalanceBefore;
        if (actualMintedShares == 0) revert MorphoV2ZeroShares();
        if (actualMintedShares != reportedMintedShares) revert MorphoV2ShareBalanceMismatch();

        _ownShares += actualMintedShares;
        emit OwnSharesUpdated(_ownShares);
    }

    /// @inheritdoc BaseStrategy
    /// @dev Morpho Vaults V2 reports 0 from `maxWithdraw` unconditionally, so
    ///      the request is clamped only to the value of locally tracked shares.
    ///      The venue call runs in an isolated self-call: liquidity-short
    ///      deallocations bubble up as untyped lower-level reverts and are
    ///      converted into a fail-soft `0` result (ADR-006) with all venue
    ///      state rolled back.
    function _doWithdraw(uint256 _amount) internal override returns (uint256 actual) {
        // Same share basis as `_estimatedTotalUnderlying`: own shares capped by
        // the live balance, so a lost-shares scenario partially recovers
        // instead of failing soft on an over-sized venue request.
        uint256 ownShares_ = _ownShares;
        uint256 currentShareBalance = morphoVault.balanceOf(address(this));
        uint256 effectiveShares = ownShares_ < currentShareBalance ? ownShares_ : currentShareBalance;
        if (effectiveShares == 0) return 0;

        uint256 trackedAssets = morphoVault.convertToAssets(effectiveShares);
        uint256 assetsToWithdraw = _amount < trackedAssets ? _amount : trackedAssets;
        if (assetsToWithdraw == 0) return 0;

        for (uint256 attempt; attempt < _MAX_WITHDRAW_ATTEMPTS; ++attempt) {
            try this.withdrawFromMorphoVault(assetsToWithdraw) returns (uint256 withdrawn) {
                return withdrawn;
            } catch {
                if (assetsToWithdraw == 1) return 0;
                assetsToWithdraw /= 2;
            }
        }

        return 0;
    }

    /// @notice Execute the Morpho vault withdrawal in an isolated call frame.
    /// @dev Self-only. Exact share-delta / asset-delta mismatch reverts stay
    ///      inside this frame so a hostile venue response (lying return value,
    ///      zero-share burn, short asset delivery) rolls back its own effects
    ///      before the outer fail-soft catch reports `0`.
    function withdrawFromMorphoVault(uint256 _assets) external returns (uint256 actualAssets) {
        if (msg.sender != address(this)) revert Unauthorized();

        uint256 ownShares_ = _ownShares;
        uint256 underlyingBalanceBefore = underlyingToken.balanceOf(address(this));
        uint256 shareBalanceBefore = morphoVault.balanceOf(address(this));
        uint256 reportedBurnedShares = morphoVault.withdraw(_assets, address(this), address(this));
        uint256 shareBalanceAfter = morphoVault.balanceOf(address(this));
        if (shareBalanceAfter > shareBalanceBefore) revert MorphoV2ShareBalanceMismatch();

        uint256 actualBurnedShares = shareBalanceBefore - shareBalanceAfter;
        if (actualBurnedShares == 0) revert MorphoV2ZeroShares();
        if (actualBurnedShares != reportedBurnedShares) revert MorphoV2ShareBalanceMismatch();
        actualAssets = underlyingToken.balanceOf(address(this)) - underlyingBalanceBefore;
        if (actualAssets != _assets) revert MorphoV2AssetAmountMismatch(_assets, actualAssets);

        _ownShares = actualBurnedShares > ownShares_ ? 0 : ownShares_ - actualBurnedShares;
        emit OwnSharesUpdated(_ownShares);
    }

    /// @inheritdoc BaseStrategy
    /// @dev Values only the shares minted through this Strategy's own deposit
    ///      path, capped by the current share balance in case of an upstream or
    ///      accidental share loss. Direct share-token donations are ignored.
    ///      Venue losses reflect here immediately via `convertToAssets`.
    function _estimatedTotalUnderlying() internal view override returns (uint256) {
        uint256 currentShareBalance = morphoVault.balanceOf(address(this));
        uint256 effectiveShares = _ownShares < currentShareBalance ? _ownShares : currentShareBalance;
        if (effectiveShares == 0) return 0;
        return morphoVault.convertToAssets(effectiveShares);
    }

    /// @inheritdoc BaseStrategy
    /// @dev The Morpho vault share token is the position token, not a reward token.
    function _isSweepProtectedToken(address _token) internal view override returns (bool) {
        return super._isSweepProtectedToken(_token) || _token == address(morphoVault);
    }

    // =============================================================
    //                   EMERGENCY FUNCTIONS
    // =============================================================

    /**
     * @notice Redeem up to `_maxShares` of this Strategy's own Morpho vault
     *         shares and immediately push all idle underlying back to the
     *         Vault in the same transaction.
     * @dev Owner only. `maxRedeem` is always 0 on Morpho Vaults V2, so the cap
     *      is `min(full share balance, _maxShares)` — donated shares included,
     *      matching `emergencyWithdrawFromERC4626`, since this is their only
     *      recovery path (`sweepRewardToken` rejects the position token). The
     *      venue redeem simply reverts if liquidity is short — size `_maxShares`
     *      to the vault's idle/deallocatable portion. When deallocation is
     *      required, use the Vault's atomic force-deallocation recovery. Receipt is
     *      accounted as returned principal. If recovered plus still-valued
     *      assets are short of principal, a Vault WRITEOFF_ROLE holder must call
     *      `Vault.writeoffStrategyPrincipal(...)`.
     * @param _maxShares Upper bound on shares to redeem (pass
     *        `type(uint256).max` for a full drain attempt).
     */
    function emergencyWithdrawFromMorphoV2(uint256 _maxShares)
        external
        onlyOwner
        nonReentrantStrategy
        returns (uint256 sent)
    {
        uint256 currentShareBalance = morphoVault.balanceOf(address(this));
        uint256 sharesToRedeem = _maxShares < currentShareBalance ? _maxShares : currentShareBalance;

        if (sharesToRedeem != 0) {
            uint256 underlyingBalanceBefore = underlyingToken.balanceOf(address(this));
            uint256 reportedAssets = morphoVault.redeem(sharesToRedeem, address(this), address(this));
            uint256 shareBalanceAfter = morphoVault.balanceOf(address(this));
            if (shareBalanceAfter > currentShareBalance) revert MorphoV2ShareBalanceMismatch();
            uint256 actualBurnedShares = currentShareBalance - shareBalanceAfter;
            if (actualBurnedShares != sharesToRedeem) revert MorphoV2ShareBalanceMismatch();
            uint256 actualAssets = underlyingToken.balanceOf(address(this)) - underlyingBalanceBefore;
            if (reportedAssets != actualAssets) revert MorphoV2AssetAmountMismatch(reportedAssets, actualAssets);

            // Burn donated shares first. This function is the only one that sizes against the
            // raw balance -- `_estimatedTotalUnderlying` and `_doWithdraw` both clamp to
            // `min(_ownShares, balance)` so donations are invisible to them. Decrementing
            // `_ownShares` by the full redeemed count would therefore charge a donation
            // recovery against the Strategy's own position: the shares stay in the vault but
            // stop being counted, which understates `estimatedTotalUnderlying()`, feeds
            // `CollateralVault.backingRatio()`, and reprices every Trove on the branch.
            uint256 ownShares_ = _ownShares;
            uint256 donatedShares = currentShareBalance > ownShares_ ? currentShareBalance - ownShares_ : 0;
            uint256 ownSharesBurned = sharesToRedeem > donatedShares ? sharesToRedeem - donatedShares : 0;
            _ownShares = ownSharesBurned > ownShares_ ? 0 : ownShares_ - ownSharesBurned;
            emit OwnSharesUpdated(_ownShares);
        }

        uint256 idleUnderlying = underlyingToken.balanceOf(address(this));
        if (idleUnderlying == 0) return 0;

        sent = _returnUnderlyingPrincipalToVault(idleUnderlying);
    }

    /**
     * @notice Force the Morpho vault to deallocate `_assets` from a market
     *         adapter into idle liquidity, paying the venue penalty from this
     *         Strategy's own shares.
     * @dev Vault only. `forceDeallocate` is PERMISSIONLESS on the Morpho vault,
     *      but it must be called through this wrapper because the penalty
     *      (`assets * forceDeallocatePenalty[adapter]`, protocol max 2%) is
     *      burned from the caller-designated `onBehalf` shares — calling from
     *      the Strategy means the Strategy's shares pay. The wrapper measures
     *      the actual share burn and reverts if it exceeds the init-frozen
     *      `maxForceDeallocatePenaltyBps` bound (plus 1 wei of round-trip
     *      rounding). Donated (untracked) shares absorb the burn first; only
     *      the burn that reduces `_ownShares` is a confirmed valuation loss.
     *      Immediately withdraws up to `_assets` of tracked value and transfers
     *      it to the Vault without a callback into its locked incident entry.
     *      The Vault enforces a nonzero minimum actual receipt atomically.
     */
    function forceDeallocate(address _adapter, bytes calldata _data, uint256 _assets)
        external
        onlyVault
        nonReentrantStrategy
        returns (uint256 penaltyShares, uint256 penaltyAssets, uint256 valuationLossAssets, uint256 withdrawnAssets)
    {
        uint256 shareBalanceBefore = morphoVault.balanceOf(address(this));
        morphoVault.forceDeallocate(_adapter, _data, _assets, address(this));
        uint256 shareBalanceAfter = morphoVault.balanceOf(address(this));
        if (shareBalanceAfter > shareBalanceBefore) revert MorphoV2ShareBalanceMismatch();

        penaltyShares = shareBalanceBefore - shareBalanceAfter;
        penaltyAssets = penaltyShares == 0 ? 0 : morphoVault.convertToAssets(penaltyShares);
        // Boundary note: the venue rounds penalty assets and the resulting
        // share burn UP, while `convertToAssets` here rounds DOWN, so at a
        // venue whose penalty sits exactly on `maxForceDeallocatePenaltyBps`
        // the measured burn can exceed this bound by up to one share's asset
        // value and revert. That is deliberately fail-closed (never accept
        // more than the frozen bound); the operator remedy is to retry with a
        // smaller `_assets` so the rounding contribution shrinks relative to
        // the bound.
        uint256 maxPenaltyAssets = (_assets * maxForceDeallocatePenaltyBps) / _BPS_DENOMINATOR + 1;
        if (penaltyAssets > maxPenaltyAssets) revert ForceDeallocatePenaltyExceeded(penaltyAssets, maxPenaltyAssets);

        uint256 ownShares_ = _ownShares;
        _ownShares = shareBalanceAfter < ownShares_ ? shareBalanceAfter : ownShares_;
        uint256 ownSharesCharged = ownShares_ - _ownShares;
        valuationLossAssets = ownSharesCharged == 0 ? 0 : morphoVault.convertToAssets(ownSharesCharged);
        emit OwnSharesUpdated(_ownShares);
        emit ForceDeallocated(_adapter, _assets, penaltyShares, penaltyAssets);
        withdrawnAssets = _doWithdraw(_assets);
        _accountReturnedPrincipal(_sendUnderlyingToVault(withdrawnAssets));
    }
}
