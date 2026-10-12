// SPDX-License-Identifier: BUSL-1.1

pragma solidity 0.8.24;

import "./Dependencies/Ownable.sol";
import {
    MIN_LIQUIDATION_PENALTY_SP,
    COLL_GAS_COMPENSATION_DIVISOR,
    MAX_LIQUIDATION_PENALTY_REDISTRIBUTION,
    URGENT_REDEMPTION_BONUS,
    COLL_GAS_COMPENSATION_CAP
} from "./Dependencies/Constants.sol";
import "./Interfaces/IAddressesRegistry.sol";
import "./Interfaces/IMetadataNFT.sol";
import {IDToken} from "./Interfaces/IDToken.sol";
import {ICollateralVault} from "./Interfaces/ICollateralVault.sol";

contract AddressesRegistry is Ownable, IAddressesRegistry {
    IERC20Metadata public collToken;
    IBorrowerOperations public borrowerOperations;
    ITroveManager public troveManager;
    ITroveNFT public troveNFT;
    IMetadataNFT public metadataNFT;
    IStabilityPool public stabilityPool;
    IPriceFeed public priceFeed;
    IActivePool public activePool;
    IDefaultPool public defaultPool;
    address public gasPoolAddress;
    ICollSurplusPool public collSurplusPool;
    ISortedTroves public sortedTroves;
    IInterestRouter public interestRouter;
    IHintHelpers public hintHelpers;
    IMultiTroveGetter public multiTroveGetter;
    ICollateralRegistry public collateralRegistry;
    IJpydfToken public jpydfToken;
    IWETH public WETH;

    // Critical system collateral ratio. If the system's total collateral ratio (TCR) falls below the CCR, some borrowing operation restrictions are applied
    uint256 public CCR;
    // Shutdown system collateral ratio. If the system's total collateral ratio (TCR) for a given collateral falls below the SCR,
    // the protocol triggers the shutdown of the borrow market and permanently disables all borrowing operations except for closing Troves.
    uint256 public SCR;

    // Minimum collateral ratio for individual troves
    uint256 public MCR;
    // Extra buffer of collateral ratio to join a batch or adjust a trove inside a batch (on top of MCR)
    uint256 public BCR;
    // Liquidation penalty for troves offset to the SP
    uint256 public LIQUIDATION_PENALTY_SP;
    // Liquidation penalty for troves redistributed
    uint256 public LIQUIDATION_PENALTY_REDISTRIBUTION;

    // Zero for branches whose risk parameters are final at deployment. Reserved
    // branches store the only address that may finalize their parameters.
    address public immutable riskParamsFinalizer;
    bool public riskParamsFinalized;

    error InvalidCollGasCompensationCap();
    error InvalidCCR();
    error InvalidMCR();
    error InvalidBCR();
    error InvalidSCR();
    error SPPenaltyTooLow();
    error SPPenaltyGtRedist();
    error RedistPenaltyTooHigh();
    error InvalidCollateralRatioOrder();
    error MCRBelowSPPenalty();
    error MCRBelowRedistributionPenalty();
    error SCRBelowUrgentRedemptionBonus();
    error CallerNotRiskParamsFinalizer();
    error RiskParamsAlreadyFinalized();
    error InvalidExpectedUnderlying();
    error InvalidDToken();
    error InvalidVault();
    error DTokenUnderlyingMismatch(address expected, address actual);
    error VaultUnderlyingMismatch(address expected, address actual);
    error VaultDTokenMismatch(address expected, address actual);
    error DTokenCapNotZero(uint256 cap);
    error DTokenSupplyNotZero(uint256 supply);
    error TrovesExist(uint256 count);
    error BranchDebtNotZero(uint256 debt);
    error BranchCollNotZero(uint256 coll);
    error StabilityPoolNotEmpty(uint256 deposits);
    error OracleFailureShutdownActive();
    error BranchAlreadyShutDown();

    event CollTokenAddressChanged(address _collTokenAddress);
    event BorrowerOperationsAddressChanged(address _borrowerOperationsAddress);
    event TroveManagerAddressChanged(address _troveManagerAddress);
    event TroveNFTAddressChanged(address _troveNFTAddress);
    event MetadataNFTAddressChanged(address _metadataNFTAddress);
    event StabilityPoolAddressChanged(address _stabilityPoolAddress);
    event PriceFeedAddressChanged(address _priceFeedAddress);
    event ActivePoolAddressChanged(address _activePoolAddress);
    event DefaultPoolAddressChanged(address _defaultPoolAddress);
    event GasPoolAddressChanged(address _gasPoolAddress);
    event CollSurplusPoolAddressChanged(address _collSurplusPoolAddress);
    event SortedTrovesAddressChanged(address _sortedTrovesAddress);
    event InterestRouterAddressChanged(address _interestRouterAddress);
    event HintHelpersAddressChanged(address _hintHelpersAddress);
    event MultiTroveGetterAddressChanged(address _multiTroveGetterAddress);
    event CollateralRegistryAddressChanged(address _collateralRegistryAddress);
    event JpydfTokenAddressChanged(address _jpydfTokenAddress);
    event WETHAddressChanged(address _wethAddress);
    event RiskParamsFinalized(
        address indexed underlying,
        uint256 CCR,
        uint256 MCR,
        uint256 BCR,
        uint256 SCR,
        uint256 liquidationPenaltySP,
        uint256 liquidationPenaltyRedistribution,
        uint256 collGasCompensationCap
    );

    constructor(
        address _initialOwner,
        uint256 _ccr,
        uint256 _mcr,
        uint256 _bcr,
        uint256 _scr,
        uint256 _liquidationPenaltySP,
        uint256 _liquidationPenaltyRedistribution,
        address _riskParamsFinalizer
    ) Ownable(_initialOwner) {
        _requireValidRiskParams(_ccr, _mcr, _bcr, _scr, _liquidationPenaltySP, _liquidationPenaltyRedistribution);

        CCR = _ccr;
        SCR = _scr;
        MCR = _mcr;
        BCR = _bcr;
        LIQUIDATION_PENALTY_SP = _liquidationPenaltySP;
        LIQUIDATION_PENALTY_REDISTRIBUTION = _liquidationPenaltyRedistribution;
        riskParamsFinalizer = _riskParamsFinalizer;
        riskParamsFinalized = _riskParamsFinalizer == address(0);
    }

    function setAddresses(AddressVars memory _vars) external onlyOwner {
        collToken = _vars.collToken;
        borrowerOperations = _vars.borrowerOperations;
        troveManager = _vars.troveManager;
        troveNFT = _vars.troveNFT;
        metadataNFT = _vars.metadataNFT;
        stabilityPool = _vars.stabilityPool;
        priceFeed = _vars.priceFeed;
        activePool = _vars.activePool;
        defaultPool = _vars.defaultPool;
        gasPoolAddress = _vars.gasPoolAddress;
        collSurplusPool = _vars.collSurplusPool;
        sortedTroves = _vars.sortedTroves;
        interestRouter = _vars.interestRouter;
        hintHelpers = _vars.hintHelpers;
        multiTroveGetter = _vars.multiTroveGetter;
        collateralRegistry = _vars.collateralRegistry;
        jpydfToken = _vars.jpydfToken;
        WETH = _vars.WETH;

        emit CollTokenAddressChanged(address(_vars.collToken));
        emit BorrowerOperationsAddressChanged(address(_vars.borrowerOperations));
        emit TroveManagerAddressChanged(address(_vars.troveManager));
        emit TroveNFTAddressChanged(address(_vars.troveNFT));
        emit MetadataNFTAddressChanged(address(_vars.metadataNFT));
        emit StabilityPoolAddressChanged(address(_vars.stabilityPool));
        emit PriceFeedAddressChanged(address(_vars.priceFeed));
        emit ActivePoolAddressChanged(address(_vars.activePool));
        emit DefaultPoolAddressChanged(address(_vars.defaultPool));
        emit GasPoolAddressChanged(_vars.gasPoolAddress);
        emit CollSurplusPoolAddressChanged(address(_vars.collSurplusPool));
        emit SortedTrovesAddressChanged(address(_vars.sortedTroves));
        emit InterestRouterAddressChanged(address(_vars.interestRouter));
        emit HintHelpersAddressChanged(address(_vars.hintHelpers));
        emit MultiTroveGetterAddressChanged(address(_vars.multiTroveGetter));
        emit CollateralRegistryAddressChanged(address(_vars.collateralRegistry));
        emit JpydfTokenAddressChanged(address(_vars.jpydfToken));
        emit WETHAddressChanged(address(_vars.WETH));

        _renounceOwnership();
    }

    function finalizeRiskParams(address _expectedUnderlying, RiskParams calldata _riskParams) external {
        if (riskParamsFinalized) revert RiskParamsAlreadyFinalized();
        if (msg.sender != riskParamsFinalizer) revert CallerNotRiskParamsFinalizer();

        _requireFinalizedRiskParams(
            _riskParams.CCR,
            _riskParams.MCR,
            _riskParams.BCR,
            _riskParams.SCR,
            _riskParams.LIQUIDATION_PENALTY_SP,
            _riskParams.LIQUIDATION_PENALTY_REDISTRIBUTION
        );
        if (
            _riskParams.COLL_GAS_COMPENSATION_CAP == 0
                || _riskParams.COLL_GAS_COMPENSATION_CAP > COLL_GAS_COMPENSATION_CAP
        ) {
            revert InvalidCollGasCompensationCap();
        }
        _requireBranchReadyForFinalization(_expectedUnderlying);

        CCR = _riskParams.CCR;
        MCR = _riskParams.MCR;
        BCR = _riskParams.BCR;
        SCR = _riskParams.SCR;
        LIQUIDATION_PENALTY_SP = _riskParams.LIQUIDATION_PENALTY_SP;
        LIQUIDATION_PENALTY_REDISTRIBUTION = _riskParams.LIQUIDATION_PENALTY_REDISTRIBUTION;
        riskParamsFinalized = true;

        borrowerOperations.syncRiskParams(_riskParams.CCR, _riskParams.MCR, _riskParams.BCR, _riskParams.SCR);
        troveManager.syncRiskParams(_riskParams);

        emit RiskParamsFinalized(
            _expectedUnderlying,
            _riskParams.CCR,
            _riskParams.MCR,
            _riskParams.BCR,
            _riskParams.SCR,
            _riskParams.LIQUIDATION_PENALTY_SP,
            _riskParams.LIQUIDATION_PENALTY_REDISTRIBUTION,
            _riskParams.COLL_GAS_COMPENSATION_CAP
        );
    }

    function _requireValidRiskParams(
        uint256 _ccr,
        uint256 _mcr,
        uint256 _bcr,
        uint256 _scr,
        uint256 _liquidationPenaltySP,
        uint256 _liquidationPenaltyRedistribution
    ) internal pure {
        if (_ccr <= 1e18 || _ccr >= 2e18) revert InvalidCCR();
        if (_mcr <= 1e18 || _mcr >= 2e18) revert InvalidMCR();
        if (_bcr < 5e16 || _bcr >= 50e16) revert InvalidBCR();
        if (_scr <= 1e18 || _scr >= 2e18) revert InvalidSCR();
        if (_liquidationPenaltySP < MIN_LIQUIDATION_PENALTY_SP) revert SPPenaltyTooLow();
        if (_liquidationPenaltySP > _liquidationPenaltyRedistribution) revert SPPenaltyGtRedist();
        if (_liquidationPenaltyRedistribution > MAX_LIQUIDATION_PENALTY_REDISTRIBUTION) revert RedistPenaltyTooHigh();
    }

    function _requireFinalizedRiskParams(
        uint256 _ccr,
        uint256 _mcr,
        uint256 _bcr,
        uint256 _scr,
        uint256 _liquidationPenaltySP,
        uint256 _liquidationPenaltyRedistribution
    ) internal pure {
        _requireValidRiskParams(_ccr, _mcr, _bcr, _scr, _liquidationPenaltySP, _liquidationPenaltyRedistribution);
        if (_scr >= _mcr || _mcr >= _ccr) revert InvalidCollateralRatioOrder();
        if (
            _mcr * (COLL_GAS_COMPENSATION_DIVISOR - 1)
                < (1e18 + _liquidationPenaltySP) * COLL_GAS_COMPENSATION_DIVISOR
        ) revert MCRBelowSPPenalty();
        if (1e18 + _liquidationPenaltyRedistribution > _mcr) revert MCRBelowRedistributionPenalty();
        if (1e18 + URGENT_REDEMPTION_BONUS > _scr) revert SCRBelowUrgentRedemptionBonus();
    }

    function _requireBranchReadyForFinalization(address _expectedUnderlying) internal view {
        if (_expectedUnderlying.code.length == 0) revert InvalidExpectedUnderlying();
        if (address(collToken).code.length == 0) revert InvalidDToken();

        IDToken dToken = IDToken(address(collToken));
        address dTokenUnderlying = address(dToken.underlying());
        if (dTokenUnderlying != _expectedUnderlying) {
            revert DTokenUnderlyingMismatch(_expectedUnderlying, dTokenUnderlying);
        }

        address vaultAddress = dToken.vault();
        if (vaultAddress.code.length == 0) revert InvalidVault();
        ICollateralVault vault = ICollateralVault(vaultAddress);
        address vaultDToken = address(vault.dToken());
        if (vaultDToken != address(dToken)) revert VaultDTokenMismatch(address(dToken), vaultDToken);
        address vaultUnderlying = address(vault.underlying());
        if (vaultUnderlying != _expectedUnderlying) {
            revert VaultUnderlyingMismatch(_expectedUnderlying, vaultUnderlying);
        }

        uint256 dTokenCap = dToken.cap();
        if (dTokenCap != 0) revert DTokenCapNotZero(dTokenCap);
        uint256 dTokenSupply = dToken.totalSupply();
        if (dTokenSupply != 0) revert DTokenSupplyNotZero(dTokenSupply);

        uint256 troveCount = troveManager.getTroveIdsCount();
        if (troveCount != 0) revert TrovesExist(troveCount);
        uint256 branchDebt = borrowerOperations.getEntireBranchDebt();
        if (branchDebt != 0) revert BranchDebtNotZero(branchDebt);
        uint256 branchColl = borrowerOperations.getEntireBranchColl();
        if (branchColl != 0) revert BranchCollNotZero(branchColl);
        uint256 stabilityPoolDeposits = stabilityPool.getTotalJpydfDeposits();
        if (stabilityPoolDeposits != 0) revert StabilityPoolNotEmpty(stabilityPoolDeposits);

        if (borrowerOperations.isOracleFailureShutdown()) revert OracleFailureShutdownActive();
        if (borrowerOperations.hasBeenShutDown() || troveManager.shutdownTime() != 0 || activePool.hasBeenShutDown()) {
            revert BranchAlreadyShutDown();
        }
    }
}
