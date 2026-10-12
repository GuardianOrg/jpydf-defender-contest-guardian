// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

interface IRedemptionHelper {
    struct SimulationContext {
        address troveManager;
        address sortedTroves;
        bool redeemable;
        uint256 price;
        uint256 proportion;
        uint256 attemptedJpydf;
        uint256 redeemedJpydf;
        uint256 iterations;
    }

    struct Redeemed {
        uint256 jpydf;
        uint256 coll;
    }

    function simulateRedemption(uint256 _jpydf, uint256 _maxIterationsPerCollateral)
        external
        returns (SimulationContext[] memory branch, uint256 totalProportions);

    // Find the request amount associated with the proportional quote within the
    // iteration limit. This is not a full-fill guarantee: unavailable branches
    // retain their allocation weights, so part of truncatedJpydf may remain unspent.
    // Sum redeemed[i].jpydf for the expected fill. This helps avoid overpaying fees.
    //
    // Also returns the expected fee that will be paid (as a percentage), and the
    // expected collateral amounts that will be paid out in exchange for the
    // redeemed JPYDF. The latter may be used to calculate the _minCollRedeemed
    // parameter passed to redeemCollateral().
    function truncateRedemption(uint256 _jpydf, uint256 _maxIterationsPerCollateral)
        external
        returns (uint256 truncatedJpydf, uint256 feePct, Redeemed[] memory redeemed);

    // Wrapper around CollateralRegistry's redeemCollateral() that adds slippage
    // protection in the form of a minimum acceptable collateral amounts parameter.
    function redeemCollateral(
        uint256 _jpydf,
        uint256 _maxIterationsPerCollateral,
        uint256 _maxFeePct,
        uint256[] memory _minCollRedeemed
    ) external;
}
