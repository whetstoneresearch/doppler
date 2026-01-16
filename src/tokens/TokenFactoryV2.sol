// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.24;

import { ImmutableAirlock } from "src/base/ImmutableAirlock.sol";
import { ITokenFactory } from "src/interfaces/ITokenFactory.sol";
import { DERC20V2, VestingSchedule } from "src/tokens/DERC20V2.sol";

/// @custom:security-contact security@whetstone.cc
contract TokenFactoryV2 is ITokenFactory, ImmutableAirlock {
    constructor(address airlock_) ImmutableAirlock(airlock_) { }

    /**
     * @notice Creates a new DERC20V2 token with multi-schedule vesting
     * @param initialSupply Total supply of the token
     * @param recipient Address receiving the non-vested initial supply
     * @param owner Address receiving the ownership of the token
     * @param salt Salt used for the create2 deployment
     * @param data Creation parameters encoded as bytes:
     *             - string name
     *             - string symbol
     *             - uint256 yearlyMintRate
     *             - VestingSchedule[] schedules
     *             - address[] beneficiaries
     *             - uint256[] scheduleIds
     *             - uint256[] amounts
     *             - string tokenURI
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
            uint256 yearlyMintRate,
            VestingSchedule[] memory schedules,
            address[] memory beneficiaries,
            uint256[] memory scheduleIds,
            uint256[] memory amounts,
            string memory tokenURI
        ) = abi.decode(data, (string, string, uint256, VestingSchedule[], address[], uint256[], uint256[], string));

        return address(
            new DERC20V2{ salt: salt }(
                name,
                symbol,
                initialSupply,
                recipient,
                owner,
                yearlyMintRate,
                schedules,
                beneficiaries,
                scheduleIds,
                amounts,
                tokenURI
            )
        );
    }
}
