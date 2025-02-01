// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.24;

import { ITokenFactory } from "src/interfaces/ITokenFactory.sol";
import { DERC20 } from "src/DERC20.sol";

/// @dev Thrown when the sender is not the Airlock contract
error SenderNotAirlock();

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
     * @param data Creation parameters encoded as bytes
     */
    function create(
        uint256 initialSupply,
        uint256 vestedTotalAmount,
        address recipient,
        address owner,
        bytes32 salt,
        bytes calldata data
    ) external returns (address) {
        require(msg.sender == airlock, SenderNotAirlock());

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
                name,
                symbol,
                initialSupply,
                vestedTotalAmount,
                recipient,
                owner,
                yearlyMintCap,
                vestingDuration,
                recipients,
                amounts
            )
        );
    }
}
