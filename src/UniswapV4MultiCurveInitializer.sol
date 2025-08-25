// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.13;

import { TickMath } from "@v4-core/libraries/TickMath.sol";
import { LiquidityAmounts } from "@v4-core-test/utils/LiquidityAmounts.sol";
import { SqrtPriceMath } from "v4-core/libraries/SqrtPriceMath.sol";
import { FullMath } from "@v4-core/libraries/FullMath.sol";
import { ERC20, SafeTransferLib } from "@solmate/utils/SafeTransferLib.sol";
import { Airlock } from "src/Airlock.sol";
import { IPoolInitializer } from "src/interfaces/IPoolInitializer.sol";
import { ImmutableAirlock } from "src/base/ImmutableAirlock.sol";
import { BeneficiaryData } from "src/StreamableFeesLocker.sol";
import { StateLibrary } from "@v4-core/libraries/StateLibrary.sol";
import { IPoolManager } from "@v4-core/interfaces/IPoolManager.sol";
import { PoolId, PoolIdLibrary } from "@v4-core/types/PoolId.sol";
import { PoolKey } from "@v4-core/types/PoolKey.sol";
import { Currency, CurrencyLibrary } from "@v4-core/types/Currency.sol";
import { MiniV4Manager, Position } from "./MiniV4Manager.sol";
import { IHooks } from "@v4-core/interfaces/IHooks.sol";
import { BalanceDelta, BalanceDeltaLibrary } from "@v4-core/types/BalanceDelta.sol";

/**
 * @notice Emitted when a collect event is called
 * @param pool Address of the pool
 * @param beneficiary Address of the beneficiary receiving the fees
 * @param fees0 Amount of fees collected in token0
 * @param fees1 Amount of fees collected in token1
 */
event Collect(address indexed pool, address indexed beneficiary, uint256 fees0, uint256 fees1);

/**
 * @notice Emitted when a new pool is locked
 * @param pool Address of the Uniswap V4 pool key
 * @param beneficiaries Array of beneficiaries with their shares
 */
event Lock(address indexed pool, BeneficiaryData[] beneficiaries);

/// @notice Thrown when the caller is not the Pool contract
error OnlyPool();

/// @notice Thrown when the pool is already initialized
error PoolAlreadyInitialized();

/// @notice Thrown when the pool is already exited
error PoolAlreadyExited();

/// @notice Thrown when the pool is locked but collect is called
error PoolLocked();

/// @notice Thrown when the current tick is not sufficient to migrate
error CannotMigrateInsufficientTick(int24 targetTick, int24 currentTick);

/// @notice Thrown when the computed liquidity to mint is zero
error CannotMintZeroLiquidity();

/// @notice Thrown when the tick range is misordered
error InvalidTickRangeMisordered(int24 tickLower, int24 tickUpper);

/// @notice Thrown when the max share to be sold exceeds the maximum unit
error MaxShareToBeSoldExceeded(uint256 value, uint256 limit);

/// @dev Thrown when the beneficiaries are not in ascending order
error UnorderedBeneficiaries();

/// @notice Thrown when shares are invalid
error InvalidShares();

/// @notice Thrown when total shares are not equal to WAD
error InvalidTotalShares();

/// @notice Thrown when protocol owner shares are invalid
error InvalidProtocolOwnerShares();

/// @notice Thrown when protocol owner beneficiary is not found
error InvalidProtocolOwnerBeneficiary();

/// @notice Thrown when a mismatched info length for curves
error InvalidArrayLength();

error ZeroPosition(uint256 index);

error ZeroMaxShare(uint256 index);

error TickNotAligned(int24 tick);

/// @dev Constant used to increase precision during calculations
uint256 constant WAD = 1e18;

struct InitData {
    uint24 fee;
    int24 tickSpacing;
    int24[] tickLower;
    int24[] tickUpper;
    uint16[] numPositions;
    uint256[] shareToBeSold;
    BeneficiaryData[] beneficiaries;
}

struct CallbackData {
    address asset;
    address numeraire;
    uint24 fee;
}

enum PoolStatus {
    Uninitialized,
    Initialized,
    Locked,
    Exited
}

struct PoolState {
    address numeraire;
    int24[] tickLower;
    int24[] tickUpper;
    uint256[] shareToBeSold;
    uint256 totalTokensOnBondingCurve;
    uint256 totalNumPositions;
    BeneficiaryData[] beneficiaries;
    Position[] positions;
    PoolStatus status;
    PoolKey poolKey;
}

contract UniswapV4MultiCurveInitializer is IPoolInitializer, ImmutableAirlock, MiniV4Manager {
    using StateLibrary for IPoolManager;
    using PoolIdLibrary for PoolKey;
    using CurrencyLibrary for Currency;
    using BalanceDeltaLibrary for BalanceDelta;

    IHooks public immutable multiCurveHook;

    /// @notice Returns the state of a pool
    mapping(address asset => PoolState state) public getState;

    /**
     * @param airlock_ Address of the Airlock contract
     * @param poolManager_ Address of the Uniswap V4 pool manager
     */
    constructor(
        address airlock_,
        IPoolManager poolManager_,
        IHooks multiCurveHook_
    ) ImmutableAirlock(airlock_) MiniV4Manager(poolManager_) {
        multiCurveHook = multiCurveHook_;
    }

    /// @inheritdoc IPoolInitializer
    function initialize(
        address asset,
        address numeraire,
        uint256 totalTokensOnBondingCurve,
        bytes32,
        bytes calldata data
    ) external onlyAirlock returns (address pool) {
        InitData memory initData = abi.decode(data, (InitData));

        (
            uint24 fee,
            int24 tickSpacing,
            int24[] memory tickLower,
            int24[] memory tickUpper,
            uint16[] memory numPositions,
            uint256[] memory shareToBeSold,
            BeneficiaryData[] memory beneficiaries
        ) = (
            initData.fee,
            initData.tickSpacing,
            initData.tickLower,
            initData.tickUpper,
            initData.numPositions,
            initData.shareToBeSold,
            initData.beneficiaries
        );

        uint256 numCurves = initData.tickLower.length;

        if (
            numCurves != tickUpper.length || numCurves != shareToBeSold.length || numCurves != numPositions.length
                || shareToBeSold.length != numPositions.length
        ) {
            revert InvalidArrayLength();
        }

        // todo determine if we just put the rest on the curve
        uint256 totalShareToBeSold;
        uint256 totalNumPositions;
        (address token0, address token1) = asset < numeraire ? (asset, numeraire) : (numeraire, asset);
        bool isToken0 = asset == token0;

        int24 lowerTickBoundary = TickMath.MIN_TICK;
        int24 upperTickBoundary = TickMath.MAX_TICK;

        // Check the curves to see if they are safe
        for (uint256 i; i != numCurves; ++i) {
            require(numPositions[i] > 0, ZeroPosition(i));
            require(shareToBeSold[i] > 0, ZeroMaxShare(i));

            totalNumPositions += numPositions[i];
            totalShareToBeSold += shareToBeSold[i];

            int24 currentTickLower = tickLower[i];
            int24 currentTickUpper = tickUpper[i];

            // Check if the ticks are in the tick spacing
            _isValidTick(currentTickLower, tickSpacing);
            _isValidTick(currentTickUpper, tickSpacing);

            require(currentTickLower < currentTickUpper, InvalidTickRangeMisordered(currentTickLower, currentTickUpper));

            // Flip the ticks if the asset is token1
            if (!isToken0) {
                tickLower[i] = -currentTickUpper;
                tickUpper[i] = -currentTickLower;
            }

            // Calculate the boundaries
            if (lowerTickBoundary > currentTickLower) lowerTickBoundary = currentTickLower;
            if (upperTickBoundary < currentTickUpper) upperTickBoundary = currentTickUpper;
        }

        require(totalShareToBeSold <= WAD, MaxShareToBeSoldExceeded(totalShareToBeSold, WAD));
        require(lowerTickBoundary < upperTickBoundary, InvalidTickRangeMisordered(lowerTickBoundary, upperTickBoundary));

        uint160 sqrtPriceX96 = TickMath.getSqrtPriceAtTick(isToken0 ? lowerTickBoundary : upperTickBoundary);

        PoolKey memory poolKey = PoolKey({
            currency0: asset < numeraire ? Currency.wrap(asset) : Currency.wrap(numeraire),
            currency1: asset < numeraire ? Currency.wrap(numeraire) : Currency.wrap(asset),
            hooks: multiCurveHook,
            fee: fee,
            tickSpacing: tickSpacing
        });

        poolManager.initialize(poolKey, sqrtPriceX96);

        Position[] memory positions = _calculatePositions(
            poolKey, isToken0, numPositions, tickLower, tickUpper, shareToBeSold, totalTokensOnBondingCurve
        );

        PoolState memory state = PoolState({
            numeraire: numeraire,
            tickLower: tickLower,
            tickUpper: tickUpper,
            shareToBeSold: shareToBeSold,
            totalTokensOnBondingCurve: totalTokensOnBondingCurve,
            totalNumPositions: totalNumPositions + 1, // +1 for the tail position
            beneficiaries: beneficiaries,
            positions: positions,
            status: beneficiaries.length != 0 ? PoolStatus.Locked : PoolStatus.Initialized,
            poolKey: poolKey
        });

        require(getState[asset].status == PoolStatus.Uninitialized, PoolAlreadyInitialized());
        getState[asset] = state;

        _mint(poolKey, positions);

        emit Create(address(poolManager), asset, numeraire);

        if (beneficiaries.length != 0) {
            _validateBeneficiaries(beneficiaries);
            emit Lock(pool, beneficiaries);
        }

        // TODO: A bit hacky but since V4 pools don't have their own address we're returning the address
        // of the asset token instead to retrieve the data later on in the `exitLiquidity function
        pool = asset;
    }

    /// @inheritdoc IPoolInitializer
    function exitLiquidity(
        address asset
    )
        external
        onlyAirlock
        returns (
            uint160 sqrtPriceX96,
            address token0,
            uint128 fees0,
            uint128 balance0,
            address token1,
            uint128 fees1,
            uint128 balance1
        )
    {
        PoolState memory state = getState[asset];
        require(state.status == PoolStatus.Initialized, PoolAlreadyExited());

        state.status = PoolStatus.Exited;
        token0 = Currency.unwrap(state.poolKey.currency0);
        token1 = Currency.unwrap(state.poolKey.currency1);

        int24 tick;
        (sqrtPriceX96, tick,,) = poolManager.getSlot0(state.poolKey.toId());
        bool isToken0 = asset == token0;

        int24 farTick = isToken0 ? state.tickUpper[state.tickUpper.length - 1] : state.tickLower[0];
        require(asset == token0 ? tick >= farTick : tick <= farTick, CannotMigrateInsufficientTick(farTick, tick));

        (BalanceDelta balanceDelta, BalanceDelta feesAccrued) = _burn(state.poolKey, state.positions);
        balance0 = uint128(balanceDelta.amount0());
        balance1 = uint128(balanceDelta.amount1());
        fees0 = uint128(feesAccrued.amount0());
        fees1 = uint128(feesAccrued.amount1());

        state.poolKey.currency0.transfer(msg.sender, balance0);
        state.poolKey.currency1.transfer(msg.sender, balance1);
    }

    /**
     * @notice Collects fees from a locked Uniswap V4 pool and distributes them to beneficiaries
     * @param asset Address of the asset token
     * @return fees0ToDistribute Total fees collected in token0
     * @return fees1ToDistribute Total fees collected in token1
     */
    function collectFees(
        address asset
    ) external returns (uint256 fees0ToDistribute, uint256 fees1ToDistribute) {
        require(getState[asset].status == PoolStatus.Locked, PoolLocked());

        PoolState memory state = getState[asset];

        BalanceDelta totalFees = _collect(state.poolKey, state.positions);
        fees0ToDistribute = uint128(totalFees.amount0());
        fees1ToDistribute = uint128(totalFees.amount1());

        BeneficiaryData[] memory beneficiaries = state.beneficiaries;

        Currency currency0 = state.poolKey.currency0;
        Currency currency1 = state.poolKey.currency1;

        uint256 amount0Distributed;
        uint256 amount1Distributed;
        address beneficiary;

        for (uint256 i; i < beneficiaries.length; ++i) {
            beneficiary = beneficiaries[i].beneficiary;
            uint256 shares = beneficiaries[i].shares;

            // Calculate share of fees for this beneficiary
            uint256 amount0 = fees0ToDistribute * shares / WAD;
            uint256 amount1 = fees1ToDistribute * shares / WAD;

            amount0Distributed += amount0;
            amount1Distributed += amount1;

            if (i == beneficiaries.length - 1) {
                // Distribute the remaining fees to the last beneficiary
                amount0 += fees0ToDistribute > amount0Distributed ? fees0ToDistribute - amount0Distributed : 0;
                amount1 += fees1ToDistribute > amount1Distributed ? fees1ToDistribute - amount1Distributed : 0;
            }

            currency0.transfer(beneficiary, amount0);
            currency1.transfer(beneficiary, amount1);

            emit Collect(asset, beneficiary, amount0, amount1);
        }
    }

    function _calculatePositions(
        PoolKey memory poolKey,
        bool isToken0,
        uint16[] memory numPositions,
        int24[] memory tickLower,
        int24[] memory tickUpper,
        uint256[] memory shareToBeSold,
        uint256 numTokensToSell
    ) internal pure returns (Position[] memory positions) {
        uint256 length = tickLower.length;
        uint256 totalAssetSupplied;

        for (uint256 i; i != length; ++i) {
            uint256 curveSupply = FullMath.mulDiv(numTokensToSell, shareToBeSold[i], WAD);

            // Calculate the positions for this curve
            (Position[] memory newPositions,) = _calculateLogNormalDistribution(
                tickLower[i], tickUpper[i], poolKey.tickSpacing, isToken0, numPositions[i], curveSupply
            );

            newPositions = _concat(positions, newPositions);

            // Update the bonding assets remaining
            totalAssetSupplied += curveSupply;
        }

        // flush the rest into the tail
        uint256 tailSupply = numTokensToSell - totalAssetSupplied;

        uint256 last = positions.length - 1;
        positions[last] = _calculateLpTail(
            last, tickLower[length - 1], tickUpper[length - 1], isToken0, tailSupply, poolKey.tickSpacing
        );
    }

    /// @notice Calculates the final LP position that extends from the far tick to the pool's min/max tick
    /// @dev This position ensures price equivalence between Uniswap v2 and v3 pools beyond the LBP range
    function _calculateLpTail(
        uint256 id,
        int24 tickLower,
        int24 tickUpper,
        bool isToken0,
        uint256 bondingAssetsRemaining,
        int24 tickSpacing
    ) internal pure returns (Position memory lpTail) {
        int24 tailTick = isToken0 ? tickUpper : tickLower;
        uint160 sqrtPriceAtTail = TickMath.getSqrtPriceAtTick(tailTick);

        uint128 lpTailLiquidity = LiquidityAmounts.getLiquidityForAmounts(
            sqrtPriceAtTail,
            TickMath.MIN_SQRT_PRICE,
            TickMath.MAX_SQRT_PRICE,
            isToken0 ? bondingAssetsRemaining : type(uint256).max,
            isToken0 ? type(uint256).max : bondingAssetsRemaining
        );

        int24 posTickLower = isToken0 ? tailTick : _alignTickToTickSpacing(isToken0, TickMath.MIN_TICK, tickSpacing);
        int24 posTickUpper = isToken0 ? _alignTickToTickSpacing(isToken0, TickMath.MAX_TICK, tickSpacing) : tailTick;

        require(posTickLower < posTickUpper, InvalidTickRangeMisordered(posTickLower, posTickUpper));

        lpTail =
            Position({ tickLower: posTickLower, tickUpper: posTickUpper, liquidity: lpTailLiquidity, id: uint16(id) });
    }

    /// @notice Calculates the distribution of liquidity positions across tick ranges
    /// @dev For example, with 1000 tokens and 10 bins starting at tick 0:
    ///      - Creates positions: [0,10], [1,10], [2,10], ..., [9,10]
    ///      - Each position gets an equal share of tokens (100 tokens each)
    ///      This creates a linear distribution of liquidity across the tick range
    function _calculateLogNormalDistribution(
        int24 tickLower,
        int24 tickUpper,
        int24 tickSpacing,
        bool isToken0,
        uint16 numPositions,
        uint256 curveSupply
    ) internal pure returns (Position[] memory, uint256) {
        int24 farTick = isToken0 ? tickUpper : tickLower;
        int24 closeTick = isToken0 ? tickLower : tickUpper;
        int24 spread = tickUpper - tickLower;

        uint160 farSqrtPriceX96 = TickMath.getSqrtPriceAtTick(farTick);
        uint256 amountPerPosition = FullMath.mulDiv(curveSupply, WAD, numPositions * WAD);
        uint256 totalAssetSupplied;
        Position[] memory positions = new Position[](numPositions + 1);
        uint256 reserves;

        for (uint256 i; i < numPositions; i++) {
            // Calculate the ticks position * 1/n to optimize the division
            int24 startingTick = isToken0
                ? closeTick + int24(uint24(FullMath.mulDiv(i, uint256(uint24(spread)), numPositions)))
                : closeTick - int24(uint24(FullMath.mulDiv(i, uint256(uint24(spread)), numPositions)));

            // Round the tick to the nearest bin
            startingTick = _alignTickToTickSpacing(isToken0, startingTick, tickSpacing);

            if (startingTick != farTick) {
                uint160 startingSqrtPriceX96 = TickMath.getSqrtPriceAtTick(startingTick);

                uint128 liquidity;

                // If curveSupply is 0, we skip the liquidity calculation as we are burning max liquidity in each position
                if (curveSupply != 0) {
                    liquidity = isToken0
                        ? LiquidityAmounts.getLiquidityForAmount0(startingSqrtPriceX96, farSqrtPriceX96, amountPerPosition)
                        : LiquidityAmounts.getLiquidityForAmount1(farSqrtPriceX96, startingSqrtPriceX96, amountPerPosition);

                    totalAssetSupplied += (
                        isToken0
                            ? SqrtPriceMath.getAmount0Delta(startingSqrtPriceX96, farSqrtPriceX96, liquidity, true)
                            : SqrtPriceMath.getAmount1Delta(farSqrtPriceX96, startingSqrtPriceX96, liquidity, true)
                    );

                    // Note: we keep track how the theoretical reserves amount at that time to then calculate the breakeven
                    // liquidity amount once we get to the end of the loop, we will know exactly how many of the reserve
                    // assets have been raised, and we can calculate the total amount of reserves after the endTick which
                    // makes swappers and LPs indifferent between Uniswap v2 (CPMM) and Uniswap v3 (CLAMM) we can then bond
                    // the tokens to the Uniswap v2 pool by moving them over to the Uniswap v3 pool whenever possible, but
                    // there is no rush as it goes up
                    reserves += (
                        isToken0
                            ? SqrtPriceMath.getAmount1Delta(
                                farSqrtPriceX96,
                                startingSqrtPriceX96,
                                liquidity,
                                false // round against the reserves to undercount eventual liquidity
                            )
                            : SqrtPriceMath.getAmount0Delta(
                                startingSqrtPriceX96,
                                farSqrtPriceX96,
                                liquidity,
                                false // round against the reserves to undercount eventual liquidity
                            )
                    );
                }

                positions[i] = Position({
                    tickLower: farSqrtPriceX96 < startingSqrtPriceX96 ? farTick : startingTick,
                    tickUpper: farSqrtPriceX96 < startingSqrtPriceX96 ? startingTick : farTick,
                    liquidity: liquidity,
                    id: uint16(i)
                });
            }
        }

        require(totalAssetSupplied <= curveSupply, CannotMintZeroLiquidity());

        return (positions, reserves);
    }

    /**
     * @dev Validates beneficiaries array and ensures protocol owner compliance
     * @param beneficiaries Array of beneficiaries to validate
     */
    function _validateBeneficiaries(
        BeneficiaryData[] memory beneficiaries
    ) internal view {
        address protocolOwner = Airlock(airlock).owner();
        address prevBeneficiary;
        uint256 totalShares;
        bool foundProtocolOwner;

        for (uint256 i; i < beneficiaries.length; i++) {
            BeneficiaryData memory beneficiary = beneficiaries[i];

            // Validate ordering and shares
            require(prevBeneficiary < beneficiary.beneficiary, UnorderedBeneficiaries());
            require(beneficiary.shares > 0, InvalidShares());

            // Check for protocol owner and validate minimum share requirement
            if (beneficiary.beneficiary == protocolOwner) {
                require(beneficiary.shares >= WAD / 20, InvalidProtocolOwnerShares());
                foundProtocolOwner = true;
            }

            prevBeneficiary = beneficiary.beneficiary;
            totalShares += beneficiary.shares;
        }

        require(totalShares == WAD, InvalidTotalShares());
        require(foundProtocolOwner, InvalidProtocolOwnerBeneficiary());
    }

    /**
     * @dev Checks if a tick is valid according to the tick spacing, reverts if not
     * @param tick Tick to check
     * @param tickSpacing Tick spacing to check against
     */
    function _isValidTick(int24 tick, int24 tickSpacing) internal pure {
        if (tick % tickSpacing != 0) revert TickNotAligned(tick);
    }

    /**
     * @dev Aligns a tick to the nearest tick spacing
     * @param isToken0 True if we're selling token 0, this impacts the rounding direction
     * @param tick Tick to align
     * @param tickSpacing Tick spacing to align against
     * @return Aligned tick
     */
    function _alignTickToTickSpacing(bool isToken0, int24 tick, int24 tickSpacing) internal pure returns (int24) {
        if (isToken0) {
            // Round down if isToken0
            if (tick < 0) {
                // If the tick is negative, we round up (negatively) the negative result to round down
                return (tick - tickSpacing + 1) / tickSpacing * tickSpacing;
            } else {
                // Else if positive, we simply round down
                return tick / tickSpacing * tickSpacing;
            }
        } else {
            // Round up if isToken1
            if (tick < 0) {
                // If the tick is negative, we round down the negative result to round up
                return tick / tickSpacing * tickSpacing;
            } else {
                // Else if positive, we simply round up
                return (tick + tickSpacing - 1) / tickSpacing * tickSpacing;
            }
        }
    }

    function _concat(Position[] memory a, Position[] memory b) internal pure returns (Position[] memory) {
        Position[] memory c = new Position[](a.length + b.length);

        uint256 i;

        for (; i != a.length; ++i) {
            c[i] = a[i];
        }

        for (uint256 j; j != b.length; ++j) {
            c[i++] = b[j];
        }

        return c;
    }
}
