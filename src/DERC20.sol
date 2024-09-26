/// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.13;

import {ERC20} from "openzeppelin/token/ERC20/ERC20.sol";
import {ERC20Votes} from "openzeppelin/token/ERC20/extensions/ERC20Votes.sol";
import {EIP712} from "openzeppelin/utils/cryptography/EIP712.sol";

/**
 * TODO:
 * - Add mint cap: bounded annual max inflation which can only go down
 * - Governor can only start minting after 365 days
 * - Fee on transfer
 */
contract DERC20 is ERC20Votes {
    constructor(string memory name_, string memory symbol_, uint256 totalSupply_, address recipient)
        EIP712(name_, symbol_)
        ERC20(name_, symbol_)
    {
        _mint(recipient, totalSupply_);
    }
}
