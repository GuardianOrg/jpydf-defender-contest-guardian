// SPDX-License-Identifier: BUSL-1.1

pragma solidity 0.8.24;

/**
 * @dev ARCHIVED — `WeETHWithdrawAdapter`, the first-party withdrawal adapter for
 * the archived `EtherfiWeETHStrategy`. It has no other consumer.
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

import {IERC20} from "openzeppelin-contracts/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "openzeppelin-contracts/contracts/token/ERC20/utils/SafeERC20.sol";

import {
    IEtherfiEETH,
    IEtherfiLiquidityPool,
    IEtherfiWeETH,
    IEtherfiWithdrawRequestNFT,
    IWeETHWithdrawAdapter
} from "src/Strategies/archive/EtherfiWeETHStrategy.sol";

/**
 * @title WeETHWithdrawAdapter
 * @notice DeltaForesight-owned adapter that turns weETH into an Ether.fi native
 *         WithdrawRequestNFT request.
 * @dev This is not an Ether.fi first-party contract. It is deliberately
 *      stateless and non-upgradeable: callers supply weETH, the adapter unwraps
 *      exactly that transfer into eETH, requests withdrawal through Ether.fi's
 *      LiquidityPool, and verifies the returned NFT owner.
 * @custom:security-contact security@deltaforesight.xyz
 */
contract WeETHWithdrawAdapter is IWeETHWithdrawAdapter {
    using SafeERC20 for IERC20;

    // =============================================================
    //                         STATE
    // =============================================================

    IEtherfiLiquidityPool public immutable liquidityPool;
    IEtherfiEETH public immutable eETH;
    IEtherfiWeETH public immutable weETH;
    IEtherfiWithdrawRequestNFT public immutable withdrawRequestNFT;
    bytes32 public constant DF_WEETH_WITHDRAW_ADAPTER_ID = keccak256("DeltaForesight.WeETHWithdrawAdapter.v1");

    // =============================================================
    //                          EVENTS
    // =============================================================

    event WeETHWithdrawRequested(
        address indexed caller,
        address indexed recipient,
        uint256 indexed requestId,
        uint256 weETHAmount,
        uint256 eETHAmount
    );

    // =============================================================
    //                          ERRORS
    // =============================================================

    error WeETHWithdrawAdapter__ZeroAddress();
    error WeETHWithdrawAdapter__NotContract(address account);
    error WeETHWithdrawAdapter__ZeroAmount();
    error WeETHWithdrawAdapter__InvalidWeETHEETH();
    error WeETHWithdrawAdapter__InvalidWeETHLiquidityPool();
    error WeETHWithdrawAdapter__InvalidWithdrawRequestNFTEETH();
    error WeETHWithdrawAdapter__InvalidWithdrawRequestNFTLiquidityPool();
    error WeETHWithdrawAdapter__InvalidLiquidityPoolWithdrawRequestNFT();
    error WeETHWithdrawAdapter__WeETHAmountMismatch(uint256 expected, uint256 actual);
    error WeETHWithdrawAdapter__EETHAmountMismatch(uint256 reported, uint256 actual);
    error WeETHWithdrawAdapter__ResidualWeETH(uint256 expected, uint256 actual);
    error WeETHWithdrawAdapter__ResidualEETH(uint256 expected, uint256 actual);
    error WeETHWithdrawAdapter__UnexpectedWithdrawRequestOwner(address owner);

    // =============================================================
    //                        CONSTRUCTOR
    // =============================================================

    constructor(
        IEtherfiLiquidityPool _liquidityPool,
        IEtherfiEETH _eETH,
        IEtherfiWeETH _weETH,
        IEtherfiWithdrawRequestNFT _withdrawRequestNFT
    ) {
        _requireContract(address(_liquidityPool));
        _requireContract(address(_eETH));
        _requireContract(address(_weETH));
        _requireContract(address(_withdrawRequestNFT));
        if (address(_weETH.eETH()) != address(_eETH)) revert WeETHWithdrawAdapter__InvalidWeETHEETH();
        if (address(_weETH.liquidityPool()) != address(_liquidityPool)) {
            revert WeETHWithdrawAdapter__InvalidWeETHLiquidityPool();
        }
        if (address(_withdrawRequestNFT.eETH()) != address(_eETH)) {
            revert WeETHWithdrawAdapter__InvalidWithdrawRequestNFTEETH();
        }
        if (address(_withdrawRequestNFT.liquidityPool()) != address(_liquidityPool)) {
            revert WeETHWithdrawAdapter__InvalidWithdrawRequestNFTLiquidityPool();
        }
        if (address(_liquidityPool.withdrawRequestNFT()) != address(_withdrawRequestNFT)) {
            revert WeETHWithdrawAdapter__InvalidLiquidityPoolWithdrawRequestNFT();
        }

        liquidityPool = _liquidityPool;
        eETH = _eETH;
        weETH = _weETH;
        withdrawRequestNFT = _withdrawRequestNFT;

        IERC20(address(_eETH)).forceApprove(address(_liquidityPool), type(uint256).max);
    }

    // =============================================================
    //                    USER-FACING MUTATORS
    // =============================================================

    function requestWithdraw(uint256 _weETHAmount, address _recipient) external returns (uint256 requestId) {
        if (_weETHAmount == 0) revert WeETHWithdrawAdapter__ZeroAmount();
        if (_recipient == address(0)) revert WeETHWithdrawAdapter__ZeroAddress();

        uint256 weETHBalanceBefore = weETH.balanceOf(address(this));
        IERC20(address(weETH)).safeTransferFrom(msg.sender, address(this), _weETHAmount);
        uint256 weETHReceived = weETH.balanceOf(address(this)) - weETHBalanceBefore;
        if (weETHReceived != _weETHAmount) {
            revert WeETHWithdrawAdapter__WeETHAmountMismatch(_weETHAmount, weETHReceived);
        }

        uint256 eETHBalanceBefore = eETH.balanceOf(address(this));
        uint256 reportedEETHAmount = weETH.unwrap(_weETHAmount);
        uint256 eETHReceived = eETH.balanceOf(address(this)) - eETHBalanceBefore;
        if (eETHReceived == 0) revert WeETHWithdrawAdapter__ZeroAmount();
        if (eETHReceived != reportedEETHAmount) {
            revert WeETHWithdrawAdapter__EETHAmountMismatch(reportedEETHAmount, eETHReceived);
        }
        uint256 weETHBalanceAfterUnwrap = weETH.balanceOf(address(this));
        if (weETHBalanceAfterUnwrap != weETHBalanceBefore) {
            revert WeETHWithdrawAdapter__ResidualWeETH(weETHBalanceBefore, weETHBalanceAfterUnwrap);
        }

        requestId = liquidityPool.requestWithdraw(_recipient, eETHReceived);
        uint256 eETHBalanceAfterRequest = eETH.balanceOf(address(this));
        if (eETHBalanceAfterRequest != eETHBalanceBefore) {
            revert WeETHWithdrawAdapter__ResidualEETH(eETHBalanceBefore, eETHBalanceAfterRequest);
        }
        address requestOwner = withdrawRequestNFT.ownerOf(requestId);
        if (requestOwner != _recipient) {
            revert WeETHWithdrawAdapter__UnexpectedWithdrawRequestOwner(requestOwner);
        }

        emit WeETHWithdrawRequested(msg.sender, _recipient, requestId, _weETHAmount, eETHReceived);
    }

    // =============================================================
    //                    USER-FACING VIEWS
    // =============================================================

    function getEETHByWeETH(uint256 _weETHAmount) external view returns (uint256 eETHAmount) {
        eETHAmount = weETH.getEETHByWeETH(_weETHAmount);
    }

    function dfWeETHWithdrawAdapterId() external pure returns (bytes32 adapterId) {
        adapterId = DF_WEETH_WITHDRAW_ADAPTER_ID;
    }

    // =============================================================
    //                    INTERNAL VIEWS
    // =============================================================

    function _requireContract(address _account) internal view {
        if (_account == address(0)) revert WeETHWithdrawAdapter__ZeroAddress();
        if (_account.code.length == 0) revert WeETHWithdrawAdapter__NotContract(_account);
    }
}
