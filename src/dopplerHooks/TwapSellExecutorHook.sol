// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.26;

import { IPoolManager } from "@v4-core/interfaces/IPoolManager.sol";
import { StateLibrary } from "@v4-core/libraries/StateLibrary.sol";
import { TickMath } from "@v4-core/libraries/TickMath.sol";
import { BalanceDelta } from "@v4-core/types/BalanceDelta.sol";
import { Currency, CurrencyLibrary } from "@v4-core/types/Currency.sol";
import { PoolId } from "@v4-core/types/PoolId.sol";
import { PoolKey } from "@v4-core/types/PoolKey.sol";

import { Quoter } from "@quoter/Quoter.sol";

import { BaseDopplerHook } from "src/base/BaseDopplerHook.sol";
import { DopplerHookInitializer } from "src/initializers/DopplerHookInitializer.sol";
import { V4QuoteMath } from "src/libraries/V4QuoteMath.sol";

/// -----------------------------------------------------------------------
/// Interfaces
/// -----------------------------------------------------------------------

interface ITwapVault {
    function registerPool(PoolId poolId, address asset, address numeraire, address buybackDst) external;
    function inventory(PoolId poolId, address token) external view returns (uint256);
    function debitToExecutor(PoolId poolId, address token, uint256 amount, address to) external;
    function creditFromExecutor(PoolId poolId, address token, uint256 amount) external;
}

/// -----------------------------------------------------------------------
/// Errors / Events
/// -----------------------------------------------------------------------

error InvalidTwapSchedule();

event TwapScheduleInitialized(
    PoolId indexed poolId,
    uint32 startTs,
    uint32 endTs,
    uint256 rateValuePerSec,
    uint256 maxValuePerExecute,
    uint256 maxAccumulatorValue
);

event TwapSellExecuted(
    PoolId indexed poolId,
    uint256 assetInUsed,
    uint256 numeraireOut,
    uint256 accumulatorAfter
);

/// -----------------------------------------------------------------------
/// Hook: TWAP sell executor (vault-backed)
/// -----------------------------------------------------------------------

/**
 * @title TwapSellExecutorHook
 * @notice A minimal TWAP sell executor that:
 *  - tracks a buffered value-rate accumulator in **numeraire units/sec**
 *  - on execution, sells **asset -> numeraire** via Uniswap v4
 *  - uses a middleware vault (TwapVault) for custody and accounting
 *
 * Key property:
 *  - This hook executes TWAP in `_onSwap()` (swap-driven execution).
 *  - The vault is custody + accounting; this hook debits/credits vault inventory during swap.
 *
 * TODO: Execute TWAP earlier in the swap lifecycle ("before swap").
 * Today, Doppler calls this hook via `DopplerHookInitializer.afterSwap` -> `IDopplerHook.onSwap`.
 * Supporting a true pre-swap TWAP requires wiring a pre-swap callback through the initializer and/or
 * using Uniswap v4 hook permissions beyond the current Doppler hook interface.
 */
contract TwapSellExecutorHook is BaseDopplerHook {
    using StateLibrary for IPoolManager;
    using CurrencyLibrary for Currency;

    // "No-op" return for Doppler hook callbacks.
    // Doppler ignores the return value today; we keep this explicit to avoid repeating magic literals.
    Currency internal constant NOOP = Currency.wrap(address(0));
    int128 internal constant NOOP_DELTA = 0;

    uint256 internal constant MAX_TWAP_SEARCH_ITERATIONS = 15;

    IPoolManager public immutable poolManager;
    ITwapVault public immutable vault;
    Quoter public immutable quoter;

    struct PoolInfo {
        address asset;
        address numeraire;
        address buybackDst;
    }

    /// @notice Immutable linear TWAP schedule.
    /// @dev Budget accrues in numeraire value units over [startTs, endTs).
    /// - `rateValuePerSec`: value units per second (0 disables selling)
    /// - `maxValuePerExecute`: cap budget per execution (0 uncapped)
    /// - `maxAccumulatorValue`: cap total buffered budget (0 uncapped)
    struct TwapSellSchedule {
        uint32 startTs;
        uint32 endTs;
        uint256 rateValuePerSec;
        uint256 maxValuePerExecute;
        uint256 maxAccumulatorValue;
    }

    struct TwapSellState {
        uint256 accumulatorValue; // numeraire units
        uint32 lastTs; // last accumulator update timestamp
    }

    mapping(PoolId poolId => PoolInfo info) public getPoolInfo;
    mapping(PoolId poolId => TwapSellSchedule schedule) public getTwapSellSchedule;
    mapping(PoolId poolId => TwapSellState st) public getTwapSellState;

    /// @notice Last block number when TWAP was executed for a pool (to execute at most once per block).
    mapping(PoolId poolId => uint256 lastBlock) public lastTwapExecBlock;

    receive() external payable { }

    constructor(address initializer, IPoolManager poolManager_, ITwapVault vault_) BaseDopplerHook(initializer) {
        poolManager = poolManager_;
        vault = vault_;
        quoter = new Quoter(poolManager_);
    }

    // ---------------------------------------------------------------------
    // BaseDopplerHook: initialization/swap/graduation
    // ---------------------------------------------------------------------

    function _onInitialization(address asset, PoolKey calldata key, bytes calldata data) internal override {
        (
            address numeraire,
            address buybackDst,
            uint32 startTs,
            uint32 endTs,
            uint256 rateValuePerSec,
            uint256 maxValuePerExecute,
            uint256 maxAccumulatorValue
        ) = abi.decode(data, (address, address, uint32, uint32, uint256, uint256, uint256));

        if (endTs <= startTs) revert InvalidTwapSchedule();

        PoolId poolId = key.toId();
        getPoolInfo[poolId] = PoolInfo({ asset: asset, numeraire: numeraire, buybackDst: buybackDst });

        getTwapSellSchedule[poolId] = TwapSellSchedule({
            startTs: startTs,
            endTs: endTs,
            rateValuePerSec: rateValuePerSec,
            maxValuePerExecute: maxValuePerExecute,
            maxAccumulatorValue: maxAccumulatorValue
        });

        getTwapSellState[poolId].lastTs = uint32(block.timestamp);

        emit TwapScheduleInitialized(poolId, startTs, endTs, rateValuePerSec, maxValuePerExecute, maxAccumulatorValue);

        // Register pool in the vault so it can enforce access control and maintain accounting.
        // NOTE: requires TwapVault.executor == address(this).
        vault.registerPool(poolId, asset, numeraire, buybackDst);
    }

    function _onSwap(
        address sender,
        PoolKey calldata key,
        IPoolManager.SwapParams calldata,
        BalanceDelta,
        bytes calldata
    ) internal override returns (Currency, int128) {
        // Recursion guard: when this hook executes its own swap, do not re-enter TWAP.
        if (sender == address(this)) {
            return (NOOP, NOOP_DELTA);
        }

        PoolId poolId = key.toId();

        TwapSellState storage st = getTwapSellState[poolId];

        // Execute at most once per block ("start of block" semantics).
        if (lastTwapExecBlock[poolId] == block.number) {
            return (NOOP, NOOP_DELTA);
        }

        TwapSellSchedule memory sched = getTwapSellSchedule[poolId];
        if (sched.rateValuePerSec == 0) {
            return (NOOP, NOOP_DELTA);
        }

        // Accrue budget in-memory first; commit to storage only once per path.
        (uint32 lastAfterAccrue, uint256 accAfterAccrue) = _computeAccrual(sched, st.lastTs, uint32(block.timestamp), st.accumulatorValue);

        uint256 accValue = accAfterAccrue;
        if (accValue == 0) {
            _commitState(st, lastAfterAccrue, accAfterAccrue);
            return (NOOP, NOOP_DELTA);
        }

        PoolInfo memory p = getPoolInfo[poolId];
        address asset = p.asset;

        // Resolve tokens/direction.
        bool assetIsToken0 = key.currency0 == Currency.wrap(asset);
        bool zeroForOne = assetIsToken0; // asset -> numeraire

        uint256 valueBudget = accValue;
        if (sched.maxValuePerExecute != 0 && valueBudget > sched.maxValuePerExecute) {
            valueBudget = sched.maxValuePerExecute;
        }
        if (valueBudget == 0) {
            return (NOOP, NOOP_DELTA);
        }

        uint256 availableAsset = vault.inventory(poolId, asset);
        if (availableAsset == 0) {
            _commitState(st, lastAfterAccrue, accAfterAccrue);
            return (NOOP, NOOP_DELTA);
        }

        // Convert a numeraire value budget into an (amountIn -> amountOut) swap plan.
        // This is a bounded binary-search using the v4 Quoter, which accounts for price impact
        // and avoids relying on spot-price math.
        (uint256 amountIn, uint256 expectedOut) = V4QuoteMath.findAmountInForOutBudget(
            quoter, key, zeroForOne, valueBudget, availableAsset, MAX_TWAP_SEARCH_ITERATIONS
        );
        if (amountIn == 0 || expectedOut == 0) {
            _commitState(st, lastAfterAccrue, accAfterAccrue);
            return (NOOP, NOOP_DELTA);
        }

        // Debit from vault into executor.
        vault.debitToExecutor(poolId, asset, amountIn, address(this));

        // Execute the swap directly (we are already in the PoolManager's swap lifecycle).
        // If this swap reverts, the entire call stack reverts, including the prior vault debit.
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

        uint256 assetInUsed = zeroForOne ? _abs(swapDelta.amount0()) : _abs(swapDelta.amount1());
        uint256 numeraireOut = zeroForOne ? _abs(swapDelta.amount1()) : _abs(swapDelta.amount0());

        if (assetInUsed == 0 || numeraireOut == 0) {
            // If we somehow used no input, refund any remaining balance.
            uint256 bal = Currency.wrap(asset).balanceOf(address(this));
            if (bal > 0) {
                _transferToken(asset, address(vault), bal);
                vault.creditFromExecutor(poolId, asset, bal);
            }

            _commitState(st, lastAfterAccrue, accAfterAccrue);
            return (NOOP, NOOP_DELTA);
        }

        // Refund any unused input.
        if (assetInUsed < amountIn) {
            uint256 refund = amountIn - assetInUsed;
            _transferToken(asset, address(vault), refund);
            vault.creditFromExecutor(poolId, asset, refund);
        }

        // Forward proceeds to vault.
        address numeraire = p.numeraire;
        _transferToken(numeraire, address(vault), numeraireOut);
        vault.creditFromExecutor(poolId, numeraire, numeraireOut);

        // Update accumulator (saturating). Commit lastTs + accumulator in one storage write for accumulator.
        uint256 accAfter = numeraireOut >= accValue ? 0 : (accValue - numeraireOut);
        _commitState(st, lastAfterAccrue, accAfter);
        lastTwapExecBlock[poolId] = block.number;

        emit TwapSellExecuted(poolId, assetInUsed, numeraireOut, accAfter);
        return (NOOP, NOOP_DELTA);
    }

    function _onGraduation(address, PoolKey calldata, bytes calldata) internal pure override { }

    // ---------------------------------------------------------------------
    // Accumulator (bounded linear stream over [startTs, endTs))
    // ---------------------------------------------------------------------

    function _computeAccrual(
        TwapSellSchedule memory sched,
        uint32 last,
        uint32 nowTs,
        uint256 oldAcc
    ) internal pure returns (uint32 lastAfter, uint256 accAfter) {
        // Default: no change.
        lastAfter = last;
        accAfter = oldAcc;

        if (last == 0) {
            // Initialize lastTs on first touch.
            lastAfter = nowTs;
            return (lastAfter, accAfter);
        }
        if (nowTs <= last) return (lastAfter, accAfter);

        if (sched.rateValuePerSec == 0) return (lastAfter, accAfter);

        uint32 from = last < sched.startTs ? sched.startTs : last;
        uint32 to = nowTs < sched.endTs ? nowTs : sched.endTs;
        if (to <= from) return (lastAfter, accAfter);

        lastAfter = to;

        uint256 dt = uint256(to - from);
        uint256 add = sched.rateValuePerSec * dt;
        if (add == 0) return (lastAfter, accAfter);

        uint256 newAcc = oldAcc + add;
        if (sched.maxAccumulatorValue != 0 && newAcc > sched.maxAccumulatorValue) {
            newAcc = sched.maxAccumulatorValue;
        }

        accAfter = newAcc;
    }

    function _commitState(TwapSellState storage st, uint32 lastAfter, uint256 accAfter) internal {
        if (lastAfter != 0 && lastAfter != st.lastTs) {
            st.lastTs = lastAfter;
        }
        if (accAfter != st.accumulatorValue) {
            st.accumulatorValue = accAfter;
        }
    }

    // NOTE: Quoting + inversion helpers live in `src/libraries/V4QuoteMath.sol`.

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

    function _abs(int256 value) internal pure returns (uint256) {
        return value < 0 ? uint256(-value) : uint256(value);
    }

    // ---------------------------------------------------------------------
    // Token transfer helper
    // ---------------------------------------------------------------------

    function _transferToken(address token, address to, uint256 amount) internal {
        if (amount == 0) return;

        if (token == address(0)) {
            (bool ok,) = to.call{ value: amount }("");
            require(ok, "ETH_TRANSFER_FAILED");
        } else {
            Currency.wrap(token).transfer(to, amount);
        }
    }
}
