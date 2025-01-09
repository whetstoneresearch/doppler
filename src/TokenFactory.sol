/// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.24;

import { ITokenFactory } from "src/interfaces/ITokenFactory.sol";
import { DERC20 } from "src/DERC20.sol";

/// @dev Thrown when the sender is not the Airlock contract
error NotAirlock();

/**
 * @notice Data passed to the create function
 * @param name Name of the token
 * @param symbol Symbol of the token
 * @param yearlyMintCap Maximum amount of tokens that can be minted in a year
 * @param vestingDuration Duration of the vesting period
 * @param recipients List of recipients for the vesting schedule
 * @param amounts List of amounts for the vesting schedule
 */
// struct CreateData {
//     string name;
//     string symbol;
//     uint256 yearlyMintCap;
//     uint256 vestingDuration;
//     address[] recipients;
//     uint256[] amounts;
// }

/// @custom:security-contact security@whetstone.cc
contract TokenFactory is ITokenFactory {
    /// @notice Address of the Airlock contract
    address public immutable airlock;

    constructor(
        address airlock_
    ) {
        airlock = airlock_;
    }

    /**
     * @notice Creates a new DERC20 token
     * @param initialSupply Total supply of the token
     * @param recipient Address receiving the initial supply
     * @param owner Address receiving the ownership of the token
     * @param salt Salt used for the create2 deployment
     * @param data Creation parameters encoded as a `CreateData` struct
     */
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
