// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.24;

import { DERC20 } from "src/DERC20.sol";
import { ImmutableAirlock } from "src/base/ImmutableAirlock.sol";
import { ITokenFactory } from "src/interfaces/ITokenFactory.sol";

/// @custom:security-contact security@whetstone.cc
contract TokenFactory is ITokenFactory, ImmutableAirlock {
    constructor(address airlock_) ImmutableAirlock(airlock_) { }

    /**
     * @notice Creates a new DERC20 token
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
        (
            string memory name,
            string memory symbol,
            uint256 yearlyMintCap,
            uint256 vestingDuration,
            address[] memory recipients,
            uint256[] memory amounts,
            string memory tokenURI
        ) = abi.decode(data, (string, string, uint256, uint256, address[], uint256[], string));

        return address(
            new DERC20{ salt: salt }(
                name,
                symbol,
                initialSupply,
                recipient,
                owner,
                yearlyMintCap,
                vestingDuration,
                recipients,
                amounts,
                tokenURI
            )
        );
    }
}
