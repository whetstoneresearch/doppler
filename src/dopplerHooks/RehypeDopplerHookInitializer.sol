// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.26;

import { Quoter } from "@quoter/Quoter.sol";
import { SafeTransferLib } from "@solady/utils/SafeTransferLib.sol";
import { IPoolManager } from "@v4-core/interfaces/IPoolManager.sol";
import { FullMath } from "@v4-core/libraries/FullMath.sol";
import { StateLibrary } from "@v4-core/libraries/StateLibrary.sol";
import { TickMath } from "@v4-core/libraries/TickMath.sol";
import { BalanceDelta, toBalanceDelta } from "@v4-core/types/BalanceDelta.sol";
import { Currency, CurrencyLibrary } from "@v4-core/types/Currency.sol";
import { PoolId } from "@v4-core/types/PoolId.sol";
import { PoolKey } from "@v4-core/types/PoolKey.sol";
import { LiquidityAmounts } from "@v4-periphery/libraries/LiquidityAmounts.sol";
import { BaseDopplerHookInitializer } from "src/base/BaseDopplerHookInitializer.sol";
import { Collect, FeesManager } from "src/base/FeesManager.sol";
import { DopplerHookInitializer } from "src/initializers/DopplerHookInitializer.sol";
import { MigrationMath } from "src/libraries/MigrationMath.sol";
import { BeneficiaryData } from "src/types/BeneficiaryData.sol";
import { Position } from "src/types/Position.sol";
import {
    AIRLOCK_OWNER_FEE_BPS,
    AggregatedSwapResult,
    AirlockOwnerFeesClaimed,
    BPS_DENOMINATOR,
    DEV_BUY_EXEMPTION_SLOT,
    EPSILON,
    FeeBeneficiariesNotConfigured,
    FeeBeneficiariesNotSupportedInDirectBuyback,
    FeeBeneficiariesSet,
    FeeDistributionInfo,
    FeeDistributionMustAddUpToWAD,
    FeeRoutingMode,
    FeeSchedule,
    FeeScheduleSet,
    FeeTooHigh,
    FeeUpdated,
    HookFees,
    INTEGRATOR_CONVERSION_RATIO_DENOMINATOR,
    InitData,
    InsufficientFeeCurrency,
    IntegratorAutomaticPayoutSet,
    IntegratorConversionRatiosSet,
    IntegratorFeeOverflow,
    IntegratorFeeShareSet,
    IntegratorFeeShareTooHigh,
    IntegratorFees,
    IntegratorFeesClaimed,
    IntegratorInitConfig,
    IntegratorRoutingConfig,
    IntegratorSet,
    IntegratorSettlement,
    InvalidAsset,
    InvalidDurationSeconds,
    InvalidFeeRange,
    InvalidIntegrator,
    InvalidIntegratorClaimDestination,
    InvalidIntegratorConversionRatio,
    InvalidNumeraire,
    MAX_INTEGRATOR_FEE_SHARE,
    MAX_REBALANCE_ITERATIONS,
    MAX_SWAP_FEE,
    MILLIONTHS_DENOMINATOR,
    PoolAlreadyInitialized,
    PoolInfo,
    SWAP_FEE_DENOMINATOR,
    SenderNotAirlockOwner,
    SenderNotAuthorized,
    SenderNotIntegrator,
    SwapSimulation
} from "src/types/RehypeTypes.sol";
import { WAD } from "src/types/Wad.sol";

/**
 * @title Rehype Doppler Hook Initializer
 * @author Whetstone Research
 * @custom:security-contact security@whetstone.cc
 * @notice Doppler Hook that implements fee collection, distribution, buybacks, LP fee reinvestment and decaying LP fee
 */
contract RehypeDopplerHookInitializer is BaseDopplerHookInitializer, FeesManager {
    using StateLibrary for IPoolManager;
    using CurrencyLibrary for Currency;

    /// @notice Address of the Uniswap V4 Pool Manager
    IPoolManager public immutable poolManager;

    /// @notice Quoter contract for simulating swaps
    Quoter public immutable quoter;

    /// @notice Bundler authorized to consume the one-swap dev buy exemption.
    address public immutable bundler;

    /// @notice Position data for each pool
    mapping(PoolId poolId => Position position) public getPosition;

    /// @dev Packed fee distribution configuration for each pool
    mapping(PoolId poolId => FeeDistributionInfo feeDistributionInfo) private _feeDistributionInfo;

    /// @notice Hook fees tracking for each pool
    mapping(PoolId poolId => HookFees hookFees) public getHookFees;

    /// @notice Pool info for each pool
    mapping(PoolId poolId => PoolInfo poolInfo) public getPoolInfo;

    /// @notice Fee routing mode for each pool
    mapping(PoolId poolId => FeeRoutingMode feeRoutingMode) public getFeeRoutingMode;

    /// @notice Mutable integrator routing configuration for each pool
    mapping(PoolId poolId => IntegratorRoutingConfig config) public getIntegratorRoutingConfig;

    /// @notice Integrator fees collected but not yet processed by a routing cycle
    mapping(PoolId poolId => IntegratorFees fees) public getPendingIntegratorFees;

    /// @notice Processed integrator fees retained for manual claim
    mapping(PoolId poolId => IntegratorFees fees) public getClaimableIntegratorFees;

    /// @dev Packed fee schedule and immutable integrator fee share for each pool
    mapping(PoolId poolId => FeeSchedule feeSchedule) private _feeSchedule;

    receive() external payable { }

    /**
     * @param initializer Address of the DopplerHookInitializer contract
     * @param poolManager_ Address of the Uniswap V4 Pool Manager
     * @param bundler_ Address of the authorized dev buy Bundler
     */
    constructor(
        address initializer,
        IPoolManager poolManager_,
        address bundler_
    ) BaseDopplerHookInitializer(initializer) {
        poolManager = poolManager_;
        quoter = new Quoter(poolManager_);
        bundler = bundler_;
    }

    /**
     * @notice Returns the original fee schedule ABI while packed storage also contains the integrator fee share.
     */
    function getFeeSchedule(PoolId poolId)
        external
        view
        returns (uint32 startingTime, uint24 startFee, uint24 endFee, uint24 lastFee, uint32 durationSeconds)
    {
        FeeSchedule memory schedule = _feeSchedule[poolId];
        return (schedule.startingTime, schedule.startFee, schedule.endFee, schedule.lastFee, schedule.durationSeconds);
    }

    /// @notice Returns the immutable integrator share of gross Rehype fees for a pool.
    function getIntegratorFeeShare(PoolId poolId) external view returns (uint24) {
        return _feeSchedule[poolId].integratorFeeShare;
    }

    /**
     * @notice Returns fee distribution weights using the original uint256 ABI.
     */
    function getFeeDistributionInfo(PoolId poolId)
        external
        view
        returns (
            uint256 assetFeesToAssetBuybackWad,
            uint256 assetFeesToNumeraireBuybackWad,
            uint256 assetFeesToBeneficiaryWad,
            uint256 assetFeesToLpWad,
            uint256 numeraireFeesToAssetBuybackWad,
            uint256 numeraireFeesToNumeraireBuybackWad,
            uint256 numeraireFeesToBeneficiaryWad,
            uint256 numeraireFeesToLpWad
        )
    {
        FeeDistributionInfo memory distribution = _feeDistributionInfo[poolId];
        return (
            distribution.assetFeesToAssetBuybackWad,
            distribution.assetFeesToNumeraireBuybackWad,
            distribution.assetFeesToBeneficiaryWad,
            distribution.assetFeesToLpWad,
            distribution.numeraireFeesToAssetBuybackWad,
            distribution.numeraireFeesToNumeraireBuybackWad,
            distribution.numeraireFeesToBeneficiaryWad,
            distribution.numeraireFeesToLpWad
        );
    }

    /// @inheritdoc BaseDopplerHookInitializer
    function _onInitialization(address asset, PoolKey calldata key, bytes calldata data) internal override {
        InitData memory initData = abi.decode(data, (InitData));

        PoolId poolId = key.toId();

        // We prevent reinitializing rehype hook due to beneficiaries not being enumerable, and thus clearable.
        // Naive reinitialization would lead to overallocation of beneficiary fees and overlapping claims.
        require(getPoolInfo[poolId].asset == address(0), PoolAlreadyInitialized());

        Currency assetCurrency = Currency.wrap(asset);
        Currency numeraireCurrency;
        if (key.currency0 == assetCurrency) {
            numeraireCurrency = key.currency1;
        } else if (key.currency1 == assetCurrency) {
            numeraireCurrency = key.currency0;
        } else {
            revert InvalidAsset(asset);
        }

        address numeraire = Currency.unwrap(numeraireCurrency);
        require(initData.numeraire == numeraire, InvalidNumeraire(numeraire, initData.numeraire));

        // If _onInitialization is called by create (and not on hook reinitialization), open a temporary dev buy
        // non-protocol fee exemption for one swap only.
        if (_isAirlockCreate(asset)) {
            _setDevBuyExemption(poolId);
        }

        getPoolInfo[poolId] = PoolInfo({ asset: asset, numeraire: numeraire, buybackDst: initData.buybackDst });

        _validateFeeDistribution(initData.feeDistributionInfo);
        _feeDistributionInfo[poolId] = initData.feeDistributionInfo;
        getFeeRoutingMode[poolId] = initData.feeRoutingMode;

        IntegratorInitConfig memory integratorConfig = initData.integratorConfig;
        _validateIntegratorInitConfig(integratorConfig);
        emit IntegratorFeeShareSet(poolId, integratorConfig.feeShare);
        if (integratorConfig.feeShare > 0) {
            getIntegratorRoutingConfig[poolId] = IntegratorRoutingConfig({
                integrator: integratorConfig.integrator,
                assetFeesToNumeraireRatio: integratorConfig.assetFeesToNumeraireRatio,
                numeraireFeesToAssetRatio: integratorConfig.numeraireFeesToAssetRatio,
                automaticPayout: integratorConfig.automaticPayout
            });
            emit IntegratorSet(poolId, address(0), integratorConfig.integrator);
            emit IntegratorConversionRatiosSet(
                poolId, integratorConfig.assetFeesToNumeraireRatio, integratorConfig.numeraireFeesToAssetRatio
            );
            emit IntegratorAutomaticPayoutSet(poolId, integratorConfig.automaticPayout);
        }

        if (initData.feeBeneficiaries.length > 0) {
            require(
                initData.feeRoutingMode == FeeRoutingMode.RouteToBeneficiaryFees,
                FeeBeneficiariesNotSupportedInDirectBuyback()
            );
            _storeBeneficiaries(key, initData.feeBeneficiaries);
            emit FeeBeneficiariesSet(poolId, initData.feeBeneficiaries);
        }

        // Validate and store fee schedule
        require(initData.startFee <= uint24(MAX_SWAP_FEE), FeeTooHigh(initData.startFee));
        require(initData.endFee <= uint24(MAX_SWAP_FEE), FeeTooHigh(initData.endFee));
        require(initData.startFee >= initData.endFee, InvalidFeeRange(initData.startFee, initData.endFee));

        if (initData.startFee > initData.endFee) {
            require(initData.durationSeconds > 0, InvalidDurationSeconds(initData.durationSeconds));
        }

        uint32 normalizedStart = (initData.startingTime == 0 || initData.startingTime <= uint32(block.timestamp))
            ? uint32(block.timestamp)
            : initData.startingTime;

        _feeSchedule[poolId] = FeeSchedule({
            startingTime: normalizedStart,
            startFee: initData.startFee,
            endFee: initData.endFee,
            lastFee: initData.startFee,
            durationSeconds: initData.durationSeconds,
            integratorFeeShare: integratorConfig.feeShare
        });

        emit FeeScheduleSet(poolId, normalizedStart, initData.startFee, initData.endFee, initData.durationSeconds);

        // Initialize position
        getPosition[poolId] = Position({
            tickLower: TickMath.minUsableTick(key.tickSpacing),
            tickUpper: TickMath.maxUsableTick(key.tickSpacing),
            liquidity: 0,
            salt: _fullRangeSalt(poolId)
        });
    }

    /// @inheritdoc BaseDopplerHookInitializer
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
        (Currency feeCurrency, int128 hookDelta, uint24 integratorFeeShare) =
            _collectSwapFees(sender, params, delta, key, poolId);

        uint256 balance0 = getHookFees[poolId].fees0;
        uint256 balance1 = getHookFees[poolId].fees1;
        IntegratorFees memory integratorFees;
        if (integratorFeeShare != 0) {
            integratorFees = getPendingIntegratorFees[poolId];
        }
        if (balance0 + integratorFees.fees0 <= EPSILON && balance1 + integratorFees.fees1 <= EPSILON) {
            return (feeCurrency, hookDelta);
        }

        PoolInfo storage poolInfo = getPoolInfo[poolId];
        bool isToken0 = key.currency0 == Currency.wrap(poolInfo.asset);
        bool isNumeraireToken0 = key.currency0 == Currency.wrap(poolInfo.numeraire);
        FeeDistributionInfo memory distribution = _feeDistributionInfo[poolId];
        IntegratorRoutingConfig memory integratorConfig;
        if (integratorFeeShare != 0) {
            integratorConfig = getIntegratorRoutingConfig[poolId];
        }

        uint256 assetFees = isToken0 ? balance0 : balance1;
        uint256 numeraireFees = isToken0 ? balance1 : balance0;
        uint256 integratorAssetFees = isToken0 ? integratorFees.fees0 : integratorFees.fees1;
        uint256 integratorNumeraireFees = isToken0 ? integratorFees.fees1 : integratorFees.fees0;

        uint256 assetDirectBuybackAmount = FullMath.mulDiv(assetFees, distribution.assetFeesToAssetBuybackWad, WAD);
        uint256 assetBuybackAmountIn = FullMath.mulDiv(assetFees, distribution.assetFeesToNumeraireBuybackWad, WAD);
        uint256 assetBeneficiaryAmount = FullMath.mulDiv(assetFees, distribution.assetFeesToBeneficiaryWad, WAD);
        uint256 assetLpAmount = FullMath.mulDiv(assetFees, distribution.assetFeesToLpWad, WAD);

        uint256 numeraireBuybackAmountIn =
            FullMath.mulDiv(numeraireFees, distribution.numeraireFeesToAssetBuybackWad, WAD);
        uint256 numeraireDirectBuybackAmount =
            FullMath.mulDiv(numeraireFees, distribution.numeraireFeesToNumeraireBuybackWad, WAD);
        uint256 numeraireBeneficiaryAmount =
            FullMath.mulDiv(numeraireFees, distribution.numeraireFeesToBeneficiaryWad, WAD);
        uint256 numeraireLpAmount = FullMath.mulDiv(numeraireFees, distribution.numeraireFeesToLpWad, WAD);

        uint256 integratorAssetSwapAmount = FullMath.mulDiv(
            integratorAssetFees, integratorConfig.assetFeesToNumeraireRatio, INTEGRATOR_CONVERSION_RATIO_DENOMINATOR
        );
        uint256 integratorNumeraireSwapAmount = FullMath.mulDiv(
            integratorNumeraireFees, integratorConfig.numeraireFeesToAssetRatio, INTEGRATOR_CONVERSION_RATIO_DENOMINATOR
        );

        IntegratorSettlement memory integratorSettlement;
        if (isToken0) {
            integratorSettlement.settlement0 = integratorAssetFees - integratorAssetSwapAmount;
            integratorSettlement.settlement1 = integratorNumeraireFees - integratorNumeraireSwapAmount;
        } else {
            integratorSettlement.settlement0 = integratorNumeraireFees - integratorNumeraireSwapAmount;
            integratorSettlement.settlement1 = integratorAssetFees - integratorAssetSwapAmount;
        }

        uint256 lpAmount0 = isToken0 ? assetLpAmount : numeraireLpAmount;
        uint256 lpAmount1 = isToken0 ? numeraireLpAmount : assetLpAmount;
        balance0 = isToken0
            ? assetBeneficiaryAmount + assetLpAmount + assetBuybackAmountIn
            : numeraireBeneficiaryAmount + numeraireLpAmount + numeraireBuybackAmountIn;
        balance1 = isToken0
            ? numeraireBeneficiaryAmount + numeraireLpAmount + numeraireBuybackAmountIn
            : assetBeneficiaryAmount + assetLpAmount + assetBuybackAmountIn;

        bool routeToBeneficiaryFees = getFeeRoutingMode[poolId] == FeeRoutingMode.RouteToBeneficiaryFees;
        if (assetDirectBuybackAmount > 0) {
            if (routeToBeneficiaryFees) {
                if (isToken0) balance0 += assetDirectBuybackAmount;
                else balance1 += assetDirectBuybackAmount;
            } else {
                Currency.wrap(poolInfo.asset).transfer(poolInfo.buybackDst, assetDirectBuybackAmount);
            }
        }
        if (numeraireDirectBuybackAmount > 0) {
            if (routeToBeneficiaryFees) {
                if (isNumeraireToken0) balance0 += numeraireDirectBuybackAmount;
                else balance1 += numeraireDirectBuybackAmount;
            } else {
                Currency.wrap(poolInfo.numeraire).transfer(poolInfo.buybackDst, numeraireDirectBuybackAmount);
            }
        }

        AggregatedSwapResult memory assetSwap = _executeAggregatedSwap(
            key,
            isToken0,
            assetBuybackAmountIn,
            integratorAssetSwapAmount,
            (isToken0 ? balance0 : balance1) + integratorAssetSwapAmount
        );
        if (assetSwap.residualOutput > 0) {
            if (routeToBeneficiaryFees) {
                if (isNumeraireToken0) balance0 += assetSwap.residualOutput;
                else balance1 += assetSwap.residualOutput;
            } else {
                Currency.wrap(poolInfo.numeraire).transfer(poolInfo.buybackDst, assetSwap.residualOutput);
            }
        }
        if (isToken0) balance0 -= assetSwap.residualInputUsed;
        else balance1 -= assetSwap.residualInputUsed;
        if (isNumeraireToken0) integratorSettlement.settlement0 += assetSwap.integratorOutput;
        else integratorSettlement.settlement1 += assetSwap.integratorOutput;
        if (isToken0) integratorSettlement.unconverted0 += assetSwap.integratorUnconverted;
        else integratorSettlement.unconverted1 += assetSwap.integratorUnconverted;

        AggregatedSwapResult memory numeraireSwap = _executeAggregatedSwap(
            key,
            !isToken0,
            numeraireBuybackAmountIn,
            integratorNumeraireSwapAmount,
            (isToken0 ? balance1 : balance0) + integratorNumeraireSwapAmount
        );
        if (numeraireSwap.residualOutput > 0) {
            if (routeToBeneficiaryFees) {
                if (isToken0) balance0 += numeraireSwap.residualOutput;
                else balance1 += numeraireSwap.residualOutput;
            } else {
                Currency.wrap(poolInfo.asset).transfer(poolInfo.buybackDst, numeraireSwap.residualOutput);
            }
        }
        if (isToken0) balance1 -= numeraireSwap.residualInputUsed;
        else balance0 -= numeraireSwap.residualInputUsed;
        if (isToken0) integratorSettlement.settlement0 += numeraireSwap.integratorOutput;
        else integratorSettlement.settlement1 += numeraireSwap.integratorOutput;
        if (isNumeraireToken0) integratorSettlement.unconverted0 += numeraireSwap.integratorUnconverted;
        else integratorSettlement.unconverted1 += numeraireSwap.integratorUnconverted;

        (uint160 sqrtPriceX96,,,) = poolManager.getSlot0(poolId);
        Position storage position = getPosition[poolId];
        (bool shouldSwap, bool zeroForOne, uint256 swapAmountIn, uint256 swapAmountOut,) =
            _rebalanceFees(key, lpAmount0, lpAmount1, sqrtPriceX96);
        if (shouldSwap && swapAmountIn > 0) {
            Currency outputCurrency = zeroForOne ? key.currency1 : key.currency0;
            if (outputCurrency.balanceOf(address(poolManager)) > swapAmountOut) {
                uint160 postSwapSqrtPrice;
                (postSwapSqrtPrice, swapAmountOut, swapAmountIn) = _executeSwap(key, zeroForOne, swapAmountIn);
                lpAmount0 = zeroForOne ? lpAmount0 - swapAmountIn : lpAmount0 + swapAmountOut;
                lpAmount1 = zeroForOne ? lpAmount1 + swapAmountOut : lpAmount1 - swapAmountIn;
                BalanceDelta liquidityDelta =
                    _addFullRangeLiquidity(key, position, lpAmount0, lpAmount1, postSwapSqrtPrice);
                balance0 = uint256(
                    int256(zeroForOne ? balance0 - swapAmountIn : balance0 + swapAmountOut) + liquidityDelta.amount0()
                );
                balance1 = uint256(
                    int256(zeroForOne ? balance1 + swapAmountOut : balance1 - swapAmountIn) + liquidityDelta.amount1()
                );
            }
        }

        getHookFees[poolId].beneficiaryFees0 += uint128(balance0);
        getHookFees[poolId].beneficiaryFees1 += uint128(balance1);
        getHookFees[poolId].fees0 = 0;
        getHookFees[poolId].fees1 = 0;
        if (integratorFeeShare != 0) {
            delete getPendingIntegratorFees[poolId];
            _applyIntegratorSettlement(poolId, key, integratorConfig, integratorSettlement);
        }

        return (feeCurrency, hookDelta);
    }

    /**
     * @dev Executes one directional swap for residual fee-distribution and integrator inputs together.
     * @param key Pool receiving the internal swap
     * @param zeroForOne Swap direction
     * @param residualInput Residual fee-distribution input assigned to this direction
     * @param integratorInput Integrator input assigned to this direction
     * @param availableInput Total contract accounting available in the input currency
     * @return result Proportional ownership of consumed input and produced output
     */
    function _executeAggregatedSwap(
        PoolKey memory key,
        bool zeroForOne,
        uint256 residualInput,
        uint256 integratorInput,
        uint256 availableInput
    ) internal returns (AggregatedSwapResult memory result) {
        uint256 totalInput = residualInput + integratorInput;
        if (totalInput == 0) return result;

        SwapSimulation memory simulation = _simulateSwap(
            key, zeroForOne, totalInput, zeroForOne ? availableInput : 0, zeroForOne ? 0 : availableInput
        );
        Currency outputCurrency = zeroForOne ? key.currency1 : key.currency0;
        if (
            !simulation.success || simulation.amountOut == 0
                || outputCurrency.balanceOf(address(poolManager)) < simulation.amountOut
        ) {
            result.integratorUnconverted = integratorInput;
            return result;
        }

        (, uint256 amountOut, uint256 amountInUsed) = _executeSwap(key, zeroForOne, totalInput);
        uint256 integratorInputUsed =
            integratorInput == 0 ? 0 : FullMath.mulDiv(amountInUsed, integratorInput, totalInput);
        result.residualInputUsed = amountInUsed - integratorInputUsed;
        result.integratorUnconverted = integratorInput - integratorInputUsed;

        if (integratorInputUsed > 0) {
            result.integratorOutput = FullMath.mulDiv(amountOut, integratorInputUsed, amountInUsed);
        }
        result.residualOutput = amountOut - result.integratorOutput;
    }

    /**
     * @dev Applies all integrator amounts produced by one routing cycle.
     * Unconverted amounts are always accrued. When automatic payout is enabled, transfer failures are also accrued
     * instead of reverting the outer user swap.
     */
    function _applyIntegratorSettlement(
        PoolId poolId,
        PoolKey memory key,
        IntegratorRoutingConfig memory config,
        IntegratorSettlement memory settlement
    ) internal {
        if (!config.automaticPayout) {
            _accrueIntegratorFees(
                poolId,
                settlement.unconverted0 + settlement.settlement0,
                settlement.unconverted1 + settlement.settlement1
            );
            return;
        }

        uint256 failed0 = _tryAutomaticIntegratorPayout(key.currency0, config.integrator, settlement.settlement0);
        uint256 failed1 = _tryAutomaticIntegratorPayout(key.currency1, config.integrator, settlement.settlement1);
        _accrueIntegratorFees(poolId, settlement.unconverted0 + failed0, settlement.unconverted1 + failed1);
    }

    /**
     * @dev Attempts one automatic integrator payout and returns its amount when the transfer fails.
     */
    function _tryAutomaticIntegratorPayout(
        Currency currency,
        address integrator,
        uint256 amount
    ) internal returns (uint256 failedAmount) {
        if (amount == 0) return 0;
        if (_tryAutomaticTransfer(currency, integrator, amount)) return 0;
        return amount;
    }

    /**
     * @dev Adds integrator balances to claimable accounting with checked narrowing.
     */
    function _accrueIntegratorFees(PoolId poolId, uint256 amount0, uint256 amount1) internal {
        if (amount0 == 0 && amount1 == 0) return;

        IntegratorFees memory fees = getClaimableIntegratorFees[poolId];
        fees = IntegratorFees({
            fees0: _toUint128(uint256(fees.fees0) + amount0), fees1: _toUint128(uint256(fees.fees1) + amount1)
        });
        getClaimableIntegratorFees[poolId] = fees;
    }

    /**
     * @dev Narrows integrator accounting amounts without truncation.
     */
    function _toUint128(uint256 amount) internal pure returns (uint128 narrowed) {
        require(amount <= type(uint128).max, IntegratorFeeOverflow());
        narrowed = uint128(amount);
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
                if (high == 1) {
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

        try poolManager.modifyLiquidity(
            key,
            IPoolManager.ModifyLiquidityParams({
                tickLower: position.tickLower,
                tickUpper: position.tickUpper,
                liquidityDelta: int256(uint256(liquidityDelta)),
                salt: position.salt
            }),
            new bytes(0)
        ) returns (
            BalanceDelta delta, BalanceDelta
        ) {
            callerDelta = delta;
        } catch {
            return toBalanceDelta(0, 0);
        }

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
     * @notice Collects accumulated beneficiary fees for a pool
     * @dev Legacy pools initialized with an empty fee-beneficiary array transfer fees to `buybackDst`. Configured
     * pools harvest fees into FeesManager cumulative accounting and release only the caller's ordinary share.
     * @param asset Asset to collect fees from
     * @return fees Collected fees as a BalanceDelta
     */
    function collectFees(address asset) external nonReentrant returns (BalanceDelta fees) {
        (,,,,, PoolKey memory poolKey,) = DopplerHookInitializer(payable(INITIALIZER)).getState(asset);
        PoolId poolId = poolKey.toId();

        if (address(getPoolKey[poolId].hooks) != address(0)) {
            return _collectAndReleaseRehypeFees(poolId);
        }

        HookFees storage hookFees = getHookFees[poolId];
        uint128 beneficiaryFees0 = hookFees.beneficiaryFees0;
        uint128 beneficiaryFees1 = hookFees.beneficiaryFees1;
        address beneficiary = getPoolInfo[poolId].buybackDst;

        fees = toBalanceDelta(int128(beneficiaryFees0), int128(beneficiaryFees1));

        hookFees.beneficiaryFees0 = 0;
        hookFees.beneficiaryFees1 = 0;

        if (beneficiaryFees0 > 0) {
            poolKey.currency0.transfer(beneficiary, beneficiaryFees0);
        }
        if (beneficiaryFees1 > 0) {
            poolKey.currency1.transfer(beneficiary, beneficiaryFees1);
        }

        return fees;
    }

    /// @inheritdoc FeesManager
    function _collectFees(PoolId poolId) internal override returns (BalanceDelta fees) {
        require(address(getPoolKey[poolId].hooks) != address(0), FeeBeneficiariesNotConfigured());

        HookFees storage hookFees = getHookFees[poolId];
        fees = toBalanceDelta(int128(uint128(hookFees.beneficiaryFees0)), int128(uint128(hookFees.beneficiaryFees1)));
        hookFees.beneficiaryFees0 = 0;
        hookFees.beneficiaryFees1 = 0;
    }

    function _collectAndReleaseRehypeFees(PoolId poolId) internal returns (BalanceDelta fees) {
        fees = _collectFees(poolId);
        uint128 fees0 = uint128(fees.amount0());
        uint128 fees1 = uint128(fees.amount1());

        getCumulatedFees0[poolId] += fees0;
        getCumulatedFees1[poolId] += fees1;
        _releaseFees(poolId, msg.sender);

        emit Collect(poolId, fees0, fees1);
    }

    /**
     * @notice Claims accumulated airlock owner fees for a pool
     * @param asset Asset address to identify the pool
     * @return fees0 Amount of currency0 claimed
     * @return fees1 Amount of currency1 claimed
     */
    function claimAirlockOwnerFees(address asset) external nonReentrant returns (uint128 fees0, uint128 fees1) {
        address airlockOwner = DopplerHookInitializer(payable(INITIALIZER)).airlock().owner();
        require(msg.sender == airlockOwner, SenderNotAirlockOwner());

        (,,,,, PoolKey memory poolKey,) = DopplerHookInitializer(payable(INITIALIZER)).getState(asset);
        PoolId poolId = poolKey.toId();

        fees0 = getHookFees[poolId].airlockOwnerFees0;
        fees1 = getHookFees[poolId].airlockOwnerFees1;
        getHookFees[poolId].airlockOwnerFees0 = 0;
        getHookFees[poolId].airlockOwnerFees1 = 0;

        if (fees0 > 0) {
            poolKey.currency0.transfer(msg.sender, fees0);
        }
        if (fees1 > 0) {
            poolKey.currency1.transfer(msg.sender, fees1);
        }

        emit AirlockOwnerFeesClaimed(poolId, msg.sender, fees0, fees1);
    }

    /**
     * @notice Claims all accrued integrator fees to a chosen destination
     * @param asset Asset address identifying the pool
     * @param to Address receiving both pool currencies
     * @return fees0 Amount of currency0 claimed
     * @return fees1 Amount of currency1 claimed
     */
    function claimIntegratorFees(
        address asset,
        address to
    ) external nonReentrant returns (uint128 fees0, uint128 fees1) {
        require(to != address(0), InvalidIntegratorClaimDestination());

        (,,,,, PoolKey memory poolKey,) = DopplerHookInitializer(payable(INITIALIZER)).getState(asset);
        PoolId poolId = poolKey.toId();
        IntegratorRoutingConfig memory config = getIntegratorRoutingConfig[poolId];
        require(msg.sender == config.integrator, SenderNotIntegrator());

        IntegratorFees memory fees = getClaimableIntegratorFees[poolId];
        fees0 = fees.fees0;
        fees1 = fees.fees1;
        delete getClaimableIntegratorFees[poolId];

        if (fees0 > 0) _safeTransfer(poolKey.currency0, to, fees0);
        if (fees1 > 0) _safeTransfer(poolKey.currency1, to, fees1);

        emit IntegratorFeesClaimed(poolId, msg.sender, to, fees0, fees1);
    }

    /**
     * @notice Atomically updates both integrator fee conversion ratios
     * @dev The current integrator controls the ratios. The update applies to all unprocessed and future fees.
     * @param poolId Pool whose conversion ratios are updated
     * @param assetFeesToNumeraireRatio Ratio of asset fees converted to numeraire
     * @param numeraireFeesToAssetRatio Ratio of numeraire fees converted to asset
     */
    function setIntegratorConversionRatios(
        PoolId poolId,
        uint32 assetFeesToNumeraireRatio,
        uint32 numeraireFeesToAssetRatio
    ) external {
        IntegratorRoutingConfig storage config = getIntegratorRoutingConfig[poolId];
        require(msg.sender == config.integrator, SenderNotIntegrator());
        _validateIntegratorConversionRatios(assetFeesToNumeraireRatio, numeraireFeesToAssetRatio);

        config.assetFeesToNumeraireRatio = assetFeesToNumeraireRatio;
        config.numeraireFeesToAssetRatio = numeraireFeesToAssetRatio;
        emit IntegratorConversionRatiosSet(poolId, assetFeesToNumeraireRatio, numeraireFeesToAssetRatio);
    }

    /**
     * @notice Updates whether processed integrator fees are paid automatically
     * @dev The current integrator controls this setting. Existing claimable fees remain claimable.
     * @param poolId Pool whose automatic payout setting is updated
     * @param automaticPayout Whether future processed fees are paid automatically
     */
    function setIntegratorAutomaticPayout(PoolId poolId, bool automaticPayout) external {
        IntegratorRoutingConfig storage config = getIntegratorRoutingConfig[poolId];
        require(msg.sender == config.integrator, SenderNotIntegrator());

        config.automaticPayout = automaticPayout;
        emit IntegratorAutomaticPayoutSet(poolId, automaticPayout);
    }

    /**
     * @notice Rotates integrator control, automatic payout, and claim rights to a new address
     * @param poolId Pool whose integrator is updated
     * @param newIntegrator Address receiving control and outstanding claim rights
     */
    function setIntegrator(PoolId poolId, address newIntegrator) external {
        require(newIntegrator != address(0), InvalidIntegrator());

        IntegratorRoutingConfig storage config = getIntegratorRoutingConfig[poolId];
        address oldIntegrator = config.integrator;
        require(msg.sender == oldIntegrator, SenderNotIntegrator());

        config.integrator = newIntegrator;
        emit IntegratorSet(poolId, oldIntegrator, newIntegrator);
    }

    /**
     * @notice Updates the fee distribution for a pool
     * @param poolId Uniswap V4 poolId
     * @param assetFeesToAssetBuybackWad Percentage of asset fees to asset buyback
     * @param assetFeesToNumeraireBuybackWad Percentage of asset fees to numeraire buyback
     * @param assetFeesToBeneficiaryWad Percentage of asset fees to beneficiary accounting
     * @param assetFeesToLpWad Percentage of asset fees to LP reinvestment
     * @param numeraireFeesToAssetBuybackWad Percentage of numeraire fees to asset buyback
     * @param numeraireFeesToNumeraireBuybackWad Percentage of numeraire fees to numeraire buyback
     * @param numeraireFeesToBeneficiaryWad Percentage of numeraire fees to beneficiary accounting
     * @param numeraireFeesToLpWad Percentage of numeraire fees to LP reinvestment
     */
    function setFeeDistribution(
        PoolId poolId,
        uint256 assetFeesToAssetBuybackWad,
        uint256 assetFeesToNumeraireBuybackWad,
        uint256 assetFeesToBeneficiaryWad,
        uint256 assetFeesToLpWad,
        uint256 numeraireFeesToAssetBuybackWad,
        uint256 numeraireFeesToNumeraireBuybackWad,
        uint256 numeraireFeesToBeneficiaryWad,
        uint256 numeraireFeesToLpWad
    ) external {
        address buybackDst = getPoolInfo[poolId].buybackDst;
        require(msg.sender == buybackDst, SenderNotAuthorized());

        _validateFeeDistribution(
            assetFeesToAssetBuybackWad,
            assetFeesToNumeraireBuybackWad,
            assetFeesToBeneficiaryWad,
            assetFeesToLpWad,
            numeraireFeesToAssetBuybackWad,
            numeraireFeesToNumeraireBuybackWad,
            numeraireFeesToBeneficiaryWad,
            numeraireFeesToLpWad
        );
        _feeDistributionInfo[poolId] = FeeDistributionInfo({
            assetFeesToAssetBuybackWad: uint64(assetFeesToAssetBuybackWad),
            assetFeesToNumeraireBuybackWad: uint64(assetFeesToNumeraireBuybackWad),
            assetFeesToBeneficiaryWad: uint64(assetFeesToBeneficiaryWad),
            assetFeesToLpWad: uint64(assetFeesToLpWad),
            numeraireFeesToAssetBuybackWad: uint64(numeraireFeesToAssetBuybackWad),
            numeraireFeesToNumeraireBuybackWad: uint64(numeraireFeesToNumeraireBuybackWad),
            numeraireFeesToBeneficiaryWad: uint64(numeraireFeesToBeneficiaryWad),
            numeraireFeesToLpWad: uint64(numeraireFeesToLpWad)
        });
    }

    function _validateFeeDistribution(
        uint256 assetFeesToAssetBuybackWad,
        uint256 assetFeesToNumeraireBuybackWad,
        uint256 assetFeesToBeneficiaryWad,
        uint256 assetFeesToLpWad,
        uint256 numeraireFeesToAssetBuybackWad,
        uint256 numeraireFeesToNumeraireBuybackWad,
        uint256 numeraireFeesToBeneficiaryWad,
        uint256 numeraireFeesToLpWad
    ) internal pure {
        require(
            assetFeesToAssetBuybackWad + assetFeesToNumeraireBuybackWad + assetFeesToBeneficiaryWad + assetFeesToLpWad
                == WAD,
            FeeDistributionMustAddUpToWAD()
        );
        require(
            numeraireFeesToAssetBuybackWad + numeraireFeesToNumeraireBuybackWad + numeraireFeesToBeneficiaryWad
                    + numeraireFeesToLpWad == WAD,
            FeeDistributionMustAddUpToWAD()
        );
    }

    function _validateFeeDistribution(FeeDistributionInfo memory feeDistributionInfo) internal pure {
        require(
            uint256(feeDistributionInfo.assetFeesToAssetBuybackWad) + feeDistributionInfo.assetFeesToNumeraireBuybackWad
                    + feeDistributionInfo.assetFeesToBeneficiaryWad + feeDistributionInfo.assetFeesToLpWad == WAD,
            FeeDistributionMustAddUpToWAD()
        );
        require(
            uint256(feeDistributionInfo.numeraireFeesToAssetBuybackWad)
                    + feeDistributionInfo.numeraireFeesToNumeraireBuybackWad
                    + feeDistributionInfo.numeraireFeesToBeneficiaryWad + feeDistributionInfo.numeraireFeesToLpWad
                == WAD,
            FeeDistributionMustAddUpToWAD()
        );
    }

    /**
     * @dev Validates the immutable integrator fee share and initial mutable routing configuration.
     */
    function _validateIntegratorInitConfig(IntegratorInitConfig memory config) internal pure {
        require(config.feeShare <= MAX_INTEGRATOR_FEE_SHARE, IntegratorFeeShareTooHigh());
        _validateIntegratorConversionRatios(config.assetFeesToNumeraireRatio, config.numeraireFeesToAssetRatio);
        if (config.feeShare == 0) {
            require(config.integrator == address(0), InvalidIntegrator());
            require(
                config.assetFeesToNumeraireRatio == 0 && config.numeraireFeesToAssetRatio == 0,
                InvalidIntegratorConversionRatio()
            );
        } else {
            require(config.integrator != address(0), InvalidIntegrator());
        }
    }

    /**
     * @dev Validates both independent per-source conversion ratios.
     */
    function _validateIntegratorConversionRatios(
        uint32 assetFeesToNumeraireRatio,
        uint32 numeraireFeesToAssetRatio
    ) internal pure {
        require(
            assetFeesToNumeraireRatio <= INTEGRATOR_CONVERSION_RATIO_DENOMINATOR
                && numeraireFeesToAssetRatio <= INTEGRATOR_CONVERSION_RATIO_DENOMINATOR,
            InvalidIntegratorConversionRatio()
        );
    }

    /**
     * @dev Computes the current fee based on linear interpolation of the fee schedule
     * @param schedule The fee schedule
     * @param elapsed Time elapsed since schedule start
     * @return The interpolated fee
     */
    function _computeCurrentFee(FeeSchedule memory schedule, uint256 elapsed) internal pure returns (uint24) {
        uint256 feeRange = uint256(schedule.startFee - schedule.endFee);
        uint256 feeDelta_ = feeRange * elapsed / schedule.durationSeconds;
        return uint24(uint256(schedule.startFee) - feeDelta_);
    }

    /**
     * @dev Returns the current Rehype fee and immutable integrator fee share from their shared storage slot.
     * @param poolId Uniswap V4 poolId
     * @return currentFee The current Rehype fee rate
     * @return integratorFeeShare The immutable integrator share of gross Rehype fees
     */
    function _getCurrentFee(PoolId poolId) internal returns (uint24 currentFee, uint24 integratorFeeShare) {
        FeeSchedule memory schedule = _feeSchedule[poolId];
        integratorFeeShare = schedule.integratorFeeShare;

        // No decay: startFee == endFee or durationSeconds == 0
        if (schedule.startFee == schedule.endFee || schedule.durationSeconds == 0) {
            return (schedule.startFee, integratorFeeShare);
        }

        // Already fully decayed
        if (schedule.lastFee == schedule.endFee) {
            return (schedule.endFee, integratorFeeShare);
        }

        // Before schedule start
        if (block.timestamp <= schedule.startingTime) {
            return (schedule.startFee, integratorFeeShare);
        }

        uint256 elapsed = block.timestamp - schedule.startingTime;

        if (elapsed >= schedule.durationSeconds) {
            currentFee = schedule.endFee;
        } else {
            currentFee = _computeCurrentFee(schedule, elapsed);
        }

        // Only write to storage if the fee has changed (optimization to avoid redundant writes)
        if (currentFee < schedule.lastFee) {
            _feeSchedule[poolId].lastFee = currentFee;
            emit FeeUpdated(poolId, currentFee);
        }

        return (currentFee, integratorFeeShare);
    }

    /**
     * @dev Collects swap fees from a swap and updates hook fee tracking
     * @param sender Address that called PoolManager.swap
     * @param params Parameters of the swap
     * @param delta BalanceDelta of the swap
     * @param key Uniswap V4 pool key
     * @param poolId Uniswap V4 poolId (to save gas)
     * @return feeCurrency Currency in which the fee was collected (always the unspecified token)
     * @return feeDelta Amount of fee collected in feeCurrency
     * @return integratorFeeShare Immutable integrator share of gross Rehype fees
     */
    function _collectSwapFees(
        address sender,
        IPoolManager.SwapParams memory params,
        BalanceDelta delta,
        PoolKey memory key,
        PoolId poolId
    ) internal returns (Currency feeCurrency, int128 feeDelta, uint24 integratorFeeShare) {
        int256 outputAmount = params.zeroForOne ? delta.amount1() : delta.amount0();

        if (outputAmount <= 0) {
            integratorFeeShare = _feeSchedule[poolId].integratorFeeShare;
            return (feeCurrency, feeDelta, integratorFeeShare);
        }

        bool exactInput = params.amountSpecified < 0;

        // Fee is always taken from the unspecified token:
        feeCurrency = params.zeroForOne == exactInput ? key.currency1 : key.currency0;

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

        // If a swap is occurring within the same call frame as create, then one swap is exempted from
        // non-protocol fees. Only our Bundler is allowed to trigger this exemption.
        bool devBuyExempt = _checkDevBuyExemption(poolId, sender);
        if (devBuyExempt) {
            _clearDevBuyExemption(poolId);
        }

        uint24 currentFee;
        (currentFee, integratorFeeShare) = _getCurrentFee(poolId);
        uint256 feeAmount = FullMath.mulDiv(feeBase, currentFee, SWAP_FEE_DENOMINATOR);

        // Reserve owner and integrator shares from gross fees. The fee-distribution matrix receives the exact residual.
        uint256 airlockOwnerFee = FullMath.mulDiv(feeAmount, AIRLOCK_OWNER_FEE_BPS, BPS_DENOMINATOR);
        uint256 integratorFeeAmount = devBuyExempt || integratorFeeShare == 0
            ? 0
            : FullMath.mulDiv(feeAmount, integratorFeeShare, MILLIONTHS_DENOMINATOR);
        uint256 remainingFee = devBuyExempt ? 0 : feeAmount - airlockOwnerFee - integratorFeeAmount;
        uint256 collectedFee = devBuyExempt ? airlockOwnerFee : feeAmount;
        uint256 balanceOfFeeCurrency = feeCurrency.balanceOf(address(poolManager));

        if (balanceOfFeeCurrency < collectedFee) {
            revert InsufficientFeeCurrency();
        }

        poolManager.take(feeCurrency, address(this), collectedFee);

        if (feeCurrency == key.currency0) {
            getHookFees[poolId].airlockOwnerFees0 += uint128(airlockOwnerFee);
            getHookFees[poolId].fees0 += uint128(remainingFee);
        } else {
            getHookFees[poolId].airlockOwnerFees1 += uint128(airlockOwnerFee);
            getHookFees[poolId].fees1 += uint128(remainingFee);
        }

        if (integratorFeeAmount != 0) {
            IntegratorFees memory pendingFees = getPendingIntegratorFees[poolId];
            if (feeCurrency == key.currency0) {
                pendingFees.fees0 = _toUint128(uint256(pendingFees.fees0) + integratorFeeAmount);
            } else {
                pendingFees.fees1 = _toUint128(uint256(pendingFees.fees1) + integratorFeeAmount);
            }
            getPendingIntegratorFees[poolId] = pendingFees;
        }

        return (feeCurrency, int128(uint128(collectedFee)), integratorFeeShare);
    }

    /**
     * @dev Transfers a claimed currency and reverts on failure.
     */
    function _safeTransfer(Currency currency, address to, uint256 amount) internal {
        address token = Currency.unwrap(currency);
        if (token == address(0)) {
            SafeTransferLib.safeTransferETH(to, amount);
        } else {
            SafeTransferLib.safeTransfer(token, to, amount);
        }
    }

    /**
     * @dev Attempts an automatic payout without allowing its recipient to halt pool swaps.
     * Native transfers use a bounded gas stipend. ERC-20 return data is checked without ABI decoding so malformed
     * token responses become payout failures rather than reverting the outer swap.
     */
    function _tryAutomaticTransfer(Currency currency, address to, uint256 amount) internal returns (bool success) {
        address token = Currency.unwrap(currency);
        if (token == address(0)) {
            return SafeTransferLib.trySafeTransferETH(to, amount, SafeTransferLib.GAS_STIPEND_NO_GRIEF);
        }

        bytes memory result;
        (success, result) = token.call(abi.encodeWithSelector(0xa9059cbb, to, amount));
        if (!success) return false;
        if (result.length == 0) return token.code.length != 0;
        if (result.length < 32) return false;

        uint256 returned;
        assembly ("memory-safe") {
            returned := mload(add(result, 0x20))
        }
        return returned == 1;
    }

    /// @dev Checks if the call is from Airlock.create, which is possible by checking if the poolInitializer
    ///      has been set yet. It is only configured once the initial call into the pool initializer is complete.
    function _isAirlockCreate(address asset) internal view returns (bool) {
        IAirlock airlock = IAirlock(address(DopplerHookInitializer(payable(INITIALIZER)).airlock()));
        (,,,, address poolInitializer,,,,,) = airlock.getAssetData(asset);
        return poolInitializer == address(0);
    }

    function _setDevBuyExemption(PoolId poolId) internal {
        bytes32 slot = _devBuyExemptionSlot(poolId);
        assembly ("memory-safe") {
            tstore(slot, 1)
        }
    }

    function _clearDevBuyExemption(PoolId poolId) internal {
        bytes32 slot = _devBuyExemptionSlot(poolId);
        assembly ("memory-safe") {
            tstore(slot, 0)
        }
    }

    /// @dev Checks if the sender is our Bundler, and checks transient storage to confirm if this swap is
    ///      occurring within the Airlock.create call frame.
    function _checkDevBuyExemption(PoolId poolId, address sender) internal view returns (bool exempt) {
        if (sender != bundler) return false;

        bytes32 slot = _devBuyExemptionSlot(poolId);
        assembly ("memory-safe") {
            exempt := tload(slot)
        }
    }

    function _devBuyExemptionSlot(PoolId poolId) internal pure returns (bytes32) {
        return keccak256(abi.encode(DEV_BUY_EXEMPTION_SLOT, PoolId.unwrap(poolId)));
    }
}

interface IAirlock {
    function getAssetData(address asset)
        external
        view
        returns (
            address numeraire,
            address timelock,
            address governance,
            address liquidityMigrator,
            address poolInitializer,
            address pool,
            address migrationPool,
            uint256 numTokensToSell,
            uint256 totalSupply,
            address integrator
        );
}
