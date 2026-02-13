// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.26;

import { IHooks } from "@v4-core/interfaces/IHooks.sol";
import { IPoolManager } from "@v4-core/interfaces/IPoolManager.sol";
import { IUnlockCallback } from "@v4-core/interfaces/callback/IUnlockCallback.sol";
import { TestERC20 } from "@v4-core/test/TestERC20.sol";
import { BalanceDelta, toBalanceDelta } from "@v4-core/types/BalanceDelta.sol";
import { Currency } from "@v4-core/types/Currency.sol";
import { PoolId } from "@v4-core/types/PoolId.sol";
import { PoolKey } from "@v4-core/types/PoolKey.sol";
import { Test } from "forge-std/Test.sol";
import { AssetData } from "src/Airlock.sol";
import {
    InstructionAmountUnavailable,
    InstructionNotFound,
    InvalidInitializerKind,
    IssuancePoolUnavailable,
    NoCollectableFeesPath,
    SenderNotBeneficiary,
    VestingMiddleware
} from "src/governance/VestingMiddleware.sol";
import {
    Instruction,
    InstructionAlreadyExecuted,
    InstructionCancelled,
    InvalidInstructionAmount,
    InstructionPeriodNotInFuture,
    InstructionPeriodOutOfOrder,
    InstructionNotUnlocked,
    InvalidInstructionType,
    InvalidTransferToken,
    InsufficientSwapOutput,
    SenderNotAuthorized
} from "src/libraries/VestingInstructionLibrary.sol";
import { ILiquidityMigrator } from "src/interfaces/ILiquidityMigrator.sol";
import { IPoolInitializer } from "src/interfaces/IPoolInitializer.sol";

contract MockAirlockForVestingMiddleware {
    mapping(address asset => AssetData data) public getAssetData;

    function setAssetData(address asset, AssetData memory data) external {
        getAssetData[asset] = data;
    }
}

contract MockPoolManagerForVestingMiddleware {
    int128 internal _amount0;
    int128 internal _amount1;

    receive() external payable { }

    function setSwapDelta(int128 amount0, int128 amount1) external {
        _amount0 = amount0;
        _amount1 = amount1;
    }

    function unlock(bytes calldata data) external returns (bytes memory) {
        return IUnlockCallback(msg.sender).unlockCallback(data);
    }

    function swap(PoolKey memory, IPoolManager.SwapParams memory, bytes calldata) external view returns (BalanceDelta) {
        return toBalanceDelta(_amount0, _amount1);
    }

    function take(Currency currency, address to, uint256 amount) external {
        address token = Currency.unwrap(currency);
        if (token == address(0)) {
            payable(to).transfer(amount);
        } else {
            TestERC20(token).transfer(to, amount);
        }
    }

    function sync(Currency) external { }

    function settle() external payable returns (uint256 paid) {
        paid = msg.value;
    }

    function settleFor(address) external payable returns (uint256 paid) {
        paid = msg.value;
    }
}

contract MockDopplerHookInitializerForVestingMiddleware {
    uint8 public status;
    PoolKey public poolKey;
    uint128 public fees0;
    uint128 public fees1;

    function setState(uint8 status_, PoolKey memory poolKey_) external {
        status = status_;
        poolKey = poolKey_;
    }

    function setFees(uint128 fees0_, uint128 fees1_) external {
        fees0 = fees0_;
        fees1 = fees1_;
    }

    function getState(address)
        external
        view
        returns (address, uint256, address, bytes memory, uint8, PoolKey memory, int24)
    {
        return (address(0), 0, address(0), bytes(""), status, poolKey, 0);
    }

    function getVestingInitializerState(address) external view returns (uint8, PoolKey memory) {
        return (status, poolKey);
    }

    function collectFees(PoolId) external view returns (uint128, uint128) {
        return (fees0, fees1);
    }

    function isDopplerHookEnabled(address) external pure returns (uint256) {
        return 1;
    }
}

contract MockDecayInitializerForVestingMiddleware {
    uint8 public status;
    PoolKey public poolKey;
    uint128 public fees0;
    uint128 public fees1;

    function setState(uint8 status_, PoolKey memory poolKey_) external {
        status = status_;
        poolKey = poolKey_;
    }

    function setFees(uint128 fees0_, uint128 fees1_) external {
        fees0 = fees0_;
        fees1 = fees1_;
    }

    function getState(address) external view returns (address, uint8, PoolKey memory, int24) {
        return (address(0), status, poolKey, 0);
    }

    function getVestingInitializerState(address) external view returns (uint8, PoolKey memory) {
        return (status, poolKey);
    }

    function collectFees(PoolId) external view returns (uint128, uint128) {
        return (fees0, fees1);
    }
}

contract MockLockerForVestingMiddleware {
    uint128 public fees0;
    uint128 public fees1;

    function setFees(uint128 fees0_, uint128 fees1_) external {
        fees0 = fees0_;
        fees1 = fees1_;
    }

    function collectFees(PoolId) external view returns (uint128, uint128) {
        return (fees0, fees1);
    }
}

contract MockDopplerHookMigratorForVestingMiddleware {
    PoolKey public poolKey;
    uint8 public status;
    address public locker;

    constructor(address locker_) {
        locker = locker_;
    }

    function setState(uint8 status_, PoolKey memory poolKey_) external {
        status = status_;
        poolKey = poolKey_;
    }

    function getMigratorState(address) external view returns (address, PoolKey memory, address, bytes memory, uint8) {
        return (address(0), poolKey, address(0), bytes(""), status);
    }

    function getVestingMigratorState(address, PoolKey calldata) external view returns (uint8, PoolKey memory, address) {
        return (status, poolKey, locker);
    }
}

contract VestingMiddlewareTest is Test {
    uint32 internal constant PERIOD = 15 minutes;
    uint32 internal constant GRACE = 5 minutes;
    uint8 internal constant MULTICURVE_INITIALIZER_KIND = 0;
    uint8 internal constant DOPPLER_HOOK_INITIALIZER_KIND = 1;

    MockAirlockForVestingMiddleware internal mockAirlock;
    MockPoolManagerForVestingMiddleware internal mockPoolManager;
    MockDopplerHookInitializerForVestingMiddleware internal mockDopplerInitializer;
    MockDecayInitializerForVestingMiddleware internal mockDecayInitializer;
    MockLockerForVestingMiddleware internal mockLocker;
    MockDopplerHookMigratorForVestingMiddleware internal mockMigrator;

    TestERC20 internal asset;
    TestERC20 internal numeraire;
    TestERC20 internal foreignToken;

    VestingMiddleware internal middleware;

    address internal owner = makeAddr("owner");
    address internal governanceExecutor = makeAddr("governanceExecutor");
    address internal beneficiary = makeAddr("beneficiary");
    address internal random = makeAddr("random");
    uint64 internal streamStart;

    function setUp() public {
        mockAirlock = new MockAirlockForVestingMiddleware();
        mockPoolManager = new MockPoolManagerForVestingMiddleware();
        mockDopplerInitializer = new MockDopplerHookInitializerForVestingMiddleware();
        mockDecayInitializer = new MockDecayInitializerForVestingMiddleware();
        mockLocker = new MockLockerForVestingMiddleware();
        mockMigrator = new MockDopplerHookMigratorForVestingMiddleware(address(mockLocker));

        asset = new TestERC20(0);
        numeraire = new TestERC20(0);
        foreignToken = new TestERC20(0);

        streamStart = uint64(block.timestamp + PERIOD);

        middleware = new VestingMiddleware(
            address(mockAirlock),
            address(asset),
            address(numeraire),
            IPoolManager(address(mockPoolManager)),
            beneficiary,
            governanceExecutor,
            streamStart,
            PERIOD,
            GRACE,
            DOPPLER_HOOK_INITIALIZER_KIND,
            owner
        );

        _setPoolState(address(mockDopplerInitializer), 1, _buildPoolKey(address(asset), address(numeraire)));
        _setAssetData(address(mockDopplerInitializer), address(mockMigrator));
    }

    function test_queueAndCancelInstruction() public {
        asset.mint(address(middleware), 100e18);

        vm.prank(owner);
        uint256 instructionId = middleware.queueSellInstruction(0, 100e18);
        assertEq(instructionId, 0);

        vm.prank(owner);
        middleware.cancelInstruction(0, instructionId);
        assertTrue(middleware.getInstruction(0, instructionId).cancelled);
        assertEq(middleware.queuedAmountByToken(address(asset)), 0);
    }

    function testFuzz_queueSellInstruction_ReservesAmount(uint96 balance, uint96 amount) public {
        vm.assume(balance > 0);
        vm.assume(amount > 0);
        vm.assume(amount <= balance);

        asset.mint(address(middleware), uint256(balance));

        vm.prank(owner);
        uint256 instructionId = middleware.queueSellInstruction(0, uint256(amount));

        assertEq(middleware.queuedAmountByToken(address(asset)), uint256(amount));
        assertEq(middleware.getInstructionCount(0), 1);

        Instruction memory instruction = middleware.getInstruction(0, instructionId);
        assertEq(uint256(instruction.amount), uint256(amount));
        assertFalse(instruction.executed);
        assertFalse(instruction.cancelled);
    }

    function test_queueInstruction_RevertsWhenPeriodNotFuture() public {
        vm.warp(streamStart);

        vm.expectRevert(
            abi.encodeWithSelector(InstructionPeriodNotInFuture.selector, uint256(0), uint256(streamStart), uint256(streamStart))
        );
        vm.prank(owner);
        middleware.queueSellInstruction(0, 1e18);
    }

    function test_queueInstruction_AllowsMultipleInFuturePeriod() public {
        asset.mint(address(middleware), 10e18);
        foreignToken.mint(address(middleware), 5e18);

        vm.prank(owner);
        uint256 sellInstructionId = middleware.queueSellInstruction(2, 10e18);

        vm.prank(owner);
        uint256 transferInstructionId = middleware.queueTransferTokenInstruction(2, address(foreignToken), 5e18);

        assertEq(sellInstructionId, 0);
        assertEq(transferInstructionId, 1);
        assertEq(middleware.getInstructionCount(2), 2);
    }

    function test_queueInstruction_RevertsWhenPeriodOutOfOrder() public {
        asset.mint(address(middleware), 2e18);

        vm.prank(owner);
        middleware.queueSellInstruction(2, 1e18);

        vm.expectRevert(abi.encodeWithSelector(InstructionPeriodOutOfOrder.selector, uint256(2), uint256(1)));
        vm.prank(owner);
        middleware.queueSellInstruction(1, 1e18);
    }

    function test_queueInstruction_RevertsWhenAmountUnavailable() public {
        asset.mint(address(middleware), 5e18);

        vm.expectRevert(
            abi.encodeWithSelector(InstructionAmountUnavailable.selector, address(asset), uint256(6e18), uint256(5e18))
        );
        vm.prank(owner);
        middleware.queueSellInstruction(1, 6e18);
    }

    function test_queueTransferTokenInstruction_RevertsWhenTokenIsZero() public {
        vm.expectRevert(InvalidTransferToken.selector);
        vm.prank(owner);
        middleware.queueTransferTokenInstruction(1, address(0), 1e18);
    }

    function test_queueInstruction_RevertsWhenAmountIsZero() public {
        asset.mint(address(middleware), 1e18);

        vm.expectRevert(InvalidInstructionAmount.selector);
        vm.prank(owner);
        middleware.queueSellInstruction(1, 0);
    }

    function testFuzz_queueInstruction_RevertsWhenCumulativeAmountUnavailable(
        uint96 balance,
        uint96 firstAmount,
        uint96 extraAmount
    ) public {
        vm.assume(balance > 0);
        vm.assume(firstAmount > 0);
        vm.assume(firstAmount <= balance);
        vm.assume(extraAmount > 0);
        vm.assume(uint256(firstAmount) + uint256(extraAmount) > uint256(balance));

        asset.mint(address(middleware), uint256(balance));

        vm.prank(owner);
        middleware.queueSellInstruction(0, uint256(firstAmount));

        uint256 available = uint256(balance) - uint256(firstAmount);
        vm.expectRevert(
            abi.encodeWithSelector(
                InstructionAmountUnavailable.selector, address(asset), uint256(extraAmount), uint256(available)
            )
        );
        vm.prank(owner);
        middleware.queueSellInstruction(0, uint256(extraAmount));
    }

    function test_executeSellInstruction_TracksExecutionAndReceivesNumeraire() public {
        asset.mint(address(middleware), 50e18);

        vm.prank(owner);
        uint256 instructionId = middleware.queueSellInstruction(0, 50e18);

        numeraire.mint(address(mockPoolManager), 50e18);
        mockPoolManager.setSwapDelta(-int128(50e18), int128(25e18));

        vm.warp(streamStart);
        vm.prank(owner);
        uint256 amountOut = middleware.executeSellInstruction(0, instructionId, 20e18, 0, new bytes(0));
        assertEq(amountOut, 25e18);

        assertEq(asset.balanceOf(address(middleware)), 0, "asset balance should decrease by amountIn");
        assertEq(numeraire.balanceOf(address(middleware)), 25e18, "middleware should receive numeraire from sell");
        assertTrue(middleware.getInstruction(0, instructionId).executed, "instruction should be marked executed");
    }

    function testFuzz_executeSellInstruction_UsesFullQueuedAmount(uint96 amountIn, uint96 amountOut) public {
        vm.assume(amountIn > 0);
        vm.assume(amountOut > 0);

        asset.mint(address(middleware), uint256(amountIn));

        vm.prank(owner);
        uint256 instructionId = middleware.queueSellInstruction(0, uint256(amountIn));

        numeraire.mint(address(mockPoolManager), uint256(amountOut));
        mockPoolManager.setSwapDelta(-int128(uint128(amountIn)), int128(uint128(amountOut)));

        vm.warp(streamStart);
        vm.prank(owner);
        uint256 received = middleware.executeSellInstruction(0, instructionId, uint256(amountOut), 0, new bytes(0));

        assertEq(received, uint256(amountOut));
        assertEq(asset.balanceOf(address(middleware)), 0);
        assertEq(numeraire.balanceOf(address(middleware)), uint256(amountOut));
        assertTrue(middleware.getInstruction(0, instructionId).executed);
    }

    function test_executeTransferTokenInstruction_AllowsSamePeriodAsSell() public {
        asset.mint(address(middleware), 15e18);

        vm.prank(owner);
        uint256 sellId = middleware.queueSellInstruction(0, 10e18);

        vm.prank(owner);
        uint256 transferId = middleware.queueTransferTokenInstruction(0, address(asset), 5e18);

        numeraire.mint(address(mockPoolManager), 50e18);
        mockPoolManager.setSwapDelta(-int128(10e18), int128(8e18));

        vm.warp(streamStart);
        vm.prank(owner);
        middleware.executeSellInstruction(0, sellId, 1, 0, new bytes(0));

        vm.prank(owner);
        middleware.executeTransferInstruction(0, transferId);

        assertEq(asset.balanceOf(beneficiary), 5e18, "beneficiary should receive transfer instruction amount");
    }

    function test_executeTransferETHInstruction() public {
        vm.deal(address(middleware), 1 ether);

        vm.prank(owner);
        uint256 instructionId = middleware.queueTransferETHInstruction(0, 1 ether);

        vm.warp(streamStart);
        vm.prank(owner);
        middleware.executeTransferInstruction(0, instructionId);

        assertEq(beneficiary.balance, 1 ether, "beneficiary should receive ETH");
    }

    function test_executeInstruction_RevertsWhenNotUnlocked() public {
        asset.mint(address(middleware), 10e18);

        vm.prank(owner);
        uint256 instructionId = middleware.queueSellInstruction(1, 10e18);

        vm.expectRevert();
        vm.prank(owner);
        middleware.executeSellInstruction(1, instructionId, 0, 0, new bytes(0));
    }

    function test_executeInstruction_RevertsForUnauthorizedSenderDuringGrace() public {
        foreignToken.mint(address(middleware), 1e18);

        vm.prank(owner);
        uint256 instructionId = middleware.queueTransferTokenInstruction(0, address(foreignToken), 1e18);

        vm.warp(streamStart);
        vm.expectRevert(SenderNotAuthorized.selector);
        vm.prank(random);
        middleware.executeTransferInstruction(0, instructionId);
    }

    function test_executeInstruction_PermissionlessAfterGrace() public {
        foreignToken.mint(address(middleware), 1e18);

        vm.prank(owner);
        uint256 instructionId = middleware.queueTransferTokenInstruction(0, address(foreignToken), 1e18);

        vm.warp(uint256(streamStart) + GRACE + 1);
        vm.prank(random);
        middleware.executeTransferInstruction(0, instructionId);

        assertEq(foreignToken.balanceOf(beneficiary), 1e18);
    }

    function test_executeTransferInstruction_RevertsWhenWrongInstructionType() public {
        asset.mint(address(middleware), 10e18);

        vm.prank(owner);
        uint256 instructionId = middleware.queueSellInstruction(0, 10e18);

        vm.warp(streamStart);
        vm.expectRevert(InvalidInstructionType.selector);
        vm.prank(owner);
        middleware.executeTransferInstruction(0, instructionId);
    }

    function test_executeSellInstruction_RevertsWhenAlreadyExecuted() public {
        asset.mint(address(middleware), 10e18);

        vm.prank(owner);
        uint256 instructionId = middleware.queueSellInstruction(0, 10e18);

        numeraire.mint(address(mockPoolManager), 10e18);
        mockPoolManager.setSwapDelta(-int128(10e18), int128(5e18));

        vm.warp(streamStart);
        vm.prank(owner);
        middleware.executeSellInstruction(0, instructionId, 0, 0, new bytes(0));

        vm.expectRevert(InstructionAlreadyExecuted.selector);
        vm.prank(owner);
        middleware.executeSellInstruction(0, instructionId, 0, 0, new bytes(0));
    }

    function test_executeSellInstruction_RevertsWhenCancelled() public {
        asset.mint(address(middleware), 10e18);

        vm.prank(owner);
        uint256 instructionId = middleware.queueSellInstruction(0, 10e18);

        vm.prank(owner);
        middleware.cancelInstruction(0, instructionId);

        vm.warp(streamStart);
        vm.expectRevert(InstructionCancelled.selector);
        vm.prank(owner);
        middleware.executeSellInstruction(0, instructionId, 0, 0, new bytes(0));
    }

    function test_executeSellInstruction_RevertsWhenInsufficientSwapOutput() public {
        asset.mint(address(middleware), 10e18);

        vm.prank(owner);
        uint256 instructionId = middleware.queueSellInstruction(0, 10e18);

        numeraire.mint(address(mockPoolManager), 10e18);
        mockPoolManager.setSwapDelta(-int128(10e18), int128(2e18));

        vm.warp(streamStart);
        vm.expectRevert(abi.encodeWithSelector(InsufficientSwapOutput.selector, uint256(2e18), uint256(3e18)));
        vm.prank(owner);
        middleware.executeSellInstruction(0, instructionId, 3e18, 0, new bytes(0));
    }

    function test_collectFees_RoutesToDopplerInitializerWhenLocked() public {
        mockDopplerInitializer.setFees(111, 222);
        _setPoolState(address(mockDopplerInitializer), 2, _buildPoolKey(address(asset), address(numeraire)));
        _setAssetData(address(mockDopplerInitializer), address(mockMigrator));

        (uint128 fees0, uint128 fees1) = middleware.collectFees();
        assertEq(fees0, 111);
        assertEq(fees1, 222);
    }

    function test_collectFees_RoutesToDecayInitializerWhenLocked() public {
        VestingMiddleware decayMiddleware = new VestingMiddleware(
            address(mockAirlock),
            address(asset),
            address(numeraire),
            IPoolManager(address(mockPoolManager)),
            beneficiary,
            governanceExecutor,
            streamStart,
            PERIOD,
            GRACE,
            MULTICURVE_INITIALIZER_KIND,
            owner
        );

        mockDecayInitializer.setFees(333, 444);
        _setPoolStateDecay(address(mockDecayInitializer), 2, _buildPoolKey(address(asset), address(numeraire)));
        _setAssetDataFor(address(decayMiddleware), address(mockDecayInitializer), address(mockMigrator));

        (uint128 fees0, uint128 fees1) = decayMiddleware.collectFees();
        assertEq(fees0, 333);
        assertEq(fees1, 444);
    }

    function test_collectFees_RoutesToLockerWhenInitializerNotCollectable() public {
        _setPoolState(address(mockDopplerInitializer), 4, _buildPoolKey(address(asset), address(numeraire)));
        _setAssetData(address(mockDopplerInitializer), address(mockMigrator));

        mockLocker.setFees(999, 888);
        mockMigrator.setState(1, _buildPoolKey(address(asset), address(numeraire)));

        (uint128 fees0, uint128 fees1) = middleware.collectFees();
        assertEq(fees0, 999);
        assertEq(fees1, 888);
    }

    function test_collectFees_RevertsWhenNoCollectablePath() public {
        _setPoolState(address(mockDopplerInitializer), 1, _buildPoolKey(address(asset), address(numeraire)));
        _setAssetData(address(mockDopplerInitializer), address(mockMigrator));
        mockMigrator.setState(0, _buildPoolKey(address(asset), address(numeraire)));

        vm.expectRevert(NoCollectableFeesPath.selector);
        middleware.collectFees();
    }

    function test_withdrawNumeraire_AllowsBeneficiaryAnytime() public {
        numeraire.mint(address(middleware), 77e18);

        vm.prank(beneficiary);
        middleware.withdrawNumeraire(55e18);

        assertEq(numeraire.balanceOf(beneficiary), 55e18);

        vm.prank(beneficiary);
        uint256 withdrawn = middleware.withdrawAllNumeraire();
        assertEq(withdrawn, 22e18);
        assertEq(numeraire.balanceOf(beneficiary), 77e18);
    }

    function test_withdrawNumeraire_RevertsWhenCallerNotBeneficiary() public {
        vm.expectRevert(SenderNotBeneficiary.selector);
        vm.prank(random);
        middleware.withdrawNumeraire(1);
    }

    function test_executeInstruction_RevertsWhenAlreadyExecuted() public {
        foreignToken.mint(address(middleware), 5e18);

        vm.prank(owner);
        uint256 instructionId = middleware.queueTransferTokenInstruction(0, address(foreignToken), 5e18);

        vm.warp(uint256(streamStart) + GRACE + 1);
        vm.prank(random);
        middleware.executeTransferInstruction(0, instructionId);

        vm.expectRevert(InstructionAlreadyExecuted.selector);
        vm.prank(random);
        middleware.executeTransferInstruction(0, instructionId);
    }

    function testFuzz_executeTransferInstruction_TransfersOnce(uint96 amount, bool executePermissionlessly) public {
        vm.assume(amount > 0);

        foreignToken.mint(address(middleware), uint256(amount));

        vm.prank(owner);
        uint256 instructionId = middleware.queueTransferTokenInstruction(0, address(foreignToken), uint256(amount));

        if (executePermissionlessly) {
            vm.warp(uint256(streamStart) + GRACE + 1);
            vm.prank(random);
            middleware.executeTransferInstruction(0, instructionId);
        } else {
            vm.warp(streamStart);
            vm.prank(owner);
            middleware.executeTransferInstruction(0, instructionId);
        }

        assertEq(foreignToken.balanceOf(beneficiary), uint256(amount));

        vm.expectRevert(InstructionAlreadyExecuted.selector);
        vm.prank(owner);
        middleware.executeTransferInstruction(0, instructionId);
    }

    function test_processInstructions_WalksBookInOrder() public {
        asset.mint(address(middleware), 10e18);
        foreignToken.mint(address(middleware), 4e18);
        vm.deal(address(middleware), 1 ether);

        vm.prank(owner);
        middleware.queueSellInstruction(0, 10e18);
        vm.prank(owner);
        middleware.queueTransferTokenInstruction(0, address(foreignToken), 4e18);
        vm.prank(owner);
        middleware.queueTransferETHInstruction(1, 1 ether);

        numeraire.mint(address(mockPoolManager), 20e18);
        mockPoolManager.setSwapDelta(-int128(10e18), int128(6e18));

        vm.warp(uint256(streamStart) + GRACE + 1);
        middleware.processInstructions();
        assertEq(middleware.nextProcessPeriodId(), 1);
        assertEq(middleware.nextProcessInstructionId(), 0);
        assertEq(numeraire.balanceOf(address(middleware)), 6e18);
        assertEq(foreignToken.balanceOf(beneficiary), 4e18);

        vm.warp(uint256(streamStart) + PERIOD + GRACE + 1);
        middleware.processInstructions();
        assertEq(beneficiary.balance, 1 ether);
    }

    function test_setInitializerKind_UpdatesAndResetsIssuanceCache() public {
        assertEq(uint8(middleware.initializerKind()), DOPPLER_HOOK_INITIALIZER_KIND);
        assertFalse(middleware.issuancePoolKeySynced());

        middleware.syncIssuancePoolKey();
        assertTrue(middleware.issuancePoolKeySynced());

        vm.prank(owner);
        middleware.setInitializerKind(MULTICURVE_INITIALIZER_KIND);

        assertEq(uint8(middleware.initializerKind()), MULTICURVE_INITIALIZER_KIND);
        assertFalse(middleware.issuancePoolKeySynced());
    }

    function test_syncIssuancePoolKey_RevertsWhenInitializerUnavailable() public {
        _setPoolState(address(mockDopplerInitializer), 0, _buildPoolKey(address(asset), address(numeraire)));
        vm.expectRevert(IssuancePoolUnavailable.selector);
        middleware.syncIssuancePoolKey();
    }

    function test_cancelInstruction_RevertsWhenInstructionAlreadyExecuted() public {
        foreignToken.mint(address(middleware), 1e18);

        vm.prank(owner);
        uint256 instructionId = middleware.queueTransferTokenInstruction(0, address(foreignToken), 1e18);

        vm.warp(streamStart);
        vm.prank(owner);
        middleware.executeTransferInstruction(0, instructionId);

        vm.expectRevert(InstructionAlreadyExecuted.selector);
        vm.prank(owner);
        middleware.cancelInstruction(0, instructionId);
    }

    function test_cancelInstruction_RevertsWhenInstructionNotFound() public {
        vm.expectRevert(abi.encodeWithSelector(InstructionNotFound.selector, uint256(0), uint256(99)));
        vm.prank(owner);
        middleware.cancelInstruction(0, 99);
    }

    function test_setInitializerKind_RevertsWhenCallerNotOwner() public {
        vm.expectRevert();
        vm.prank(random);
        middleware.setInitializerKind(MULTICURVE_INITIALIZER_KIND);
    }

    function test_setInitializerKind_RevertsWhenKindInvalid() public {
        vm.expectRevert(abi.encodeWithSelector(InvalidInitializerKind.selector, uint8(2)));
        vm.prank(owner);
        middleware.setInitializerKind(2);
    }

    function _setAssetData(address initializer, address migrator) internal {
        _setAssetDataFor(address(middleware), initializer, migrator);
    }

    function _setAssetDataFor(address timelock, address initializer, address migrator) internal {
        AssetData memory data = AssetData({
            numeraire: address(numeraire),
            timelock: timelock,
            governance: address(0xdead),
            liquidityMigrator: ILiquidityMigrator(migrator),
            poolInitializer: IPoolInitializer(initializer),
            pool: address(0),
            migrationPool: address(0),
            numTokensToSell: 0,
            totalSupply: 0,
            integrator: address(0)
        });
        mockAirlock.setAssetData(address(asset), data);
    }

    function _setPoolState(address initializer, uint8 status, PoolKey memory poolKey) internal {
        MockDopplerHookInitializerForVestingMiddleware(initializer).setState(status, poolKey);
    }

    function _setPoolStateDecay(address initializer, uint8 status, PoolKey memory poolKey) internal {
        MockDecayInitializerForVestingMiddleware(initializer).setState(status, poolKey);
    }

    function _buildPoolKey(address token0, address token1) internal pure returns (PoolKey memory) {
        return PoolKey({
            currency0: Currency.wrap(token0),
            currency1: Currency.wrap(token1),
            hooks: IHooks(address(0)),
            fee: 3000,
            tickSpacing: 60
        });
    }
}
