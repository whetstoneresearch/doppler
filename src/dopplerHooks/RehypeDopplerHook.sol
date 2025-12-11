// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.26;

import { Quoter } from "@quoter/Quoter.sol";
import { IPoolManager } from "@v4-core/interfaces/IPoolManager.sol";
import { FullMath } from "@v4-core/libraries/FullMath.sol";
import { StateLibrary } from "@v4-core/libraries/StateLibrary.sol";
import { TickMath } from "@v4-core/libraries/TickMath.sol";
import { BalanceDelta } from "@v4-core/types/BalanceDelta.sol";
import { toBalanceDelta } from "@v4-core/types/BalanceDelta.sol";
import { Currency, CurrencyLibrary } from "@v4-core/types/Currency.sol";
import { PoolId } from "@v4-core/types/PoolId.sol";
import { PoolKey } from "@v4-core/types/PoolKey.sol";
import { LiquidityAmounts } from "@v4-periphery/libraries/LiquidityAmounts.sol";
import { console } from "forge-std/console.sol";
import { IERC20 } from "lib/universal-router/lib/v4-periphery/lib/v4-core/lib/forge-std/src/interfaces/IERC20.sol";
import { BaseDopplerHook } from "src/base/BaseDopplerHook.sol";
import { DopplerHookInitializer } from "src/initializers/DopplerHookInitializer.sol";
import { MigrationMath } from "src/libraries/MigrationMath.sol";
import { Position } from "src/types/Position.sol";
import { FeeDistributionInfo, HookFees, PoolInfo, SwapSimulation } from "src/types/RehypeTypes.sol";
import { WAD } from "src/types/Wad.sol";

/// @notice Thrown when the fee distribution does not add up to WAD (1e18)
error FeeDistributionMustAddUpToWAD();

/// @notice Thrown when caller is not authorized
error Unauthorized();

// Constants
uint256 constant MAX_SWAP_FEE = 1e6;
uint128 constant EPSILON = 1e6;
uint256 constant MAX_REBALANCE_ITERATIONS = 15;

/**
 * @title Rehype Doppler Hook
 * @author Whetstone Research
 * @custom:security-contact security@whetstone.cc
 * @notice Doppler Hook that implements fee collection, distribution, buybacks, and LP fee reinvestment
 */
contract RehypeDopplerHook is BaseDopplerHook {
    using StateLibrary for IPoolManager;
    using CurrencyLibrary for Currency;

    /// @notice Address of the Uniswap V4 Pool Manager
    IPoolManager public immutable poolManager;

    /// @notice Quoter contract for simulating swaps
    Quoter public immutable quoter;

    /// @notice Position data for each pool
    mapping(PoolId poolId => Position position) public getPosition;

    /// @notice Fee distribution configuration for each pool
    mapping(PoolId poolId => FeeDistributionInfo feeDistributionInfo) public getFeeDistributionInfo;

    /// @notice Hook fees tracking for each pool
    mapping(PoolId poolId => HookFees hookFees) public getHookFees;

    /// @notice Pool info for each pool
    mapping(PoolId poolId => PoolInfo poolInfo) public getPoolInfo;

    /**
     * @param initializer Address of the DopplerHookInitializer contract
     * @param _poolManager Address of the Uniswap V4 Pool Manager
     */
    constructor(address initializer, IPoolManager _poolManager) BaseDopplerHook(initializer) {
        poolManager = _poolManager;
        quoter = new Quoter(_poolManager);
    }

    /// @inheritdoc BaseDopplerHook
    function _onInitialization(address asset, PoolKey calldata key, bytes calldata data) internal override {
        (
            address numeraire,
            address buybackDst,
            uint24 customFee,
            uint256 assetBuybackPercentWad,
            uint256 numeraireBuybackPercentWad,
            uint256 beneficiaryPercentWad,
            uint256 lpPercentWad
        ) = abi.decode(data, (address, address, uint24, uint256, uint256, uint256, uint256));

        require(
            assetBuybackPercentWad + numeraireBuybackPercentWad + beneficiaryPercentWad + lpPercentWad == WAD,
            FeeDistributionMustAddUpToWAD()
        );

        PoolId poolId = key.toId();

        getPoolInfo[poolId] = PoolInfo({ asset: asset, numeraire: numeraire, buybackDst: buybackDst });

        getFeeDistributionInfo[poolId] = FeeDistributionInfo({
            assetBuybackPercentWad: assetBuybackPercentWad,
            numeraireBuybackPercentWad: numeraireBuybackPercentWad,
            beneficiaryPercentWad: beneficiaryPercentWad,
            lpPercentWad: lpPercentWad
        });

        getHookFees[poolId] =
            HookFees({ customFee: customFee, fees0: 0, fees1: 0, beneficiaryFees0: 0, beneficiaryFees1: 0 });

        // Initialize position
        Position storage position = getPosition[poolId];
        position.tickLower = TickMath.minUsableTick(key.tickSpacing);
        position.tickUpper = TickMath.maxUsableTick(key.tickSpacing);
        position.salt = _fullRangeSalt(poolId);
    }

    /// @inheritdoc BaseDopplerHook
    function _onSwap(
        address sender,
        PoolKey calldata key,
        IPoolManager.SwapParams calldata params,
        BalanceDelta delta,
        bytes calldata
    ) internal override {
        if (sender == address(this)) {
            return;
        }

        PoolId poolId = key.toId();
        _collectSwapFees(params, delta, key, poolId);

        uint256 balance0 = getHookFees[poolId].fees0;
        uint256 balance1 = getHookFees[poolId].fees1;
        console.log("balance0", balance0);
        console.log("balance1", balance1);

        if (balance0 <= EPSILON && balance1 <= EPSILON) {
            return;
        }

        address asset = getPoolInfo[poolId].asset;
        bool isToken0 = key.currency0 == Currency.wrap(asset);

        uint256 assetBuybackPercentWad = getFeeDistributionInfo[poolId].assetBuybackPercentWad;
        uint256 numeraireBuybackPercentWad = getFeeDistributionInfo[poolId].numeraireBuybackPercentWad;
        uint256 lpPercentWad = getFeeDistributionInfo[poolId].lpPercentWad;

        uint256 assetBuybackAmountIn = isToken0
            ? FullMath.mulDiv(balance1, assetBuybackPercentWad, WAD)
            : FullMath.mulDiv(balance0, assetBuybackPercentWad, WAD);

        uint256 numeraireBuybackAmountIn = isToken0
            ? FullMath.mulDiv(balance0, numeraireBuybackPercentWad, WAD)
            : FullMath.mulDiv(balance1, numeraireBuybackPercentWad, WAD);

        uint256 lpAmount0 = FullMath.mulDiv(balance0, lpPercentWad, WAD);
        uint256 lpAmount1 = FullMath.mulDiv(balance1, lpPercentWad, WAD);

        if (assetBuybackAmountIn > 0) {
            (, uint256 assetBuybackAmountOut, uint256 assetBuybackAmountInUsed) =
                _executeSwap(key, !isToken0, assetBuybackAmountIn);
            console.log("assetBuybackAmountOut", assetBuybackAmountOut);
            isToken0
                ? key.currency0.transfer(getPoolInfo[poolId].buybackDst, assetBuybackAmountOut)
                : key.currency1.transfer(getPoolInfo[poolId].buybackDst, assetBuybackAmountOut);
            console.log("assetBuybackAmountInUsed", assetBuybackAmountInUsed);
            balance0 = isToken0 ? balance0 : balance0 - assetBuybackAmountInUsed;
            balance1 = isToken0 ? balance1 - assetBuybackAmountInUsed : balance1;
        }
        console.log("isToken0", isToken0);

        if (numeraireBuybackAmountIn > 0) {
            Currency outputCurrency = isToken0 ? key.currency1 : key.currency0;
            SwapSimulation memory sim = _simulateSwap(
                key, isToken0, numeraireBuybackAmountIn, isToken0 ? balance0 : 0, isToken0 ? 0 : balance1
            );
            console.log("sim.success", sim.success);
            console.log("sim.amountOut", sim.amountOut);
            uint256 poolManagerOutputBalance = IERC20(Currency.unwrap(outputCurrency)).balanceOf(address(poolManager));
            if (sim.success && sim.amountOut > 0 && poolManagerOutputBalance >= sim.amountOut) {
                console.log("here");
                (, uint256 numeraireBuybackAmountOutResult, uint256 numeraireBuybackAmountInUsed) =
                    _executeSwap(key, isToken0, numeraireBuybackAmountIn);
                isToken0
                    ? key.currency1.transfer(getPoolInfo[poolId].buybackDst, numeraireBuybackAmountOutResult)
                    : key.currency0.transfer(getPoolInfo[poolId].buybackDst, numeraireBuybackAmountOutResult);
                balance0 = isToken0 ? balance0 - numeraireBuybackAmountInUsed : balance0;
                balance1 = isToken0 ? balance1 : balance1 - numeraireBuybackAmountInUsed;
                console.log("here");
            }
        }

        (uint160 sqrtPriceX96,,,) = poolManager.getSlot0(poolId);

        Position storage position = getPosition[poolId];
        console.log("rebalancing");
        (bool shouldSwap, bool zeroForOne, uint256 swapAmountIn, uint256 swapAmountOut, uint160 postSwapSqrtPrice) =
            _rebalanceFees(key, lpAmount0, lpAmount1, sqrtPriceX96);
        console.log("shouldSwap", shouldSwap);
        console.log("swapAmountIn", swapAmountIn);
        console.log("swapAmountOut", swapAmountOut);
        console.log("postSwapSqrtPrice", postSwapSqrtPrice);
        if (shouldSwap && swapAmountIn > 0) {
            console.log("here???");
            Currency outputCurrency = zeroForOne ? key.currency1 : key.currency0;
            if (IERC20(Currency.unwrap(outputCurrency)).balanceOf(address(poolManager)) > swapAmountOut) {
                (postSwapSqrtPrice, swapAmountOut, swapAmountIn) = _executeSwap(key, zeroForOne, swapAmountIn);
                lpAmount0 = zeroForOne ? lpAmount0 - swapAmountIn : lpAmount0 + swapAmountOut;
                lpAmount1 = zeroForOne ? lpAmount1 + swapAmountOut : lpAmount1 - swapAmountIn;
                (uint256 amount0Added, uint256 amount1Added) =
                    _addFullRangeLiquidity(key, position, lpAmount0, lpAmount1, postSwapSqrtPrice);
                uint256 remainder0 = lpAmount0 - amount0Added;
                uint256 remainder1 = lpAmount1 - amount1Added;
                balance0 = zeroForOne ? balance0 - (amount0Added + swapAmountIn) + remainder0 : balance0 + remainder0;
                balance1 = zeroForOne ? balance1 + remainder1 : balance1 - (amount1Added + swapAmountIn) + remainder1;
            }
        }

        getHookFees[poolId].beneficiaryFees0 += uint128(balance0);
        getHookFees[poolId].beneficiaryFees1 += uint128(balance1);

        getHookFees[poolId].fees0 = 0;
        getHookFees[poolId].fees1 = 0;
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

        BalanceDelta swapDelta = poolManager.swap(
            key,
            IPoolManager.SwapParams({
                zeroForOne: zeroForOne,
                amountSpecified: -int256(amountIn),
                sqrtPriceLimitX96: zeroForOne ? TickMath.MIN_SQRT_PRICE + 1 : TickMath.MAX_SQRT_PRICE - 1
            }),
            new bytes(0)
        );

        _settleDelta(key, swapDelta);
        _collectDelta(key, swapDelta);

        uintIn = zeroForOne ? _abs(swapDelta.amount0()) : _abs(swapDelta.amount1());
        uintOut = zeroForOne ? _abs(swapDelta.amount1()) : _abs(swapDelta.amount0());

        (sqrtPriceX96,,,) = poolManager.getSlot0(key.toId());
        return (sqrtPriceX96, uintOut, uintIn);
    }

    function _addFullRangeLiquidity(
        PoolKey memory key,
        Position storage position,
        uint256 amount0,
        uint256 amount1,
        uint160 sqrtPriceX96
    ) internal returns (uint256 amount0Added, uint256 amount1Added) {
        uint128 liquidityDelta = 0;
        if (amount0 >= 1 && amount1 >= 1) {
            liquidityDelta = LiquidityAmounts.getLiquidityForAmounts(
                sqrtPriceX96,
                TickMath.getSqrtPriceAtTick(position.tickLower),
                TickMath.getSqrtPriceAtTick(position.tickUpper),
                amount0 - 1,
                amount1 - 1
            );
        }

        if (liquidityDelta == 0) {
            return (amount0, amount1);
        }

        (BalanceDelta balanceDelta, BalanceDelta feeDelta) = poolManager.modifyLiquidity(
            key,
            IPoolManager.ModifyLiquidityParams({
                tickLower: position.tickLower,
                tickUpper: position.tickUpper,
                liquidityDelta: int256(uint256(liquidityDelta)),
                salt: position.salt
            }),
            new bytes(0)
        );

        // subtract the fees to avoid overflow when casting to uint
        BalanceDelta realizedDelta = balanceDelta - feeDelta;

        _settleDelta(key, realizedDelta);
        _collectDelta(key, realizedDelta);

        position.liquidity += liquidityDelta;

        amount0Added = uint256(uint128(-realizedDelta.amount0()));
        amount1Added = uint256(uint128(-realizedDelta.amount1()));
    }

    function _settleDelta(PoolKey memory key, BalanceDelta delta) internal {
        if (delta.amount0() < 0) _pay(key.currency0, uint256(uint128(-delta.amount0())));
        if (delta.amount1() < 0) _pay(key.currency1, uint256(uint128(-delta.amount1())));
    }

    function _collectDelta(PoolKey memory key, BalanceDelta delta) internal {
        if (delta.amount0() > 0) {
            poolManager.take(key.currency0, address(this), uint128(delta.amount0()));
        }
        if (delta.amount1() > 0) {
            poolManager.take(key.currency1, address(this), uint128(delta.amount1()));
        }
    }

    function _pay(Currency currency, uint256 amount) internal {
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
                console.log("zeroForOne");
                if (amount0 >= 0 || amount1 <= 0) return simulation;
                uint256 amountIn = uint256(-amount0);
                console.log("amountIn", amountIn);
                if (amountIn > fees0) return simulation;
                uint256 amountOut = uint256(amount1);
                simulation.success = true;
                simulation.amountIn = amountIn;
                simulation.amountOut = amountOut;
                simulation.fees0 = fees0 - amountIn;
                simulation.fees1 = fees1 + amountOut;
            } else {
                console.log("!zeroForOne");
                console.log("amount1", amount1);
                console.log("amount0", amount0);
                if (amount1 >= 0 || amount0 <= 0) return simulation;
                uint256 amountIn = uint256(-amount1);
                console.log("amountIn", amountIn);
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
            excess0 = 0;
            excess1 = fees1 > depositAmount1 ? fees1 - depositAmount1 : 0;
        } else {
            excess0 = fees0 > depositAmount0 ? fees0 - depositAmount0 : 0;
            excess1 = 0;
        }
    }

    function _fullRangeSalt(PoolId poolId) internal view returns (bytes32) {
        return keccak256(abi.encodePacked(address(this), PoolId.unwrap(poolId)));
    }

    function _score(uint256 excess0, uint256 excess1) internal pure returns (uint256) {
        return excess0 > excess1 ? excess0 : excess1;
    }

    function _abs(int256 value) internal pure returns (uint256) {
        return value < 0 ? uint256(-value) : uint256(value);
    }

    /**
     * @notice Collects accumulated beneficiary fees for a pool
     * @param asset The asset to collect fees from
     * @return fees The collected fees as a BalanceDelta
     */
    function collectFees(address asset) external returns (BalanceDelta fees) {
        (address numeraire,,,,, PoolKey memory poolKey,) = DopplerHookInitializer(payable(INITIALIZER)).getState(asset);
        PoolId poolId = poolKey.toId();
        HookFees memory hookFees = getHookFees[poolId];

        fees = toBalanceDelta(int128(uint128(hookFees.beneficiaryFees0)), int128(uint128(hookFees.beneficiaryFees1)));
        bool isToken0 = Currency.wrap(asset) == poolKey.currency0;

        if (hookFees.beneficiaryFees0 > 0) {
            Currency.wrap(asset).transfer(INITIALIZER, isToken0 ? hookFees.beneficiaryFees0 : hookFees.beneficiaryFees1);
        }
        if (hookFees.beneficiaryFees1 > 0) {
            Currency.wrap(numeraire)
                .transfer(INITIALIZER, isToken0 ? hookFees.beneficiaryFees1 : hookFees.beneficiaryFees0);
        }

        getHookFees[poolId].beneficiaryFees0 = 0;
        getHookFees[poolId].beneficiaryFees1 = 0;

        return fees;
    }

    /**
     * @notice Updates the fee distribution for a pool
     * @param poolId The pool ID to update
     * @param assetBuybackPercentWad Percentage for asset buyback (in WAD)
     * @param numeraireBuybackPercentWad Percentage for numeraire buyback (in WAD)
     * @param beneficiaryPercentWad Percentage for beneficiary (in WAD)
     * @param lpPercentWad Percentage for LP reinvestment (in WAD)
     */
    function setFeeDistribution(
        PoolId poolId,
        uint256 assetBuybackPercentWad,
        uint256 numeraireBuybackPercentWad,
        uint256 beneficiaryPercentWad,
        uint256 lpPercentWad
    ) external onlyInitializer {
        require(
            assetBuybackPercentWad + numeraireBuybackPercentWad + beneficiaryPercentWad + lpPercentWad == WAD,
            FeeDistributionMustAddUpToWAD()
        );

        getFeeDistributionInfo[poolId] = FeeDistributionInfo({
            assetBuybackPercentWad: assetBuybackPercentWad,
            numeraireBuybackPercentWad: numeraireBuybackPercentWad,
            beneficiaryPercentWad: beneficiaryPercentWad,
            lpPercentWad: lpPercentWad
        });
    }

    /**
     * @notice Updates the custom fee for a pool
     * @param poolId The pool ID to update
     * @param customFee The new custom fee (in units of 1e6)
     */
    function setCustomFee(PoolId poolId, uint24 customFee) external onlyInitializer {
        getHookFees[poolId].customFee = customFee;
    }

    /**
     * @notice Updates the buyback destination for a pool
     * @param poolId The pool ID to update
     * @param buybackDst The new buyback destination address
     */
    function setBuybackDestination(PoolId poolId, address buybackDst) external onlyInitializer {
        getPoolInfo[poolId].buybackDst = buybackDst;
    }

    /**
     * @dev Internal helper to reconstruct pool key from pool ID
     * @param poolId The pool ID
     * @return key The reconstructed key
     */
    function _getPoolKey(PoolId poolId) internal view returns (PoolKey memory key) {
        PoolInfo memory info = getPoolInfo[poolId];
        Position memory position = getPosition[poolId];

        key.currency0 = Currency.wrap(info.asset < info.numeraire ? info.asset : info.numeraire);
        key.currency1 = Currency.wrap(info.asset < info.numeraire ? info.numeraire : info.asset);
        key.tickSpacing = int24(
            (position.tickUpper - position.tickLower) / (TickMath.maxUsableTick(1) - TickMath.minUsableTick(1))
        );
    }

    function _collectSwapFees(
        IPoolManager.SwapParams memory params,
        BalanceDelta delta,
        PoolKey memory key,
        PoolId poolId
    ) internal {
        bool outputIsToken0 = params.zeroForOne ? false : true;
        int256 outputAmount = outputIsToken0 ? delta.amount0() : delta.amount1();

        if (outputAmount <= 0) {
            return;
        }

        uint256 feeAmount = FullMath.mulDiv(uint256(outputAmount), getHookFees[poolId].customFee, MAX_SWAP_FEE);
        console.log("feeAmount", feeAmount);

        bool isExactIn = params.amountSpecified < 0;
        Currency feeCurrency;
        if (isExactIn) {
            feeCurrency = outputIsToken0 ? key.currency0 : key.currency1;
        } else {
            bool inputIsToken0 = params.zeroForOne ? true : false;
            feeCurrency = inputIsToken0 ? key.currency0 : key.currency1;
        }

        uint256 balanceOfFeeCurrency = IERC20(Currency.unwrap(feeCurrency)).balanceOf(address(poolManager));
        console.log("balanceOfFeeCurrency", balanceOfFeeCurrency);

        if (balanceOfFeeCurrency < feeAmount) {
            return;
        }

        poolManager.take(feeCurrency, address(this), feeAmount);

        if (feeCurrency == key.currency0) {
            getHookFees[poolId].fees0 += uint128(feeAmount);
        } else {
            getHookFees[poolId].fees1 += uint128(feeAmount);
        }
    }
}

