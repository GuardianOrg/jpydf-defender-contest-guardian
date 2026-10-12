// SPDX-License-Identifier: MIT

pragma solidity ^0.8.0;

import "openzeppelin-contracts/contracts/token/ERC20/extensions/IERC20Metadata.sol";

import "../Types/RiskParams.sol";
import "./IActivePool.sol";
import "./IJpydfToken.sol";
import "./IBorrowerOperations.sol";
import "./ICollSurplusPool.sol";
import "./IDefaultPool.sol";
import "./IHintHelpers.sol";
import "./IMultiTroveGetter.sol";
import "./ISortedTroves.sol";
import "./IStabilityPool.sol";
import "./ITroveManager.sol";
import "./ITroveNFT.sol";
import "./IMetadataNFT.sol";
import "./ICollateralRegistry.sol";
import "./IInterestRouter.sol";
import "./IPriceFeed.sol";
import "./IWETH.sol";

interface IAddressesRegistry {
    struct AddressVars {
        IERC20Metadata collToken;
        IBorrowerOperations borrowerOperations;
        ITroveManager troveManager;
        ITroveNFT troveNFT;
        IMetadataNFT metadataNFT;
        IStabilityPool stabilityPool;
        IPriceFeed priceFeed;
        IActivePool activePool;
        IDefaultPool defaultPool;
        address gasPoolAddress;
        ICollSurplusPool collSurplusPool;
        ISortedTroves sortedTroves;
        IInterestRouter interestRouter;
        IHintHelpers hintHelpers;
        IMultiTroveGetter multiTroveGetter;
        ICollateralRegistry collateralRegistry;
        IJpydfToken jpydfToken;
        IWETH WETH;
    }

    function CCR() external view returns (uint256);
    function SCR() external view returns (uint256);
    function MCR() external view returns (uint256);
    function BCR() external view returns (uint256);
    function LIQUIDATION_PENALTY_SP() external view returns (uint256);
    function LIQUIDATION_PENALTY_REDISTRIBUTION() external view returns (uint256);

    function riskParamsFinalizer() external view returns (address);
    function riskParamsFinalized() external view returns (bool);

    function collToken() external view returns (IERC20Metadata);
    function borrowerOperations() external view returns (IBorrowerOperations);
    function troveManager() external view returns (ITroveManager);
    function troveNFT() external view returns (ITroveNFT);
    function metadataNFT() external view returns (IMetadataNFT);
    function stabilityPool() external view returns (IStabilityPool);
    function priceFeed() external view returns (IPriceFeed);
    function activePool() external view returns (IActivePool);
    function defaultPool() external view returns (IDefaultPool);
    function gasPoolAddress() external view returns (address);
    function collSurplusPool() external view returns (ICollSurplusPool);
    function sortedTroves() external view returns (ISortedTroves);
    function interestRouter() external view returns (IInterestRouter);
    function hintHelpers() external view returns (IHintHelpers);
    function multiTroveGetter() external view returns (IMultiTroveGetter);
    function collateralRegistry() external view returns (ICollateralRegistry);
    function jpydfToken() external view returns (IJpydfToken);
    function WETH() external returns (IWETH);

    function setAddresses(AddressVars memory _vars) external;
    function finalizeRiskParams(address _expectedUnderlying, RiskParams calldata _riskParams) external;
}
