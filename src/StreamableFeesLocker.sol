// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.24;

import { IPositionManager } from "@v4-periphery/interfaces/IPositionManager.sol";
import { Actions } from "@v4-periphery/libraries/Actions.sol";
import { PoolKey } from "@v4-core/types/PoolKey.sol";

struct LockData {
    address beneficiary;
    uint256 unlockDate;
}

contract StreamableFeesLocker {
    IPositionManager public immutable positionManager;

    mapping(uint256 tokenId => LockData data) public getLockData;

    constructor(
        IPositionManager positionManager_
    ) {
        positionManager = positionManager_;
    }

    function lock(uint256 tokenId, address beneficiary) external {
        getLockData[tokenId] = LockData({ beneficiary: address(beneficiary), unlockDate: block.timestamp + 30 days });
    }

    function claim(
        uint256 tokenId
    ) external {
        bytes memory actions = abi.encodePacked(uint8(Actions.DECREASE_LIQUIDITY), uint8(Actions.TAKE_PAIR));
        bytes[] memory params = new bytes[](2);
        params[0] = abi.encode(tokenId, 0, 0, 0, new bytes(0));

        (PoolKey memory poolKey,) = positionManager.getPoolAndPositionInfo(tokenId);
        params[1] = abi.encode(poolKey.currency0, poolKey.currency1, address(this));
        positionManager.modifyLiquidities(abi.encode(actions, params), block.timestamp);

        address integrator;
        // Transfers the fees to the integrator
        poolKey.currency0.transfer(integrator, poolKey.currency0.balanceOfSelf() / 20);
        poolKey.currency1.transfer(integrator, poolKey.currency1.balanceOfSelf() / 20);

        address beneficiary = getLockData[tokenId].beneficiary;
        poolKey.currency0.transfer(beneficiary, poolKey.currency0.balanceOfSelf());
        poolKey.currency1.transfer(beneficiary, poolKey.currency1.balanceOfSelf());
    }

    function unlock(
        uint256 tokenId
    ) external { }
}
