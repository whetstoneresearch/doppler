// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.24;

import { LibClone } from "@solady/utils/LibClone.sol";
import { ImmutableAirlock } from "src/base/ImmutableAirlock.sol";
import { ITokenFactory } from "src/interfaces/ITokenFactory.sol";
import { CloneERC20Votes } from "src/CloneERC20Votes.sol";

/**
 * @title CloneERC20VotesFactory
 * @author Whetstone Research
 * @notice Deploys new CloneERC20Votes tokens using the minimal proxy pattern (EIP-1167)
 * @custom:security-contact security@whetstone.cc
 */
contract CloneERC20VotesFactory is ImmutableAirlock, ITokenFactory {
    /// @notice Address of the implementation contract which will be cloned
    address public immutable IMPLEMENTATION;

    /// @param airlock_ Address of the Airlock contract
    constructor(
        address airlock_
    ) ImmutableAirlock(airlock_) {
        IMPLEMENTATION = address(new CloneERC20Votes());
        CloneERC20Votes(IMPLEMENTATION)
            .initialize("", "", 0, address(0), address(0), 0, 0, new address[](0), new uint256[](0), "");
    }

    /**
     * @notice Deploys a new ERC20 token
     * @dev This function (only callable by the Airlock) clones the implementation contract
     * and initializes it with the provided parameters
     * @param initialSupply Initial supply of the token
     * @param recipient Address to receive the initial supply
     * @param owner Address receiving owner privileges
     * @param salt Salt for deterministic deployment
     * @param tokenData Encoded token parameters:
     * - name: Name of the token
     * - symbol: Symbol of the token
     * - yearlyMintRate (optional): Yearly mint rate (in WAD)
     * - recipients (optional): Addresses to receive vested tokens
     * - amounts (optional): Amounts to be vested to each recipient
     * - vestingDuration (optional): Duration of the vesting period in seconds
     * - tokenURI (optional): Token URI for metadata
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
            uint256 vestingDuration,
            address[] memory recipients,
            uint256[] memory amounts,
            string memory tokenURI
        ) = abi.decode(tokenData, (string, string, uint256, uint256, address[], uint256[], string));

        asset = LibClone.cloneDeterministic(IMPLEMENTATION, salt);
        CloneERC20Votes(asset)
            .initialize(
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
