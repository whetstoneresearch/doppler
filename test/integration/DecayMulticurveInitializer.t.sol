// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.26;

import { Deployers } from "@uniswap/v4-core/test/utils/Deployers.sol";
import { IPoolManager } from "@v4-core/interfaces/IPoolManager.sol";
import { Hooks } from "@v4-core/libraries/Hooks.sol";
import { LPFeeLibrary } from "@v4-core/libraries/LPFeeLibrary.sol";
import { StateLibrary } from "@v4-core/libraries/StateLibrary.sol";
import { TickMath } from "@v4-core/libraries/TickMath.sol";
import { PoolSwapTest } from "@v4-core/test/PoolSwapTest.sol";
import { TestERC20 } from "@v4-core/test/TestERC20.sol";
import { Currency, greaterThan } from "@v4-core/types/Currency.sol";
import { PoolId } from "@v4-core/types/PoolId.sol";
import { PoolKey } from "@v4-core/types/PoolKey.sol";
import { Vm } from "forge-std/Vm.sol";

import { Airlock, CreateParams, ModuleState } from "src/Airlock.sol";
import { GovernanceFactory } from "src/governance/GovernanceFactory.sol";
import { DecayMulticurveInitializer, InitData, MAX_LP_FEE } from "src/initializers/DecayMulticurveInitializer.sol";
import { DecayMulticurveInitializerHook } from "src/initializers/DecayMulticurveInitializerHook.sol";
import { PoolAlreadyExited, PoolStatus } from "src/initializers/UniswapV4MulticurveInitializer.sol";
import { IGovernanceFactory } from "src/interfaces/IGovernanceFactory.sol";
import { ILiquidityMigrator } from "src/interfaces/ILiquidityMigrator.sol";
import { IPoolInitializer } from "src/interfaces/IPoolInitializer.sol";
import { ITokenFactory } from "src/interfaces/ITokenFactory.sol";
import { Curve } from "src/libraries/Multicurve.sol";
import { DERC20 } from "src/tokens/DERC20.sol";
import { TokenFactory } from "src/tokens/TokenFactory.sol";
import { BeneficiaryData } from "src/types/BeneficiaryData.sol";
import { WAD } from "src/types/Wad.sol";

contract DecayMulticurveLiquidityMigratorMock is ILiquidityMigrator {
    function initialize(address, address, bytes memory) external pure override returns (address) {
        return address(0xdeadbeef);
    }

    function migrate(uint160, address, address, address) external payable override returns (uint256) {
        return 0;
    }
}

contract DecayMulticurveInitializerIntegrationTest is Deployers {
    using StateLibrary for IPoolManager;

    address public airlockOwner = makeAddr("AirlockOwner");
    Airlock public airlock;
    DecayMulticurveInitializer public initializer;
    DecayMulticurveInitializerHook public hook;
    TokenFactory public tokenFactory;
    GovernanceFactory public governanceFactory;
    DecayMulticurveLiquidityMigratorMock public mockLiquidityMigrator;
    TestERC20 public numeraire;

    PoolKey public poolKey;
    PoolId public poolId;

    function setUp() public {
        deployFreshManagerAndRouters();
        numeraire = new TestERC20(1e48);

        airlock = new Airlock(airlockOwner);
        tokenFactory = new TokenFactory(address(airlock));
        governanceFactory = new GovernanceFactory(address(airlock));
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

        mockLiquidityMigrator = new DecayMulticurveLiquidityMigratorMock();

        address[] memory modules = new address[](4);
        modules[0] = address(tokenFactory);
        modules[1] = address(governanceFactory);
        modules[2] = address(initializer);
        modules[3] = address(mockLiquidityMigrator);

        ModuleState[] memory states = new ModuleState[](4);
        states[0] = ModuleState.TokenFactory;
        states[1] = ModuleState.GovernanceFactory;
        states[2] = ModuleState.PoolInitializer;
        states[3] = ModuleState.LiquidityMigrator;

        vm.startPrank(airlockOwner);
        airlock.setModuleState(modules, states);
        vm.stopPrank();
    }

    function test_swap_UsesDecayedFeeOnFirstSwap() public {
        uint24 startFee = 20_000;
        uint24 endFee = 5000;
        uint64 durationSeconds = 1000;
        uint256 elapsed = 250;

        (bool isToken0,) = _createToken(bytes32(uint256(1)), startFee, endFee, durationSeconds);

        // Hook seeds fee at initialization time via setSchedule().
        (,,, uint24 lpFeeBefore) = manager.getSlot0(poolId);
        assertEq(lpFeeBefore, startFee, "unexpected initial slot0 fee");

        // Expected decayed fee at elapsed time.
        vm.warp(block.timestamp + elapsed);
        uint24 expectedFee = uint24(uint256(startFee) - (uint256(startFee - endFee) * elapsed) / durationSeconds);

        vm.recordLogs();
        _buyAsset(isToken0);
        Vm.Log[] memory logs = vm.getRecordedLogs();

        // Slot0 fee must be updated by beforeSwap in same transaction.
        (,,, uint24 lpFeeAfter) = manager.getSlot0(poolId);
        assertEq(lpFeeAfter, expectedFee, "slot0 fee should match decayed fee");

        // PoolManager swap event fee must match expected fee (no one-swap lag).
        uint24 observedSwapFee = _extractPoolManagerSwapFee(logs);
        assertEq(observedSwapFee, expectedFee, "first swap should use decayed fee immediately");
    }

    function test_noTradesThenFirstSwapAfterEnd_UsesEndFeeAndCompletes() public {
        uint24 startFee = 20_000;
        uint24 endFee = 5000;
        uint64 durationSeconds = 1000;

        (bool isToken0,) = _createToken(bytes32(uint256(2)), startFee, endFee, durationSeconds);

        vm.warp(block.timestamp + durationSeconds + 1);

        vm.recordLogs();
        _buyAsset(isToken0);
        Vm.Log[] memory logs = vm.getRecordedLogs();

        (,,, uint24 lpFeeAfter) = manager.getSlot0(poolId);
        assertEq(lpFeeAfter, endFee, "first post-end swap should set terminal fee");

        uint24 observedSwapFee = _extractPoolManagerSwapFee(logs);
        assertEq(observedSwapFee, endFee, "first post-end swap should execute at terminal fee");

        (,,, uint24 lastFee,) = hook.getFeeScheduleOf(poolId);
        assertEq(lastFee, endFee, "lastFee should be terminal fee");
    }

    function test_preStartSwap_UsesStartFeeAndDoesNotRevert() public {
        uint24 startFee = 20_000;
        uint24 endFee = 5000;
        uint64 durationSeconds = 1000;
        uint32 startingTime = uint32(block.timestamp + 3600);

        (bool isToken0,) =
            _createTokenWithStartTime(bytes32(uint256(3)), startFee, endFee, durationSeconds, startingTime);
        vm.warp(block.timestamp + 1);

        vm.recordLogs();
        _buyAsset(isToken0);
        Vm.Log[] memory logs = vm.getRecordedLogs();

        (,,, uint24 lpFeeAfter) = manager.getSlot0(poolId);
        assertEq(lpFeeAfter, startFee, "pre-start swap should retain start fee");

        uint24 observedSwapFee = _extractPoolManagerSwapFee(logs);
        assertEq(observedSwapFee, startFee, "pre-start swap should execute at start fee");

        (,,, uint24 lastFee,) = hook.getFeeScheduleOf(poolId);
        assertEq(lastFee, startFee, "pre-start swap should not decay lastFee");
    }

    function test_create_WithBeneficiariesLocksPoolAndBlocksMigration() public {
        uint24 startFee = 20_000;
        uint24 endFee = 5000;
        uint64 durationSeconds = 1000;

        BeneficiaryData[] memory beneficiaries = new BeneficiaryData[](2);
        beneficiaries[0] = BeneficiaryData({ beneficiary: makeAddr("Beneficiary1"), shares: 0.95e18 });
        beneficiaries[1] = BeneficiaryData({ beneficiary: airlockOwner, shares: 0.05e18 });

        (, address asset) = _createTokenWithStartTimeAndBeneficiaries(
            bytes32(uint256(7)), startFee, endFee, durationSeconds, uint32(block.timestamp + 100), beneficiaries
        );

        (, PoolStatus status,,) = initializer.getState(asset);
        assertEq(uint8(status), uint8(PoolStatus.Locked), "beneficiaries should lock pool state");

        (uint48 scheduleStart, uint24 storedStartFee, uint24 storedEndFee, uint24 lastFee,) =
            hook.getFeeScheduleOf(poolId);
        assertEq(scheduleStart, uint48(block.timestamp + 100), "unexpected schedule start");
        assertEq(storedStartFee, startFee, "unexpected schedule start fee");
        assertEq(storedEndFee, endFee, "unexpected schedule end fee");
        assertEq(lastFee, startFee, "unexpected schedule last fee");

        vm.expectRevert(PoolAlreadyExited.selector);
        airlock.migrate(asset);

        (, PoolStatus statusAfter,,) = initializer.getState(asset);
        assertEq(uint8(statusAfter), uint8(PoolStatus.Locked), "failed migration should not change locked state");
    }

    function testFuzz_swap_UsesExpectedDecayedFeeOnFirstSwap(
        uint24 rawStartFee,
        uint24 rawEndFee,
        uint64 rawDurationSeconds,
        uint32 rawElapsed
    ) public {
        uint24 startFee = uint24(bound(rawStartFee, 1, MAX_LP_FEE));
        uint24 endFee = uint24(bound(rawEndFee, 0, startFee - 1));
        uint64 durationSeconds = uint64(bound(rawDurationSeconds, 1, 200_000));
        uint256 elapsed = bound(uint256(rawElapsed), 1, uint256(durationSeconds) + 200_000);

        (bool isToken0,) = _createToken(bytes32(uint256(4)), startFee, endFee, durationSeconds);

        vm.warp(block.timestamp + elapsed);
        vm.recordLogs();
        _buyAsset(isToken0);
        Vm.Log[] memory logs = vm.getRecordedLogs();

        uint24 expectedFee = _expectedDecayFee(startFee, endFee, durationSeconds, elapsed);
        (,,, uint24 lpFeeAfter) = manager.getSlot0(poolId);
        assertEq(lpFeeAfter, expectedFee, "slot0 fee should equal decayed fee");

        uint24 observedSwapFee = _extractPoolManagerSwapFee(logs);
        assertEq(observedSwapFee, expectedFee, "swap should execute at decayed fee");

        (,,, uint24 lastFee,) = hook.getFeeScheduleOf(poolId);
        assertEq(lastFee, expectedFee, "stored lastFee should match computed fee");
    }

    function testFuzz_preStartSwap_RetainsStartFee(
        uint24 rawStartFee,
        uint24 rawEndFee,
        uint64 rawDurationSeconds,
        uint32 rawStartOffset,
        uint32 rawElapsedBeforeStart
    ) public {
        uint24 startFee = uint24(bound(rawStartFee, 1, MAX_LP_FEE));
        uint24 endFee = uint24(bound(rawEndFee, 0, startFee - 1));
        uint64 durationSeconds = uint64(bound(rawDurationSeconds, 1, 200_000));
        uint32 startOffset = uint32(bound(rawStartOffset, 1, 200_000));
        uint256 elapsedBeforeStart = bound(uint256(rawElapsedBeforeStart), 0, uint256(startOffset) - 1);

        uint32 startingTime = uint32(block.timestamp + startOffset);
        (bool isToken0,) =
            _createTokenWithStartTime(bytes32(uint256(5)), startFee, endFee, durationSeconds, startingTime);

        vm.warp(block.timestamp + elapsedBeforeStart);
        vm.recordLogs();
        _buyAsset(isToken0);
        Vm.Log[] memory logs = vm.getRecordedLogs();

        (,,, uint24 lpFeeAfter) = manager.getSlot0(poolId);
        assertEq(lpFeeAfter, startFee, "pre-start swap should keep start fee");

        uint24 observedSwapFee = _extractPoolManagerSwapFee(logs);
        assertEq(observedSwapFee, startFee, "pre-start swap should execute at start fee");

        (uint48 storedStart,,, uint24 lastFee,) = hook.getFeeScheduleOf(poolId);
        assertEq(storedStart, startingTime, "future start time should remain unchanged");
        assertEq(lastFee, startFee, "lastFee should remain at start fee before start");
    }

    function testFuzz_create_ClampsPastStartTime(
        uint24 rawStartFee,
        uint24 rawEndFee,
        uint64 rawDurationSeconds,
        uint32 rawPastOffset
    ) public {
        vm.warp(2_000_000_000);

        uint24 startFee = uint24(bound(rawStartFee, 1, MAX_LP_FEE));
        uint24 endFee = uint24(bound(rawEndFee, 0, startFee - 1));
        uint64 durationSeconds = uint64(bound(rawDurationSeconds, 1, 200_000));
        uint32 pastOffset = uint32(bound(rawPastOffset, 1, 200_000));
        uint32 pastStartingTime = uint32(block.timestamp - pastOffset);

        _createTokenWithStartTime(bytes32(uint256(6)), startFee, endFee, durationSeconds, pastStartingTime);

        (uint48 storedStart, uint24 storedStartFee, uint24 storedEndFee, uint24 lastFee, uint48 duration) =
            hook.getFeeScheduleOf(poolId);
        assertEq(storedStart, block.timestamp, "past schedule start should clamp to current timestamp");
        assertEq(storedStartFee, startFee, "unexpected start fee");
        assertEq(storedEndFee, endFee, "unexpected end fee");
        assertEq(lastFee, startFee, "lastFee should seed to start fee");
        assertEq(duration, durationSeconds, "unexpected duration");

        (,,, uint24 lpFeeAfterCreate) = manager.getSlot0(poolId);
        assertEq(lpFeeAfterCreate, startFee, "slot0 fee should be seeded to start fee");
    }

    function _extractPoolManagerSwapFee(Vm.Log[] memory logs) internal pure returns (uint24 fee) {
        bytes32 swapSig = keccak256("Swap(bytes32,address,int128,int128,uint160,uint128,int24,uint24)");

        for (uint256 i; i < logs.length; i++) {
            if (logs[i].topics.length > 0 && logs[i].topics[0] == swapSig) {
                (,,,,, fee) = abi.decode(logs[i].data, (int128, int128, uint160, uint128, int24, uint24));
                return fee;
            }
        }

        revert("swap event not found");
    }

    function _buyAsset(bool isToken0) internal {
        IPoolManager.SwapParams memory swapParams = IPoolManager.SwapParams({
            zeroForOne: !isToken0,
            amountSpecified: 1 ether,
            sqrtPriceLimitX96: !isToken0 ? TickMath.MIN_SQRT_PRICE + 1 : TickMath.MAX_SQRT_PRICE - 1
        });

        swapRouter.swap(poolKey, swapParams, PoolSwapTest.TestSettings(false, false), new bytes(0));
    }

    function _expectedDecayFee(
        uint24 startFee,
        uint24 endFee,
        uint64 durationSeconds,
        uint256 elapsed
    ) internal pure returns (uint24) {
        if (elapsed >= durationSeconds) {
            return endFee;
        }

        return uint24(uint256(startFee) - (uint256(startFee - endFee) * elapsed) / durationSeconds);
    }

    function _prepareInitData(
        address token,
        uint24 startFee,
        uint24 endFee,
        uint64 durationSeconds,
        uint32 startingTime
    ) internal returns (InitData memory) {
        Curve[] memory curves = new Curve[](10);
        int24 tickSpacing = 8;

        for (uint256 i; i < 10; ++i) {
            curves[i].tickLower = int24(uint24(i * 16_000));
            curves[i].tickUpper = 240_000;
            curves[i].numPositions = 10;
            curves[i].shares = WAD / 10;
        }

        Currency currency0 = Currency.wrap(address(numeraire));
        Currency currency1 = Currency.wrap(address(token));
        (currency0, currency1) = greaterThan(currency0, currency1) ? (currency1, currency0) : (currency0, currency1);

        poolKey = PoolKey({
            currency0: currency0,
            currency1: currency1,
            tickSpacing: tickSpacing,
            fee: LPFeeLibrary.DYNAMIC_FEE_FLAG,
            hooks: hook
        });
        poolId = poolKey.toId();

        return InitData({
            startFee: startFee,
            fee: endFee,
            durationSeconds: durationSeconds,
            tickSpacing: tickSpacing,
            curves: curves,
            beneficiaries: new BeneficiaryData[](0),
            startingTime: startingTime
        });
    }

    function _createToken(
        bytes32 salt,
        uint24 startFee,
        uint24 endFee,
        uint64 durationSeconds
    ) internal returns (bool isToken0, address asset) {
        return _createTokenWithStartTime(salt, startFee, endFee, durationSeconds, uint32(block.timestamp));
    }

    function _createTokenWithStartTime(
        bytes32 salt,
        uint24 startFee,
        uint24 endFee,
        uint64 durationSeconds,
        uint32 startingTime
    ) internal returns (bool isToken0, address asset) {
        string memory name = "Test Token";
        string memory symbol = "TEST";
        uint256 initialSupply = 1e27;

        address tokenAddress = vm.computeCreate2Address(
            salt,
            keccak256(
                abi.encodePacked(
                    type(DERC20).creationCode,
                    abi.encode(
                        name,
                        symbol,
                        initialSupply,
                        address(airlock),
                        address(airlock),
                        0,
                        0,
                        new address[](0),
                        new uint256[](0),
                        "TOKEN_URI"
                    )
                )
            ),
            address(tokenFactory)
        );

        InitData memory initData = _prepareInitData(tokenAddress, startFee, endFee, durationSeconds, startingTime);

        CreateParams memory params = CreateParams({
            initialSupply: initialSupply,
            numTokensToSell: initialSupply,
            numeraire: address(numeraire),
            tokenFactory: ITokenFactory(tokenFactory),
            tokenFactoryData: abi.encode(name, symbol, 0, 0, new address[](0), new uint256[](0), "TOKEN_URI"),
            governanceFactory: IGovernanceFactory(governanceFactory),
            governanceFactoryData: abi.encode("Test Token", 7200, 50_400, 0),
            poolInitializer: IPoolInitializer(initializer),
            poolInitializerData: abi.encode(initData),
            liquidityMigrator: ILiquidityMigrator(mockLiquidityMigrator),
            liquidityMigratorData: new bytes(0),
            integrator: address(0),
            salt: salt
        });

        (asset,,,,) = airlock.create(params);
        isToken0 = asset < address(numeraire);

        (,, poolKey,) = initializer.getState(asset);
        poolId = poolKey.toId();
        numeraire.approve(address(swapRouter), type(uint256).max);
    }

    function _createTokenWithStartTimeAndBeneficiaries(
        bytes32 salt,
        uint24 startFee,
        uint24 endFee,
        uint64 durationSeconds,
        uint32 startingTime,
        BeneficiaryData[] memory beneficiaries
    ) internal returns (bool isToken0, address asset) {
        string memory name = "Test Token";
        string memory symbol = "TEST";
        uint256 initialSupply = 1e27;

        address tokenAddress = vm.computeCreate2Address(
            salt,
            keccak256(
                abi.encodePacked(
                    type(DERC20).creationCode,
                    abi.encode(
                        name,
                        symbol,
                        initialSupply,
                        address(airlock),
                        address(airlock),
                        0,
                        0,
                        new address[](0),
                        new uint256[](0),
                        "TOKEN_URI"
                    )
                )
            ),
            address(tokenFactory)
        );

        InitData memory initData = _prepareInitData(tokenAddress, startFee, endFee, durationSeconds, startingTime);
        initData.beneficiaries = beneficiaries;

        CreateParams memory params = CreateParams({
            initialSupply: initialSupply,
            numTokensToSell: initialSupply,
            numeraire: address(numeraire),
            tokenFactory: ITokenFactory(tokenFactory),
            tokenFactoryData: abi.encode(name, symbol, 0, 0, new address[](0), new uint256[](0), "TOKEN_URI"),
            governanceFactory: IGovernanceFactory(governanceFactory),
            governanceFactoryData: abi.encode("Test Token", 7200, 50_400, 0),
            poolInitializer: IPoolInitializer(initializer),
            poolInitializerData: abi.encode(initData),
            liquidityMigrator: ILiquidityMigrator(mockLiquidityMigrator),
            liquidityMigratorData: new bytes(0),
            integrator: address(0),
            salt: salt
        });

        (asset,,,,) = airlock.create(params);
        isToken0 = asset < address(numeraire);

        (,, poolKey,) = initializer.getState(asset);
        poolId = poolKey.toId();
        numeraire.approve(address(swapRouter), type(uint256).max);
    }
}
