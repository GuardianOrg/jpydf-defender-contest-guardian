// SPDX-License-Identifier: BUSL-1.1

pragma solidity 0.8.24;

import "openzeppelin-contracts/contracts/utils/math/Math.sol";

import "./BaseStrategy.sol";

/**
 * @title IAaveV3Pool - Aave V3 Pool Interface (minimal)
 */
interface IAaveV3Pool {
    function supply(address asset, uint256 amount, address onBehalfOf, uint16 referralCode) external;

    function withdraw(address asset, uint256 amount, address to) external returns (uint256);

    /// @notice Returns the normalized income of the reserve, in RAY (1e27).
    ///         underlying = scaled * income / RAY.
    function getReserveNormalizedIncome(address asset) external view returns (uint256);
}

/**
 * @title IAaveRewardsController - Aave V3 rewards interface (minimal)
 */
interface IAaveRewardsController {
    function claimRewards(address[] calldata assets, uint256 amount, address to, address reward)
        external
        returns (uint256);
}

/**
 * @title IAToken - Aave aToken Interface (minimal)
 */
interface IAToken {
    function balanceOf(address account) external view returns (uint256);

    /// @notice Scaled balance (RAY-precision share of the reserve). Unaffected
    ///         by interest accrual; changes only on supply / withdraw / transfer.
    function scaledBalanceOf(address account) external view returns (uint256);

    function UNDERLYING_ASSET_ADDRESS() external view returns (address);
}

/**
 * @title AaveV3Strategy - Aave V3 Lending Strategy (push model, Upgradeable)
 * @notice Synchronous lending strategy backed by Aave V3.
 *         Withdrawals are immediate up to the reserve's currently liquid
 *         underlying; `_doWithdraw` pulls underlying into this contract. The
 *         BaseStrategy then routes principal returns through
 *         `receiveFromStrategy` and yield-only pushes through a direct transfer
 *         to the Vault buffer.
 * @dev    The Strategy tracks the scaled-balance share that **this contract**
 *         accumulated via its own `supply` / `withdraw` calls. The Aave V3
 *         `Pool.supply(asset, X, onBehalfOf = AaveV3Strategy, 0)` entry point
 *         is permissionless, so anyone can credit additional aToken to this
 *         contract. To prevent such "donations" from inflating
 *         `realizedYield()` (which would let an adversary route arbitrary
 *         amounts into `treasury` via
 *         `sendProfitToVault` + `transferYieldToTreasury`),
 *         `_estimatedTotalUnderlying()` is computed from the locally tracked
 *         scaled balance rather than `aToken.balanceOf`.
 */
contract AaveV3Strategy is BaseStrategy {
    using SafeERC20 for IERC20;

    // =============================================================
    //                         STATE
    // =============================================================

    IAaveV3Pool public aavePool;
    IAToken public aToken;

    /// @notice Scaled balance (RAY-precision) that this contract minted
    ///         through its own `supply` calls minus what was burned through
    ///         its own `withdraw` calls. Donations made by third parties via
    ///         `supply(_, _, onBehalfOf=this, _)` do NOT affect this value,
    ///         so `_estimatedTotalUnderlying()` reflects only the Strategy's
    ///         own share of the reserve.
    uint256 internal _ownScaledBalance;

    /// @dev Storage gap for future upgrades of this derived contract.
    uint256[48] private __gapAaveV3;

    /// @dev Aave V3 normalized-income / scaled-balance precision.
    uint256 internal constant _RAY = 1e27;

    // =============================================================
    //                          EVENTS
    // =============================================================

    event OwnScaledBalanceUpdated(uint256 newScaledBalance);
    event AaveRewardsClaimed(
        address indexed rewardsController, address indexed reward, uint256 requested, uint256 claimed, uint256 settled
    );
    event AaveUnderlyingRewardsClaimed(
        address indexed rewardsController,
        address indexed reward,
        uint256 requested,
        uint256 claimed,
        uint256 sentToVault
    );

    // =============================================================
    //                        INITIALIZER
    // =============================================================

    error InvalidATokenUnderlying();
    error InvalidAaveRewardsController();
    error AaveSupplyZeroScaledBalance(uint256 amount);
    error AaveWithdrawZeroScaledBurn(uint256 actual);
    error AaveWithdrawZeroReported(uint256 actual);

    function initialize(
        address _vault,
        IERC20 _underlying,
        address _owner,
        address _upgrader,
        IAaveV3Pool _aavePool,
        IAToken _aToken
    ) external initializer {
        __BaseStrategy_init(_vault, _underlying, _owner, _upgrader);

        if (address(_aavePool) == address(0)) revert ZeroAddress();
        if (address(_aToken) == address(0)) revert ZeroAddress();
        if (address(_aavePool).code.length == 0) revert NotContract(address(_aavePool));
        if (address(_aToken).code.length == 0) revert NotContract(address(_aToken));
        if (_aToken.UNDERLYING_ASSET_ADDRESS() != address(_underlying)) {
            revert InvalidATokenUnderlying();
        }

        aavePool = _aavePool;
        aToken = _aToken;

        // Approve underlying token to Aave Pool (for supply).
        _underlying.forceApprove(address(_aavePool), type(uint256).max);
    }

    // =============================================================
    //                  BaseStrategy HOOKS
    // =============================================================

    /// @inheritdoc BaseStrategy
    /// @dev Tracks the scaled balance Aave mints for THIS specific `supply`
    ///      call by snapshotting before/after `scaledBalanceOf`. Concurrent
    ///      donations (separate transactions) inflate both snapshots equally,
    ///      so the delta still reflects only the amount attributable to this
    ///      call.
    function _doDeposit(uint256 _amount) internal override {
        uint256 scaledBalanceBeforeSupply = aToken.scaledBalanceOf(address(this));
        aavePool.supply(address(underlyingToken), _amount, address(this), 0);
        uint256 scaledBalanceAfterSupply = aToken.scaledBalanceOf(address(this));
        uint256 scaledBalanceMinted = scaledBalanceAfterSupply - scaledBalanceBeforeSupply;
        if (scaledBalanceMinted == 0) revert AaveSupplyZeroScaledBalance(_amount);

        _ownScaledBalance += scaledBalanceMinted;
        emit OwnScaledBalanceUpdated(_ownScaledBalance);
    }

    /// @inheritdoc BaseStrategy
    /// @dev Withdraws no more than the Strategy's Aave-accounted value and no
    ///      more than the reserve's currently liquid underlying. Aave V3 does
    ///      not partially fill ordinary withdraw requests; over-asking or
    ///      hitting an illiquid reserve reverts. Capping here gives the same
    ///      partial-withdraw semantics as ERC-4626 `maxWithdraw` without
    ///      treating utilization as a solvency loss.
    function _doWithdraw(uint256 _amount) internal override returns (uint256 actual) {
        uint256 withdrawAmount = _amount;

        uint256 accountingValue = _ownedAaveAccountingValue();
        if (accountingValue < withdrawAmount) withdrawAmount = accountingValue;

        uint256 liquidUnderlying = _aaveLiquidUnderlying();
        if (liquidUnderlying < withdrawAmount) withdrawAmount = liquidUnderlying;
        if (withdrawAmount == 0) return 0;

        actual = _withdrawFromAave(withdrawAmount);
    }

    /// @inheritdoc BaseStrategy
    /// @dev Computes underlying value from the locally tracked scaled balance,
    ///      capped at Aave's current `scaledBalanceOf` of this contract so
    ///      that an Aave-side scaled-balance shrink is reflected immediately.
    ///      This is an Aave accounting value, not a reserve-liquidity or
    ///      protocol-deficit oracle: Aave deficits that do not reduce scaled
    ///      balances / normalized income must be handled by monitoring and
    ///      `Vault.writeoffStrategyPrincipal`.
    function _estimatedTotalUnderlying() internal view override returns (uint256) {
        return _ownedAaveAccountingValue();
    }

    function _ownedAaveAccountingValue() internal view returns (uint256) {
        uint256 currentAaveScaledBalance = aToken.scaledBalanceOf(address(this));
        uint256 effectiveScaledBalance =
            _ownScaledBalance < currentAaveScaledBalance ? _ownScaledBalance : currentAaveScaledBalance;
        if (effectiveScaledBalance == 0) return 0;
        return _aaveAccountingValue(effectiveScaledBalance);
    }

    function _aaveAccountingValue(uint256 _scaledBalance) internal view returns (uint256) {
        uint256 normalizedReserveIncome = aavePool.getReserveNormalizedIncome(address(underlyingToken));
        return Math.mulDiv(_scaledBalance, normalizedReserveIncome, _RAY);
    }

    function _aaveLiquidUnderlying() internal view returns (uint256) {
        return underlyingToken.balanceOf(address(aToken));
    }

    function _withdrawFromAave(uint256 _amount) internal returns (uint256 actual) {
        uint256 underlyingBalanceBeforeWithdraw = underlyingToken.balanceOf(address(this));
        uint256 scaledBalanceBeforeWithdraw = aToken.scaledBalanceOf(address(this));
        uint256 reported = aavePool.withdraw(address(underlyingToken), _amount, address(this));
        uint256 scaledBalanceAfterWithdraw = aToken.scaledBalanceOf(address(this));
        uint256 underlyingBalanceAfterWithdraw = underlyingToken.balanceOf(address(this));

        uint256 actualBurnedScaledBalance = scaledBalanceBeforeWithdraw - scaledBalanceAfterWithdraw;
        actual = underlyingBalanceAfterWithdraw - underlyingBalanceBeforeWithdraw;
        if (actual != 0 && actualBurnedScaledBalance == 0) revert AaveWithdrawZeroScaledBurn(actual);

        _ownScaledBalance =
            actualBurnedScaledBalance > _ownScaledBalance ? 0 : _ownScaledBalance - actualBurnedScaledBalance;
        emit OwnScaledBalanceUpdated(_ownScaledBalance);

        if (reported == 0 && actual != 0) revert AaveWithdrawZeroReported(actual);
    }

    /// @inheritdoc BaseStrategy
    /// @dev aToken is the Aave position/accounting token, not a reward token.
    ///      It must leave the Strategy only through Aave withdraw paths.
    function _isSweepProtectedToken(address _token) internal view override returns (bool) {
        return super._isSweepProtectedToken(_token) || _token == address(aToken);
    }

    // =============================================================
    //                   REWARD CLAIM FUNCTIONS
    // =============================================================

    /**
     * @notice Claim Aave rewards earned by this Strategy's aToken position.
     * @dev The rewards asset list is fixed to this Strategy's aToken so the
     *      owner cannot accidentally claim rewards for an unrelated Aave
     *      position through this adapter. Ordinary reward tokens are swept to
     *      the Vault treasury; underlying rewards are treated as yield and sent
     *      to the Vault buffer without reducing principal.
     * @param _rewardsController Aave V3 rewards controller.
     * @param _amount Amount requested from Aave, or `type(uint256).max` for all
     *        currently claimable rewards.
     * @param _reward Reward token to claim.
     * @return claimed Amount reported by the rewards controller.
     * @return settled Amount actually received by treasury or Vault.
     */
    function claimAaveRewards(IAaveRewardsController _rewardsController, uint256 _amount, address _reward)
        external
        onlyOwner
        nonReentrantStrategy
        returns (uint256 claimed, uint256 settled)
    {
        if (address(_rewardsController) == address(0)) revert ZeroAddress();
        if (address(_rewardsController).code.length == 0) revert InvalidAaveRewardsController();
        if (_reward == address(0)) revert ZeroAddress();

        address underlyingAddress = address(underlyingToken);
        if (_reward != underlyingAddress && _isSweepProtectedToken(_reward)) revert CannotSweepProtectedToken();

        address[] memory assets = new address[](1);
        assets[0] = address(aToken);

        uint256 balanceBeforeClaim = IERC20(_reward).balanceOf(address(this));
        claimed = _rewardsController.claimRewards(assets, _amount, address(this), _reward);

        if (_reward == underlyingAddress) {
            uint256 balanceAfterClaim = IERC20(_reward).balanceOf(address(this));
            uint256 claimedUnderlying =
                balanceAfterClaim > balanceBeforeClaim ? balanceAfterClaim - balanceBeforeClaim : 0;
            settled = _sendUnderlyingYieldToVault(claimedUnderlying);
            emit AaveUnderlyingRewardsClaimed(address(_rewardsController), _reward, _amount, claimed, settled);
        } else {
            settled = _sweepRewardToken(IERC20(_reward), type(uint256).max);
            emit AaveRewardsClaimed(address(_rewardsController), _reward, _amount, claimed, settled);
        }
    }

    // =============================================================
    //                   EMERGENCY FUNCTIONS
    // =============================================================

    /**
     * @notice Withdraw the currently liquid Aave position (including any
     *         liquid third-party donations) and immediately push all idle
     *         underlying back to the Vault. The Vault receipt is accounted as
     *         returned principal; if the remaining Aave-accounted position is
     *         later deemed unrecoverable, GOV should follow up with
     *         `Vault.writeoffStrategyPrincipal(...)` for that residual.
     * @dev    Owner only. Pushing through `receiveFromStrategy` keeps the
     *         Vault-side valuation cache in sync and avoids an observable
     *         window where funds sit idle in the Strategy but are excluded from
     *         `CollateralVault.backingRatio()`.
     */
    function emergencyWithdrawFromAave() external onlyOwner nonReentrantStrategy returns (uint256 sent) {
        uint256 aTokenBalance = aToken.balanceOf(address(this));
        uint256 liquidUnderlying = _aaveLiquidUnderlying();
        uint256 withdrawAmount = aTokenBalance < liquidUnderlying ? aTokenBalance : liquidUnderlying;
        if (withdrawAmount != 0) {
            _withdrawFromAave(withdrawAmount);
        }

        uint256 idleUnderlying = underlyingToken.balanceOf(address(this));
        if (idleUnderlying == 0) return 0;

        sent = _returnUnderlyingPrincipalToVault(idleUnderlying);
    }
}
