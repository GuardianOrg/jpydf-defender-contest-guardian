// SPDX-License-Identifier: MIT

pragma solidity ^0.8.0;

interface IZapper {
    struct OpenTroveParams {
        address owner;
        uint256 ownerIndex;
        uint256 collAmount;
        uint256 jpydfAmount;
        uint256 upperHint;
        uint256 lowerHint;
        uint256 annualInterestRate;
        address batchManager;
        uint256 maxUpfrontFee;
        address addManager;
        address removeManager;
        address receiver;
    }

    function openTroveWithRawETH(OpenTroveParams calldata _params) external payable returns (uint256);
}
