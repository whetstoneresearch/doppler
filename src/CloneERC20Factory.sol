// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.24;

import { LibClone } from "solady/utils/LibClone.sol";
import { ImmutableAirlock } from "src/base/ImmutableAirlock.sol";
import { ITokenFactory } from "src/interfaces/ITokenFactory.sol";
import { CloneERC20 } from "src/CloneERC20.sol";

contract CloneERC20Factory is ImmutableAirlock, ITokenFactory {
    address public immutable IMPLEMENTATION;

    constructor(
        address airlock_
    ) ImmutableAirlock(airlock_) {
        IMPLEMENTATION = address(new CloneERC20());
        CloneERC20(IMPLEMENTATION).initialize(
            "", "", 0, address(0), address(0), 0, 0, new address[](0), new uint256[](0), ""
        );
    }

    function create(
        uint256 initialSupply,
        address recipient,
        address owner,
        bytes32 salt,
        bytes calldata tokenData
    ) external onlyAirlock returns (address asset) {
        (
            string memory name,
            string memory symbol,
            uint256 yearlyMintRate,
            uint256 vestingDuration,
            address[] memory recipients,
            uint256[] memory amounts,
            string memory tokenURI
        ) = abi.decode(tokenData, (string, string, uint256, uint256, address[], uint256[], string));

        asset = LibClone.cloneDeterministic(IMPLEMENTATION, salt);
        CloneERC20(asset).initialize(
            name,
            symbol,
            initialSupply,
            recipient,
            owner,
            yearlyMintRate,
            vestingDuration,
            recipients,
            amounts,
            tokenURI
        );
    }
}
