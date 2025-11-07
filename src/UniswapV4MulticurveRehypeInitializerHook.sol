// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.24;

import { BaseHook } from "@v4-periphery/utils/BaseHook.sol";
import { IPoolManager } from "@v4-core/interfaces/IPoolManager.sol";
import { Hooks } from "@v4-core/libraries/Hooks.sol";
import { BalanceDelta, BalanceDeltaLibrary } from "@v4-core/types/BalanceDelta.sol";
import { PoolKey } from "@v4-core/types/PoolKey.sol";
import { PoolId } from "@v4-core/types/PoolId.sol";
import { UniswapV4MulticurveRehypeInitializer } from "src/UniswapV4MulticurveRehypeInitializer.sol";
import { TickMath } from "@v4-core/libraries/TickMath.sol";
import { BeforeSwapDelta, BeforeSwapDeltaLibrary, toBeforeSwapDelta } from "@v4-core/types/BeforeSwapDelta.sol";
import { StateLibrary } from "@v4-core/libraries/StateLibrary.sol";
import { ProtocolFeeLibrary } from "@v4-core/libraries/ProtocolFeeLibrary.sol";
import { Position } from "src/types/Position.sol";
import { FullMath } from "@v4-core/libraries/FullMath.sol";
import { Currency, CurrencyLibrary } from "@v4-core/types/Currency.sol";
import { Quoter } from "@quoter/Quoter.sol";
import { LiquidityAmounts } from "@v4-periphery/libraries/LiquidityAmounts.sol";
import { MigrationMath } from "src/libraries/MigrationMath.sol";
import { IERC20 } from "lib/universal-router/lib/v4-periphery/lib/v4-core/lib/forge-std/src/interfaces/IERC20.sol";
import { console } from "forge-std/console.sol";

// goals
// - create an empty full range LP position given tickSpacing
// - save that position so that we can rehype it later
// - when a swap happens, we should dynamically update the fee, and do a self swap to get 50/50
// - when we get 50/50, we should add liquidity to the full range LP position
// - after all is said and done, we should update the fee back to its original value

/// @notice Thrown when the caller is not the Uniswap V4 Multicurve Initializer
error OnlyInitializer();

/**
 * @notice Emitted when liquidity is modified
 * @param key Key of the related pool
 * @param params Parameters of the liquidity modification
 */
event ModifyLiquidity(PoolKey key, IPoolManager.ModifyLiquidityParams params);

/**
 * @notice Emitted when a Swap occurs
 * @param sender Address calling the PoolManager
 * @param poolKey Key of the related pool
 * @param poolId Id of the related pool
 * @param params Parameters of the swap
 * @param amount0 Balance denominated in token0
 * @param amount1 Balance denominated in token1
 * @param hookData Data passed to the hook
 */
event Swap(
    address indexed sender,
    PoolKey indexed poolKey,
    PoolId indexed poolId,
    IPoolManager.SwapParams params,
    int128 amount0,
    int128 amount1,
    bytes hookData
);

struct FeeDistributionData {
    address asset;
    uint128 fees0;
    uint128 fees1;
    uint24 customFee;
    uint256 buybackPercentWad;
    uint256 creatorPercentWad;
    uint256 lpPercentWad;
    uint128 creatorFees0;
    uint128 creatorFees1;
}

struct SwapSimulation {
    bool success;
    uint256 amountIn;
    uint256 amountOut;
    uint256 fees0;
    uint256 fees1;
    uint160 sqrtPriceX96;
    uint256 excess0;
    uint256 excess1;
}

uint256 constant MAX_SWAP_FEE = 1e6;
uint128 constant EPSILON = 1e6;
uint256 constant MAX_REBALANCE_ITERATIONS = 15;

/**
 * @title Uniswap V4 Multicurve Hook
 * @author Whetstone Research
 * @notice Hook used by the Uniswap V4 Multicurve Initializer to restrict liquidity
 * addition in a Uniswap V4 pool
 * @custom:security-contact security@whetstone.cc
 */
contract UniswapV4MulticurveRehypeInitializerHook is BaseHook {
    using StateLibrary for IPoolManager;
    using ProtocolFeeLibrary for *;
    using CurrencyLibrary for Currency;

    /// @notice Address of the Uniswap V4 Multicurve Initializer contract
    address public immutable INITIALIZER;
    Quoter public immutable quoter;

    mapping(PoolId poolId => Position position) public getPosition;
    mapping(PoolId poolId => FeeDistributionData feeDistribution) public getFeeDistribution;
    /**
     *
     * @dev Modifier to ensure the caller is the Uniswap V4 Multicurve Initializer
     * @param sender Address of the caller
     */
    modifier onlyInitializer(
        address sender
    ) {
        if (sender != INITIALIZER) revert OnlyInitializer();
        _;
    }

    /**
     * @notice Constructor for the Uniswap V4 Migrator Hook
     * @param manager Address of the Uniswap V4 Pool Manager
     * @param initializer Address of the Uniswap V4 Multicurve Initializer contract
     */
    constructor(
        IPoolManager manager,
        UniswapV4MulticurveRehypeInitializer initializer
    ) BaseHook(manager) {
        INITIALIZER = address(initializer);
        quoter = new Quoter(manager);
    }

    /// @inheritdoc BaseHook
    function _beforeInitialize(
        address sender,
        PoolKey calldata,
        uint160
    ) internal view override onlyInitializer(sender) returns (bytes4) {
        return BaseHook.beforeInitialize.selector;
    }

    function _afterInitialize(
        address,
        PoolKey calldata key,
        uint160,
        int24
    ) internal override returns (bytes4) {
        PoolId poolId = key.toId();
        Position storage position = getPosition[poolId];
        if (position.salt == bytes32(0)) {
            position.tickLower = int24(TickMath.minUsableTick(key.tickSpacing));
            position.tickUpper = int24(TickMath.maxUsableTick(key.tickSpacing));
            position.salt = _fullRangeSalt(poolId);
        }

        return BaseHook.afterInitialize.selector;
    }

    /// @inheritdoc BaseHook
    function _beforeAddLiquidity(
        address sender,
        PoolKey calldata,
        IPoolManager.ModifyLiquidityParams calldata,
        bytes calldata
    ) internal view override returns (bytes4) {
        if (sender == address(this) || sender == INITIALIZER) {
            return BaseHook.beforeAddLiquidity.selector;
        }
        revert OnlyInitializer();
    }

    /// @inheritdoc BaseHook
    function _afterAddLiquidity(
        address,
        PoolKey calldata key,
        IPoolManager.ModifyLiquidityParams calldata params,
        BalanceDelta,
        BalanceDelta,
        bytes calldata
    ) internal override returns (bytes4, BalanceDelta) {
        PoolId poolId = key.toId();
        Position storage storedPosition = getPosition[poolId];
        int256 liquidityDelta = params.liquidityDelta;

        if (liquidityDelta != 0) {
            if (storedPosition.salt == bytes32(0)) {
                int24 minTick = TickMath.minUsableTick(key.tickSpacing);
                int24 maxTick = TickMath.maxUsableTick(key.tickSpacing);
                if (params.tickLower == minTick || params.tickUpper == maxTick) {
                    storedPosition.tickLower = params.tickLower;
                    storedPosition.tickUpper = params.tickUpper;
                    storedPosition.salt = params.salt;
                    if (liquidityDelta > 0) {
                        storedPosition.liquidity = uint128(uint256(liquidityDelta));
                    }
                }
            } else if (storedPosition.salt == params.salt) {
                if (liquidityDelta > 0) {
                    storedPosition.liquidity += uint128(uint256(liquidityDelta));
                }
            }
        }

        emit ModifyLiquidity(key, params);
        return (BaseHook.afterAddLiquidity.selector, BalanceDeltaLibrary.ZERO_DELTA);
    }

    /// @inheritdoc BaseHook
    function _afterRemoveLiquidity(
        address,
        PoolKey calldata key,
        IPoolManager.ModifyLiquidityParams calldata params,
        BalanceDelta,
        BalanceDelta,
        bytes calldata
    ) internal override returns (bytes4, BalanceDelta) {
        emit ModifyLiquidity(key, params);
        return (BaseHook.afterRemoveLiquidity.selector, BalanceDeltaLibrary.ZERO_DELTA);
    }

    /// @inheritdoc BaseHook
    function _beforeSwap(
        address sender,
        PoolKey calldata key,
        IPoolManager.SwapParams calldata params,
        bytes calldata
    ) internal override returns (bytes4, BeforeSwapDelta, uint24) {
        if (sender == address(this)) {
            return (BaseHook.beforeSwap.selector, BeforeSwapDeltaLibrary.ZERO_DELTA, 0);
        }

        uint24 fee = getFeeDistribution[key.toId()].customFee;

        uint256 swapAmount =
            params.amountSpecified < 0 ? uint256(-params.amountSpecified) : uint256(params.amountSpecified);

        if (fee == 0 || swapAmount == 0) {
            return (BaseHook.beforeSwap.selector, BeforeSwapDeltaLibrary.ZERO_DELTA, 0);
        }

        uint256 feeAmount = FullMath.mulDiv(swapAmount, fee, MAX_SWAP_FEE);
        if (feeAmount == 0) {
            return (BaseHook.beforeSwap.selector, BeforeSwapDeltaLibrary.ZERO_DELTA, 0);
        }

        Currency feeCurrency = (params.amountSpecified < 0) == params.zeroForOne ? key.currency0 : key.currency1;

        poolManager.take(feeCurrency, address(this), feeAmount);

        if (feeCurrency == key.currency0) {
            getFeeDistribution[key.toId()].fees0 += uint128(feeAmount);
        } else {
            getFeeDistribution[key.toId()].fees1 += uint128(feeAmount);
        }

        BeforeSwapDelta returnDelta = toBeforeSwapDelta(int128(int256(feeAmount)), 0);

        return (BaseHook.beforeSwap.selector, returnDelta, 0);
    }

    /// @inheritdoc BaseHook
    function _afterSwap(
        address sender,
        PoolKey calldata key,
        IPoolManager.SwapParams calldata params,
        BalanceDelta delta,
        bytes calldata hookData
    ) internal override returns (bytes4, int128) {
        if (sender == address(this)) {
            return (BaseHook.afterSwap.selector, 0);
        }
        console.log("here?");

        PoolId poolId = key.toId();

        uint256 balance0 = getFeeDistribution[poolId].fees0;
        uint256 balance1 = getFeeDistribution[poolId].fees1;

        if (balance0 <= EPSILON && balance1 <= EPSILON) {
            return (BaseHook.afterSwap.selector, delta.amount0());
        }

        address asset = getFeeDistribution[poolId].asset;
        bool isToken0 = key.currency0 == Currency.wrap(asset);

        console.log("isToken0", isToken0);

        uint256 buybackPercentWad = getFeeDistribution[poolId].buybackPercentWad;
        uint256 creatorPercentWad = getFeeDistribution[poolId].creatorPercentWad;
        uint256 lpPercentWad = getFeeDistribution[poolId].lpPercentWad;

        uint256 buybackAmount = isToken0
            ? FullMath.mulDiv(balance1, buybackPercentWad, 1e18)
            : FullMath.mulDiv(balance0, buybackPercentWad, 1e18);

        console.log("buybackAmount", buybackAmount);

        uint256 creatorAmount0 = FullMath.mulDiv(balance0, creatorPercentWad, 1e18);
        uint256 creatorAmount1 = FullMath.mulDiv(balance1, creatorPercentWad, 1e18);

        console.log("creatorAmount0", creatorAmount0);
        console.log("creatorAmount1", creatorAmount1);

        uint256 lpAmount0 = FullMath.mulDiv(balance0, lpPercentWad, 1e18);
        uint256 lpAmount1 = FullMath.mulDiv(balance1, lpPercentWad, 1e18);

        console.log("lpAmount0", lpAmount0);
        console.log("lpAmount1", lpAmount1);

        if (buybackAmount > 0) {
            console.log("here?");
            (, uint256 buybackAmountOut, uint256 buybackAmountIn) = _executeSwap(key, !isToken0, buybackAmount);
            console.log("buybackAmountOut", buybackAmountOut);
            console.log("buybackAmountIn", buybackAmountIn);
            isToken0
                ? key.currency0.transfer(address(0), buybackAmountOut)
                : key.currency1.transfer(address(0), buybackAmountOut);
            balance0 = isToken0 ? balance0 : balance0 - buybackAmountIn;
            balance1 = isToken0 ? balance1 - buybackAmountIn : balance1;
        }
        if (creatorPercentWad > 0) {
            balance0 -= creatorAmount0;
            balance1 -= creatorAmount1;
            getFeeDistribution[poolId].creatorFees0 += uint128(creatorAmount0);
            getFeeDistribution[poolId].creatorFees1 += uint128(creatorAmount1);
        }

        (uint160 sqrtPriceX96,,,) = poolManager.getSlot0(poolId);

        Position storage position = getPosition[poolId];
        if (position.salt == bytes32(0)) {
            position.tickLower = TickMath.minUsableTick(key.tickSpacing);
            position.tickUpper = TickMath.maxUsableTick(key.tickSpacing);
            position.salt = _fullRangeSalt(poolId);
        }

        bool shouldSwap;
        bool zeroForOne;
        uint256 swapAmountIn;
        uint256 swapAmountOut;
        uint160 postSwapSqrtPrice;

        (shouldSwap, zeroForOne, swapAmountIn, swapAmountOut, postSwapSqrtPrice) =
            _rebalanceFees(key, lpAmount0, lpAmount1, sqrtPriceX96);

        if (shouldSwap && swapAmountIn > 0) {
            Currency outputCurrency = zeroForOne ? key.currency1 : key.currency0;
            if (IERC20(Currency.unwrap(outputCurrency)).balanceOf(address(poolManager)) > swapAmountOut) {
                (postSwapSqrtPrice, swapAmountOut, swapAmountIn) = _executeSwap(key, zeroForOne, swapAmountIn);
                balance0 = zeroForOne ? balance0 - swapAmountIn : balance0 + swapAmountOut;
                balance1 = zeroForOne ? balance1 + swapAmountOut : balance1 - swapAmountIn;
                _addFullRangeLiquidity(key, position, balance0, balance1, postSwapSqrtPrice);
            }
        }

        emit Swap(sender, key, key.toId(), params, delta.amount0(), delta.amount1(), hookData);

        return (BaseHook.afterSwap.selector, 0);
    }

    function _rebalanceFees(
        PoolKey memory key,
        uint256 lpAmount0,
        uint256 lpAmount1,
        uint160 sqrtPriceX96
    )
        internal
        view
        returns (bool shouldSwap, bool zeroForOne, uint256 amountIn, uint256 amountOut, uint160 newSqrtPriceX96)
    {
        (uint256 excess0, uint256 excess1) = _calculateExcess(lpAmount0, lpAmount1, sqrtPriceX96);

        if (excess0 <= EPSILON && excess1 <= EPSILON) {
            return (false, false, 0, 0, sqrtPriceX96);
        }

        zeroForOne = excess0 >= excess1;
        uint256 high = zeroForOne ? excess0 : excess1;
        uint256 low;
        SwapSimulation memory best;

        for (uint256 i; i < MAX_REBALANCE_ITERATIONS && high > 0; ++i) {
            uint256 guess = (low + high) / 2;
            if (guess == 0) guess = 1;

            SwapSimulation memory sim = _simulateSwap(key, zeroForOne, guess, lpAmount0, lpAmount1);
            if (!sim.success) {
                if (high == 0 || high == 1) {
                    break;
                }
                high = guess > 0 ? guess - 1 : 0;
                continue;
            }

            if (!best.success || _score(sim.excess0, sim.excess1) < _score(best.excess0, best.excess1)) {
                best = sim;
            }

            if (sim.excess0 <= EPSILON && sim.excess1 <= EPSILON) {
                return (true, zeroForOne, sim.amountIn, sim.amountOut, sim.sqrtPriceX96);
            }

            if (zeroForOne) {
                if (sim.excess1 > EPSILON) {
                    if (guess <= 1) break;
                    high = guess - 1;
                } else {
                    if (low == guess) {
                        if (high <= guess + 1) break;
                        low = guess;
                    } else {
                        low = guess;
                    }
                }
            } else {
                if (sim.excess0 > EPSILON) {
                    if (guess <= 1) break;
                    high = guess - 1;
                } else {
                    if (low == guess) {
                        if (high <= guess + 1) break;
                        low = guess;
                    } else {
                        low = guess;
                    }
                }
            }
        }

        if (best.success) {
            return (true, zeroForOne, best.amountIn, best.amountOut, best.sqrtPriceX96);
        }

        return (false, zeroForOne, 0, 0, sqrtPriceX96);
    }

    function _executeSwap(
        PoolKey memory key,
        bool zeroForOne,
        uint256 amountIn
    ) internal returns (uint160 sqrtPriceX96, uint256 uintOut, uint256 uintIn) {
        if (amountIn == 0) {
            (uint160 currentSqrtPrice,,,) = poolManager.getSlot0(key.toId());
            return (currentSqrtPrice, 0, 0);
        }

        BalanceDelta delta = poolManager.swap(
            key,
            IPoolManager.SwapParams({
                zeroForOne: zeroForOne,
                amountSpecified: -int256(amountIn),
                sqrtPriceLimitX96: zeroForOne ? TickMath.MIN_SQRT_PRICE + 1 : TickMath.MAX_SQRT_PRICE - 1
            }),
            new bytes(0)
        );

        _settleDelta(key, delta);
        _collectDelta(key, delta);

        uintIn = zeroForOne ? _abs(delta.amount0()) : _abs(delta.amount1());
        uintOut = zeroForOne ? _abs(delta.amount1()) : _abs(delta.amount0());

        (sqrtPriceX96,,,) = poolManager.getSlot0(key.toId());
        return (sqrtPriceX96, uintOut, uintIn);
    }

    function _addFullRangeLiquidity(
        PoolKey memory key,
        Position storage position,
        uint256 amount0,
        uint256 amount1,
        uint160 sqrtPriceX96
    ) internal returns (uint256 remaining0, uint256 remaining1) {
        uint128 liquidityDelta = LiquidityAmounts.getLiquidityForAmounts(
            sqrtPriceX96,
            TickMath.getSqrtPriceAtTick(position.tickLower),
            TickMath.getSqrtPriceAtTick(position.tickUpper),
            amount0,
            amount1
        );

        if (liquidityDelta == 0) {
            return (amount0, amount1);
        }

        (BalanceDelta balanceDelta,) = poolManager.modifyLiquidity(
            key,
            IPoolManager.ModifyLiquidityParams({
                tickLower: position.tickLower,
                tickUpper: position.tickUpper,
                liquidityDelta: int256(uint256(liquidityDelta)),
                salt: position.salt
            }),
            new bytes(0)
        );

        _settleDelta(key, balanceDelta);
        _collectDelta(key, balanceDelta);

        position.liquidity += liquidityDelta;

        uint256 used0 = balanceDelta.amount0() < 0 ? uint256(uint128(-balanceDelta.amount0())) : 0;
        uint256 used1 = balanceDelta.amount1() < 0 ? uint256(uint128(-balanceDelta.amount1())) : 0;
        uint256 received0 = balanceDelta.amount0() > 0 ? uint256(uint128(balanceDelta.amount0())) : 0;
        uint256 received1 = balanceDelta.amount1() > 0 ? uint256(uint128(balanceDelta.amount1())) : 0;

        remaining0 = amount0 + received0;
        remaining0 = used0 > remaining0 ? 0 : remaining0 - used0;

        remaining1 = amount1 + received1;
        remaining1 = used1 > remaining1 ? 0 : remaining1 - used1;

        getFeeDistribution[key.toId()].fees0 = uint128(remaining0);
        getFeeDistribution[key.toId()].fees1 = uint128(remaining1);
    }

    function _settleDelta(
        PoolKey memory key,
        BalanceDelta delta
    ) internal {
        if (delta.amount0() < 0) _pay(key.currency0, uint256(uint128(-delta.amount0())));
        if (delta.amount1() < 0) _pay(key.currency1, uint256(uint128(-delta.amount1())));
    }

    function _collectDelta(
        PoolKey memory key,
        BalanceDelta delta
    ) internal {
        if (delta.amount0() > 0) {
            poolManager.take(key.currency0, address(this), uint128(delta.amount0()));
        }
        if (delta.amount1() > 0) {
            poolManager.take(key.currency1, address(this), uint128(delta.amount1()));
        }
    }

    function _pay(
        Currency currency,
        uint256 amount
    ) internal {
        if (amount == 0) return;
        poolManager.sync(currency);
        if (currency.isAddressZero()) {
            poolManager.settle{ value: amount }();
        } else {
            currency.transfer(address(poolManager), amount);
            poolManager.settle();
        }
    }

    function _simulateSwap(
        PoolKey memory key,
        bool zeroForOne,
        uint256 guess,
        uint256 fees0,
        uint256 fees1
    ) internal view returns (SwapSimulation memory simulation) {
        if (guess == 0) return simulation;
        if (zeroForOne && guess > fees0) return simulation;
        if (!zeroForOne && guess > fees1) return simulation;

        try quoter.quoteSingle(
            key,
            IPoolManager.SwapParams({
                zeroForOne: zeroForOne,
                amountSpecified: -int256(guess),
                sqrtPriceLimitX96: zeroForOne ? TickMath.MIN_SQRT_PRICE + 1 : TickMath.MAX_SQRT_PRICE - 1
            })
        ) returns (
            int256 amount0, int256 amount1, uint160 sqrtPriceAfterX96, uint32
        ) {
            if (zeroForOne) {
                if (amount0 >= 0 || amount1 <= 0) return simulation;
                uint256 amountIn = uint256(-amount0);
                if (amountIn > fees0) return simulation;
                uint256 amountOut = uint256(amount1);
                simulation.success = true;
                simulation.amountIn = amountIn;
                simulation.amountOut = amountOut;
                simulation.fees0 = fees0 - amountIn;
                simulation.fees1 = fees1 + amountOut;
            } else {
                if (amount1 >= 0 || amount0 <= 0) return simulation;
                uint256 amountIn = uint256(-amount1);
                if (amountIn > fees1) return simulation;
                uint256 amountOut = uint256(amount0);
                simulation.success = true;
                simulation.amountIn = amountIn;
                simulation.amountOut = amountOut;
                simulation.fees0 = fees0 + amountOut;
                simulation.fees1 = fees1 - amountIn;
            }

            simulation.sqrtPriceX96 = sqrtPriceAfterX96;
            (simulation.excess0, simulation.excess1) =
                _calculateExcess(simulation.fees0, simulation.fees1, sqrtPriceAfterX96);
        } catch {
            return simulation;
        }
    }

    function _calculateExcess(
        uint256 fees0,
        uint256 fees1,
        uint160 sqrtPriceX96
    ) internal pure returns (uint256 excess0, uint256 excess1) {
        (uint256 depositAmount0, uint256 depositAmount1) =
            MigrationMath.computeDepositAmounts(fees0, fees1, sqrtPriceX96);

        if (depositAmount0 > fees0) {
            (, depositAmount1) = MigrationMath.computeDepositAmounts(fees0, depositAmount1, sqrtPriceX96);
            excess0 = 0;
            excess1 = fees1 > depositAmount1 ? fees1 - depositAmount1 : 0;
        } else {
            (depositAmount0,) = MigrationMath.computeDepositAmounts(depositAmount0, fees1, sqrtPriceX96);
            excess0 = fees0 > depositAmount0 ? fees0 - depositAmount0 : 0;
            excess1 = 0;
        }
    }

    function _fullRangeSalt(
        PoolId poolId
    ) internal view returns (bytes32) {
        return keccak256(abi.encodePacked(address(this), PoolId.unwrap(poolId)));
    }

    function _score(
        uint256 excess0,
        uint256 excess1
    ) internal pure returns (uint256) {
        return excess0 > excess1 ? excess0 : excess1;
    }

    function _abs(
        int256 value
    ) internal pure returns (uint256) {
        return value < 0 ? uint256(-value) : uint256(value);
    }

    function setFeeDistributionForPool(
        PoolId poolId,
        address asset,
        uint24 customFee,
        uint256 buybackPercentWad,
        uint256 creatorPercentWad,
        uint256 lpPercentWad
    ) external onlyInitializer(msg.sender) {
        require(buybackPercentWad + creatorPercentWad + lpPercentWad == 1e18, "Fee distribution must add up to 1e18");
        getFeeDistribution[poolId] = FeeDistributionData({
            asset: asset,
            fees0: 0,
            fees1: 0,
            buybackPercentWad: buybackPercentWad,
            creatorPercentWad: creatorPercentWad,
            lpPercentWad: lpPercentWad,
            customFee: customFee,
            creatorFees0: 0,
            creatorFees1: 0
        });
    }

    /// @inheritdoc BaseHook
    function getHookPermissions() public pure override returns (Hooks.Permissions memory) {
        return Hooks.Permissions({
            beforeInitialize: true,
            afterInitialize: true,
            beforeAddLiquidity: true,
            beforeRemoveLiquidity: false,
            afterAddLiquidity: true,
            afterRemoveLiquidity: true,
            beforeSwap: true,
            afterSwap: true,
            beforeDonate: false,
            afterDonate: false,
            beforeSwapReturnDelta: true,
            afterSwapReturnDelta: false,
            afterAddLiquidityReturnDelta: false,
            afterRemoveLiquidityReturnDelta: false
        });
    }
}

interface IRehypeHook {
    function setFeesForPool(
        PoolId poolId,
        uint24 customFee
    ) external;

    function setFeeDistributionForPool(
        PoolId poolId,
        address asset,
        uint24 customFee,
        uint256 buybackPercentWad,
        uint256 creatorPercentWad,
        uint256 lpPercentWad
    ) external;

    function collectFees(
        PoolId poolId
    ) external;
}
