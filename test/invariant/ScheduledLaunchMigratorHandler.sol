// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.24;

import { Constants } from "@v4-core-test/utils/Constants.sol";
import { Deployers } from "@v4-core-test/utils/Deployers.sol";
import { IHooks } from "@v4-core/interfaces/IHooks.sol";
import { IPoolManager } from "@v4-core/interfaces/IPoolManager.sol";
import { Hooks } from "@v4-core/libraries/Hooks.sol";
import { TickMath } from "@v4-core/libraries/TickMath.sol";
import { PoolSwapTest } from "@v4-core/test/PoolSwapTest.sol";
import { TestERC20 } from "@v4-core/test/TestERC20.sol";
import { Currency } from "@v4-core/types/Currency.sol";
import { PoolId } from "@v4-core/types/PoolId.sol";
import { PoolKey } from "@v4-core/types/PoolKey.sol";
import { Test } from "forge-std/Test.sol";

import { StreamableFeesLockerV2 } from "src/StreamableFeesLockerV2.sol";
import { ON_INITIALIZATION_FLAG, ON_SWAP_FLAG } from "src/base/BaseDopplerHook.sol";
import { ScheduledLaunchDopplerHook } from "src/dopplerHooks/ScheduledLaunchDopplerHook.sol";
import { DopplerHookMigrator } from "src/migrators/DopplerHookMigrator.sol";
import { BeneficiaryData } from "src/types/BeneficiaryData.sol";
import { AddressSet, LibAddressSet } from "test/invariant/AddressSet.sol";

uint160 constant MIN_PRICE_LIMIT = TickMath.MIN_SQRT_PRICE + 1;
uint160 constant MAX_PRICE_LIMIT = TickMath.MAX_SQRT_PRICE - 1;

address constant AIRLOCK_OWNER = 0xf00000000000000000000000000000000000B055;

contract ScheduledLaunchMigratorInvariantTests is Deployers {
    DopplerHookMigrator public migrator;
    ScheduledLaunchDopplerHook public scheduledLaunchHook;
    StreamableFeesLockerV2 public locker;
    ScheduledLaunchMigratorHandler public handler;

    function setUp() public {
        deployFreshManager();
        swapRouter = new PoolSwapTest(manager);

        handler = new ScheduledLaunchMigratorHandler(manager, swapRouter);

        uint160 hookFlags = Hooks.BEFORE_INITIALIZE_FLAG | Hooks.AFTER_SWAP_FLAG | Hooks.AFTER_SWAP_RETURNS_DELTA_FLAG;

        locker = new StreamableFeesLockerV2(manager, AIRLOCK_OWNER);
        address migratorAddress = address(uint160(hookFlags) ^ (0x4444 << 144));
        migrator = DopplerHookMigrator(payable(migratorAddress));
        deployCodeTo("DopplerHookMigrator", abi.encode(address(handler), address(manager), locker), migratorAddress);

        scheduledLaunchHook = new ScheduledLaunchDopplerHook(address(migrator));

        vm.prank(AIRLOCK_OWNER);
        locker.approveMigrator(address(migrator));

        address[] memory hooks = new address[](1);
        hooks[0] = address(scheduledLaunchHook);
        uint256[] memory flags = new uint256[](1);
        flags[0] = ON_INITIALIZATION_FLAG | ON_SWAP_FLAG;
        vm.prank(AIRLOCK_OWNER);
        migrator.setDopplerHookState(hooks, flags);

        handler.setMigrator(migrator, scheduledLaunchHook, locker);

        bytes4[] memory selectors = new bytes4[](3);
        selectors[0] = handler.initialize.selector;
        selectors[1] = handler.swapExactIn.selector;
        selectors[2] = handler.advanceTime.selector;

        targetSelector(FuzzSelector({ addr: address(handler), selectors: selectors }));
        targetContract(address(handler));
    }

    function invariant_SwapsOnlyAfterStartTime() public view {
        uint256 poolKeysLength = handler.poolKeysLength();

        for (uint256 i; i < poolKeysLength; i++) {
            PoolKey memory poolKey = handler.getPoolKey(i);
            PoolId poolId = poolKey.toId();

            uint256 startTime = handler.getStartTime(poolId);
            uint256 swapCount = handler.getSwapCount(poolId);
            uint256 lastSwapTime = handler.getLastSwapTime(poolId);

            if (swapCount == 0) continue;
            assertGe(lastSwapTime, startTime, "Swap occurred before start time");
        }
    }
}

struct ScheduledLaunchSettings {
    address asset;
    address numeraire;
    uint256 startTime;
    bool isToken0;
}

contract ScheduledLaunchMigratorHandler is Test {
    using LibAddressSet for AddressSet;

    IPoolManager public manager;
    DopplerHookMigrator public migrator;
    ScheduledLaunchDopplerHook public hook;
    StreamableFeesLockerV2 public locker;
    PoolSwapTest public swapRouter;

    mapping(PoolId => ScheduledLaunchSettings) public settingsOf;
    PoolKey[] public poolKeys;
    uint256 public poolKeysLength;
    address[] public availableNumeraires;

    mapping(PoolId => uint256) public swapCountOf;
    mapping(PoolId => uint256) public lastSwapTimeOf;

    AddressSet internal actors;
    address internal currentActor;

    modifier createActor() {
        currentActor = address(uint160(msg.sender) | uint160(0xfFfFFFFfFF000000000000000000000000000000));
        actors.add(currentActor);
        vm.startPrank(currentActor);
        _;
        vm.stopPrank();
    }

    constructor(IPoolManager manager_, PoolSwapTest swapRouter_) {
        manager = manager_;
        swapRouter = swapRouter_;

        availableNumeraires.push(address(0));
        for (uint256 i; i < 2; i++) {
            availableNumeraires.push(address(new TestERC20(0)));
        }
    }

    function setMigrator(
        DopplerHookMigrator migrator_,
        ScheduledLaunchDopplerHook hook_,
        StreamableFeesLockerV2 locker_
    ) external {
        migrator = migrator_;
        hook = hook_;
        locker = locker_;
    }

    function owner() external pure returns (address) {
        return AIRLOCK_OWNER;
    }

    function initialize(uint256 seed) public {
        vm.assume(seed % 100 > 5);

        address numeraire = availableNumeraires[seed % availableNumeraires.length];
        address asset = address(new TestERC20(1e27));

        bool isToken0 = asset < numeraire;
        address token0 = isToken0 ? asset : numeraire;
        address token1 = isToken0 ? numeraire : asset;

        BeneficiaryData[] memory beneficiaries = new BeneficiaryData[](2);
        beneficiaries[0] = BeneficiaryData({ beneficiary: address(0xbeef), shares: 0.95e18 });
        beneficiaries[1] = BeneficiaryData({ beneficiary: AIRLOCK_OWNER, shares: 0.05e18 });

        uint256 startTime = block.timestamp + (seed % 2 == 0 ? 1 days : 0);
        bytes memory migratorData = abi.encode(
            uint24(3000),
            int24(8),
            uint32(30 days),
            beneficiaries,
            false,
            address(hook),
            abi.encode(startTime),
            new bytes(0)
        );

        migrator.initialize(asset, numeraire, migratorData);

        if (token0 == address(0)) {
            deal(address(migrator), 5 ether);
        } else {
            deal(token0, address(this), 5 ether);
            TestERC20(token0).transfer(address(migrator), 5 ether);
        }

        if (token1 == address(0)) {
            deal(address(migrator), 5 ether);
        } else {
            deal(token1, address(this), 5 ether);
            TestERC20(token1).transfer(address(migrator), 5 ether);
        }

        migrator.migrate(Constants.SQRT_PRICE_1_1, token0, token1, address(0xbeef));

        PoolKey memory poolKey = migrator.getMigratorState(asset).poolKey;
        poolKeys.push(poolKey);
        poolKeysLength++;

        settingsOf[poolKey.toId()] = ScheduledLaunchSettings({
            asset: asset,
            numeraire: numeraire,
            startTime: startTime,
            isToken0: Currency.unwrap(poolKey.currency0) == asset
        });
    }

    function swapExactIn(uint256 seed) public createActor {
        if (poolKeys.length == 0) return;

        uint256 swapAmount = 0.1 ether;
        PoolKey memory poolKey = poolKeys[seed % poolKeys.length];
        PoolId poolId = poolKey.toId();
        ScheduledLaunchSettings memory settings = settingsOf[poolId];

        if (settings.numeraire == address(0)) {
            deal(currentActor, swapAmount);
        } else {
            deal(settings.numeraire, currentActor, swapAmount);
            TestERC20(settings.numeraire).approve(address(swapRouter), swapAmount);
        }

        try swapRouter.swap{ value: settings.numeraire == address(0) ? swapAmount : 0 }(
            poolKey,
            IPoolManager.SwapParams(
                !settings.isToken0, -int256(swapAmount), settings.isToken0 ? MAX_PRICE_LIMIT : MIN_PRICE_LIMIT
            ),
            PoolSwapTest.TestSettings(false, false),
            ""
        ) { }
        catch {
            return;
        }

        swapCountOf[poolId] += 1;
        lastSwapTimeOf[poolId] = block.timestamp;
    }

    function advanceTime(uint256 seed) public {
        uint256 warpBy = (seed % 2 days) + 1;
        vm.warp(block.timestamp + warpBy);
    }

    function getPoolKey(uint256 index) external view returns (PoolKey memory) {
        return poolKeys[index];
    }

    function getStartTime(PoolId poolId) external view returns (uint256) {
        return settingsOf[poolId].startTime;
    }

    function getSwapCount(PoolId poolId) external view returns (uint256) {
        return swapCountOf[poolId];
    }

    function getLastSwapTime(PoolId poolId) external view returns (uint256) {
        return lastSwapTimeOf[poolId];
    }
}
