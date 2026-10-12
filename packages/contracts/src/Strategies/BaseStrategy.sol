// SPDX-License-Identifier: MIT

pragma solidity 0.8.24;

import "openzeppelin-contracts/contracts/token/ERC20/IERC20.sol";
import "openzeppelin-contracts/contracts/token/ERC20/utils/SafeERC20.sol";
import "openzeppelin-contracts/contracts/access/IAccessControl.sol";
import "openzeppelin-contracts-upgradeable/access/OwnableUpgradeable.sol";
import "openzeppelin-contracts-upgradeable/proxy/utils/Initializable.sol";
import "openzeppelin-contracts-upgradeable/proxy/utils/UUPSUpgradeable.sol";

import "../Interfaces/IStrategy.sol";
import "../Interfaces/ICollateralVault.sol";

interface IMerklDistributor {
    function claim(
        address[] calldata users,
        address[] calldata tokens,
        uint256[] calldata amounts,
        bytes32[][] calldata proofs
    ) external;
}

/**
 * @title BaseStrategy - Push-model Strategy base contract (Upgradeable)
 * @notice Implements the push model for all derived strategies.
 *
 *   - `deposit(declared, received)`: onlyVault. Underlying is transferred BEFORE this call.
 *                                  Runs `_doDeposit(received)` in an isolated self-call; on
 *                                  rejection, returns the exact receipt to the Vault or reverts.
 *   - `sendToVault(amount)`     : WITHDRAWER_ROLE on Vault.
 *                                  Withdraws from the upstream protocol via `_doWithdraw`,
 *                                  reduces `principal` (principal-first), pushes the result
 *                                  to the Vault via `receiveFromStrategy`.
 *   - `sendProfitToVault()`     : HARVESTER_ROLE on Vault.
 *                                  Caps the amount at `realizedYield()`, withdraws via
 *                                  `_doWithdraw`, leaves `principal` unchanged, pushes
 *                                  the result directly to the Vault buffer.
 *   - `writeoffPrincipal(amt)`  : onlyVault. Acknowledges a permanent loss so the Strategy
 *                                  can later be removed. Returns the clamped amount written off.
 *
 *   Derived contracts only implement three hooks:
 *     `_doDeposit(amount)`
 *     `_doWithdraw(amount) -> actual`
 *     `_estimatedTotalUnderlying() view -> uint256`
 */
abstract contract BaseStrategy is Initializable, IStrategy, OwnableUpgradeable, UUPSUpgradeable {
    using SafeERC20 for IERC20;

    // =============================================================
    //                          STATE
    // =============================================================

    /// @notice Vault address managing this Strategy
    address public vault;

    /// @notice Underlying token under management
    IERC20 public underlyingToken;

    /// @notice Principal currently tracked by this Strategy
    /// @dev    Increased on `deposit`, decreased on `sendToVault` and `writeoffPrincipal`.
    ///         `sendProfitToVault` does not change this.
    uint256 internal _principal;

    /// @notice Pending owner for two-step ownership transfer
    address private _pendingOwner;

    /// @notice Address authorized to upgrade this Strategy implementation.
    address public upgrader;

    /// @dev Local reentrancy guard for Strategy entry points that call external protocols or tokens.
    uint256 private _reentrancyStatus;

    /// @dev Storage gap for future upgrades.
    uint256[46] private __gap;

    // =============================================================
    //                          CONSTANTS
    // =============================================================

    /// @dev Legacy role retained only for archived async strategy request functions.
    bytes32 internal constant _ALLOCATOR_ROLE = keccak256("ALLOCATOR_ROLE");
    /// @dev Must match the operation-specific roles on CollateralVault.
    bytes32 internal constant _WITHDRAWER_ROLE = keccak256("WITHDRAWER_ROLE");
    bytes32 internal constant _HARVESTER_ROLE = keccak256("HARVESTER_ROLE");
    uint256 public constant MAX_MERKL_TOKENS_PER_CLAIM = 16;

    // =============================================================
    //                          EVENTS
    // =============================================================

    event Deposited(uint256 amount, uint256 newPrincipal);
    event SentToVault(address indexed caller, uint256 requested, uint256 actual, uint256 newPrincipal);
    event ProfitSentToVault(address indexed caller, uint256 yield, uint256 actual);
    event PrincipalWrittenOff(uint256 amount, uint256 newPrincipal);
    event PrincipalReturned(uint256 amount, uint256 newPrincipal);
    event EmergencyWithdrawn(uint256 amount);
    event RewardTokenSwept(address indexed token, address indexed treasury, uint256 requested, uint256 received);
    event MerklRewardsClaimed(
        address indexed distributor, address indexed token, uint256 cumulativeAmount, uint256 swept
    );
    event MerklUnderlyingRewardsClaimed(
        address indexed distributor, address indexed token, uint256 cumulativeAmount, uint256 sentToVault
    );
    event OwnershipTransferStarted(address indexed previousOwner, address indexed newOwner);
    event UpgraderUpdated(address indexed oldUpgrader, address indexed newUpgrader);

    // =============================================================
    //                          ERRORS
    // =============================================================

    error OnlyVault();
    error Unauthorized();
    error ZeroAddress();
    error NotContract(address target);
    error ReentrantCall();
    error CannotSweepProtectedToken();
    error RenounceOwnershipDisabled();
    error InvalidMerklDistributor();
    error InvalidMerklClaim();
    error DuplicateMerklToken(address token);
    error TooManyMerklTokens(uint256 tokenCount, uint256 maxTokenCount);
    error DepositRecoveryFailed();

    // =============================================================
    //                        MODIFIERS
    // =============================================================

    modifier onlyVault() {
        if (msg.sender != vault) revert OnlyVault();
        _;
    }

    modifier onlyVaultRole(bytes32 role) {
        if (!IAccessControl(vault).hasRole(role, msg.sender)) revert Unauthorized();
        _;
    }

    modifier nonReentrantStrategy() {
        if (_reentrancyStatus == 1) revert ReentrantCall();
        _reentrancyStatus = 1;
        _;
        _reentrancyStatus = 0;
    }

    // =============================================================
    //                       CONSTRUCTOR
    // =============================================================

    /// @custom:oz-upgrades-unsafe-allow constructor
    constructor() {
        _disableInitializers();
    }

    // =============================================================
    //                      INITIALIZER
    // =============================================================

    /**
     * @notice BaseStrategy initialization function
     * @param _vault Vault address managing this Strategy
     * @param _underlying Underlying token under management
     * @param _owner Strategy manager (for emergency operations)
     * @param _upgrader Strategy upgrade authority
     */
    function __BaseStrategy_init(address _vault, IERC20 _underlying, address _owner, address _upgrader)
        internal
        onlyInitializing
    {
        __Ownable_init();
        __UUPSUpgradeable_init();

        if (_vault == address(0)) revert ZeroAddress();
        if (address(_underlying) == address(0)) revert ZeroAddress();
        if (_owner == address(0)) revert ZeroAddress();
        if (_upgrader == address(0)) revert ZeroAddress();
        if (_vault.code.length == 0) revert NotContract(_vault);
        if (address(_underlying).code.length == 0) revert NotContract(address(_underlying));

        vault = _vault;
        underlyingToken = _underlying;
        upgrader = _upgrader;
        _transferOwnership(_owner);

        // Pre-approve Vault so `receiveFromStrategy` can pull underlying via
        // `safeTransferFrom`. The Vault is a trusted contract (UUPS, GOV-controlled).
        _underlying.forceApprove(_vault, type(uint256).max);
    }

    // =============================================================
    //                    UUPS UPGRADE
    // =============================================================

    function _authorizeUpgrade(address) internal view override {
        if (msg.sender != upgrader) revert Unauthorized();
    }

    function setUpgrader(address _newUpgrader) external {
        if (msg.sender != upgrader) revert Unauthorized();
        if (_newUpgrader == address(0)) revert ZeroAddress();

        address oldUpgrader = upgrader;
        upgrader = _newUpgrader;
        emit UpgraderUpdated(oldUpgrader, _newUpgrader);
    }

    // =============================================================
    //                    OWNERSHIP OVERRIDES
    // =============================================================

    /**
     * @notice Pending owner for two-step ownership transfer.
     */
    function pendingOwner() public view returns (address) {
        return _pendingOwner;
    }

    /**
     * @notice Start a two-step ownership transfer.
     * @dev Passing address(0) cancels an existing pending transfer, matching
     *      OpenZeppelin Ownable2Step behavior.
     */
    function transferOwnership(address newOwner) public override onlyOwner {
        _pendingOwner = newOwner;
        emit OwnershipTransferStarted(owner(), newOwner);
    }

    /**
     * @notice Accept a pending ownership transfer.
     */
    function acceptOwnership() public {
        require(_pendingOwner == _msgSender(), "Ownable2Step: caller is not the new owner");
        _transferOwnership(_msgSender());
    }

    /**
     * @notice Disable ownership renounce to preserve emergency, reward-sweep,
     *         and upgrade controls.
     */
    function renounceOwnership() public view override onlyOwner {
        revert RenounceOwnershipDisabled();
    }

    function _transferOwnership(address newOwner) internal override {
        delete _pendingOwner;
        super._transferOwnership(newOwner);
    }

    // =============================================================
    //                    IStrategy VIEW FUNCTIONS
    // =============================================================

    /// @inheritdoc IStrategy
    function underlying() external view override returns (address) {
        return address(underlyingToken);
    }

    /// @inheritdoc IStrategy
    function principal() external view override returns (uint256) {
        return _principal;
    }

    /// @inheritdoc IStrategy
    function realizedYield() public view override returns (uint256) {
        uint256 total = _estimatedTotalUnderlying();
        return total > _principal ? total - _principal : 0;
    }

    /// @inheritdoc IStrategy
    function estimatedTotalUnderlying() external view override returns (uint256) {
        return _estimatedTotalUnderlying();
    }

    // =============================================================
    //                    IStrategy MUTATING FUNCTIONS
    // =============================================================

    /// @inheritdoc IStrategy
    function deposit(uint256 _declaredAmount, uint256 _receivedAmount)
        external
        override
        onlyVault
        nonReentrantStrategy
        returns (uint256 deposited)
    {
        if (_receivedAmount == 0) {
            if (_declaredAmount != 0) revert DepositRecoveryFailed();
            return 0;
        }

        try this.deployUnderlying(_receivedAmount) {
            _principal += _receivedAmount;
            emit Deposited(_receivedAmount, _principal);
            return _receivedAmount;
        } catch {
            if (_declaredAmount != _receivedAmount) revert DepositRecoveryFailed();
            uint256 vaultBalanceBeforeRecovery = underlyingToken.balanceOf(vault);
            uint256 strategyBalanceBeforeRecovery = underlyingToken.balanceOf(address(this));
            (bool transferSucceeded, bytes memory transferReturnData) =
                address(underlyingToken).call(abi.encodeCall(IERC20.transfer, (vault, _receivedAmount)));
            if (
                !transferSucceeded
                    || (transferReturnData.length != 0
                        && (transferReturnData.length < 32 || !abi.decode(transferReturnData, (bool))))
            ) {
                revert DepositRecoveryFailed();
            }
            uint256 vaultBalanceAfterRecovery = underlyingToken.balanceOf(vault);
            uint256 strategyBalanceAfterRecovery = underlyingToken.balanceOf(address(this));
            if (
                vaultBalanceAfterRecovery < vaultBalanceBeforeRecovery
                    || strategyBalanceAfterRecovery > strategyBalanceBeforeRecovery
                    || vaultBalanceAfterRecovery - vaultBalanceBeforeRecovery != _receivedAmount
                    || strategyBalanceBeforeRecovery - strategyBalanceAfterRecovery != _receivedAmount
            ) {
                revert DepositRecoveryFailed();
            }
            return 0;
        }
    }

    /// @notice Execute the protocol-specific deposit in an isolated call frame.
    /// @dev Self-only so an upstream revert rolls back its effects while the
    ///      outer `deposit` frame can return the idle Underlying to the Vault.
    function deployUnderlying(uint256 _amount) external {
        if (msg.sender != address(this)) revert Unauthorized();
        _doDeposit(_amount);
    }

    /// @inheritdoc IStrategy
    function sendToVault(uint256 _amount)
        external
        override
        nonReentrantStrategy
        onlyVaultRole(_WITHDRAWER_ROLE)
        returns (uint256 sent)
    {
        if (_amount == 0) return 0;

        uint256 withdrawnUnderlying = _doWithdraw(_amount);
        if (withdrawnUnderlying == 0) {
            emit SentToVault(msg.sender, _amount, 0, _principal);
            return 0;
        }

        // Push first, then decrement `_principal` using the amount the Vault
        // actually received (`sent`). Decrementing based on `actual` alone
        // would drop principal even when fee-on-transfer / rebasing / hook
        // tokens deliver less than `actual` to the Vault, producing silent
        // accounting drift between Strategy.principal and Vault.bufferBalance.
        // Principal-first decrement: any excess of `sent` over the remaining
        // `_principal` represents yield that is being deallocated as part of
        // this amount-specified push and stays in the Vault buffer to be
        // handled by `transferYieldToTreasury`.
        sent = ICollateralVault(vault).receiveFromStrategy(withdrawnUnderlying);
        uint256 principalReduction = sent > _principal ? _principal : sent;
        _principal -= principalReduction;

        emit SentToVault(msg.sender, _amount, sent, _principal);
    }

    /// @inheritdoc IStrategy
    function sendProfitToVault()
        external
        override
        nonReentrantStrategy
        onlyVaultRole(_HARVESTER_ROLE)
        returns (uint256 sent)
    {
        uint256 realizedProfit = realizedYield();
        if (realizedProfit == 0) {
            emit ProfitSentToVault(msg.sender, 0, 0);
            return 0;
        }

        uint256 withdrawnUnderlying = _doWithdraw(realizedProfit);
        if (withdrawnUnderlying == 0) {
            emit ProfitSentToVault(msg.sender, realizedProfit, 0);
            return 0;
        }

        // A converter's loss allowance can withdraw more than the measured yield.
        // Return that excess as principal instead of leaving phantom principal behind.
        if (withdrawnUnderlying > realizedProfit) {
            uint256 returned = ICollateralVault(vault).receiveFromStrategy(withdrawnUnderlying - realizedProfit);
            _accountReturnedPrincipal(returned);
            withdrawnUnderlying = realizedProfit;
        }

        // The remaining yield-only push leaves `_principal` unchanged. Send
        // directly to the Vault buffer so Strategy valuation cache is not
        // reduced as if principal had been returned.
        sent = _sendUnderlyingToVault(withdrawnUnderlying);
        emit ProfitSentToVault(msg.sender, realizedProfit, sent);
    }

    /// @inheritdoc IStrategy
    function writeoffPrincipal(uint256 _amount)
        external
        override
        onlyVault
        nonReentrantStrategy
        returns (uint256 writtenOff)
    {
        writtenOff = _amount > _principal ? _principal : _amount;
        _principal -= writtenOff;
        emit PrincipalWrittenOff(writtenOff, _principal);
    }

    // =============================================================
    //                   EMERGENCY FUNCTIONS
    // =============================================================

    /**
     * @notice Emergency push of Underlying held directly by this Strategy
     *         (not deployed in the upstream protocol) back to the Vault.
     *         Used to recover funds that became idle in the Strategy contract
     *         — e.g. after `emergencyWithdrawFromAave`, a donation, or an
     *         upstream protocol incident.
     * @dev    Owner only. The destination is fixed to `vault`; the previous
     *         arbitrary `_to` parameter allowed a Strategy owner (who can be
     *         distinct from the Vault GOV in some deployments) to drain
     *         Underlying to any address without GOV approval.
     *
     *         `_principal` is intentionally NOT decremented. This operation
     *         only moves recoverable idle Underlying back into Vault custody;
     *         it does not assert that the Strategy's upstream principal has
     *         been repaid or permanently lost.
     *
     *         Route through `Vault.receiveFromStrategy` instead of transferring
     *         directly so the Vault reduces an exact-delivery cache or
     *         invalidates it when declared and received amounts differ. A stale
     *         pre-recovery cache must not be able to count the same underlying
     *         once in the Vault buffer and again as Strategy value if live
     *         Strategy valuation is unavailable.
     *
     *         If the upstream balance is also gone and the residual loss needs
     *         to be acknowledged, the incident writeoff role should follow up with
     *         `Vault.writeoffStrategyPrincipal(strategy, amount, minBackingRatioAfter)`.
     */
    function emergencyWithdraw(uint256 _amount) external onlyOwner nonReentrantStrategy {
        if (_amount == 0) return;
        uint256 sent = ICollateralVault(vault).receiveFromStrategy(_amount);
        _afterEmergencyUnderlyingSent(_amount, sent);
        emit EmergencyWithdrawn(sent);
    }

    /**
     * @notice Sweep non-underlying, non-position reward tokens to the Vault treasury.
     * @dev    Covers Aave incentives, Merkl rewards, or accidental reward-token
     *         transfers that have already landed in the Strategy. Underlying and
     *         protocol position/accounting tokens are deliberately excluded:
     *         principal and underlying yield must return through `sendToVault`,
     *         `sendProfitToVault`, or `emergencyWithdraw`.
     *         Pass `type(uint256).max` to sweep the Strategy's full token balance.
     */
    function sweepRewardToken(IERC20 _token, uint256 _amount)
        external
        override
        onlyOwner
        nonReentrantStrategy
        returns (uint256 swept)
    {
        swept = _sweepRewardToken(_token, _amount);
    }

    /**
     * @notice Claim Merkl rewards earned by this Strategy. Ordinary reward
     *         tokens are swept to the current Vault treasury; underlying rewards
     *         are pushed back to the Vault as yield.
     * @dev    Uses Merkl's basic `claim` entry point only: every `user` is forced
     *         to `address(this)`, so no custom recipient or callback data can be
     *         injected. Upstream position/accounting tokens are rejected before
     *         the distributor call; underlying-token rewards are allowed but must
     *         are sent directly to the Vault buffer instead of the treasury
     *         sweep path, preserving the principal/yield accounting boundary for
     *         Morpho/Euler/Merkl-style reward programs without reducing the
     *         Vault's Strategy valuation cache.
     * @param  _distributor Merkl distributor contract.
     * @param  _tokens Reward tokens being claimed.
     * @param  _amounts Cumulative Merkl claim amounts for this Strategy.
     * @param  _proofs Merkle proofs matching each `(strategy, token, amount)`.
     * @return settledAmounts Amounts actually received by treasury or Vault per token.
     */
    function claimMerklRewards(
        IMerklDistributor _distributor,
        address[] calldata _tokens,
        uint256[] calldata _amounts,
        bytes32[][] calldata _proofs
    ) external onlyOwner nonReentrantStrategy returns (uint256[] memory settledAmounts) {
        if (address(_distributor) == address(0)) revert ZeroAddress();
        if (address(_distributor).code.length == 0) revert InvalidMerklDistributor();

        uint256 length = _tokens.length;
        if (length == 0 || length != _amounts.length || length != _proofs.length) revert InvalidMerklClaim();
        if (length > MAX_MERKL_TOKENS_PER_CLAIM) {
            revert TooManyMerklTokens(length, MAX_MERKL_TOKENS_PER_CLAIM);
        }

        address[] memory users = new address[](length);
        uint256[] memory balancesBeforeClaim = new uint256[](length);
        address underlyingAddress = address(underlyingToken);
        for (uint256 i = 0; i < length;) {
            address token = _tokens[i];
            if (token == address(0)) revert ZeroAddress();
            if (token != underlyingAddress && _isSweepProtectedToken(token)) revert CannotSweepProtectedToken();
            for (uint256 j = 0; j < i;) {
                if (_tokens[j] == token) revert DuplicateMerklToken(token);
                unchecked {
                    ++j;
                }
            }
            balancesBeforeClaim[i] = IERC20(token).balanceOf(address(this));
            users[i] = address(this);
            unchecked {
                ++i;
            }
        }

        _distributor.claim(users, _tokens, _amounts, _proofs);

        settledAmounts = new uint256[](length);
        for (uint256 i = 0; i < length;) {
            settledAmounts[i] = _settleClaimedMerklToken(
                address(_distributor), _tokens[i], _amounts[i], balancesBeforeClaim[i], underlyingAddress
            );
            unchecked {
                ++i;
            }
        }
    }

    function _settleClaimedMerklToken(
        address _distributor,
        address _token,
        uint256 _cumulativeAmount,
        uint256 _balanceBeforeClaim,
        address _underlyingAddress
    ) internal returns (uint256 settled) {
        if (_token == _underlyingAddress) {
            uint256 balanceAfterClaim = IERC20(_token).balanceOf(address(this));
            uint256 claimedUnderlying =
                balanceAfterClaim > _balanceBeforeClaim ? balanceAfterClaim - _balanceBeforeClaim : 0;
            if (claimedUnderlying != 0) {
                settled = _sendUnderlyingToVault(claimedUnderlying);
            }
            emit MerklUnderlyingRewardsClaimed(_distributor, _token, _cumulativeAmount, settled);
        } else {
            settled = _sweepRewardToken(IERC20(_token), type(uint256).max);
            emit MerklRewardsClaimed(_distributor, _token, _cumulativeAmount, settled);
        }
    }

    function _sendUnderlyingToVault(uint256 _amount) internal returns (uint256 sent) {
        if (_amount == 0) return 0;

        uint256 vaultBalanceBefore = underlyingToken.balanceOf(vault);
        underlyingToken.safeTransfer(vault, _amount);
        uint256 vaultBalanceAfter = underlyingToken.balanceOf(vault);
        sent = vaultBalanceAfter > vaultBalanceBefore ? vaultBalanceAfter - vaultBalanceBefore : 0;
    }

    function _accountReturnedPrincipal(uint256 _received) internal returns (uint256 principalReturned) {
        if (_received == 0) return 0;

        principalReturned = _received > _principal ? _principal : _received;
        if (principalReturned == 0) return 0;

        _principal -= principalReturned;
        emit PrincipalReturned(principalReturned, _principal);
    }

    /// @dev Common settlement path for protocol-specific emergency recovery.
    ///      This differs from `emergencyWithdraw`: recovered upstream principal
    ///      reduces `_principal` by the Vault's actual received amount.
    function _returnUnderlyingPrincipalToVault(uint256 _amount) internal returns (uint256 sent) {
        if (_amount == 0) return 0;

        sent = ICollateralVault(vault).receiveFromStrategy(_amount);
        _afterEmergencyUnderlyingSent(_amount, sent);
        _accountReturnedPrincipal(sent);
        emit EmergencyWithdrawn(sent);
    }

    /**
     * @dev Shared reward-token sweep primitive for future claim adapters.
     *      Protocol-specific strategies may claim rewards into this contract and
     *      call this helper, preserving the same accounting boundary and fixed
     *      treasury destination as the external owner operation. Derived
     *      strategies must mark any receipt/accounting token that represents the
     *      upstream position as sweep-protected.
     */
    function _sweepRewardToken(IERC20 _token, uint256 _amount) internal returns (uint256 swept) {
        address tokenAddress = address(_token);
        if (tokenAddress == address(0)) revert ZeroAddress();
        if (_isSweepProtectedToken(tokenAddress)) revert CannotSweepProtectedToken();

        uint256 amount = _amount == type(uint256).max ? _token.balanceOf(address(this)) : _amount;
        if (amount == 0) return 0;

        address recipient = ICollateralVault(vault).treasury();
        if (recipient == address(0)) revert ZeroAddress();

        uint256 recipientBalanceBeforeSweep = _token.balanceOf(recipient);
        _token.safeTransfer(recipient, amount);
        uint256 recipientBalanceAfterSweep = _token.balanceOf(recipient);
        swept = recipientBalanceAfterSweep > recipientBalanceBeforeSweep
            ? recipientBalanceAfterSweep - recipientBalanceBeforeSweep
            : 0;

        emit RewardTokenSwept(tokenAddress, recipient, amount, swept);
    }

    /**
     * @dev Tokens that are not rewards and must not be routed to treasury.
     *      Derived strategies override this to protect protocol-specific
     *      receipt/accounting tokens such as Aave aTokens.
     */
    function _isSweepProtectedToken(address _token) internal view virtual returns (bool) {
        return _token == address(underlyingToken) || _token == address(ICollateralVault(vault).dToken());
    }

    /// @dev Optional hook for derived strategies that separately track idle
    ///      underlying held by the Strategy contract itself.
    function _afterEmergencyUnderlyingSent(uint256, uint256) internal virtual {}

    // =============================================================
    //                   VIRTUAL HOOKS
    // =============================================================

    /// @dev Deploy `_amount` of underlying (already in this contract) into the
    ///      upstream yield protocol. Implementer is responsible for the actual
    ///      external call (e.g., `aavePool.supply(...)`).
    function _doDeposit(uint256 _amount) internal virtual;

    /// @dev Withdraw `_amount` of underlying from the upstream protocol. The
    ///      withdrawn underlying must end up held by THIS contract so the base
    ///      logic can route principal/cache-reducing returns through
    ///      `receiveFromStrategy` and yield-only returns through direct transfer.
    /// @return actual Amount actually withdrawn; may be less than requested.
    function _doWithdraw(uint256 _amount) internal virtual returns (uint256 actual);

    /// @dev Underlying value (principal + accrued yield) held in the upstream
    ///      protocol on behalf of this Strategy.
    function _estimatedTotalUnderlying() internal view virtual returns (uint256);
}
