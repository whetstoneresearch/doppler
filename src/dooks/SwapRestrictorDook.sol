// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.26;

import { BaseDook } from "src/base/BaseDook.sol";

contract SwapRestrictorDook is BaseDook {
    constructor(address initializer, address hook) BaseDook(initializer, hook) { }
}
