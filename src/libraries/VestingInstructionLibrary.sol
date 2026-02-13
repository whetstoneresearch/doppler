// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.26;

import { SafeTransferLib } from "@solady/utils/SafeTransferLib.sol";
import { IPoolManager } from "@v4-core/interfaces/IPoolManager.sol";
import { TickMath } from "@v4-core/libraries/TickMath.sol";
import { BalanceDelta } from "@v4-core/types/BalanceDelta.sol";
import { Currency, CurrencyLibrary } from "@v4-core/types/Currency.sol";
import { PoolKey } from "@v4-core/types/PoolKey.sol";

/// @notice Thrown when governance executor is not authorized
error SenderNotAuthorized();

/// @notice Thrown when instruction amount is zero
error InvalidInstructionAmount();

/// @notice Thrown when instruction period is not in the future
error InstructionPeriodNotInFuture(uint256 periodId, uint256 unlockTime, uint256 currentTime);

/// @notice Thrown when instruction period is lower than the highest previously queued period
error InstructionPeriodOutOfOrder(uint256 lastPeriodId, uint256 periodId);

/// @notice Thrown when instruction type does not match requested execution path
error InvalidInstructionType();

/// @notice Thrown when instruction is canceled
error InstructionCancelled();

/// @notice Thrown when instruction has already been executed
error InstructionAlreadyExecuted();

/// @notice Thrown when execution is attempted before period unlock
error InstructionNotUnlocked(uint256 unlockTime, uint256 currentTime);

/// @notice Thrown when swap output is lower than requested `minAmountOut`
error InsufficientSwapOutput(uint256 actualAmountOut, uint256 minAmountOut);

/// @notice Thrown when an arbitrary token transfer attempts to use a zero token address
error InvalidTransferToken();

/// @notice Thrown when ETH transfer amount is above contract balance
error InsufficientEthBalance(uint256 amount, uint256 balance);

/// @notice Thrown when launch asset sell amount cannot fit in int256 for V4 exact input swap
error SellAmountTooLarge(uint256 amount);

/// @notice Instruction type used for scheduled vesting actions
enum InstructionType {
    SellAssetToPool,
    TransferToBeneficiary
}

/// @notice Scheduled instruction for a specific period
struct Instruction {
    InstructionType instructionType;
    address token;
    uint256 amount;
    bool executed;
    bool cancelled;
}

/**
 * @notice Validation and execution helpers for vesting instructions.
 */
library VestingInstructionLibrary {
    using CurrencyLibrary for Currency;

    /// @dev Callback payload used by `poolManager.unlock`.
    struct SwapCallbackData {
        PoolKey poolKey;
        bool zeroForOne;
        uint256 amountIn;
        uint160 sqrtPriceLimitX96;
        bytes hookData;
    }

    function validateQueueAmount(uint256 amount) internal pure {
        require(amount != 0, InvalidInstructionAmount());
    }

    function validateQueuePeriod(uint256 periodId, uint256 unlockTimestamp, uint256 currentTime) internal pure {
        require(unlockTimestamp > currentTime, InstructionPeriodNotInFuture(periodId, unlockTimestamp, currentTime));
    }

    function validateQueueOrdering(bool hasQueuedInstructions, uint256 lastQueuedPeriodId, uint256 periodId) internal pure {
        require(
            !hasQueuedInstructions || periodId >= lastQueuedPeriodId,
            InstructionPeriodOutOfOrder(lastQueuedPeriodId, periodId)
        );
    }

    function normalizeQueueToken(
        InstructionType instructionType,
        address token,
        address asset
    ) internal pure returns (address normalizedToken) {
        if (instructionType == InstructionType.SellAssetToPool) {
            return asset;
        }

        if (instructionType == InstructionType.TransferToBeneficiary) {
            return token;
        }

        revert InvalidInstructionType();
    }

    function assertNotCancelledOrExecuted(Instruction storage instruction) internal view {
        require(!instruction.cancelled, InstructionCancelled());
        require(!instruction.executed, InstructionAlreadyExecuted());
    }

    function assertExecutable(Instruction storage instruction, InstructionType expectedType) internal view {
        assertNotCancelledOrExecuted(instruction);
        require(instruction.instructionType == expectedType, InvalidInstructionType());
    }

    function isProcessable(Instruction storage instruction) internal view returns (bool) {
        return !instruction.cancelled && !instruction.executed;
    }

    function isUnlocked(uint256 unlockTimestamp, uint256 currentTime) internal pure returns (bool) {
        return currentTime >= unlockTimestamp;
    }

    function isPermissionless(uint256 unlockTimestamp, uint256 graceDuration, uint256 currentTime)
        internal
        pure
        returns (bool)
    {
        return currentTime >= unlockTimestamp + graceDuration;
    }

    function isAuthorizedDuringGrace(address sender, address ownerAddress, address governanceExecutorAddress)
        internal
        pure
        returns (bool)
    {
        return sender == ownerAddress || sender == governanceExecutorAddress;
    }

    function assertExecutionAuthorization(
        uint256 unlockTimestamp,
        uint256 currentTime,
        bool permissionlessExecution,
        address sender,
        address ownerAddress,
        address governanceExecutorAddress
    ) internal pure {
        require(isUnlocked(unlockTimestamp, currentTime), InstructionNotUnlocked(unlockTimestamp, currentTime));
        require(
            permissionlessExecution || isAuthorizedDuringGrace(sender, ownerAddress, governanceExecutorAddress),
            SenderNotAuthorized()
        );
    }

    function releaseReservedAmount(
        mapping(address token => uint256 amount) storage queuedAmountByToken,
        address token,
        uint256 amount
    ) internal {
        if (amount == 0) return;
        queuedAmountByToken[token] -= amount;
    }

    function resolveSqrtPriceLimit(bool zeroForOne, uint160 sqrtPriceLimitX96) internal pure returns (uint160) {
        if (sqrtPriceLimitX96 != 0) return sqrtPriceLimitX96;
        return zeroForOne ? TickMath.MIN_SQRT_PRICE + 1 : TickMath.MAX_SQRT_PRICE - 1;
    }

    function unlockAndSwapExactInput(
        IPoolManager poolManager,
        PoolKey memory poolKey,
        bool zeroForOne,
        uint256 amountIn,
        uint160 sqrtPriceLimitX96,
        bytes memory hookData
    ) internal returns (uint256 amountOut) {
        bytes memory encoded = poolManager.unlock(
            abi.encode(
                SwapCallbackData({
                    poolKey: poolKey,
                    zeroForOne: zeroForOne,
                    amountIn: amountIn,
                    sqrtPriceLimitX96: sqrtPriceLimitX96,
                    hookData: hookData
                })
            )
        );

        BalanceDelta swapDelta = abi.decode(encoded, (BalanceDelta));
        int128 outDelta = zeroForOne ? swapDelta.amount1() : swapDelta.amount0();
        amountOut = outDelta > 0 ? uint256(uint128(outDelta)) : 0;
    }

    function settleSwapDelta(IPoolManager poolManager, PoolKey memory poolKey, BalanceDelta swapDelta) internal {
        int128 amount0 = swapDelta.amount0();
        int128 amount1 = swapDelta.amount1();

        if (amount0 > 0) {
            poolManager.take(poolKey.currency0, address(this), uint256(uint128(amount0)));
        }

        if (amount1 > 0) {
            poolManager.take(poolKey.currency1, address(this), uint256(uint128(amount1)));
        }

        if (amount0 < 0) {
            _pay(poolManager, poolKey.currency0, uint256(-int256(amount0)));
        }

        if (amount1 < 0) {
            _pay(poolManager, poolKey.currency1, uint256(-int256(amount1)));
        }
    }

    function executeSellInstruction(
        Instruction storage instruction,
        mapping(address token => uint256 amount) storage queuedAmountByToken,
        IPoolManager poolManager,
        PoolKey memory poolKey,
        bool zeroForOne,
        uint256 minAmountOut,
        uint160 sqrtPriceLimitX96,
        bytes memory hookData
    ) internal returns (uint256 amountIn, uint256 amountOut) {
        assertExecutable(instruction, InstructionType.SellAssetToPool);

        amountIn = instruction.amount;
        require(amountIn <= uint256(type(int256).max), SellAmountTooLarge(amountIn));

        releaseReservedAmount(queuedAmountByToken, instruction.token, amountIn);

        amountOut = unlockAndSwapExactInput(poolManager, poolKey, zeroForOne, amountIn, sqrtPriceLimitX96, hookData);
        require(amountOut >= minAmountOut, InsufficientSwapOutput(amountOut, minAmountOut));

        instruction.executed = true;
    }

    function executeTransferInstruction(
        Instruction storage instruction,
        mapping(address token => uint256 amount) storage queuedAmountByToken,
        address beneficiary
    ) internal returns (uint256 transferred, address transferToken) {
        assertExecutable(instruction, InstructionType.TransferToBeneficiary);

        releaseReservedAmount(queuedAmountByToken, instruction.token, instruction.amount);

        instruction.executed = true;
        transferred = instruction.amount;

        if (instruction.token != address(0)) {
            SafeTransferLib.safeTransfer(instruction.token, beneficiary, instruction.amount);
            return (transferred, instruction.token);
        }

        uint256 balance = address(this).balance;
        require(instruction.amount <= balance, InsufficientEthBalance(instruction.amount, balance));
        SafeTransferLib.safeTransferETH(beneficiary, instruction.amount);
        return (transferred, address(0));
    }

    function _pay(IPoolManager poolManager, Currency currency, uint256 amount) private {
        poolManager.sync(currency);

        if (currency.isAddressZero()) {
            poolManager.settle{ value: amount }();
        } else {
            currency.transfer(address(poolManager), amount);
            poolManager.settle();
        }
    }
}
