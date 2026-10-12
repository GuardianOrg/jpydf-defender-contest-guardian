// SPDX-License-Identifier: BUSL-1.1

pragma solidity 0.8.24;

import {IERC20} from "openzeppelin-contracts/contracts/token/ERC20/IERC20.sol";

interface ISkyLitePsmWrapper {
    function gem() external view returns (address);
    function dai() external view returns (address);
    function tin() external view returns (uint256);
    function tout() external view returns (uint256);
    function sellGem(address receiver, uint256 usdcAmount) external returns (uint256 usdsOut);
    function buyGem(address receiver, uint256 usdcAmount) external returns (uint256 usdsIn);
}

interface ISkyUsdcSUsdsConverter {
    function usdcToken() external view returns (IERC20);
    function usdsToken() external view returns (IERC20);
    function psmWrapper() external view returns (ISkyLitePsmWrapper);

    function convertUsdcToUsds(uint256 usdcAmount, uint256 minUsdsOut, address receiver)
        external
        returns (uint256 usdsOut);

    function convertUsdsToUsdc(uint256 maxUsdsIn, uint256 minUsdcOut, address receiver)
        external
        returns (uint256 usdcOut);

    /// @notice Returns whether Sky explicitly halted the USDS-to-USDC route.
    /// @dev Invalid fees and failures while reading the wrapper are not classified as a halt.
    function isUsdsToUsdcRouteHalted() external view returns (bool);

    /// @notice Returns a numeric quote only while the reverse route is valid.
    /// @dev Reverts when Sky marks the route halted or reports an invalid fee;
    ///      ordinary sub-USDC-atom rounding may still return zero.
    function previewUsdsToUsdc(uint256 maxUsdsIn) external view returns (uint256 usdcOut);
}
