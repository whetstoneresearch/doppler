// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.24;

import { ERC20 } from "@solmate/utils/SafeTransferLib.sol";
import { Actions } from "@v4-periphery/libraries/Actions.sol";
import { IPoolManager } from "@v4-core/interfaces/IPoolManager.sol";
import { PositionManager } from "@v4-periphery/PositionManager.sol";
import { PoolKey } from "@v4-core/types/PoolKey.sol";
import { StateLibrary } from "@v4-core/libraries/StateLibrary.sol";
import { PoolIdLibrary } from "@v4-core/types/PoolId.sol";
import { Currency } from "@v4-core/types/Currency.sol";
import { CurrencyLibrary } from "@v4-core/types/Currency.sol";
import { IHooks } from "@v4-core/interfaces/IHooks.sol";
import { TickMath } from "@v4-core/libraries/TickMath.sol";
import { LiquidityAmounts } from "@v4-periphery/libraries/LiquidityAmounts.sol";
import { ILiquidityMigrator } from "src/interfaces/ILiquidityMigrator.sol";
import { ImmutableAirlock } from "src/base/ImmutableAirlock.sol";
import { BeneficiaryData, StreamableFeesLocker } from "src/StreamableFeesLocker.sol";

/**
 * @notice Data to use for the migration
 * @param poolKey Key of the Uniswap V4 pool to migrate liquidity to
 * @param lockDuration Duration for which the liquidity will be locked in the locker contract
 * @param beneficiaries Array of beneficiaries used by the locker contract
 */
struct AssetData {
    PoolKey poolKey;
    uint32 lockDuration;
    BeneficiaryData[] beneficiaries;
}

/// @dev Thrown when the tick is out of range for the pool
error TickOutOfRange();

/// @dev Thrown when the computed liquidity is zero
error ZeroLiquidity();

/// @dev Thrown when the beneficiaries are not in ascending order
error UnorderedBeneficiaries();

/// @notice Thrown when shares are invalid
error InvalidShares();

/// @notice Thrown when total shares are not equal to WAD
error InvalidTotalShares();

/// @notice Thrown when an invalid length is used
error InvalidLength();

/// @dev WAD constant for precise decimal calculations
uint256 constant WAD = 1e18;

/**
 * @title Uniswap V4 Migrator
 * @author Whetstone Research
 * @notice Module contract to migrate liquidity from a Doppler Dutch auction pool to a
 * regular Uniswap V4 pool
 */
contract UniswapV4Migrator is ILiquidityMigrator, ImmutableAirlock {
    using StateLibrary for IPoolManager;
    using PoolIdLibrary for PoolKey;

    /// @notice Address of the Uniswap V4 Pool Manager contract
    IPoolManager public immutable poolManager;

    /// @notice Address of the Uniswap V4 Position Manager contract
    PositionManager public immutable positionManager;

    /// @notice Address of the Streamable Fees Locker
    StreamableFeesLocker public immutable locker;

    /// @notice Address of the Uniswap V4 Migrator Hook
    IHooks public immutable migratorHook;

    /// @notice The dead address used for no-op governance
    address public constant DEAD_ADDRESS = address(0xdead);

    /// @notice Mapping of asset pairs to their respective asset data
    mapping(address token0 => mapping(address token1 => AssetData data)) public getAssetData;

    /// @notice Anyone can send ETH to this contract
    receive() external payable { }

    /**
     *
     * @param airlock_ Address of the Airlock contract
     * @param poolManager_ Address of the Uniswap V4 Pool Manager contract
     * @param positionManager_ Address of the Uniswap V4 Position Manager contract
     * @param locker_ Address of the Streamable Fees Locker contract
     * @param migratorHook_ Address of the Uniswap V4 Migrator Hook contract
     */
    constructor(
        address airlock_,
        IPoolManager poolManager_,
        PositionManager positionManager_,
        StreamableFeesLocker locker_,
        IHooks migratorHook_
    ) ImmutableAirlock(airlock_) {
        poolManager = poolManager_;
        positionManager = positionManager_;
        locker = locker_;
        migratorHook = migratorHook_;
    }

    /// @inheritdoc ILiquidityMigrator
    function initialize(
        address asset,
        address numeraire,
        bytes calldata liquidityMigratorData
    ) external onlyAirlock returns (address) {
        (uint24 fee, int24 tickSpacing, uint32 lockDuration, BeneficiaryData[] memory beneficiaries) =
            abi.decode(liquidityMigratorData, (uint24, int24, uint32, BeneficiaryData[]));

        require(beneficiaries.length > 0, InvalidLength());

        address prevBeneficiary = address(0);
        uint256 totalShares;
        for (uint256 i = 0; i < beneficiaries.length; i++) {
            require(prevBeneficiary < beneficiaries[i].beneficiary, UnorderedBeneficiaries());
            require(beneficiaries[i].shares > 0, InvalidShares());

            prevBeneficiary = beneficiaries[i].beneficiary;

            totalShares += beneficiaries[i].shares;
        }

        require(totalShares == WAD, InvalidTotalShares());

        PoolKey memory poolKey = PoolKey({
            currency0: asset < numeraire ? Currency.wrap(asset) : Currency.wrap(numeraire),
            currency1: asset < numeraire ? Currency.wrap(numeraire) : Currency.wrap(asset),
            hooks: migratorHook,
            fee: fee,
            tickSpacing: tickSpacing
        });

        getAssetData[Currency.unwrap(poolKey.currency0)][Currency.unwrap(poolKey.currency1)] =
            AssetData({ poolKey: poolKey, lockDuration: lockDuration, beneficiaries: beneficiaries });

        return address(0);
    }

    /// @inheritdoc ILiquidityMigrator
    function migrate(
        uint160 sqrtPriceX96,
        address token0,
        address token1,
        address recipient
    ) external payable onlyAirlock returns (uint256 liquidity) {
        AssetData memory assetData = getAssetData[token0][token1];
        PoolKey memory poolKey = assetData.poolKey;

        // Check if this is no-op governance
        bool isNoOpGovernance = recipient == DEAD_ADDRESS;

        poolManager.initialize(poolKey, sqrtPriceX96);

        uint256 balance1 = ERC20(token1).balanceOf(address(this));

        uint256 balance0;
        bytes memory actions;
        bytes[] memory params;

        if (token0 == address(0)) {
            if (isNoOpGovernance) {
                params = new bytes[](3);
                params[2] = abi.encode(CurrencyLibrary.ADDRESS_ZERO, address(this));
                balance0 = address(this).balance;
                actions =
                    abi.encodePacked(uint8(Actions.MINT_POSITION), uint8(Actions.SETTLE_PAIR), uint8(Actions.SWEEP));
            } else {
                params = new bytes[](4);
                params[3] = abi.encode(CurrencyLibrary.ADDRESS_ZERO, address(this));
                balance0 = address(this).balance;
                actions = abi.encodePacked(
                    uint8(Actions.MINT_POSITION),
                    uint8(Actions.MINT_POSITION),
                    uint8(Actions.SETTLE_PAIR),
                    uint8(Actions.SWEEP)
                );
            }
        } else {
            if (isNoOpGovernance) {
                params = new bytes[](2);
                balance0 = ERC20(token0).balanceOf(address(this));
                actions = abi.encodePacked(uint8(Actions.MINT_POSITION), uint8(Actions.SETTLE_PAIR));
            } else {
                params = new bytes[](3);
                balance0 = ERC20(token0).balanceOf(address(this));
                actions = abi.encodePacked(
                    uint8(Actions.MINT_POSITION), uint8(Actions.MINT_POSITION), uint8(Actions.SETTLE_PAIR)
                );
            }
        }

        int24 lowerTick =
            ((TickMath.MIN_TICK + 1) - poolKey.tickSpacing + 1) / poolKey.tickSpacing * poolKey.tickSpacing;
        int24 upperTick = (TickMath.MAX_TICK - 1) / poolKey.tickSpacing * poolKey.tickSpacing;

        int24 currentTick = TickMath.getTickAtSqrtPrice(sqrtPriceX96);

        if (currentTick < lowerTick || currentTick > upperTick) revert TickOutOfRange();

        liquidity = LiquidityAmounts.getLiquidityForAmounts(
            sqrtPriceX96,
            TickMath.getSqrtPriceAtTick(lowerTick),
            TickMath.getSqrtPriceAtTick(upperTick),
            uint128(balance0),
            uint128(balance1)
        );

        if (liquidity == 0) revert ZeroLiquidity();

        if (isNoOpGovernance) {
            // For no-op governance, send all liquidity to the protocol locker
            params[0] = abi.encode(
                poolKey,
                lowerTick,
                upperTick,
                uint128(liquidity),
                uint128(balance0),
                uint128(balance1),
                address(this),
                new bytes(0)
            );

            params[1] = abi.encode(poolKey.currency0, poolKey.currency1);
        } else {
            // Standard case: split liquidity 10/90
            uint256 lockedLiquidity = liquidity / 10;
            uint256 timeLockLiquidity = liquidity - lockedLiquidity;

            // Liquidity for the protocol locker
            params[0] = abi.encode(
                poolKey,
                lowerTick,
                upperTick,
                uint128(lockedLiquidity),
                uint128(balance0) / 10,
                uint128(balance1) / 10,
                address(this),
                new bytes(0)
            );

            // Liquidity for the Timelock, we can pass the full balances as maximum
            // amounts here since the protocol locker already received its share
            params[1] = abi.encode(
                poolKey,
                lowerTick,
                upperTick,
                uint128(timeLockLiquidity),
                uint128(balance0),
                uint128(balance1),
                recipient,
                new bytes(0)
            );

            params[2] = abi.encode(poolKey.currency0, poolKey.currency1);
        }

        if (token0 != address(0)) {
            ERC20(token0).approve(address(positionManager.permit2()), balance0);
            positionManager.permit2().approve(token0, address(positionManager), uint160(balance0), type(uint48).max);
        }

        ERC20(token1).approve(address(positionManager.permit2()), balance1);
        positionManager.permit2().approve(token1, address(positionManager), uint160(balance1), type(uint48).max);

        positionManager.modifyLiquidities{ value: token0 == address(0) ? balance0 : 0 }(
            abi.encode(actions, params), block.timestamp
        );

        if (isNoOpGovernance) {
            // For no-op governance, only one NFT was minted, transfer it to the locker
            positionManager.safeTransferFrom(
                address(this),
                address(locker),
                positionManager.nextTokenId() - 1,
                abi.encode(recipient, assetData.lockDuration, assetData.beneficiaries)
            );
        } else {
            // Standard case: two NFTs were minted, transfer the first one to the locker
            positionManager.safeTransferFrom(
                address(this),
                address(locker),
                positionManager.nextTokenId() - 2,
                abi.encode(recipient, assetData.lockDuration, assetData.beneficiaries)
            );
        }

        // Transfer any remaining dust
        // For no-op governance, send dust to the protocol locker instead of dead address
        address dustRecipient = isNoOpGovernance ? address(locker) : recipient;
        if (poolKey.currency0.balanceOfSelf() > 0) {
            poolKey.currency0.transfer(dustRecipient, poolKey.currency0.balanceOfSelf());
        }
        if (poolKey.currency1.balanceOfSelf() > 0) {
            poolKey.currency1.transfer(dustRecipient, poolKey.currency1.balanceOfSelf());
        }
    }
}
