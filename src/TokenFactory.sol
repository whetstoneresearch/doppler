/// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.13;

import { ITokenFactory } from "src/interfaces/ITokenFactory.sol";
import { DERC20 } from "src/DERC20.sol";

contract TokenFactory is ITokenFactory {
    function create(
        string memory name,
        string memory symbol,
        uint256 initialSupply,
        address recipient,
        address owner,
        address pool,
        bytes memory,
        bytes32 salt
    ) external returns (address) {
        return address(new DERC20{ salt: salt }(name, symbol, initialSupply, recipient, owner, pool));
    }
}
