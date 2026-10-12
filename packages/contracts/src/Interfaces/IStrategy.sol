// SPDX-License-Identifier: MIT

pragma solidity ^0.8.0;

import "openzeppelin-contracts/contracts/token/ERC20/IERC20.sol";

/**
 * @title IStrategy - Common interface for yield strategies (push model)
 * @notice Strategies expose two push functions. They withdraw underlying internally
 *         and call back into the Vault via `receiveFromStrategy` for principal
 *         pushes; realized yield is transferred directly to the Vault buffer.
 *         The upstream yield protocol can be synchronous or asynchronous.
 * @dev
 *   - `sendToVault(uint256)` is the "amount-specified push" used by the
 *     ALLOCATOR role on the Vault. It is the replacement for the old
 *     `Vault.deallocate(...)` flow.
 *   - `sendProfitToVault()` is the "profit-capped push", also gated by the
 *     ALLOCATOR role on the Vault. The amount is internally capped at `realizedYield()`.
 *   - Both functions are role-gated by querying the Vault's AccessControl, so
 *     a single role registry (on the Vault) governs both.
 *   - `principal()` is the per-Strategy bookkeeping of cumulative deposits
 *     minus principal-portion withdrawals. The Vault uses
 *     `min(estimatedTotalUnderlying, principal)` for the solvency view.
 */
interface IStrategy {
    /// @notice Underlying token address used by this Strategy
    function underlying() external view returns (address);

    /// @notice Receive underlying that has already been transferred by the Vault
    ///         and deploy it to the upstream yield protocol.
    /// @dev    onlyVault. The Vault transfers underlying *before* calling this.
    /// @param  _declaredAmount Amount removed from the Vault buffer
    /// @param  _receivedAmount Net amount received by the Strategy
    /// @return deposited `_receivedAmount` when deployed, or 0 after exact recovery to the Vault
    function deposit(uint256 _declaredAmount, uint256 _receivedAmount) external returns (uint256 deposited);

    /// @notice Principal currently tracked by this Strategy
    ///         (cumulative deposit minus the principal-portion of withdrawals).
    function principal() external view returns (uint256);

    /// @notice `estimatedTotalUnderlying() - principal()` clamped at zero.
    ///         Used as the cap by `sendProfitToVault()`.
    function realizedYield() external view returns (uint256);

    /// @notice Current estimated underlying value held by this Strategy.
    function estimatedTotalUnderlying() external view returns (uint256);

    /// @notice Push underlying back to the Vault. Caller must hold the
    ///         WITHDRAWER_ROLE on the Vault. Used for deallocation /
    ///         portfolio rebalancing / removeStrategy preparation.
    /// @param  _amount Requested amount. The actual sent amount may be less
    ///         if the upstream protocol cannot fulfill the full request.
    /// @return sent   Amount actually received by the Vault.
    function sendToVault(uint256 _amount) external returns (uint256 sent);

    /// @notice Push only realized yield to the Vault. Caller must hold the
    ///         HARVESTER_ROLE on the Vault. The amount is computed by the
    ///         Strategy as `realizedYield()` at call time; the caller does
    ///         not supply an amount.
    /// @return sent   Amount actually received by the Vault.
    function sendProfitToVault() external returns (uint256 sent);

    /// @notice Acknowledge a permanent loss of principal so that the Strategy
    ///         can be removed even though `estimatedTotalUnderlying()` is
    ///         below `principal()`. Vault-only.
    /// @param  _amount Amount of principal to write off.
    /// @return writtenOff Amount actually written off after clamping to principal.
    function writeoffPrincipal(uint256 _amount) external returns (uint256 writtenOff);

    /// @notice Sweep non-underlying, non-position reward tokens held by this
    ///         Strategy to the Vault's current treasury. Owner-only in the implementation.
    /// @dev    Must reject the Strategy underlying and protocol position /
    ///         accounting tokens so this cannot bypass the normal Vault-return
    ///         path for principal or underlying yield. Pass `type(uint256).max`
    ///         to sweep the full Strategy token balance.
    /// @param  _token Reward token to sweep.
    /// @param  _amount Requested amount to transfer.
    /// @return swept Amount actually received by the treasury, measured by
    ///         balance diff to support fee-on-transfer reward tokens.
    function sweepRewardToken(IERC20 _token, uint256 _amount) external returns (uint256 swept);
}
