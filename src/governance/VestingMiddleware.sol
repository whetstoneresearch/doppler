// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.26;

import { Ownable } from "@openzeppelin/access/Ownable.sol";
import { ReentrancyGuard } from "@solady/utils/ReentrancyGuard.sol";
import { SafeTransferLib } from "@solady/utils/SafeTransferLib.sol";
import { IPoolManager } from "@v4-core/interfaces/IPoolManager.sol";
import { IUnlockCallback } from "@v4-core/interfaces/callback/IUnlockCallback.sol";
import { BalanceDelta } from "@v4-core/types/BalanceDelta.sol";
import { Currency, CurrencyLibrary } from "@v4-core/types/Currency.sol";
import { PoolId, PoolIdLibrary } from "@v4-core/types/PoolId.sol";
import { PoolKey } from "@v4-core/types/PoolKey.sol";
import { ImmutableState } from "@v4-periphery/base/ImmutableState.sol";
import { ImmutableAirlock } from "src/base/ImmutableAirlock.sol";
import { ILiquidityMigrator } from "src/interfaces/ILiquidityMigrator.sol";
import { IPoolInitializer } from "src/interfaces/IPoolInitializer.sol";
import { IVestingInitializerReader } from "src/interfaces/IVestingInitializerReader.sol";
import { IVestingMigratorReader } from "src/interfaces/IVestingMigratorReader.sol";
import {
    InsufficientEthBalance,
    Instruction,
    InstructionCancelled,
    InstructionType,
    InvalidInstructionType,
    InvalidInstructionAmount,
    InstructionAlreadyExecuted,
    InstructionNotUnlocked,
    InstructionPeriodNotInFuture,
    InstructionPeriodOutOfOrder,
    InvalidTransferToken,
    SenderNotAuthorized,
    SellAmountTooLarge,
    InsufficientSwapOutput,
    VestingInstructionLibrary
} from "src/libraries/VestingInstructionLibrary.sol";

/// @notice Thrown when period duration is below 15 minutes
error InvalidPeriodDuration(uint32 periodDuration);

/// @notice Thrown when beneficiary is address zero
error InvalidBeneficiary();

/// @notice Thrown when initializer kind value is invalid
error InvalidInitializerKind(uint8 kind);

/// @notice Thrown when instruction id is out of range
error InstructionNotFound(uint256 periodId, uint256 instructionId);

/// @notice Thrown when launch asset sell is attempted without an initialized issuance pool
error IssuancePoolUnavailable();

/// @notice Thrown when launch asset sell is attempted after issuance pool has exited
error IssuancePoolExited();

/// @notice Thrown when `collectFees` cannot determine a valid target route
error NoCollectableFeesPath();

/// @notice Thrown when non-beneficiary attempts to withdraw numeraire
error SenderNotBeneficiary();

/// @notice Thrown when a queued instruction exceeds currently available unreserved balance
error InstructionAmountUnavailable(address token, uint256 amount, uint256 available);

/// @notice Emitted when a new instruction is queued
event QueueInstruction(
    uint256 indexed periodId,
    uint256 indexed instructionId,
    InstructionType indexed instructionType,
    address token,
    uint256 amount
);

/// @notice Emitted when a queued instruction is canceled
event CancelInstruction(uint256 indexed periodId, uint256 indexed instructionId);

/// @notice Emitted when a sell instruction is executed
event ExecuteSellInstruction(
    uint256 indexed periodId,
    uint256 indexed instructionId,
    uint256 amountIn,
    uint256 amountOut,
    bool permissionlessExecution
);

/// @notice Emitted when a transfer instruction is executed
event ExecuteTransferInstruction(
    uint256 indexed periodId,
    uint256 indexed instructionId,
    address indexed token,
    uint256 amount,
    bool permissionlessExecution
);

/// @notice Emitted when fees are collected through initializer or locker route
event CollectFees(address indexed target, PoolId indexed poolId, uint128 fees0, uint128 fees1);

/// @notice Emitted when numeraire is withdrawn to beneficiary
event WithdrawNumeraire(address indexed beneficiary, uint256 amount);

/// @notice Emitted when governance executor is updated
event SetGovernanceExecutor(address indexed oldExecutor, address indexed newExecutor);

/// @notice Emitted when initializer kind is updated.
event SetInitializerKind(InitializerKind indexed oldKind, InitializerKind indexed newKind);

/// @notice Emitted when instruction processing cursor advances
event ProcessInstructions(address indexed sender, uint256 nextPeriodId, uint256 nextInstructionId);

/// @notice Expected initializer reader shape used by this middleware instance.
enum InitializerKind {
    UniswapV4MulticurveLike,
    DopplerHook
}

/// @notice Internal route target for fee collection
enum FeeCollectionTarget {
    None,
    Initializer,
    Locker
}

/// @dev Common collect interface for initializer and locker fee managers.
interface ICollectFeesTarget {
    function collectFees(PoolId poolId) external returns (uint128 fees0, uint128 fees1);
}

/// @dev Reads state from UniswapV4Multicurve-style initializers (including Decay/Scheduled variants).
interface IUniswapV4MulticurveInitializerReader {
    function getState(address asset)
        external
        view
        returns (address numeraire, uint8 status, PoolKey memory poolKey, int24 farTick);
}

/**
 * @title VestingMiddleware
 * @author Whetstone Research
 * @custom:security-contact security@whetstone.cc
 * @notice Custodies launch inventory, executes periodized vesting instructions, and routes fee collection by lifecycle.
 */
contract VestingMiddleware is Ownable, ReentrancyGuard, ImmutableAirlock, ImmutableState, IUnlockCallback {
    using CurrencyLibrary for Currency;
    using PoolIdLibrary for PoolKey;
    using VestingInstructionLibrary for Instruction;
    using VestingInstructionLibrary for IPoolManager;

    uint32 public constant MIN_PERIOD_DURATION = 15 minutes;
    uint8 internal constant STATUS_LOCKED = 2;
    uint8 internal constant MULTICURVE_STATUS_EXITED = 3;
    uint8 internal constant DOPPLER_HOOK_STATUS_EXITED = 4;

    /// @notice Launch asset sold by this middleware
    address public immutable asset;

    /// @notice Numeraire token received from sells and fee collection
    address public immutable numeraire;

    /// @notice Fixed beneficiary in p0 receiving numeraire withdrawals and transfer instructions
    address public immutable beneficiary;

    /// @notice Unix timestamp of period 0 unlock
    uint64 public immutable streamStart;

    /// @notice Duration of each period in seconds
    uint32 public immutable periodDuration;

    /// @notice Grace window duration in seconds (owner/executor-only execution window)
    uint32 public immutable graceDuration;

    /// @notice Initializer kind used for all initializer state reads.
    InitializerKind public initializerKind;

    /// @notice Optional non-owner executor authorized during grace windows
    address public governanceExecutor;

    /// @notice Cached issuance pool key from initializer state
    PoolKey public issuancePoolKey;

    /// @notice Whether `issuancePoolKey` has been resolved and cached
    bool public issuancePoolKeySynced;

    /// @notice Whether launch asset is `currency0` in `issuancePoolKey`
    bool public assetIsToken0;

    /// @dev Period id => queued instructions
    mapping(uint256 periodId => Instruction[]) internal _instructions;

    /// @notice Amount currently queued (unexecuted and not canceled) per token (address(0) = ETH)
    mapping(address token => uint256 amount) public queuedAmountByToken;

    /// @notice Next instruction cursor period for `processInstructions`
    uint256 public nextProcessPeriodId;

    /// @notice Next instruction cursor id inside `nextProcessPeriodId`
    uint256 public nextProcessInstructionId;

    /// @notice Highest period id that has ever been queued
    uint256 public lastQueuedPeriodId;

    /// @notice Whether at least one instruction has been queued
    bool public hasQueuedInstructions;

    modifier onlyBeneficiary() {
        if (msg.sender != beneficiary) revert SenderNotBeneficiary();
        _;
    }

    constructor(
        address airlock_,
        address asset_,
        address numeraire_,
        IPoolManager poolManager_,
        address beneficiary_,
        address governanceExecutor_,
        uint64 streamStart_,
        uint32 periodDuration_,
        uint32 graceDuration_,
        uint8 initializerKind_,
        address owner_
    ) Ownable(owner_) ImmutableAirlock(airlock_) ImmutableState(poolManager_) {
        if (periodDuration_ < MIN_PERIOD_DURATION) revert InvalidPeriodDuration(periodDuration_);
        if (beneficiary_ == address(0)) revert InvalidBeneficiary();
        if (initializerKind_ > uint8(InitializerKind.DopplerHook)) revert InvalidInitializerKind(initializerKind_);

        asset = asset_;
        numeraire = numeraire_;
        beneficiary = beneficiary_;
        streamStart = streamStart_;
        periodDuration = periodDuration_;
        graceDuration = graceDuration_;
        initializerKind = InitializerKind(initializerKind_);
        governanceExecutor = governanceExecutor_ == address(0) ? owner_ : governanceExecutor_;
    }

    receive() external payable { }

    /// @inheritdoc IUnlockCallback
    function unlockCallback(bytes calldata data) external onlyPoolManager returns (bytes memory) {
        VestingInstructionLibrary.SwapCallbackData memory swapData =
            abi.decode(data, (VestingInstructionLibrary.SwapCallbackData));
        uint160 sqrtPriceLimitX96 =
            VestingInstructionLibrary.resolveSqrtPriceLimit(swapData.zeroForOne, swapData.sqrtPriceLimitX96);

        BalanceDelta swapDelta = poolManager.swap(
            swapData.poolKey,
            IPoolManager.SwapParams({
                zeroForOne: swapData.zeroForOne,
                amountSpecified: -int256(swapData.amountIn),
                sqrtPriceLimitX96: sqrtPriceLimitX96
            }),
            swapData.hookData
        );

        VestingInstructionLibrary.settleSwapDelta(poolManager, swapData.poolKey, swapDelta);
        return abi.encode(swapDelta);
    }

    /// @notice Queues a sell instruction for a future period.
    function queueSellInstruction(uint256 periodId, uint256 amount) external onlyOwner returns (uint256 instructionId) {
        return _queueInstruction(periodId, InstructionType.SellAssetToPool, asset, amount);
    }

    /// @notice Queues a token transfer instruction for a future period.
    function queueTransferTokenInstruction(
        uint256 periodId,
        address token,
        uint256 amount
    ) external onlyOwner returns (uint256 instructionId) {
        require(token != address(0), InvalidTransferToken());
        return _queueInstruction(periodId, InstructionType.TransferToBeneficiary, token, amount);
    }

    /// @notice Queues an ETH transfer instruction for a future period.
    function queueTransferETHInstruction(
        uint256 periodId,
        uint256 amount
    ) external onlyOwner returns (uint256 instructionId) {
        return _queueInstruction(periodId, InstructionType.TransferToBeneficiary, address(0), amount);
    }

    /// @notice Cancels a queued instruction.
    function cancelInstruction(uint256 periodId, uint256 instructionId) external onlyOwner {
        Instruction storage instruction = _getInstruction(periodId, instructionId);
        instruction.assertNotCancelledOrExecuted();
        VestingInstructionLibrary.releaseReservedAmount(queuedAmountByToken, instruction.token, instruction.amount);
        instruction.cancelled = true;
        emit CancelInstruction(periodId, instructionId);
    }

    /// @notice Executes a sell instruction against the issuance pool.
    function executeSellInstruction(
        uint256 periodId,
        uint256 instructionId,
        uint256 minAmountOut,
        uint160 sqrtPriceLimitX96,
        bytes calldata hookData
    ) external nonReentrant returns (uint256 amountOut) {
        bool permissionlessExecution = _authorizeExecution(periodId);

        Instruction storage instruction = _getInstruction(periodId, instructionId);
        instruction.assertExecutable(InstructionType.SellAssetToPool);
        amountOut = _executeSellInstruction(
            periodId, instructionId, instruction, permissionlessExecution, minAmountOut, sqrtPriceLimitX96, hookData
        );
    }

    /// @notice Executes token or ETH transfer instruction to fixed beneficiary.
    function executeTransferInstruction(
        uint256 periodId,
        uint256 instructionId
    ) external nonReentrant returns (uint256 transferred) {
        bool permissionlessExecution = _authorizeExecution(periodId);

        Instruction storage instruction = _getInstruction(periodId, instructionId);
        instruction.assertExecutable(InstructionType.TransferToBeneficiary);
        transferred = _executeTransferInstruction(periodId, instructionId, instruction, permissionlessExecution);
    }

    /// @notice Collects fees from initializer if still locked there, otherwise from migrator locker if migrated.
    function collectFees() external nonReentrant returns (uint128 fees0, uint128 fees1) {
        (address initializer, address liquidityMigrator) = _getModuleAddresses();

        (FeeCollectionTarget target, PoolId poolId, address collectTarget) =
            _resolveFeeCollectionTarget(initializer, liquidityMigrator);

        if (target == FeeCollectionTarget.None) revert NoCollectableFeesPath();

        (fees0, fees1) = ICollectFeesTarget(collectTarget).collectFees(poolId);
        emit CollectFees(collectTarget, poolId, fees0, fees1);
    }

    /// @notice Allows fixed beneficiary to withdraw numeraire at any time.
    function withdrawNumeraire(uint256 amount) external nonReentrant onlyBeneficiary {
        _withdrawNumeraire(amount);
    }

    /// @notice Allows fixed beneficiary to withdraw full numeraire balance at any time.
    function withdrawAllNumeraire() external nonReentrant onlyBeneficiary returns (uint256 withdrawnAmount) {
        if (numeraire == address(0)) {
            withdrawnAmount = address(this).balance;
        } else {
            withdrawnAmount = SafeTransferLib.balanceOf(numeraire, address(this));
        }

        _withdrawNumeraire(withdrawnAmount);
    }

    /// @notice Updates governance executor address.
    function setGovernanceExecutor(address newExecutor) external onlyOwner {
        address oldExecutor = governanceExecutor;
        governanceExecutor = newExecutor == address(0) ? owner() : newExecutor;
        emit SetGovernanceExecutor(oldExecutor, governanceExecutor);
    }

    /// @notice Updates the initializer kind used for state reads.
    function setInitializerKind(uint8 newKind) external onlyOwner {
        require(newKind <= uint8(InitializerKind.DopplerHook), InvalidInitializerKind(newKind));
        InitializerKind oldKind = initializerKind;
        InitializerKind updatedKind = InitializerKind(newKind);
        initializerKind = updatedKind;
        issuancePoolKeySynced = false;
        delete issuancePoolKey;
        assetIsToken0 = false;
        emit SetInitializerKind(oldKind, updatedKind);
    }

    /// @notice Returns instruction count for a given period.
    function getInstructionCount(uint256 periodId) external view returns (uint256) {
        return _instructions[periodId].length;
    }

    /// @notice Returns instruction data for a given period/id pair.
    function getInstruction(uint256 periodId, uint256 instructionId) external view returns (Instruction memory) {
        return _getInstruction(periodId, instructionId);
    }

    /// @notice Returns unlock timestamp for a period id.
    function periodUnlockTimestamp(uint256 periodId) public view returns (uint256) {
        return uint256(streamStart) + periodId * uint256(periodDuration);
    }

    /// @notice Returns whether execution is currently permissionless for a period.
    function isPermissionlessExecution(uint256 periodId) external view returns (bool) {
        return _isPermissionlessExecution(periodId);
    }

    /// @notice Manually resolves and caches issuance pool key from initializer state.
    function syncIssuancePoolKey() external returns (PoolKey memory) {
        PoolKey memory poolKey = _syncIssuancePoolKey();
        return poolKey;
    }

    /// @notice Processes queued instructions in-order using full amount for each unlocked instruction.
    function processInstructions() external nonReentrant {
        _processInstructions(0, 0, bytes(""));
    }

    function _queueInstruction(
        uint256 periodId,
        InstructionType instructionType,
        address token,
        uint256 amount
    ) internal returns (uint256 instructionId) {
        token = _validateAndNormalizeQueueInstruction(periodId, instructionType, token, amount);
        _reserveInstructionAmount(token, amount);

        instructionId = _instructions[periodId].length;
        _instructions[periodId].push(
            Instruction({ instructionType: instructionType, token: token, amount: amount, executed: false, cancelled: false })
        );

        if (!hasQueuedInstructions) {
            hasQueuedInstructions = true;
            nextProcessPeriodId = periodId;
            nextProcessInstructionId = 0;
            lastQueuedPeriodId = periodId;
        } else if (periodId > lastQueuedPeriodId) {
            lastQueuedPeriodId = periodId;
        }

        emit QueueInstruction(periodId, instructionId, instructionType, token, amount);
    }

    function _validateAndNormalizeQueueInstruction(
        uint256 periodId,
        InstructionType instructionType,
        address token,
        uint256 amount
    ) internal view returns (address normalizedToken) {
        VestingInstructionLibrary.validateQueueAmount(amount);
        uint256 unlockTimestamp = periodUnlockTimestamp(periodId);
        VestingInstructionLibrary.validateQueuePeriod(periodId, unlockTimestamp, block.timestamp);
        VestingInstructionLibrary.validateQueueOrdering(hasQueuedInstructions, lastQueuedPeriodId, periodId);
        normalizedToken = VestingInstructionLibrary.normalizeQueueToken(instructionType, token, asset);
    }

    function _getInstruction(
        uint256 periodId,
        uint256 instructionId
    ) internal view returns (Instruction storage instruction) {
        require(instructionId < _instructions[periodId].length, InstructionNotFound(periodId, instructionId));
        instruction = _instructions[periodId][instructionId];
    }

    function _isPermissionlessExecution(uint256 periodId) internal view returns (bool) {
        uint256 unlockTimestamp = periodUnlockTimestamp(periodId);
        return VestingInstructionLibrary.isPermissionless(unlockTimestamp, uint256(graceDuration), block.timestamp);
    }

    function _authorizeExecution(uint256 periodId) internal view returns (bool permissionlessExecution) {
        permissionlessExecution = _isPermissionlessExecution(periodId);
        _checkExecutionAuthorization(periodId, permissionlessExecution);
    }

    function _checkExecutionAuthorization(uint256 periodId, bool permissionlessExecution) internal view {
        uint256 unlockTimestamp = periodUnlockTimestamp(periodId);
        VestingInstructionLibrary.assertExecutionAuthorization(
            unlockTimestamp, block.timestamp, permissionlessExecution, msg.sender, owner(), governanceExecutor
        );
    }

    function _withdrawNumeraire(uint256 amount) internal {
        if (numeraire == address(0)) {
            uint256 balance = address(this).balance;
            require(amount <= balance, InsufficientEthBalance(amount, balance));
            if (amount > 0) SafeTransferLib.safeTransferETH(beneficiary, amount);
        } else {
            if (amount > 0) SafeTransferLib.safeTransfer(numeraire, beneficiary, amount);
        }

        emit WithdrawNumeraire(beneficiary, amount);
    }

    function _getOrSyncIssuancePoolKey() internal returns (PoolKey memory poolKey) {
        if (!issuancePoolKeySynced) {
            poolKey = _syncIssuancePoolKey();
        } else {
            poolKey = issuancePoolKey;
        }
    }

    function _syncIssuancePoolKey() internal returns (PoolKey memory poolKey) {
        (address initializer,) = _getModuleAddresses();

        (uint8 status, PoolKey memory resolvedPoolKey) = _readInitializerPoolState(initializer);
        require(status != 0, IssuancePoolUnavailable());
        require(resolvedPoolKey.tickSpacing != 0, IssuancePoolUnavailable());
        require(!_isInitializerExited(status), IssuancePoolExited());

        poolKey = resolvedPoolKey;
        issuancePoolKey = poolKey;
        issuancePoolKeySynced = true;
        assetIsToken0 = Currency.unwrap(poolKey.currency0) == asset;
    }

    function _getModuleAddresses() internal view returns (address initializer, address liquidityMigrator) {
        (,,, ILiquidityMigrator migrator, IPoolInitializer poolInitializer,,,,,) = airlock.getAssetData(asset);
        return (address(poolInitializer), address(migrator));
    }

    function _processInstructions(uint256 minAmountOut, uint160 sqrtPriceLimitX96, bytes memory hookData) internal {
        if (!hasQueuedInstructions) return;

        uint256 periodId = nextProcessPeriodId;
        uint256 instructionId = nextProcessInstructionId;

        while (periodId <= lastQueuedPeriodId) {
            Instruction[] storage periodInstructions = _instructions[periodId];
            if (instructionId >= periodInstructions.length) {
                periodId++;
                instructionId = 0;
                continue;
            }

            uint256 unlockTimestamp = periodUnlockTimestamp(periodId);
            if (!VestingInstructionLibrary.isUnlocked(unlockTimestamp, block.timestamp)) break;

            bool permissionlessExecution =
                VestingInstructionLibrary.isPermissionless(unlockTimestamp, uint256(graceDuration), block.timestamp);
            if (
                !permissionlessExecution
                    && !VestingInstructionLibrary.isAuthorizedDuringGrace(
                        msg.sender, owner(), governanceExecutor
                    )
            ) {
                break;
            }

            Instruction storage instruction = periodInstructions[instructionId];
            _processInstructionAtCursor(
                periodId,
                instructionId,
                instruction,
                permissionlessExecution,
                minAmountOut,
                sqrtPriceLimitX96,
                hookData
            );

            instructionId++;
        }

        nextProcessPeriodId = periodId;
        nextProcessInstructionId = instructionId;
        emit ProcessInstructions(msg.sender, periodId, instructionId);
    }

    function _processInstructionAtCursor(
        uint256 periodId,
        uint256 instructionId,
        Instruction storage instruction,
        bool permissionlessExecution,
        uint256 minAmountOut,
        uint160 sqrtPriceLimitX96,
        bytes memory hookData
    ) internal {
        if (!instruction.isProcessable()) return;

        if (instruction.instructionType == InstructionType.SellAssetToPool) {
            _executeSellInstruction(
                periodId, instructionId, instruction, permissionlessExecution, minAmountOut, sqrtPriceLimitX96, hookData
            );
            return;
        }

        if (instruction.instructionType == InstructionType.TransferToBeneficiary) {
            _executeTransferInstruction(periodId, instructionId, instruction, permissionlessExecution);
            return;
        }

        revert InvalidInstructionType();
    }

    function _executeSellInstruction(
        uint256 periodId,
        uint256 instructionId,
        Instruction storage instruction,
        bool permissionlessExecution,
        uint256 minAmountOut,
        uint160 sqrtPriceLimitX96,
        bytes memory hookData
    ) internal returns (uint256 amountOut) {
        PoolKey memory poolKey = _getOrSyncIssuancePoolKey();
        bool zeroForOne = assetIsToken0;

        uint256 amountIn;
        (amountIn, amountOut) = instruction.executeSellInstruction(
            queuedAmountByToken, poolManager, poolKey, zeroForOne, minAmountOut, sqrtPriceLimitX96, hookData
        );
        emit ExecuteSellInstruction(periodId, instructionId, amountIn, amountOut, permissionlessExecution);
    }

    function _executeTransferInstruction(
        uint256 periodId,
        uint256 instructionId,
        Instruction storage instruction,
        bool permissionlessExecution
    ) internal returns (uint256 transferred) {
        address transferToken;
        (transferred, transferToken) = instruction.executeTransferInstruction(queuedAmountByToken, beneficiary);
        emit ExecuteTransferInstruction(periodId, instructionId, transferToken, transferred, permissionlessExecution);
    }

    function _reserveInstructionAmount(address token, uint256 amount) internal {
        uint256 available = _availableInstructionAmount(token);
        require(amount <= available, InstructionAmountUnavailable(token, amount, available));
        queuedAmountByToken[token] += amount;
    }

    function _availableInstructionAmount(address token) internal view returns (uint256) {
        uint256 balance = _currentTokenBalance(token);
        uint256 queued = queuedAmountByToken[token];
        if (balance <= queued) return 0;
        return balance - queued;
    }

    function _currentTokenBalance(address token) internal view returns (uint256) {
        if (token == address(0)) return address(this).balance;
        return SafeTransferLib.balanceOf(token, address(this));
    }

    function _resolveFeeCollectionTarget(
        address initializer,
        address liquidityMigrator
    ) internal view returns (FeeCollectionTarget target, PoolId poolId, address collectTarget) {
        (uint8 initializerStatus, PoolKey memory initializerPoolKey) = _readInitializerPoolState(initializer);

        if (initializerStatus == STATUS_LOCKED) {
            return (FeeCollectionTarget.Initializer, initializerPoolKey.toId(), initializer);
        }

        (uint8 migratorStatus, PoolKey memory migratorPoolKey, address lockerAddress) =
            _readMigratorPoolState(liquidityMigrator, initializerPoolKey);

        if (migratorStatus != 0 && migratorPoolKey.tickSpacing != 0 && lockerAddress != address(0)) {
            return (FeeCollectionTarget.Locker, migratorPoolKey.toId(), lockerAddress);
        }

        return (FeeCollectionTarget.None, PoolId.wrap(bytes32(0)), address(0));
    }

    function _readInitializerPoolState(address initializer)
        internal
        view
        returns (uint8 status, PoolKey memory poolKey)
    {
        if (initializerKind == InitializerKind.DopplerHook) {
            return IVestingInitializerReader(initializer).getVestingInitializerState(asset);
        }

        (, status, poolKey,) = IUniswapV4MulticurveInitializerReader(initializer).getState(asset);
        return (status, poolKey);
    }

    function _isInitializerExited(uint8 status) internal view returns (bool) {
        if (initializerKind == InitializerKind.DopplerHook) return status == DOPPLER_HOOK_STATUS_EXITED;
        return status == MULTICURVE_STATUS_EXITED;
    }

    function _readMigratorPoolState(
        address liquidityMigrator,
        PoolKey memory initializerPoolKey
    ) internal view returns (uint8 status, PoolKey memory poolKey, address lockerAddress) {
        return IVestingMigratorReader(liquidityMigrator).getVestingMigratorState(asset, initializerPoolKey);
    }
}
