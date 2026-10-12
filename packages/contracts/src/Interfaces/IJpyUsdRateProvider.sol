// SPDX-License-Identifier: MIT

pragma solidity 0.8.24;

interface IJpyUsdRateProvider {
    function fetchJpyUsdRate() external returns (uint256 rate, bool freezeExpired);
}
