// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.24;

import { ITokenFactory } from "src/interfaces/ITokenFactory.sol";
import { ImmutableAirlock } from "src/base/ImmutableAirlock.sol";
import { DopplerDN404 } from "src/dn404/DopplerDN404.sol";

/// @custom:security-contact security@whetstone.cc
contract DN404Factory is ITokenFactory, ImmutableAirlock {

    event DN404Created(address indexed token, address indexed collection, address indexed owner, uint256 initialSupply);

    constructor(
        address airlock_
    ) ImmutableAirlock(airlock_) { }

    /**
     * @notice Creates a new DN404-based token
     * @param initialSupply Total supply of the token
     * @param recipient Address receiving the initial supply
     * @param owner Address receiving the ownership of the token
     * @param salt Salt used for the create2 deployment
     * @param data Creation parameters encoded as bytes
     */
    function create(
        uint256 initialSupply,
        address recipient,
        address owner,
        bytes32 salt,
        bytes calldata data
    ) external onlyAirlock returns (address) {
        // Decode name, symbol, baseURI, and unit from the data
        (string memory name,
         string memory symbol,
         string memory baseURI,
         uint256 unit
        ) = abi.decode(data, (string, string, string, uint256));

        //return address(new DopplerDN404{ salt: salt }(name, symbol, initialSupply, recipient, owner, baseURI, unit));
        DopplerDN404 token = new DopplerDN404{ salt: salt }(name, symbol, initialSupply, recipient, owner, baseURI, unit);
        address collection = token.mirrorERC721();

        emit DN404Created(address(token), collection, owner, initialSupply);
        return address(token);
    }
}
