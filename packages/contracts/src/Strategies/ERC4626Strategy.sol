// SPDX-License-Identifier: BUSL-1.1

pragma solidity 0.8.24;

import "openzeppelin-contracts/contracts/interfaces/IERC4626.sol";

import "./BaseStrategy.sol";

/**
 * @title ERC4626Strategy - ERC-4626 vault Strategy (push model, Upgradeable)
 * @notice Synchronous Strategy adapter for ERC-4626 yield vaults whose `asset()`
 *         is the same token as this Strategy's underlying.
 * @dev    The Strategy tracks the vault shares minted through its own deposits.
 *         Anyone can transfer ERC-4626 shares directly to this contract, but
 *         donated shares must not inflate `estimatedTotalUnderlying()` or
 *         `realizedYield()`. Emergency recovery may still redeem donated shares
 *         and push the recovered underlying to the Vault.
 */
contract ERC4626Strategy is BaseStrategy {
    using SafeERC20 for IERC20;

    // =============================================================
    //                         STATE
    // =============================================================

    IERC4626 public erc4626Vault;

    /// @notice ERC-4626 shares minted through this Strategy's own deposits,
    ///         minus shares burned through this Strategy's own withdrawals.
    /// @dev Third-party share transfers to this contract do not affect this
    ///      value, so regular valuation ignores share-token donations.
    uint256 internal _ownShares;

    /// @dev Storage gap for future upgrades of this derived contract.
    uint256[48] private __gapERC4626;

    // =============================================================
    //                          EVENTS
    // =============================================================

    event OwnSharesUpdated(uint256 newOwnShares);

    // =============================================================
    //                          ERRORS
    // =============================================================

    error InvalidERC4626Asset();
    error ERC4626ZeroShares();
    error ERC4626ShareBalanceMismatch();
    error ERC4626AssetAmountMismatch(uint256 reported, uint256 actual);

    // =============================================================
    //                        INITIALIZER
    // =============================================================

    function initialize(address _vault, IERC20 _underlying, address _owner, address _upgrader, IERC4626 _erc4626Vault)
        external
        initializer
    {
        __BaseStrategy_init(_vault, _underlying, _owner, _upgrader);

        if (address(_erc4626Vault) == address(0)) revert ZeroAddress();
        if (address(_erc4626Vault).code.length == 0) revert NotContract(address(_erc4626Vault));
        if (_erc4626Vault.asset() != address(_underlying)) revert InvalidERC4626Asset();

        erc4626Vault = _erc4626Vault;

        _underlying.forceApprove(address(_erc4626Vault), type(uint256).max);
    }

    // =============================================================
    //                  BaseStrategy HOOKS
    // =============================================================

    /// @inheritdoc BaseStrategy
    function _doDeposit(uint256 _amount) internal override {
        uint256 shareBalanceBefore = erc4626Vault.balanceOf(address(this));
        uint256 reportedMintedShares = erc4626Vault.deposit(_amount, address(this));
        uint256 shareBalanceAfter = erc4626Vault.balanceOf(address(this));
        if (shareBalanceAfter < shareBalanceBefore) revert ERC4626ShareBalanceMismatch();

        uint256 actualMintedShares = shareBalanceAfter - shareBalanceBefore;
        if (actualMintedShares == 0) revert ERC4626ZeroShares();
        if (actualMintedShares != reportedMintedShares) revert ERC4626ShareBalanceMismatch();

        _ownShares += actualMintedShares;
        emit OwnSharesUpdated(_ownShares);
    }

    /// @inheritdoc BaseStrategy
    /// @dev Withdraws no more than the value of locally tracked shares and no
    ///      more than the ERC-4626 vault reports as currently withdrawable.
    function _doWithdraw(uint256 _amount) internal override returns (uint256 actual) {
        uint256 ownShares = _ownShares;
        if (ownShares == 0) return 0;

        uint256 trackedAssets = erc4626Vault.convertToAssets(ownShares);
        uint256 maxAssets = erc4626Vault.maxWithdraw(address(this));
        uint256 assetsToWithdraw = trackedAssets < maxAssets ? trackedAssets : maxAssets;
        if (_amount < assetsToWithdraw) assetsToWithdraw = _amount;
        if (assetsToWithdraw == 0) return 0;

        uint256 underlyingBalanceBefore = underlyingToken.balanceOf(address(this));
        uint256 shareBalanceBefore = erc4626Vault.balanceOf(address(this));
        uint256 reportedBurnedShares = erc4626Vault.withdraw(assetsToWithdraw, address(this), address(this));
        uint256 shareBalanceAfter = erc4626Vault.balanceOf(address(this));
        if (shareBalanceAfter > shareBalanceBefore) revert ERC4626ShareBalanceMismatch();

        uint256 actualBurnedShares = shareBalanceBefore - shareBalanceAfter;
        if (actualBurnedShares != reportedBurnedShares) revert ERC4626ShareBalanceMismatch();
        uint256 underlyingBalanceAfter = underlyingToken.balanceOf(address(this));
        actual = underlyingBalanceAfter - underlyingBalanceBefore;
        if (actualBurnedShares == 0) revert ERC4626ZeroShares();
        if (actual != assetsToWithdraw) revert ERC4626AssetAmountMismatch(assetsToWithdraw, actual);

        _ownShares = actualBurnedShares > ownShares ? 0 : ownShares - actualBurnedShares;
        emit OwnSharesUpdated(_ownShares);
    }

    /// @inheritdoc BaseStrategy
    /// @dev Values only the shares minted through this Strategy's own deposit
    ///      path, capped by the current share balance in case of an upstream or
    ///      accidental share loss. Direct share-token donations are ignored.
    function _estimatedTotalUnderlying() internal view override returns (uint256) {
        uint256 currentShareBalance = erc4626Vault.balanceOf(address(this));
        uint256 effectiveShares = _ownShares < currentShareBalance ? _ownShares : currentShareBalance;
        if (effectiveShares == 0) return 0;
        return erc4626Vault.convertToAssets(effectiveShares);
    }

    /// @inheritdoc BaseStrategy
    /// @dev The ERC-4626 share token is the position token, not a reward token.
    function _isSweepProtectedToken(address _token) internal view override returns (bool) {
        return super._isSweepProtectedToken(_token) || _token == address(erc4626Vault);
    }

    // =============================================================
    //                   EMERGENCY FUNCTIONS
    // =============================================================

    /**
     * @notice Redeem as many ERC-4626 shares as currently possible and
     *         immediately push all idle underlying back to the Vault.
     * @dev Owner only. The Vault receipt is accounted as returned principal. If
     *      recovered plus still-valued assets are short of principal, a Vault WRITEOFF_ROLE holder must call `Vault.writeoffStrategyPrincipal(...)`.
     */
    function emergencyWithdrawFromERC4626() external onlyOwner nonReentrantStrategy returns (uint256 sent) {
        uint256 currentShareBalance = erc4626Vault.balanceOf(address(this));
        if (currentShareBalance != 0) {
            uint256 redeemableShares = erc4626Vault.maxRedeem(address(this));
            if (currentShareBalance < redeemableShares) redeemableShares = currentShareBalance;

            if (redeemableShares != 0) {
                uint256 shareBalanceBefore = currentShareBalance;
                uint256 underlyingBalanceBefore = underlyingToken.balanceOf(address(this));
                uint256 reportedAssets = erc4626Vault.redeem(redeemableShares, address(this), address(this));
                uint256 shareBalanceAfter = erc4626Vault.balanceOf(address(this));
                if (shareBalanceAfter > shareBalanceBefore) revert ERC4626ShareBalanceMismatch();
                uint256 actualBurnedShares = shareBalanceBefore - shareBalanceAfter;
                if (actualBurnedShares != redeemableShares) revert ERC4626ShareBalanceMismatch();
                uint256 actualAssets = underlyingToken.balanceOf(address(this)) - underlyingBalanceBefore;
                if (reportedAssets != actualAssets) revert ERC4626AssetAmountMismatch(reportedAssets, actualAssets);

                // Emergency redemption is sized from the raw share balance, so
                // donated shares must absorb the burn before locally owned shares.
                uint256 ownShares = _ownShares;
                _ownShares = ownShares < shareBalanceAfter ? ownShares : shareBalanceAfter;
                emit OwnSharesUpdated(_ownShares);
            }
        }

        uint256 idleUnderlying = underlyingToken.balanceOf(address(this));
        if (idleUnderlying == 0) return 0;

        sent = _returnUnderlyingPrincipalToVault(idleUnderlying);
    }
}
