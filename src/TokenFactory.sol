/// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.13;

import {ITokenFactory} from "src/interfaces/ITokenFactory.sol";
import {DERC20} from "src/DERC20.sol";

contract TokenFactory is ITokenFactory {
    function create(
        string memory name,
        string memory symbol,
        uint256 totalSupply,
        address recipient,
        address owner,
        bytes memory tokenData
    ) external returns (address) {
        (uint256 feeOnTransfer, address[] memory exemptFromFees, address feeCollector) =
            abi.decode(tokenData, (uint256, address[], address));

        return address(
            new DERC20(name, symbol, totalSupply, recipient, feeOnTransfer, exemptFromFees, feeCollector, owner)
        );
    }
}
