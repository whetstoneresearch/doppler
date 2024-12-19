/// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.24;

import { ITokenFactory } from "src/interfaces/ITokenFactory.sol";
import { DERC20 } from "src/DERC20.sol";

error NotAirlock();

/// @custom:security-contact security@whetstone.cc
contract TokenFactory is ITokenFactory {
    address public immutable airlock;

    constructor(
        address airlock_
    ) {
        airlock = airlock_;
    }

    function create(
        uint256 initialSupply,
        address recipient,
        address owner,
        bytes32 salt,
        bytes calldata data
    ) external returns (address) {
        if (msg.sender != airlock) {
            revert NotAirlock();
        }

        (
            string memory name,
            string memory symbol,
            uint256 yearlyMintCap,
            uint256 vestingDuration,
            address[] memory recipients,
            uint256[] memory amounts
        ) = abi.decode(data, (string, string, uint256, uint256, address[], uint256[]));

        return address(
            new DERC20{ salt: salt }(
                name, symbol, initialSupply, recipient, owner, yearlyMintCap, vestingDuration, recipients, amounts
            )
        );
    }
}
