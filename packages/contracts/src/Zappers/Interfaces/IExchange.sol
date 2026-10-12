// SPDX-License-Identifier: MIT

pragma solidity ^0.8.0;

interface IExchange {
    function swapFromJpydf(uint256 _jpydfAmount, uint256 _minCollAmount) external;

    function swapToJpydf(uint256 _collAmount, uint256 _minJpydfAmount) external returns (uint256);
}
