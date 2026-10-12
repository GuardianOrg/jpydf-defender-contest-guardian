// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import "openzeppelin-contracts/contracts/token/ERC20/IERC20.sol";
import "openzeppelin-contracts/contracts/token/ERC20/utils/SafeERC20.sol";

import "./Interfaces/IAddressesRegistry.sol";
import "./Interfaces/IBorrowerOperations.sol";
import "./Interfaces/ITroveManager.sol";

/**
 * The purpose of this contract is to hold WETH tokens for liquidation gas compensation
 * (CORE-GP-FR-001 in documents/jp/protocol/product/spec/Liquity-v2-Core-Spec.md).
 * When a borrower opens a trove, an additional amount of WETH is pulled,
 * and sent to this contract.
 * When a borrower closes their active trove, this gas compensation is refunded
 * When a trove is liquidated, this gas compensation is paid to liquidator
 */
contract GasPool {
    using SafeERC20 for IERC20;

    constructor(IAddressesRegistry _addressesRegistry) {
        IWETH WETH = _addressesRegistry.WETH();
        IBorrowerOperations borrowerOperations = _addressesRegistry.borrowerOperations();
        ITroveManager troveManager = _addressesRegistry.troveManager();

        // Allow BorrowerOperations to refund gas compensation
        IERC20(address(WETH)).forceApprove(address(borrowerOperations), type(uint256).max);
        // Allow TroveManager to pay gas compensation to liquidator
        IERC20(address(WETH)).forceApprove(address(troveManager), type(uint256).max);
    }
}
