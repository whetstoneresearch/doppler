/// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.24;

import { ITokenFactory } from "src/interfaces/ITokenFactory.sol";
import { DERC20 } from "src/DERC20.sol";

error NotAirlock();

struct CreateData {
    string name;
    string symbol;
    uint256 yearlyMintCap;
    uint256 vestingDuration;
    address[] recipients;
    uint256[] amounts;
}

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

        CreateData memory createData = abi.decode(data, (CreateData));

        return address(
            new DERC20{ salt: salt }(
                createData.name,
                createData.symbol,
                initialSupply,
                recipient,
                owner,
                createData.yearlyMintCap,
                createData.vestingDuration,
                createData.recipients,
                createData.amounts
            )
        );
    }
}
