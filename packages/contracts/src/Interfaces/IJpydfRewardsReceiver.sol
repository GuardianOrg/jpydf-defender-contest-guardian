// SPDX-License-Identifier: MIT

pragma solidity ^0.8.0;

interface IJpydfRewardsReceiver {
    function triggerJpydfRewards(uint256 _jpydfYield) external;
}
