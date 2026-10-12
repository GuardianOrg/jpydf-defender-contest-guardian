//SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

/// @notice Core SVG utility library which helps us construct onchain SVG's with a simple, web-like API.
/// @author Modified from (https://github.com/w1nt3r-eth/hot-chain-svg/blob/main/contracts/SVG.sol) by w1nt3r-eth.

library svg {
    /* GLOBAL CONSTANTS */
    string internal constant _SVG = 'xmlns="http://www.w3.org/2000/svg"';

    /* MAIN ELEMENTS */
    function _svg(string memory _props, string memory _children) internal pure returns (string memory) {
        return el("svg", string.concat(_SVG, " ", _props), _children);
    }

    function path(string memory _d, string memory _props) internal pure returns (string memory) {
        return el("path", string.concat(prop("d", _d), _props));
    }

    function text(string memory _props, string memory _children) internal pure returns (string memory) {
        return el("text", _props, _children);
    }

    function circle(string memory _props) internal pure returns (string memory) {
        return el("circle", _props);
    }

    function polygon(string memory _props) internal pure returns (string memory) {
        return el("polygon", _props);
    }

    function rect(string memory _props) internal pure returns (string memory) {
        return el("rect", _props);
    }

    /* COMMON */
    // A generic element, can be used to construct any SVG (or HTML) element
    function el(string memory _tag, string memory _props, string memory _children)
        internal
        pure
        returns (string memory)
    {
        return string.concat("<", _tag, " ", _props, ">", _children, "</", _tag, ">");
    }

    // A generic element, can be used to construct SVG (or HTML) elements without children
    function el(string memory _tag, string memory _props) internal pure returns (string memory) {
        return string.concat("<", _tag, " ", _props, "/>");
    }

    // an SVG attribute
    function prop(string memory _key, string memory _val) internal pure returns (string memory) {
        return string.concat(_key, "=", '"', _val, '" ');
    }
}
