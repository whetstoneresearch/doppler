// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.24;

import { LibClone } from "solady/utils/LibClone.sol";
import { ImmutableAirlock } from "src/base/ImmutableAirlock.sol";
import { ITokenFactory } from "src/interfaces/ITokenFactory.sol";
import { CloneDERC20V2, VestingSchedule } from "src/tokens/CloneDERC20V2.sol";

/**
 * @title CloneDERC20V2Factory
 * @author Whetstone Research
 * @notice Deploys new CloneDERC20V2 tokens using the minimal proxy pattern (EIP-1167)
 * @custom:security-contact security@whetstone.cc
 */
contract CloneDERC20V2Factory is ImmutableAirlock, ITokenFactory {
    /// @notice Address of the implementation contract which will be cloned
    address public immutable IMPLEMENTATION;

    /// @param airlock_ Address of the Airlock contract
    constructor(address airlock_) ImmutableAirlock(airlock_) {
        IMPLEMENTATION = address(new CloneDERC20V2());
        CloneDERC20V2(IMPLEMENTATION)
            .initialize(
                "",
                "",
                0,
                address(0),
                address(0),
                0,
                new VestingSchedule[](0),
                new address[](0),
                new uint256[](0),
                new uint256[](0),
                ""
            );
    }

    /**
     * @notice Deploys a new CloneDERC20V2 token
     * @dev This function (only callable by the Airlock) clones the implementation contract
     * and initializes it with the provided parameters
     * @param initialSupply Initial supply of the token
     * @param recipient Address to receive the initial supply
     * @param owner Address receiving owner privileges
     * @param salt Salt for deterministic deployment
     * @param tokenData Creation parameters encoded as bytes:
     * - string name
     * - string symbol
     * - uint256 yearlyMintRate
     * - VestingSchedule[] schedules
     * - address[] beneficiaries
     * - uint256[] scheduleIds
     * - uint256[] amounts
     * - string tokenURI
     * @return asset Address of the newly deployed token
     */
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
            VestingSchedule[] memory schedules,
            address[] memory beneficiaries,
            uint256[] memory scheduleIds,
            uint256[] memory amounts,
            string memory tokenURI
        ) = abi.decode(tokenData, (string, string, uint256, VestingSchedule[], address[], uint256[], uint256[], string));

        asset = LibClone.cloneDeterministic(IMPLEMENTATION, salt);
        CloneDERC20V2(asset)
            .initialize(
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
            );
    }
}
