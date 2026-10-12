// SPDX-License-Identifier: MIT

pragma solidity 0.8.24;

import {IERC20} from "openzeppelin-contracts/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "openzeppelin-contracts/contracts/token/ERC20/utils/SafeERC20.sol";
import {ReentrancyGuard} from "openzeppelin-contracts/contracts/security/ReentrancyGuard.sol";

import {IDistributionCreator} from "src/Interfaces/IDistributionCreator.sol";
import {IInitiative} from "src/Interfaces/IInitiative.sol";

/**
 * @title UniV4MerklInitiative
 * @notice Merkl campaign creator for Uniswap v4 JPYdf liquidity incentives.
 * @custom:security-contact security@deltaforesight.xyz
 */
contract UniV4MerklInitiative is IInitiative, ReentrancyGuard {
    using SafeERC20 for IERC20;

    uint32 public constant CAMPAIGN_TYPE = 13;
    bool public constant IS_OUT_OF_RANGE_INCENTIVIZED = false;

    address public immutable allocator;
    IERC20 public immutable jpydfToken;
    IDistributionCreator public immutable merklDistributionCreator;
    address public immutable CAMPAIGN_CREATOR;
    uint256 public immutable CAMPAIGN_JPYDF_AMOUNT_THRESHOLD;
    uint256 public immutable CAMPAIGN_CREATION_WINDOW;
    bytes32 public immutable UNIV4_POOL_ID;
    uint32 public immutable WEIGHT_FEES;
    uint32 public immutable WEIGHT_TOKEN_0;
    uint32 public immutable WEIGHT_TOKEN_1;
    uint256 public immutable EPOCH_START;
    uint256 public immutable EPOCH_DURATION;

    mapping(uint256 => bytes32) public campaignIdByStartTimestamp;

    event NewMerklCampaign(uint256 indexed epoch, uint256 amount, bytes32 campaignId);
    event MerklCampaignAlreadyCreated(
        uint256 indexed epoch, uint256 indexed startTimestamp, uint256 amount, bytes32 campaignId
    );

    error UniV4MerklInitiative__ZeroAddress();
    error UniV4MerklInitiative__EpochStartInFuture();
    error UniV4MerklInitiative__InvalidWeights();
    error UniV4MerklInitiative__DurationTooLarge();
    error UniV4MerklInitiative__ZeroCampaignThreshold();
    error UniV4MerklInitiative__InvalidCampaignCreationWindow();
    error UniV4MerklInitiative__PoolIdZero();
    error UniV4MerklInitiative__ZeroCampaignId();
    error UniV4MerklInitiative__CampaignCreationTooEarly(uint256 earliestPublicCreation);
    error UniV4MerklInitiative__TimestampTooLarge(uint256 timestamp);
    error UniV4MerklInitiative__DependencyNotContract(address dependency);

    constructor(
        address _allocator,
        IERC20 _jpydfToken,
        IDistributionCreator _merklDistributionCreator,
        address _campaignCreator,
        uint256 _campaignJpydfAmountThreshold,
        uint256 _campaignCreationWindow,
        bytes32 _uniV4PoolId,
        uint32 _weightFees,
        uint32 _weightToken0,
        uint32 _weightToken1,
        uint256 _epochStart,
        uint256 _epochDuration
    ) {
        if (_allocator == address(0)) revert UniV4MerklInitiative__ZeroAddress();
        if (address(_jpydfToken) == address(0)) revert UniV4MerklInitiative__ZeroAddress();
        if (address(_merklDistributionCreator) == address(0)) revert UniV4MerklInitiative__ZeroAddress();
        if (_campaignCreator == address(0)) revert UniV4MerklInitiative__ZeroAddress();
        _requireContractDependency(address(_jpydfToken));
        _requireContractDependency(address(_merklDistributionCreator));
        _requireEpochConfig(_epochStart, _epochDuration);
        _requireCampaignConfig(_campaignJpydfAmountThreshold, _campaignCreationWindow, _epochDuration, _uniV4PoolId);
        _requireWeights(_weightFees, _weightToken0, _weightToken1);

        allocator = _allocator;
        jpydfToken = _jpydfToken;
        merklDistributionCreator = _merklDistributionCreator;
        CAMPAIGN_CREATOR = _campaignCreator;
        CAMPAIGN_JPYDF_AMOUNT_THRESHOLD = _campaignJpydfAmountThreshold;
        CAMPAIGN_CREATION_WINDOW = _campaignCreationWindow;
        UNIV4_POOL_ID = _uniV4PoolId;
        WEIGHT_FEES = _weightFees;
        WEIGHT_TOKEN_0 = _weightToken0;
        WEIGHT_TOKEN_1 = _weightToken1;
        EPOCH_START = _epochStart;
        EPOCH_DURATION = _epochDuration;

        _merklDistributionCreator.acceptConditions();
    }

    /*//////////////////////////////////////////////////////////////
                  USER-FACING STATE-CHANGING FUNCTIONS
    //////////////////////////////////////////////////////////////*/

    function createCampaign() external nonReentrant returns (bytes32 campaignId) {
        uint256 amount = jpydfToken.balanceOf(address(this));
        if (amount < CAMPAIGN_JPYDF_AMOUNT_THRESHOLD) return bytes32(0);

        uint256 currentEpoch = epoch();
        uint256 campaignStart = EPOCH_START + currentEpoch * EPOCH_DURATION;
        if (campaignStart > type(uint32).max) revert UniV4MerklInitiative__TimestampTooLarge(campaignStart);

        bytes32 existingCampaignId = campaignIdByStartTimestamp[campaignStart];
        if (existingCampaignId != bytes32(0)) {
            emit MerklCampaignAlreadyCreated(currentEpoch, campaignStart, amount, existingCampaignId);
            return bytes32(0);
        }
        _requireCampaignCreationAllowed(campaignStart);

        jpydfToken.forceApprove(address(merklDistributionCreator), amount);
        campaignId = merklDistributionCreator.createCampaign(
            IDistributionCreator.CampaignParameters({
                campaignId: bytes32(0),
                creator: address(this),
                rewardToken: address(jpydfToken),
                amount: amount,
                campaignType: CAMPAIGN_TYPE,
                startTimestamp: uint32(campaignStart),
                duration: uint32(EPOCH_DURATION),
                campaignData: getCampaignData()
            })
        );
        if (campaignId == bytes32(0)) revert UniV4MerklInitiative__ZeroCampaignId();
        campaignIdByStartTimestamp[campaignStart] = campaignId;
        jpydfToken.forceApprove(address(merklDistributionCreator), 0);

        emit NewMerklCampaign(currentEpoch, amount, campaignId);
    }

    function onRegisterInitiative(uint256) external override {}

    function onUnregisterInitiative(uint256) external override {}

    function onAfterAllocateLQTY(
        uint256,
        address,
        IInitiative.UserState calldata,
        IInitiative.Allocation calldata,
        IInitiative.InitiativeState calldata
    ) external override {}

    function onClaimForInitiative(uint256, uint256) external override {}

    /*//////////////////////////////////////////////////////////////
                    USER-FACING READ-ONLY FUNCTIONS
    //////////////////////////////////////////////////////////////*/

    function epoch() public view returns (uint256) {
        return ((block.timestamp - EPOCH_START) / EPOCH_DURATION) + 1;
    }

    function epochStart() public view returns (uint256) {
        return EPOCH_START + (epoch() - 1) * EPOCH_DURATION;
    }

    function nextCampaignStart() public view returns (uint256) {
        return EPOCH_START + epoch() * EPOCH_DURATION;
    }

    function publicCampaignCreationStart() public view returns (uint256) {
        return nextCampaignStart() - CAMPAIGN_CREATION_WINDOW;
    }

    function canCreateCampaign(address caller) public view returns (bool) {
        if (jpydfToken.balanceOf(address(this)) < CAMPAIGN_JPYDF_AMOUNT_THRESHOLD) return false;
        uint256 campaignStart = nextCampaignStart();
        if (campaignIdByStartTimestamp[campaignStart] != bytes32(0)) return false;
        if (caller == CAMPAIGN_CREATOR) return true;
        return block.timestamp >= publicCampaignCreationStart();
    }

    function getCampaignData() public view returns (bytes memory) {
        return bytes.concat(
            abi.encode(416, IS_OUT_OF_RANGE_INCENTIVIZED, WEIGHT_FEES, WEIGHT_TOKEN_0, WEIGHT_TOKEN_1, 480, 512, 544),
            abi.encode(0, 0, 0, 0, 576, 32, UNIV4_POOL_ID, 0, 0, 0, 0)
        );
    }

    function _requireCampaignCreationAllowed(uint256 campaignStart) internal view {
        if (msg.sender == CAMPAIGN_CREATOR) return;

        uint256 earliestPublicCreation = campaignStart - CAMPAIGN_CREATION_WINDOW;
        if (block.timestamp < earliestPublicCreation) {
            revert UniV4MerklInitiative__CampaignCreationTooEarly(earliestPublicCreation);
        }
    }

    function _requireContractDependency(address dependency) internal view {
        if (dependency.code.length == 0) revert UniV4MerklInitiative__DependencyNotContract(dependency);
    }

    function _requireEpochConfig(uint256 epochStart_, uint256 epochDuration_) internal view {
        if (epochStart_ > block.timestamp) revert UniV4MerklInitiative__EpochStartInFuture();
        if (epochDuration_ == 0 || epochDuration_ > type(uint32).max) {
            revert UniV4MerklInitiative__DurationTooLarge();
        }
    }

    function _requireCampaignConfig(
        uint256 campaignJpydfAmountThreshold_,
        uint256 campaignCreationWindow_,
        uint256 epochDuration_,
        bytes32 uniV4PoolId_
    ) internal pure {
        if (campaignJpydfAmountThreshold_ == 0) revert UniV4MerklInitiative__ZeroCampaignThreshold();
        if (campaignCreationWindow_ == 0 || campaignCreationWindow_ >= epochDuration_) {
            revert UniV4MerklInitiative__InvalidCampaignCreationWindow();
        }
        if (uniV4PoolId_ == bytes32(0)) revert UniV4MerklInitiative__PoolIdZero();
    }

    function _requireWeights(uint32 weightFees_, uint32 weightToken0_, uint32 weightToken1_) internal pure {
        if (uint256(weightFees_) + uint256(weightToken0_) + uint256(weightToken1_) != 10_000) {
            revert UniV4MerklInitiative__InvalidWeights();
        }
    }
}
