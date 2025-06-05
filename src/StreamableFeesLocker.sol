// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.24;

import { IPositionManager } from "@v4-periphery/interfaces/IPositionManager.sol";
import { Actions } from "@v4-periphery/libraries/Actions.sol";
import { PoolKey } from "@v4-core/types/PoolKey.sol";
import { ERC721TokenReceiver } from "@solmate/tokens/ERC721.sol";

struct BeneficiaryData {
    address beneficiary;
    uint256 shares;
}

struct LockData {
    BeneficiaryData[] beneficiaries;
    uint256 unlockDate;
}

event Lock(uint256 indexed tokenId, BeneficiaryData[] beneficiaries, uint256 unlockDate);

contract StreamableFeesLocker is ERC721TokenReceiver {
    IPositionManager public immutable positionManager;

    mapping(uint256 tokenId => LockData data) public getLockData;

    constructor(
        IPositionManager positionManager_
    ) {
        positionManager = positionManager_;
    }

    function onERC721Received(
        address,
        address,
        uint256 tokenId,
        bytes calldata lockData
    ) external override returns (bytes4) {
        require(msg.sender == address(positionManager), "Only PositionManager can call this");
        (BeneficiaryData[] memory beneficiaries) = abi.decode(lockData, (BeneficiaryData[]));

        require(beneficiaries.length > 0, "No beneficiaries provided");

        uint256 totalShares;

        for (uint256 i; i != beneficiaries.length; ++i) {
            require(beneficiaries[i].beneficiary != address(0), "Beneficiary cannot be zero address");
            require(beneficiaries[i].shares > 0, "Shares must be greater than zero");
            totalShares += beneficiaries[i].shares;
        }

        require(totalShares == 1e18, "Total shares must equal 1e18");

        getLockData[tokenId] = LockData({ beneficiaries: beneficiaries, unlockDate: block.timestamp + 30 days });

        return ERC721TokenReceiver.onERC721Received.selector;
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

        BeneficiaryData[] memory beneficiaries = getLockData[tokenId].beneficiaries;

        uint256 length = beneficiaries.length;

        for (uint256 i; i != length; ++i) {
            address beneficiary = beneficiaries[i].beneficiary;
            uint256 shares = beneficiaries[i].shares;

            // TODO: This might leave some dust, so we might want to check the pre / post balances
            // and send the dust to the last beneficiary
            uint256 amount0 = poolKey.currency0.balanceOfSelf() * shares / 1e18;
            uint256 amount1 = poolKey.currency1.balanceOfSelf() * shares / 1e18;

            poolKey.currency0.transfer(beneficiary, amount0);
            poolKey.currency1.transfer(beneficiary, amount1);
        }
    }

    function unlock(
        uint256 tokenId
    ) external { }
}
