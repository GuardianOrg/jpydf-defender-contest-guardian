// SPDX-License-Identifier: BUSL-1.1

pragma solidity 0.8.24;

import "openzeppelin-contracts/contracts/utils/math/Math.sol";

import "./Interfaces/ICollateralVault.sol";
import "./Interfaces/IStrategy.sol";

/**
 * @title CollateralVaultLens - read-only reporting surface for CollateralVault
 * @notice Ops and monitoring views, moved out of the Vault so they do not consume its
 *         EIP-170 budget. Fully stateless: no funds, no roles, no storage at all. The Vault
 *         is a parameter, so one deployment serves every branch, and each answer is
 *         reconstructed from that Vault's public getters plus direct calls to its Strategies.
 *
 * @dev    Why this exists: `CollateralVault` was within ~50 bytes of the 24,576-byte
 *         runtime limit, which blocked correctness fixes. These views are the largest
 *         removable surface and none of them is on a user or governance path — the Vault
 *         itself never calls them.
 *
 *         The reconstruction is exact rather than approximate. `_liveValuation` and
 *         `_cachedValuation` mirror the Vault's internal helpers, and every input they
 *         need (`strategies`, `strategyConfigs`, `strategyValuationCaches`,
 *         `strategyValuationMaxAge`, `totalUnderlying`, `actualLiabilities`) is already
 *         public. A Strategy view that reverts is caught here exactly as the Vault
 *         catches it, so an unreadable Strategy reports as unavailable rather than
 *         reverting the whole report.
 */
contract CollateralVaultLens {
    error InvalidBackingTarget();
    error StrategyNotFound();

    // =============================================================
    //                        SOLVENCY VIEWS
    // =============================================================

    /// @notice Underlying the Vault is short of its liabilities, or 0 when fully backed.
    function backingShortfall(ICollateralVault vault) external view returns (uint256) {
        uint256 totalAssets = vault.totalUnderlying();
        uint256 liabilities = vault.actualLiabilities();
        return liabilities > totalAssets ? liabilities - totalAssets : 0;
    }

    /// @notice Underlying that must be added to reach `_targetRatio` backing.
    function backstopRequiredForRatio(ICollateralVault vault, uint256 _targetRatio)
        external
        view
        returns (uint256)
    {
        if (_targetRatio > 1e18) revert InvalidBackingTarget();
        if (_targetRatio == 0) return 0;

        uint256 liabilities = vault.actualLiabilities();
        if (liabilities == 0) return 0;

        uint256 requiredAssets = Math.mulDiv(liabilities, _targetRatio, 1e18, Math.Rounding.Up);
        uint256 totalAssets = vault.totalUnderlying();
        return requiredAssets > totalAssets ? requiredAssets - totalAssets : 0;
    }

    // =============================================================
    //                       STRATEGY VIEWS
    // =============================================================

    function getStrategiesCount(ICollateralVault vault) external view returns (uint256) {
        return vault.getStrategiesCount();
    }

    /// @dev Reverts `StrategyNotFound` out of bounds, matching what the Vault did. Reading
    ///      `strategies(index)` through the public getter would panic on the array access
    ///      instead, which is a different error for the same condition.
    function getStrategyAt(ICollateralVault vault, uint256 _index)
        external
        view
        returns (IStrategy strategy, ICollateralVault.StrategyConfig memory config)
    {
        if (_index >= vault.getStrategiesCount()) revert StrategyNotFound();
        strategy = vault.strategies(_index);
        config = _configOf(vault, strategy);
    }

    function getAllStrategies(ICollateralVault vault)
        external
        view
        returns (
            IStrategy[] memory strategies_,
            ICollateralVault.StrategyConfig[] memory configs,
            uint256[] memory balances
        )
    {
        uint256 count = vault.getStrategiesCount();
        strategies_ = new IStrategy[](count);
        configs = new ICollateralVault.StrategyConfig[](count);
        balances = new uint256[](count);

        for (uint256 i; i < count; i++) {
            IStrategy strategy = vault.strategies(i);
            strategies_[i] = strategy;
            configs[i] = _configOf(vault, strategy);
            (uint256 estimated, bool available) = _tryEstimated(strategy);
            balances[i] = available ? estimated : 0;
        }
    }

    /// @notice Per-Strategy monitoring snapshot, identical in shape and content to what the
    ///         Vault used to return.
    function getStrategyStatuses(ICollateralVault vault)
        external
        view
        returns (ICollateralVault.StrategyStatus[] memory statuses)
    {
        uint256 count = vault.getStrategiesCount();
        statuses = new ICollateralVault.StrategyStatus[](count);
        for (uint256 i; i < count; i++) {
            IStrategy strategy = vault.strategies(i);
            statuses[i] = _buildStatus(vault, strategy, _configOf(vault, strategy));
        }
    }

    // =============================================================
    //                          INTERNAL
    // =============================================================

    function _configOf(ICollateralVault vault, IStrategy _strategy) internal view returns (ICollateralVault.StrategyConfig memory config) {
        (bool enabled, uint256 weightBps, uint256 cap) = vault.strategyConfigs(_strategy);
        config = ICollateralVault.StrategyConfig({enabled: enabled, weightBps: weightBps, cap: cap});
    }

    function _tryEstimated(IStrategy _strategy) internal view returns (uint256 estimated, bool available) {
        try _strategy.estimatedTotalUnderlying() returns (uint256 value) {
            return (value, true);
        } catch {
            return (0, false);
        }
    }

    function _tryPrincipal(IStrategy _strategy) internal view returns (uint256 principal_, bool available) {
        try _strategy.principal() returns (uint256 value) {
            return (value, true);
        } catch {
            return (0, false);
        }
    }

    /// @dev Mirrors `CollateralVault._liveStrategyValuation`.
    function _liveValuation(IStrategy _strategy)
        internal
        view
        returns (
            uint256 estimated,
            bool estimateAvailable,
            uint256 principal_,
            bool principalAvailable,
            uint256 conservativeValue,
            bool liveAvailable
        )
    {
        (estimated, estimateAvailable) = _tryEstimated(_strategy);
        (principal_, principalAvailable) = _tryPrincipal(_strategy);
        if (estimateAvailable && principalAvailable) {
            conservativeValue = estimated < principal_ ? estimated : principal_;
            liveAvailable = true;
        }
    }

    /// @dev Mirrors `CollateralVault._cachedStrategyConservativeValue`.
    function _cachedValuation(ICollateralVault vault, IStrategy _strategy)
        internal
        view
        returns (uint256 cachedValue, bool available, bool stale)
    {
        (uint256 conservativeValue, uint256 updatedAt, bool initialized) = vault.strategyValuationCaches(_strategy);
        if (!initialized) return (0, false, false);

        uint256 maxAge = vault.strategyValuationMaxAge();
        if (maxAge == 0 || block.timestamp - updatedAt > maxAge) return (0, false, true);

        return (conservativeValue, true, false);
    }

    /// @dev Mirrors `CollateralVault._buildStrategyStatus`.
    function _buildStatus(ICollateralVault vault, IStrategy _strategy, ICollateralVault.StrategyConfig memory _config)
        internal
        view
        returns (ICollateralVault.StrategyStatus memory status)
    {
        status.strategy = _strategy;
        status.config = _config;

        (
            uint256 estimated,
            bool estimateAvailable,
            uint256 principal_,
            bool principalAvailable,
            uint256 conservativeValue,
            bool liveAvailable
        ) = _liveValuation(_strategy);
        (uint256 cachedValue, bool cacheAvailable, bool cacheStale) = _cachedValuation(vault, _strategy);
        (uint256 rawCachedValue, uint256 cacheUpdatedAt,) = vault.strategyValuationCaches(_strategy);

        status.estimatedUnderlying = estimated;
        status.principal = principal_;
        status.estimateAvailable = estimateAvailable;
        status.principalAvailable = principalAvailable;
        status.cachedConservativeValue = rawCachedValue;
        status.cacheUpdatedAt = cacheUpdatedAt;
        status.cacheAvailable = cacheAvailable;
        status.cacheStale = cacheStale;

        if (estimateAvailable) {
            status.capRemaining = _config.cap > estimated ? _config.cap - estimated : 0;
        }

        if (liveAvailable) {
            status.conservativeValue = conservativeValue;
            if (estimated > principal_) {
                status.estimatedGain = estimated - principal_;
            } else {
                status.estimatedLoss = principal_ - estimated;
            }
        } else if (cacheAvailable) {
            status.conservativeValue = cachedValue;
            status.usingCachedConservativeValue = true;
        }
    }
}
