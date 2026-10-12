// SPDX-License-Identifier: MIT

pragma solidity 0.8.24;

import {IERC20} from "openzeppelin-contracts/contracts/token/ERC20/IERC20.sol";
import {IERC20Permit} from "openzeppelin-contracts/contracts/token/ERC20/extensions/IERC20Permit.sol";
import {SafeERC20} from "openzeppelin-contracts/contracts/token/ERC20/utils/SafeERC20.sol";
import {ReentrancyGuard} from "openzeppelin-contracts/contracts/security/ReentrancyGuard.sol";
import {SafeTransferLib} from "Solady/utils/SafeTransferLib.sol";

import {ETH_GAS_COMPENSATION} from "../Dependencies/Constants.sol";
import {ICollateralVault} from "../Interfaces/ICollateralVault.sol";
import {IDToken} from "../Interfaces/IDToken.sol";
import {BaseZapper} from "./BaseZapper.sol";
import {IAddressesRegistry} from "../Interfaces/IAddressesRegistry.sol";
import {IBorrowerOperations} from "../Interfaces/IBorrowerOperations.sol";
import {LatestTroveData} from "../Types/LatestTroveData.sol";

/// @notice Minimal Lido stETH staking interface, local to the Zapper.
interface IStETHSubmit {
    function submit(address _referral) external payable returns (uint256);
}

/// @notice Minimal Lido wstETH wrap interface, local to the Zapper.
interface IWstETHWrap {
    function stETH() external view returns (address);
    function wrap(uint256 _stETHAmount) external returns (uint256);
}

/**
 * @title CollateralYieldZapper
 * @notice Underlying-denominated UX router for dToken collateral branches.
 * @custom:security-contact security@deltaforesight.xyz
 */
contract CollateralYieldZapper is BaseZapper, ReentrancyGuard {
    using SafeERC20 for IERC20;

    ICollateralVault public immutable collateralVault;
    IDToken public immutable dToken;
    IERC20 public immutable underlyingToken;
    IERC20 public immutable collToken;
    /// @notice Lido stETH, resolved from the branch underlying when it is wstETH; address(0) otherwise.
    IERC20 public immutable stEthToken;
    /// @notice Protocol-designated Lido referral recorded on every native-ETH `submit` for
    ///         Rewards Share attribution. address(0) disables attribution.
    ///         Deliberately not user-, URL-, or referral-registry-controlled.
    address public lidoReferral;
    /// @notice Governance address authorized to update Lido Rewards Share attribution.
    address public immutable lidoReferralManager;

    event LidoReferralUpdated(address indexed oldReferral, address indexed newReferral);
    event NativeEthRouteDeposit(
        address indexed user,
        uint256 indexed troveId,
        uint256 ethAmount,
        uint256 stEthAmount,
        uint256 wstEthAmount,
        uint256 dTokenAmount,
        bytes32 indexed referralCode
    );

    event ReferralDeposit(
        address indexed user,
        uint256 indexed troveId,
        uint256 underlyingAmount,
        uint256 dTokenAmount,
        uint256 jpydfAmount,
        bytes32 indexed referralCode
    );

    error CollateralYieldZapper__ZeroAddress();
    error CollateralYieldZapper__NotContract(address target);
    error CollateralYieldZapper__WrongETH();
    error CollateralYieldZapper__CannotChooseInterestIfJoiningBatch();
    error CollateralYieldZapper__PermitFailed();
    error CollateralYieldZapper__InvalidVaultDToken();
    error CollateralYieldZapper__InvalidVaultUnderlying();
    error CollateralYieldZapper__InsufficientUnderlyingReceived(uint256 actual, uint256 minimum);
    error CollateralYieldZapper__OnlyWETH();
    error CollateralYieldZapper__OwnerMismatch(address owner, address sender);
    error CollateralYieldZapper__NativeEthRouteUnavailable();
    error CollateralYieldZapper__StEthMismatch(address resolved, address expected);
    error CollateralYieldZapper__StEthSubmitFailed(bytes reason);
    error CollateralYieldZapper__InsufficientWstEthOut(uint256 actual, uint256 minimum);
    error CollateralYieldZapper__UnauthorizedReferralManager();

    constructor(
        IAddressesRegistry _addressesRegistry,
        ICollateralVault _collateralVault,
        IERC20 _underlyingToken,
        address _expectedStEth,
        address _lidoReferral,
        address _lidoReferralManager
    ) BaseZapper(_addressesRegistry) {
        if (
            address(_collateralVault) == address(0) || address(_underlyingToken) == address(0)
                || _lidoReferralManager == address(0)
        ) {
            revert CollateralYieldZapper__ZeroAddress();
        }
        if (address(_collateralVault).code.length == 0) {
            revert CollateralYieldZapper__NotContract(address(_collateralVault));
        }
        if (address(_underlyingToken).code.length == 0) {
            revert CollateralYieldZapper__NotContract(address(_underlyingToken));
        }

        IERC20 collToken_ = _addressesRegistry.collToken();
        if (address(_collateralVault.dToken()) != address(collToken_)) {
            revert CollateralYieldZapper__InvalidVaultDToken();
        }
        if (address(_collateralVault.underlying()) != address(_underlyingToken)) {
            revert CollateralYieldZapper__InvalidVaultUnderlying();
        }

        collateralVault = _collateralVault;
        dToken = IDToken(address(collToken_));
        underlyingToken = _underlyingToken;
        collToken = collToken_;

        // Native-ETH on-ramp is a deliberate deploy decision: address(0) disables the route;
        // a nonzero value must match the underlying's wstETH stETH() getter or deployment reverts.
        address stEth_;
        if (_expectedStEth != address(0)) {
            address resolvedStEth = IWstETHWrap(address(_underlyingToken)).stETH();
            if (resolvedStEth != _expectedStEth) {
                revert CollateralYieldZapper__StEthMismatch(resolvedStEth, _expectedStEth);
            }
            if (resolvedStEth.code.length == 0) {
                revert CollateralYieldZapper__NotContract(resolvedStEth);
            }
            stEth_ = resolvedStEth;
        }
        stEthToken = IERC20(stEth_);
        lidoReferral = _lidoReferral;
        lidoReferralManager = _lidoReferralManager;

        IERC20(address(WETH)).forceApprove(address(borrowerOperations), type(uint256).max);
        collToken_.forceApprove(address(borrowerOperations), type(uint256).max);
        _underlyingToken.forceApprove(address(_collateralVault), type(uint256).max);
    }

    /// @notice Updates the protocol-designated Lido Rewards Share attribution address.
    /// @dev The immutable manager is expected to be the protocol Timelock. Zero disables attribution.
    function setLidoReferral(address _newReferral) external {
        if (msg.sender != lidoReferralManager) revert CollateralYieldZapper__UnauthorizedReferralManager();
        address oldReferral = lidoReferral;
        lidoReferral = _newReferral;
        emit LidoReferralUpdated(oldReferral, _newReferral);
    }

    receive() external payable {
        if (msg.sender != address(WETH)) revert CollateralYieldZapper__OnlyWETH();
    }

    /*//////////////////////////////////////////////////////////////
                    USER-FACING STATE-CHANGING FUNCTIONS
    //////////////////////////////////////////////////////////////*/

    function openTroveWithRawETH(OpenTroveParams calldata _params)
        external
        payable
        override
        nonReentrant
        returns (uint256 troveId)
    {
        troveId = _openTroveWithRawETHAndReferral(_params, bytes32(0));
    }

    function openTroveWithRawETHAndReferral(OpenTroveParams calldata _params, bytes32 _referralCode)
        external
        payable
        nonReentrant
        returns (uint256 troveId)
    {
        troveId = _openTroveWithRawETHAndReferral(_params, _referralCode);
    }

    function openTroveWithUnderlyingPermit(
        OpenTroveParams calldata _params,
        uint256 _deadline,
        uint8 _v,
        bytes32 _r,
        bytes32 _s
    ) external payable nonReentrant returns (uint256 troveId) {
        troveId = _openTroveWithUnderlyingPermitAndReferral(_params, _deadline, _v, _r, _s, bytes32(0));
    }

    function openTroveWithUnderlyingPermitAndReferral(
        OpenTroveParams calldata _params,
        uint256 _deadline,
        uint8 _v,
        bytes32 _r,
        bytes32 _s,
        bytes32 _referralCode
    ) external payable nonReentrant returns (uint256 troveId) {
        troveId = _openTroveWithUnderlyingPermitAndReferral(_params, _deadline, _v, _r, _s, _referralCode);
    }

    /// @notice Opens a trove from native ETH: stakes into Lido stETH, wraps to wstETH, deposits as collateral.
    /// @dev msg.value must be ETH_GAS_COMPENSATION + _params.collAmount (the ETH to stake).
    function openTroveWithNativeEth(OpenTroveParams calldata _params, uint256 _minWstEthOut)
        external
        payable
        nonReentrant
        returns (uint256 troveId)
    {
        troveId = _openTroveWithNativeEthAndReferral(_params, _minWstEthOut, bytes32(0));
    }

    function openTroveWithNativeEthAndReferral(
        OpenTroveParams calldata _params,
        uint256 _minWstEthOut,
        bytes32 _referralCode
    ) external payable nonReentrant returns (uint256 troveId) {
        troveId = _openTroveWithNativeEthAndReferral(_params, _minWstEthOut, _referralCode);
    }

    function addCollWithUnderlying(uint256 _troveId, uint256 _underlyingAmount)
        external
        nonReentrant
        returns (uint256 dTokenAmount)
    {
        address owner = troveNFT.ownerOf(_troveId);
        _requireSenderIsOwnerOrAddManager(_troveId, owner);

        dTokenAmount = _pullAndDepositUnderlying(_underlyingAmount);
        borrowerOperations.addColl(_troveId, dTokenAmount);
    }

    function withdrawCollToUnderlying(uint256 _troveId, uint256 _dTokenAmount)
        external
        nonReentrant
        returns (uint256 underlyingReceived, uint256 requestId)
    {
        (underlyingReceived, requestId) = _withdrawCollToUnderlying(_troveId, _dTokenAmount, 0);
    }

    function withdrawCollToUnderlyingWithMin(uint256 _troveId, uint256 _dTokenAmount, uint256 _minUnderlyingReceived)
        external
        nonReentrant
        returns (uint256 underlyingReceived, uint256 requestId)
    {
        (underlyingReceived, requestId) = _withdrawCollToUnderlying(_troveId, _dTokenAmount, _minUnderlyingReceived);
    }

    function _withdrawCollToUnderlying(uint256 _troveId, uint256 _dTokenAmount, uint256 _minUnderlyingReceived)
        internal
        returns (uint256 underlyingReceived, uint256 requestId)
    {
        address owner = troveNFT.ownerOf(_troveId);
        address receiver = _requireSenderIsOwnerOrRemoveManagerAndGetReceiver(_troveId, owner);
        _requireZapperIsReceiver(_troveId);

        borrowerOperations.withdrawColl(_troveId, _dTokenAmount);
        (underlyingReceived, requestId) = _redeemDTokenToUnderlying(_dTokenAmount, receiver, _minUnderlyingReceived);
    }

    function withdrawJpydf(uint256 _troveId, uint256 _jpydfAmount, uint256 _maxUpfrontFee) external nonReentrant {
        address owner = troveNFT.ownerOf(_troveId);
        address receiver = _requireSenderIsOwnerOrRemoveManagerAndGetReceiver(_troveId, owner);
        _requireZapperIsReceiver(_troveId);

        borrowerOperations.withdrawJpydf(_troveId, _jpydfAmount, _maxUpfrontFee);
        IERC20(address(jpydfToken)).safeTransfer(receiver, _jpydfAmount);
    }

    function repayJpydf(uint256 _troveId, uint256 _jpydfAmount) external nonReentrant {
        address owner = troveNFT.ownerOf(_troveId);
        _requireSenderIsOwnerOrAddManager(_troveId, owner);

        InitialBalances memory initialBalances;
        _setInitialTokensAndBalances(collToken, jpydfToken, initialBalances);

        IERC20(address(jpydfToken)).safeTransferFrom(msg.sender, address(this), _jpydfAmount);
        borrowerOperations.repayJpydf(_troveId, _jpydfAmount);

        _returnLeftovers(initialBalances);
    }

    function adjustTroveWithUnderlying(
        uint256 _troveId,
        uint256 _underlyingChange,
        bool _isCollIncrease,
        uint256 _jpydfChange,
        bool _isDebtIncrease,
        uint256 _maxUpfrontFee
    ) external nonReentrant returns (uint256 dTokenChange, uint256 underlyingReceived, uint256 requestId) {
        (dTokenChange, underlyingReceived, requestId) = _adjustTroveWithUnderlying(
            _troveId, _underlyingChange, _isCollIncrease, _jpydfChange, _isDebtIncrease, _maxUpfrontFee, 0
        );
    }

    function adjustTroveWithUnderlyingWithMin(
        uint256 _troveId,
        uint256 _underlyingChange,
        bool _isCollIncrease,
        uint256 _jpydfChange,
        bool _isDebtIncrease,
        uint256 _maxUpfrontFee,
        uint256 _minUnderlyingReceived
    ) external nonReentrant returns (uint256 dTokenChange, uint256 underlyingReceived, uint256 requestId) {
        (dTokenChange, underlyingReceived, requestId) = _adjustTroveWithUnderlying(
            _troveId,
            _underlyingChange,
            _isCollIncrease,
            _jpydfChange,
            _isDebtIncrease,
            _maxUpfrontFee,
            _minUnderlyingReceived
        );
    }

    function _adjustTroveWithUnderlying(
        uint256 _troveId,
        uint256 _underlyingChange,
        bool _isCollIncrease,
        uint256 _jpydfChange,
        bool _isDebtIncrease,
        uint256 _maxUpfrontFee,
        uint256 _minUnderlyingReceived
    ) internal returns (uint256 dTokenChange, uint256 underlyingReceived, uint256 requestId) {
        InitialBalances memory initialBalances;
        address receiver = _adjustTroveWithUnderlyingPre(
            _troveId, _underlyingChange, _isCollIncrease, _jpydfChange, _isDebtIncrease, initialBalances
        );

        if (_underlyingChange > 0) {
            if (_isCollIncrease) {
                dTokenChange = _pullAndDepositUnderlying(_underlyingChange);
            } else {
                dTokenChange = dToken.convertToDToken(_underlyingChange);
            }
        }

        borrowerOperations.adjustTrove(
            _troveId, dTokenChange, _isCollIncrease, _jpydfChange, _isDebtIncrease, _maxUpfrontFee
        );

        (underlyingReceived, requestId) = _adjustTroveWithUnderlyingPost(
            dTokenChange,
            _isCollIncrease,
            _jpydfChange,
            _isDebtIncrease,
            receiver,
            initialBalances,
            _minUnderlyingReceived
        );
    }

    function adjustZombieTroveWithUnderlying(
        uint256 _troveId,
        uint256 _underlyingChange,
        bool _isCollIncrease,
        uint256 _jpydfChange,
        bool _isDebtIncrease,
        uint256 _upperHint,
        uint256 _lowerHint,
        uint256 _maxUpfrontFee
    ) external nonReentrant returns (uint256 dTokenChange, uint256 underlyingReceived, uint256 requestId) {
        (dTokenChange, underlyingReceived, requestId) = _adjustZombieTroveWithUnderlying(
            _troveId,
            _underlyingChange,
            _isCollIncrease,
            _jpydfChange,
            _isDebtIncrease,
            _upperHint,
            _lowerHint,
            _maxUpfrontFee,
            0
        );
    }

    function adjustZombieTroveWithUnderlyingWithMin(
        uint256 _troveId,
        uint256 _underlyingChange,
        bool _isCollIncrease,
        uint256 _jpydfChange,
        bool _isDebtIncrease,
        uint256 _upperHint,
        uint256 _lowerHint,
        uint256 _maxUpfrontFee,
        uint256 _minUnderlyingReceived
    ) external nonReentrant returns (uint256 dTokenChange, uint256 underlyingReceived, uint256 requestId) {
        (dTokenChange, underlyingReceived, requestId) = _adjustZombieTroveWithUnderlying(
            _troveId,
            _underlyingChange,
            _isCollIncrease,
            _jpydfChange,
            _isDebtIncrease,
            _upperHint,
            _lowerHint,
            _maxUpfrontFee,
            _minUnderlyingReceived
        );
    }

    function _adjustZombieTroveWithUnderlying(
        uint256 _troveId,
        uint256 _underlyingChange,
        bool _isCollIncrease,
        uint256 _jpydfChange,
        bool _isDebtIncrease,
        uint256 _upperHint,
        uint256 _lowerHint,
        uint256 _maxUpfrontFee,
        uint256 _minUnderlyingReceived
    ) internal returns (uint256 dTokenChange, uint256 underlyingReceived, uint256 requestId) {
        InitialBalances memory initialBalances;
        address receiver = _adjustTroveWithUnderlyingPre(
            _troveId, _underlyingChange, _isCollIncrease, _jpydfChange, _isDebtIncrease, initialBalances
        );

        if (_underlyingChange > 0) {
            if (_isCollIncrease) {
                dTokenChange = _pullAndDepositUnderlying(_underlyingChange);
            } else {
                dTokenChange = dToken.convertToDToken(_underlyingChange);
            }
        }

        borrowerOperations.adjustZombieTrove(
            _troveId,
            dTokenChange,
            _isCollIncrease,
            _jpydfChange,
            _isDebtIncrease,
            _upperHint,
            _lowerHint,
            _maxUpfrontFee
        );

        (underlyingReceived, requestId) = _adjustTroveWithUnderlyingPost(
            dTokenChange,
            _isCollIncrease,
            _jpydfChange,
            _isDebtIncrease,
            receiver,
            initialBalances,
            _minUnderlyingReceived
        );
    }

    function closeTroveToUnderlying(uint256 _troveId)
        external
        nonReentrant
        returns (uint256 underlyingReceived, uint256 requestId)
    {
        (underlyingReceived, requestId) = _closeTroveToUnderlying(_troveId, 0);
    }

    function closeTroveToUnderlyingWithMin(uint256 _troveId, uint256 _minUnderlyingReceived)
        external
        nonReentrant
        returns (uint256 underlyingReceived, uint256 requestId)
    {
        (underlyingReceived, requestId) = _closeTroveToUnderlying(_troveId, _minUnderlyingReceived);
    }

    function _closeTroveToUnderlying(uint256 _troveId, uint256 _minUnderlyingReceived)
        internal
        returns (uint256 underlyingReceived, uint256 requestId)
    {
        address owner = troveNFT.ownerOf(_troveId);
        address payable receiver = payable(_requireSenderIsOwnerOrRemoveManagerAndGetReceiver(_troveId, owner));
        _requireZapperIsReceiver(_troveId);

        LatestTroveData memory trove = troveManager.getLatestTroveData(_troveId);
        IERC20(address(jpydfToken)).safeTransferFrom(msg.sender, address(this), trove.entireDebt);

        borrowerOperations.closeTrove(_troveId);

        (underlyingReceived, requestId) = _redeemDTokenToUnderlying(trove.entireColl, receiver, _minUnderlyingReceived);
        _sendGasCompensation(receiver);
    }

    /*//////////////////////////////////////////////////////////////
                   INTERNAL STATE-CHANGING FUNCTIONS
    //////////////////////////////////////////////////////////////*/

    function _openTroveWithUnderlyingPermitAndReferral(
        OpenTroveParams calldata _params,
        uint256 _deadline,
        uint8 _v,
        bytes32 _r,
        bytes32 _s,
        bytes32 _referralCode
    ) internal returns (uint256 troveId) {
        _permitOrRequireAllowance(_params.collAmount, _deadline, _v, _r, _s);

        troveId = _openTroveWithRawETHAndReferral(_params, _referralCode);
    }

    function _permitOrRequireAllowance(uint256 _amount, uint256 _deadline, uint8 _v, bytes32 _r, bytes32 _s) internal {
        try IERC20Permit(address(underlyingToken)).permit(msg.sender, address(this), _amount, _deadline, _v, _r, _s) {}
        catch {
            if (underlyingToken.allowance(msg.sender, address(this)) < _amount) {
                revert CollateralYieldZapper__PermitFailed();
            }
        }
    }

    function _openTroveWithRawETHAndReferral(OpenTroveParams calldata _params, bytes32 _referralCode)
        internal
        returns (uint256 troveId)
    {
        if (msg.value != ETH_GAS_COMPENSATION) revert CollateralYieldZapper__WrongETH();
        _requireOpenOwnerIsSender(_params.owner);
        _requireValidOpenBatchParams(_params);

        WETH.deposit{value: msg.value}();

        uint256 dTokenAmount = _pullAndDepositUnderlying(_params.collAmount);
        troveId = _openTroveWithDTokenCollateral(_params, dTokenAmount);

        if (_referralCode != bytes32(0)) {
            emit ReferralDeposit(
                msg.sender, troveId, _params.collAmount, dTokenAmount, _params.jpydfAmount, _referralCode
            );
        }
    }

    function _openTroveWithDTokenCollateral(OpenTroveParams calldata _params, uint256 _dTokenAmount)
        internal
        returns (uint256 troveId)
    {
        uint256 index = _getTroveIndex(_params.ownerIndex);

        if (_params.batchManager == address(0)) {
            troveId = borrowerOperations.openTrove(
                _params.owner,
                index,
                _dTokenAmount,
                _params.jpydfAmount,
                _params.upperHint,
                _params.lowerHint,
                _params.annualInterestRate,
                _params.maxUpfrontFee,
                address(this),
                address(this),
                address(this)
            );
        } else {
            IBorrowerOperations.OpenTroveAndJoinInterestBatchManagerParams memory openParams =
                IBorrowerOperations.OpenTroveAndJoinInterestBatchManagerParams({
                    owner: _params.owner,
                    ownerIndex: index,
                    collAmount: _dTokenAmount,
                    jpydfAmount: _params.jpydfAmount,
                    upperHint: _params.upperHint,
                    lowerHint: _params.lowerHint,
                    interestBatchManager: _params.batchManager,
                    maxUpfrontFee: _params.maxUpfrontFee,
                    addManager: address(this),
                    removeManager: address(this),
                    receiver: address(this)
                });
            troveId = borrowerOperations.openTroveAndJoinInterestBatchManager(openParams);
        }

        IERC20(address(jpydfToken)).safeTransfer(msg.sender, _params.jpydfAmount);
        _setAddManager(troveId, _params.addManager);
        _setRemoveManagerAndReceiver(troveId, _params.removeManager, _params.receiver);
    }

    function _openTroveWithNativeEthAndReferral(
        OpenTroveParams calldata _params,
        uint256 _minWstEthOut,
        bytes32 _referralCode
    ) internal returns (uint256 troveId) {
        if (address(stEthToken) == address(0)) {
            revert CollateralYieldZapper__NativeEthRouteUnavailable();
        }
        if (_params.collAmount == 0 || msg.value != ETH_GAS_COMPENSATION + _params.collAmount) {
            revert CollateralYieldZapper__WrongETH();
        }
        _requireOpenOwnerIsSender(_params.owner);
        _requireValidOpenBatchParams(_params);

        WETH.deposit{value: ETH_GAS_COMPENSATION}();

        (uint256 stEthAmount, uint256 wstEthAmount) = _stakeNativeEthToWstEth(_params.collAmount, _minWstEthOut);
        uint256 dTokenAmount = collateralVault.deposit(wstEthAmount);
        troveId = _openTroveWithDTokenCollateral(_params, dTokenAmount);

        if (_referralCode != bytes32(0)) {
            // Referral accounting is denominated in the branch underlying (wstETH), matching the ERC20 path.
            emit ReferralDeposit(msg.sender, troveId, wstEthAmount, dTokenAmount, _params.jpydfAmount, _referralCode);
        }
        emit NativeEthRouteDeposit(
            msg.sender, troveId, _params.collAmount, stEthAmount, wstEthAmount, dTokenAmount, _referralCode
        );
    }

    function _stakeNativeEthToWstEth(uint256 _ethAmount, uint256 _minWstEthOut)
        internal
        returns (uint256 stEthAmount, uint256 wstEthAmount)
    {
        IERC20 stEthCached = stEthToken;
        IERC20 wstEth = underlyingToken;

        uint256 stEthBalanceBefore = stEthCached.balanceOf(address(this));
        try IStETHSubmit(address(stEthCached)).submit{value: _ethAmount}(lidoReferral) {}
        catch (bytes memory reason) {
            revert CollateralYieldZapper__StEthSubmitFailed(reason);
        }
        stEthAmount = stEthCached.balanceOf(address(this)) - stEthBalanceBefore;

        uint256 wstEthBalanceBefore = wstEth.balanceOf(address(this));
        stEthCached.forceApprove(address(wstEth), stEthAmount);
        IWstETHWrap(address(wstEth)).wrap(stEthAmount);
        stEthCached.forceApprove(address(wstEth), 0);
        wstEthAmount = wstEth.balanceOf(address(this)) - wstEthBalanceBefore;

        if (wstEthAmount < _minWstEthOut || wstEthAmount == 0) {
            revert CollateralYieldZapper__InsufficientWstEthOut(wstEthAmount, _minWstEthOut);
        }

        // Lido stETH share rounding can leave 1-2 wei of stETH behind after wrap; sweep it to the caller.
        uint256 stEthBalanceAfter = stEthCached.balanceOf(address(this));
        if (stEthBalanceAfter > stEthBalanceBefore) {
            stEthCached.safeTransfer(msg.sender, stEthBalanceAfter - stEthBalanceBefore);
        }
    }

    function _pullAndDepositUnderlying(uint256 _underlyingAmount) internal returns (uint256 dTokenAmount) {
        uint256 balanceBefore = underlyingToken.balanceOf(address(this));
        underlyingToken.safeTransferFrom(msg.sender, address(this), _underlyingAmount);
        uint256 received = underlyingToken.balanceOf(address(this)) - balanceBefore;

        dTokenAmount = collateralVault.deposit(received);
    }

    function _adjustTroveWithUnderlyingPre(
        uint256 _troveId,
        uint256 _underlyingChange,
        bool _isCollIncrease,
        uint256 _jpydfChange,
        bool _isDebtIncrease,
        InitialBalances memory _initialBalances
    ) internal returns (address receiver) {
        receiver = _checkAdjustTroveManagers(_troveId, _underlyingChange, _isCollIncrease, _isDebtIncrease);

        _setInitialTokensAndBalances(collToken, jpydfToken, _initialBalances);

        if (!_isDebtIncrease && _jpydfChange > 0) {
            IERC20(address(jpydfToken)).safeTransferFrom(msg.sender, address(this), _jpydfChange);
        }
    }

    function _adjustTroveWithUnderlyingPost(
        uint256 _dTokenChange,
        bool _isCollIncrease,
        uint256 _jpydfChange,
        bool _isDebtIncrease,
        address _receiver,
        InitialBalances memory _initialBalances,
        uint256 _minUnderlyingReceived
    ) internal returns (uint256 underlyingReceived, uint256 requestId) {
        if (!_isCollIncrease && _dTokenChange > 0) {
            (underlyingReceived, requestId) =
                _redeemDTokenToUnderlying(_dTokenChange, _receiver, _minUnderlyingReceived);
        }

        if (_isDebtIncrease && _jpydfChange > 0) {
            IERC20(address(jpydfToken)).safeTransfer(_receiver, _jpydfChange);
        }

        _returnLeftovers(_initialBalances);
    }

    function _redeemDTokenToUnderlying(uint256 _dTokenAmount, address _receiver, uint256 _minUnderlyingReceived)
        internal
        returns (uint256 underlyingReceived, uint256 requestId)
    {
        uint256 redeemableDTokenAmount = dToken.convertToDToken(dToken.convertToUnderlying(_dTokenAmount));
        uint256 dTokenDust = _dTokenAmount - redeemableDTokenAmount;

        if (redeemableDTokenAmount > 0) {
            (underlyingReceived, requestId) = collateralVault.redeem(redeemableDTokenAmount, _receiver);
        }
        if (underlyingReceived < _minUnderlyingReceived) {
            revert CollateralYieldZapper__InsufficientUnderlyingReceived(underlyingReceived, _minUnderlyingReceived);
        }

        if (dTokenDust > 0) {
            collToken.safeTransfer(_receiver, dTokenDust);
        }
    }

    function _sendGasCompensation(address payable _receiver) internal {
        WETH.withdraw(ETH_GAS_COMPENSATION);
        SafeTransferLib.safeTransferETH(_receiver, ETH_GAS_COMPENSATION);
    }

    /*//////////////////////////////////////////////////////////////
                      INTERNAL READ-ONLY FUNCTIONS
    //////////////////////////////////////////////////////////////*/

    function _requireValidOpenBatchParams(OpenTroveParams calldata _params) internal pure {
        if (_params.batchManager != address(0) && _params.annualInterestRate != 0) {
            revert CollateralYieldZapper__CannotChooseInterestIfJoiningBatch();
        }
    }

    function _requireOpenOwnerIsSender(address _owner) internal view {
        if (_owner != msg.sender) {
            revert CollateralYieldZapper__OwnerMismatch(_owner, msg.sender);
        }
    }
}
