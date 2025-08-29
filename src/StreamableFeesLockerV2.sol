// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.24;

import { BalanceDelta } from "@v4-core/types/BalanceDelta.sol";
import { PoolKey } from "@v4-core/types/PoolKey.sol";
import { PoolId } from "@v4-core/types/PoolId.sol";
import { Currency } from "@v4-core/types/Currency.sol";
import { IPoolManager } from "@v4-core/interfaces/IPoolManager.sol";
import { ReentrancyGuard } from "@solady/utils/ReentrancyGuard.sol";
import { Ownable } from "@openzeppelin/access/Ownable.sol";

import { Position } from "src/types/Position.sol";
import { MiniV4Manager } from "src/base/MiniV4Manager.sol";
import { BeneficiaryData } from "src/types/BeneficiaryData.sol";
import { WAD } from "src/types/Wad.sol";
import { DEAD_ADDRESS } from "src/types/Constants.sol";

/// @notice Data structure for position information
/// @param recipient Address that will receive the NFT after unlocking
/// @param startDate Timestamp when the position was locked
/// @param lockDuration Duration of the position lock
/// @param isUnlocked Whether the position has been unlocked
/// @param beneficiaries Array of beneficiaries and their shares
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

/// @notice Thrown when a stream is already unlocked
error StreamAlreadyUnlocked();

/// @notice Thrown when a beneficiary is invalid
error InvalidBeneficiary();

/// @notice Emitted when a position is locked
/// @param poolId ID of the Uniswap V4 pool
/// @param beneficiaries Array of beneficiaries and their shares
/// @param unlockDate Timestamp when the position will be unlocked
event Lock(PoolId indexed poolId, BeneficiaryData[] beneficiaries, uint256 unlockDate);

/// @notice Emitted when a position is unlocked
/// @param recipient Address that received the NFT
event Unlock(PoolId indexed poolId, address recipient);

/// @notice Emitted when fees are distributed to a beneficiary
/// @param poolId Id of the Uniswap V4 pool
/// @param amount0 Amount of token0 distributed
/// @param amount1 Amount of token1 distributed
event Collect(PoolId indexed poolId, address beneficiary, uint256 amount0, uint256 amount1);

/// @notice Emitted when a beneficiary is updated
/// @param oldBeneficiary Previous beneficiary address
/// @param newBeneficiary New beneficiary address
event UpdateBeneficiary(PoolId poolId, address oldBeneficiary, address newBeneficiary);

/// @notice Emitted when a migrator is approved
/// @param migrator Address of the migrator
/// @param approval Whether the migrator is approved
event MigratorApproval(address indexed migrator, bool approval);

/// @title StreamableFeesLocker
/// @notice A contract that manages fee streaming for Uniswap V4 positions
/// @dev Allows locking positions for a specified duration and streaming fees to multiple beneficiaries
/// @dev Uses instant distribution mechanism for fees
contract StreamableFeesLockerV2 is ReentrancyGuard, Ownable, MiniV4Manager {
    // Taken from FeesManager //

    mapping(PoolId poolId => uint256 cumulatedFees0) public getCumulatedFees0;
    mapping(PoolId poolId => uint256 cumulatedFees1) public getCumulatedFees1;

    mapping(PoolId poolId => mapping(address beneficiary => uint256 lastCumulatedFees0)) public getLastCumulatedFees0;
    mapping(PoolId poolId => mapping(address beneficiary => uint256 lastCumulatedFees1)) public getLastCumulatedFees1;

    mapping(PoolId poolId => mapping(address beneficiary => uint256 shares)) public getShares;

    // ---------------- //

    mapping(PoolId poolId => StreamData) public streams;

    /// @notice Mapping of approved migrators
    mapping(address migrator => bool approved) public approvedMigrators;

    /// @notice Anyone can send ETH to this contract
    receive() external payable { }

    /// @param owner_ Address of the owner of the contract
    constructor(IPoolManager poolManager_, address owner_) Ownable(owner_) MiniV4Manager(poolManager_) {
        poolManager = poolManager_;
    }

    /// @notice Modifier to restrict sender to approved migrators only
    modifier onlyApprovedMigrator() {
        if (!approvedMigrators[msg.sender]) {
            revert NotApprovedMigrator();
        }
        _;
    }

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

        _mint(poolKey, positions);

        emit Lock(poolId, beneficiaries, recipient != DEAD_ADDRESS ? block.timestamp + lockDuration : 0);
    }

    /// @notice Collect fees from a Uniswap V4 pool and accrue them to beneficiaries
    function collect(
        PoolId poolId
    ) external nonReentrant {
        StreamData memory stream = streams[poolId];

        require(stream.startDate != 0, StreamNotFound());
        require(stream.isUnlocked != true, StreamAlreadyUnlocked());

        BalanceDelta fees = _collect(stream.poolKey, stream.positions);

        uint128 fees0 = uint128(fees.amount0());
        uint128 fees1 = uint128(fees.amount1());

        getCumulatedFees0[poolId] += fees0;
        getCumulatedFees1[poolId] += fees1;

        _releaseFees(poolId, msg.sender);

        // Note: For no-op governance, if recipient is DEAD_ADDRESS (0xdead), the position will be permanently locked
        // and beneficiaries can collect fees in perpetuity
        if (block.timestamp >= stream.startDate + stream.lockDuration && stream.recipient != DEAD_ADDRESS) {
            streams[poolId].isUnlocked = true;

            (BalanceDelta delta,) = _handleBurn(stream.poolKey, stream.positions);
            stream.poolKey.currency0.transfer(stream.recipient, uint128(delta.amount0()));
            stream.poolKey.currency1.transfer(stream.recipient, uint128(delta.amount1()));

            emit Unlock(poolId, stream.recipient);
        }
    }

    /// @notice Releases fees to a beneficiary
    /// @param beneficiary Address to release fees to
    function _releaseFees(PoolId poolId, address beneficiary) internal {
        uint256 shares = getShares[poolId][beneficiary];

        if (shares > 0) {
            uint256 delta0 = getCumulatedFees0[poolId] - getLastCumulatedFees0[poolId][beneficiary];
            uint256 amount0 = delta0 * shares / WAD;
            getLastCumulatedFees0[poolId][beneficiary] = getCumulatedFees0[poolId];
            if (amount0 > 0) streams[poolId].poolKey.currency0.transfer(beneficiary, amount0);

            uint256 delta1 = getCumulatedFees1[poolId] - getLastCumulatedFees1[poolId][beneficiary];
            uint256 amount1 = delta1 * shares / WAD;
            getLastCumulatedFees1[poolId][beneficiary] = getCumulatedFees1[poolId];
            if (amount1 > 0) streams[poolId].poolKey.currency1.transfer(beneficiary, amount1);

            emit Collect(poolId, beneficiary, amount0, amount1);
        }
    }

    /// @notice Updates the beneficiary address for a position
    /// @param newBeneficiary New beneficiary address
    function updateBeneficiary(PoolId poolId, address newBeneficiary) external nonReentrant {
        _releaseFees(poolId, msg.sender);
        getShares[poolId][newBeneficiary] = getShares[poolId][msg.sender];
        getShares[poolId][msg.sender] = 0;
        getLastCumulatedFees0[poolId][newBeneficiary] = getCumulatedFees0[poolId];
        getLastCumulatedFees1[poolId][newBeneficiary] = getCumulatedFees1[poolId];

        emit UpdateBeneficiary(poolId, msg.sender, newBeneficiary);
    }

    /// @notice Approves a migrator
    /// @param migrator Address of the migrator
    function approveMigrator(
        address migrator
    ) external onlyOwner {
        if (!approvedMigrators[migrator]) {
            approvedMigrators[migrator] = true;
            emit MigratorApproval(address(migrator), true);
        }
    }

    /// @notice Revokes a migrator
    /// @param migrator Address of the migrator
    function revokeMigrator(
        address migrator
    ) external onlyOwner {
        if (approvedMigrators[migrator]) {
            approvedMigrators[migrator] = false;
            emit MigratorApproval(address(migrator), false);
        }
    }
}
