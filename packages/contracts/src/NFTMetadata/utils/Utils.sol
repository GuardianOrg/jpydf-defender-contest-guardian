//SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import "Solady/utils/LibString.sol";

library numUtils {
    function toLocale(string memory _wholeNumber) internal pure returns (string memory) {
        bytes memory b = bytes(_wholeNumber);
        uint256 len = b.length;
        if (len < 4) return _wholeNumber;

        uint256 numCommas = (len - 1) / 3;

        bytes memory result = new bytes(len + numCommas);

        uint256 j = result.length - 1;
        uint256 k = len;
        for (uint256 i = 0; i < len; i++) {
            result[j] = b[k - 1];
            j = j > 1 ? j - 1 : 0;
            k--;
            if (k > 0 && (len - k) % 3 == 0) {
                result[j] = ",";
                j = j > 1 ? j - 1 : 0;
            }
        }

        return string(result);
    }

    // returns a string representation of a number with commas, where result = _value / 10 ** _divisor
    function toLocaleString(uint256 _value, uint8 _divisor, uint8 _precision) internal pure returns (string memory) {
        uint256 whole;
        uint256 fraction;

        if (_divisor > 0) {
            whole = _value / 10 ** _divisor;
            // check if the divisor is less than the precision
            if (_divisor <= _precision) {
                fraction = (_value % 10 ** _divisor);
                // adjust fraction to be the same as the precision
                fraction = fraction * 10 ** (_precision - _divisor);

                // if whole is zero, then add another zero to the fraction, special case if the value is 1
                fraction = (whole == 0 && _value != 1) ? fraction * 10 : fraction;
            } else {
                fraction = (_value % 10 ** _divisor) / 10 ** (_divisor - _precision - 1);
            }
        } else {
            whole = _value;
        }

        string memory wholeStr = toLocale(LibString.toString(whole));

        if (fraction == 0) {
            if (whole > 0 && _precision > 0) wholeStr = string.concat(wholeStr, ".");
            for (uint8 i = 0; i < _precision; i++) {
                wholeStr = string.concat(wholeStr, "0");
            }

            return wholeStr;
        }

        string memory fractionStr = LibString.slice(LibString.toString(fraction), 0, _precision);

        // pad with leading zeros
        if (_precision > bytes(fractionStr).length) {
            uint256 len = _precision - bytes(fractionStr).length;
            string memory zeroStr = "";

            for (uint8 i = 0; i < len; i++) {
                zeroStr = string.concat(zeroStr, "0");
            }

            fractionStr = string.concat(zeroStr, fractionStr);
        }

        return string.concat(wholeStr, _precision > 0 ? "." : "", fractionStr);
    }
}

/// @notice Number formatting helpers and a shared empty-string constant for SVG assembly.
/// @author Modified from (https://github.com/w1nt3r-eth/hot-chain-svg/blob/main/contracts/Utils.sol) by w1nt3r-eth.

library utils {
    // used to simulate empty strings
    string internal constant NULL = "";
}
