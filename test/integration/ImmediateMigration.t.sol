// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.13;

import { ERC20 } from "@solmate/tokens/ERC20.sol";
import { Deployers } from "@v4-core-test/utils/Deployers.sol";
import { IPoolManager } from "@v4-core/interfaces/IPoolManager.sol";
import { Hooks } from "@v4-core/libraries/Hooks.sol";
import { TickMath } from "@v4-core/libraries/TickMath.sol";
import { PoolSwapTest } from "@v4-core/test/PoolSwapTest.sol";
import { Currency } from "@v4-core/types/Currency.sol";
import { PoolKey } from "@v4-core/types/PoolKey.sol";

import { Airlock, CreateParams, Migrate, ModuleState } from "src/Airlock.sol";
import { ImmutableAirlock } from "src/base/ImmutableAirlock.sol";
import { NoOpGovernanceFactory } from "src/governance/NoOpGovernanceFactory.sol";
import { DopplerHookInitializer, InitData, PoolStatus } from "src/initializers/DopplerHookInitializer.sol";
import { ILiquidityMigrator } from "src/interfaces/ILiquidityMigrator.sol";
import { Curve } from "src/libraries/Multicurve.sol";
import { CloneERC20Factory } from "src/tokens/CloneERC20Factory.sol";
import { BeneficiaryData } from "src/types/BeneficiaryData.sol";
import { WAD } from "src/types/Wad.sol";

/// @dev Simple mock migrator that accepts tokens without doing anything
/// Used to test migration flow without actual liquidity migration
contract MockMigrator is ILiquidityMigrator, ImmutableAirlock {
    constructor(address airlock_) ImmutableAirlock(airlock_) { }

    receive() external payable { }

    function initialize(address, address, bytes calldata) external view onlyAirlock returns (address) {
        return address(this);
    }

    function migrate(uint160, address, address, address) external payable onlyAirlock returns (uint256) {
        // Just accept the tokens and ETH, do nothing
        return 0;
    }
}

/**
 * @title Immediate Migration Integration Test
 * @notice Tests the scenario where farTick = startTick, allowing immediate migration with zero proceeds.
 * This is a key requirement for prediction markets where migration should be gated by oracle, not by tick.
 */
contract ImmediateMigrationTest is Deployers {
    address internal constant AIRLOCK_OWNER = address(0xA111);

    Airlock public airlock;
    DopplerHookInitializer public initializer;
    CloneERC20Factory public tokenFactory;
    NoOpGovernanceFactory public governanceFactory;
    MockMigrator public migrator;

    address public asset;
    address public pool;
    address public governance;
    address public timelock;
    address public migrationPool;

    function setUp() public {
        // Deploy fresh Uniswap V4 manager and routers
        deployFreshManagerAndRouters();

        // Deploy Airlock
        airlock = new Airlock(AIRLOCK_OWNER);

        // Deploy and register TokenFactory
        tokenFactory = new CloneERC20Factory(address(airlock));
        _registerModule(address(tokenFactory), ModuleState.TokenFactory);

        // Deploy and register DopplerHookInitializer
        initializer = DopplerHookInitializer(
            payable(address(
                    uint160(
                        Hooks.BEFORE_INITIALIZE_FLAG | Hooks.AFTER_ADD_LIQUIDITY_FLAG
                            | Hooks.AFTER_REMOVE_LIQUIDITY_FLAG | Hooks.BEFORE_SWAP_FLAG
                            | Hooks.AFTER_SWAP_FLAG | Hooks.AFTER_SWAP_RETURNS_DELTA_FLAG
                    ) ^ (0x4444 << 144)
                ))
        );
        deployCodeTo("DopplerHookInitializer", abi.encode(address(airlock), address(manager)), address(initializer));
        _registerModule(address(initializer), ModuleState.PoolInitializer);

        // Deploy and register NoOpGovernanceFactory
        governanceFactory = new NoOpGovernanceFactory();
        _registerModule(address(governanceFactory), ModuleState.GovernanceFactory);

        // Deploy and register MockMigrator (accepts tokens without migration)
        migrator = new MockMigrator(address(airlock));
        _registerModule(address(migrator), ModuleState.LiquidityMigrator);
    }

    function _registerModule(address module, ModuleState state) internal {
        address[] memory modules = new address[](1);
        modules[0] = module;
        ModuleState[] memory states = new ModuleState[](1);
        states[0] = state;
        vm.prank(AIRLOCK_OWNER);
        airlock.setModuleState(modules, states);
    }

    /**
     * @notice Test: Create and immediately migrate with farTick = startTick (zero proceeds)
     * @dev This tests the key scenario for prediction markets where:
     *      1. Pool is created with farTick equal to startTick
     *      2. Migration can happen immediately without any swaps
     *      3. Airlock handles zero proceeds gracefully
     *      4. All asset tokens are returned to migrator (none sold)
     */
    function test_createAndMigrateImmediately_ZeroProceeds() public {
        uint256 numTokensToSell = 1e23;
        uint256 initialSupply = 1e23;

        // Prepare curves that start at tick 160,000
        Curve[] memory curves = new Curve[](1);
        curves[0] = Curve({ tickLower: 160_000, tickUpper: 240_000, numPositions: 10, shares: WAD });

        // Set farTick = startTick (160,000 for token1 asset)
        // This means migration can happen immediately
        int24 startTick = 160_000; // lowerTickBoundary for isToken0=false
        int24 farTick = startTick; // KEY: farTick == startTick

        bytes memory poolInitializerData = abi.encode(
            InitData({
                fee: 0,
                tickSpacing: 8,
                curves: curves,
                beneficiaries: new BeneficiaryData[](0),
                dopplerHook: address(0),
                onInitializationDopplerHookCalldata: new bytes(0),
                graduationDopplerHookCalldata: new bytes(0),
                farTick: farTick // Will be negated for isToken0=false
            })
        );

        bytes memory tokenFactoryData = abi.encode(
            "Immediate Migration Test Token",
            "IMMT",
            0, // yearlyMintRate
            0, // vestingDuration
            new address[](0),
            new uint256[](0),
            "TOKEN_URI"
        );

        CreateParams memory createParams = CreateParams({
            initialSupply: initialSupply,
            numTokensToSell: numTokensToSell,
            numeraire: address(0), // ETH as numeraire
            tokenFactory: tokenFactory,
            tokenFactoryData: tokenFactoryData,
            governanceFactory: governanceFactory,
            governanceFactoryData: new bytes(0),
            poolInitializer: initializer,
            poolInitializerData: poolInitializerData,
            liquidityMigrator: migrator,
            liquidityMigratorData: new bytes(0),
            integrator: address(0),
            salt: bytes32(uint256(1))
        });

        // Step 1: Create the token and pool
        (asset, pool, governance, timelock, migrationPool) = airlock.create(createParams);

        // Verify pool was created and is in Initialized state
        (,,,, PoolStatus status,,) = initializer.getState(asset);
        assertEq(uint8(status), uint8(PoolStatus.Initialized), "Pool should be Initialized");

        // Record balances before migration
        uint256 airlockAssetBalanceBefore = ERC20(asset).balanceOf(address(airlock));
        uint256 migratorAssetBalanceBefore = ERC20(asset).balanceOf(address(migrator));
        uint256 migratorEthBalanceBefore = address(migrator).balance;

        // Step 2: Migrate IMMEDIATELY - no swaps, zero proceeds
        // This should succeed because farTick = startTick
        vm.expectEmit(true, true, false, false);
        emit Migrate(asset, migrationPool);
        airlock.migrate(asset);

        // Step 3: Verify migration succeeded
        (,,,, PoolStatus statusAfter,,) = initializer.getState(asset);
        assertEq(uint8(statusAfter), uint8(PoolStatus.Exited), "Pool should be Exited after migration");

        // Step 4: Verify token distribution
        // - Migrator should have received ALL asset tokens (none sold)
        // - Migrator should have received ZERO ETH (no proceeds)
        uint256 migratorAssetBalanceAfter = ERC20(asset).balanceOf(address(migrator));
        uint256 migratorEthBalanceAfter = address(migrator).balance;

        // All tokens should go to migrator since none were sold
        // Note: There's a small amount of rounding dust (~20 tokens) that gets lost
        // due to Uniswap V4 liquidity position rounding across 10 slugs
        uint256 tokensReceived = migratorAssetBalanceAfter - migratorAssetBalanceBefore;
        uint256 dustAllowance = 100; // Allow up to 100 wei of rounding dust
        assertApproxEqAbs(
            tokensReceived,
            numTokensToSell,
            dustAllowance,
            "Migrator should receive all unsold tokens (minus rounding dust)"
        );

        // Zero ETH should be transferred (no trading happened)
        assertEq(migratorEthBalanceAfter, migratorEthBalanceBefore, "Migrator should receive zero ETH");

        // Airlock should have zero asset balance
        assertEq(ERC20(asset).balanceOf(address(airlock)), 0, "Airlock should have zero asset balance");

        // No fees should be recorded (no trading)
        assertEq(airlock.getProtocolFees(address(0)), 0, "No ETH protocol fees");
        assertEq(airlock.getProtocolFees(asset), 0, "No asset protocol fees");
    }

    /**
     * @notice Test: Create, do some swaps, then migrate when farTick = startTick
     * @dev Even with farTick = startTick, swaps can still happen and generate proceeds.
     *      Migration succeeds immediately because tick check passes at startTick.
     */
    function test_createSwapAndMigrate_WithProceeds() public {
        uint256 numTokensToSell = 1e23;
        uint256 initialSupply = 1e23;

        Curve[] memory curves = new Curve[](1);
        curves[0] = Curve({ tickLower: 160_000, tickUpper: 240_000, numPositions: 10, shares: WAD });

        // farTick = startTick
        int24 farTick = 160_000;

        bytes memory poolInitializerData = abi.encode(
            InitData({
                fee: 3000, // 0.3% fee to generate fees
                tickSpacing: 8,
                curves: curves,
                beneficiaries: new BeneficiaryData[](0),
                dopplerHook: address(0),
                onInitializationDopplerHookCalldata: new bytes(0),
                graduationDopplerHookCalldata: new bytes(0),
                farTick: farTick
            })
        );

        bytes memory tokenFactoryData =
            abi.encode("Swap Test Token", "SWPT", 0, 0, new address[](0), new uint256[](0), "TOKEN_URI");

        CreateParams memory createParams = CreateParams({
            initialSupply: initialSupply,
            numTokensToSell: numTokensToSell,
            numeraire: address(0),
            tokenFactory: tokenFactory,
            tokenFactoryData: tokenFactoryData,
            governanceFactory: governanceFactory,
            governanceFactoryData: new bytes(0),
            poolInitializer: initializer,
            poolInitializerData: poolInitializerData,
            liquidityMigrator: migrator,
            liquidityMigratorData: new bytes(0),
            integrator: address(0),
            salt: bytes32(uint256(2))
        });

        // Create
        (asset, pool, governance, timelock, migrationPool) = airlock.create(createParams);

        // Get pool key for swapping
        (,,,, PoolStatus status, PoolKey memory poolKey,) = initializer.getState(asset);
        assertEq(uint8(status), uint8(PoolStatus.Initialized), "Pool should be Initialized");

        // Do a swap - buy some asset tokens with ETH
        uint256 swapAmount = 0.1 ether;
        deal(address(this), swapAmount);

        bool isToken0 = asset == Currency.unwrap(poolKey.currency0);

        IPoolManager.SwapParams memory swapParams = IPoolManager.SwapParams({
            zeroForOne: !isToken0, // Buying asset (numeraire -> asset)
            amountSpecified: -int256(swapAmount), // Exact input
            sqrtPriceLimitX96: !isToken0 ? TickMath.MIN_SQRT_PRICE + 1 : TickMath.MAX_SQRT_PRICE - 1
        });

        swapRouter.swap{ value: swapAmount }(poolKey, swapParams, PoolSwapTest.TestSettings(false, false), "");

        // Record migrator balance before migration
        uint256 migratorEthBefore = address(migrator).balance;
        uint256 migratorAssetBefore = ERC20(asset).balanceOf(address(migrator));

        // Migrate - should still work immediately since farTick = startTick
        airlock.migrate(asset);

        // Verify migration succeeded
        (,,,, PoolStatus statusAfter,,) = initializer.getState(asset);
        assertEq(uint8(statusAfter), uint8(PoolStatus.Exited), "Pool should be Exited");

        // Migrator should have received some ETH (proceeds from swap minus fees)
        uint256 migratorEthAfter = address(migrator).balance;
        assertGt(migratorEthAfter, migratorEthBefore, "Migrator should receive ETH proceeds");

        // Migrator should have received remaining asset tokens (not all, since some were sold)
        uint256 migratorAssetAfter = ERC20(asset).balanceOf(address(migrator));
        assertGt(migratorAssetAfter, migratorAssetBefore, "Migrator should receive unsold tokens");
        assertLt(
            migratorAssetAfter - migratorAssetBefore,
            numTokensToSell,
            "Not all tokens should be returned (some were sold)"
        );
    }
}
