// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.26;

import { Quoter } from "@quoter/Quoter.sol";
import { IPoolManager } from "@v4-core/interfaces/IPoolManager.sol";
import { FullMath } from "@v4-core/libraries/FullMath.sol";
import { StateLibrary } from "@v4-core/libraries/StateLibrary.sol";
import { TickMath } from "@v4-core/libraries/TickMath.sol";
import { BalanceDelta, toBalanceDelta } from "@v4-core/types/BalanceDelta.sol";
import { Currency, CurrencyLibrary } from "@v4-core/types/Currency.sol";
import { PoolId } from "@v4-core/types/PoolId.sol";
import { PoolKey } from "@v4-core/types/PoolKey.sol";
import { LiquidityAmounts } from "@v4-periphery/libraries/LiquidityAmounts.sol";
import { BaseDopplerHook } from "src/base/BaseDopplerHook.sol";
import { DopplerHookInitializer } from "src/initializers/DopplerHookInitializer.sol";
import { MigrationMath } from "src/libraries/MigrationMath.sol";
import { BeneficiaryData } from "src/types/BeneficiaryData.sol";
import { Position } from "src/types/Position.sol";
import { FeeDistributionInfo, HookFees, PoolInfo, SwapSimulation } from "src/types/RehypeTypes.sol";
import { WAD } from "src/types/Wad.sol";

/// @notice Thrown when the fee distribution does not add up to WAD (1e18)
error FeeDistributionMustAddUpToWAD();

/// @notice Thrown when the sender is not authorized to perform an action
error SenderNotAuthorized();

/// @notice Thrown when the sender is not the airlock owner
error SenderNotAirlockOwner();

/**
 * @notice Emitted when Airlock owner claims fees
 * @param poolId Pool from which fees were claimed
 * @param airlockOwner Address that received the fees
 * @param fees0 Amount of currency0 claimed
 * @param fees1 Amount of currency1 claimed
 */
event AirlockOwnerFeesClaimed(PoolId indexed poolId, address indexed airlockOwner, uint128 fees0, uint128 fees1);

// Constants
/// @dev Maximum swap fee denominator (1e6 = 100%)
uint256 constant MAX_SWAP_FEE = 1e6;

/// @dev Epsilon trigger for rebalancing swaps
uint128 constant EPSILON = 1e6;

/// @dev Maximum iterations for rebalancing swap calculation
uint256 constant MAX_REBALANCE_ITERATIONS = 15;

/// @dev Airlock owner fee in basis points (5% = 500 BPS)
uint256 constant AIRLOCK_OWNER_FEE_BPS = 500;

/// @dev Basis points denominator
uint256 constant BPS_DENOMINATOR = 10_000;

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

    receive() external payable { }

    /**
     * @param initializer Address of the DopplerHookInitializer contract
     * @param poolManager_ Address of the Uniswap V4 Pool Manager
     */
    constructor(address initializer, IPoolManager poolManager_) BaseDopplerHook(initializer) {
        poolManager = poolManager_;
        quoter = new Quoter(poolManager_);
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

        getHookFees[poolId].customFee = customFee;

        // Initialize position
        getPosition[poolId] = Position({
            tickLower: TickMath.minUsableTick(key.tickSpacing),
            tickUpper: TickMath.maxUsableTick(key.tickSpacing),
            liquidity: 0,
            salt: _fullRangeSalt(poolId)
        });
    }

    /// @inheritdoc BaseDopplerHook
    function _onSwap(
        address sender,
        PoolKey calldata key,
        IPoolManager.SwapParams calldata params,
        BalanceDelta delta,
        bytes calldata
    ) internal override returns (Currency, int128) {
        if (sender == address(this)) {
            return (Currency.wrap(address(0)), 0);
        }

        PoolId poolId = key.toId();

        (Currency feeCurrency, int128 hookDelta) = _collectSwapFees(params, delta, key, poolId);

        uint256 balance0 = getHookFees[poolId].fees0;
        uint256 balance1 = getHookFees[poolId].fees1;

        if (balance0 <= EPSILON && balance1 <= EPSILON) {
            return (feeCurrency, hookDelta);
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

        address recipient = getPoolInfo[poolId].buybackDst;

        if (assetBuybackAmountIn > 0) {
            (, uint256 assetBuybackAmountOut, uint256 assetBuybackAmountInUsed) =
                _executeSwap(key, !isToken0, assetBuybackAmountIn);
            isToken0
                ? key.currency0.transfer(recipient, assetBuybackAmountOut)
                : key.currency1.transfer(recipient, assetBuybackAmountOut);
            balance0 = isToken0 ? balance0 : balance0 - assetBuybackAmountInUsed;
            balance1 = isToken0 ? balance1 - assetBuybackAmountInUsed : balance1;
        }

        if (numeraireBuybackAmountIn > 0) {
            Currency outputCurrency = isToken0 ? key.currency1 : key.currency0;
            SwapSimulation memory sim = _simulateSwap(
                key, isToken0, numeraireBuybackAmountIn, isToken0 ? balance0 : 0, isToken0 ? 0 : balance1
            );
            uint256 poolManagerOutputBalance = outputCurrency.balanceOf(address(poolManager));
            if (sim.success && sim.amountOut > 0 && poolManagerOutputBalance >= sim.amountOut) {
                (, uint256 numeraireBuybackAmountOutResult, uint256 numeraireBuybackAmountInUsed) =
                    _executeSwap(key, isToken0, numeraireBuybackAmountIn);
                isToken0
                    ? key.currency1.transfer(recipient, numeraireBuybackAmountOutResult)
                    : key.currency0.transfer(recipient, numeraireBuybackAmountOutResult);
                balance0 = isToken0 ? balance0 - numeraireBuybackAmountInUsed : balance0;
                balance1 = isToken0 ? balance1 : balance1 - numeraireBuybackAmountInUsed;
            }
        }

        (uint160 sqrtPriceX96,,,) = poolManager.getSlot0(poolId);

        Position storage position = getPosition[poolId];
        (bool shouldSwap, bool zeroForOne, uint256 swapAmountIn, uint256 swapAmountOut, uint160 postSwapSqrtPrice) =
            _rebalanceFees(key, lpAmount0, lpAmount1, sqrtPriceX96);
        if (shouldSwap && swapAmountIn > 0) {
            Currency outputCurrency = zeroForOne ? key.currency1 : key.currency0;
            if (outputCurrency.balanceOf(address(poolManager)) > swapAmountOut) {
                (postSwapSqrtPrice, swapAmountOut, swapAmountIn) = _executeSwap(key, zeroForOne, swapAmountIn);
                lpAmount0 = zeroForOne ? lpAmount0 - swapAmountIn : lpAmount0 + swapAmountOut;
                lpAmount1 = zeroForOne ? lpAmount1 + swapAmountOut : lpAmount1 - swapAmountIn;
                BalanceDelta liquidityDelta =
                    _addFullRangeLiquidity(key, position, lpAmount0, lpAmount1, postSwapSqrtPrice);
                balance0 =
                    uint256(int256(zeroForOne ? balance0 - swapAmountIn : balance0 + swapAmountOut) + liquidityDelta.amount0());
                balance1 =
                    uint256(int256(zeroForOne ? balance1 + swapAmountOut : balance1 - swapAmountIn) + liquidityDelta.amount1());
            }
        }

        getHookFees[poolId].beneficiaryFees0 += uint128(balance0);
        getHookFees[poolId].beneficiaryFees1 += uint128(balance1);

        getHookFees[poolId].fees0 = 0;
        getHookFees[poolId].fees1 = 0;

        return (feeCurrency, hookDelta);
    }

    /**
     * @dev Calculates the optimal swap to rebalance fees for LP reinvestment
     * @param key Uniswap V4 pool key
     * @param lpAmount0 Available amount in currency0
     * @param lpAmount1 Available amount in currency1
     * @param sqrtPriceX96 Current square root price of the pool
     * @return shouldSwap Whether a swap should be executed
     * @return zeroForOne Direction of the swap
     * @return amountIn Amount to swap in
     * @return amountOut Amount to receive from the swap
     * @return newSqrtPriceX96 New square root price after the swap
     */
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

    /**
     * @dev Executes a swap on the pool
     * @param key Uniswap V4 pool key
     * @param zeroForOne Direction of the swap
     * @param amountIn Amount to swap in
     * @return sqrtPriceX96 New square root price after the swap
     * @return uintOut Amount received from the swap
     * @return uintIn Amount swapped in
     */
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

    /**
     * @dev Adds full range liquidity to the pool
     * @param key Uniswap V4 pool key
     * @param position Position data
     * @param amount0 Amount of currency0 to add
     * @param amount1 Amount of currency1 to add
     * @param sqrtPriceX96 Current square root price of the pool
     * @return callerDelta The balance delta (negative = paid, positive = received fees)
     */
    function _addFullRangeLiquidity(
        PoolKey memory key,
        Position storage position,
        uint256 amount0,
        uint256 amount1,
        uint160 sqrtPriceX96
    ) internal returns (BalanceDelta callerDelta) {
        uint128 liquidityDelta;

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
            return toBalanceDelta(0, 0);
        }

        (callerDelta,) = poolManager.modifyLiquidity(
            key,
            IPoolManager.ModifyLiquidityParams({
                tickLower: position.tickLower,
                tickUpper: position.tickUpper,
                liquidityDelta: int256(uint256(liquidityDelta)),
                salt: position.salt
            }),
            new bytes(0)
        );

        _settleDelta(key, callerDelta);
        _collectDelta(key, callerDelta);

        position.liquidity += liquidityDelta;
    }

    /**
     * @dev Settles a BalanceDelta by paying the required amounts to the pool manager
     * @param key Uniswap V4 pool key
     * @param delta BalanceDelta to settle
     */
    function _settleDelta(PoolKey memory key, BalanceDelta delta) internal {
        if (delta.amount0() < 0) _pay(key.currency0, uint256(uint128(-delta.amount0())));
        if (delta.amount1() < 0) _pay(key.currency1, uint256(uint128(-delta.amount1())));
    }

    /**
     * @dev Collects amounts from the pool manager based on a BalanceDelta
     * @param key Uniswap V4 pool key
     * @param delta BalanceDelta to collect
     */
    function _collectDelta(PoolKey memory key, BalanceDelta delta) internal {
        if (delta.amount0() > 0) {
            poolManager.take(key.currency0, address(this), uint128(delta.amount0()));
        }
        if (delta.amount1() > 0) {
            poolManager.take(key.currency1, address(this), uint128(delta.amount1()));
        }
    }

    /**
     * @dev Pays the specified amount of currency to the pool manager
     * @param currency Currency to pay
     * @param amount Amount to pay
     */
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

    /**
     * @dev Simulates a swap on the pool
     * @param key Uniswap V4 pool key
     * @param zeroForOne Direction of the swap
     * @param guess Amount to swap in
     * @param fees0 Available fees in currency0
     * @param fees1 Available fees in currency1
     * @return simulation Result of the swap simulation
     */
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

    /**
     * @dev Calculates excess amounts for LP reinvestment
     * @param fees0 Available fees in currency0
     * @param fees1 Available fees in currency1
     * @param sqrtPriceX96 Current square root price of the pool
     * @return excess0 Excess amount in currency0
     * @return excess1 Excess amount in currency1
     */
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

    /**
     * @dev Generates a salt for a full range liquidity position
     * @param poolId Uniswap V4 poolId
     * @return salt Generated salt
     */
    function _fullRangeSalt(PoolId poolId) internal view returns (bytes32) {
        return keccak256(abi.encodePacked(address(this), PoolId.unwrap(poolId)));
    }

    /**
     * @dev Determines the greater of two amounts
     * @param excess0 First amount
     * @param excess1 Second amount
     * @return Greater amount
     */
    function _score(uint256 excess0, uint256 excess1) internal pure returns (uint256) {
        return excess0 > excess1 ? excess0 : excess1;
    }

    /**
     * @dev Returns the absolute value of an amount
     * @param value Amount to convert
     * @return Absolute value
     */
    function _abs(int256 value) internal pure returns (uint256) {
        return value < 0 ? uint256(-value) : uint256(value);
    }

    /**
     * @notice Collects accumulated beneficiary fees for a pool and transfers them to the associated beneficiary
     * @param asset Asset to collect fees from
     * @return fees Collected fees as a BalanceDelta
     */
    function collectFees(address asset) external returns (BalanceDelta fees) {
        (,,,,, PoolKey memory poolKey,) = DopplerHookInitializer(payable(INITIALIZER)).getState(asset);
        PoolId poolId = poolKey.toId();
        HookFees memory hookFees = getHookFees[poolId];
        address beneficiary = getPoolInfo[poolId].buybackDst;

        fees = toBalanceDelta(int128(uint128(hookFees.beneficiaryFees0)), int128(uint128(hookFees.beneficiaryFees1)));

        if (hookFees.beneficiaryFees0 > 0) {
            getHookFees[poolId].beneficiaryFees0 = 0;
            poolKey.currency0.transfer(beneficiary, hookFees.beneficiaryFees0);
        }
        if (hookFees.beneficiaryFees1 > 0) {
            getHookFees[poolId].beneficiaryFees1 = 0;
            poolKey.currency1.transfer(beneficiary, hookFees.beneficiaryFees1);
        }

        return fees;
    }

    /**
     * @notice Claims accumulated airlock owner fees for a pool
     * @param asset Asset address to identify the pool
     * @return fees0 Amount of currency0 claimed
     * @return fees1 Amount of currency1 claimed
     */
    function claimAirlockOwnerFees(address asset) external returns (uint128 fees0, uint128 fees1) {
        address airlockOwner = DopplerHookInitializer(payable(INITIALIZER)).airlock().owner();
        require(msg.sender == airlockOwner, SenderNotAirlockOwner());

        (,,,,, PoolKey memory poolKey,) = DopplerHookInitializer(payable(INITIALIZER)).getState(asset);
        PoolId poolId = poolKey.toId();

        fees0 = getHookFees[poolId].airlockOwnerFees0;
        fees1 = getHookFees[poolId].airlockOwnerFees1;

        if (fees0 > 0) {
            getHookFees[poolId].airlockOwnerFees0 = 0;
            poolKey.currency0.transfer(msg.sender, fees0);
        }
        if (fees1 > 0) {
            getHookFees[poolId].airlockOwnerFees1 = 0;
            poolKey.currency1.transfer(msg.sender, fees1);
        }

        emit AirlockOwnerFeesClaimed(poolId, msg.sender, fees0, fees1);
    }

    /**
     * @notice Updates the fee distribution for a pool
     * @param poolId Uniswap V4 poolId
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
    ) external {
        address buybackDst = getPoolInfo[poolId].buybackDst;
        require(msg.sender == buybackDst, SenderNotAuthorized());

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
     * @dev Collects swap fees from a swap and updates hook fee tracking
     * @param params Parameters of the swap
     * @param delta BalanceDelta of the swap
     * @param key Uniswap V4 pool key
     * @param poolId Uniswap V4 poolId (to save gas)
     * @return feeCurrency Currency in which the fee was collected (always the unspecified token)
     * @return feeDelta Amount of fee collected in feeCurrency
     */
    function _collectSwapFees(
        IPoolManager.SwapParams memory params,
        BalanceDelta delta,
        PoolKey memory key,
        PoolId poolId
    ) internal returns (Currency feeCurrency, int128 feeDelta) {
        bool outputIsToken0 = params.zeroForOne ? false : true;
        int256 outputAmount = outputIsToken0 ? delta.amount0() : delta.amount1();

        if (outputAmount <= 0) {
            return (feeCurrency, feeDelta);
        }

        bool exactInput = params.amountSpecified < 0;

        // Fee is always taken from the unspecified token:
        if (exactInput) {
            feeCurrency = outputIsToken0 ? key.currency0 : key.currency1;
        } else {
            feeCurrency = params.zeroForOne ? key.currency0 : key.currency1;
        }

        // Compute fee based on the feeCurrency amount 
        uint256 feeBase;
        if (exactInput) {
            // For exact input, fee is of output
            feeBase = uint256(outputAmount);
        } else {
            // For exact output, fee is of input 
            int256 inputAmount = params.zeroForOne ? delta.amount0() : delta.amount1();
            feeBase = uint256(-inputAmount);
        }

        uint256 feeAmount = FullMath.mulDiv(feeBase, getHookFees[poolId].customFee, MAX_SWAP_FEE);
        uint256 balanceOfFeeCurrency = feeCurrency.balanceOf(address(poolManager));

        if (balanceOfFeeCurrency < feeAmount) {
            return (feeCurrency, feeDelta);
        }

        poolManager.take(feeCurrency, address(this), feeAmount);

        // Calculate airlock owner fee (5% of total fee)
        uint256 airlockOwnerFee = FullMath.mulDiv(feeAmount, AIRLOCK_OWNER_FEE_BPS, BPS_DENOMINATOR);
        uint256 remainingFee = feeAmount - airlockOwnerFee;

        if (feeCurrency == key.currency0) {
            getHookFees[poolId].airlockOwnerFees0 += uint128(airlockOwnerFee);
            getHookFees[poolId].fees0 += uint128(remainingFee);
        } else {
            getHookFees[poolId].airlockOwnerFees1 += uint128(airlockOwnerFee);
            getHookFees[poolId].fees1 += uint128(remainingFee);
        }

        return (feeCurrency, int128(uint128(feeAmount)));
    }
}

