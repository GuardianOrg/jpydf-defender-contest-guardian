// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

library V4RouterCodec {
    uint8 internal constant V4_SWAP = 0x10;

    uint8 internal constant SWAP_EXACT_IN_SINGLE = 0x06;
    uint8 internal constant SWAP_EXACT_OUT_SINGLE = 0x08;
    uint8 internal constant SETTLE_ALL = 0x0c;
    uint8 internal constant TAKE_ALL = 0x0f;
}
