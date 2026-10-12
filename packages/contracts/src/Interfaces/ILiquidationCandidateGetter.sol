// SPDX-License-Identifier: MIT

pragma solidity ^0.8.0;

interface ILiquidationCandidateGetter {
    error LiquidationCandidateGetter__InvalidCollateralRegistry();
    error LiquidationCandidateGetter__InvalidCollateralIndex();

    struct LiquidationCandidate {
        uint256 id;
        uint256 ICR;
        uint256 entireDebt;
        uint256 entireColl;
    }

    function getLiquidationCandidates(
        uint256 _collIndex,
        uint256 _startId,
        uint256 _maxIterations,
        uint256 _price,
        uint256 _mcr
    ) external view returns (LiquidationCandidate[] memory candidates, uint256 currId);

    function getLiquidationCandidatesWithLastZombie(
        uint256 _collIndex,
        uint256 _startId,
        uint256 _maxIterations,
        uint256 _price,
        uint256 _mcr,
        bool _includeLastZombie
    ) external view returns (LiquidationCandidate[] memory candidates, uint256 currId, bool includedLastZombie);

    function getLastZombieLiquidationCandidate(uint256 _collIndex, uint256 _price, uint256 _mcr)
        external
        view
        returns (bool found, LiquidationCandidate memory candidate);
}
