/// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.13;

import {DERC20} from "src/DERC20.sol";

contract TokenFactory {
    function create(
        string memory name,
        string memory symbol,
        uint256 totalSupply,
        address recipient,
        uint256 feeOnTransfer,
        address[] memory exemptFromFees,
        address feeCollector,
        address owner
    ) external returns (address) {
        return address(
            new DERC20(name, symbol, totalSupply, recipient, feeOnTransfer, exemptFromFees, feeCollector, owner)
        );
    }
}
