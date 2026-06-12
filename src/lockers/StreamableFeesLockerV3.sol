// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.24;

import { Ownable } from "@openzeppelin/access/Ownable.sol";
import { IPoolManager } from "@v4-core/interfaces/IPoolManager.sol";
import { BalanceDelta, toBalanceDelta } from "@v4-core/types/BalanceDelta.sol";
import { Currency, CurrencyLibrary } from "@v4-core/types/Currency.sol";
import { PoolId } from "@v4-core/types/PoolId.sol";
import { PoolKey } from "@v4-core/types/PoolKey.sol";
import { PositionManager } from "@v4-periphery/PositionManager.sol";
import { Actions } from "@v4-periphery/libraries/Actions.sol";
import { ERC20 } from "solady/tokens/ERC20.sol";

import { FeesManager } from "src/base/FeesManager.sol";
import { BeneficiaryData, MIN_PROTOCOL_OWNER_SHARES } from "src/types/BeneficiaryData.sol";
import { DEAD_ADDRESS } from "src/types/Constants.sol";
import { Position } from "src/types/Position.sol";

/**
 * @notice Data structure for stream information
 * @param poolKey Key of the associated Uniswap V4 pool
 * @param recipient Address receiving control of the unlocked liquidity
 * @param startDate Timestamp when the stream started
 * @param lockDuration Duration for which the position is locked
 * @param isUnlocked True if the position has been unlocked
 * @param beneficiaries Array of beneficiaries and their shares
 * @param tokenIds Array of PositionManager token ids locked in the stream
 */
struct StreamData {
    PoolKey poolKey;
    address recipient;
    uint32 startDate;
    uint32 lockDuration;
    bool isUnlocked;
    BeneficiaryData[] beneficiaries;
    uint256[] tokenIds;
}

/// @notice Thrown when a migrator is not approved
error NotApprovedMigrator();

/// @notice Thrown when a stream is not found
error StreamNotFound();

/// @notice Thrown when a stream already started
error StreamAlreadyStarted();

/**
 * @notice Emitted when a position is locked
 * @param poolId Id of the associated Uniswap V4 pool
 * @param beneficiaries Array of beneficiaries and their shares
 * @param unlockDate Timestamp when the position will be unlocked
 */
event Lock(PoolId indexed poolId, BeneficiaryData[] beneficiaries, uint256 unlockDate);

/**
 * @notice Emitted when a new stream is unlocked and its liquidity control is assigned to the recipient
 * @param poolId Id of the associated Uniswap V4 pool
 * @param recipient Address receiving the unlocked liquidity control
 */
event Unlock(PoolId indexed poolId, address recipient);

/**
 * @notice Emitted when a migrator status is updated
 * @param migrator Address of the migrator
 * @param approval True if the migrator is approved
 */
event MigratorApproval(address indexed migrator, bool approval);

/**
 * @title StreamableFeesLocker V3
 * @author Whetstone Research
 * @custom:security-contact security@whetstone.cc
 * @notice A contract that manages fee streaming for Uniswap V4 PositionManager positions
 * @dev Keeps the V2 lock and fee-collection surface while transferring locked NFTs to the recipient on unlock.
 */
contract StreamableFeesLockerV3 is Ownable, FeesManager {
    using CurrencyLibrary for Currency;

    /// @notice Uniswap V4 PoolManager used by the PositionManager
    IPoolManager public immutable poolManager;

    /// @notice Uniswap V4 PositionManager used to mint and custody transferable positions
    PositionManager public immutable positionManager;

    /// @notice Mapping of Uniswap V4 pool ids and their respective streams
    mapping(PoolId poolId => StreamData) public streams;

    /// @notice Mapping of approved migrators
    mapping(address migrator => bool approved) public approvedMigrators;

    /**
     * @param poolManager_ Address of the Uniswap V4 PoolManager contract
     * @param positionManager_ Address of the Uniswap V4 PositionManager contract
     * @param owner_ Address of the owner of the contract
     */
    constructor(IPoolManager poolManager_, PositionManager positionManager_, address owner_) Ownable(owner_) {
        poolManager = poolManager_;
        positionManager = positionManager_;
    }

    receive() external payable { }

    /// @notice Checks if the `msg.sender` is an approved migrator
    modifier onlyApprovedMigrator() {
        if (!approvedMigrators[msg.sender]) {
            revert NotApprovedMigrator();
        }
        _;
    }

    /**
     * @notice Returns all PositionManager token ids locked for a pool
     * @param poolId Id of the associated Uniswap V4 pool
     */
    function getTokenIds(PoolId poolId) external view returns (uint256[] memory) {
        return streams[poolId].tokenIds;
    }

    /**
     * @notice Locks positions for a specified duration and sets its beneficiaries
     * @param poolKey Key of the Uniswap V4 pool to which the positions belong
     * @param lockDuration Duration for which the positions will be locked
     * @param recipient Recipient address receiving liquidity control on unlock
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

        require(streams[poolId].startDate == 0, StreamAlreadyStarted());

        _storeBeneficiaries(poolKey, beneficiaries, owner(), MIN_PROTOCOL_OWNER_SHARES);

        uint256[] memory tokenIds = _mintPositions(poolKey, positions);

        // Note: If recipient is DEAD_ADDRESS (0xdead), the positions will be permanently locked
        // and beneficiaries can collect fees in perpetuity
        streams[poolId] = StreamData({
            poolKey: poolKey,
            beneficiaries: beneficiaries,
            startDate: uint32(block.timestamp),
            isUnlocked: false,
            recipient: recipient,
            lockDuration: lockDuration,
            tokenIds: tokenIds
        });

        emit Lock(poolId, beneficiaries, recipient != DEAD_ADDRESS ? block.timestamp + lockDuration : 0);
    }

    /// @inheritdoc FeesManager
    function _collectFees(PoolId poolId) internal override returns (BalanceDelta fees) {
        StreamData memory stream = streams[poolId];
        require(stream.startDate != 0, StreamNotFound());

        if (stream.isUnlocked) return toBalanceDelta(0, 0);

        fees = _collectPositionFees(stream.poolKey, stream.tokenIds);

        // Note: For no-op governance, if recipient is DEAD_ADDRESS (0xdead), the position will be
        // permanently locked and beneficiaries can collect fees in perpetuity.
        if (block.timestamp >= stream.startDate + stream.lockDuration && stream.recipient != DEAD_ADDRESS) {
            streams[poolId].isUnlocked = true;
            _transferPositions(stream.recipient, stream.tokenIds);

            emit Unlock(poolId, stream.recipient);
        }
    }

    /**
     * @notice Approves a migrator
     * @param migrator Address of the migrator
     */
    function approveMigrator(address migrator) external onlyOwner {
        if (!approvedMigrators[migrator]) {
            approvedMigrators[migrator] = true;
            emit MigratorApproval(address(migrator), true);
        }
    }

    /**
     * @notice Revokes a migrator
     * @param migrator Address of the migrator
     */
    function revokeMigrator(address migrator) external onlyOwner {
        if (approvedMigrators[migrator]) {
            approvedMigrators[migrator] = false;
            emit MigratorApproval(address(migrator), false);
        }
    }

    function _mintPositions(
        PoolKey memory poolKey,
        Position[] calldata positions
    ) internal returns (uint256[] memory tokenIds) {
        uint256 length = positions.length;
        tokenIds = new uint256[](length);

        bool hasNativeCurrency = _hasNativeCurrency(poolKey);
        uint256 actionsLength = length + 1 + (hasNativeCurrency ? 1 : 0);
        bytes[] memory params = new bytes[](actionsLength);
        bytes memory actions = new bytes(actionsLength);

        uint128 amount0Max = _balanceOfSelf(poolKey.currency0);
        uint128 amount1Max = _balanceOfSelf(poolKey.currency1);

        for (uint256 i; i < length; ++i) {
            Position calldata position = positions[i];
            actions[i] = bytes1(uint8(Actions.MINT_POSITION));
            params[i] = abi.encode(
                poolKey,
                position.tickLower,
                position.tickUpper,
                position.liquidity,
                amount0Max,
                amount1Max,
                address(this),
                new bytes(0)
            );
        }

        actions[length] = bytes1(uint8(Actions.SETTLE_PAIR));
        params[length] = abi.encode(poolKey.currency0, poolKey.currency1);

        if (hasNativeCurrency) {
            actions[actionsLength - 1] = bytes1(uint8(Actions.SWEEP));
            params[actionsLength - 1] = abi.encode(CurrencyLibrary.ADDRESS_ZERO, address(this));
        }

        uint256 nextTokenId = positionManager.nextTokenId();

        _approvePositionManager(poolKey.currency0, amount0Max);
        _approvePositionManager(poolKey.currency1, amount1Max);

        positionManager.modifyLiquidities{ value: _nativeValue(poolKey) }(
            abi.encode(abi.encodePacked(actions), params), block.timestamp
        );

        for (uint256 i; i < length; ++i) {
            tokenIds[i] = nextTokenId + i;
        }
    }

    function _collectPositionFees(
        PoolKey memory poolKey,
        uint256[] memory tokenIds
    ) internal returns (BalanceDelta fees) {
        uint256 balance0Before = _balanceOfSelf(poolKey.currency0);
        uint256 balance1Before = _balanceOfSelf(poolKey.currency1);
        uint256 length = tokenIds.length;

        bytes[] memory params = new bytes[](length + 1);
        bytes memory actions = new bytes(length + 1);

        for (uint256 i; i < length; ++i) {
            actions[i] = bytes1(uint8(Actions.DECREASE_LIQUIDITY));
            params[i] = abi.encode(tokenIds[i], 0, 0, 0, new bytes(0));
        }

        actions[length] = bytes1(uint8(Actions.TAKE_PAIR));
        params[length] = abi.encode(poolKey.currency0, poolKey.currency1, address(this));

        positionManager.modifyLiquidities(abi.encode(abi.encodePacked(actions), params), block.timestamp);

        fees = toBalanceDelta(
            int128(uint128(_balanceOfSelf(poolKey.currency0) - balance0Before)),
            int128(uint128(_balanceOfSelf(poolKey.currency1) - balance1Before))
        );
    }

    function _transferPositions(address recipient, uint256[] memory tokenIds) internal {
        uint256 length = tokenIds.length;

        for (uint256 i; i < length; ++i) {
            positionManager.transferFrom(address(this), recipient, tokenIds[i]);
        }
    }

    function _approvePositionManager(Currency currency, uint256 amount) internal {
        if (amount == 0 || Currency.unwrap(currency) == address(0)) return;

        address token = Currency.unwrap(currency);
        address permit2 = address(positionManager.permit2());

        if (ERC20(token).allowance(address(this), permit2) < amount) {
            ERC20(token).approve(permit2, type(uint256).max);
        }

        positionManager.permit2().approve(token, address(positionManager), uint160(amount), type(uint48).max);
    }

    function _balanceOfSelf(Currency currency) internal view returns (uint128 balance) {
        if (Currency.unwrap(currency) == address(0)) {
            balance = uint128(address(this).balance);
        } else {
            balance = uint128(currency.balanceOfSelf());
        }
    }

    function _nativeValue(PoolKey memory poolKey) internal view returns (uint256) {
        if (_hasNativeCurrency(poolKey)) {
            return address(this).balance;
        }

        return 0;
    }

    function _hasNativeCurrency(PoolKey memory poolKey) internal pure returns (bool) {
        return Currency.unwrap(poolKey.currency0) == address(0) || Currency.unwrap(poolKey.currency1) == address(0);
    }
}
