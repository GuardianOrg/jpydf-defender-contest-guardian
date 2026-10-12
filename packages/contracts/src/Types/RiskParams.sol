// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

struct RiskParams {
    uint256 CCR;
    uint256 MCR;
    uint256 BCR;
    uint256 SCR;
    uint256 LIQUIDATION_PENALTY_SP;
    uint256 LIQUIDATION_PENALTY_REDISTRIBUTION;
    uint256 COLL_GAS_COMPENSATION_CAP;
}
