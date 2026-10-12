// SPDX-License-Identifier: MIT

pragma solidity ^0.8.0;

interface IDistributionCreator {
    struct CampaignParameters {
        bytes32 campaignId;
        address creator;
        address rewardToken;
        uint256 amount;
        uint32 campaignType;
        uint32 startTimestamp;
        uint32 duration;
        bytes campaignData;
    }

    function acceptConditions() external;

    function campaignId(CampaignParameters memory _campaignData) external returns (bytes32);

    function createCampaign(CampaignParameters memory _newCampaign) external returns (bytes32);
}
