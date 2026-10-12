// SPDX-License-Identifier: MIT

pragma solidity 0.8.24;

import {IERC20} from "openzeppelin-contracts/contracts/token/ERC20/IERC20.sol";
import {IERC20Metadata} from "openzeppelin-contracts/contracts/token/ERC20/extensions/IERC20Metadata.sol";
import {SafeERC20} from "openzeppelin-contracts/contracts/token/ERC20/utils/SafeERC20.sol";
import {IERC4626} from "openzeppelin-contracts/contracts/interfaces/IERC4626.sol";

import {ETH_GAS_COMPENSATION} from "../../Dependencies/Constants.sol";
import {ICollateralVault} from "../../Interfaces/ICollateralVault.sol";
import {IAddressesRegistry} from "../../Interfaces/IAddressesRegistry.sol";
import {ISkyUsdcSUsdsConverter} from "../../Interfaces/ISkyUsdcSUsdsConverter.sol";
import {CollateralYieldZapper} from "../CollateralYieldZapper.sol";

/**
 * @title SkyUsdcSUsdsYieldZapper
 * @notice USDC -> USDS -> sUSDS -> dUSDS route variant for CollateralYieldZapper.
 * @custom:security-contact security@deltaforesight.xyz
 */
contract SkyUsdcSUsdsYieldZapper is CollateralYieldZapper {
    using SafeERC20 for IERC20;

    IERC20 public immutable usdcToken;
    IERC20 public immutable usdsToken;
    IERC4626 public immutable susdsVault;
    ISkyUsdcSUsdsConverter public immutable usdcUsdsConverter;

    event SkyUsdcRouteDeposit(
        address indexed user,
        uint256 indexed troveId,
        uint256 usdcAmount,
        uint256 usdsAmount,
        uint256 susdsAmount,
        uint256 dTokenAmount,
        bytes32 indexed referralCode
    );
    event SkyUsdcRouteAddColl(
        address indexed user,
        uint256 indexed troveId,
        uint256 usdcAmount,
        uint256 usdsAmount,
        uint256 susdsAmount,
        uint256 dTokenAmount
    );

    error SkyUsdcSUsdsYieldZapper__ZeroAddress();
    error SkyUsdcSUsdsYieldZapper__NotContract(address target);
    error SkyUsdcSUsdsYieldZapper__ZeroAmount();
    error SkyUsdcSUsdsYieldZapper__InvalidSUsdsAsset();
    error SkyUsdcSUsdsYieldZapper__InvalidUsdcDecimals(uint8 decimals);
    error SkyUsdcSUsdsYieldZapper__InvalidUsdsDecimals(uint8 decimals);
    error SkyUsdcSUsdsYieldZapper__InvalidSUsdsDecimals(uint8 decimals);
    error SkyUsdcSUsdsYieldZapper__InvalidConverterUsdc();
    error SkyUsdcSUsdsYieldZapper__InvalidConverterUsds();
    error SkyUsdcSUsdsYieldZapper__InsufficientUsdsOut(uint256 actual, uint256 minimum);
    error SkyUsdcSUsdsYieldZapper__InsufficientSUsdsOut(uint256 actual, uint256 minimum);
    error SkyUsdcSUsdsYieldZapper__UsdsAmountMismatch(uint256 reported, uint256 actual);
    error SkyUsdcSUsdsYieldZapper__UnexpectedTokenResidue(address token, uint256 expected, uint256 actual);

    constructor(
        IAddressesRegistry _addressesRegistry,
        ICollateralVault _collateralVault,
        IERC4626 _susdsVault,
        IERC20 _usdcToken,
        IERC20 _usdsToken,
        ISkyUsdcSUsdsConverter _usdcUsdsConverter
    ) CollateralYieldZapper(_addressesRegistry, _collateralVault, IERC20(address(_susdsVault)), address(0)) {
        if (
            address(_usdcToken) == address(0) || address(_usdsToken) == address(0)
                || address(_usdcUsdsConverter) == address(0)
        ) {
            revert SkyUsdcSUsdsYieldZapper__ZeroAddress();
        }
        if (address(_usdcToken).code.length == 0) {
            revert SkyUsdcSUsdsYieldZapper__NotContract(address(_usdcToken));
        }
        if (address(_usdsToken).code.length == 0) {
            revert SkyUsdcSUsdsYieldZapper__NotContract(address(_usdsToken));
        }
        if (address(_usdcUsdsConverter).code.length == 0) {
            revert SkyUsdcSUsdsYieldZapper__NotContract(address(_usdcUsdsConverter));
        }
        if (_susdsVault.asset() != address(_usdsToken)) revert SkyUsdcSUsdsYieldZapper__InvalidSUsdsAsset();

        uint8 usdcDecimals = IERC20Metadata(address(_usdcToken)).decimals();
        if (usdcDecimals != 6) revert SkyUsdcSUsdsYieldZapper__InvalidUsdcDecimals(usdcDecimals);

        uint8 usdsDecimals = IERC20Metadata(address(_usdsToken)).decimals();
        if (usdsDecimals != 18) revert SkyUsdcSUsdsYieldZapper__InvalidUsdsDecimals(usdsDecimals);

        uint8 susdsDecimals = IERC20Metadata(address(_susdsVault)).decimals();
        if (susdsDecimals != 18) revert SkyUsdcSUsdsYieldZapper__InvalidSUsdsDecimals(susdsDecimals);

        if (address(_usdcUsdsConverter.usdcToken()) != address(_usdcToken)) {
            revert SkyUsdcSUsdsYieldZapper__InvalidConverterUsdc();
        }
        if (address(_usdcUsdsConverter.usdsToken()) != address(_usdsToken)) {
            revert SkyUsdcSUsdsYieldZapper__InvalidConverterUsds();
        }

        usdcToken = _usdcToken;
        usdsToken = _usdsToken;
        susdsVault = _susdsVault;
        usdcUsdsConverter = _usdcUsdsConverter;
    }

    /*//////////////////////////////////////////////////////////////
                    USER-FACING STATE-CHANGING FUNCTIONS
    //////////////////////////////////////////////////////////////*/

    function openTroveWithUsdc(OpenTroveParams calldata _params, uint256 _minUsdsOut, uint256 _minSUsdsOut)
        external
        payable
        nonReentrant
        returns (uint256 troveId)
    {
        troveId = _openTroveWithUsdcAndReferral(_params, _minUsdsOut, _minSUsdsOut, bytes32(0));
    }

    function openTroveWithUsdcAndReferral(
        OpenTroveParams calldata _params,
        uint256 _minUsdsOut,
        uint256 _minSUsdsOut,
        bytes32 _referralCode
    ) external payable nonReentrant returns (uint256 troveId) {
        troveId = _openTroveWithUsdcAndReferral(_params, _minUsdsOut, _minSUsdsOut, _referralCode);
    }

    function addCollWithUsdc(uint256 _troveId, uint256 _usdcAmount, uint256 _minUsdsOut, uint256 _minSUsdsOut)
        external
        nonReentrant
        returns (uint256 usdsAmount, uint256 susdsAmount, uint256 dTokenAmount)
    {
        address owner = troveNFT.ownerOf(_troveId);
        _requireSenderIsOwnerOrAddManager(_troveId, owner);

        uint256 usdcAmount;
        (usdcAmount, usdsAmount, susdsAmount, dTokenAmount) =
            _pullUsdcAndDepositDUsds(_usdcAmount, _minUsdsOut, _minSUsdsOut);
        borrowerOperations.addColl(_troveId, dTokenAmount);

        emit SkyUsdcRouteAddColl(msg.sender, _troveId, usdcAmount, usdsAmount, susdsAmount, dTokenAmount);
    }

    /*//////////////////////////////////////////////////////////////
                   INTERNAL STATE-CHANGING FUNCTIONS
    //////////////////////////////////////////////////////////////*/

    function _openTroveWithUsdcAndReferral(
        OpenTroveParams calldata _params,
        uint256 _minUsdsOut,
        uint256 _minSUsdsOut,
        bytes32 _referralCode
    ) internal returns (uint256 troveId) {
        if (msg.value != ETH_GAS_COMPENSATION) revert CollateralYieldZapper__WrongETH();
        _requireOpenOwnerIsSender(_params.owner);
        _requireValidOpenBatchParams(_params);

        WETH.deposit{value: msg.value}();

        (uint256 usdcAmount, uint256 usdsAmount, uint256 susdsAmount, uint256 dTokenAmount) =
            _pullUsdcAndDepositDUsds(_params.collAmount, _minUsdsOut, _minSUsdsOut);
        troveId = _openTroveWithDTokenCollateral(_params, dTokenAmount);

        if (_referralCode != bytes32(0)) {
            emit ReferralDeposit(msg.sender, troveId, usdcAmount, dTokenAmount, _params.jpydfAmount, _referralCode);
        }
        emit SkyUsdcRouteDeposit(msg.sender, troveId, usdcAmount, usdsAmount, susdsAmount, dTokenAmount, _referralCode);
    }

    function _pullUsdcAndDepositDUsds(uint256 _usdcAmount, uint256 _minUsdsOut, uint256 _minSUsdsOut)
        internal
        returns (uint256 usdcAmount, uint256 usdsAmount, uint256 susdsAmount, uint256 dTokenAmount)
    {
        if (_usdcAmount == 0) revert SkyUsdcSUsdsYieldZapper__ZeroAmount();

        IERC20 usdcTokenCached = usdcToken;
        IERC20 susdsTokenCached = IERC20(address(susdsVault));

        uint256 usdcBalanceBefore = usdcTokenCached.balanceOf(address(this));
        usdcTokenCached.safeTransferFrom(msg.sender, address(this), _usdcAmount);
        usdcAmount = usdcTokenCached.balanceOf(address(this)) - usdcBalanceBefore;

        uint256 usdsBalanceBefore = usdsToken.balanceOf(address(this));
        usdsAmount = _convertUsdcToUsds(
            usdcTokenCached, usdsToken, usdcUsdsConverter, usdcAmount, _minUsdsOut, usdcBalanceBefore, usdsBalanceBefore
        );

        uint256 susdsBalanceBefore = susdsTokenCached.balanceOf(address(this));
        usdsToken.forceApprove(address(susdsVault), usdsAmount);
        susdsAmount = susdsVault.deposit(usdsAmount, address(this));
        usdsToken.forceApprove(address(susdsVault), 0);
        _requireBalanceReturned(usdsToken, usdsBalanceBefore);

        if (susdsAmount < _minSUsdsOut || susdsAmount == 0) {
            revert SkyUsdcSUsdsYieldZapper__InsufficientSUsdsOut(susdsAmount, _minSUsdsOut);
        }

        dTokenAmount = collateralVault.deposit(susdsAmount);
        _requireBalanceReturned(susdsTokenCached, susdsBalanceBefore);
    }

    function _convertUsdcToUsds(
        IERC20 _usdcToken,
        IERC20 _usdsToken,
        ISkyUsdcSUsdsConverter _converter,
        uint256 _usdcAmount,
        uint256 _minUsdsOut,
        uint256 _expectedUsdcBalance,
        uint256 _expectedUsdsBalance
    ) internal returns (uint256 usdsAmount) {
        _usdcToken.forceApprove(address(_converter), _usdcAmount);
        uint256 reportedUsdsAmount = _converter.convertUsdcToUsds(_usdcAmount, _minUsdsOut, address(this));
        _usdcToken.forceApprove(address(_converter), 0);
        _requireBalanceReturned(_usdcToken, _expectedUsdcBalance);

        usdsAmount = _usdsToken.balanceOf(address(this)) - _expectedUsdsBalance;
        if (reportedUsdsAmount != usdsAmount) {
            revert SkyUsdcSUsdsYieldZapper__UsdsAmountMismatch(reportedUsdsAmount, usdsAmount);
        }
        if (usdsAmount < _minUsdsOut) {
            revert SkyUsdcSUsdsYieldZapper__InsufficientUsdsOut(usdsAmount, _minUsdsOut);
        }
    }

    function _requireBalanceReturned(IERC20 _token, uint256 _expectedBalance) internal view {
        uint256 actualBalance = _token.balanceOf(address(this));
        if (actualBalance != _expectedBalance) {
            revert SkyUsdcSUsdsYieldZapper__UnexpectedTokenResidue(address(_token), _expectedBalance, actualBalance);
        }
    }
}
