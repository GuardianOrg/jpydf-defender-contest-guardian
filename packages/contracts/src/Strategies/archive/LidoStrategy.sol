// SPDX-License-Identifier: BUSL-1.1

pragma solidity 0.8.24;

/**
 * @dev ARCHIVED — `LidoStrategy` (WETH -> ETH -> stETH -> wstETH, async Withdrawal Queue exit).
 *
 * Status: Archived / Out of Day-1 scope.
 *
 * Reason: this contract's underlying is structurally WETH -- `initialize` takes
 * `IWETH _weth` and passes it to `__BaseStrategy_init` as the underlying, and the
 * deposit path unwraps WETH to native ETH before `lido.submit`. There is no
 * in-contract `require(underlying == WETH)`; the rejection of a non-WETH underlying
 * lived in the `DeployLiquity2` strategy selector, whose `lido` / `etherfi-weeth`
 * kinds, venue structs, helpers, and env keys were removed in PR #1424. Branch 0's
 * Vault underlying then moved from WETH to wstETH, so no current branch can supply
 * a WETH underlying and no reachable deploy/register path remains.
 *
 * Audit status: this source was in scope for, and covered by, the external audit
 * completed 2026-08-05 against audited identity `0c7766e0`. It is preserved here
 * unmodified so that audit result is not discarded. It is out of the ACTIVE audit
 * scope from this commit onward; see
 * `documents/en/engineering/guides/Contract-Audit-Scope-And-nSLOC.md`.
 *
 * Re-activation requires re-entry into the `DeployLiquity2` strategy selector plus
 * a fresh strategy activation package (venue evidence, risk sign-off, and an
 * audit-scope change). Do not deploy, register, fund, or route to this contract.
 */

import "openzeppelin-contracts/contracts/token/ERC20/IERC20.sol";
import "openzeppelin-contracts/contracts/token/ERC20/utils/SafeERC20.sol";

import "../../Interfaces/IWETH.sol";
import "./AsyncRequestStrategy.sol";

/**
 * @title IStETH - Lido stETH interface (minimal)
 */
interface IStETH is IERC20 {
    function sharesOf(address account) external view returns (uint256);
    function getPooledEthByShares(uint256 sharesAmount) external view returns (uint256);
}

/**
 * @title IWstETH - Lido wstETH interface (minimal)
 */
interface IWstETH is IERC20 {
    function wrap(uint256 stETHAmount) external returns (uint256);
    function unwrap(uint256 wstETHAmount) external returns (uint256);
    function stETH() external view returns (address);
    function getStETHByWstETH(uint256 wstETHAmount) external view returns (uint256);
    function getWstETHByStETH(uint256 stETHAmount) external view returns (uint256);
    function stEthPerToken() external view returns (uint256);
}

/**
 * @title ILido - Lido staking interface (minimal)
 */
interface ILido is IStETH {
    function submit(address referral) external payable returns (uint256);
}

/**
 * @title IWithdrawalQueueERC721 - Lido Withdrawal Queue interface (minimal)
 */
interface IWithdrawalQueueERC721 {
    function requestWithdrawalsWstETH(uint256[] calldata amounts, address owner)
        external
        returns (uint256[] memory requestIds);
    function claimWithdrawals(uint256[] calldata requestIds, uint256[] calldata hints) external;
    function claimWithdrawal(uint256 requestId) external;
    function MIN_STETH_WITHDRAWAL_AMOUNT() external view returns (uint256);
    function MAX_STETH_WITHDRAWAL_AMOUNT() external view returns (uint256);
    function ownerOf(uint256 requestId) external view returns (address owner);
}

/**
 * @title LidoStrategy - Lido wstETH async Strategy (push model, Upgradeable)
 * @notice Stakes WETH into Lido, wraps stETH into wstETH, and hides Withdrawal Queue asynchrony
 *         behind Strategy-specific keeper functions. The BaseStrategy surface
 *         remains synchronous: `sendToVault` and `sendProfitToVault` can only
 *         push WETH that was already claimed from Lido and wrapped.
 * @dev    wstETH is freely transferable, so this Strategy values only the
 *         wstETH minted by its own `submit` -> `wrap` calls. Direct stETH or
 *         wstETH donations do not inflate `estimatedTotalUnderlying()` or
 *         `realizedYield()`. Claimed idle WETH is tracked separately so direct
 *         WETH donations cannot be misreported as claimable Lido value.
 */
contract LidoStrategy is AsyncRequestStrategy {
    using SafeERC20 for IERC20;

    // =============================================================
    //                         STATE
    // =============================================================

    ILido public lido;
    IStETH public stETH;
    IWstETH public wstETH;
    IWithdrawalQueueERC721 public withdrawalQueue;
    IWETH public weth;
    address public referral;

    /// @notice wstETH minted through this Strategy's own Lido deposits,
    ///         minus wstETH transferred to the Withdrawal Queue by this Strategy.
    uint256 internal _ownWstETH;

    /// @dev Storage gap for future upgrades of this derived contract.
    uint256[40] private __gapLido;

    uint256 public constant MAX_LIDO_WITHDRAWAL_REQUESTS_PER_CALL = 32;

    // =============================================================
    //                          EVENTS
    // =============================================================

    event ReferralUpdated(address indexed referral);
    event WithdrawRequested(uint256[] requestIds, uint256 stETHAmount);
    event WithdrawClaimed(uint256[] requestIds, uint256 ethReceived);
    event OwnWstETHUpdated(uint256 ownWstETH);

    // =============================================================
    //                          ERRORS
    // =============================================================

    error AmountOutOfRange();
    error AmountExceedsStaked();
    error WithdrawalQueueRequestMismatch();
    error LidoZeroShares();
    error LidoShareBalanceMismatch();
    error InvalidWstETHStETH();
    error InvalidWithdrawalQueueBounds();
    error ClaimHintsRequired();
    error LidoWithdrawalRequestTooLarge(uint256 requestCount, uint256 maxRequestCount);
    error UnexpectedWithdrawalRequestOwner(address owner);

    // =============================================================
    //                        INITIALIZER
    // =============================================================

    function initialize(
        address _vault,
        IWETH _weth,
        address _owner,
        address _upgrader,
        ILido _lido,
        IWstETH _wstETH,
        IWithdrawalQueueERC721 _withdrawalQueue,
        address _referral
    ) external initializer {
        __BaseStrategy_init(_vault, IERC20(address(_weth)), _owner, _upgrader);
        __AsyncRequestStrategy_init();

        if (address(_lido) == address(0)) revert ZeroAddress();
        if (address(_wstETH) == address(0)) revert ZeroAddress();
        if (address(_withdrawalQueue) == address(0)) revert ZeroAddress();
        if (address(_lido).code.length == 0) revert NotContract(address(_lido));
        if (address(_wstETH).code.length == 0) revert NotContract(address(_wstETH));
        if (address(_withdrawalQueue).code.length == 0) revert NotContract(address(_withdrawalQueue));
        if (_wstETH.stETH() != address(_lido)) revert InvalidWstETHStETH();

        uint256 minWithdrawalAmount = _withdrawalQueue.MIN_STETH_WITHDRAWAL_AMOUNT();
        uint256 maxWithdrawalAmount = _withdrawalQueue.MAX_STETH_WITHDRAWAL_AMOUNT();
        if (minWithdrawalAmount == 0 || maxWithdrawalAmount < minWithdrawalAmount) {
            revert InvalidWithdrawalQueueBounds();
        }

        lido = _lido;
        stETH = IStETH(address(_lido));
        wstETH = _wstETH;
        withdrawalQueue = _withdrawalQueue;
        weth = _weth;
        referral = _referral;

        IERC20(address(_lido)).forceApprove(address(_wstETH), type(uint256).max);
        IERC20(address(_wstETH)).forceApprove(address(_withdrawalQueue), type(uint256).max);
    }

    receive() external payable {}

    // =============================================================
    //                    LIDO-SPECIFIC VIEWS
    // =============================================================

    function ownWstETH() external view returns (uint256) {
        return _ownWstETH;
    }

    // =============================================================
    //                    LIDO-SPECIFIC MUTATORS
    // =============================================================

    function requestLidoWithdrawal(uint256 _stETHAmount)
        external
        nonReentrantStrategy
        onlyVaultRole(_ALLOCATOR_ROLE)
        returns (uint256[] memory requestIds)
    {
        requestIds = _requestLidoWithdrawal(_stETHAmount);
    }

    /// @notice Claim finalized Lido withdrawal requests owned by this Strategy.
    /// @dev Permissionless so finalized losses cannot remain hidden from
    ///      `estimatedTotalUnderlying()` only because the allocator has not acted.
    function claimLidoWithdrawals(uint256[] calldata _requestIds) external nonReentrantStrategy {
        if (_requestIds.length > 1) revert ClaimHintsRequired();
        _claimLidoWithdrawals(_requestIds, new uint256[](0), false);
    }

    /// @notice Claim finalized Lido withdrawal requests owned by this Strategy using checkpoint hints.
    /// @dev Permissionless for the same reason as the single-request overload.
    function claimLidoWithdrawals(uint256[] calldata _requestIds, uint256[] calldata _hints)
        external
        nonReentrantStrategy
    {
        _claimLidoWithdrawals(_requestIds, _hints, true);
    }

    function _claimLidoWithdrawals(uint256[] calldata _requestIds, uint256[] memory _hints, bool _useHints) internal {
        uint256 requestCount = _requestIds.length;
        if (requestCount == 0) return;
        _requireAsyncClaimRequestCount(requestCount);
        if (_useHints && requestCount != _hints.length) revert WithdrawalQueueRequestMismatch();

        for (uint256 requestIndex = 0; requestIndex < requestCount; requestIndex++) {
            _removePendingRequest(_requestIds[requestIndex]);
        }

        uint256 ethBalanceBeforeClaim = address(this).balance;
        if (_useHints) {
            withdrawalQueue.claimWithdrawals(_requestIds, _hints);
        } else {
            withdrawalQueue.claimWithdrawal(_requestIds[0]);
        }
        uint256 ethReceived = address(this).balance - ethBalanceBeforeClaim;

        uint256 underlyingBalanceBeforeWrap = underlyingToken.balanceOf(address(this));
        if (ethReceived != 0) {
            weth.deposit{value: ethReceived}();
        }
        uint256 underlyingReceived = underlyingToken.balanceOf(address(this)) - underlyingBalanceBeforeWrap;
        _increaseOwnIdleUnderlying(underlyingReceived);

        emit WithdrawClaimed(_requestIds, ethReceived);
    }

    function emergencyWithdrawFromLido() external onlyOwner nonReentrantStrategy returns (uint256 sent) {
        sent = _emergencyWithdrawFromLido(_maxLidoWithdrawalRequestAmount());
    }

    function emergencyWithdrawFromLido(uint256 _maxStETHToRequest)
        external
        onlyOwner
        nonReentrantStrategy
        returns (uint256 sent)
    {
        sent = _emergencyWithdrawFromLido(_maxStETHToRequest);
    }

    function setReferral(address _referral) external onlyOwner {
        referral = _referral;
        emit ReferralUpdated(_referral);
    }

    function _emergencyWithdrawFromLido(uint256 _maxStETHToRequest) internal returns (uint256 sent) {
        uint256 idleUnderlying = _ownedIdleUnderlyingValue();
        if (idleUnderlying != 0) {
            sent = _returnUnderlyingPrincipalToVault(idleUnderlying);
        }

        uint256 remainingStakedUnderlying = _stakedUnderlyingValue();
        uint256 minWithdrawalAmount = withdrawalQueue.MIN_STETH_WITHDRAWAL_AMOUNT();
        uint256 maxRequestAmount = _maxLidoWithdrawalRequestAmount();
        uint256 cappedMaxStETHToRequest = _maxStETHToRequest < maxRequestAmount ? _maxStETHToRequest : maxRequestAmount;
        if (remainingStakedUnderlying >= minWithdrawalAmount && cappedMaxStETHToRequest >= minWithdrawalAmount) {
            uint256 requestAmount = remainingStakedUnderlying < cappedMaxStETHToRequest
                ? remainingStakedUnderlying
                : cappedMaxStETHToRequest;
            _requestLidoWithdrawal(requestAmount, true);
        }
    }

    // =============================================================
    //                  BaseStrategy HOOKS
    // =============================================================

    /// @inheritdoc BaseStrategy
    function _doDeposit(uint256 _amount) internal override {
        uint256 stETHBalanceBeforeSubmit = stETH.balanceOf(address(this));
        uint256 stETHSharesBeforeSubmit = stETH.sharesOf(address(this));
        weth.withdraw(_amount);
        uint256 reportedStETHShares = lido.submit{value: _amount}(referral);
        uint256 stETHSharesAfterSubmit = stETH.sharesOf(address(this));
        if (stETHSharesAfterSubmit < stETHSharesBeforeSubmit) revert LidoShareBalanceMismatch();
        uint256 actualStETHShares = stETHSharesAfterSubmit - stETHSharesBeforeSubmit;
        if (reportedStETHShares == 0 || actualStETHShares == 0) revert LidoZeroShares();
        if (reportedStETHShares != actualStETHShares) revert LidoShareBalanceMismatch();
        uint256 stETHReceived = stETH.balanceOf(address(this)) - stETHBalanceBeforeSubmit;

        uint256 wstETHBalanceBeforeWrap = wstETH.balanceOf(address(this));
        uint256 reportedWstETHMinted = wstETH.wrap(stETHReceived);
        uint256 wstETHBalanceAfterWrap = wstETH.balanceOf(address(this));
        if (wstETHBalanceAfterWrap < wstETHBalanceBeforeWrap) revert LidoShareBalanceMismatch();

        uint256 actualWstETHMinted = wstETHBalanceAfterWrap - wstETHBalanceBeforeWrap;
        if (actualWstETHMinted == 0) revert LidoZeroShares();
        if (actualWstETHMinted != reportedWstETHMinted) revert LidoShareBalanceMismatch();

        _ownWstETH += actualWstETHMinted;
        emit OwnWstETHUpdated(_ownWstETH);
    }

    /// @inheritdoc BaseStrategy
    /// @dev Only already-claimed and wrapped WETH can be pushed synchronously.
    ///      stETH unstaking happens through `requestLidoWithdrawal` and
    ///      `claimLidoWithdrawals`.
    function _doWithdraw(uint256 _amount) internal override returns (uint256 actual) {
        actual = _takeOwnIdleUnderlying(_amount);
    }

    /// @inheritdoc BaseStrategy
    function _estimatedTotalUnderlying() internal view override returns (uint256) {
        return _stakedUnderlyingValue() + _pendingWithdrawalValuation() + _ownedIdleUnderlyingValue();
    }

    /// @inheritdoc BaseStrategy
    /// @dev stETH, wstETH, and the Withdrawal Queue NFT are position/accounting
    ///      assets, not reward tokens.
    function _isSweepProtectedToken(address _token) internal view override returns (bool) {
        return super._isSweepProtectedToken(_token) || _token == address(stETH) || _token == address(wstETH)
            || _token == address(withdrawalQueue);
    }

    // =============================================================
    //                   INTERNAL HELPERS
    // =============================================================

    function _requestLidoWithdrawal(uint256 _stETHAmount) internal returns (uint256[] memory requestIds) {
        requestIds = _requestLidoWithdrawal(_stETHAmount, false);
    }

    function _requestLidoWithdrawal(uint256 _stETHAmount, bool _failSoft)
        internal
        returns (uint256[] memory requestIds)
    {
        if (_stETHAmount == 0) return new uint256[](0);
        if (_stETHAmount > _stakedUnderlyingValue()) revert AmountExceedsStaked();

        (
            uint256[] memory wstETHAmounts,
            uint256[] memory requestStETHAmounts,
            uint256 totalWstETHQueued,
            uint256 totalStETHRequested
        ) = _splitWithdrawalAmount(_stETHAmount);
        _requireAsyncPendingRequestCapacity(wstETHAmounts.length);

        uint256 wstETHBalanceBeforeQueue = wstETH.balanceOf(address(this));
        if (_failSoft) {
            try withdrawalQueue.requestWithdrawalsWstETH(wstETHAmounts, address(this)) returns (
                uint256[] memory returnedIds
            ) {
                requestIds = returnedIds;
            } catch {
                return new uint256[](0);
            }
        } else {
            requestIds = withdrawalQueue.requestWithdrawalsWstETH(wstETHAmounts, address(this));
        }

        if (requestIds.length != wstETHAmounts.length) revert WithdrawalQueueRequestMismatch();

        uint256 wstETHBalanceAfterQueue = wstETH.balanceOf(address(this));
        if (wstETHBalanceAfterQueue > wstETHBalanceBeforeQueue) revert WithdrawalQueueRequestMismatch();
        if (wstETHBalanceBeforeQueue - wstETHBalanceAfterQueue != totalWstETHQueued) {
            revert WithdrawalQueueRequestMismatch();
        }

        uint256 ownWstETHBeforeQueue = _ownWstETH;
        _ownWstETH = totalWstETHQueued > ownWstETHBeforeQueue ? 0 : ownWstETHBeforeQueue - totalWstETHQueued;

        for (uint256 requestIndex = 0; requestIndex < wstETHAmounts.length; requestIndex++) {
            address requestOwner = withdrawalQueue.ownerOf(requestIds[requestIndex]);
            if (requestOwner != address(this)) revert UnexpectedWithdrawalRequestOwner(requestOwner);
            _addPendingRequest(requestIds[requestIndex], requestStETHAmounts[requestIndex]);
        }

        emit WithdrawRequested(requestIds, totalStETHRequested);
        emit OwnWstETHUpdated(_ownWstETH);
    }

    function _splitWithdrawalAmount(uint256 _stETHAmount)
        internal
        view
        returns (
            uint256[] memory wstETHAmounts,
            uint256[] memory stETHAmounts,
            uint256 totalWstETH,
            uint256 totalRequested
        )
    {
        stETHAmounts = _splitStETHWithdrawalAmount(_stETHAmount);
        wstETHAmounts = new uint256[](stETHAmounts.length);

        uint256 minStETHAmount = withdrawalQueue.MIN_STETH_WITHDRAWAL_AMOUNT();
        uint256 maxStETHAmount = withdrawalQueue.MAX_STETH_WITHDRAWAL_AMOUNT();
        uint256 trackedWstETHBeforeSplit = _ownWstETH;
        uint256 currentWstETHBalance = wstETH.balanceOf(address(this));
        uint256 effectiveWstETH =
            trackedWstETHBeforeSplit < currentWstETHBalance ? trackedWstETHBeforeSplit : currentWstETHBalance;

        for (uint256 chunkIndex = 0; chunkIndex < stETHAmounts.length; chunkIndex++) {
            uint256 wstETHAmount = wstETH.getWstETHByStETH(stETHAmounts[chunkIndex]);
            if (wstETHAmount == 0 && stETHAmounts[chunkIndex] != 0) wstETHAmount = 1;

            uint256 stETHValue = wstETH.getStETHByWstETH(wstETHAmount);
            if (stETHValue < minStETHAmount) {
                wstETHAmount += 1;
                stETHValue = wstETH.getStETHByWstETH(wstETHAmount);
            }
            if (stETHValue < minStETHAmount || stETHValue > maxStETHAmount) revert AmountOutOfRange();

            wstETHAmounts[chunkIndex] = wstETHAmount;
            stETHAmounts[chunkIndex] = stETHValue;
            totalWstETH += wstETHAmount;
            totalRequested += stETHValue;
        }

        if (totalWstETH > effectiveWstETH) revert AmountExceedsStaked();
    }

    function _splitStETHWithdrawalAmount(uint256 _amount) internal view returns (uint256[] memory stETHChunks) {
        uint256 minStETHAmount = withdrawalQueue.MIN_STETH_WITHDRAWAL_AMOUNT();
        uint256 maxStETHAmount = withdrawalQueue.MAX_STETH_WITHDRAWAL_AMOUNT();

        if (minStETHAmount == 0 || maxStETHAmount < minStETHAmount || _amount < minStETHAmount) {
            revert AmountOutOfRange();
        }

        uint256 fullChunkCount = _amount / maxStETHAmount;
        uint256 remainder = _amount % maxStETHAmount;

        if (remainder == 0) {
            _requireLidoWithdrawalRequestCount(fullChunkCount);
            stETHChunks = new uint256[](fullChunkCount);
            for (uint256 chunkIndex = 0; chunkIndex < fullChunkCount; chunkIndex++) {
                stETHChunks[chunkIndex] = maxStETHAmount;
            }
            return stETHChunks;
        }

        if (remainder >= minStETHAmount) {
            uint256 chunkCountWithRemainder = fullChunkCount + 1;
            _requireLidoWithdrawalRequestCount(chunkCountWithRemainder);
            stETHChunks = new uint256[](chunkCountWithRemainder);
            for (uint256 chunkIndex = 0; chunkIndex < fullChunkCount; chunkIndex++) {
                stETHChunks[chunkIndex] = maxStETHAmount;
            }
            stETHChunks[fullChunkCount] = remainder;
            return stETHChunks;
        }

        if (fullChunkCount == 0) revert AmountOutOfRange();

        uint256 topUp = minStETHAmount - remainder;
        uint256 adjustedLastFullChunk = maxStETHAmount - topUp;
        if (adjustedLastFullChunk < minStETHAmount) revert AmountOutOfRange();

        uint256 adjustedChunkCount = fullChunkCount + 1;
        _requireLidoWithdrawalRequestCount(adjustedChunkCount);
        stETHChunks = new uint256[](adjustedChunkCount);
        for (uint256 chunkIndex = 0; chunkIndex < fullChunkCount - 1; chunkIndex++) {
            stETHChunks[chunkIndex] = maxStETHAmount;
        }
        stETHChunks[fullChunkCount - 1] = adjustedLastFullChunk;
        stETHChunks[fullChunkCount] = minStETHAmount;
    }

    function _maxLidoWithdrawalRequestAmount() internal view returns (uint256) {
        return withdrawalQueue.MAX_STETH_WITHDRAWAL_AMOUNT() * MAX_LIDO_WITHDRAWAL_REQUESTS_PER_CALL;
    }

    function _requireLidoWithdrawalRequestCount(uint256 _requestCount) internal pure {
        if (_requestCount > MAX_LIDO_WITHDRAWAL_REQUESTS_PER_CALL) {
            revert LidoWithdrawalRequestTooLarge(_requestCount, MAX_LIDO_WITHDRAWAL_REQUESTS_PER_CALL);
        }
    }

    function _stakedUnderlyingValue() internal view returns (uint256) {
        uint256 currentWstETHBalance = wstETH.balanceOf(address(this));
        uint256 effectiveWstETH = _ownWstETH < currentWstETHBalance ? _ownWstETH : currentWstETHBalance;
        if (effectiveWstETH == 0) return 0;
        return wstETH.getStETHByWstETH(effectiveWstETH);
    }
}
