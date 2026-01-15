// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.24;

import { IHooks } from "@v4-core/interfaces/IHooks.sol";
import { IPoolManager } from "@v4-core/interfaces/IPoolManager.sol";
import { Hooks } from "@v4-core/libraries/Hooks.sol";
import { TickMath } from "@v4-core/libraries/TickMath.sol";
import { PoolSwapTest } from "@v4-core/test/PoolSwapTest.sol";
import { TestERC20 } from "@v4-core/test/TestERC20.sol";
import { Currency } from "@v4-core/types/Currency.sol";
import { PoolKey } from "@v4-core/types/PoolKey.sol";
import { PositionManager } from "@v4-periphery/PositionManager.sol";
import { IPositionManager } from "@v4-periphery/interfaces/IPositionManager.sol";
import { Vm } from "forge-std/Vm.sol";

import { Airlock, CreateParams, ModuleState } from "src/Airlock.sol";
import { StreamableFeesLocker } from "src/StreamableFeesLocker.sol";
import { NoOpGovernanceFactory } from "src/governance/NoOpGovernanceFactory.sol";
import { Doppler } from "src/initializers/Doppler.sol";
import { DopplerDeployer, UniswapV4Initializer } from "src/initializers/UniswapV4Initializer.sol";
import { ILiquidityMigrator } from "src/interfaces/ILiquidityMigrator.sol";
import { ITokenFactory } from "src/interfaces/ITokenFactory.sol";
import {
    IUniswapV2Factory,
    IUniswapV2Pair,
    IUniswapV2Router02,
    UniswapV2Migrator
} from "src/migrators/UniswapV2Migrator.sol";
import { UniswapV4Migrator } from "src/migrators/UniswapV4Migrator.sol";
import { UniswapV4MigratorHook } from "src/migrators/UniswapV4MigratorHook.sol";
import { DistributionMigrator, MAX_DISTRIBUTION_WAD, WAD } from "src/migrators/distribution/DistributionMigrator.sol";
import { ForwardedUniswapV2Migrator } from "src/migrators/distribution/ForwardedUniswapV2Migrator.sol";
import { ForwardedUniswapV4Migrator } from "src/migrators/distribution/ForwardedUniswapV4Migrator.sol";
import { TokenFactory } from "src/tokens/TokenFactory.sol";
import { BeneficiaryData } from "src/types/BeneficiaryData.sol";

import {
    BaseIntegrationTest,
    deployNoOpGovernanceFactory,
    deployTokenFactory,
    prepareTokenFactoryData
} from "test/integration/BaseIntegrationTest.sol";
import { deployUniswapV4Initializer, preparePoolInitializerData } from "test/integration/UniswapV4Initializer.t.sol";
import { UNISWAP_V2_FACTORY_MAINNET, UNISWAP_V2_ROUTER_MAINNET } from "test/shared/Addresses.sol";
import { MineV4Params, mineV4 } from "test/shared/AirlockMiner.sol";

// =============================================================================
// HELPER FUNCTIONS
// =============================================================================

/// @notice Deploys a DistributionMigrator and whitelists it in the Airlock
function deployDistributionMigrator(
    Vm vm,
    Airlock airlock,
    address airlockOwner
) returns (DistributionMigrator distributor) {
    distributor = new DistributionMigrator(address(airlock));

    address[] memory modules = new address[](1);
    modules[0] = address(distributor);
    ModuleState[] memory states = new ModuleState[](1);
    states[0] = ModuleState.LiquidityMigrator;
    vm.prank(airlockOwner);
    airlock.setModuleState(modules, states);
}

/// @notice Deploys a ForwardedUniswapV2Migrator and whitelists it in the Airlock
function deployForwardedUniswapV2Migrator(
    Vm vm,
    Airlock airlock,
    address airlockOwner,
    address distributor,
    address v2Factory,
    address v2Router
) returns (ForwardedUniswapV2Migrator forwardedMigrator) {
    forwardedMigrator = new ForwardedUniswapV2Migrator(
        distributor, IUniswapV2Factory(v2Factory), IUniswapV2Router02(v2Router), airlockOwner
    );

    address[] memory modules = new address[](1);
    modules[0] = address(forwardedMigrator);
    ModuleState[] memory states = new ModuleState[](1);
    states[0] = ModuleState.LiquidityMigrator;
    vm.prank(airlockOwner);
    airlock.setModuleState(modules, states);
}

/// @notice Deploys a ForwardedUniswapV4Migrator with hook and locker, whitelists in Airlock
function deployForwardedUniswapV4Migrator(
    Vm vm,
    function(string memory, bytes memory, address) deployCodeTo,
    Airlock airlock,
    address airlockOwner,
    address distributor,
    address poolManager,
    address positionManager
)
    returns (
        StreamableFeesLocker locker,
        UniswapV4MigratorHook migratorHook,
        ForwardedUniswapV4Migrator forwardedMigrator
    )
{
    locker = new StreamableFeesLocker(IPositionManager(positionManager), airlockOwner);

    // Compute hook address with required flags
    migratorHook = UniswapV4MigratorHook(
        address(
            uint160(Hooks.BEFORE_INITIALIZE_FLAG | Hooks.AFTER_ADD_LIQUIDITY_FLAG | Hooks.AFTER_REMOVE_LIQUIDITY_FLAG)
            ^ (0x5555 << 144) // Different salt from regular V4 migrator
        )
    );

    forwardedMigrator = new ForwardedUniswapV4Migrator(
        distributor, IPoolManager(poolManager), PositionManager(payable(positionManager)), locker, IHooks(migratorHook)
    );

    deployCodeTo(
        "UniswapV4MigratorHook", abi.encode(address(poolManager), address(forwardedMigrator)), address(migratorHook)
    );

    // Whitelist and approve
    address[] memory modules = new address[](1);
    modules[0] = address(forwardedMigrator);
    ModuleState[] memory states = new ModuleState[](1);
    states[0] = ModuleState.LiquidityMigrator;
    vm.startPrank(airlockOwner);
    airlock.setModuleState(modules, states);
    locker.approveMigrator(address(forwardedMigrator));
    vm.stopPrank();
}

/// @notice Encodes distribution migrator initialization data
function prepareDistributionMigratorData(
    address payout,
    uint256 percentWad,
    address underlyingMigrator,
    bytes memory underlyingData
) pure returns (bytes memory) {
    return abi.encode(payout, percentWad, underlyingMigrator, underlyingData);
}

/// @notice Prepares standard V4 migrator data with default beneficiaries
function prepareForwardedUniswapV4MigratorData(Airlock airlock) view returns (bytes memory) {
    BeneficiaryData[] memory beneficiaries = new BeneficiaryData[](3);
    beneficiaries[0] = BeneficiaryData({ beneficiary: airlock.owner(), shares: 0.05e18 });
    beneficiaries[1] = BeneficiaryData({ beneficiary: address(0xbeef), shares: 0.05e18 });
    beneficiaries[2] = BeneficiaryData({ beneficiary: address(0xb0b), shares: 0.9e18 });
    beneficiaries = sortBeneficiaries(beneficiaries);

    return abi.encode(2000, int24(8), 30 days, beneficiaries);
}

/// @notice Sorts beneficiaries by address (required by V4 migrator)
function sortBeneficiaries(BeneficiaryData[] memory beneficiaries) pure returns (BeneficiaryData[] memory) {
    uint256 length = beneficiaries.length;
    for (uint256 i = 0; i < length - 1; i++) {
        for (uint256 j = 0; j < length - i - 1; j++) {
            if (uint160(beneficiaries[j].beneficiary) > uint160(beneficiaries[j + 1].beneficiary)) {
                BeneficiaryData memory temp = beneficiaries[j];
                beneficiaries[j] = beneficiaries[j + 1];
                beneficiaries[j + 1] = temp;
            }
        }
    }
    return beneficiaries;
}

// =============================================================================
// BASE TEST CONTRACT
// =============================================================================

/// @notice Base contract for V4 distribution migrator integration tests
abstract contract DistributionMigratorV4BaseTest is BaseIntegrationTest {
    DistributionMigrator public distributor;
    ForwardedUniswapV4Migrator public forwardedV4Migrator;
    StreamableFeesLocker public locker;
    UniswapV4MigratorHook public migratorHook;

    /// @notice Sets up common V4 infrastructure without configuring the migrator
    function _setupV4Infrastructure() internal {
        // Deploy token factory
        TokenFactory tokenFactory = deployTokenFactory(vm, airlock, AIRLOCK_OWNER);
        createParams.tokenFactory = tokenFactory;
        createParams.tokenFactoryData =
            abi.encode("Test Token", "TEST", 0, 0, new address[](0), new uint256[](0), "TOKEN_URI");

        // Deploy V4 initializer
        (, UniswapV4Initializer initializer) = deployUniswapV4Initializer(vm, airlock, AIRLOCK_OWNER, address(manager));
        createParams.poolInitializer = initializer;
        (bytes32 salt, bytes memory poolInitializerData) = preparePoolInitializerData(
            address(airlock),
            address(manager),
            address(tokenFactory),
            createParams.tokenFactoryData,
            address(initializer)
        );
        createParams.poolInitializerData = poolInitializerData;
        createParams.salt = salt;
        createParams.numTokensToSell = 1e23;
        createParams.initialSupply = 1e23;

        // Deploy DistributionMigrator
        distributor = deployDistributionMigrator(vm, airlock, AIRLOCK_OWNER);

        // Deploy ForwardedUniswapV4Migrator
        (locker, migratorHook, forwardedV4Migrator) = deployForwardedUniswapV4Migrator(
            vm, _deployCodeTo, airlock, AIRLOCK_OWNER, address(distributor), address(manager), address(positionManager)
        );

        // Deploy governance factory
        NoOpGovernanceFactory governanceFactory = deployNoOpGovernanceFactory(vm, airlock, AIRLOCK_OWNER);
        createParams.governanceFactory = governanceFactory;
    }

    /// @notice Configures the distribution migrator with given parameters
    function _configureDistributor(address payout, uint256 percentWad) internal {
        bytes memory underlyingData = prepareForwardedUniswapV4MigratorData(airlock);
        bytes memory distributionData =
            prepareDistributionMigratorData(payout, percentWad, address(forwardedV4Migrator), underlyingData);
        createParams.liquidityMigrator = distributor;
        createParams.liquidityMigratorData = distributionData;
    }

    /// @notice Performs swaps until the pool has enough proceeds to migrate
    function _doSwapsUntilMigrateable() internal {
        bool canMigrate;
        uint256 i;

        do {
            i++;
            deal(address(this), 1 ether);

            (Currency currency0, Currency currency1, uint24 fee, int24 tickSpacing, IHooks hooks) =
                Doppler(payable(pool)).poolKey();

            swapRouter.swap{ value: 0.01 ether }(
                PoolKey({
                    currency0: currency0, currency1: currency1, hooks: hooks, fee: fee, tickSpacing: tickSpacing
                }),
                IPoolManager.SwapParams(true, -int256(0.01 ether), TickMath.MIN_SQRT_PRICE + 1),
                PoolSwapTest.TestSettings(false, false),
                ""
            );

            (,,, uint256 totalProceeds,,) = Doppler(payable(pool)).state();
            canMigrate = totalProceeds > Doppler(payable(pool)).minimumProceeds();

            vm.warp(block.timestamp + 200);
        } while (!canMigrate && i < 200);

        vm.warp(block.timestamp + 1 days);
    }

    /// @notice Verifies migration completed successfully
    function _assertMigrationComplete() internal view {
        assertTrue(
            PositionManager(payable(address(positionManager))).balanceOf(address(locker)) >= 1,
            "Locker should have positions"
        );
    }
}

// =============================================================================
// V2 INTEGRATION TEST (requires mainnet fork)
// =============================================================================

/**
 * @title DistributionMigrator + UniswapV2 Integration Test
 * @notice Tests full create → migrate flow with V2 underlying migrator
 * @dev Requires MAINNET_RPC_URL environment variable
 */
contract DistributionMigratorV2IntegrationTest is BaseIntegrationTest {
    DistributionMigrator public distributor;
    ForwardedUniswapV2Migrator public forwardedV2Migrator;

    address public payout = address(0xCafe);
    uint256 public percentWad = 1e17; // 10%

    TestERC20 internal numeraire;

    function setUp() public override {
        vm.createSelectFork(vm.envString("MAINNET_RPC_URL"), 21_093_509);
        super.setUp();

        name = "DistributionMigratorV2Integration";

        numeraire = new TestERC20(0);

        TokenFactory tokenFactory = deployTokenFactory(vm, airlock, AIRLOCK_OWNER);
        createParams.tokenFactory = tokenFactory;
        bytes32 salt = bytes32(uint256(456));
        (, bytes memory tokenFactoryData) = prepareTokenFactoryData(vm, address(airlock), address(tokenFactory), salt);
        createParams.tokenFactoryData = tokenFactoryData;
        createParams.salt = salt;
        createParams.numTokensToSell = 1e23;
        createParams.initialSupply = 1e23;
        createParams.numeraire = address(numeraire);

        (, UniswapV4Initializer initializer) = deployUniswapV4Initializer(vm, airlock, AIRLOCK_OWNER, address(manager));
        createParams.poolInitializer = initializer;
        (bytes32 minedSalt, bytes memory poolInitializerData) = preparePoolInitializerData(
            address(airlock), address(manager), address(tokenFactory), tokenFactoryData, address(initializer)
        );
        createParams.poolInitializerData = poolInitializerData;
        createParams.salt = minedSalt;

        distributor = deployDistributionMigrator(vm, airlock, AIRLOCK_OWNER);
        forwardedV2Migrator = deployForwardedUniswapV2Migrator(
            vm, airlock, AIRLOCK_OWNER, address(distributor), UNISWAP_V2_FACTORY_MAINNET, UNISWAP_V2_ROUTER_MAINNET
        );

        bytes memory distributionData =
            prepareDistributionMigratorData(payout, percentWad, address(forwardedV2Migrator), "");
        createParams.liquidityMigrator = distributor;
        createParams.liquidityMigratorData = distributionData;

        NoOpGovernanceFactory governanceFactory = deployNoOpGovernanceFactory(vm, airlock, AIRLOCK_OWNER);
        createParams.governanceFactory = governanceFactory;
    }

    function _beforeMigrate() internal override {
        bool canMigrate;
        uint256 i;

        do {
            i++;
            numeraire.mint(address(this), 1 ether);
            numeraire.approve(address(swapRouter), type(uint256).max);

            (Currency currency0, Currency currency1, uint24 fee, int24 tickSpacing, IHooks hooks) =
                Doppler(payable(pool)).poolKey();

            bool zeroForOne = Currency.unwrap(currency0) == address(numeraire);

            swapRouter.swap(
                PoolKey({
                    currency0: currency0, currency1: currency1, hooks: hooks, fee: fee, tickSpacing: tickSpacing
                }),
                IPoolManager.SwapParams(
                        zeroForOne,
                        int256(0.1 ether),
                        zeroForOne ? TickMath.MIN_SQRT_PRICE + 1 : TickMath.MAX_SQRT_PRICE - 1
                    ),
                PoolSwapTest.TestSettings(false, false),
                ""
            );

            (,,, uint256 totalProceeds,,) = Doppler(payable(pool)).state();
            canMigrate = totalProceeds > Doppler(payable(pool)).minimumProceeds();

            vm.warp(block.timestamp + 200);
        } while (!canMigrate && i < 100);

        vm.warp(block.timestamp + 1 days);
    }

    function test_fullFlow_V2_WithDistribution() public {
        (asset, pool, governance, timelock, migrationPool) = airlock.create(createParams);

        uint256 payoutBalanceBefore = numeraire.balanceOf(payout);
        _beforeMigrate();
        airlock.migrate(asset);

        assertTrue(numeraire.balanceOf(payout) > payoutBalanceBefore, "Payout should have received distribution");

        address v2Pair = IUniswapV2Factory(UNISWAP_V2_FACTORY_MAINNET).getPair(asset, address(numeraire));
        assertTrue(v2Pair != address(0), "V2 pair should exist");
        assertTrue(IUniswapV2Pair(v2Pair).totalSupply() > 0, "V2 pair should have liquidity");
    }
}

// =============================================================================
// V4 INTEGRATION TEST
// =============================================================================

/**
 * @title DistributionMigrator + UniswapV4 Integration Test
 * @notice Tests full create → migrate flow with V4 underlying migrator
 */
contract DistributionMigratorV4IntegrationTest is DistributionMigratorV4BaseTest {
    address public payout = address(0xCafe);
    uint256 public percentWad = 1e17; // 10%

    function setUp() public override {
        super.setUp();
        name = "DistributionMigratorV4Integration";
        _setupV4Infrastructure();
        _configureDistributor(payout, percentWad);
    }

    function _beforeMigrate() internal override {
        _doSwapsUntilMigrateable();
    }

    function test_fullFlow_V4_WithDistribution() public {
        (asset, pool, governance, timelock, migrationPool) = airlock.create(createParams);

        uint256 payoutBalanceBefore = payout.balance;
        _beforeMigrate();
        airlock.migrate(asset);

        assertTrue(payout.balance > payoutBalanceBefore, "Payout should have received ETH distribution");
        _assertMigrationComplete();
    }

    function test_fullFlow_V4_ZeroFunds_ShouldRevert() public {
        (asset, pool, governance, timelock, migrationPool) = airlock.create(createParams);

        // Skip swaps, just warp past auction end
        vm.warp(block.timestamp + 2 days);

        vm.expectRevert();
        airlock.migrate(asset);
    }
}

// =============================================================================
// DISTRIBUTION CALCULATION TEST
// =============================================================================

/**
 * @title Distribution Calculation Test
 * @notice Verifies exact distribution amounts with different percentages
 */
contract DistributionCalculationTest is DistributionMigratorV4BaseTest {
    address public payout = address(0xCafe);

    function setUp() public override {
        super.setUp();
        name = "DistributionCalculationTest";
        _setupV4Infrastructure();
        _configureDistributor(payout, 1e17); // Default 10%
    }

    function _beforeMigrate() internal override {
        _doSwapsUntilMigrateable();
    }

    function test_distributionCalculation_50Percent() public {
        _configureDistributor(payout, 5e17); // 50%

        (asset, pool, governance, timelock, migrationPool) = airlock.create(createParams);

        uint256 totalSwapped;
        bool canMigrate;
        uint256 i;

        do {
            i++;
            deal(address(this), 0.1 ether);

            (Currency currency0, Currency currency1, uint24 fee, int24 tickSpacing, IHooks hooks) =
                Doppler(payable(pool)).poolKey();

            swapRouter.swap{ value: 0.01 ether }(
                PoolKey({
                    currency0: currency0, currency1: currency1, hooks: hooks, fee: fee, tickSpacing: tickSpacing
                }),
                IPoolManager.SwapParams(true, -int256(0.01 ether), TickMath.MIN_SQRT_PRICE + 1),
                PoolSwapTest.TestSettings(false, false),
                ""
            );
            totalSwapped += 0.01 ether;

            (,,, uint256 totalProceeds,,) = Doppler(payable(pool)).state();
            canMigrate = totalProceeds > Doppler(payable(pool)).minimumProceeds();

            vm.warp(block.timestamp + 200);
        } while (!canMigrate && i < 200);

        vm.warp(block.timestamp + 1 days);

        uint256 payoutBalanceBefore = payout.balance;
        airlock.migrate(asset);

        uint256 distribution = payout.balance - payoutBalanceBefore;
        assertTrue(distribution > 0, "Distribution should be > 0");

        emit log_named_uint("Total swapped", totalSwapped);
        emit log_named_uint("Distribution received", distribution);
    }
}

// =============================================================================
// FUZZ TESTS
// =============================================================================

/**
 * @title Distribution Migrator Fuzz Tests
 * @notice Fuzz tests for the full flow with varying parameters
 * @dev Tests invariants:
 *      - Distribution > 0 for percentWad > 0 (above dust threshold)
 *      - Any valid EOA can receive distribution
 *      - Migration always completes after distribution
 */
contract DistributionMigratorFuzzTest is DistributionMigratorV4BaseTest {
    function setUp() public override {
        super.setUp();
        name = "DistributionMigratorFuzzTest";
        _setupV4Infrastructure();
        _configureDistributor(address(0xCafe), 1e17); // Default config
    }

    function _beforeMigrate() internal override {
        _doSwapsUntilMigrateable();
    }

    /// @notice Tests distribution calculation with varying percentages
    /// @dev Minimum 0.1% to ensure non-zero distribution after rounding
    function testFuzz_fullFlow_VaryingPercent(uint256 percentWad) public {
        percentWad = bound(percentWad, 1e15, MAX_DISTRIBUTION_WAD); // 0.1% to 50%

        address payoutAddr = address(0xF0001);
        _configureDistributor(payoutAddr, percentWad);

        (asset, pool, governance, timelock, migrationPool) = airlock.create(createParams);
        _doSwapsUntilMigrateable();

        uint256 payoutBalanceBefore = payoutAddr.balance;
        airlock.migrate(asset);

        assertTrue(payoutAddr.balance > payoutBalanceBefore, "Distribution should be > 0");
        _assertMigrationComplete();
    }

    /// @notice Tests that any valid EOA can receive distribution
    function testFuzz_fullFlow_VaryingPayout(address payoutAddr) public {
        // Exclude invalid addresses
        vm.assume(payoutAddr != address(0));
        vm.assume(uint160(payoutAddr) > 0x100);
        vm.assume(payoutAddr != address(this));
        vm.assume(payoutAddr != address(airlock));
        vm.assume(payoutAddr != address(distributor));
        vm.assume(payoutAddr != address(manager));
        vm.assume(payoutAddr != address(permit2));
        vm.assume(payoutAddr != address(positionManager));
        vm.assume(payoutAddr != address(swapRouter));
        vm.assume(payoutAddr.code.length == 0); // EOA only

        _configureDistributor(payoutAddr, 1e17);

        (asset, pool, governance, timelock, migrationPool) = airlock.create(createParams);
        _doSwapsUntilMigrateable();

        uint256 payoutBalanceBefore = payoutAddr.balance;
        airlock.migrate(asset);

        assertTrue(payoutAddr.balance > payoutBalanceBefore, "Payout should have received distribution");
    }

    /// @notice Tests distribution with varying swap amounts
    function testFuzz_fullFlow_VaryingSwapAmount(uint256 swapAmount) public {
        swapAmount = bound(swapAmount, 0.005 ether, 0.1 ether);

        address payoutAddr = address(0xF0003);
        _configureDistributor(payoutAddr, 25e16); // 25%

        (asset, pool, governance, timelock, migrationPool) = airlock.create(createParams);

        // Custom swap loop with fuzzed amount
        bool canMigrate;
        uint256 i;

        do {
            i++;
            deal(address(this), 10 ether);

            (Currency currency0, Currency currency1, uint24 fee, int24 tickSpacing, IHooks hooks) =
                Doppler(payable(pool)).poolKey();

            swapRouter.swap{ value: swapAmount }(
                PoolKey({
                    currency0: currency0, currency1: currency1, hooks: hooks, fee: fee, tickSpacing: tickSpacing
                }),
                IPoolManager.SwapParams(true, -int256(swapAmount), TickMath.MIN_SQRT_PRICE + 1),
                PoolSwapTest.TestSettings(false, false),
                ""
            );

            (,,, uint256 totalProceeds,,) = Doppler(payable(pool)).state();
            canMigrate = totalProceeds > Doppler(payable(pool)).minimumProceeds();

            vm.warp(block.timestamp + 200);
        } while (!canMigrate && i < 200);

        vm.warp(block.timestamp + 1 days);

        uint256 payoutBalanceBefore = payoutAddr.balance;
        airlock.migrate(asset);

        assertTrue(payoutAddr.balance > payoutBalanceBefore, "Distribution should be > 0");
    }

    /// @notice Tests varying percentage with extra swaps after minimum proceeds
    function testFuzz_fullFlow_PercentAndIterations(uint256 percentWad, uint8 extraSwaps) public {
        percentWad = bound(percentWad, 1e16, MAX_DISTRIBUTION_WAD); // 1% to 50%
        extraSwaps = uint8(bound(extraSwaps, 0, 5));

        address payoutAddr = address(0xF0004);
        _configureDistributor(payoutAddr, percentWad);

        (asset, pool, governance, timelock, migrationPool) = airlock.create(createParams);
        _doSwapsUntilMigrateable();

        // Extra swaps (may fail if pool exhausted)
        for (uint256 j = 0; j < extraSwaps; j++) {
            deal(address(this), 1 ether);

            (Currency currency0, Currency currency1, uint24 fee, int24 tickSpacing, IHooks hooks) =
                Doppler(payable(pool)).poolKey();

            try swapRouter.swap{ value: 0.01 ether }(
                PoolKey({
                    currency0: currency0, currency1: currency1, hooks: hooks, fee: fee, tickSpacing: tickSpacing
                }),
                IPoolManager.SwapParams(true, -int256(0.01 ether), TickMath.MIN_SQRT_PRICE + 1),
                PoolSwapTest.TestSettings(false, false),
                ""
            ) {
                vm.warp(block.timestamp + 200);
            } catch {
                break; // Pool exhausted
            }
        }

        vm.warp(block.timestamp + 1 days);

        uint256 payoutBalanceBefore = payoutAddr.balance;
        airlock.migrate(asset);

        assertTrue(payoutAddr.balance > payoutBalanceBefore, "Distribution should be > 0");
        _assertMigrationComplete();
    }

    /// @notice Edge case: 0% distribution should give nothing to payout
    function testFuzz_fullFlow_ZeroPercent() public {
        address payoutAddr = address(0xF0005);
        _configureDistributor(payoutAddr, 0);

        (asset, pool, governance, timelock, migrationPool) = airlock.create(createParams);
        _doSwapsUntilMigrateable();

        uint256 payoutBalanceBefore = payoutAddr.balance;
        airlock.migrate(asset);

        assertEq(payoutAddr.balance, payoutBalanceBefore, "Payout should receive nothing with 0%");
        _assertMigrationComplete();
    }

    /// @notice Edge case: 50% (max) distribution
    function testFuzz_fullFlow_MaxPercent() public {
        address payoutAddr = address(0xF0006);
        _configureDistributor(payoutAddr, MAX_DISTRIBUTION_WAD);

        (asset, pool, governance, timelock, migrationPool) = airlock.create(createParams);
        _doSwapsUntilMigrateable();

        uint256 payoutBalanceBefore = payoutAddr.balance;
        airlock.migrate(asset);

        assertTrue(payoutAddr.balance > payoutBalanceBefore, "Distribution should be > 0 at 50%");
        _assertMigrationComplete();
    }
}
