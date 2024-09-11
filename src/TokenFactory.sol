/// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.13;

import {DERC20} from "src/DERC20.sol";

contract TokenFactory {
    function create(string memory name, string memory symbol, uint256 totalSupply, address recipient)
        external
        returns (address)
    {
        return address(new DERC20(name, symbol, totalSupply, recipient));
    }
}
