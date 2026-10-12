// SPDX-License-Identifier: BUSL-1.1

pragma solidity 0.8.24;

import "./Interfaces/ICollateralRegistry.sol";
import "./Interfaces/ILiquidationCandidateGetter.sol";
import "./Interfaces/ISortedTroves.sol";
import "./Interfaces/ITroveManager.sol";
import "./Types/LatestTroveData.sol";

/**
 * @title LiquidationCandidateGetter
 * @notice Read-only helper for liquidation bots and monitoring.
 * @dev This contract deliberately stays outside the core Liquity state machine:
 *      it only walks branch-local `SortedTroves`, recomputes ICR using the
 *      caller-supplied protocol price/MCR, and returns enough debt/collateral
 *      data for off-chain batching. Zombie Troves are not in `SortedTroves`, so
 *      callers that need full coverage must use the `WithLastZombie` path.
 */
contract LiquidationCandidateGetter is ILiquidationCandidateGetter {
    ICollateralRegistry public immutable collateralRegistry;

    constructor(ICollateralRegistry _collateralRegistry) {
        if (address(_collateralRegistry) == address(0)) revert LiquidationCandidateGetter__InvalidCollateralRegistry();
        collateralRegistry = _collateralRegistry;
    }

    function getLiquidationCandidates(
        uint256 _collIndex,
        uint256 _startId,
        uint256 _maxIterations,
        uint256 _price,
        uint256 _mcr
    ) external view returns (LiquidationCandidate[] memory candidates, uint256 currId) {
        (candidates, currId,) = _getLiquidationCandidates(_collIndex, _startId, _maxIterations, _price, _mcr, false);
    }

    function getLiquidationCandidatesWithLastZombie(
        uint256 _collIndex,
        uint256 _startId,
        uint256 _maxIterations,
        uint256 _price,
        uint256 _mcr,
        bool _includeLastZombie
    ) external view returns (LiquidationCandidate[] memory candidates, uint256 currId, bool includedLastZombie) {
        return _getLiquidationCandidates(_collIndex, _startId, _maxIterations, _price, _mcr, _includeLastZombie);
    }

    function getLastZombieLiquidationCandidate(uint256 _collIndex, uint256 _price, uint256 _mcr)
        external
        view
        returns (bool found, LiquidationCandidate memory candidate)
    {
        return _getLastZombieLiquidationCandidate(_requireTroveManager(_collIndex), _price, _mcr);
    }

    function _getLiquidationCandidates(
        uint256 _collIndex,
        uint256 _startId,
        uint256 _maxIterations,
        uint256 _price,
        uint256 _mcr,
        bool _includeLastZombie
    ) internal view returns (LiquidationCandidate[] memory candidates, uint256 currId, bool includedLastZombie) {
        ITroveManager troveManager = _requireTroveManager(_collIndex);

        ISortedTroves sortedTroves = troveManager.sortedTroves();
        assert(address(sortedTroves) != address(0));

        LiquidationCandidate[] memory candidateBuffer =
            new LiquidationCandidate[](_maxIterations + (_includeLastZombie ? 1 : 0));
        // `currId` is returned as a cursor for the next scan. The current Trove
        // is advanced before any expensive reads so off-chain callers can safely
        // resume even when a candidate is skipped after rechecking ICR.
        currId = _startId == 0 ? sortedTroves.getFirst() : _startId;
        uint256 candidateCount;

        for (uint256 scannedCount; scannedCount < _maxIterations && currId != 0; ++scannedCount) {
            uint256 troveId = currId;
            currId = sortedTroves.getNext(troveId);

            uint256 icr = troveManager.getCurrentICR(troveId, _price);
            if (icr >= _mcr) continue;

            LatestTroveData memory trove = troveManager.getLatestTroveData(troveId);
            candidateBuffer[candidateCount++] = LiquidationCandidate({
                id: troveId,
                ICR: icr,
                entireDebt: trove.entireDebt,
                entireColl: trove.entireColl
            });
        }

        if (_includeLastZombie) {
            // Redemptions can leave one zombie outside `SortedTroves`. Append it
            // explicitly so keepers do not miss a liquidatable zombie when a
            // branch is otherwise idle.
            LiquidationCandidate memory lastZombie;
            (includedLastZombie, lastZombie) = _getLastZombieLiquidationCandidate(troveManager, _price, _mcr);
            if (includedLastZombie) {
                candidateBuffer[candidateCount++] = lastZombie;
            }
        }

        candidates = new LiquidationCandidate[](candidateCount);
        for (uint256 candidateIndex; candidateIndex < candidateCount; ++candidateIndex) {
            candidates[candidateIndex] = candidateBuffer[candidateIndex];
        }
    }

    function _getLastZombieLiquidationCandidate(ITroveManager _troveManager, uint256 _price, uint256 _mcr)
        internal
        view
        returns (bool found, LiquidationCandidate memory candidate)
    {
        uint256 troveId = _troveManager.lastZombieTroveId();
        if (troveId == 0) return (false, candidate);
        if (_troveManager.getTroveStatus(troveId) != ITroveManager.Status.zombie) return (false, candidate);

        uint256 icr = _troveManager.getCurrentICR(troveId, _price);
        if (icr >= _mcr) return (false, candidate);

        LatestTroveData memory trove = _troveManager.getLatestTroveData(troveId);
        return (
            true,
            LiquidationCandidate({id: troveId, ICR: icr, entireDebt: trove.entireDebt, entireColl: trove.entireColl})
        );
    }

    function _requireTroveManager(uint256 _collIndex) internal view returns (ITroveManager troveManager) {
        troveManager = collateralRegistry.getTroveManager(_collIndex);
        if (address(troveManager) == address(0)) revert LiquidationCandidateGetter__InvalidCollateralIndex();
    }
}
