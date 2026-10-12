// SPDX-License-Identifier: BUSL-1.1

pragma solidity 0.8.24;

/**
 * @dev ARCHIVED — `EtherfiWeETHStrategy` (WETH -> ETH -> eETH -> weETH, async WithdrawRequestNFT exit).
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
import "openzeppelin-contracts/contracts/token/ERC721/IERC721Receiver.sol";

import "../../Interfaces/IWETH.sol";
import "./AsyncRequestStrategy.sol";

interface IEtherfiLiquidityPool {
    function deposit(address referral) external payable returns (uint256);
    function requestWithdraw(address recipient, uint256 amount) external returns (uint256 requestId);
    function withdrawRequestNFT() external view returns (IEtherfiWithdrawRequestNFT);
}

interface IEtherfiEETH is IERC20 {}

interface IEtherfiWeETH is IERC20 {
    function eETH() external view returns (IEtherfiEETH);
    function liquidityPool() external view returns (IEtherfiLiquidityPool);
    function wrap(uint256 eETHAmount) external returns (uint256);
    function unwrap(uint256 weETHAmount) external returns (uint256);
    function getWeETHByeETH(uint256 eETHAmount) external view returns (uint256);
    function getEETHByWeETH(uint256 weETHAmount) external view returns (uint256);
}

interface IWeETHWithdrawAdapter {
    function dfWeETHWithdrawAdapterId() external pure returns (bytes32 adapterId);
    function liquidityPool() external view returns (IEtherfiLiquidityPool);
    function eETH() external view returns (IEtherfiEETH);
    function weETH() external view returns (IEtherfiWeETH);
    function withdrawRequestNFT() external view returns (IEtherfiWithdrawRequestNFT);
    function requestWithdraw(uint256 weETHAmount, address recipient) external returns (uint256 requestId);
    function getEETHByWeETH(uint256 weETHAmount) external view returns (uint256 eETHAmount);
}

interface IEtherfiWithdrawRequestNFT {
    struct WithdrawRequest {
        uint96 amountOfEEth;
        uint96 shareOfEEth;
        bool isValid;
        uint32 feeGwei;
    }

    function claimWithdraw(uint256 requestId) external;
    function eETH() external view returns (IEtherfiEETH);
    function liquidityPool() external view returns (IEtherfiLiquidityPool);
    function getRequest(uint256 requestId) external view returns (WithdrawRequest memory);
    function isFinalized(uint256 requestId) external view returns (bool);
    function ownerOf(uint256 requestId) external view returns (address owner);
}

/**
 * @title EtherfiWeETHStrategy - Ether.fi weETH async Strategy.
 * @notice Stakes WETH into Ether.fi, wraps eETH into weETH, and tracks
 *         WithdrawRequestNFT requests until they can be claimed back as WETH.
 * @dev The BaseStrategy synchronous surface can only push WETH that has already
 *      been claimed and wrapped. weETH and withdrawal NFTs are protected
 *      position assets and are not sweepable rewards. Raw ETH already held by
 *      the strategy is not claim proceeds; only the balance delta during claim
 *      is wrapped and tracked as idle underlying.
 * @custom:security-contact security@deltaforesight.xyz
 */
contract EtherfiWeETHStrategy is AsyncRequestStrategy, IERC721Receiver {
    using SafeERC20 for IERC20;

    // =============================================================
    //                         STATE
    // =============================================================

    bytes32 public constant DF_WEETH_WITHDRAW_ADAPTER_ID = keccak256("DeltaForesight.WeETHWithdrawAdapter.v1");

    IWETH public weth;
    IEtherfiLiquidityPool public liquidityPool;
    IEtherfiEETH public eETH;
    IEtherfiWeETH public weETH;
    IWeETHWithdrawAdapter public withdrawAdapter;
    IEtherfiWithdrawRequestNFT public withdrawRequestNFT;
    address public referral;

    uint256 internal _ownWeETH;
    /// @dev Storage gap for future upgrades of this derived contract.
    uint256[39] private __gapEtherfi;

    // =============================================================
    //                          EVENTS
    // =============================================================

    event ReferralUpdated(address indexed referral);
    event WithdrawRequested(uint256 indexed requestId, uint256 weETHAmount, uint256 netEETHAmount);
    event WithdrawClaimed(uint256[] requestIds, uint256 ethReceived);
    event OwnWeETHUpdated(uint256 ownWeETH);

    // =============================================================
    //                          ERRORS
    // =============================================================

    error EtherfiWeETHStrategy__AmountExceedsStaked();
    error EtherfiWeETHStrategy__InvalidRequest();
    error EtherfiWeETHStrategy__UnexpectedWithdrawRequestNFT();
    error EtherfiWeETHStrategy__EtherfiZeroShares();
    error EtherfiWeETHStrategy__EtherfiShareBalanceMismatch();
    error EtherfiWeETHStrategy__InvalidWeETHEETH();
    error EtherfiWeETHStrategy__InvalidWeETHLiquidityPool();
    error EtherfiWeETHStrategy__InvalidWithdrawRequestNFTEETH();
    error EtherfiWeETHStrategy__InvalidWithdrawRequestNFTLiquidityPool();
    error EtherfiWeETHStrategy__InvalidLiquidityPoolWithdrawRequestNFT();
    error EtherfiWeETHStrategy__InvalidAdapterLiquidityPool();
    error EtherfiWeETHStrategy__InvalidAdapterEETH();
    error EtherfiWeETHStrategy__InvalidAdapterWeETH();
    error EtherfiWeETHStrategy__InvalidAdapterWithdrawRequestNFT();
    error EtherfiWeETHStrategy__InvalidAdapterIdentity();
    error EtherfiWeETHStrategy__UnexpectedWithdrawRequestOwner(address owner);

    // =============================================================
    //                        INITIALIZER
    // =============================================================

    function initialize(
        address _vault,
        IWETH _weth,
        address _owner,
        address _upgrader,
        IEtherfiLiquidityPool _liquidityPool,
        IEtherfiEETH _eETH,
        IEtherfiWeETH _weETH,
        IWeETHWithdrawAdapter _withdrawAdapter,
        IEtherfiWithdrawRequestNFT _withdrawRequestNFT,
        address _referral
    ) external initializer {
        __BaseStrategy_init(_vault, IERC20(address(_weth)), _owner, _upgrader);
        __AsyncRequestStrategy_init();

        if (address(_liquidityPool) == address(0)) revert ZeroAddress();
        if (address(_eETH) == address(0)) revert ZeroAddress();
        if (address(_weETH) == address(0)) revert ZeroAddress();
        if (address(_withdrawAdapter) == address(0)) revert ZeroAddress();
        if (address(_withdrawRequestNFT) == address(0)) revert ZeroAddress();
        if (address(_liquidityPool).code.length == 0) revert NotContract(address(_liquidityPool));
        if (address(_eETH).code.length == 0) revert NotContract(address(_eETH));
        if (address(_weETH).code.length == 0) revert NotContract(address(_weETH));
        if (address(_withdrawAdapter).code.length == 0) revert NotContract(address(_withdrawAdapter));
        if (address(_withdrawRequestNFT).code.length == 0) revert NotContract(address(_withdrawRequestNFT));
        bytes32 adapterId;
        try _withdrawAdapter.dfWeETHWithdrawAdapterId() returns (bytes32 returnedAdapterId) {
            adapterId = returnedAdapterId;
        } catch {
            revert EtherfiWeETHStrategy__InvalidAdapterIdentity();
        }
        if (adapterId != DF_WEETH_WITHDRAW_ADAPTER_ID) revert EtherfiWeETHStrategy__InvalidAdapterIdentity();
        if (address(_weETH.eETH()) != address(_eETH)) revert EtherfiWeETHStrategy__InvalidWeETHEETH();
        if (address(_weETH.liquidityPool()) != address(_liquidityPool)) {
            revert EtherfiWeETHStrategy__InvalidWeETHLiquidityPool();
        }
        if (address(_withdrawRequestNFT.eETH()) != address(_eETH)) {
            revert EtherfiWeETHStrategy__InvalidWithdrawRequestNFTEETH();
        }
        if (address(_withdrawRequestNFT.liquidityPool()) != address(_liquidityPool)) {
            revert EtherfiWeETHStrategy__InvalidWithdrawRequestNFTLiquidityPool();
        }
        if (address(_liquidityPool.withdrawRequestNFT()) != address(_withdrawRequestNFT)) {
            revert EtherfiWeETHStrategy__InvalidLiquidityPoolWithdrawRequestNFT();
        }
        if (address(_withdrawAdapter.liquidityPool()) != address(_liquidityPool)) {
            revert EtherfiWeETHStrategy__InvalidAdapterLiquidityPool();
        }
        if (address(_withdrawAdapter.eETH()) != address(_eETH)) revert EtherfiWeETHStrategy__InvalidAdapterEETH();
        if (address(_withdrawAdapter.weETH()) != address(_weETH)) revert EtherfiWeETHStrategy__InvalidAdapterWeETH();
        if (address(_withdrawAdapter.withdrawRequestNFT()) != address(_withdrawRequestNFT)) {
            revert EtherfiWeETHStrategy__InvalidAdapterWithdrawRequestNFT();
        }

        weth = _weth;
        liquidityPool = _liquidityPool;
        eETH = _eETH;
        weETH = _weETH;
        withdrawAdapter = _withdrawAdapter;
        withdrawRequestNFT = _withdrawRequestNFT;
        referral = _referral;

        IERC20(address(_eETH)).forceApprove(address(_weETH), type(uint256).max);
        IERC20(address(_weETH)).forceApprove(address(_withdrawAdapter), type(uint256).max);
    }

    receive() external payable {}

    // =============================================================
    //                    ERC721 RECEIVER
    // =============================================================

    function onERC721Received(address, address, uint256, bytes calldata) external view returns (bytes4) {
        if (msg.sender != address(withdrawRequestNFT)) revert EtherfiWeETHStrategy__UnexpectedWithdrawRequestNFT();
        return IERC721Receiver.onERC721Received.selector;
    }

    // =============================================================
    //                    ETHERFI-SPECIFIC VIEWS
    // =============================================================

    function ownWeETH() external view returns (uint256) {
        return _ownWeETH;
    }

    // =============================================================
    //                    ETHERFI-SPECIFIC MUTATORS
    // =============================================================

    function requestEtherfiWithdrawal(uint256 _eETHAmount)
        external
        nonReentrantStrategy
        onlyVaultRole(_ALLOCATOR_ROLE)
        returns (uint256 requestId)
    {
        requestId = _requestEtherfiWithdrawal(_eETHAmount);
    }

    function claimEtherfiWithdrawals(uint256[] calldata _requestIds) external nonReentrantStrategy {
        uint256 requestCount = _requestIds.length;
        if (requestCount == 0) return;
        _requireAsyncClaimRequestCount(requestCount);

        for (uint256 requestIndex; requestIndex < requestCount; requestIndex++) {
            _removePendingRequest(_requestIds[requestIndex]);
        }

        uint256 ethBalanceBeforeClaim = address(this).balance;
        for (uint256 requestIndex; requestIndex < requestCount; requestIndex++) {
            withdrawRequestNFT.claimWithdraw(_requestIds[requestIndex]);
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

    function emergencyWithdrawFromEtherfi(uint256 _maxEETHToRequest)
        external
        onlyOwner
        nonReentrantStrategy
        returns (uint256 sent)
    {
        uint256 idleUnderlying = _ownedIdleUnderlyingValue();
        if (idleUnderlying != 0) {
            sent = _returnUnderlyingPrincipalToVault(idleUnderlying);
        }

        uint256 remainingStakedUnderlying = _stakedUnderlyingValue();
        uint256 requestAmount =
            remainingStakedUnderlying < _maxEETHToRequest ? remainingStakedUnderlying : _maxEETHToRequest;
        if (requestAmount != 0) {
            _requestEtherfiWithdrawal(requestAmount);
        }
    }

    function setReferral(address _referral) external onlyOwner {
        referral = _referral;
        emit ReferralUpdated(_referral);
    }

    // =============================================================
    //                  BaseStrategy HOOKS
    // =============================================================

    /// @inheritdoc BaseStrategy
    function _doDeposit(uint256 _amount) internal override {
        uint256 eETHBalanceBeforeDeposit = eETH.balanceOf(address(this));
        weth.withdraw(_amount);
        liquidityPool.deposit{value: _amount}(referral);
        uint256 eETHReceived = eETH.balanceOf(address(this)) - eETHBalanceBeforeDeposit;
        if (eETHReceived == 0) revert EtherfiWeETHStrategy__EtherfiZeroShares();

        uint256 weETHBalanceBeforeWrap = weETH.balanceOf(address(this));
        uint256 reportedWeETHMinted = weETH.wrap(eETHReceived);
        uint256 weETHBalanceAfterWrap = weETH.balanceOf(address(this));
        if (weETHBalanceAfterWrap < weETHBalanceBeforeWrap) revert EtherfiWeETHStrategy__EtherfiShareBalanceMismatch();

        uint256 actualWeETHMinted = weETHBalanceAfterWrap - weETHBalanceBeforeWrap;
        if (actualWeETHMinted == 0) revert EtherfiWeETHStrategy__EtherfiZeroShares();
        if (actualWeETHMinted != reportedWeETHMinted) revert EtherfiWeETHStrategy__EtherfiShareBalanceMismatch();

        _ownWeETH += actualWeETHMinted;
        emit OwnWeETHUpdated(_ownWeETH);
    }

    /// @inheritdoc BaseStrategy
    function _doWithdraw(uint256 _amount) internal override returns (uint256 actual) {
        actual = _takeOwnIdleUnderlying(_amount);
    }

    /// @inheritdoc BaseStrategy
    function _estimatedTotalUnderlying() internal view override returns (uint256) {
        return _stakedUnderlyingValue() + _pendingWithdrawalValuation() + _ownedIdleUnderlyingValue();
    }

    /// @inheritdoc BaseStrategy
    function _isSweepProtectedToken(address _token) internal view override returns (bool) {
        return super._isSweepProtectedToken(_token) || _token == address(eETH) || _token == address(weETH)
            || _token == address(withdrawRequestNFT);
    }

    // =============================================================
    //                   INTERNAL FUNCTIONS
    // =============================================================

    function _requestEtherfiWithdrawal(uint256 _eETHAmount) internal returns (uint256 requestId) {
        if (_eETHAmount == 0) return 0;
        if (_eETHAmount > _stakedUnderlyingValue()) revert EtherfiWeETHStrategy__AmountExceedsStaked();
        _requireAsyncPendingRequestCapacity(1);

        uint256 weETHAmount = weETH.getWeETHByeETH(_eETHAmount);
        if (weETHAmount == 0 && _eETHAmount != 0) weETHAmount = 1;

        uint256 currentWeETHBalance = weETH.balanceOf(address(this));
        uint256 ownWeETHBeforeRequest = _ownWeETH;
        uint256 effectiveWeETH =
            ownWeETHBeforeRequest < currentWeETHBalance ? ownWeETHBeforeRequest : currentWeETHBalance;
        if (weETHAmount > effectiveWeETH) revert EtherfiWeETHStrategy__AmountExceedsStaked();

        uint256 weETHBalanceBeforeRequest = currentWeETHBalance;
        requestId = withdrawAdapter.requestWithdraw(weETHAmount, address(this));
        uint256 weETHBalanceAfterRequest = weETH.balanceOf(address(this));
        if (weETHBalanceAfterRequest > weETHBalanceBeforeRequest) {
            revert EtherfiWeETHStrategy__EtherfiShareBalanceMismatch();
        }
        uint256 actualWeETHSpent = weETHBalanceBeforeRequest - weETHBalanceAfterRequest;
        if (actualWeETHSpent != weETHAmount) revert EtherfiWeETHStrategy__EtherfiShareBalanceMismatch();

        address requestOwner = withdrawRequestNFT.ownerOf(requestId);
        if (requestOwner != address(this)) revert EtherfiWeETHStrategy__UnexpectedWithdrawRequestOwner(requestOwner);

        uint256 netRequestAmount = _netRequestAmount(requestId);
        if (netRequestAmount == 0) revert EtherfiWeETHStrategy__InvalidRequest();

        _ownWeETH = actualWeETHSpent > ownWeETHBeforeRequest ? 0 : ownWeETHBeforeRequest - actualWeETHSpent;
        _addPendingRequest(requestId, netRequestAmount);

        emit OwnWeETHUpdated(_ownWeETH);
        emit WithdrawRequested(requestId, weETHAmount, netRequestAmount);
    }

    function _netRequestAmount(uint256 _requestId) internal view returns (uint256) {
        IEtherfiWithdrawRequestNFT.WithdrawRequest memory request = withdrawRequestNFT.getRequest(_requestId);
        if (!request.isValid) revert EtherfiWeETHStrategy__InvalidRequest();
        uint256 fee = uint256(request.feeGwei) * 1 gwei;
        return uint256(request.amountOfEEth) > fee ? uint256(request.amountOfEEth) - fee : 0;
    }

    function _stakedUnderlyingValue() internal view returns (uint256) {
        uint256 currentWeETHBalance = weETH.balanceOf(address(this));
        uint256 effectiveWeETH = _ownWeETH < currentWeETHBalance ? _ownWeETH : currentWeETHBalance;
        if (effectiveWeETH == 0) return 0;
        return weETH.getEETHByWeETH(effectiveWeETH);
    }
}
