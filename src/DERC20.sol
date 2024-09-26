/// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.13;

import {ERC20} from "openzeppelin/token/ERC20/ERC20.sol";

/**
 * TODO:
 * - Add mint cap: bounded annual max inflation which can only go down
 * - Governor can only start minting after 365 days
 * - Fee on transfer
 */
contract DERC20 is ERC20 {
    constructor(string memory name_, string memory symbol_, uint256 totalSupply_, address recipient)
        ERC20(name_, symbol_)
    {
        _mint(recipient, totalSupply_);
    }
}
