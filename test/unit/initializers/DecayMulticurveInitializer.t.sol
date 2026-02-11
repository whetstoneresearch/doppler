// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.26;

import { ERC20 } from "@solmate/tokens/ERC20.sol";
import { Deployers } from "@uniswap/v4-core/test/utils/Deployers.sol";
import { IHooks } from "@v4-core/interfaces/IHooks.sol";
import { IPoolManager } from "@v4-core/interfaces/IPoolManager.sol";
import { Hooks } from "@v4-core/libraries/Hooks.sol";
import { LPFeeLibrary } from "@v4-core/libraries/LPFeeLibrary.sol";
import { StateLibrary } from "@v4-core/libraries/StateLibrary.sol";
import { TickMath } from "@v4-core/libraries/TickMath.sol";
import { PoolSwapTest } from "@v4-core/test/PoolSwapTest.sol";
import { Currency } from "@v4-core/types/Currency.sol";
import { PoolId } from "@v4-core/types/PoolId.sol";
import { PoolKey } from "@v4-core/types/PoolKey.sol";

import { Airlock } from "src/Airlock.sol";
import { SenderNotAirlock } from "src/base/ImmutableAirlock.sol";
import {
    DecayMulticurveInitializer,
    FeeTooHigh,
    InitData,
    InvalidDurationSeconds,
    InvalidFeeRange,
    MAX_LP_FEE
} from "src/initializers/DecayMulticurveInitializer.sol";
import { DecayMulticurveInitializerHook } from "src/initializers/DecayMulticurveInitializerHook.sol";
import {
    CannotMigrateInsufficientTick,
    Lock,
    PoolAlreadyExited,
    PoolAlreadyInitialized,
    PoolNotLocked,
    PoolStatus
} from "src/initializers/UniswapV4MulticurveInitializer.sol";
import { IPoolInitializer } from "src/interfaces/IPoolInitializer.sol";
import { Curve, ZeroPosition } from "src/libraries/Multicurve.sol";
import { BeneficiaryData } from "src/types/BeneficiaryData.sol";
import { Position } from "src/types/Position.sol";
import { WAD } from "src/types/Wad.sol";

contract DecayMulticurveInitializerTest is Deployers {
    using StateLibrary for IPoolManager;

    DecayMulticurveInitializer public initializer;
    DecayMulticurveInitializerHook public hook;
    address public airlockOwner = makeAddr("AirlockOwner");
    Airlock public airlock;

    uint256 internal totalTokensOnBondingCurve = 1e27;
    PoolKey internal poolKey;
    PoolId internal poolId;
    address internal asset;
    address internal numeraire;

    function setUp() public {
        deployFreshManagerAndRouters();
        (currency0, currency1) = deployAndMint2Currencies();
        airlock = new Airlock(airlockOwner);

        hook = DecayMulticurveInitializerHook(
            address(
                uint160(
                    Hooks.BEFORE_INITIALIZE_FLAG | Hooks.BEFORE_ADD_LIQUIDITY_FLAG | Hooks.AFTER_ADD_LIQUIDITY_FLAG
                        | Hooks.AFTER_REMOVE_LIQUIDITY_FLAG | Hooks.BEFORE_SWAP_FLAG | Hooks.AFTER_SWAP_FLAG
                ) ^ (0x4444 << 144)
            )
        );
        initializer = new DecayMulticurveInitializer(address(airlock), manager, hook);
        deployCodeTo("DecayMulticurveInitializerHook", abi.encode(manager, initializer), address(hook));
    }

    modifier prepareAsset(bool isToken0) {
        asset = isToken0 ? Currency.unwrap(currency0) : Currency.unwrap(currency1);
        numeraire = isToken0 ? Currency.unwrap(currency1) : Currency.unwrap(currency0);
        vm.label(asset, "Asset");
        vm.label(numeraire, "Numeraire");
        (isToken0 ? currency0 : currency1).transfer(address(airlock), currency0.balanceOfSelf());
        vm.prank(address(airlock));
        ERC20(asset).approve(address(initializer), type(uint256).max);
        _;
    }

    /* --------------------------------------------------------------------------- */
    /*                                constructor()                                */
    /* --------------------------------------------------------------------------- */

    function test_constructor() public view {
        assertEq(address(initializer.airlock()), address(airlock));
        assertEq(address(initializer.poolManager()), address(manager));
        assertEq(address(initializer.HOOK()), address(hook));
    }

    /* -------------------------------------------------------------------------- */
    /*                                initialize()                                */
    /* -------------------------------------------------------------------------- */

    function test_initialize_RevertsWhenSenderNotAirlock() public {
        InitData memory initData = _prepareInitData();
        vm.expectRevert(SenderNotAirlock.selector);
        initializer.initialize(
            Currency.unwrap(currency0),
            Currency.unwrap(currency1),
            totalTokensOnBondingCurve,
            bytes32(0),
            abi.encode(initData)
        );
    }

    function test_initialize_RevertsWhenAlreadyInitialized(bool isToken0) public {
        InitData memory initData = test_initialize_InitializesPool(isToken0);
        vm.expectRevert(PoolAlreadyInitialized.selector);
        vm.prank(address(airlock));
        initializer.initialize(asset, numeraire, totalTokensOnBondingCurve, 0, abi.encode(initData));
    }

    function test_initialize_RevertsWhenStartFeeTooHigh(bool isToken0) public prepareAsset(isToken0) {
        InitData memory initData = _prepareInitData();
        initData.startFee = MAX_LP_FEE + 1;

        vm.expectRevert(abi.encodeWithSelector(FeeTooHigh.selector, MAX_LP_FEE + 1));
        vm.prank(address(airlock));
        initializer.initialize(asset, numeraire, totalTokensOnBondingCurve, 0, abi.encode(initData));
    }

    function test_initialize_RevertsWhenEndFeeTooHigh(bool isToken0) public prepareAsset(isToken0) {
        InitData memory initData = _prepareInitData();
        initData.fee = MAX_LP_FEE + 1;

        vm.expectRevert(abi.encodeWithSelector(FeeTooHigh.selector, MAX_LP_FEE + 1));
        vm.prank(address(airlock));
        initializer.initialize(asset, numeraire, totalTokensOnBondingCurve, 0, abi.encode(initData));
    }

    function test_initialize_RevertsWhenFeeRangeAscending(bool isToken0) public prepareAsset(isToken0) {
        InitData memory initData = _prepareInitData();
        initData.startFee = 1000;
        initData.fee = 10_000;

        vm.expectRevert(abi.encodeWithSelector(InvalidFeeRange.selector, 1000, 10_000));
        vm.prank(address(airlock));
        initializer.initialize(asset, numeraire, totalTokensOnBondingCurve, 0, abi.encode(initData));
    }

    function test_initialize_RevertsWhenDescendingDurationZero(bool isToken0) public prepareAsset(isToken0) {
        InitData memory initData = _prepareInitData();
        initData.startFee = 10_000;
        initData.fee = 1000;
        initData.durationSeconds = 0;

        vm.expectRevert(abi.encodeWithSelector(InvalidDurationSeconds.selector, 0));
        vm.prank(address(airlock));
        initializer.initialize(asset, numeraire, totalTokensOnBondingCurve, 0, abi.encode(initData));
    }

    function test_initialize_InitializesPool(bool isToken0)
        public
        prepareAsset(isToken0)
        returns (InitData memory initData)
    {
        initData = _prepareInitData();

        vm.expectEmit();
        emit IPoolInitializer.Create(address(manager), asset, numeraire);

        vm.prank(address(airlock));
        address returnedAsset =
            initializer.initialize(asset, numeraire, totalTokensOnBondingCurve, 0, abi.encode(initData));
        assertEq(returnedAsset, asset, "Returned asset address is incorrect");

        (, PoolStatus status,,) = initializer.getState(asset);
        assertEq(uint8(status), uint8(PoolStatus.Initialized), "Pool status should be Initialized");
    }

    function test_initialize_AddsLiquidity(bool isToken0) public {
        test_initialize_InitializesPool(isToken0);

        Position[] memory positions = initializer.getPositions(asset);
        uint256 totalLiquidity;

        for (uint256 i; i < positions.length; i++) {
            (uint128 liquidity,,) = manager.getPositionInfo(
                poolId, address(initializer), positions[i].tickLower, positions[i].tickUpper, positions[i].salt
            );
            totalLiquidity += liquidity;
        }

        assertGt(totalLiquidity, 0, "No position liquidity minted");
    }

    function test_initialize_LocksPool(bool isToken0) public prepareAsset(isToken0) {
        InitData memory initData = _prepareInitDataLock();

        vm.expectEmit();
        emit Lock(asset, initData.beneficiaries);
        vm.prank(address(airlock));
        initializer.initialize(asset, numeraire, totalTokensOnBondingCurve, 0, abi.encode(initData));

        (, PoolStatus status,,) = initializer.getState(asset);
        assertEq(uint8(status), uint8(PoolStatus.Locked), "Pool status should be locked");

        BeneficiaryData[] memory beneficiaries = initializer.getBeneficiaries(asset);

        for (uint256 i; i < initData.beneficiaries.length; i++) {
            assertEq(beneficiaries[i].beneficiary, initData.beneficiaries[i].beneficiary, "Incorrect beneficiary");
            assertEq(beneficiaries[i].shares, initData.beneficiaries[i].shares, "Incorrect shares");
        }
    }

    function test_initialize_StoresPoolState(bool isToken0) public {
        InitData memory initData = test_initialize_InitializesPool(isToken0);

        (address returnedNumeraire, PoolStatus status, PoolKey memory key, int24 farTick) = initializer.getState(asset);
        assertEq(uint8(status), uint8(PoolStatus.Initialized), "Pool status should be initialized");

        assertEq(returnedNumeraire, numeraire, "Incorrect numeraire");
        assertEq(Currency.unwrap(key.currency0), Currency.unwrap(currency0), "Incorrect currency0");
        assertEq(Currency.unwrap(key.currency1), Currency.unwrap(currency1), "Incorrect currency1");
        assertEq(key.fee, LPFeeLibrary.DYNAMIC_FEE_FLAG, "Incorrect fee flag");
        assertEq(key.tickSpacing, initData.tickSpacing, "Incorrect tick spacing");
        assertEq(address(key.hooks), address(hook), "Incorrect hook");
        assertEq(farTick, isToken0 ? int24(240_000) : int24(-240_000), "Incorrect far tick");

        // Hook schedule should mirror the init config.
        (uint32 startingTime, uint24 startFee, uint24 endFee, uint24 lastFee, uint32 durationSeconds) =
            hook.getFeeScheduleOf(poolId);
        assertEq(startingTime, initData.startingTime, "Incorrect schedule start");
        assertEq(startFee, initData.startFee, "Incorrect schedule start fee");
        assertEq(endFee, initData.fee, "Incorrect schedule end fee");
        assertEq(lastFee, initData.startFee, "Incorrect schedule last fee");
        assertEq(durationSeconds, initData.durationSeconds, "Incorrect schedule duration");

        // Hook seeds dynamic fee during initialization through setSchedule.
        (,,, uint24 lpFee) = manager.getSlot0(poolId);
        assertEq(lpFee, initData.startFee, "Incorrect seeded LP fee");
    }

    function testFuzz_initialize_StoresScheduleAndPoolStateForValidConfigs(
        bool isToken0,
        uint24 rawStartFee,
        uint24 rawEndFee,
        uint64 rawDurationSeconds,
        uint32 rawStartOffset
    ) public prepareAsset(isToken0) {
        InitData memory initData = _prepareInitData();
        uint24 startFee = uint24(bound(rawStartFee, 0, MAX_LP_FEE));
        uint24 endFee = uint24(bound(rawEndFee, 0, startFee));
        bool isDescending = startFee > endFee;
        uint32 durationSeconds = isDescending ? uint32(bound(rawDurationSeconds, 1, 200_000)) : 0;
        uint32 startOffset = uint32(bound(rawStartOffset, 0, 200_000));

        initData.startFee = startFee;
        initData.fee = endFee;
        initData.durationSeconds = durationSeconds;
        initData.startingTime = uint32(block.timestamp + startOffset);

        vm.prank(address(airlock));
        address returnedAsset =
            initializer.initialize(asset, numeraire, totalTokensOnBondingCurve, bytes32(0), abi.encode(initData));
        assertEq(returnedAsset, asset, "Returned asset must match initialized asset");

        (address returnedNumeraire, PoolStatus status, PoolKey memory key, int24 farTick) = initializer.getState(asset);
        assertEq(returnedNumeraire, numeraire, "Incorrect numeraire in stored state");
        assertEq(uint8(status), uint8(PoolStatus.Initialized), "Pool should remain initialized without beneficiaries");
        assertEq(address(key.hooks), address(hook), "Unexpected hook address");
        assertEq(key.fee, LPFeeLibrary.DYNAMIC_FEE_FLAG, "Pool key must use dynamic fee flag");
        assertEq(key.tickSpacing, initData.tickSpacing, "Unexpected tick spacing");

        address token0 = Currency.unwrap(key.currency0);
        address token1 = Currency.unwrap(key.currency1);
        assertLt(uint160(token0), uint160(token1), "Pool key currencies must be sorted");
        bool assetIsToken0 = asset == token0;
        assertEq(farTick, assetIsToken0 ? int24(240_000) : int24(-240_000), "Unexpected farTick orientation");

        (
            uint32 startingTime,
            uint24 scheduleStartFee,
            uint24 scheduleEndFee,
            uint24 lastFee,
            uint32 duration
        ) = hook.getFeeScheduleOf(poolId);
        assertEq(startingTime, initData.startingTime, "Future/now schedule start should be preserved");
        assertEq(scheduleStartFee, startFee, "Incorrect schedule start fee");
        assertEq(scheduleEndFee, endFee, "Incorrect schedule end fee");
        assertEq(lastFee, startFee, "Incorrect lastFee after initialization");
        assertEq(duration, durationSeconds, "Incorrect schedule duration");

        (,,, uint24 lpFee) = manager.getSlot0(poolId);
        assertEq(lpFee, startFee, "slot0 fee must be seeded to startFee");
    }

    function testFuzz_initialize_ClampsPastStartingTimeToCurrentBlock(
        bool isToken0,
        uint24 rawStartFee,
        uint24 rawEndFee,
        uint64 rawDurationSeconds,
        uint32 rawPastOffset
    ) public prepareAsset(isToken0) {
        vm.warp(2_000_000_000);

        InitData memory initData = _prepareInitData();
        uint24 startFee = uint24(bound(rawStartFee, 1, MAX_LP_FEE));
        uint24 endFee = uint24(bound(rawEndFee, 0, startFee - 1));
        uint32 durationSeconds = uint32(bound(rawDurationSeconds, 1, 200_000));
        uint32 pastOffset = uint32(bound(rawPastOffset, 1, 200_000));

        initData.startFee = startFee;
        initData.fee = endFee;
        initData.durationSeconds = durationSeconds;
        initData.startingTime = uint32(block.timestamp - pastOffset);

        vm.prank(address(airlock));
        initializer.initialize(asset, numeraire, totalTokensOnBondingCurve, bytes32(0), abi.encode(initData));

        (
            uint32 startingTime,
            uint24 scheduleStartFee,
            uint24 scheduleEndFee,
            uint24 lastFee,
            uint32 duration
        ) = hook.getFeeScheduleOf(poolId);
        assertEq(startingTime, block.timestamp, "Past start time should clamp to current block");
        assertEq(scheduleStartFee, startFee, "Incorrect schedule start fee");
        assertEq(scheduleEndFee, endFee, "Incorrect schedule end fee");
        assertEq(lastFee, startFee, "lastFee should equal startFee after initialization");
        assertEq(duration, durationSeconds, "Incorrect schedule duration");
    }

    function testFuzz_initialize_FlatScheduleCompletesImmediatelyAndNoOpsOnSwap(
        bool isToken0,
        uint24 rawFee,
        uint32 rawStartOffset,
        uint32 rawWarpAfterInit
    ) public prepareAsset(isToken0) {
        InitData memory initData = _prepareInitData();
        uint24 fee = uint24(bound(rawFee, 0, MAX_LP_FEE));
        uint32 startOffset = uint32(bound(rawStartOffset, 0, 200_000));
        uint32 warpAfterInit = uint32(bound(rawWarpAfterInit, 0, 200_000));

        initData.startFee = fee;
        initData.fee = fee;
        initData.durationSeconds = 0;
        initData.startingTime = uint32(block.timestamp + startOffset);

        vm.prank(address(airlock));
        initializer.initialize(asset, numeraire, totalTokensOnBondingCurve, bytes32(0), abi.encode(initData));

        (
            uint32 startingTime,
            uint24 scheduleStartFee,
            uint24 scheduleEndFee,
            uint24 lastFee,
            uint32 duration
        ) = hook.getFeeScheduleOf(poolId);
        assertEq(startingTime, initData.startingTime, "Flat schedule should preserve start time");
        assertEq(scheduleStartFee, fee, "Incorrect schedule start fee");
        assertEq(scheduleEndFee, fee, "Incorrect schedule end fee");
        assertEq(lastFee, fee, "Incorrect schedule lastFee");
        assertEq(duration, 0, "Flat schedule should persist zero duration");

        vm.warp(block.timestamp + warpAfterInit);
        _swapAssetAgainstNumeraire(isToken0, 1 ether);

        (,,, uint24 lpFeeAfter) = manager.getSlot0(poolId);
        assertEq(lpFeeAfter, fee, "Flat schedule should never update fee on swap");
        (,,, uint24 lastFeeAfter,) = hook.getFeeScheduleOf(poolId);
        assertEq(lastFeeAfter, fee, "Flat schedule should keep terminal fee");
    }

    function test_initialize_FlatScheduleAllowsNonZeroDurationAndRemainsComplete(bool isToken0)
        public
        prepareAsset(isToken0)
    {
        InitData memory initData = _prepareInitData();
        initData.startFee = 7000;
        initData.fee = 7000;
        initData.durationSeconds = 1234;

        vm.prank(address(airlock));
        initializer.initialize(asset, numeraire, totalTokensOnBondingCurve, bytes32(0), abi.encode(initData));

        (,,, uint24 seededFee) = manager.getSlot0(poolId);
        assertEq(seededFee, initData.startFee, "slot0 fee should be seeded to flat fee");

        (uint32 startingTime, uint24 startFee, uint24 endFee, uint24 lastFee, uint32 duration) =
            hook.getFeeScheduleOf(poolId);
        assertEq(startingTime, initData.startingTime, "flat schedule start should be preserved");
        assertEq(startFee, initData.startFee, "unexpected flat start fee");
        assertEq(endFee, initData.fee, "unexpected flat end fee");
        assertEq(lastFee, initData.startFee, "unexpected flat lastFee");
        assertEq(duration, initData.durationSeconds, "flat schedule should preserve non-zero duration");

        vm.warp(block.timestamp + 1 days);
        _swapAssetAgainstNumeraire(isToken0, 1 ether);

        (,,, uint24 feeAfterSwap) = manager.getSlot0(poolId);
        assertEq(feeAfterSwap, initData.startFee, "flat schedule fee should not change on swap");
        (,,, uint24 lastFeeAfterSwap,) = hook.getFeeScheduleOf(poolId);
        assertEq(lastFeeAfterSwap, initData.startFee, "flat schedule lastFee should remain terminal");
    }

    function test_initialize_ReturnsDustToAirlock(bool isToken0) public prepareAsset(isToken0) {
        InitData memory initData = _prepareInitData();
        uint256 airlockBalanceBefore = ERC20(asset).balanceOf(address(airlock));

        vm.prank(address(airlock));
        initializer.initialize(asset, numeraire, totalTokensOnBondingCurve, bytes32(0), abi.encode(initData));

        uint256 airlockBalanceAfter = ERC20(asset).balanceOf(address(airlock));
        assertLt(airlockBalanceAfter, airlockBalanceBefore, "airlock should spend some asset tokens");
        assertGt(
            airlockBalanceAfter,
            airlockBalanceBefore - totalTokensOnBondingCurve,
            "initializer should return rounding dust to airlock"
        );
        assertEq(ERC20(asset).balanceOf(address(initializer)), 0, "initializer should not retain asset dust");
    }

    function testFuzz_initialize_RevertsWhenStartFeeTooHigh_Fuzzed(
        bool isToken0,
        uint24 rawStartFee
    ) public prepareAsset(isToken0) {
        InitData memory initData = _prepareInitData();
        uint24 startFee = uint24(bound(rawStartFee, MAX_LP_FEE + 1, type(uint24).max));

        initData.startFee = startFee;
        initData.fee = MAX_LP_FEE;
        initData.durationSeconds = 0;

        vm.expectRevert(abi.encodeWithSelector(FeeTooHigh.selector, startFee));
        vm.prank(address(airlock));
        initializer.initialize(asset, numeraire, totalTokensOnBondingCurve, bytes32(0), abi.encode(initData));
    }

    function testFuzz_initialize_RevertsWhenEndFeeTooHigh_Fuzzed(
        bool isToken0,
        uint24 rawEndFee
    ) public prepareAsset(isToken0) {
        InitData memory initData = _prepareInitData();
        uint24 endFee = uint24(bound(rawEndFee, MAX_LP_FEE + 1, type(uint24).max));

        initData.startFee = MAX_LP_FEE;
        initData.fee = endFee;
        initData.durationSeconds = 0;

        vm.expectRevert(abi.encodeWithSelector(FeeTooHigh.selector, endFee));
        vm.prank(address(airlock));
        initializer.initialize(asset, numeraire, totalTokensOnBondingCurve, bytes32(0), abi.encode(initData));
    }

    function testFuzz_initialize_RevertsWhenFeeRangeAscending_Fuzzed(
        bool isToken0,
        uint24 rawStartFee,
        uint24 rawEndFee
    ) public prepareAsset(isToken0) {
        InitData memory initData = _prepareInitData();
        uint24 startFee = uint24(bound(rawStartFee, 0, MAX_LP_FEE - 1));
        uint24 endFee = uint24(bound(rawEndFee, startFee + 1, MAX_LP_FEE));

        initData.startFee = startFee;
        initData.fee = endFee;
        initData.durationSeconds = 0;

        vm.expectRevert(abi.encodeWithSelector(InvalidFeeRange.selector, startFee, endFee));
        vm.prank(address(airlock));
        initializer.initialize(asset, numeraire, totalTokensOnBondingCurve, bytes32(0), abi.encode(initData));
    }

    function testFuzz_initialize_RevertsWhenDescendingDurationZero_Fuzzed(
        bool isToken0,
        uint24 rawStartFee,
        uint24 rawEndFee
    ) public prepareAsset(isToken0) {
        InitData memory initData = _prepareInitData();
        uint24 startFee = uint24(bound(rawStartFee, 1, MAX_LP_FEE));
        uint24 endFee = uint24(bound(rawEndFee, 0, startFee - 1));

        initData.startFee = startFee;
        initData.fee = endFee;
        initData.durationSeconds = 0;

        vm.expectRevert(abi.encodeWithSelector(InvalidDurationSeconds.selector, 0));
        vm.prank(address(airlock));
        initializer.initialize(asset, numeraire, totalTokensOnBondingCurve, bytes32(0), abi.encode(initData));
    }

    function testFuzz_initialize_DecaysFeeOnFirstPostStartSwap(
        bool isToken0,
        uint24 rawStartFee,
        uint24 rawEndFee,
        uint64 rawDurationSeconds,
        uint32 rawStartOffset,
        uint32 rawElapsedAfterStart
    ) public prepareAsset(isToken0) {
        InitData memory initData = _prepareInitData();
        uint24 startFee = uint24(bound(rawStartFee, 1, MAX_LP_FEE));
        uint24 endFee = uint24(bound(rawEndFee, 0, startFee - 1));
        uint32 durationSeconds = uint32(bound(rawDurationSeconds, 1, 200_000));
        uint32 startOffset = uint32(bound(rawStartOffset, 0, 200_000));

        initData.startFee = startFee;
        initData.fee = endFee;
        initData.durationSeconds = durationSeconds;
        initData.startingTime = uint32(block.timestamp + startOffset);

        vm.prank(address(airlock));
        initializer.initialize(asset, numeraire, totalTokensOnBondingCurve, bytes32(0), abi.encode(initData));

        uint256 elapsedAfterStart = bound(uint256(rawElapsedAfterStart), 1, uint256(durationSeconds) + 200_000);
        vm.warp(uint256(initData.startingTime) + elapsedAfterStart);
        _swapAssetAgainstNumeraire(isToken0, 1 ether);

        uint24 expectedFee = _expectedDecayFee(startFee, endFee, durationSeconds, elapsedAfterStart);
        (,,, uint24 lpFeeAfterSwap) = manager.getSlot0(poolId);
        assertEq(lpFeeAfterSwap, expectedFee, "Swap should execute at decayed fee");

        (,,, uint24 lastFee,) = hook.getFeeScheduleOf(poolId);
        assertEq(lastFee, expectedFee, "Stored schedule fee must match computed decay");
    }

    function testFuzz_initialize_PreStartSwapRetainsStartFee(
        bool isToken0,
        uint24 rawStartFee,
        uint24 rawEndFee,
        uint64 rawDurationSeconds,
        uint32 rawStartOffset,
        uint32 rawElapsedBeforeStart
    ) public prepareAsset(isToken0) {
        InitData memory initData = _prepareInitData();
        uint24 startFee = uint24(bound(rawStartFee, 1, MAX_LP_FEE));
        uint24 endFee = uint24(bound(rawEndFee, 0, startFee - 1));
        uint32 durationSeconds = uint32(bound(rawDurationSeconds, 1, 200_000));
        uint32 startOffset = uint32(bound(rawStartOffset, 1, 200_000));

        initData.startFee = startFee;
        initData.fee = endFee;
        initData.durationSeconds = durationSeconds;
        initData.startingTime = uint32(block.timestamp + startOffset);

        vm.prank(address(airlock));
        initializer.initialize(asset, numeraire, totalTokensOnBondingCurve, bytes32(0), abi.encode(initData));

        uint256 elapsedBeforeStart = bound(uint256(rawElapsedBeforeStart), 0, uint256(startOffset) - 1);
        vm.warp(block.timestamp + elapsedBeforeStart);
        _swapAssetAgainstNumeraire(isToken0, 1 ether);

        (,,, uint24 lpFeeAfterSwap) = manager.getSlot0(poolId);
        assertEq(lpFeeAfterSwap, startFee, "Pre-start swap must use start fee");

        (uint32 scheduleStart,,, uint24 lastFee, uint32 duration) = hook.getFeeScheduleOf(poolId);
        assertEq(scheduleStart, initData.startingTime, "Pre-start schedule start should remain unchanged");
        assertEq(duration, durationSeconds, "Schedule duration should remain unchanged");
        assertEq(lastFee, startFee, "lastFee should remain start fee before start");
    }

    function test_initialize_SwapExactlyAtStartTimeRetainsStartFee(bool isToken0) public prepareAsset(isToken0) {
        InitData memory initData = _prepareInitData();
        initData.startingTime = uint32(block.timestamp + 3600);

        vm.prank(address(airlock));
        initializer.initialize(asset, numeraire, totalTokensOnBondingCurve, bytes32(0), abi.encode(initData));

        vm.warp(initData.startingTime);
        _swapAssetAgainstNumeraire(isToken0, 1 ether);

        (,,, uint24 lpFeeAfterSwap) = manager.getSlot0(poolId);
        assertEq(lpFeeAfterSwap, initData.startFee, "swap at exact start timestamp should still use start fee");

        (uint32 scheduleStart,,, uint24 lastFee, uint32 duration) = hook.getFeeScheduleOf(poolId);
        assertEq(scheduleStart, initData.startingTime, "schedule start should remain unchanged");
        assertEq(duration, initData.durationSeconds, "schedule duration should remain unchanged");
        assertEq(lastFee, initData.startFee, "fee should not decay exactly at start boundary");
    }

    function test_initialize_InvalidCurveRevertsAtomically(bool isToken0) public prepareAsset(isToken0) {
        InitData memory initData = _prepareInitData();
        initData.curves[0].numPositions = 0;

        uint256 airlockAssetBefore = ERC20(asset).balanceOf(address(airlock));

        vm.expectRevert(ZeroPosition.selector);
        vm.prank(address(airlock));
        initializer.initialize(asset, numeraire, totalTokensOnBondingCurve, bytes32(0), abi.encode(initData));

        assertEq(
            ERC20(asset).balanceOf(address(airlock)), airlockAssetBefore, "airlock balance should remain unchanged"
        );
        assertEq(
            ERC20(asset).balanceOf(address(initializer)), 0, "initializer should not retain asset on reverted init"
        );

        (address returnedNumeraire, PoolStatus status,,) = initializer.getState(asset);
        assertEq(returnedNumeraire, address(0), "state should not be partially initialized");
        assertEq(uint8(status), uint8(PoolStatus.Uninitialized), "pool status should remain uninitialized");

        (uint32 scheduleStart, uint24 startFee, uint24 endFee, uint24 lastFee, uint32 duration) =
            hook.getFeeScheduleOf(poolId);
        assertEq(scheduleStart, 0, "fee schedule should not be persisted");
        assertEq(startFee, 0, "fee schedule should not be persisted");
        assertEq(endFee, 0, "fee schedule should not be persisted");
        assertEq(lastFee, 0, "fee schedule should not be persisted");
        assertEq(duration, 0, "fee schedule should not be persisted");
    }

    /* ----------------------------------------------------------------------------- */
    /*                                exitLiquidity()                                */
    /* ----------------------------------------------------------------------------- */

    function test_exitLiquidity(bool isToken0) public {
        test_initialize_InitializesPool(isToken0);

        (,,, int24 farTick) = initializer.getState(asset);
        _buyUntilFarTick(farTick, isToken0);
        vm.prank(address(airlock));
        (uint160 sqrtPriceX96,,,,,,) = initializer.exitLiquidity(asset);

        assertEq(sqrtPriceX96, TickMath.getSqrtPriceAtTick(farTick), "Incorrect returned sqrtPriceX96");

        (, PoolStatus status,,) = initializer.getState(asset);
        assertEq(uint8(status), uint8(PoolStatus.Exited), "Pool status should be Exited");

        assertEq(currency0.balanceOf(address(initializer)), 0, "Initializer should have zero balance of token0");
        assertEq(currency1.balanceOf(address(initializer)), 0, "Initializer should have zero balance of token1");

        assertLt(currency0.balanceOf(address(manager)), 200, "Poolmanager should have near-zero balance of token0");
        assertLt(currency1.balanceOf(address(manager)), 200, "Poolmanager should have near-zero balance of token1");

        assertEq(manager.getLiquidity(poolId), 0, "Pool liquidity should be zero");

        Position[] memory positions = initializer.getPositions(asset);

        for (uint256 i; i < positions.length; i++) {
            (uint128 liquidity,,) = manager.getPositionInfo(
                poolId, address(initializer), positions[i].tickLower, positions[i].tickUpper, positions[i].salt
            );
            assertEq(liquidity, 0, "Position liquidity should be zero");
        }
    }

    function test_exitLiquidity_RevertsWhenSenderNotAirlock(bool isToken0) public {
        test_initialize_InitializesPool(isToken0);
        vm.expectRevert(SenderNotAirlock.selector);
        initializer.exitLiquidity(asset);
    }

    function test_exitLiquidity_RevertsWhenPoolNotInitialized(bool isToken0) public {
        test_exitLiquidity(isToken0);
        vm.expectRevert(PoolAlreadyExited.selector);
        vm.prank(address(airlock));
        initializer.exitLiquidity(asset);
    }

    function test_exitLiquidity_RevertsWhenInsufficientTick(bool isToken0) public {
        test_initialize_InitializesPool(isToken0);
        (,,, int24 farTick) = initializer.getState(asset);
        (, int24 tick,,) = manager.getSlot0(poolId);

        vm.prank(address(airlock));
        vm.expectRevert(abi.encodeWithSelector(CannotMigrateInsufficientTick.selector, farTick, tick));
        initializer.exitLiquidity(asset);
    }

    /* --------------------------------------------------------------------------- */
    /*                                collectFees()                                */
    /* --------------------------------------------------------------------------- */

    function test_collectFees_RevertsWhenPoolNotLocked() public {
        vm.expectRevert(PoolNotLocked.selector);
        initializer.collectFees(PoolId.wrap(0));
    }

    function test_collectFees(bool isToken0) public prepareAsset(isToken0) {
        InitData memory initData = _prepareInitDataLock();
        vm.prank(address(airlock));
        initializer.initialize(asset, numeraire, totalTokensOnBondingCurve, 0, abi.encode(initData));

        IPoolManager.SwapParams memory params = IPoolManager.SwapParams({
            zeroForOne: !isToken0,
            amountSpecified: 1e18,
            sqrtPriceLimitX96: !isToken0 ? TickMath.MIN_SQRT_PRICE + 1 : TickMath.MAX_SQRT_PRICE - 1
        });

        ERC20(numeraire).approve(address(swapRouter), type(uint256).max);
        swapRouter.swap(poolKey, params, PoolSwapTest.TestSettings(false, false), new bytes(0));

        initializer.collectFees(poolId);
    }

    /* ----------------------------------------------------------------------- */
    /*                                Utilities                                */
    /* ----------------------------------------------------------------------- */

    function _prepareInitData() internal returns (InitData memory) {
        Curve[] memory curves = new Curve[](10);
        int24 tickSpacing = 8;

        for (uint256 i; i < 10; ++i) {
            curves[i].tickLower = int24(uint24(160_000 + i * 8));
            curves[i].tickUpper = 240_000;
            curves[i].numPositions = 10;
            curves[i].shares = WAD / 10;
        }

        poolKey = PoolKey({
            currency0: currency0,
            currency1: currency1,
            tickSpacing: tickSpacing,
            fee: LPFeeLibrary.DYNAMIC_FEE_FLAG,
            hooks: IHooks(address(hook))
        });
        poolId = poolKey.toId();

        return InitData({
            startFee: 20_000,
            fee: 5000,
            durationSeconds: 1000,
            tickSpacing: tickSpacing,
            curves: curves,
            beneficiaries: new BeneficiaryData[](0),
            startingTime: uint32(block.timestamp + 100)
        });
    }

    function _prepareInitDataLock() internal returns (InitData memory) {
        InitData memory initData = _prepareInitData();
        BeneficiaryData[] memory beneficiaries = new BeneficiaryData[](2);
        beneficiaries[0] = BeneficiaryData({ beneficiary: makeAddr("Beneficiary1"), shares: 0.95e18 });
        beneficiaries[1] = BeneficiaryData({ beneficiary: airlockOwner, shares: 0.05e18 });
        initData.beneficiaries = beneficiaries;
        return initData;
    }

    function _buyUntilFarTick(int24 farTick, bool isToken0) internal {
        IPoolManager.SwapParams memory params = IPoolManager.SwapParams({
            zeroForOne: !isToken0,
            amountSpecified: int256(totalTokensOnBondingCurve),
            sqrtPriceLimitX96: !isToken0 ? TickMath.MIN_SQRT_PRICE + 1 : TickMath.MAX_SQRT_PRICE - 1
        });

        ERC20(numeraire).approve(address(swapRouter), type(uint256).max);
        swapRouter.swap(poolKey, params, PoolSwapTest.TestSettings(false, false), new bytes(0));
        (, int24 tick,,) = manager.getSlot0(poolId);
        assertTrue(((isToken0 && tick >= farTick) || (!isToken0 && tick <= farTick)), "Did not reach far tick");
    }

    function _swapAssetAgainstNumeraire(bool isToken0, int256 amountSpecified) internal {
        IPoolManager.SwapParams memory params = IPoolManager.SwapParams({
            zeroForOne: !isToken0,
            amountSpecified: amountSpecified,
            sqrtPriceLimitX96: !isToken0 ? TickMath.MIN_SQRT_PRICE + 1 : TickMath.MAX_SQRT_PRICE - 1
        });

        ERC20(numeraire).approve(address(swapRouter), type(uint256).max);
        swapRouter.swap(poolKey, params, PoolSwapTest.TestSettings(false, false), new bytes(0));
    }

    function _expectedDecayFee(
        uint24 startFee,
        uint24 endFee,
        uint32 durationSeconds,
        uint256 elapsed
    ) internal pure returns (uint24) {
        if (elapsed >= durationSeconds) {
            return endFee;
        }

        return uint24(uint256(startFee) - (uint256(startFee - endFee) * elapsed) / durationSeconds);
    }
}
