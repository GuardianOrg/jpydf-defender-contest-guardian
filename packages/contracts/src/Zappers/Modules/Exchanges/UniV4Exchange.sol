// SPDX-License-Identifier: MIT

pragma solidity 0.8.24;

import {IERC20} from "openzeppelin-contracts/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "openzeppelin-contracts/contracts/token/ERC20/utils/SafeERC20.sol";
import {ReentrancyGuard} from "openzeppelin-contracts/contracts/security/ReentrancyGuard.sol";

import {IJpydfToken} from "src/Interfaces/IJpydfToken.sol";
import {IExchange} from "src/Zappers/Interfaces/IExchange.sol";
import {LeftoversSweep} from "src/Zappers/LeftoversSweep.sol";
import {Currency, IHooks, IV4Router, PoolKey} from "src/Zappers/Modules/Exchanges/UniswapV4/IV4Router.sol";
import {IPermit2} from "src/Zappers/Modules/Exchanges/UniswapV4/IPermit2.sol";
import {IUniversalRouter} from "src/Zappers/Modules/Exchanges/UniswapV4/IUniversalRouter.sol";
import {V4RouterCodec} from "src/Zappers/Modules/Exchanges/UniswapV4/V4RouterCodec.sol";

/**
 * @title UniV4Exchange
 * @notice IExchange adapter for a single hook-configured Uniswap v4 pool through Universal Router.
 * @custom:security-contact security@deltaforesight.xyz
 */
contract UniV4Exchange is LeftoversSweep, IExchange, ReentrancyGuard {
    using SafeERC20 for IERC20;

    uint256 private constant ROUTER_DEADLINE_SECONDS = 20;
    uint256 private constant PERMIT2_EXPIRATION_SECONDS = 60;

    IERC20 public immutable collToken;
    IJpydfToken public immutable jpydfToken;
    IUniversalRouter public immutable universalRouter;
    IPermit2 public immutable permit2;
    address public immutable currency0;
    address public immutable currency1;
    uint24 public immutable fee;
    int24 public immutable tickSpacing;
    IHooks public immutable hooks;

    error UniV4Exchange__ZeroAddress();
    error UniV4Exchange__NotContract(address target);
    error UniV4Exchange__IdenticalTokens();
    error UniV4Exchange__AmountTooLarge(uint256 amount);
    error UniV4Exchange__InsufficientOutput(uint256 actual, uint256 minimum);

    constructor(
        IERC20 _collToken,
        IJpydfToken _jpydfToken,
        uint24 _fee,
        int24 _tickSpacing,
        IHooks _hooks,
        IUniversalRouter _universalRouter,
        IPermit2 _permit2
    ) {
        if (
            address(_collToken) == address(0) || address(_jpydfToken) == address(0)
                || address(_universalRouter) == address(0) || address(_permit2) == address(0)
        ) {
            revert UniV4Exchange__ZeroAddress();
        }
        if (address(_collToken) == address(_jpydfToken)) revert UniV4Exchange__IdenticalTokens();
        if (address(_collToken).code.length == 0) revert UniV4Exchange__NotContract(address(_collToken));
        if (address(_jpydfToken).code.length == 0) revert UniV4Exchange__NotContract(address(_jpydfToken));
        if (address(_universalRouter).code.length == 0) {
            revert UniV4Exchange__NotContract(address(_universalRouter));
        }
        if (address(_permit2).code.length == 0) revert UniV4Exchange__NotContract(address(_permit2));

        collToken = _collToken;
        jpydfToken = _jpydfToken;
        fee = _fee;
        tickSpacing = _tickSpacing;
        hooks = _hooks;
        universalRouter = _universalRouter;
        permit2 = _permit2;

        (currency0, currency1) = address(_collToken) < address(_jpydfToken)
            ? (address(_collToken), address(_jpydfToken))
            : (address(_jpydfToken), address(_collToken));
    }

    /*//////////////////////////////////////////////////////////////
                    USER-FACING STATE-CHANGING FUNCTIONS
    //////////////////////////////////////////////////////////////*/

    function swapFromJpydf(uint256 _jpydfAmount, uint256 _minCollAmount) external nonReentrant {
        InitialBalances memory initialBalances;
        _setInitialTokensAndBalances(collToken, jpydfToken, initialBalances);

        IERC20 jpydfTokenCached = IERC20(address(jpydfToken));
        jpydfTokenCached.safeTransferFrom(msg.sender, address(this), _jpydfAmount);
        _approvePermit2(jpydfTokenCached, _jpydfAmount);

        _executeExactOutputSingle(
            address(jpydfToken), address(collToken), _jpydfAmount, _minCollAmount, _zeroForOne(address(jpydfToken))
        );
        _clearPermit2(jpydfTokenCached);

        uint256 collOutput = _balanceIncrease(collToken.balanceOf(address(this)), initialBalances.balances[0]);
        if (collOutput < _minCollAmount) revert UniV4Exchange__InsufficientOutput(collOutput, _minCollAmount);

        _returnLeftovers(initialBalances);
    }

    function swapToJpydf(uint256 _collAmount, uint256 _minJpydfAmount)
        external
        nonReentrant
        returns (uint256 amountOut)
    {
        InitialBalances memory initialBalances;
        _setInitialTokensAndBalances(collToken, jpydfToken, initialBalances);

        collToken.safeTransferFrom(msg.sender, address(this), _collAmount);
        _approvePermit2(collToken, _collAmount);

        _executeExactInputSingle(
            address(collToken), address(jpydfToken), _collAmount, _minJpydfAmount, _zeroForOne(address(collToken))
        );
        _clearPermit2(collToken);

        amountOut = _balanceIncrease(IERC20(address(jpydfToken)).balanceOf(address(this)), initialBalances.balances[1]);
        if (amountOut < _minJpydfAmount) revert UniV4Exchange__InsufficientOutput(amountOut, _minJpydfAmount);

        _returnLeftovers(initialBalances);
    }

    /*//////////////////////////////////////////////////////////////
                   INTERNAL STATE-CHANGING FUNCTIONS
    //////////////////////////////////////////////////////////////*/

    function _executeExactInputSingle(
        address _currencyIn,
        address _currencyOut,
        uint256 _amountIn,
        uint256 _amountOutMinimum,
        bool _isZeroForOne
    ) internal {
        bytes[] memory params = new bytes[](3);
        params[0] = abi.encode(
            IV4Router.ExactInputSingleParams({
                poolKey: _poolKey(),
                zeroForOne: _isZeroForOne,
                amountIn: _toUint128(_amountIn),
                amountOutMinimum: _toUint128(_amountOutMinimum),
                minHopPriceX36: 0,
                hookData: bytes("")
            })
        );
        params[1] = abi.encode(Currency.wrap(_currencyIn), _amountIn);
        params[2] = abi.encode(Currency.wrap(_currencyOut), _amountOutMinimum);

        _executeV4Swap(
            abi.encodePacked(V4RouterCodec.SWAP_EXACT_IN_SINGLE, V4RouterCodec.SETTLE_ALL, V4RouterCodec.TAKE_ALL),
            params
        );
    }

    function _executeExactOutputSingle(
        address _currencyIn,
        address _currencyOut,
        uint256 _amountInMaximum,
        uint256 _amountOut,
        bool _isZeroForOne
    ) internal {
        bytes[] memory params = new bytes[](3);
        params[0] = abi.encode(
            IV4Router.ExactOutputSingleParams({
                poolKey: _poolKey(),
                zeroForOne: _isZeroForOne,
                amountOut: _toUint128(_amountOut),
                amountInMaximum: _toUint128(_amountInMaximum),
                minHopPriceX36: 0,
                hookData: bytes("")
            })
        );
        params[1] = abi.encode(Currency.wrap(_currencyIn), _amountInMaximum);
        params[2] = abi.encode(Currency.wrap(_currencyOut), _amountOut);

        _executeV4Swap(
            abi.encodePacked(V4RouterCodec.SWAP_EXACT_OUT_SINGLE, V4RouterCodec.SETTLE_ALL, V4RouterCodec.TAKE_ALL),
            params
        );
    }

    function _executeV4Swap(bytes memory _actions, bytes[] memory _params) internal {
        bytes[] memory inputs = new bytes[](1);
        inputs[0] = abi.encode(_actions, _params);

        universalRouter.execute(
            abi.encodePacked(V4RouterCodec.V4_SWAP), inputs, block.timestamp + ROUTER_DEADLINE_SECONDS
        );
    }

    function _approvePermit2(IERC20 _token, uint256 _amount) internal {
        _token.forceApprove(address(permit2), _amount);
        permit2.approve(
            address(_token),
            address(universalRouter),
            _toUint160(_amount),
            uint48(block.timestamp + PERMIT2_EXPIRATION_SECONDS)
        );
    }

    function _clearPermit2(IERC20 _token) internal {
        permit2.approve(address(_token), address(universalRouter), 0, 0);
        _token.forceApprove(address(permit2), 0);
    }

    /*//////////////////////////////////////////////////////////////
                         INTERNAL READ-ONLY FUNCTIONS
    //////////////////////////////////////////////////////////////*/

    function _poolKey() internal view returns (PoolKey memory) {
        return PoolKey({
            currency0: Currency.wrap(currency0),
            currency1: Currency.wrap(currency1),
            fee: fee,
            tickSpacing: tickSpacing,
            hooks: hooks
        });
    }

    function _zeroForOne(address _tokenIn) internal view returns (bool) {
        return _tokenIn == currency0;
    }

    function _toUint128(uint256 _amount) internal pure returns (uint128) {
        if (_amount > type(uint128).max) revert UniV4Exchange__AmountTooLarge(_amount);
        return uint128(_amount);
    }

    function _toUint160(uint256 _amount) internal pure returns (uint160) {
        if (_amount > type(uint160).max) revert UniV4Exchange__AmountTooLarge(_amount);
        return uint160(_amount);
    }

    function _balanceIncrease(uint256 _currentBalance, uint256 _initialBalance) internal pure returns (uint256) {
        if (_currentBalance <= _initialBalance) return 0;
        return _currentBalance - _initialBalance;
    }
}
