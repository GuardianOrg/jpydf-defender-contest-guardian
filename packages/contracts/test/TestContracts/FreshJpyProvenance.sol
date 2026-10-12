// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

/// @dev Test-only provenance surface for sources whose tests are unrelated to JPY age.
abstract contract FreshJpyProvenance {
    function jpyUsdRateProvider() external view returns (address) {
        return address(this);
    }

    function lastGoodJpyUpdatedAt() external view virtual returns (uint256) {
        return block.timestamp;
    }
}
