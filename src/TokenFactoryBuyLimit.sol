// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.24;

import { IPoolManager } from "@v4-core/interfaces/IPoolManager.sol";
import { ITokenFactory } from "src/interfaces/ITokenFactory.sol";
import { Airlock } from "src/Airlock.sol";
import { DERC20BuyLimit } from "src/DERC20BuyLimit.sol";
import { ImmutableAirlock } from "src/base/ImmutableAirlock.sol";

/// @custom:security-contact security@whetstone.cc
contract TokenFactoryBuyLimit is ITokenFactory, ImmutableAirlock {
    constructor(
        address airlock_
    ) ImmutableAirlock(airlock_) { }

    /**
     * @notice Creates a new DERC20BuyLimit token
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
            string memory tokenURI,
            IPoolManager buyLimitedPoolManager_,
            uint256 buyLimitEnd_,
            uint256 spendLimitAmount_
        ) = abi.decode(
            data, (string, string, uint256, uint256, address[], uint256[], string, IPoolManager, uint256, uint256)
        );

        return address(
            new DERC20BuyLimit{ salt: salt }(
                name,
                symbol,
                initialSupply,
                recipient,
                owner,
                yearlyMintCap,
                vestingDuration,
                recipients,
                amounts,
                tokenURI,
                buyLimitedPoolManager_,
                buyLimitEnd_,
                spendLimitAmount_,
                address(airlock)
            )
        );
    }
}
