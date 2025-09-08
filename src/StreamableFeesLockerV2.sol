// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.24;

import { BalanceDelta } from "@v4-core/types/BalanceDelta.sol";
import { PoolKey } from "@v4-core/types/PoolKey.sol";
import { PoolId } from "@v4-core/types/PoolId.sol";
import { IPoolManager } from "@v4-core/interfaces/IPoolManager.sol";
import { Ownable } from "@openzeppelin/access/Ownable.sol";

import { FeesManager } from "src/base/FeesManager.sol";
import { Position } from "src/types/Position.sol";
import { MiniV4Manager } from "src/base/MiniV4Manager.sol";
import { BeneficiaryData } from "src/types/BeneficiaryData.sol";
import { DEAD_ADDRESS } from "src/types/Constants.sol";

/**
 * @notice Data structure for stream information
 * @param poolKey Key of the associated Uniswap V4 pool
 * @param recipient Address receiving the token balances on unlock
 * @param startDate Timestamp when the stream started
 * @param lockDuration Duration for which the position is locked
 * @param isUnlocked True if the position has been unlocked
 * @param beneficiaries Array of beneficiaries and their shares
 * @param positions Array of positions that are locked in the stream
 */
struct StreamData {
    PoolKey poolKey;
    address recipient;
    uint32 startDate;
    uint32 lockDuration;
    bool isUnlocked;
    BeneficiaryData[] beneficiaries;
    Position[] positions;
}

/// @notice Thrown when a migrator is not approved
error NotApprovedMigrator();

/// @notice Thrown when a stream is not found
error StreamNotFound();

/**
 * @notice Emitted when a position is locked
 * @param poolId Id of the associated Uniswap V4 pool
 * @param beneficiaries Array of beneficiaries and their shares
 * @param unlockDate Timestamp when the position will be unlocked
 */
event Lock(PoolId indexed poolId, BeneficiaryData[] beneficiaries, uint256 unlockDate);

/**
 * @notice Emitted when a new stream is unlocked
 * @param poolId Id of the associated Uniswap V4 pool
 * @param recipient Address receiving the token balances on unlock
 */
event Unlock(PoolId indexed poolId, address recipient);

/**
 * @notice Emitted when a migrator status is updated
 * @param migrator Address of the migrator
 * @param approval True if the migrator is approved
 */
event MigratorApproval(address indexed migrator, bool approval);

/**
 * @title StreamableFeesLocker
 * @author Whetstone Research
 * @custom:security-contact security@whetstone.cc
 * @notice A contract that manages fee streaming for Uniswap V4 positions
 * @dev Allows locking positions for a specified duration and streaming fees to multiple beneficiaries
 */
contract StreamableFeesLockerV2 is Ownable, MiniV4Manager, FeesManager {
    /// @notice Mapping of Uniswap V4 pool ids and their respective streams
    mapping(PoolId poolId => StreamData) public streams;

    /// @notice Mapping of approved migrators
    mapping(address migrator => bool approved) public approvedMigrators;

    /// @notice Anyone can send ETH to this contract
    receive() external payable { }

    /**
     * @param poolManager_ Address of the Uniswap V4 PoolManager contract
     * @param owner_ Address of the owner of the contract
     */
    constructor(IPoolManager poolManager_, address owner_) Ownable(owner_) MiniV4Manager(poolManager_) {
        poolManager = poolManager_;
    }

    /// @notice Checks if the `msg.sender` is an approved migrator
    modifier onlyApprovedMigrator() {
        if (!approvedMigrators[msg.sender]) {
            revert NotApprovedMigrator();
        }
        _;
    }

    /**
     * @notice Locks positions for a specified duration and sets its beneficiaries
     * @param poolKey Key of the Uniswap V4 pool to which the positions belong
     * @param lockDuration Duration for which the positions will be locked
     * @param recipient Recipient address receiving the token balances on unlock
     * @param beneficiaries Array of beneficiaries and their shares
     * @param positions Array of positions to lock
     */
    function lock(
        PoolKey memory poolKey,
        uint32 lockDuration,
        address recipient,
        BeneficiaryData[] calldata beneficiaries,
        Position[] calldata positions
    ) external onlyApprovedMigrator {
        PoolId poolId = poolKey.toId();

        // Note: If recipient is DEAD_ADDRESS (0xdead), the position will be permanently locked
        // and beneficiaries can collect fees in perpetuity
        streams[poolId] = StreamData({
            poolKey: poolKey,
            beneficiaries: beneficiaries,
            startDate: uint32(block.timestamp),
            isUnlocked: false,
            recipient: recipient,
            lockDuration: lockDuration,
            positions: positions
        });

        _storeBeneficiaries(poolId, owner(), beneficiaries);
        getPoolKey[poolId] = poolKey;
        _mint(poolKey, positions);

        emit Lock(poolId, beneficiaries, recipient != DEAD_ADDRESS ? block.timestamp + lockDuration : 0);
    }

    /// @inheritdoc FeesManager
    function _collectFees(
        PoolId poolId
    ) internal override returns (BalanceDelta fees) {
        StreamData memory stream = streams[poolId];
        require(stream.startDate != 0, StreamNotFound());

        if (stream.isUnlocked == false) {
            fees = _collect(stream.poolKey, stream.positions);

            // Note: For no-op governance, if recipient is DEAD_ADDRESS (0xdead), the position will be
            // permanently locked and beneficiaries can collect fees in perpetuity
            if (block.timestamp >= stream.startDate + stream.lockDuration && stream.recipient != DEAD_ADDRESS) {
                streams[poolId].isUnlocked = true;

                (BalanceDelta delta,) = _burn(stream.poolKey, stream.positions);
                stream.poolKey.currency0.transfer(stream.recipient, uint128(delta.amount0()));
                stream.poolKey.currency1.transfer(stream.recipient, uint128(delta.amount1()));

                emit Unlock(poolId, stream.recipient);
            }
        }
    }

    /**
     * @notice Approves a migrator
     * @param migrator Address of the migrator
     */
    function approveMigrator(
        address migrator
    ) external onlyOwner {
        if (!approvedMigrators[migrator]) {
            approvedMigrators[migrator] = true;
            emit MigratorApproval(address(migrator), true);
        }
    }

    /**
     * @notice Revokes a migrator
     * @param migrator Address of the migrator
     */
    function revokeMigrator(
        address migrator
    ) external onlyOwner {
        if (approvedMigrators[migrator]) {
            approvedMigrators[migrator] = false;
            emit MigratorApproval(address(migrator), false);
        }
    }
}
