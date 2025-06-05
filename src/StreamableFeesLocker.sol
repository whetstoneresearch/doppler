// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.24;

import { IPositionManager } from "@v4-periphery/interfaces/IPositionManager.sol";
import { Actions } from "@v4-periphery/libraries/Actions.sol";
import { PoolKey } from "@v4-core/types/PoolKey.sol";
import { ERC721TokenReceiver } from "@solmate/tokens/ERC721.sol";
import { EnumerableSet } from "@openzeppelin/contracts/utils/structs/EnumerableSet.sol";

struct BeneficiaryData {
    address beneficiary;
    uint64 shares;
    uint256 amountClaimed0;
    uint256 amountClaimed1;
}

struct PositionData {
    BeneficiaryData[] beneficiaries;
    uint64 startDate;
    bool isUnlocked;
    address recipient;
}

event Lock(uint256 indexed tokenId, BeneficiaryData[] beneficiaries, uint256 unlockDate);

event Unlock(uint256 indexed tokenId, address recipient);

event Release(uint256 indexed tokenId, address beneficiary, uint256 amount0, uint256 amount1);

event UpdateBeneficiary(uint256 indexed tokenId, address oldBeneficiary, address newBeneficiary);

uint256 constant WAD = 1e18;

uint256 constant LOCK_DURATION = 30 days;

contract StreamableFeesLocker is ERC721TokenReceiver, EnumerableSet {
    IPositionManager public immutable positionManager;

    mapping(uint256 tokenId => PositionData) public positions;
    mapping(address beneficiary => mapping(Currency currency => uint256 releasableBalance)) public beneficiariesClaims;

    constructor(
        IPositionManager positionManager_
    ) {
        positionManager = positionManager_;
    }

    modifier onlyPositionManager() {
        if (msg.sender != address(positionManager)) {
            revert("StreamableFeesLocker: ONLY_POSITION_MANAGER");
        }
        _;
    }

    function onERC721Received(
        address,
        address,
        uint256 tokenId,
        bytes calldata positionData
    ) external override onlyPositionManager returns (bytes4) {
        (address recipient, BeneficiaryData[] memory beneficiaries) =
            abi.decode(positionData, (address, BeneficiaryData[]));
        require(beneficiaries.length > 0, "No beneficiaries provided");

        uint256 totalShares;
        for (uint256 i; i != beneficiaries.length; ++i) {
            require(
                beneficiaries[i].beneficiary != address(0), "StreamableFeesLocker: BENEFICIARY_CANNOT_BE_ZERO_ADDRESS"
            );
            require(beneficiaries[i].shares > 0, "StreamableFeesLocker: SHARES_MUST_BE_GREATER_THAN_ZERO");
            totalShares += beneficiaries[i].shares;
        }

        require(totalShares == WAD, "StreamableFeesLocker: TOTAL_SHARES_NOT_EQUAL_TO_WAD");

        positions[tokenId] = PositionData({
            beneficiaries: beneficiaries,
            startDate: block.timestamp,
            isUnlocked: false,
            recipient: recipient
        });

        emit Lock(tokenId, beneficiaries, block.timestamp + LOCK_DURATION);

        return ERC721TokenReceiver.onERC721Received.selector;
    }

    function accrueFees(
        uint256 tokenId
    ) external {
        // Get pool info
        (PoolKey memory poolKey,) = positionManager.getPoolAndPositionInfo(tokenId);

        // Get the amount of fees to claim
        bytes memory actions = abi.encodePacked(uint8(Actions.DECREASE_LIQUIDITY), uint8(Actions.TAKE_PAIR));
        bytes[] memory params = new bytes[](2);
        params[0] = abi.encode(tokenId, 0, 0, 0, new bytes(0));
        params[1] = abi.encode(poolKey.currency0, poolKey.currency1, address(this));

        positionManager.modifyLiquidities(abi.encode(actions, params), block.timestamp);

        PositionData memory position = positions[tokenId];
        BeneficiaryData[] memory beneficiaries = position.beneficiaries;

        require(position.isUnlocked != true, "StreamableFeesLocker: POSITION_ALREADY_UNLOCKED");

        uint256 length = beneficiaries.length;
        for (uint256 i; i != length; ++i) {
            address beneficiary = beneficiaries[i].beneficiary;
            uint256 shares = beneficiaries[i].shares;

            uint256 timeElapsed = block.timestamp > position.startDate + LOCK_DURATION
                ? LOCK_DURATION
                : block.timestamp - position.startDate;

            // TODO: This might leave some dust, so we might want to check the pre / post balances
            // and send the dust to the last beneficiary
            uint256 amount0 = poolKey.currency0.balanceOfSelf() * shares / WAD;
            uint256 amount1 = poolKey.currency1.balanceOfSelf() * shares / WAD;

            uint256 amount0Claimable =
                amount0 * timeElapsed / LOCK_DURATION - beneficiaries[i].claimedAmounts.amountClaimed0;
            uint256 amount1Claimable =
                amount1 * timeElapsed / LOCK_DURATION - beneficiaries[i].claimedAmounts.amountClaimed1;

            beneficiaries[i].amountClaimed0 += amount0Claimable;
            beneficiaries[i].amountClaimed1 += amount1Claimable;

            beneficiariesClaims[beneficiary][poolKey.currency0] += amount0Claimable;
            beneficiariesClaims[beneficiary][poolKey.currency1] += amount1Claimable;

            if (timeElapsed == LOCK_DURATION) {
                position.isUnlocked = true;
            }
        }
    }

    function releaseFees(
        uint256 tokenId
    ) external {
        // Get pool info
        (PoolKey memory poolKey,) = positionManager.getPoolAndPositionInfo(tokenId);

        // Get the amount of fees to release
        uint256 amount0ToRelease = beneficiariesClaims[msg.sender][poolKey.currency0];
        uint256 amount1ToRelease = beneficiariesClaims[msg.sender][poolKey.currency1];

        // Release the fees
        poolKey.currency0.transfer(beneficiary, amount0ToRelease);
        poolKey.currency1.transfer(beneficiary, amount1ToRelease);

        beneficiariesClaims[msg.sender][poolKey.currency0] = 0;
        beneficiariesClaims[msg.sender][poolKey.currency1] = 0;

        emit Release(tokenId, msg.sender, amount0ToRelease, amount1ToRelease);
    }

    function updateBeneficiary(uint256 tokenId, address newBeneficiary) external {
        // Get position data
        PositionData memory position = positions[tokenId];

        // Get the index of the beneficiary to transfer ownership to `newBeneficiary`
        uint256 length = position.beneficiaries.length;
        for (uint256 i; i != length; ++i) {
            if (position.beneficiaries[i].beneficiary == msg.sender) {
                position.beneficiaries[i].beneficiary = newBeneficiary;
                break;
            }
        }

        // Update the position data
        positions[tokenId] = position;

        emit UpdateBeneficiary(tokenId, msg.sender, newBeneficiary);
    }

    function unlock(
        uint256 tokenId
    ) external {
        // Get token position and unlock it
        PositionData memory position = positions[tokenId];
        require(position.isUnlocked == true, "StreamableFeesLocker: POSITION_NOT_UNLOCKED");

        // Transfer the position to the recipient
        positionManager.safeTransferFrom(address(this), position.recipient, tokenId, new bytes(0));

        emit Unlock(tokenId, position.recipient);
    }
}
