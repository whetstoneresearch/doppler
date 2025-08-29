// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.13;

import { LiquidityAmounts } from "@v4-periphery/libraries/LiquidityAmounts.sol";
import { TickMath } from "@v4-core/libraries/TickMath.sol";
import { SqrtPriceMath } from "v4-core/libraries/SqrtPriceMath.sol";
import { FullMath } from "@v4-core/libraries/FullMath.sol";
import { StateLibrary } from "@v4-core/libraries/StateLibrary.sol";
import { IPoolManager } from "@v4-core/interfaces/IPoolManager.sol";
import { PoolId, PoolIdLibrary } from "@v4-core/types/PoolId.sol";
import { PoolKey } from "@v4-core/types/PoolKey.sol";
import { Currency, CurrencyLibrary } from "@v4-core/types/Currency.sol";
import { IHooks } from "@v4-core/interfaces/IHooks.sol";
import { BalanceDelta, BalanceDeltaLibrary } from "@v4-core/types/BalanceDelta.sol";

import { WAD } from "src/types/Wad.sol";
import { MiniV4Manager, Position } from "src/base/MiniV4Manager.sol";
import { Airlock } from "src/Airlock.sol";
import { IPoolInitializer } from "src/interfaces/IPoolInitializer.sol";
import { ImmutableAirlock } from "src/base/ImmutableAirlock.sol";
import { BeneficiaryData } from "src/types/BeneficiaryData.sol";
import { isTickAligned, alignTick, isRangeOrdered } from "src/libraries/TickLibrary.sol";
import { calculateLpTail, calculatePositions, calculateLogNormalDistribution } from "src/libraries/Multicurve.sol";

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

/// @notice Thrown when the max share to be sold exceeds the maximum unit
error MaxShareToBeSoldExceeded(uint256 value, uint256 limit);

/// @notice Thrown when a mismatched info length for curves
error InvalidArrayLength();

error ZeroPosition(uint256 index);

error ZeroMaxShare(uint256 index);

/// @dev Thrown when the beneficiaries are not in ascending order
error UnorderedBeneficiaries();

/// @notice Thrown when shares are invalid
error InvalidShares();

/// @notice Thrown when protocol owner beneficiary is not found
error InvalidProtocolOwnerBeneficiary();

/// @notice Thrown when total shares are not equal to WAD
error InvalidTotalShares();

/// @notice Thrown when protocol owner shares are invalid
error InvalidProtocolOwnerShares();

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
    BeneficiaryData[] beneficiaries;
    Position[] positions;
    PoolStatus status;
    PoolKey poolKey;
}

//
//                   Normalized liquidity (k) at price (%)
//
// 100 |                                                       █████████
//     |                                                       █████████
//  80 |                                                       █████████
//     |                                                   █████████████
//  60 |                                             ███████████████████
//     |                                       █████████████████████████
//  40 |                               █████████████████████████████████
//     |                       █████████████████████████████████████████
//  20 |                 ███████████████████████████████████████████████
//     |           █████████████████████████████████████████████████████
//   0 |     ███████████████████████████████████████████████████████████
//     └───────┬───────┬───────┬───────┬───────┬───────┬───────┬───────┬
//          0.825   0.850   0.875   0.900   0.925   0.950   0.975   1.000
//                                     Price
//
contract UniswapV4MulticurveInitializer is IPoolInitializer, ImmutableAirlock, MiniV4Manager {
    using StateLibrary for IPoolManager;
    using PoolIdLibrary for PoolKey;
    using CurrencyLibrary for Currency;
    using BalanceDeltaLibrary for BalanceDelta;

    /// @notice Address of the Uniswap V4 Multicurve hook
    IHooks public immutable hook;

    /// @notice Returns the state of a pool
    mapping(address asset => PoolState state) public getState;

    mapping(address asset => uint256 cumulatedFees0) public getCumulatedFees0;
    mapping(address asset => uint256 cumulatedFees1) public getCumulatedFees1;

    mapping(address asset => mapping(address beneficiary => uint256 lastCumulatedFees0)) public getLastCumulatedFees0;
    mapping(address asset => mapping(address beneficiary => uint256 lastCumulatedFees1)) public getLastCumulatedFees1;

    mapping(address asset => mapping(address beneficiary => uint256 shares)) public getShares;

    /**
     * @param airlock_ Address of the Airlock contract
     * @param poolManager_ Address of the Uniswap V4 pool manager
     */
    constructor(
        address airlock_,
        IPoolManager poolManager_,
        IHooks hook_
    ) ImmutableAirlock(airlock_) MiniV4Manager(poolManager_) {
        hook = hook_;
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

        PoolKey memory poolKey = PoolKey({
            currency0: asset < numeraire ? Currency.wrap(asset) : Currency.wrap(numeraire),
            currency1: asset < numeraire ? Currency.wrap(numeraire) : Currency.wrap(asset),
            hooks: hook,
            fee: fee,
            tickSpacing: tickSpacing
        });

        bool isToken0 = asset == Currency.unwrap(poolKey.currency0);

        int24 lowerTickBoundary = TickMath.MIN_TICK;
        int24 upperTickBoundary = TickMath.MAX_TICK;

        // Check the curves to see if they are safe
        for (uint256 i; i != numCurves; ++i) {
            require(numPositions[i] > 0, ZeroPosition(i));
            require(shareToBeSold[i] > 0, ZeroMaxShare(i));

            totalShareToBeSold += shareToBeSold[i];

            int24 currentTickLower = tickLower[i];
            int24 currentTickUpper = tickUpper[i];

            isTickAligned(currentTickLower, tickSpacing);
            isTickAligned(currentTickUpper, tickSpacing);
            isRangeOrdered(currentTickLower, currentTickUpper);

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
        isRangeOrdered(lowerTickBoundary, upperTickBoundary);

        uint160 sqrtPriceX96 = TickMath.getSqrtPriceAtTick(isToken0 ? lowerTickBoundary : upperTickBoundary);

        poolManager.initialize(poolKey, sqrtPriceX96);

        Position[] memory positions = calculatePositions(
            poolKey, isToken0, numPositions, tickLower, tickUpper, shareToBeSold, totalTokensOnBondingCurve
        );

        require(getState[asset].status == PoolStatus.Uninitialized, PoolAlreadyInitialized());

        PoolState memory state = PoolState({
            numeraire: numeraire,
            tickLower: tickLower,
            tickUpper: tickUpper,
            shareToBeSold: shareToBeSold,
            beneficiaries: beneficiaries,
            positions: positions,
            status: beneficiaries.length != 0 ? PoolStatus.Locked : PoolStatus.Initialized,
            poolKey: poolKey
        });

        getState[asset] = state;

        _mint(poolKey, positions);

        emit Create(address(poolManager), asset, numeraire);

        if (beneficiaries.length != 0) {
            _validateBeneficiaries(asset, airlock.owner(), beneficiaries);
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
     * @notice Collects fees from a locked Uniswap V4 pool, distributes to the caller if applicable
     * @dev Collected fees are now held in this contract until they are claimed by their beneficiary
     * @param asset Address of the asset token
     * @return fees0 Total fees collected in token0 since last collection
     * @return fees1 Total fees collected in token1 since last collection
     */
    function collectFees(
        address asset
    ) external returns (uint256 fees0, uint256 fees1) {
        PoolState memory state = getState[asset];
        require(state.status == PoolStatus.Locked, PoolLocked());

        BalanceDelta fees = _collect(state.poolKey, state.positions);
        fees0 = uint128(fees.amount0());
        fees1 = uint128(fees.amount1());

        getCumulatedFees0[asset] += fees0;
        getCumulatedFees1[asset] += fees1;

        uint256 shares = getShares[asset][msg.sender];

        if (shares > 0) {
            uint256 delta0 = getCumulatedFees0[asset] - getLastCumulatedFees0[asset][msg.sender];
            uint256 amount0 = delta0 * shares / WAD;
            getLastCumulatedFees0[asset][msg.sender] = getCumulatedFees0[asset];
            if (amount0 > 0) state.poolKey.currency0.transfer(msg.sender, amount0);

            uint256 delta1 = getCumulatedFees1[asset] - getLastCumulatedFees1[asset][msg.sender];
            uint256 amount1 = delta1 * shares / WAD;
            getLastCumulatedFees1[asset][msg.sender] = getCumulatedFees1[asset];
            if (amount1 > 0) state.poolKey.currency1.transfer(msg.sender, amount1);

            emit Collect(asset, msg.sender, amount0, amount1);
        }
    }

    function _validateBeneficiaries(
        address asset,
        address protocolOwner,
        BeneficiaryData[] memory beneficiaries
    ) internal {
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

            getShares[asset][prevBeneficiary] = beneficiary.shares;
        }

        require(totalShares == WAD, InvalidTotalShares());
        require(foundProtocolOwner, InvalidProtocolOwnerBeneficiary());
    }
}
