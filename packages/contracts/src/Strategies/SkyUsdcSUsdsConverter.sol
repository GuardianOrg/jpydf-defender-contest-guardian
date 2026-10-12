// SPDX-License-Identifier: BUSL-1.1

pragma solidity 0.8.24;

import {IERC20} from "openzeppelin-contracts/contracts/token/ERC20/IERC20.sol";
import {IERC20Metadata} from "openzeppelin-contracts/contracts/token/ERC20/extensions/IERC20Metadata.sol";
import {SafeERC20} from "openzeppelin-contracts/contracts/token/ERC20/utils/SafeERC20.sol";
import {ReentrancyGuard} from "openzeppelin-contracts/contracts/security/ReentrancyGuard.sol";
import {Math} from "openzeppelin-contracts/contracts/utils/math/Math.sol";

import {ISkyLitePsmWrapper, ISkyUsdcSUsdsConverter} from "../Interfaces/ISkyUsdcSUsdsConverter.sol";

/**
 * @title SkyUsdcSUsdsConverter
 * @notice Non-upgradeable USDC <-> USDS adapter for Sky's LitePSMWrapper-USDS-USDC.
 * @dev The reverse route treats `maxUsdsIn` as a budget because Sky's `buyGem`
 *      is output-denominated in six-decimal USDC. Any unspent USDS is returned
 *      to the caller in the same transaction.
 * @custom:security-contact security@deltaforesight.xyz
 */
contract SkyUsdcSUsdsConverter is ISkyUsdcSUsdsConverter, ReentrancyGuard {
    using SafeERC20 for IERC20;

    uint256 internal constant _WAD = 1e18;
    uint256 internal constant _USDC_TO_USDS_SCALE = 1e12;
    uint256 internal constant _HALTED = type(uint256).max;

    ISkyLitePsmWrapper public immutable psmWrapper;
    IERC20 public immutable usdcToken;
    IERC20 public immutable usdsToken;

    struct SwapBalances {
        uint256 converterUsdc;
        uint256 converterUsds;
        uint256 receiverToken;
    }

    event UsdcConvertedToUsds(address indexed caller, address indexed receiver, uint256 usdcAmount, uint256 usdsOut);
    event UsdsConvertedToUsdc(address indexed caller, address indexed receiver, uint256 usdsSpent, uint256 usdcOut);

    error SkyUsdcSUsdsConverter__ZeroAddress();
    error SkyUsdcSUsdsConverter__NotContract(address account);
    error SkyUsdcSUsdsConverter__ZeroAmount();
    error SkyUsdcSUsdsConverter__InvalidUsdcDecimals(uint8 decimals);
    error SkyUsdcSUsdsConverter__InvalidUsdsDecimals(uint8 decimals);
    error SkyUsdcSUsdsConverter__InvalidFee(uint256 fee);
    error SkyUsdcSUsdsConverter__RouteHalted();
    error SkyUsdcSUsdsConverter__InsufficientUsdsOut(uint256 actual, uint256 minimum);
    error SkyUsdcSUsdsConverter__InsufficientUsdcOut(uint256 actual, uint256 minimum);
    error SkyUsdcSUsdsConverter__TokenAmountMismatch(address token, uint256 reported, uint256 actual);
    error SkyUsdcSUsdsConverter__UnexpectedTokenBalance(address token, uint256 expected, uint256 actual);

    constructor(ISkyLitePsmWrapper _psmWrapper) {
        _requireContract(address(_psmWrapper));

        address usdc = _psmWrapper.gem();
        address usds = _psmWrapper.dai();
        _requireContract(usdc);
        _requireContract(usds);

        uint8 usdcDecimals = IERC20Metadata(usdc).decimals();
        if (usdcDecimals != 6) revert SkyUsdcSUsdsConverter__InvalidUsdcDecimals(usdcDecimals);
        uint8 usdsDecimals = IERC20Metadata(usds).decimals();
        if (usdsDecimals != 18) revert SkyUsdcSUsdsConverter__InvalidUsdsDecimals(usdsDecimals);

        psmWrapper = _psmWrapper;
        usdcToken = IERC20(usdc);
        usdsToken = IERC20(usds);
    }

    function convertUsdcToUsds(uint256 _usdcAmount, uint256 _minUsdsOut, address _receiver)
        external
        nonReentrant
        returns (uint256 usdsOut)
    {
        if (_usdcAmount == 0) revert SkyUsdcSUsdsConverter__ZeroAmount();
        _requireReceiver(_receiver);

        ISkyLitePsmWrapper wrapper = psmWrapper;
        uint256 tin = wrapper.tin();
        if (tin == _HALTED) revert SkyUsdcSUsdsConverter__RouteHalted();
        if (tin > _WAD) revert SkyUsdcSUsdsConverter__InvalidFee(tin);

        IERC20 usdc = usdcToken;
        IERC20 usds = usdsToken;
        SwapBalances memory beforeBalances = SwapBalances({
            converterUsdc: usdc.balanceOf(address(this)),
            converterUsds: usds.balanceOf(address(this)),
            receiverToken: usds.balanceOf(_receiver)
        });

        usdc.safeTransferFrom(msg.sender, address(this), _usdcAmount);
        _requireBalance(usdc, beforeBalances.converterUsdc + _usdcAmount);
        usdc.forceApprove(address(wrapper), _usdcAmount);
        uint256 reportedUsdsOut = wrapper.sellGem(_receiver, _usdcAmount);
        usdc.forceApprove(address(wrapper), 0);

        _requireBalance(usdc, beforeBalances.converterUsdc);
        _requireBalance(usds, beforeBalances.converterUsds);
        usdsOut = usds.balanceOf(_receiver) - beforeBalances.receiverToken;
        if (reportedUsdsOut != usdsOut) {
            revert SkyUsdcSUsdsConverter__TokenAmountMismatch(address(usds), reportedUsdsOut, usdsOut);
        }
        if (usdsOut < _minUsdsOut) {
            revert SkyUsdcSUsdsConverter__InsufficientUsdsOut(usdsOut, _minUsdsOut);
        }

        emit UsdcConvertedToUsds(msg.sender, _receiver, _usdcAmount, usdsOut);
    }

    function convertUsdsToUsdc(uint256 _maxUsdsIn, uint256 _minUsdcOut, address _receiver)
        external
        nonReentrant
        returns (uint256 usdcOut)
    {
        if (_maxUsdsIn == 0) revert SkyUsdcSUsdsConverter__ZeroAmount();
        _requireReceiver(_receiver);

        ISkyLitePsmWrapper wrapper = psmWrapper;
        uint256 tout = wrapper.tout();
        if (tout == _HALTED) revert SkyUsdcSUsdsConverter__RouteHalted();
        if (tout > _WAD) revert SkyUsdcSUsdsConverter__InvalidFee(tout);

        usdcOut = _previewUsdsToUsdc(_maxUsdsIn, tout);
        if (usdcOut == 0 || usdcOut < _minUsdcOut) {
            revert SkyUsdcSUsdsConverter__InsufficientUsdcOut(usdcOut, _minUsdcOut);
        }

        IERC20 usdc = usdcToken;
        IERC20 usds = usdsToken;
        SwapBalances memory beforeBalances = SwapBalances({
            converterUsdc: usdc.balanceOf(address(this)),
            converterUsds: usds.balanceOf(address(this)),
            receiverToken: usdc.balanceOf(_receiver)
        });

        usds.safeTransferFrom(msg.sender, address(this), _maxUsdsIn);
        _requireBalance(usds, beforeBalances.converterUsds + _maxUsdsIn);
        usds.forceApprove(address(wrapper), _maxUsdsIn);
        uint256 reportedUsdsIn = wrapper.buyGem(_receiver, usdcOut);
        usds.forceApprove(address(wrapper), 0);

        uint256 usdsAfterSwap = usds.balanceOf(address(this));
        uint256 actualUsdsIn = beforeBalances.converterUsds + _maxUsdsIn - usdsAfterSwap;
        if (reportedUsdsIn != actualUsdsIn) {
            revert SkyUsdcSUsdsConverter__TokenAmountMismatch(address(usds), reportedUsdsIn, actualUsdsIn);
        }

        uint256 refund = _maxUsdsIn - actualUsdsIn;
        if (refund != 0) usds.safeTransfer(msg.sender, refund);

        _requireBalance(usdc, beforeBalances.converterUsdc);
        _requireBalance(usds, beforeBalances.converterUsds);
        uint256 actualUsdcOut = usdc.balanceOf(_receiver) - beforeBalances.receiverToken;
        if (actualUsdcOut != usdcOut) {
            revert SkyUsdcSUsdsConverter__TokenAmountMismatch(address(usdc), usdcOut, actualUsdcOut);
        }

        emit UsdsConvertedToUsdc(msg.sender, _receiver, actualUsdsIn, usdcOut);
    }

    function previewUsdsToUsdc(uint256 _maxUsdsIn) external view returns (uint256 usdcOut) {
        uint256 tout = psmWrapper.tout();
        if (tout == _HALTED) revert SkyUsdcSUsdsConverter__RouteHalted();
        if (tout > _WAD) revert SkyUsdcSUsdsConverter__InvalidFee(tout);
        return _previewUsdsToUsdc(_maxUsdsIn, tout);
    }

    function isUsdsToUsdcRouteHalted() external view returns (bool) {
        return psmWrapper.tout() == _HALTED;
    }

    function _previewUsdsToUsdc(uint256 _maxUsdsIn, uint256 _tout) internal pure returns (uint256 usdcOut) {
        uint256 denominator = _USDC_TO_USDS_SCALE * (_WAD + _tout);
        usdcOut = Math.mulDiv(_maxUsdsIn, _WAD, denominator);

        if (usdcOut < type(uint256).max / _USDC_TO_USDS_SCALE) {
            uint256 next = usdcOut + 1;
            if (_requiredUsds(next, _tout) <= _maxUsdsIn) usdcOut = next;
        }
    }

    function _requiredUsds(uint256 _usdcAmount, uint256 _tout) internal pure returns (uint256) {
        uint256 base = _usdcAmount * _USDC_TO_USDS_SCALE;
        return base + Math.mulDiv(base, _tout, _WAD);
    }

    function _requireReceiver(address _receiver) internal view {
        if (_receiver == address(0) || _receiver == address(this)) {
            revert SkyUsdcSUsdsConverter__ZeroAddress();
        }
    }

    function _requireContract(address _account) internal view {
        if (_account == address(0)) revert SkyUsdcSUsdsConverter__ZeroAddress();
        if (_account.code.length == 0) revert SkyUsdcSUsdsConverter__NotContract(_account);
    }

    function _requireBalance(IERC20 _token, uint256 _expected) internal view {
        uint256 actual = _token.balanceOf(address(this));
        if (actual != _expected) {
            revert SkyUsdcSUsdsConverter__UnexpectedTokenBalance(address(_token), _expected, actual);
        }
    }
}
