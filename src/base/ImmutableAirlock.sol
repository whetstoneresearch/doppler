// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import { Airlock } from "../Airlock.sol";

/// @notice Thrown when the caller is not the Airlock contract
error SenderNotAirlock();

abstract contract ImmutableAirlock {
    Airlock public immutable airlock;

    constructor(address _airlock) {
        airlock = Airlock(payable(_airlock));
    }

    /// @notice Throws `SenderNotAirlock` if the caller is not the Airlock contract
    modifier onlyAirlock() {
        require(msg.sender == address(airlock), SenderNotAirlock());
        _;
    }
}
