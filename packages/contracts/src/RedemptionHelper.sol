// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.24;

import {IERC20} from "openzeppelin-contracts/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "openzeppelin-contracts/contracts/token/ERC20/utils/SafeERC20.sol";
import {Math} from "openzeppelin-contracts/contracts/utils/math/Math.sol";

import {_100pct, DECIMAL_PRECISION} from "./Dependencies/Constants.sol";
import {IAddressesRegistry} from "./Interfaces/IAddressesRegistry.sol";
import {IJpydfToken} from "./Interfaces/IJpydfToken.sol";
import {ICollateralRegistry} from "./Interfaces/ICollateralRegistry.sol";
import {IRedemptionHelper} from "./Interfaces/IRedemptionHelper.sol";
import {ISortedTroves} from "./Interfaces/ISortedTroves.sol";
import {ITroveManager} from "./Interfaces/ITroveManager.sol";
import {LatestTroveData} from "./Types/LatestTroveData.sol";

contract RedemptionHelper is IRedemptionHelper {
    using SafeERC20 for IERC20;

    struct RedemptionContext {
        IERC20 collToken;
        uint256 collBalanceBefore;
    }

    uint256 public immutable numBranches;
    ICollateralRegistry public immutable collateralRegistry;
    IJpydfToken public immutable jpydfToken;
    IAddressesRegistry[] public addresses; // only used off-chain, so we don't care about storage cost

    constructor(ICollateralRegistry _collateralRegistry, IAddressesRegistry[] memory _addresses) {
        require(_addresses.length == _collateralRegistry.totalCollaterals(), "Wrong number of registries");
        numBranches = _addresses.length;
        collateralRegistry = _collateralRegistry;
        jpydfToken = _collateralRegistry.jpydfToken();

        for (uint256 i = 0; i < _addresses.length; ++i) {
            require(_collateralRegistry.getTroveManager(i) == _addresses[i].troveManager(), "TroveManager mismatch");
            addresses.push(_addresses[i]);
        }
    }

    // Meant to be called off-chain
    // Not a view because price fetching has side-effects
    function simulateRedemption(uint256 _jpydf, uint256 _maxIterationsPerCollateral)
        public
        returns (SimulationContext[] memory branch, uint256 totalProportions)
    {
        branch = new SimulationContext[](numBranches);
        bool[] memory redemptionPriceAvailable = new bool[](numBranches);
        uint256 availableProportions;

        // First priority: proportional to unbacked debt
        for (uint256 i = 0; i < numBranches; ++i) {
            branch[i].troveManager = address(addresses[i].troveManager());
            branch[i].sortedTroves = address(addresses[i].sortedTroves());
            (branch[i].proportion, branch[i].price, branch[i].redeemable) =
                ITroveManager(branch[i].troveManager).getUnbackedPortionPriceAndRedeemability();
            if (branch[i].redeemable) {
                (, bool redemptionFailure) = addresses[i].priceFeed().fetchRedemptionPrice();
                redemptionPriceAvailable[i] = !redemptionFailure;
                totalProportions += branch[i].proportion;
                if (!redemptionFailure) availableProportions += branch[i].proportion;
            }
        }

        // CS-JPYDF-013: truncate redemption if it would exceed total unbacked debt
        if (0 < totalProportions && totalProportions < _jpydf) _jpydf = totalProportions;

        // Fallback: proportional to total debt
        if (totalProportions == 0) {
            availableProportions = 0;
            for (uint256 i = 0; i < numBranches; ++i) {
                branch[i].proportion = ITroveManager(branch[i].troveManager).getEntireBranchDebt();
                if (branch[i].redeemable) {
                    totalProportions += branch[i].proportion;
                    if (redemptionPriceAvailable[i]) availableProportions += branch[i].proportion;
                }
            }
        }

        for (uint256 i = 0; i < numBranches; ++i) {
            if (branch[i].redeemable && !redemptionPriceAvailable[i]) branch[i].redeemable = false;
        }

        if (totalProportions == 0 || availableProportions == 0) return (branch, 0);

        for (uint256 i = 0; i < numBranches; ++i) {
            if (!branch[i].redeemable) continue;

            branch[i].attemptedJpydf = _jpydf * branch[i].proportion / totalProportions;
            if (branch[i].attemptedJpydf == 0) continue;

            uint256 lastZombieTroveId = ITroveManager(branch[i].troveManager).lastZombieTroveId();
            uint256 lastTroveId = ISortedTroves(branch[i].sortedTroves).getLast();

            (uint256 troveId, uint256 nextTroveId) = lastZombieTroveId != 0
                ? (lastZombieTroveId, lastTroveId)
                : (lastTroveId, ISortedTroves(branch[i].sortedTroves).getPrev(lastTroveId));

            for (
                branch[i].iterations = 0;
                branch[i].iterations < _maxIterationsPerCollateral || _maxIterationsPerCollateral == 0;
                ++branch[i].iterations
            ) {
                if (branch[i].redeemedJpydf == branch[i].attemptedJpydf || troveId == 0) break;

                LatestTroveData memory trove = ITroveManager(branch[i].troveManager).getLatestTroveData(troveId);
                if (trove.entireColl * branch[i].price / trove.entireDebt >= _100pct) {
                    branch[i].redeemedJpydf +=
                        Math.min(branch[i].attemptedJpydf - branch[i].redeemedJpydf, trove.entireDebt);
                }

                troveId = nextTroveId;
                nextTroveId = ISortedTroves(branch[i].sortedTroves).getPrev(nextTroveId);
            }
        }
    }

    // Meant to be called off-chain
    // Not a view because price fetching has side-effects
    function truncateRedemption(uint256 _jpydf, uint256 _maxIterationsPerCollateral)
        external
        returns (uint256 truncatedJpydf, uint256 feePct, Redeemed[] memory redeemed)
    {
        (SimulationContext[] memory branch, uint256 totalProportions) =
            simulateRedemption(_jpydf, _maxIterationsPerCollateral);

        if (totalProportions == 0) return (0, 0, redeemed);

        truncatedJpydf = _jpydf;
        for (uint256 i = 0; i < numBranches; ++i) {
            if (branch[i].redeemable && branch[i].proportion > 0) {
                // Extrapolate how much the entire redeemed JPYDF would
                // have been if this branch was redeemed proportionally.
                uint256 extrapolatedJpydf = branch[i].redeemedJpydf * totalProportions / branch[i].proportion;

                // Normally this is no different from `_jpydf`, but can be less if the redemption on this branch
                // terminated due to hitting the iteration limit. We're looking for the smallest extrapolated value,
                // since that is the maximum amount of JPYDF that can be redeemed proportionally within the given
                // iteration limit. Any attempt to redeem more than this would result in a partial redemption, thus
                // paying a higher redemption fee than necessary — since the fee is based on the attempted amount.
                if (extrapolatedJpydf < truncatedJpydf) truncatedJpydf = extrapolatedJpydf;
            }
        }

        feePct = collateralRegistry.getRedemptionRateForRedeemedAmount(truncatedJpydf);
        redeemed = new Redeemed[](numBranches);

        for (uint256 i = 0; i < numBranches; ++i) {
            if (branch[i].redeemable && branch[i].proportion > 0) {
                (uint256 redemptionPrice, bool redemptionFailure) = addresses[i].priceFeed().fetchRedemptionPrice();
                if (redemptionFailure) return (0, 0, new Redeemed[](numBranches));
                redeemed[i].jpydf = truncatedJpydf * branch[i].proportion / totalProportions;
                redeemed[i].coll = redeemed[i].jpydf * (DECIMAL_PRECISION - feePct) / redemptionPrice;
            }
        }
    }

    function redeemCollateral(
        uint256 _jpydf,
        uint256 _maxIterationsPerCollateral,
        uint256 _maxFeePct,
        uint256[] memory _minCollRedeemed
    ) external {
        require(_jpydf > 0, "Redeemed amount must be non-zero");
        require(_minCollRedeemed.length == numBranches, "Wrong _minCollRedeemed length");

        RedemptionContext[] memory branch = new RedemptionContext[](numBranches);

        for (uint256 i = 0; i < numBranches; ++i) {
            branch[i].collToken = collateralRegistry.getToken(i);
            branch[i].collBalanceBefore = branch[i].collToken.balanceOf(address(this));
        }

        uint256 jpydfBalanceBefore = jpydfToken.balanceOf(address(this));

        IERC20(address(jpydfToken)).safeTransferFrom(msg.sender, address(this), _jpydf);
        collateralRegistry.redeemCollateral(_jpydf, _maxIterationsPerCollateral, _maxFeePct);

        for (uint256 i = 0; i < numBranches; ++i) {
            uint256 collRedeemed = branch[i].collToken.balanceOf(address(this)) - branch[i].collBalanceBefore;
            require(collRedeemed >= _minCollRedeemed[i], "Insufficient collateral redeemed");
            if (collRedeemed > 0) branch[i].collToken.safeTransfer(msg.sender, collRedeemed);
        }

        uint256 jpydfRemaining = jpydfToken.balanceOf(address(this)) - jpydfBalanceBefore;
        if (jpydfRemaining > 0) IERC20(address(jpydfToken)).safeTransfer(msg.sender, jpydfRemaining);
    }
}
