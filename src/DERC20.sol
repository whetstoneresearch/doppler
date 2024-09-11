/// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.13;

import {ERC20} from "solady/tokens/ERC20.sol";

contract DopplerERC20 is ERC20 {
    string private _name;
    string private _symbol;

    constructor(string memory name_, string memory symbol_, uint256 totalSupply_, address recipient) ERC20() {
        _name = name_;
        _symbol = symbol_;
        _mint(recipient, totalSupply_);
    }

    /// @inheritdoc ERC20
    function name() public view override returns (string memory) {
        return _name;
    }

    /// @inheritdoc ERC20
    function symbol() public view override returns (string memory) {
        return _symbol;
    }
}
