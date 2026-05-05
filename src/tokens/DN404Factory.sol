// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.24;

import { ImmutableAirlock } from "src/base/ImmutableAirlock.sol";
import { DopplerDN404 } from "src/dn404/DopplerDN404.sol";
import { ITokenFactory } from "src/interfaces/ITokenFactory.sol";

contract DN404Factory is ITokenFactory, ImmutableAirlock {
    event DN404Created(address indexed token, address indexed collection, address indexed owner, uint256 initialSupply);

    constructor(address airlock_) ImmutableAirlock(airlock_) { }

    function create(
        uint256 initialSupply,
        address recipient,
        address owner,
        bytes32 salt,
        bytes calldata data
    ) external onlyAirlock returns (address) {
        (string memory name, string memory symbol, string memory baseURI, uint256 unit) =
            abi.decode(data, (string, string, string, uint256));

        DopplerDN404 token =
            new DopplerDN404{ salt: salt }(name, symbol, initialSupply, recipient, owner, baseURI, unit);
        address collection = token.mirrorERC721();

        emit DN404Created(address(token), collection, owner, initialSupply);
        return address(token);
    }
}
