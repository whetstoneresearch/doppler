/// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.13;

import { ITokenFactory } from "src/interfaces/ITokenFactory.sol";
import { DERC20 } from "src/DERC20.sol";

error NotAirlock();

contract TokenFactory is ITokenFactory {
    address public immutable airlock;

    constructor(
        address airlock_
    ) {
        airlock = airlock_;
    }

    function create(
        string calldata name,
        string calldata symbol,
        uint256 initialSupply,
        address recipient,
        address owner,
        address pool,
        bytes calldata,
        bytes32 salt
    ) external returns (address) {
        if (msg.sender != airlock) {
            revert NotAirlock();
        }

        return address(new DERC20{ salt: salt }(name, symbol, initialSupply, recipient, owner, pool));
    }
}
