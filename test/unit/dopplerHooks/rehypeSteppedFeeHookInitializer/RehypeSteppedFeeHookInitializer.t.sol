// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.26;

import { IHooks } from "@v4-core/interfaces/IHooks.sol";
import { IPoolManager } from "@v4-core/interfaces/IPoolManager.sol";
import { TestERC20 } from "@v4-core/test/TestERC20.sol";
import { toBalanceDelta } from "@v4-core/types/BalanceDelta.sol";
import { Currency } from "@v4-core/types/Currency.sol";
import { PoolId } from "@v4-core/types/PoolId.sol";
import { PoolKey } from "@v4-core/types/PoolKey.sol";
import { Test } from "forge-std/Test.sol";
import {
    EmptyFeeSegments,
    FeeScheduleTimeOverflow,
    FeeSegment,
    InvalidFeeSegment,
    RehypeSteppedFeeHookInitializer,
    SteppedFeeInitData,
    TimestampTooLarge
} from "src/dopplerHooks/RehypeSteppedFeeHookInitializer.sol";
import {
    FeeDistributionInfo,
    FeeRoutingMode,
    FeeScheduleSet,
    FeeTooHigh,
    FeeUpdated,
    InsufficientFeeCurrency,
    MAX_SWAP_FEE
} from "src/types/RehypeTypes.sol";
import { WAD } from "src/types/Wad.sol";

contract SteppedFeeMockPoolManager {
    uint160 internal constant MOCK_SQRT_PRICE_X96 = uint160(1 << 96);

    function extsload(bytes32) external pure returns (bytes32 value) {
        return bytes32(uint256(MOCK_SQRT_PRICE_X96));
    }
}

contract SteppedFeeTrackingPoolManager {
    Currency public lastTakeCurrency;
    address public lastTakeRecipient;
    uint256 public lastTakeAmount;
    uint256 public takeCallCount;
    uint160 internal constant MOCK_SQRT_PRICE_X96 = uint160(1 << 96);

    function take(Currency currency, address to, uint256 amount) external {
        lastTakeCurrency = currency;
        lastTakeRecipient = to;
        lastTakeAmount = amount;
        ++takeCallCount;
    }

    function extsload(bytes32) external pure returns (bytes32 value) {
        return bytes32(uint256(MOCK_SQRT_PRICE_X96));
    }
}

contract RehypeSteppedFeeHookHarness is RehypeSteppedFeeHookInitializer {
    constructor(
        address initializer,
        IPoolManager poolManager_
    ) RehypeSteppedFeeHookInitializer(initializer, poolManager_) { }

    function exposed_getCurrentFee(PoolId poolId) external returns (uint24) {
        return _getCurrentFee(poolId);
    }
}

contract RehypeSteppedFeeHookInitializerTest is Test {
    RehypeSteppedFeeHookInitializer internal hook;
    RehypeSteppedFeeHookHarness internal harness;
    RehypeSteppedFeeHookHarness internal trackingHarness;
    SteppedFeeTrackingPoolManager internal trackingPoolManager;
    TestERC20 internal token0;
    TestERC20 internal token1;
    address internal initializer = makeAddr("initializer");

    function setUp() public {
        hook = new RehypeSteppedFeeHookInitializer(initializer, IPoolManager(address(new SteppedFeeMockPoolManager())));
        harness = new RehypeSteppedFeeHookHarness(initializer, IPoolManager(address(new SteppedFeeMockPoolManager())));
        trackingPoolManager = new SteppedFeeTrackingPoolManager();
        trackingHarness = new RehypeSteppedFeeHookHarness(initializer, IPoolManager(address(trackingPoolManager)));
        token0 = new TestERC20(type(uint128).max);
        token1 = new TestERC20(type(uint128).max);
        token0.mint(address(trackingPoolManager), type(uint128).max);
        token1.mint(address(trackingPoolManager), type(uint128).max);
    }

    function test_onInitialization_StoresScheduleAndCheckpoints() public {
        PoolKey memory poolKey = _poolKey(address(token0), address(token1));
        FeeSegment[] memory segments = _segments(3000, 3600);
        uint32 expectedStartTime = uint32(block.timestamp);
        uint32 expectedEndTime = expectedStartTime + 3600;

        vm.expectEmit(true, false, false, true);
        emit FeeScheduleSet(poolKey.toId(), expectedStartTime, 10_000, 3000, 3600);

        vm.prank(initializer);
        hook.onInitialization(address(token0), poolKey, abi.encode(_initData(address(token1), 10_000, segments)));

        (
            uint32 startTime,
            uint32 nextTime,
            uint32 nextIndex,
            uint32 checkpointCount,
            uint24 startFee,
            uint24 currentFee,
            uint24 endFee
        ) = hook.getFeeSchedule(poolKey.toId());
        assertEq(startTime, expectedStartTime);
        assertEq(nextTime, expectedEndTime);
        assertEq(nextIndex, 0);
        assertEq(checkpointCount, 1);
        assertEq(startFee, 10_000);
        assertEq(currentFee, 10_000);
        assertEq(endFee, 3000);

        (uint24 targetFee, uint32 endTime) = hook.getFeeCheckpoints(poolKey.toId(), 0);
        assertEq(targetFee, 3000);
        assertEq(endTime, expectedEndTime);
    }

    function test_onInitialization_RevertsWhenSegmentsEmpty() public {
        PoolKey memory poolKey = _poolKey(address(token0), address(token1));
        FeeSegment[] memory segments = new FeeSegment[](0);

        vm.expectRevert(EmptyFeeSegments.selector);
        vm.prank(initializer);
        hook.onInitialization(address(token0), poolKey, abi.encode(_initData(address(token1), 10_000, segments)));
    }

    function test_onInitialization_RevertsWhenTargetFeeTooHigh() public {
        PoolKey memory poolKey = _poolKey(address(token0), address(token1));
        FeeSegment[] memory segments = _segments(uint24(MAX_SWAP_FEE) + 1, 1);

        vm.expectRevert(abi.encodeWithSelector(FeeTooHigh.selector, uint24(MAX_SWAP_FEE) + 1));
        vm.prank(initializer);
        hook.onInitialization(address(token0), poolKey, abi.encode(_initData(address(token1), 10_000, segments)));
    }

    function test_onInitialization_RevertsWhenSegmentIncreasesFee() public {
        PoolKey memory poolKey = _poolKey(address(token0), address(token1));
        FeeSegment[] memory segments = _segments(10_001, 3600);

        vm.expectRevert(abi.encodeWithSelector(InvalidFeeSegment.selector, 0, uint24(10_000), uint24(10_001)));
        vm.prank(initializer);
        hook.onInitialization(address(token0), poolKey, abi.encode(_initData(address(token1), 10_000, segments)));
    }

    function test_onInitialization_RevertsWhenCurrentTimestampTooLarge() public {
        PoolKey memory poolKey = _poolKey(address(token0), address(token1));
        FeeSegment[] memory segments = _segments(3000, 3600);
        uint256 timestamp = uint256(type(uint32).max) + 1;

        vm.warp(timestamp);
        vm.expectRevert(abi.encodeWithSelector(TimestampTooLarge.selector, timestamp));
        vm.prank(initializer);
        hook.onInitialization(address(token0), poolKey, abi.encode(_initData(address(token1), 10_000, segments)));
    }

    function test_onInitialization_RevertsWhenCheckpointTimeOverflows() public {
        PoolKey memory poolKey = _poolKey(address(token0), address(token1));
        FeeSegment[] memory segments = _segments(3000, 11);
        uint32 startTime = type(uint32).max - 10;

        vm.expectRevert(abi.encodeWithSelector(FeeScheduleTimeOverflow.selector, startTime, uint256(11)));
        vm.prank(initializer);
        hook.onInitialization(
            address(token0), poolKey, abi.encode(_initDataWithStart(address(token1), 10_000, segments, startTime))
        );
    }

    function test_getCurrentFee_AllZeroDurationDescendingScheduleAppliesAtStart() public {
        PoolKey memory poolKey = _poolKey(address(token0), address(token1));
        FeeSegment[] memory segments = _segments(3000, 0);

        vm.warp(1_000_000);
        vm.prank(initializer);
        harness.onInitialization(address(token0), poolKey, abi.encode(_initData(address(token1), 10_000, segments)));

        assertEq(harness.exposed_getCurrentFee(poolKey.toId()), 3000);
    }

    function test_getCurrentFee_FlatPlateauSegment() public {
        PoolKey memory poolKey = _poolKey(address(token0), address(token1));
        FeeSegment[] memory segments = _segments(5000, 0);

        vm.prank(initializer);
        harness.onInitialization(address(token0), poolKey, abi.encode(_initData(address(token1), 5000, segments)));

        vm.warp(block.timestamp + 10_000);
        assertEq(harness.exposed_getCurrentFee(poolKey.toId()), 5000);
    }

    function test_getCurrentFee_PlateauThenDescendingSegment() public {
        PoolKey memory poolKey = _poolKey(address(token0), address(token1));
        FeeSegment[] memory segments = new FeeSegment[](2);
        segments[0] = FeeSegment({ targetFee: 10_000, durationSeconds: 100 });
        segments[1] = FeeSegment({ targetFee: 2000, durationSeconds: 400 });

        uint256 start = 1_000_000;
        vm.warp(start);
        vm.prank(initializer);
        harness.onInitialization(address(token0), poolKey, abi.encode(_initData(address(token1), 10_000, segments)));

        vm.warp(start + 50);
        assertEq(harness.exposed_getCurrentFee(poolKey.toId()), 10_000);

        vm.warp(start + 300);
        assertEq(harness.exposed_getCurrentFee(poolKey.toId()), 10_000);

        vm.warp(start + 500);
        assertEq(harness.exposed_getCurrentFee(poolKey.toId()), 2000);
    }

    function test_getCurrentFee_ZeroDurationCliffThenStep() public {
        PoolKey memory poolKey = _poolKey(address(token0), address(token1));
        FeeSegment[] memory segments = new FeeSegment[](2);
        segments[0] = FeeSegment({ targetFee: 5000, durationSeconds: 0 });
        segments[1] = FeeSegment({ targetFee: 1000, durationSeconds: 100 });

        uint256 start = 1_000_000;
        vm.warp(start);
        vm.prank(initializer);
        harness.onInitialization(address(token0), poolKey, abi.encode(_initData(address(token1), 10_000, segments)));

        vm.warp(start + 50);
        assertEq(harness.exposed_getCurrentFee(poolKey.toId()), 5000);

        vm.warp(start + 100);
        assertEq(harness.exposed_getCurrentFee(poolKey.toId()), 1000);
    }

    function test_getCurrentFee_TwoSegmentSteps() public {
        PoolKey memory poolKey = _poolKey(address(token0), address(token1));
        FeeSegment[] memory segments = new FeeSegment[](2);
        segments[0] = FeeSegment({ targetFee: 6000, durationSeconds: 100 });
        segments[1] = FeeSegment({ targetFee: 2000, durationSeconds: 100 });

        uint256 start = 1_000_000;
        vm.warp(start);
        vm.prank(initializer);
        harness.onInitialization(address(token0), poolKey, abi.encode(_initData(address(token1), 10_000, segments)));

        vm.warp(start + 50);
        assertEq(harness.exposed_getCurrentFee(poolKey.toId()), 10_000);

        vm.warp(start + 100);
        assertEq(harness.exposed_getCurrentFee(poolKey.toId()), 6000);

        vm.warp(start + 150);
        assertEq(harness.exposed_getCurrentFee(poolKey.toId()), 6000);

        vm.warp(start + 200);
        assertEq(harness.exposed_getCurrentFee(poolKey.toId()), 2000);
    }

    function test_getCurrentFee_BoundaryTimestamps() public {
        PoolKey memory poolKey = _poolKey(address(token0), address(token1));
        FeeSegment[] memory segments = new FeeSegment[](2);
        segments[0] = FeeSegment({ targetFee: 6000, durationSeconds: 100 });
        segments[1] = FeeSegment({ targetFee: 2000, durationSeconds: 100 });

        vm.warp(1_000_000);
        vm.prank(initializer);
        harness.onInitialization(
            address(token0), poolKey, abi.encode(_initDataWithStart(address(token1), 10_000, segments, 1_000_100))
        );

        vm.warp(1_000_050);
        assertEq(harness.exposed_getCurrentFee(poolKey.toId()), 10_000);

        vm.warp(1_000_100);
        assertEq(harness.exposed_getCurrentFee(poolKey.toId()), 10_000);

        vm.warp(1_000_200);
        assertEq(harness.exposed_getCurrentFee(poolKey.toId()), 6000);

        vm.warp(1_000_300);
        assertEq(harness.exposed_getCurrentFee(poolKey.toId()), 2000);

        vm.warp(1_000_400);
        assertEq(harness.exposed_getCurrentFee(poolKey.toId()), 2000);
    }

    function test_getCurrentFee_StateAdvancesThroughExpiredCheckpoints() public {
        PoolKey memory poolKey = _poolKey(address(token0), address(token1));
        FeeSegment[] memory segments = new FeeSegment[](3);
        segments[0] = FeeSegment({ targetFee: 8000, durationSeconds: 100 });
        segments[1] = FeeSegment({ targetFee: 6000, durationSeconds: 100 });
        segments[2] = FeeSegment({ targetFee: 2000, durationSeconds: 100 });

        uint256 start = 1_000_000;
        vm.warp(start);
        vm.prank(initializer);
        harness.onInitialization(address(token0), poolKey, abi.encode(_initData(address(token1), 10_000, segments)));

        PoolId poolId = poolKey.toId();
        vm.warp(start + 250);
        assertEq(harness.exposed_getCurrentFee(poolId), 6000);

        (, uint32 nextTime, uint32 nextIndex,,, uint24 currentFee,) = harness.getFeeSchedule(poolId);
        assertEq(nextTime, 1_000_300);
        assertEq(nextIndex, 2);
        assertEq(currentFee, 6000);

        vm.warp(start + 300);
        assertEq(harness.exposed_getCurrentFee(poolId), 2000);

        (, nextTime, nextIndex,,, currentFee,) = harness.getFeeSchedule(poolId);
        assertEq(nextTime, 0);
        assertEq(nextIndex, 3);
        assertEq(currentFee, 2000);
    }

    function test_getCurrentFee_EmitsFeeUpdatedOnlyWhenFeeDecreases() public {
        PoolKey memory poolKey = _poolKey(address(token0), address(token1));
        FeeSegment[] memory segments = _segments(2000, 4000);

        uint256 start = 1_000_000;
        vm.warp(start);
        vm.prank(initializer);
        harness.onInitialization(address(token0), poolKey, abi.encode(_initData(address(token1), 10_000, segments)));

        PoolId poolId = poolKey.toId();
        vm.warp(start + 2000);
        assertEq(harness.exposed_getCurrentFee(poolId), 10_000);

        vm.warp(start + 4000);

        vm.expectEmit(true, false, false, true);
        emit FeeUpdated(poolId, 2000);
        harness.exposed_getCurrentFee(poolId);

        (,,,,, uint24 currentFeeBefore,) = harness.getFeeSchedule(poolId);
        harness.exposed_getCurrentFee(poolId);
        (,,,,, uint24 currentFeeAfter,) = harness.getFeeSchedule(poolId);
        assertEq(currentFeeBefore, currentFeeAfter);
    }

    function test_onSwap_UsesSteppedFee() public {
        PoolKey memory poolKey = _poolKey(address(token0), address(token1));
        FeeSegment[] memory segments = _segments(6000, 2000);

        uint256 start = 1_000_000;
        vm.warp(start);
        vm.prank(initializer);
        trackingHarness.onInitialization(
            address(token0), poolKey, abi.encode(_beneficiaryOnlyInitData(address(token1), 10_000, segments))
        );

        vm.warp(start + 2000);

        IPoolManager.SwapParams memory swapParams =
            IPoolManager.SwapParams({ zeroForOne: true, amountSpecified: -1 ether, sqrtPriceLimitX96: 0 });
        uint256 expectedFeeAmount = 5 ether * 6000 / MAX_SWAP_FEE;

        vm.prank(initializer);
        (Currency feeCurrency, int128 hookDelta) = trackingHarness.onSwap(
            address(0x1234),
            poolKey,
            swapParams,
            toBalanceDelta(-int128(uint128(1 ether)), int128(uint128(5 ether))),
            ""
        );

        assertEq(Currency.unwrap(feeCurrency), address(token1));
        assertEq(uint256(uint128(hookDelta)), expectedFeeAmount);
        assertEq(trackingPoolManager.takeCallCount(), 1);
        assertEq(trackingPoolManager.lastTakeAmount(), expectedFeeAmount);

        (,,,,, uint24 currentFee,) = trackingHarness.getFeeSchedule(poolKey.toId());
        assertEq(currentFee, 6000);
    }

    function test_onSwap_RevertsWhenPoolManagerFeeCurrencyBalanceInsufficient() public {
        PoolKey memory poolKey =
            _poolKey(address(new TestERC20(type(uint128).max)), address(new TestERC20(type(uint128).max)));
        FeeSegment[] memory segments = _segments(10_000, 0);

        vm.prank(initializer);
        hook.onInitialization(
            Currency.unwrap(poolKey.currency0),
            poolKey,
            abi.encode(_beneficiaryOnlyInitData(Currency.unwrap(poolKey.currency1), 10_000, segments))
        );

        IPoolManager.SwapParams memory swapParams =
            IPoolManager.SwapParams({ zeroForOne: true, amountSpecified: -1 ether, sqrtPriceLimitX96: 0 });

        vm.expectRevert(InsufficientFeeCurrency.selector);
        vm.prank(initializer);
        hook.onSwap(
            address(0x1234),
            poolKey,
            swapParams,
            toBalanceDelta(-int128(uint128(1 ether)), int128(uint128(5 ether))),
            ""
        );
    }

    function _poolKey(address currency0, address currency1) internal pure returns (PoolKey memory) {
        return PoolKey({
            currency0: Currency.wrap(currency0),
            currency1: Currency.wrap(currency1),
            fee: 0,
            tickSpacing: 60,
            hooks: IHooks(address(0))
        });
    }

    function _segments(uint24 targetFee, uint32 durationSeconds) internal pure returns (FeeSegment[] memory segments) {
        segments = new FeeSegment[](1);
        segments[0] = FeeSegment({ targetFee: targetFee, durationSeconds: durationSeconds });
    }

    function _initData(
        address numeraire,
        uint24 startFee,
        FeeSegment[] memory segments
    ) internal pure returns (SteppedFeeInitData memory) {
        return SteppedFeeInitData({
            numeraire: numeraire,
            buybackDst: address(0),
            startFee: startFee,
            feeSegments: segments,
            startingTime: 0,
            feeRoutingMode: FeeRoutingMode.DirectBuyback,
            feeDistributionInfo: _quarterDistribution()
        });
    }

    function _initDataWithStart(
        address numeraire,
        uint24 startFee,
        FeeSegment[] memory segments,
        uint32 startingTime
    ) internal pure returns (SteppedFeeInitData memory) {
        SteppedFeeInitData memory initData = _initData(numeraire, startFee, segments);
        initData.startingTime = startingTime;
        return initData;
    }

    function _beneficiaryOnlyInitData(
        address numeraire,
        uint24 startFee,
        FeeSegment[] memory segments
    ) internal pure returns (SteppedFeeInitData memory) {
        return SteppedFeeInitData({
            numeraire: numeraire,
            buybackDst: address(0),
            startFee: startFee,
            feeSegments: segments,
            startingTime: 0,
            feeRoutingMode: FeeRoutingMode.DirectBuyback,
            feeDistributionInfo: FeeDistributionInfo({
                assetFeesToAssetBuybackWad: 0,
                assetFeesToNumeraireBuybackWad: 0,
                assetFeesToBeneficiaryWad: WAD,
                assetFeesToLpWad: 0,
                numeraireFeesToAssetBuybackWad: 0,
                numeraireFeesToNumeraireBuybackWad: 0,
                numeraireFeesToBeneficiaryWad: WAD,
                numeraireFeesToLpWad: 0
            })
        });
    }

    function _quarterDistribution() internal pure returns (FeeDistributionInfo memory) {
        return FeeDistributionInfo({
            assetFeesToAssetBuybackWad: 0.25e18,
            assetFeesToNumeraireBuybackWad: 0.25e18,
            assetFeesToBeneficiaryWad: 0.25e18,
            assetFeesToLpWad: 0.25e18,
            numeraireFeesToAssetBuybackWad: 0.25e18,
            numeraireFeesToNumeraireBuybackWad: 0.25e18,
            numeraireFeesToBeneficiaryWad: 0.25e18,
            numeraireFeesToLpWad: 0.25e18
        });
    }
}
