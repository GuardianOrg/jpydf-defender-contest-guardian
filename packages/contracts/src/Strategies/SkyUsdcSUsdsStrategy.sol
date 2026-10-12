// SPDX-License-Identifier: BUSL-1.1

pragma solidity 0.8.24;

import "openzeppelin-contracts/contracts/interfaces/IERC4626.sol";
import "openzeppelin-contracts/contracts/token/ERC20/IERC20.sol";
import "openzeppelin-contracts/contracts/token/ERC20/extensions/IERC20Metadata.sol";
import "openzeppelin-contracts/contracts/token/ERC20/utils/SafeERC20.sol";
import "openzeppelin-contracts/contracts/utils/math/Math.sol";

import {ISkyUsdcSUsdsConverter} from "../Interfaces/ISkyUsdcSUsdsConverter.sol";
import "./BaseStrategy.sol";

/**
 * @title SkyUsdcSUsdsStrategy - USDC -> USDS -> sUSDS asset-transforming Strategy.
 * @notice Keeps the Vault underlying as USDC while deploying idle USDC into
 *         Sky sUSDS through an explicit converter boundary.
 * @dev The Strategy values only sUSDS shares minted by its own deposit path and
 *      USDS produced by its own emergency redeem path. Direct sUSDS / USDS /
 *      USDC donations do not inflate `estimatedTotalUnderlying()` or
 *      `realizedYield()`.
 * @custom:security-contact security@deltaforesight.xyz
 */
contract SkyUsdcSUsdsStrategy is BaseStrategy {
    using SafeERC20 for IERC20;

    // =============================================================
    //                         STATE
    // =============================================================

    IERC20 public usdsToken;
    IERC4626 public susdsVault;
    ISkyUsdcSUsdsConverter public converter;
    uint256 public maxConversionLossBps;

    uint256 internal _ownSUsdsShares;
    uint256 internal _ownIdleUsds;

    /// @dev Storage gap for future upgrades of this derived contract.
    uint256[44] private __gapSkyUsdcSUsds;

    // =============================================================
    //                         CONSTANTS
    // =============================================================

    uint256 internal constant _BPS_DENOMINATOR = 10_000;
    uint256 internal constant _USDC_TO_USDS_SCALE = 1e12;
    uint256 public constant MAX_CONVERSION_LOSS_BPS = 1_000;

    // =============================================================
    //                          EVENTS
    // =============================================================

    event MaxConversionLossBpsUpdated(uint256 oldMaxConversionLossBps, uint256 newMaxConversionLossBps);
    event OwnSUsdsSharesUpdated(uint256 ownSUsdsShares);
    event OwnIdleUsdsUpdated(uint256 ownIdleUsds);
    event SkyDeposited(uint256 usdcAmount, uint256 usdsAmount, uint256 susdsShares);
    event SkySUsdsRedeemed(uint256 usdsAmount, uint256 susdsShares);
    event SkyUsdsConverted(uint256 usdsAmount, uint256 usdcAmount);

    // =============================================================
    //                          ERRORS
    // =============================================================

    error SkyUsdcSUsdsStrategy__InvalidSUsdsAsset();
    error SkyUsdcSUsdsStrategy__InvalidConverterUsdc();
    error SkyUsdcSUsdsStrategy__InvalidConverterUsds();
    error SkyUsdcSUsdsStrategy__InvalidUsdcDecimals(uint8 decimals);
    error SkyUsdcSUsdsStrategy__InvalidUsdsDecimals(uint8 decimals);
    error SkyUsdcSUsdsStrategy__InvalidSUsdsDecimals(uint8 decimals);
    error SkyUsdcSUsdsStrategy__InvalidMaxConversionLossBps(uint256 maxConversionLossBps);
    error SkyUsdcSUsdsStrategy__InsufficientUsdsOut(uint256 actual, uint256 minimum);
    error SkyUsdcSUsdsStrategy__InsufficientUsdcOut(uint256 actual, uint256 minimum);
    error SkyUsdcSUsdsStrategy__UsdsAmountMismatch(uint256 reported, uint256 actual);
    error SkyUsdcSUsdsStrategy__UsdcAmountMismatch(uint256 reported, uint256 actual);
    error SkyUsdcSUsdsStrategy__InvalidUsdsSpent(uint256 actual, uint256 maximum);
    error SkyUsdcSUsdsStrategy__SUsdsShareBalanceMismatch();
    error SkyUsdcSUsdsStrategy__SUsdsZeroShares();
    error SkyUsdcSUsdsStrategy__ZeroUsdcOut(uint256 usdsAmount);
    error SkyUsdcSUsdsStrategy__UnexpectedTokenBalance(address token, uint256 expected, uint256 actual);

    // =============================================================
    //                        INITIALIZER
    // =============================================================

    function initialize(
        address _vault,
        IERC20 _usdcUnderlying,
        address _owner,
        address _upgrader,
        IERC20 _usdsToken,
        IERC4626 _susdsVault,
        ISkyUsdcSUsdsConverter _converter,
        uint256 _maxConversionLossBps
    ) external initializer {
        __BaseStrategy_init(_vault, _usdcUnderlying, _owner, _upgrader);

        if (address(_usdsToken) == address(0)) revert ZeroAddress();
        if (address(_susdsVault) == address(0)) revert ZeroAddress();
        if (address(_converter) == address(0)) revert ZeroAddress();
        if (address(_usdsToken).code.length == 0) revert NotContract(address(_usdsToken));
        if (address(_susdsVault).code.length == 0) revert NotContract(address(_susdsVault));
        if (address(_converter).code.length == 0) revert NotContract(address(_converter));
        if (_susdsVault.asset() != address(_usdsToken)) revert SkyUsdcSUsdsStrategy__InvalidSUsdsAsset();
        if (address(_converter.usdcToken()) != address(_usdcUnderlying)) {
            revert SkyUsdcSUsdsStrategy__InvalidConverterUsdc();
        }
        if (address(_converter.usdsToken()) != address(_usdsToken)) {
            revert SkyUsdcSUsdsStrategy__InvalidConverterUsds();
        }

        uint8 usdcDecimals = IERC20Metadata(address(_usdcUnderlying)).decimals();
        if (usdcDecimals != 6) revert SkyUsdcSUsdsStrategy__InvalidUsdcDecimals(usdcDecimals);
        uint8 usdsDecimals = IERC20Metadata(address(_usdsToken)).decimals();
        if (usdsDecimals != 18) revert SkyUsdcSUsdsStrategy__InvalidUsdsDecimals(usdsDecimals);
        uint8 susdsDecimals = IERC20Metadata(address(_susdsVault)).decimals();
        if (susdsDecimals != 18) revert SkyUsdcSUsdsStrategy__InvalidSUsdsDecimals(susdsDecimals);

        _requireValidMaxConversionLossBps(_maxConversionLossBps);

        usdsToken = _usdsToken;
        susdsVault = _susdsVault;
        converter = _converter;
        maxConversionLossBps = _maxConversionLossBps;
    }

    // =============================================================
    //                    SKY-SPECIFIC VIEWS
    // =============================================================

    function ownSUsdsShares() external view returns (uint256) {
        return _ownSUsdsShares;
    }

    function ownIdleUsds() external view returns (uint256) {
        return _ownIdleUsds;
    }

    // =============================================================
    //                    SKY-SPECIFIC MUTATORS
    // =============================================================

    function setMaxConversionLossBps(uint256 _maxConversionLossBps) external onlyOwner {
        _requireValidMaxConversionLossBps(_maxConversionLossBps);
        uint256 oldMaxConversionLossBps = maxConversionLossBps;
        maxConversionLossBps = _maxConversionLossBps;
        emit MaxConversionLossBpsUpdated(oldMaxConversionLossBps, _maxConversionLossBps);
    }

    function emergencyRedeemSUsdsToUsds(uint256 _usdsAmount)
        external
        onlyOwner
        nonReentrantStrategy
        returns (uint256 usdsReceived)
    {
        usdsReceived = _redeemSUsdsForUsds(_usdsAmount);
    }

    function emergencyConvertIdleUsdsToVault(uint256 _usdsAmount, uint256 _minUsdcOut)
        external
        onlyOwner
        nonReentrantStrategy
        returns (uint256 sent)
    {
        uint256 usdsToConvert = _usdsAmount < _ownIdleUsds ? _usdsAmount : _ownIdleUsds;
        uint256 usdcReceived = _convertUsdsToUsdc(usdsToConvert, _minUsdcOut);
        if (usdcReceived == 0) return 0;

        sent = _returnUnderlyingPrincipalToVault(usdcReceived);
    }

    function emergencyWithdrawFromSky(uint256 _maxUsdsToRedeem, uint256 _minUsdcOut)
        external
        onlyOwner
        nonReentrantStrategy
        returns (uint256 sent)
    {
        if (_maxUsdsToRedeem != 0) {
            _redeemSUsdsForUsds(_maxUsdsToRedeem);
        }

        uint256 usdcReceived = _convertUsdsToUsdc(_ownIdleUsds, _minUsdcOut);
        if (usdcReceived == 0) return 0;

        sent = _returnUnderlyingPrincipalToVault(usdcReceived);
    }

    // =============================================================
    //                  BaseStrategy HOOKS
    // =============================================================

    /// @inheritdoc BaseStrategy
    function _doDeposit(uint256 _amount) internal override {
        uint256 minUsdsOut = _minimumUsdsOut(_amount);
        uint256 usdsAmount = _convertUsdcToUsds(_amount, minUsdsOut);
        uint256 susdsShares = _depositUsdsIntoSUsds(usdsAmount);

        emit SkyDeposited(_amount, usdsAmount, susdsShares);
    }

    /// @inheritdoc BaseStrategy
    function _doWithdraw(uint256 _amount) internal override returns (uint256 actual) {
        uint256 usdsTarget = _usdsTargetForUsdc(_amount);
        uint256 idleUsds = _ownIdleUsds;
        if (idleUsds < usdsTarget) {
            _redeemSUsdsForUsds(usdsTarget - idleUsds);
        }

        uint256 usdsToConvert = _ownIdleUsds < usdsTarget ? _ownIdleUsds : usdsTarget;
        actual = _convertUsdsToUsdc(usdsToConvert, _minimumUsdcOut(usdsToConvert));
    }

    /// @inheritdoc BaseStrategy
    function _estimatedTotalUnderlying() internal view override returns (uint256) {
        uint256 usdsValue = _ownedSUsdsUsdsValue() + _ownIdleUsds;
        if (usdsValue == 0) return 0;

        uint256 oneToOneUsdc = _usdsToUsdc(usdsValue);
        if (converter.isUsdsToUsdcRouteHalted()) {
            uint256 principalCached = _principal;
            return oneToOneUsdc < principalCached ? oneToOneUsdc : principalCached;
        }

        uint256 quotedUsdc = converter.previewUsdsToUsdc(usdsValue);
        return quotedUsdc < oneToOneUsdc ? quotedUsdc : oneToOneUsdc;
    }

    /// @inheritdoc BaseStrategy
    function _isSweepProtectedToken(address _token) internal view override returns (bool) {
        return super._isSweepProtectedToken(_token) || _token == address(usdsToken) || _token == address(susdsVault);
    }

    // =============================================================
    //                   INTERNAL FUNCTIONS
    // =============================================================

    function _convertUsdcToUsds(uint256 _usdcAmount, uint256 _minUsdsOut) internal returns (uint256 usdsAmount) {
        IERC20 underlyingCached = underlyingToken;
        IERC20 usds = usdsToken;
        ISkyUsdcSUsdsConverter converterCached = converter;

        uint256 usdcBalanceBefore = underlyingCached.balanceOf(address(this));
        uint256 usdsBalanceBefore = usds.balanceOf(address(this));
        underlyingCached.forceApprove(address(converterCached), _usdcAmount);
        uint256 reportedUsdsAmount = converterCached.convertUsdcToUsds(_usdcAmount, _minUsdsOut, address(this));
        underlyingCached.forceApprove(address(converterCached), 0);

        _requireTokenBalance(underlyingCached, usdcBalanceBefore - _usdcAmount);
        usdsAmount = usds.balanceOf(address(this)) - usdsBalanceBefore;
        if (reportedUsdsAmount != usdsAmount) {
            revert SkyUsdcSUsdsStrategy__UsdsAmountMismatch(reportedUsdsAmount, usdsAmount);
        }
        if (usdsAmount < _minUsdsOut) revert SkyUsdcSUsdsStrategy__InsufficientUsdsOut(usdsAmount, _minUsdsOut);
    }

    function _depositUsdsIntoSUsds(uint256 _usdsAmount) internal returns (uint256 susdsShares) {
        IERC20 usds = usdsToken;
        IERC4626 susds = susdsVault;

        uint256 usdsBalanceBefore = usds.balanceOf(address(this));
        uint256 shareBalanceBefore = susds.balanceOf(address(this));
        usds.forceApprove(address(susds), _usdsAmount);
        uint256 reportedShares = susds.deposit(_usdsAmount, address(this));
        usds.forceApprove(address(susds), 0);

        _requireTokenBalance(usds, usdsBalanceBefore - _usdsAmount);

        uint256 shareBalanceAfter = susds.balanceOf(address(this));
        if (shareBalanceAfter < shareBalanceBefore) revert SkyUsdcSUsdsStrategy__SUsdsShareBalanceMismatch();
        susdsShares = shareBalanceAfter - shareBalanceBefore;
        if (susdsShares == 0) revert SkyUsdcSUsdsStrategy__SUsdsZeroShares();
        if (susdsShares != reportedShares) revert SkyUsdcSUsdsStrategy__SUsdsShareBalanceMismatch();

        _ownSUsdsShares += susdsShares;
        emit OwnSUsdsSharesUpdated(_ownSUsdsShares);
    }

    function _redeemSUsdsForUsds(uint256 _usdsAmount) internal returns (uint256 usdsReceived) {
        if (_usdsAmount == 0) return 0;

        IERC4626 susds = susdsVault;
        uint256 ownShares = _ownSUsdsShares;
        if (ownShares == 0) return 0;

        uint256 currentShareBalance = susds.balanceOf(address(this));
        uint256 effectiveShares = ownShares < currentShareBalance ? ownShares : currentShareBalance;
        if (effectiveShares == 0) return 0;

        uint256 ownedAssets = susds.convertToAssets(effectiveShares);
        uint256 maxAssets = susds.maxWithdraw(address(this));
        uint256 assetsToWithdraw = ownedAssets < maxAssets ? ownedAssets : maxAssets;
        if (_usdsAmount < assetsToWithdraw) assetsToWithdraw = _usdsAmount;
        if (assetsToWithdraw == 0) return 0;

        uint256 usdsBalanceBefore = usdsToken.balanceOf(address(this));
        uint256 shareBalanceBefore = currentShareBalance;
        uint256 reportedBurnedShares = susds.withdraw(assetsToWithdraw, address(this), address(this));
        uint256 shareBalanceAfter = susds.balanceOf(address(this));
        if (shareBalanceAfter > shareBalanceBefore) revert SkyUsdcSUsdsStrategy__SUsdsShareBalanceMismatch();

        uint256 actualBurnedShares = shareBalanceBefore - shareBalanceAfter;
        if (actualBurnedShares != reportedBurnedShares) revert SkyUsdcSUsdsStrategy__SUsdsShareBalanceMismatch();

        usdsReceived = usdsToken.balanceOf(address(this)) - usdsBalanceBefore;
        if (usdsReceived != assetsToWithdraw) {
            revert SkyUsdcSUsdsStrategy__UsdsAmountMismatch(assetsToWithdraw, usdsReceived);
        }

        _ownSUsdsShares = actualBurnedShares > ownShares ? 0 : ownShares - actualBurnedShares;
        _increaseOwnIdleUsds(usdsReceived);

        emit OwnSUsdsSharesUpdated(_ownSUsdsShares);
        emit SkySUsdsRedeemed(usdsReceived, actualBurnedShares);
    }

    function _convertUsdsToUsdc(uint256 _usdsAmount, uint256 _minUsdcOut) internal returns (uint256 usdcAmount) {
        if (_usdsAmount == 0) return 0;

        IERC20 usds = usdsToken;
        IERC20 underlyingCached = underlyingToken;
        ISkyUsdcSUsdsConverter converterCached = converter;
        uint256 enforcedMinUsdcOut = _minimumUsdcOut(_usdsAmount);
        if (_minUsdcOut > enforcedMinUsdcOut) enforcedMinUsdcOut = _minUsdcOut;

        uint256 usdsBalanceBefore = usds.balanceOf(address(this));
        uint256 usdcBalanceBefore = underlyingCached.balanceOf(address(this));
        usds.forceApprove(address(converterCached), _usdsAmount);
        uint256 reportedUsdcAmount = converterCached.convertUsdsToUsdc(_usdsAmount, enforcedMinUsdcOut, address(this));
        usds.forceApprove(address(converterCached), 0);

        uint256 usdsBalanceAfter = usds.balanceOf(address(this));
        if (usdsBalanceAfter > usdsBalanceBefore) {
            revert SkyUsdcSUsdsStrategy__UnexpectedTokenBalance(address(usds), usdsBalanceBefore, usdsBalanceAfter);
        }
        uint256 usdsSpent = usdsBalanceBefore - usdsBalanceAfter;
        if (usdsSpent == 0 || usdsSpent > _usdsAmount) {
            revert SkyUsdcSUsdsStrategy__InvalidUsdsSpent(usdsSpent, _usdsAmount);
        }
        usdcAmount = underlyingCached.balanceOf(address(this)) - usdcBalanceBefore;
        if (reportedUsdcAmount != usdcAmount) {
            revert SkyUsdcSUsdsStrategy__UsdcAmountMismatch(reportedUsdcAmount, usdcAmount);
        }
        if (usdcAmount < enforcedMinUsdcOut) {
            revert SkyUsdcSUsdsStrategy__InsufficientUsdcOut(usdcAmount, enforcedMinUsdcOut);
        }
        if (usdcAmount == 0) revert SkyUsdcSUsdsStrategy__ZeroUsdcOut(_usdsAmount);

        _decreaseOwnIdleUsds(usdsSpent);
        emit SkyUsdsConverted(usdsSpent, usdcAmount);
    }

    function _increaseOwnIdleUsds(uint256 _amount) internal {
        if (_amount == 0) return;
        _ownIdleUsds += _amount;
        emit OwnIdleUsdsUpdated(_ownIdleUsds);
    }

    function _decreaseOwnIdleUsds(uint256 _amount) internal {
        if (_amount == 0) return;
        uint256 idleUsds = _ownIdleUsds;
        _ownIdleUsds = _amount > idleUsds ? 0 : idleUsds - _amount;
        emit OwnIdleUsdsUpdated(_ownIdleUsds);
    }

    function _ownedSUsdsUsdsValue() internal view returns (uint256) {
        uint256 currentShareBalance = susdsVault.balanceOf(address(this));
        uint256 effectiveShares = _ownSUsdsShares < currentShareBalance ? _ownSUsdsShares : currentShareBalance;
        if (effectiveShares == 0) return 0;
        return susdsVault.convertToAssets(effectiveShares);
    }

    function _minimumUsdsOut(uint256 _usdcAmount) internal view returns (uint256) {
        return Math.mulDiv(_usdcToUsds(_usdcAmount), _BPS_DENOMINATOR - maxConversionLossBps, _BPS_DENOMINATOR);
    }

    function _minimumUsdcOut(uint256 _usdsAmount) internal view returns (uint256) {
        return Math.mulDiv(_usdsToUsdc(_usdsAmount), _BPS_DENOMINATOR - maxConversionLossBps, _BPS_DENOMINATOR);
    }

    function _usdcToUsdsWithLossBuffer(uint256 _usdcAmount) internal view returns (uint256) {
        uint256 denominator = _BPS_DENOMINATOR - maxConversionLossBps;
        return Math.mulDiv(_usdcAmount, _USDC_TO_USDS_SCALE * _BPS_DENOMINATOR, denominator, Math.Rounding.Up);
    }

    function _usdsTargetForUsdc(uint256 _usdcAmount) internal view returns (uint256) {
        uint256 oneToOneUsds = _usdcToUsds(_usdcAmount);
        if (converter.previewUsdsToUsdc(oneToOneUsds) >= _usdcAmount) return oneToOneUsds;
        return _usdcToUsdsWithLossBuffer(_usdcAmount);
    }

    function _usdcToUsds(uint256 _usdcAmount) internal pure returns (uint256) {
        return _usdcAmount * _USDC_TO_USDS_SCALE;
    }

    function _usdsToUsdc(uint256 _usdsAmount) internal pure returns (uint256) {
        return _usdsAmount / _USDC_TO_USDS_SCALE;
    }

    function _requireValidMaxConversionLossBps(uint256 _maxConversionLossBps) internal pure {
        if (_maxConversionLossBps > MAX_CONVERSION_LOSS_BPS) {
            revert SkyUsdcSUsdsStrategy__InvalidMaxConversionLossBps(_maxConversionLossBps);
        }
    }

    function _requireTokenBalance(IERC20 _token, uint256 _expectedBalance) internal view {
        uint256 actualBalance = _token.balanceOf(address(this));
        if (actualBalance != _expectedBalance) {
            revert SkyUsdcSUsdsStrategy__UnexpectedTokenBalance(address(_token), _expectedBalance, actualBalance);
        }
    }
}
